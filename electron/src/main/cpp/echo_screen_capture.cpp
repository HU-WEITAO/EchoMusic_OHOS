/*
 * 听歌识曲 · 系统音频采集（AVScreenCapture C API，只取内录音频原始 PCM）。
 *
 * ── 为什么换成 AVScreenCapture ────────────────────────────────────────────────
 * 之前走 AudioCapturer.requestPlaybackCaptureStart() 的「录制设备内声音」授权，
 * 系统组件 InnerCapturerDialogExtension 有一个清理 bug：点击弹框外部空白后，
 * 弹框内容消失但全屏 UIExtension 容器不销毁，屏幕变成纯黑/纯白且无法退出。
 * 应用侧无法销毁系统遮罩，只能换一条授权链路。
 *
 * 网易云音乐等应用走的是 AVScreenCapture 的「允许使用你的屏幕」录屏授权，
 * 由另一个系统组件承载，不存在上述问题。AVScreenCapture 同时支持：
 *   · innerCapInfo.audioSource = OH_ALL_PLAYBACK → 设备内部正在播放的音频；
 *   · micCapInfo 采样率/声道数同时为 0 → 完全不采麦克风（也不需要麦克风权限）；
 *   · videoFrameWidth / videoFrameHeight 同时为 0 → 完全不采集屏幕画面。
 * 三者组合起来就是「只借录屏授权链路拿系统内录 PCM」，不真的录屏、不弹麦克风权限。
 *
 * ── 与壳层 / 主进程的协议 ─────────────────────────────────────────────────────
 * 本模块把 48kHz / 2ch / S16LE 的原始 PCM 直接写进 ArkTS 传进来的 ac-pcm.raw，
 * 并暴露 status() 供壳层轮询授权与采集状态；状态文件 ac-state.json 仍由
 * ScreenCaptureService.ets 写，主进程 ohosAudioCapture.ts 一行都不用改。
 *
 * 状态机：0 idle / 1 starting / 2 running / 3 denied / 4 error / 5 stopped
 */

#include <node_api.h>

#include <hilog/log.h>

#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <multimedia/player_framework/native_avscreen_capture_errors.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <unistd.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "EchoScreenCapture"

namespace {

constexpr int32_t kStateIdle = 0;
constexpr int32_t kStateStarting = 1;
constexpr int32_t kStateRunning = 2;
constexpr int32_t kStateDenied = 3;
constexpr int32_t kStateError = 4;
constexpr int32_t kStateStopped = 5;

constexpr int32_t kDefaultSampleRate = 48000;
constexpr int32_t kDefaultChannels = 2;

struct Session {
  std::atomic<int32_t> state{kStateIdle};
  std::atomic<uint64_t> bytes{0};
  std::atomic<int> pcmFd{-1};
  /** 每轮采集自增；系统回调可能晚到，用 generation 把旧回调全部作废 */
  std::atomic<uint64_t> generation{0};
  std::mutex mutex;
  std::string error;
  std::string path;
  OH_AVScreenCapture* capture = nullptr;
};

Session g_session;

void SetState(int32_t state, const char* message) {
  {
    std::lock_guard<std::mutex> lock(g_session.mutex);
    g_session.error = message ? message : "";
  }
  g_session.state.store(state);
  OH_LOG_INFO(LOG_APP, "state=%d message=%{public}s", state, message ? message : "");
}

/** 回调里的 userData 携带创建时的 generation，结束后迟到的回调一律忽略 */
bool IsCurrent(void* userData) {
  return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(userData)) ==
         g_session.generation.load();
}

void* GenerationData(uint64_t generation) {
  return reinterpret_cast<void*>(static_cast<uintptr_t>(generation));
}

// ── 系统回调 ────────────────────────────────────────────────────────────────

void OnStateChange(OH_AVScreenCapture*, OH_AVScreenCaptureStateCode code, void* userData) {
  if (!IsCurrent(userData)) {
    return;
  }
  switch (code) {
    case OH_SCREEN_CAPTURE_STATE_STARTED:
      // 用户在「允许使用你的屏幕」里点了允许，系统真正开始投递音频流
      SetState(kStateRunning, "");
      break;
    case OH_SCREEN_CAPTURE_STATE_CANCELED:
      SetState(kStateDenied, "用户取消了屏幕录制授权");
      break;
    case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
    case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
      SetState(kStateStopped, "录屏已被系统提示条停止");
      break;
    case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
      SetState(kStateError, "屏幕录制被其它应用打断");
      break;
    case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
      SetState(kStateError, "来电中断了屏幕录制");
      break;
    case OH_SCREEN_CAPTURE_STATE_MIC_UNAVAILABLE:
    case OH_SCREEN_CAPTURE_STATE_MIC_MUTED_BY_USER:
    case OH_SCREEN_CAPTURE_STATE_MIC_UNMUTED_BY_USER:
      // 我们根本没启用麦克风路，这些状态与本模块无关
      break;
    case OH_SCREEN_CAPTURE_STATE_ENTER_PRIVATE_SCENE:
    case OH_SCREEN_CAPTURE_STATE_EXIT_PRIVATE_SCENE:
      // 隐私窗口只影响画面，我们不采画面
      break;
    default:
      break;
  }
}

void OnError(OH_AVScreenCapture*, int32_t errorCode, void* userData) {
  if (!IsCurrent(userData)) {
    return;
  }
  char message[128];
  (void)snprintf(message, sizeof(message), "屏幕录制失败(code %d)", errorCode);
  SetState(kStateError, message);
}

/**
 * 音频数据回调：只做「整块写文件」。
 * 重采样、编码、网络发送都不能放这里，回调阻塞会直接丢帧。
 */
void OnBufferAvailable(OH_AVScreenCapture*, OH_AVBuffer* buffer,
                       OH_AVScreenCaptureBufferType type, int64_t, void* userData) {
  if (!IsCurrent(userData) || buffer == nullptr) {
    return;
  }
  if (type != OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_INNER) {
    return;
  }
  // 不硬性要求 state == RUNNING：个别系统版本只回调 OnUserSelected 而不上报
  // STATE_STARTED。generation + pcmFd 已经足以保证「这轮会话还活着」，
  // 真正收到第一个内录音频包才是最可靠的「采集已启动」信号。
  if (g_session.state.load() == kStateIdle) {
    return;
  }

  OH_AVCodecBufferAttr attr{};
  if (static_cast<int32_t>(OH_AVBuffer_GetBufferAttr(buffer, &attr)) != 0) {
    return;
  }
  int32_t size = attr.size;
  if (size <= 0) {
    return;
  }
  uint8_t* addr = OH_AVBuffer_GetAddr(buffer);
  if (addr == nullptr) {
    return;
  }
  int32_t offset = attr.offset > 0 ? attr.offset : 0;
  int fd = g_session.pcmFd.load();
  if (fd < 0) {
    return;
  }
  ssize_t written = ::write(fd, addr + offset, static_cast<size_t>(size));
  if (written > 0) {
    g_session.bytes.fetch_add(static_cast<uint64_t>(written));
    // 首个音频包到达即视为采集真正启动，兜底 STATE_STARTED 缺失的情况。
    // 这里只做一次无锁 CAS，不在音频回调里抢 g_session.mutex / 写 error。
    int32_t expected = kStateStarting;
    if (g_session.state.compare_exchange_strong(expected, kStateRunning)) {
      OH_LOG_INFO(LOG_APP, "first audio buffer received, capture is running");
    }
  }
}

/** API 20+ 的「用户选择结果」回调，注册后系统确认弹框才会正确回执 */
void OnUserSelected(OH_AVScreenCapture*, OH_AVScreenCapture_UserSelectionInfo*, void* userData) {
  if (!IsCurrent(userData)) {
    return;
  }
  OH_LOG_INFO(LOG_APP, "user confirmed screen capture selection");
}

// ── 生命周期 ────────────────────────────────────────────────────────────────

/**
 * 停止并释放。先自增 generation 让系统回调失效，再摘掉 fd / capture 指针，
 * 最后才做阻塞的 Stop/Release —— 避免回调线程在释放过程中继续写文件。
 */
void Teardown(bool removeFile) {
  uint64_t generation = g_session.generation.fetch_add(1) + 1;
  (void)generation;

  int fd = g_session.pcmFd.exchange(-1);
  OH_AVScreenCapture* capture = nullptr;
  std::string path;
  {
    std::lock_guard<std::mutex> lock(g_session.mutex);
    capture = g_session.capture;
    g_session.capture = nullptr;
    path = g_session.path;
  }

  if (capture != nullptr) {
    OH_AVScreenCapture_StopScreenCapture(capture);
    OH_AVScreenCapture_Release(capture);
  }
  if (fd >= 0) {
    ::close(fd);
  }
  if (removeFile && !path.empty()) {
    ::unlink(path.c_str());
  }
}

// ── napi helpers ────────────────────────────────────────────────────────────

napi_value MakeResult(napi_env env, int32_t code, const char* message) {
  napi_value object = nullptr;
  napi_create_object(env, &object);
  napi_value nCode = nullptr;
  napi_create_int32(env, code, &nCode);
  napi_set_named_property(env, object, "code", nCode);
  napi_value nMessage = nullptr;
  napi_create_string_utf8(env, message ? message : "", NAPI_AUTO_LENGTH, &nMessage);
  napi_set_named_property(env, object, "message", nMessage);
  return object;
}

napi_value Ok(napi_env env) {
  return MakeResult(env, static_cast<int32_t>(AV_SCREEN_CAPTURE_ERR_OK), "");
}

// ── 导出给 ArkTS 的方法 ───────────────────────────────────────────────────────

/**
 * start(pcmPath, sampleRate?, channels?): { code, message }
 * 同步返回「创建 + 参数初始化 + 拉起录屏授权」的结果；授权本身是异步的，
 * 结果通过 status() 轮询。
 */
napi_value Start(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  char path[512] = {0};
  size_t pathLength = 0;
  if (argc >= 1 && argv[0] != nullptr) {
    napi_get_value_string_utf8(env, argv[0], path, sizeof(path), &pathLength);
  }
  if (pathLength == 0) {
    return MakeResult(env, -1, "pcm path is required");
  }
  int32_t sampleRate = kDefaultSampleRate;
  int32_t channels = kDefaultChannels;
  if (argc >= 2 && argv[1] != nullptr) {
    napi_get_value_int32(env, argv[1], &sampleRate);
  }
  if (argc >= 3 && argv[2] != nullptr) {
    napi_get_value_int32(env, argv[2], &channels);
  }
  if (sampleRate <= 0) {
    sampleRate = kDefaultSampleRate;
  }
  if (channels <= 0) {
    channels = kDefaultChannels;
  }

  Teardown(false);
  g_session.bytes.store(0);
  {
    std::lock_guard<std::mutex> lock(g_session.mutex);
    g_session.error.clear();
    g_session.path = path;
  }

  int fd = ::open(path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0666);
  if (fd < 0) {
    return MakeResult(env, -errno, "open pcm file failed");
  }
  g_session.pcmFd.store(fd);

  OH_AVScreenCapture* capture = OH_AVScreenCapture_Create();
  if (capture == nullptr) {
    Teardown(true);
    return MakeResult(env, -2, "OH_AVScreenCapture_Create failed");
  }
  {
    std::lock_guard<std::mutex> lock(g_session.mutex);
    g_session.capture = capture;
  }

  // 结构体先整体清零，再只填合法参数（官方明确要求）。
  // micCapInfo 全 0 → 不采麦克风；videoCapInfo 宽高全 0 → 不采画面。
  OH_AVScreenCaptureConfig config{};
  config.captureMode = OH_CAPTURE_HOME_SCREEN;
  config.dataType = OH_ORIGINAL_STREAM;
  config.audioInfo.micCapInfo.audioSampleRate = 0;
  config.audioInfo.micCapInfo.audioChannels = 0;
  config.audioInfo.micCapInfo.audioSource = OH_SOURCE_INVALID;
  config.audioInfo.innerCapInfo.audioSampleRate = sampleRate;
  config.audioInfo.innerCapInfo.audioChannels = channels;
  config.audioInfo.innerCapInfo.audioSource = OH_ALL_PLAYBACK;
  config.videoInfo.videoCapInfo.videoFrameWidth = 0;
  config.videoInfo.videoCapInfo.videoFrameHeight = 0;
  config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;

  OH_AVSCREEN_CAPTURE_ErrCode code = OH_AVScreenCapture_Init(capture, config);
  if (code != AV_SCREEN_CAPTURE_ERR_OK) {
    Teardown(true);
    return MakeResult(env, static_cast<int32_t>(code), "OH_AVScreenCapture_Init failed");
  }

  // 明确关闭麦克风路（配置里已经全 0，这里是双保险）
  OH_AVScreenCapture_SetMicrophoneEnabled(capture, false);

  uint64_t generation = g_session.generation.load();
  void* userData = GenerationData(generation);
  code = OH_AVScreenCapture_SetStateCallback(capture, OnStateChange, userData);
  if (code != AV_SCREEN_CAPTURE_ERR_OK) {
    Teardown(true);
    return MakeResult(env, static_cast<int32_t>(code), "SetStateCallback failed");
  }
  code = OH_AVScreenCapture_SetErrorCallback(capture, OnError, userData);
  if (code != AV_SCREEN_CAPTURE_ERR_OK) {
    Teardown(true);
    return MakeResult(env, static_cast<int32_t>(code), "SetErrorCallback failed");
  }
  code = OH_AVScreenCapture_SetDataCallback(capture, OnBufferAvailable, userData);
  if (code != AV_SCREEN_CAPTURE_ERR_OK) {
    Teardown(true);
    return MakeResult(env, static_cast<int32_t>(code), "SetDataCallback failed");
  }

  // API 20+ 的用户选择回调，动态解析以免在低版本系统上产生硬符号依赖。
  using SetSelectionFn = OH_AVSCREEN_CAPTURE_ErrCode (*)(
      OH_AVScreenCapture*, OH_AVScreenCapture_OnUserSelected, void*);
  auto setSelection = reinterpret_cast<SetSelectionFn>(
      dlsym(RTLD_DEFAULT, "OH_AVScreenCapture_SetSelectionCallback"));
  if (setSelection != nullptr) {
    (void)setSelection(capture, OnUserSelected, userData);
  }

  g_session.state.store(kStateStarting);
  code = OH_AVScreenCapture_StartScreenCapture(capture);
  if (code != AV_SCREEN_CAPTURE_ERR_OK) {
    Teardown(true);
    return MakeResult(env, static_cast<int32_t>(code),
                      "OH_AVScreenCapture_StartScreenCapture failed");
  }
  OH_LOG_INFO(LOG_APP, "start ok, waiting for screen capture authorization");
  return Ok(env);
}

/** status(): { state, bytes, error } */
napi_value Status(napi_env env, napi_callback_info) {
  napi_value object = nullptr;
  napi_create_object(env, &object);

  napi_value nState = nullptr;
  napi_create_int32(env, g_session.state.load(), &nState);
  napi_set_named_property(env, object, "state", nState);

  napi_value nBytes = nullptr;
  napi_create_int64(env, static_cast<int64_t>(g_session.bytes.load()), &nBytes);
  napi_set_named_property(env, object, "bytes", nBytes);

  std::string error;
  {
    std::lock_guard<std::mutex> lock(g_session.mutex);
    error = g_session.error;
  }
  napi_value nError = nullptr;
  napi_create_string_utf8(env, error.c_str(), NAPI_AUTO_LENGTH, &nError);
  napi_set_named_property(env, object, "error", nError);
  return object;
}

/** stop(): 结束采集，保留 PCM 文件供主进程读取 */
napi_value Stop(napi_env env, napi_callback_info) {
  Teardown(false);
  g_session.state.store(kStateStopped);
  OH_LOG_INFO(LOG_APP, "stopped, bytes=%{public}llu",
              static_cast<unsigned long long>(g_session.bytes.load()));
  return Ok(env);
}

/** cancel(): 结束采集并删除本轮 PCM */
napi_value Cancel(napi_env env, napi_callback_info) {
  Teardown(true);
  g_session.bytes.store(0);
  g_session.state.store(kStateIdle);
  return Ok(env);
}

/** release(): 应用退出时静默释放 */
napi_value Release(napi_env env, napi_callback_info) {
  Teardown(true);
  g_session.bytes.store(0);
  g_session.state.store(kStateIdle);
  return Ok(env);
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

// libecho_screen_capture.so ↔ import ... from 'libecho_screen_capture.so'
// nm_modname 必须是去掉 lib 前缀和 .so 后缀的名字（与 libadapter.so / adapter 同理）。
napi_module g_module = {
    .nm_version = NAPI_MODULE_VERSION,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "echo_screen_capture",
    .nm_priv = nullptr,
    .reserved = {nullptr, nullptr, nullptr, nullptr},
};

extern "C" __attribute__((constructor)) void RegisterEchoScreenCaptureModule() {
  napi_module_register(&g_module);
}

}  // namespace
