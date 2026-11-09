/**
 * AVScreenCapture C API 采集桥（libecho_screen_capture.so）的 ArkTS 类型声明。
 * 只取系统内录音频的原始 PCM，不采麦克风、不采画面。
 */

export interface ScreenCaptureResult {
  /** AV_SCREEN_CAPTURE_ERR_OK(0) 表示调用成功；负数或系统错误码表示失败 */
  code: number;
  /** 失败时的可读原因 */
  message: string;
}

export interface ScreenCaptureStatus {
  /** 0 idle / 1 starting / 2 running / 3 denied / 4 error / 5 stopped */
  state: number;
  /** 本轮已写入 PCM 文件的字节数 */
  bytes: number;
  /** 系统回调给出的失败原因 */
  error: string;
}

/** 创建录屏实例并拉起系统「允许使用你的屏幕」授权；授权结果异步，用 status() 轮询 */
export const start: (path: string, sampleRate?: number, channels?: number) => ScreenCaptureResult;
/** 查询当前采集状态与已写入字节数 */
export const status: () => ScreenCaptureStatus;
/** 停止采集，保留 PCM 文件供主进程读取 */
export const stop: () => ScreenCaptureResult;
/** 取消本轮采集并删除 PCM 文件 */
export const cancel: () => ScreenCaptureResult;
/** 应用退出时静默释放 */
export const release: () => ScreenCaptureResult;
