/**
 * 听歌识曲采集服务门面（壳层侧）。
 *
 * ── 两条音源链路 ─────────────────────────────────────────────────────────────
 *   · system → ScreenCaptureService（AVScreenCapture C API，系统「允许使用你的屏幕」
 *              授权链路，只取设备内录 PCM，不采麦克风、不采画面）。
 *   · mic    → 本文件里的 AudioCapturer（SOURCE_TYPE_MIC + MICROPHONE 权限）。
 *
 * 原先 system 也走 AudioCapturer.requestPlaybackCaptureStart()，但系统组件
 * InnerCapturerDialogExtension 有清理 bug（点弹框外空白后全屏容器不销毁，屏幕
 * 纯黑/纯白且无法退出），应用侧修不了，所以换成上面的录屏授权链路。
 *
 * ── 协议（与主进程 ohosAudioCapture.ts 一一对应）────────────────────────────────
 *   主进程 → 本文件：CommonEvent(EVENT_STATE) 下发
 *     {"type":"capture","action":"start","source":"system|mic","seq":N}
 *     {"type":"capture","action":"stop","seq":N}
 *     {"type":"capture","action":"cancel"}
 *   本文件 → 主进程：应用级沙箱文件（与 app.getPath('userData') 同一目录）
 *     ac-state.json  {seq,state,source,sampleRate,channels,bytes,frames,error,at}
 *                   state: requesting / running / denied / error / stopped / canceled
 *     ac-pcm.raw     采集到的原始 PCM（48kHz / 立体声 / S16LE），停止时落盘完毕
 *
 * ── 为什么 PCM 落文件而不是走内存 ─────────────────────────────────────────────
 * 10 秒 48kHz 立体声 = 1.92MB，一次识别完全放得下，但采集回调里做重采样 / 编码
 * 会阻塞采集（文档明确不建议），所以回调里只做「整块写文件」这一件最轻的事，
 * 8kHz 单声道的转换交给主进程（Node 侧，不影响采集线程）。
 */
import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import { ScreenCaptureService } from './ScreenCaptureService';

const TAG = 'PlaybackCapture';

/** 采集参数：与系统原生格式对齐，避免设备侧做一次额外重采样 */
const CAPTURE_SAMPLE_RATE: number = 48000;
const CAPTURE_CHANNELS: number = 2;
const BYTES_PER_SAMPLE: number = 2;

/** 壳层写、主进程读：采集状态 */
const STATE_FILE_NAME: string = 'ac-state.json';
/** 壳层写、主进程读：本轮采集的原始 PCM */
const PCM_FILE_NAME: string = 'ac-pcm.raw';

/** 回报给主进程的状态载荷 */
interface CaptureStatePayload {
  seq: number;
  state: string;
  source: string;
  sampleRate: number;
  channels: number;
  bytes: number;
  frames: number;
  error: string;
  at: number;
}

export class PlaybackCaptureService {
  private context: common.UIAbilityContext;
  private resolveDir: () => string;
  /** 系统音频：AVScreenCapture 录屏授权链路 */
  private screenCapture: ScreenCaptureService;
  /** 本轮活跃的音源，决定 stop/cancel 转发给谁 */
  private activeSource: string = '';

  private capturer: audio.AudioCapturer | undefined = undefined;
  /** PCM 文件句柄（-1 = 未打开） */
  private pcmFd: number = -1;
  /** 当前这一轮的命令序号（原样回写，主进程按它匹配异步结果） */
  private seq: number = 0;
  /** 启动请求序号：异步创建期间用户取消时，旧请求的结果不能改写新一轮状态 */
  private requestId: number = 0;
  private source: string = 'mic';
  private bytes: number = 0;
  private running: boolean = false;

  constructor(context: common.UIAbilityContext, resolveDir: () => string) {
    this.context = context;
    this.resolveDir = resolveDir;
    this.screenCapture = new ScreenCaptureService(resolveDir);
  }

  /** 主进程下发的采集指令 */
  handleCommand(obj: Record<string, Object>): void {
    const action: string = typeof obj.action === 'string' ? obj.action as string : '';
    const seq: number = typeof obj.seq === 'number' ? obj.seq as number : 0;

    if (action === 'start') {
      const requested: string = typeof obj.source === 'string' ? obj.source as string : 'system';
      this.activeSource = requested === 'mic' ? 'mic' : 'system';
      const cancelOther: Record<string, Object> = { 'action': 'cancel' };
      if (this.activeSource === 'system') {
        // 切音源时先收掉可能悬挂的麦克风采集器；quiet=true 不写状态，
        // 否则会把系统音频刚写下的 requesting 覆盖成 canceled。
        this.cancel(true).catch((e: BusinessError) => {
          hilog.warn(0x0000, TAG, `quiet cancel mic failed: ${e.message}`);
        });
        this.screenCapture.handleCommand(obj);
        return;
      }
      this.screenCapture.handleCommand(cancelOther);
      this.startMic(seq).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, `start mic failed: ${e.message}`);
        this.reportError(e);
      });
      return;
    }

    if (action === 'stop') {
      if (this.activeSource === 'system') {
        this.screenCapture.handleCommand(obj);
        return;
      }
      this.stop(seq).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, `stop mic failed: ${e.message}`);
        this.reportError(e);
      });
      return;
    }

    if (action === 'cancel') {
      // 两条链路都收：应用退出时 activeSource 可能还是空的，
      // 只判活跃源会漏掉「授权等待中」的那一轮。
      this.screenCapture.handleCommand(obj);
      this.cancel().catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, `cancel mic failed: ${e.message}`);
      });
    }
  }

  /** 应用退出：静默释放（不写状态，主进程已经不关心结果了） */
  async release(): Promise<void> {
    await this.screenCapture.release();
    this.requestId++;
    await this.releaseCapturer();
    this.removePcmFile();
  }

  // ── 麦克风启动 ────────────────────────────────────────────────────────────

  private async startMic(seq: number): Promise<void> {
    await this.releaseCapturer();
    this.seq = seq;
    this.source = 'mic';
    this.bytes = 0;
    this.requestId++;
    const requestId: number = this.requestId;
    hilog.info(0x0000, TAG, `start mic requested: seq=${seq}`);
    this.writeState('requesting', '');

    const granted: boolean = await this.requestMicPermission();
    if (requestId !== this.requestId) {
      return;
    }
    if (!granted) {
      hilog.warn(0x0000, TAG, 'microphone permission denied');
      this.writeState('denied', '麦克风权限未授权');
      return;
    }

    this.removePcmFile();
    try {
      const file = fs.openSync(this.pcmPath(),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      this.pcmFd = file.fd;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `open pcm file failed: ${err.message}`);
      this.writeState('error', `无法创建录音缓存文件: ${err.message}`);
      return;
    }

    let capturer: audio.AudioCapturer | undefined = undefined;
    try {
      capturer = await audio.createAudioCapturer(this.buildMicOptions());
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG,
        `createAudioCapturer failed: code=${err.code} msg=${err.message}`);
      this.closePcm();
      this.writeState('error', `无法创建音频采集器: ${err.message}(code ${err.code})`);
      return;
    }
    if (requestId !== this.requestId) {
      await capturer.release();
      return;
    }
    this.capturer = capturer;
    try {
      capturer.on('readData', this.onReadData);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `register readData failed: ${err.message}`);
      await this.releaseCapturer();
      this.writeState('error', `注册音频回调失败: ${err.message}`);
      return;
    }

    try {
      await capturer.start();
      if (requestId !== this.requestId) {
        await this.releaseCapturer();
        return;
      }
      this.running = true;
      this.writeState('running', '');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `mic start failed: code=${err.code} msg=${err.message}`);
      this.failStart('error', `麦克风启动失败: ${err.message}(code ${err.code})`);
    }
  }

  private buildMicOptions(): audio.AudioCapturerOptions {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
      channels: audio.AudioChannel.CHANNEL_2,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    return { streamInfo: streamInfo, capturerInfo: capturerInfo };
  }

  private async requestMicPermission(): Promise<boolean> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const perms: Array<Permissions> = ['ohos.permission.MICROPHONE'];
      const result = await manager.requestPermissionsFromUser(this.context, perms);
      if (!result.authResults || result.authResults.length === 0) {
        return false;
      }
      return result.authResults[0] === 0;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `request microphone permission failed: ${err.message}`);
      return false;
    }
  }

  /** 启动失败：先释放采集器，再回写终态（主进程据此抛错给界面） */
  private failStart(kind: string, message: string): void {
    this.releaseCapturer().then(() => {
      this.writeState(kind, message);
    }).catch(() => {
      this.writeState(kind, message);
    });
  }

  // ── 停止 / 取消 ──────────────────────────────────────────────────────────

  private async stop(seq: number): Promise<void> {
    if (seq > 0) {
      this.seq = seq;
    }
    this.requestId++;
    await this.releaseCapturer();
    hilog.info(0x0000, TAG, `stopped: bytes=${this.bytes}`);
    // 文件句柄已在 releaseCapturer 里关闭，此刻落盘内容是完整的
    this.writeState('stopped', '');
  }

  /**
   * @param quiet 切音源时补发的清理：不回写状态，避免覆盖新一轮的 requesting。
   */
  private async cancel(quiet: boolean = false): Promise<void> {
    this.requestId++;
    const hadCapturer: boolean = this.capturer !== undefined;
    await this.releaseCapturer();
    if (!quiet) {
      // quiet 是「切到系统音源时补发」的清理，此时新链路可能已经创建了
      // 同名 ac-pcm.raw；这里再删一次会把对方刚打开的文件删掉。
      this.removePcmFile();
      this.bytes = 0;
      if (hadCapturer) {
        this.writeState('canceled', '');
      }
    }
    hilog.info(0x0000, TAG, `canceled: hadCapturer=${hadCapturer} quiet=${quiet}`);
  }

  private async releaseCapturer(): Promise<void> {
    const capturer: audio.AudioCapturer | undefined = this.capturer;
    this.capturer = undefined;
    const wasRunning: boolean = this.running;
    this.running = false;
    if (capturer) {
      try {
        capturer.off('readData', this.onReadData);
      } catch (e) {
        hilog.warn(0x0000, TAG, `off readData failed: ${(e as BusinessError).message}`);
      }
      if (wasRunning) {
        try {
          await capturer.stop();
        } catch (e) {
          hilog.warn(0x0000, TAG, `capturer stop failed: ${(e as BusinessError).message}`);
        }
      }
      try {
        await capturer.release();
      } catch (e) {
        hilog.warn(0x0000, TAG, `capturer release failed: ${(e as BusinessError).message}`);
      }
    }
    this.closePcm();
  }

  // ── 采集回调 ────────────────────────────────────────────────────────────

  /**
   * readData：只做「整块写文件」。
   * 重采样 / 编码 / 网络发送都不能放这里 —— 回调阻塞会直接丢帧、产生杂音。
   */
  private onReadData = (buffer: ArrayBuffer): void => {
    if (this.pcmFd < 0 || !buffer) {
      return;
    }
    try {
      fs.writeSync(this.pcmFd, buffer);
      this.bytes += buffer.byteLength;
    } catch (e) {
      hilog.error(0x0000, TAG, `write pcm failed: ${(e as BusinessError).message}`);
    }
  };

  // ── 落盘 ────────────────────────────────────────────────────────────────

  private pcmPath(): string {
    return `${this.resolveDir()}/${PCM_FILE_NAME}`;
  }

  private removePcmFile(): void {
    const file: string = this.pcmPath();
    try {
      if (fs.accessSync(file)) {
        fs.unlinkSync(file);
      }
    } catch (e) {
      // 文件本来就不存在
    }
  }

  private closePcm(): void {
    if (this.pcmFd < 0) {
      return;
    }
    try {
      fs.closeSync(this.pcmFd);
    } catch (e) {
      hilog.warn(0x0000, TAG, `close pcm failed: ${(e as BusinessError).message}`);
    }
    this.pcmFd = -1;
  }

  private reportError(e: BusinessError): void {
    this.writeState('error', e.message ? e.message : 'audio capture failed');
  }

  /**
   * 回写采集状态。主进程轮询这个文件，按 seq 匹配「是不是我这轮请求的结果」。
   * 只在状态迁移时写，不在数据回调里写 —— 那是每秒 50 次的高频路径。
   */
  private writeState(state: string, error: string): void {
    try {
      const payload: CaptureStatePayload = {
        seq: this.seq,
        state: state,
        source: this.source,
        sampleRate: CAPTURE_SAMPLE_RATE,
        channels: CAPTURE_CHANNELS,
        bytes: this.bytes,
        frames: Math.floor(this.bytes / (CAPTURE_CHANNELS * BYTES_PER_SAMPLE)),
        error: error,
        at: Date.now()
      };
      const file: string = `${this.resolveDir()}/${STATE_FILE_NAME}`;
      const f = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(payload));
      } finally {
        fs.closeSync(f);
      }
      hilog.info(0x0000, TAG, `state=${state} seq=${this.seq} bytes=${this.bytes} error=${error}`);
    } catch (e) {
      hilog.error(0x0000, TAG, `write state failed: ${(e as BusinessError).message}`);
    }
  }
}
