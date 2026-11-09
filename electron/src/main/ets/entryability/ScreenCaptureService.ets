/**
 * 听歌识曲 · 系统音频采集（AVScreenCapture 录屏授权链路）。
 *
 * ── 为什么有这个文件 ─────────────────────────────────────────────────────────
 * 上一版用 AudioCapturer.requestPlaybackCaptureStart() 弹「录制设备内声音」，
 * 系统组件 InnerCapturerDialogExtension 有清理 bug：点弹框外部空白后弹框内容消失、
 * 全屏 UIExtension 容器却不销毁，屏幕变成纯黑/纯白且无法退出。应用侧修不了系统遮罩，
 * 只能换授权链路。网易云音乐等应用用的是 AVScreenCapture 的「允许使用你的屏幕」，
 * 由另一套系统组件承载，不存在这个问题。
 *
 * 采集本体在 native（libecho_screen_capture.so，见 src/main/cpp/echo_screen_capture.cpp）：
 *   · innerCapInfo.audioSource = OH_ALL_PLAYBACK → 设备内部正在播放的音频；
 *   · micCapInfo 采样率/声道数全 0 → 完全不采麦克风，也不需要麦克风权限；
 *   · videoFrameWidth / videoFrameHeight 全 0 → 完全不采集画面。
 * 也就是「只借录屏授权链路拿系统内录 PCM」，产出仍是 48kHz / 立体声 / S16LE。
 *
 * ── 协议（与主进程 ohosAudioCapture.ts 一一对应）────────────────────────────────
 *   主进程 → 本文件：CommonEvent 下发 {type:'capture',action:'start|stop|cancel',seq}
 *   本文件 → 主进程：应用级沙箱文件
 *     ac-state.json  {seq,state,source,sampleRate,channels,bytes,frames,error,at}
 *     ac-pcm.raw     原始 PCM（native 侧直接写，停止时落盘完毕）
 *   本文件 ↔ native：start() 同步拉起授权，status() 轮询异步结果。
 *
 * 主进程那边的读取、8kHz 单声道重采样、取消逻辑完全不用改。
 */
import screenCapture from 'libecho_screen_capture.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'ScreenCapture';

/** 与 native 采集配置一致，主进程按这两个值做重采样 */
const CAPTURE_SAMPLE_RATE: number = 48000;
const CAPTURE_CHANNELS: number = 2;
const BYTES_PER_SAMPLE: number = 2;

const STATE_FILE_NAME: string = 'ac-state.json';
const PCM_FILE_NAME: string = 'ac-pcm.raw';

/** native 状态机（与 cpp 里 kState* 一一对应） */
const NATIVE_STARTING: number = 1;
const NATIVE_RUNNING: number = 2;
const NATIVE_DENIED: number = 3;
const NATIVE_ERROR: number = 4;
const NATIVE_STOPPED: number = 5;

/** 轮询授权结果的间隔：弹框期间状态只变几次，100ms 足够跟手 */
const POLL_INTERVAL_MS: number = 100;
/**
 * 录屏授权看门狗。用户需要在「允许使用你的屏幕」里选择屏幕/窗口再确认，
 * 比旧的音频内录弹框多一步，给足 60s；超时后主动释放 native 实例并回写终态，
 * 避免系统录屏指示一直挂着、状态永远停在 requesting。
 */
const AUTH_TIMEOUT_MS: number = 60000;

interface ScreenCaptureResult {
  code: number;
  message: string;
}

interface ScreenCaptureStatus {
  state: number;
  bytes: number;
  error: string;
}

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

export class ScreenCaptureService {
  private resolveDir: () => string;

  private seq: number = 0;
  /** 本轮请求序号：系统回调/定时器可能晚到，旧请求一律作废 */
  private requestId: number = 0;
  private bytes: number = 0;
  private running: boolean = false;
  /** native 实例是否已经建起来（决定 cancel 要不要写状态、退出要不要释放） */
  private started: boolean = false;
  private pollTimer: number = -1;
  private authTimer: number = -1;

  constructor(resolveDir: () => string) {
    this.resolveDir = resolveDir;
  }

  /** 主进程下发的采集指令（由 PlaybackCaptureService 按音源分流过来） */
  handleCommand(obj: Record<string, Object>): void {
    const action: string = typeof obj.action === 'string' ? obj.action as string : '';
    const seq: number = typeof obj.seq === 'number' ? obj.seq as number : 0;
    if (action === 'start') {
      this.start(seq);
      return;
    }
    if (action === 'stop') {
      this.stop(seq);
      return;
    }
    if (action === 'cancel') {
      this.cancel();
    }
  }

  /** 应用退出：静默释放，不写状态（主进程已经不关心结果了） */
  async release(): Promise<void> {
    this.clearTimers();
    this.requestId++;
    try {
      screenCapture.release();
    } catch (e) {
      hilog.warn(0x0000, TAG, `native release failed: ${(e as BusinessError).message}`);
    }
    this.started = false;
    this.running = false;
    this.removePcmFile();
  }

  // ── 启动 ────────────────────────────────────────────────────────────────

  private start(seq: number): void {
    this.clearTimers();
    this.requestId++;
    const requestId: number = this.requestId;
    this.seq = seq;
    this.bytes = 0;
    this.running = false;
    this.started = false;
    hilog.info(0x0000, TAG, `start requested: seq=${seq}`);

    // 先回 requesting：录屏授权是异步的，弹框可能要用户点一下才回来
    this.writeState('requesting', '');
    this.removePcmFile();

    let result: ScreenCaptureResult;
    try {
      result = screenCapture.start(this.pcmPath(), CAPTURE_SAMPLE_RATE,
        CAPTURE_CHANNELS) as ScreenCaptureResult;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `native start failed: ${err.message}`);
      this.writeState('error', `屏幕录制组件不可用: ${err.message}`);
      return;
    }
    if (result.code !== 0) {
      hilog.error(0x0000, TAG, `native start error: code=${result.code} msg=${result.message}`);
      this.writeState('error', `无法启动屏幕录制: ${result.message}(code ${result.code})`);
      return;
    }
    this.started = true;

    this.authTimer = setTimeout(() => {
      if (requestId !== this.requestId) {
        return;
      }
      hilog.warn(0x0000, TAG, 'screen capture authorization timeout');
      this.finishEarly(requestId, 'error', '等待屏幕录制授权超时，请重试');
    }, AUTH_TIMEOUT_MS);

    this.pollTimer = setInterval(() => {
      if (requestId !== this.requestId) {
        return;
      }
      let status: ScreenCaptureStatus;
      try {
        status = screenCapture.status() as ScreenCaptureStatus;
      } catch (e) {
        hilog.error(0x0000, TAG, `native status failed: ${(e as BusinessError).message}`);
        this.finishEarly(requestId, 'error', '屏幕录制组件状态异常');
        return;
      }
      this.bytes = status.bytes;
      if (status.state === NATIVE_STARTING) {
        return;
      }
      if (status.state === NATIVE_RUNNING) {
        if (!this.running) {
          this.running = true;
          this.clearAuthTimer();
          hilog.info(0x0000, TAG, `running: seq=${this.seq}`);
          this.writeState('running', '');
        }
        return;
      }
      if (status.state === NATIVE_DENIED) {
        this.finishEarly(requestId, 'denied', status.error || '用户未允许使用屏幕录制');
      } else if (status.state === NATIVE_ERROR) {
        this.finishEarly(requestId, 'error', status.error || '屏幕录制启动失败');
      } else if (status.state === NATIVE_STOPPED) {
        this.finishEarly(requestId, 'error', '屏幕录制已被系统停止，请重试');
      }
    }, POLL_INTERVAL_MS);
  }

  /** 授权阶段就落到终态：释放 native 实例 + 回写，避免状态永远停在 requesting */
  private finishEarly(requestId: number, state: string, message: string): void {
    if (requestId !== this.requestId) {
      return;
    }
    this.clearTimers();
    this.requestId++;
    try {
      screenCapture.cancel();
    } catch (e) {
      hilog.warn(0x0000, TAG, `native cancel failed: ${(e as BusinessError).message}`);
    }
    this.removePcmFile();
    this.started = false;
    this.running = false;
    this.bytes = 0;
    this.writeState(state, message);
  }

  // ── 停止 / 取消 ──────────────────────────────────────────────────────────

  private stop(seq: number): void {
    if (seq > 0) {
      this.seq = seq;
    }
    this.clearTimers();
    this.requestId++;
    try {
      screenCapture.stop();
      // stop() 保留 bytes，cancel() 会清零，所以这里才是取最终字节数的唯一时机
      const status = screenCapture.status() as ScreenCaptureStatus;
      this.bytes = status.bytes;
    } catch (e) {
      hilog.warn(0x0000, TAG, `native stop failed: ${(e as BusinessError).message}`);
    }
    this.started = false;
    this.running = false;
    hilog.info(0x0000, TAG, `stopped: seq=${this.seq} bytes=${this.bytes}`);
    // native 已关闭文件句柄，此刻 ac-pcm.raw 落盘完整，主进程读完会自己删
    this.writeState('stopped', '');
  }

  private cancel(): void {
    this.clearTimers();
    this.requestId++;
    const hadSession: boolean = this.started;
    try {
      screenCapture.cancel();
    } catch (e) {
      hilog.warn(0x0000, TAG, `native cancel failed: ${(e as BusinessError).message}`);
    }
    this.removePcmFile();
    this.started = false;
    this.running = false;
    this.bytes = 0;
    // 切音源时也会给另一条链路补发 cancel。没有活跃会话就别写状态，
    // 否则会把新一轮刚写下的 requesting 覆盖成 canceled。
    if (hadSession) {
      this.writeState('canceled', '');
    }
    hilog.info(0x0000, TAG, `canceled: hadSession=${hadSession}`);
  }

  private clearTimers(): void {
    this.clearAuthTimer();
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private clearAuthTimer(): void {
    if (this.authTimer >= 0) {
      clearTimeout(this.authTimer);
      this.authTimer = -1;
    }
  }

  // ── 落盘 ────────────────────────────────────────────────────────────────

  private pcmPath(): string {
    return `${this.resolveDir()}/${PCM_FILE_NAME}`;
  }

  private removePcmFile(): void {
    try {
      if (fs.accessSync(this.pcmPath())) {
        fs.unlinkSync(this.pcmPath());
      }
    } catch (e) {
      // 文件本来就不存在
    }
  }

  /**
   * 回写采集状态。主进程轮询这个文件并按 seq 匹配本轮结果。
   * 只在状态迁移时写，音频数据由 native 直接写 PCM 文件，不走这里。
   */
  private writeState(state: string, error: string): void {
    try {
      const payload: CaptureStatePayload = {
        seq: this.seq,
        state: state,
        source: 'system',
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
