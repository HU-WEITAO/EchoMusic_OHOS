# EchoMusic 鸿蒙版 · EchoMusic for HarmonyOS

<p align="center">
  <img src="AppScope/resources/base/media/app_icon.png" width="128" height="128" alt="EchoMusic Logo">
</p>

<p align="center">
  <strong>EchoMusic 鸿蒙版</strong> —— 把桌面端 Electron 播放器 <a href="https://github.com/hoowhoami/EchoMusic">hoowhoami/EchoMusic</a> 整体搬到 HarmonyOS 设备上运行。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-HarmonyOS%206.1.0-brightgreen" alt="Platform">
  <img src="https://img.shields.io/badge/Language-ArkTS%20%2B%20ArkUI-1677FF" alt="ArkTS">
  <img src="https://img.shields.io/badge/Runtime-Chromium%20132-47848F" alt="Runtime">
  <img src="https://img.shields.io/badge/SDK-API%2023%20(6.1.0)-8A2BE2" alt="SDK">
  <img src="https://img.shields.io/badge/Arch-arm64--v8a-blue" alt="Arch">
  <img src="https://img.shields.io/badge/License-GPLv3-orange" alt="License">
</p>

---

## ⚠️ 移植声明（请先读这一段）

> **本项目是开源项目 [hoowhoami/EchoMusic](https://github.com/hoowhoami/EchoMusic) 的 HarmonyOS（鸿蒙）移植版本，不是原创项目。**
>
> | 项目 | 说明 |
> | --- | --- |
> | 上游项目 | [hoowhoami/EchoMusic](https://github.com/hoowhoami/EchoMusic) —— 「一个简约的第三方酷狗概念版音乐播放器」 |
> | 上游作者 | [@hoowhoami](https://github.com/hoowhoami) |
> | 上游协议 | GNU General Public License v3.0 |
> | 本仓库 | **移植版** —— 仅做鸿蒙平台适配，不含任何播放器本体的原创实现 |
>
> **播放器本体（界面、交互、插件体系、音效引擎、本地 Node 服务、数据接口）全部来自上游项目**，
> 本项目做的事情是：把上游这个桌面端 Electron 应用，原样搬到鸿蒙设备上跑起来，
> 并针对鸿蒙的窗口模型、系统媒体框架、后台任务机制与 SDK 版本做必要的适配与修复。
>
> 上游代码若在别处更新，本移植版不会自动同步；两边是**独立演进的仓库**：
> 上游的问题请不要提到本仓库，本仓库的适配问题也不要提给上游。
>
> 本移植版同样以 **GPL-3.0** 发布，衍生关系与改动说明见 [`NOTICE.md`](NOTICE.md)。

---

## 这是什么

上游是一个 **Electron 桌面应用**（macOS / Windows / Linux）。本项目给它套了一层鸿蒙外壳：

```
┌─ HarmonyOS 应用（DevEco 工程）──────────────────────────┐
│                                                        │
│  electron/  ← entry 模块：Ability、窗口、页面（ArkTS）    │
│      │                                                 │
│      ↓ ArkWeb 容器 + ipcRenderer 桥                       │
│  web_engine/  ← Electron 鸿蒙化运行时（Chromium 132）     │
│      │                                                 │
│      ↓ 原样加载                                          │
│  resfile/  ← 上游 Electron 载荷（未改一个字节）           │
│      ├── app/dist/          前端构建产物（Vue 3）         │
│      ├── app/dist-electron/ 主进程 + preload             │
│      └── server/            本地 Node 服务（Express）      │
└────────────────────────────────────────────────────────┘
```

**关键点**：鸿蒙侧提供的是一个「Electron 容器」，上游原本跑在桌面上的那套前端与服务端代码
被原封不动地跑在这个容器里；需要落地的原生能力（音频解码、系统媒体控制、本地存储）
由**用鸿蒙交叉工具链重新编译过的 napi 模块**提供。

工程规模：ArkTS 源码 **153 个文件 / 19,854 行**（`web_engine` 135 + `electron` 18），
原生库 **8 个 / 180 MB**。

---

## ✨ 鸿蒙原生能力适配

这是本移植版的核心工作。上游原本依赖 macOS `MPNowPlayingInfoCenter`、Windows `SMTC`、
Linux `MPRIS` 三套系统媒体接口，本移植版把它们统一收敛到鸿蒙的 **AVSession** 框架，
并额外接上了桌面端不存在或行为不同的能力：后台保活、实况窗、自由窗口形态约束等。

### 1. 系统媒体控制（AVSession）· 媒体实况窗

| 能力 | 实现 |
| --- | --- |
| 会话创建 | `avSession.createAVSession(context, 'echomusic.media', 'audio')` |
| 元数据推送 | `setAVMetadata()` —— 曲名 / 歌手 / 专辑 / 封面 / 时长 |
| 播放态推送 | `setAVPlaybackState()` —— 播放 / 暂停 / 跳转 / 快进 / 快退 |
| 支持的命令 | `play` `pause` `playNext` `playPrevious` `seek` `fastForward` `rewind` |
| 桌面歌词探测 | `avSession.isDesktopLyricSupported()` |

> **AVSession 在 ArkTS 壳层创建，而不是 NDK 层。** 上游的 Rust 音频模块在 C++ 里拿不到
> ArkTS 的 `Context`，因此媒体会话由 `EntryAbility.ets` 持有，再通过 ipc 把状态转给音频引擎。
> 锁屏页与状态栏胶囊（媒体实况窗）由此点亮。

### 2. 后台播放保活

| 环节 | 配置 / 调用 |
| --- | --- |
| Ability 声明 | `backgroundModes: ["audioPlayback"]` |
| 权限 | `ohos.permission.KEEP_BACKGROUND_RUNNING` |
| 长时任务 | `backgroundTaskManager.startBackgroundRunning()` |

> **踩过的坑**：官方指引只说「声明 `backgroundModes` + 接入 AVSession」，
> 实测**不足以**唤起系统媒体实况窗。必须再申请 `audioPlayback` 类型的长时任务，
> 让进程退到后台后继续存活，实况窗才会出现。
> 另：API 23 下 `setBackgroundPlayMode()` 不可用（会被拒），已移除；回到 API 26 工具链可恢复。

### 3. 设备类型必须包含 `phone`（关键）

`module.json5` 的 `deviceTypes` 写的是 `["phone", "tablet", "2in1"]`，**`phone` 不能删**。
只声明 `["2in1", "tablet"]` 时：

1. 系统把本应用判定为「PC 端应用」；
2. 窗口被归入 PC 应用窗口容器；
3. 回桌面时**只最小化窗口，不产生 ability 退后台**；
4. 媒体实况窗因此始终不显示。

### 4. 沉浸式窗口与系统栏

| 能力 | 实现 |
| --- | --- |
| 隐藏系统栏 | `setSpecificSystemBarEnabled('statusBar' / 'navigationBar', false)` |
| 避让区读取 | `getWindowAvoidArea()` |
| 自绘标题栏 | `setWindowDecorVisible(false)` |
| 右上角窗口三键 | `setWindowTitleButtonVisible(max, min, close)` |
| 首帧尺寸 | `setDefaultBounds()` |

> **★ 隐藏系统栏 ≠ 避让区归零。** 这点很反直觉：系统栏隐藏后 `getWindowAvoidArea()`
> 仍返回非 0 高度（沉浸式语义），首帧若仍按避让区裁剪，顶部就会留一条空白。
> 本项目让首帧 `setDefaultBounds` 不再按避让裁剪。

> **★ 早期的「伪沉浸」方案已整体下线。** 最初为了做「按窗口像素取色」（跟随封面主色染系统栏），
> 用了 `window.snapshot()` 逐帧取色。实测 3120×2080 全窗口位图分配 + GPU 回读达 24.8 MB/次，
> 单次分析 1.25 ms、但整轮要十几~几十 ms，且**静止时仍在 400 ms 一拍持续截屏** —— 功耗不可接受。
> 相关实现共 477 行已全部删除，改为直接隐藏系统栏。

### 5. 自由窗口形态约束

用 `module.json5` 声明式限制自由窗口（悬浮窗 / 全景多窗 / 分屏）能被拖成多大：

| 字段 | 本项目取值 | 作用 |
| --- | --- | --- |
| `minWindowWidth` | `640` vp | 最小宽度 |
| `minWindowHeight` | `400` vp | 最小高度 |
| `minWindowRatio` | `1.0` | 宽 ÷ 高下限，不允许出现「高于宽」的竖条 |
| `maxWindowRatio` | `2.5` | 宽 ÷ 高上限，挡住最扁的极端形状 |

> **为什么要限**：本应用是 WebView 壳，页面按窗口宽度做响应式排布。窗口被拖成极窄高或
> 极扁宽的条状时，侧边栏被挤扁、内容溢出。生效优先级为
> `setWindowLimits()` > `StartOptions` > `module.json5` > 系统默认（取交集）。
> **调参入口就在 `module.json5`，改完重编即可，不用动代码。**
> 若平板左右分屏被限制（横屏对半比例约 0.75，低于下限 1.0），把 `minWindowRatio` 调到 0.7~0.75 即可。

### 6. 系统窗口三键

上游是自绘标题栏。鸿蒙在自由多窗模式下会在标题栏之上**额外叠一层系统三键**（最小化 / 最大化 / 关闭）。
`setWindowDecorVisible(false)` **只隐藏标题栏本体，不关三键** —— 三键需要
`setWindowTitleButtonVisible()` 单独控制。本项目通过 `PAD_HIDE_SYSTEM_CAPTION_BUTTONS`
开关，在窗口形态变化时重压一次策略。

### 7. 多进程与渲染容器

| 能力 | 实现 |
| --- | --- |
| 子进程管理 | `childProcessManager`（`CustomChildProcess.ets` / `WebChildProcess.ets`） |
| 独立进程 | `process: ':browser'`（`BrowserAbility` / `StatelessAbility`） |
| 渲染容器 | ArkWeb `@kit.ArkWeb`（`WebviewController`） |
| 前后台桥 | `window.electron.ipcRenderer` ← ArkTS Adapter ← `jsbindings/*Bind.ets` |

### 8. 状态栏扩展

`StatusBarEntryAbility`（`type: "statusBarView"`）+ `@kit.StatusBarExtensionKit`，
承载系统状态栏上的扩展视图。

### 9. 系统能力适配器矩阵

`web_engine/src/main/ets/adapter/` 下共 **45 个 Adapter**，配 **44 个 jsbinding 桥**，
把 Electron / Node 的能力翻译到鸿蒙系统 API：

| 类别 | Adapter |
| --- | --- |
| 窗口 | `AppWindowAdapter` `SubWindowAdapter` `PopupWindowAdapter` `SystemFloatingWindowAdapter` |
| 媒体 / 通知 | `MediaAdapter` `NotificationAdapter` `StatusBarManager` |
| 输入 | `CursorAdapter` `MultiInputAdapter` `DragDropAdapter` `IMFAdapter` `FontAdapter` |
| 设备 / 上下文 | `DeviceAdapter` `DeviceInfoAdapter` `ContextAdapter` `ContextPathAdapter` `ElectronAppAdapter` `AppLifecycleAdapter` |
| 文件 | `FilePickerAdapter` `FileManagerAdapter` `DialogAdapter` `ExternalProtocolAdapter` |
| 权限 / 证书 | `PermissionManagerAdapter` `CertManagerAdapter` `DeviceUserAuthAdapter` |
| 分享 / 剪贴板 | `ShareAdapter` `PasteBoardApadter` |
| 显示 / 主题 | `DisplayAdapter` `NativeThemeAdapter` |
| 网络设备 | `BluetoothAdapter` `BluetoothLowEnergyAdapter` `PrintAdapter` |
| 其它 | `RunningLockAdapter` `ScreenshotAdapter` `SpeechAdapter` `ShapeDetectionAdapter` `WebAppAdapter` `AccessibilityAdapter` `BrowserPolicyAdapter` `AutoUpdaterAdapter` `MimeTypeAdapter` `ProcessAdapter` `EtsBridgeAdapter` `DefaultApplicationAdapter` |

### 10. C++ NAPI 桥与 Rust 原生模块

| 产物 | 大小 | 说明 |
| --- | --- | --- |
| `libelectron.so` | 159 MB | Electron 鸿蒙化运行时（内含 Chromium 132.0.6834.161） |
| `libffmpeg.so` | 2.1 MB | 音频解码 |
| `libadapter.so` | 5.3 MB | ArkTS ↔ Native 双向桥 |
| `libc++_shared.so` | 1.2 MB | C++ 运行库 |
| `echo-audio-player.node` | 7.4 MB | 播放 / 解码 / 音效处理（FFmpeg + SoundTouch） |
| `echo-audio-capture.node` | 1.4 MB | 系统音频与麦克风采集 |
| `echo-media-controls.node` | 1.2 MB | 系统媒体控制 |
| `echo-sqlite-store.node` | 2.8 MB | SQLite 持久化 |

> 上游的 4 个 Rust napi 模块源码**未修改**，仅用鸿蒙交叉工具链重新编译为 `arm64-v8a`。

### 11. 日志

全工程统一 `LogUtil.<level>(TAG, …)` 封装 `hilog`，共 **787 处** `LogUtil.*` 调用
（另有 78 处 `hilog.*` 直调，集中在壳层），`console.*` 直调已清零。

---

## 🛠️ 技术栈

### 鸿蒙侧（本仓库的适配层）

| 层次 | 技术 |
| --- | --- |
| 应用框架 | HarmonyOS **ArkTS** / ArkUI 声明式 |
| SDK | **API 23（6.1.0）**（上游原为 API 26） |
| 构建 | **DevEco Studio 6.1.0** + hvigor + ohpm |
| 运行时 | **Electron 鸿蒙化运行时**（`libelectron.so`，内含 **Chromium 132**） |
| 渲染容器 | **ArkWeb** `@kit.ArkWeb` |
| 媒体框架 | `@kit.AVSessionKit` `@kit.BackgroundTasksKit` `@kit.DeskTopExtensionKit` |
| 窗口 / 生命周期 | `@kit.AbilityKit` `@kit.WindowKit` `@kit.BasicServicesKit` |
| 状态栏扩展 | `@kit.StatusBarExtensionKit` |
| 数据 | `@kit.ArkData`（preferences / KVStore）+ SQLite（`echo-sqlite-store.node`） |
| 原生桥 | **C++ NAPI**（`libadapter.so`） |
| 原生模块 | **Rust + napi-rs**，arm64-v8a 交叉编译 ×4 |
| 多进程 | `childProcessManager` |
| 日志 | `hilog`（`LogUtil` 统一封装） |
| 目标架构 | **arm64-v8a**（唯一） |

### 上游侧（原样运行在容器内，未改）

| 层次 | 技术 |
| --- | --- |
| 桌面壳 | **Electron 43.7.0** API |
| 前端框架 | **Vue 3.5** + **TypeScript 5.9** |
| 构建工具 | **Vite 8** + esbuild |
| UI | **Tailwind CSS 4.3** + **Reka UI 2.9** + Iconify(Tabler) + VueUse |
| 状态管理 | **Pinia 3** + yzs-keep-alive-v3 |
| 路由 | **vue-router 4** |
| 本地服务 | **Node.js + Express**（`resfile/resources/server`，含 pnpm 依赖树） |
| 音频引擎 | **FFmpeg** 解码 + **SoundTouch** 变速（`libffmpeg.so`） |
| 原生扩展 | **Rust + napi-rs** ×4（`echo-audio-player` / `echo-audio-capture` / `echo-media-controls` / `echo-sqlite-store`） |
| 其它 | music-metadata、electron-log、electron-updater、font-list |

---

## 📁 目录结构

```
.
├── AppScope/                          应用级配置与图标（bundleName / versionName）
├── electron/                          entry 模块
│   ├── libs/arm64-v8a/                ★ 8 个原生库（180 MB，内置勿删）
│   └── src/main/
│       ├── ets/                       18 个 ArkTS 文件
│       │   ├── entryability/          EntryAbility（AVSession 在此）/ StatusBar / Browser / TaskManager
│       │   ├── pages/                 Index / WebPage / 子窗口 / 状态栏页
│       │   └── process/               CustomChildProcess
│       ├── module.json5               设备类型、权限、窗口模式与比例限制
│       └── resources/                 字符串 / 颜色 / 页面路由
├── web_engine/                        Electron 鸿蒙化运行时
│   └── src/main/
│       ├── ets/                       135 个 ArkTS 文件
│       │   ├── ability/               WebBaseAbility / WebAbility / Continue / Embedded
│       │   ├── adapter/               ★ 45 个系统能力 Adapter
│       │   ├── jsbindings/            44 个 ipc 桥接 Bind
│       │   ├── components/            WebWindow / 子窗口 / 浮窗 / NodeHandle
│       │   └── common/ utils/         常量、KVStore、LogUtil
│       ├── cpp/types/libadapter/      NAPI 桥的类型定义
│       └── resources/resfile/         ★ 上游 Electron 载荷（内置勿删）
│           ├── resources/app/         主进程 bundle + 前端 dist + node_modules
│           ├── resources/server/      本地 Node 服务
│           └── locales/               Chromium 语言包
├── docs/                              Electron 鸿蒙化参考文档（zip / pdf）
├── README.md                          本文件（GitHub 首页）
├── NOTICE.md                          GPLv3 §5(a) 衍生与修改声明
└── README-编译说明.md                  详细编译说明与逐轮改动记录
```

---

## 🚀 环境要求与编译

| 项目 | 要求 |
| --- | --- |
| DevEco Studio | **HarmonyOS 6.1.0**（带 API 23 SDK） |
| SDK 版本 | `compatibleSdkVersion` = `targetSdkVersion` = `6.1.0(23)` |
| 设备类型 | `phone` / `tablet` / `2in1`（**必须含 `phone`**，见上文第 3 节） |
| 目标架构 | **arm64-v8a**（仅此一个） |
| 网络 | 首次 Sync 会执行 `ohpm install`；`oh_modules` 未随仓库提供 |

```bash
# 1) 先配好自己的签名（必做）
#    DevEco → File → Project Structure → Project → Signing Configs
#    勾选 Automatically generate signature（需登录华为账号）
#    本仓库不含任何证书文件，build-profile.json5 中的 signingConfigs 需替换为本地值

# 2) 工程根目录执行
ohpm install
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`electron/build/default/outputs/default/electron-default-signed.hap`

详细步骤、易踩的坑、离线编译说明见 [`README-编译说明.md`](README-编译说明.md)。

### 仓库内已内置、**千万不要删**的两块资产

1. **`electron/libs/arm64-v8a/`（180 MB）** —— 用鸿蒙交叉工具链编出的 8 个原生库。
   目标机上没有对应工具链，**删了补不回来**。
2. **`web_engine/src/main/resources/resfile/`** —— 上游 Electron 载荷
   （主进程 bundle + 前端 `dist` + 本地 Node 服务 + Chromium 语言包）。
   不需要在目标机上重跑前端或 Rust 构建。

> ⚠️ **`libelectron.so` 单文件 166 MB，超过 GitHub 单文件 100 MB 硬上限。**
> 若要把本项目完整推送到 GitHub，这块必须走 **Git LFS**，或按 `.gitignore` 排除后用
> Release 附件 / 网盘提供。**直接 `git push` 会被服务端拒绝。**

---

## ⚠️ 已知限制

- 只在 **arm64-v8a** 上验证；未做 x86_64 产物。
- 上游的平台独占能力在鸿蒙上不可用：系统托盘、全局快捷键、开机自启、桌面歌词窗。
- 部分上游能力（听歌识曲、音乐云盘、插件系统、音效引擎等）在鸿蒙侧的完整可用性**尚未逐项验收**。
- `supportWindowMode` 含 `floating`：恢复悬浮窗后，若验收时发现媒体实况窗不再出现，
  用 `module.json5.bak-nosplit` 回退（取舍说明见编译说明「六、易踩的坑」）。
- 上游的自动更新（`AutoUpdater`）在鸿蒙上不适用。

---

## 📄 免责声明

上游声明同样适用于本移植版，且本移植版**未对上游的任何数据获取行为做修改**：

- 本项目是基于公开 API 接口开发的第三方音乐客户端，**仅供个人学习和技术研究使用**。
- 所有音乐数据通过公开接口获取，本项目**不存储、不传播任何音频文件**。
- 音乐内容版权归原平台及版权方所有，请尊重知识产权、支持正版音乐。
- **禁止将本项目用于任何商业用途或违法行为。**
- 因使用本项目产生的任何法律纠纷或损失，均由使用者自行承担。
- 如版权方认为本项目侵犯其权益，请通过 Issues 联系，我们将积极配合处理。
- **本项目不接受任何商业合作、广告或捐赠。**

## ⚖️ 开源协议

本项目以 **[GNU General Public License v3.0](LICENSE)** 发布 —— 与上游 [hoowhoami/EchoMusic](https://github.com/hoowhoami/EchoMusic) 保持一致。

- 衍生关系、修改范围与版权归属说明：见 [`NOTICE.md`](NOTICE.md)
- 上游第三方组件与授权说明：见上游仓库的 `THIRD_PARTY_NOTICES.md`
- 按 GPLv3 要求，**二次分发本项目的二进制包时，须同时提供完整对应源码、本协议全文与衍生说明**。

## 🙏 致谢

- **[hoowhoami/EchoMusic](https://github.com/hoowhoami/EchoMusic)** —— 本项目的全部上游来源，感谢作者的开源工作。
- 上游所引用的开源项目：[KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)、
  [SPlayer](https://github.com/imsyy/SPlayer)、[ffmpeg-audio](https://github.com/apoint123/ffmpeg-audio)、
  [soundtouch-rs](https://github.com/apoint123/soundtouch-rs)、
  [MoeKoeMusic](https://github.com/MoeKoeMusic/MoeKoeMusic)。
- Electron 鸿蒙化运行时来自华为 OpenHarmony / Electron 适配工程。
