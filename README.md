# EchoMusic 鸿蒙版 · EchoMusic for HarmonyOS

<p align="center">
  <img src="AppScope/resources/base/media/app_icon.png" width="128" height="128" alt="EchoMusic Logo">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-HarmonyOS-brightgreen" alt="Platform">
  <img src="https://img.shields.io/badge/Arch-arm64--v8a-blue" alt="Architecture">
  <img src="https://img.shields.io/badge/Electron-43.4.1-blue?logo=electron" alt="Electron">
  <img src="https://img.shields.io/badge/Runtime-ArkTS%20%2B%20Node.js-orange" alt="Runtime">
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
>
> **播放器本体（界面、交互、插件体系、音效引擎、本地服务、数据接口）全部来自上游项目**，
> 本项目只做一件事：**把上游这个桌面端 Electron 应用，原样搬到鸿蒙设备上跑起来**，
> 并针对鸿蒙的窗口模型、系统栏、后台播放与 SDK 版本做了必要的适配与修复。
>
> 上游代码若在别处更新，本移植版不会自动同步；两边是**独立演进的仓库**，
> 上游的问题请不要提到本仓库，本仓库的适配问题也不要提给上游。
>
> 本移植版同样以 **GPL-3.0** 发布，衍生关系与改动说明见 [`NOTICE.md`](NOTICE.md)。

---

## 这是什么

EchoMusic 上游是一个 **Electron 桌面应用**：Electron 主进程 + Vue 3 渲染层 + Rust 写的 napi 原生扩展。

本项目把这套东西搬到了鸿蒙上，落地形态是：

```
HarmonyOS 应用（DevEco 工程，ArkTS）
        │
        ├── electron            entry 模块：应用入口、窗口、Ability、页面
        │
        └── web_engine          运行时模块：Electron/Chromium 鸿蒙化运行时
                └── resources/  上游 Electron 载荷（主进程 bundle + 前端 dist + 本地服务）
```

也就是说：**鸿蒙侧提供的是一个「Electron 容器」**，上游原本跑在 macOS / Windows / Linux 上的那套
前端与服务端代码，被原封不动地跑在这个容器里；需要落地的原生能力（音频播放、采集、媒体控制、
SQLite 存储）则由**用鸿蒙交叉编译工具链重新编译过的 napi 模块**提供。

## 上游功能

以下能力均沿用上游实现，本移植版不做删改（部分能力在鸿蒙上尚未验证，见「已知限制」）：

- **播放**：播放队列、播放模式、音量、进度拖动、倍速、淡入淡出切歌
- **内容**：歌曲 / 歌单 / 歌手 / 专辑 / 排行榜推荐，歌曲 / 歌手 / 专辑 / 歌单 / 歌词 / MV 搜索
- **歌词**：LRC / YRC 逐字歌词、翻译、正则过滤、滚动同步、全屏歌词、写真模式
- **第三方歌单导入**：网易云、QQ 音乐、酷我、酷狗、汽水、Spotify、Apple Music
- **音效**：10 段均衡器、LUFS 响度标准化、WAV / IRS 空间音效，支持导入兼容音效引擎
- **实时频谱**：直接从播放引擎取音频做 FFT，供插件消费
- **系统媒体控制**：在鸿蒙上接到 **AVSession + 媒体实况窗**（锁屏 / 状态栏胶囊）
- **插件系统**：在线插件源浏览安装 + 本地插件加载，可扩展页面、侧边栏、设置项、播放器按钮、右键菜单
- **其它**：私人 FM、音乐云盘、听歌识曲、歌曲评论、歌曲详情、分享、持久化

## 相对上游，鸿蒙侧做了什么

上游代码基本原样保留，改动集中在「鸿蒙跑不起来 / 跑起来不对」的地方：

| 方向 | 做的事 |
| --- | --- |
| **运行时** | 引入 Electron 鸿蒙化运行时模块（`web_engine`），承载上游 Electron 载荷 |
| **原生模块** | `echo-audio-player` / `echo-audio-capture` / `echo-media-controls` / `echo-sqlite-store` 四个 Rust napi 模块用**鸿蒙交叉工具链重编为 arm64-v8a**（本仓库内已内置产物） |
| **SDK 降级** | 上游工程按 API 26 出，本副本降至 **API 23（6.1.0(23)）** 并在 DevEco 6.1.0 上验证通过；过程中改掉了若干 API 23 不接受的 ArkTS 写法 |
| **启动流程** | 修复启动阶段的窗口异常（两个窗口来回切换、首帧尺寸按避让区裁剪等） |
| **窗口抖动** | 定位到「窗口以 20Hz 被反复 隐藏→显示」的根因（上位调用方在上游主进程 JS 里），在 ArkTS 边界丢弃冗余 show / hide |
| **沉浸式系统栏** | 平板下直接隐藏小横条与状态栏。**早期实现是「按窗口像素取色」的伪沉浸方案，因 `window.snapshot()` 的开销与耗电问题已整体下线**（相关代码 477 行已删除） |
| **窗口形态约束** | 用 `module.json5` 声明式限制自由窗口尺寸与**宽高比**（`minWindowWidth` / `minWindowHeight` / `minWindowRatio` / `maxWindowRatio`），避免窗口被拖成极端比例导致响应式布局错位 |
| **系统窗口三键** | 上游是自绘标题栏，鸿蒙在自由多窗模式下会额外叠一层系统三键，现已通过策略隐藏 |
| **后台播放** | 声明 `backgroundModes: ["audioPlayback"]` + `KEEP_BACKGROUND_RUNNING` 权限，让 AVSession 实况窗能正常出现 |
| **日志规范** | 全工程统一 `LogUtil`，清除全部 `console.*` 直调 |

> 每一轮改动的原因、改法、验收入口和回退方式，都记在 [`README-编译说明.md`](README-编译说明.md) 里（含每轮的备份文件名）。

## 目录结构

```
.
├── AppScope/                     应用级配置与图标（bundleName / 版本号）
├── electron/                     entry 模块
│   ├── libs/arm64-v8a/           ★ 原生库（内置，勿删）
│   └── src/main/
│       ├── ets/                  Ability、窗口、页面（ArkTS）
│       ├── module.json5          设备类型、权限、窗口模式与比例限制
│       └── resources/            字符串 / 颜色 / 页面路由
├── web_engine/                   运行时模块：Electron 鸿蒙化 + Chromium 载荷
│   ├── src/main/ets/             Ability 基类、各类系统能力 Adapter
│   ├── src/main/cpp/             libadapter.so 的 C++ 源码
│   └── src/main/resources/
│       └── resfile/              ★ Electron 载荷（内置，勿删）
├── docs/                         Electron 鸿蒙化参考文档
├── README.md                     本文件（GitHub 首页）
└── README-编译说明.md             详细编译说明与逐轮改动记录
```

## 环境要求

| 项目 | 要求 |
| --- | --- |
| DevEco Studio | **HarmonyOS 6.1.0**（带 API 23 SDK） |
| SDK 版本 | `compatibleSdkVersion` = `targetSdkVersion` = `6.1.0(23)`，`modelVersion` = `6.1.0` |
| 设备类型 | `phone` / `tablet` / `2in1`（**必须包含 phone**，否则媒体实况窗不显示） |
| 目标架构 | **arm64-v8a**（仅此一个） |
| 网络 | 首次 Sync 会执行 `ohpm install`；`oh_modules` 未随仓库提供，需联网 |

> 上游工程原本要求 API 26（HarmonyOS 26.0.0），本项目为便于在 6.1.0 工具链上构建已降至 API 23。

## 编译

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

1. **`electron/libs/arm64-v8a/`（约 187 MB）** —— 用鸿蒙交叉工具链从上游 Rust/C++ 源码编出来的原生库
   （`libelectron.so` / `libffmpeg.so` / `libadapter.so` / 四个 `echo-*.node`）。
   目标机上没有对应工具链，**删了补不回来**。
2. **`web_engine/src/main/resources/resfile/resources/`** —— 上游 Electron 载荷
   （主进程 bundle + 前端 `dist` + 本地 Node 服务端，已打好 addon 路径补丁）。
   同样不需要在目标机上重跑前端或 Rust 构建。

> ⚠️ **`libelectron.so` 单文件 159 MB，超过 GitHub 单文件 100 MB 的硬上限。**
> 若要把本项目完整推送到 GitHub，这块必须走 **Git LFS**，或按 `.gitignore` 排除后用
> Release 附件 / 网盘提供。**直接 `git push` 会被服务端拒绝。**

## 已知限制

- 只在 **arm64-v8a** 上验证；未做 x86_64 产物。
- 部分上游能力（听歌识曲、音乐云盘、插件系统、音效引擎等）在鸿蒙侧的完整可用性**尚未逐项验收**。
- `supportWindowMode` 含 `floating` 时，窗口形态正常但媒体实况窗需实机复核；取舍说明见编译说明「六、易踩的坑」。
- 上游的自动更新（`AutoUpdater`）在鸿蒙上不适用。
- 上游的 macOS / Windows / Linux 平台独占能力（系统托盘、全局快捷键、桌面歌词窗等）在鸿蒙上不可用。

## 免责声明

上游声明同样适用于本移植版，且本移植版**未对上游的任何数据获取行为做修改**：

- 本项目是基于公开 API 接口开发的第三方音乐客户端，**仅供个人学习和技术研究使用**。
- 所有音乐数据通过公开接口获取，本项目**不存储、不传播任何音频文件**。
- 音乐内容版权归原平台及版权方所有，请尊重知识产权、支持正版音乐。
- **禁止将本项目用于任何商业用途或违法行为。**
- 因使用本项目产生的任何法律纠纷或损失，均由使用者自行承担。
- 如版权方认为本项目侵犯其权益，请通过 Issues 联系，我们将积极配合处理。
- **本项目不接受任何商业合作、广告或捐赠。**

## 开源协议

本项目以 **[GNU General Public License v3.0](LICENSE)** 发布 —— 与上游 [hoowhoami/EchoMusic](https://github.com/hoowhoami/EchoMusic) 保持一致。

- 衍生关系、修改范围与版权归属说明：见 [`NOTICE.md`](NOTICE.md)
- 上游第三方组件与授权说明：见上游仓库的 `THIRD_PARTY_NOTICES.md`
- 按 GPLv3 要求，**二次分发本项目的二进制包时，须同时提供完整对应源码、本协议全文与衍生说明**。

## 致谢

- **[hoowhoami/EchoMusic](https://github.com/hoowhoami/EchoMusic)** —— 本项目的全部上游来源，感谢作者的开源工作。
- 上游所引用的开源项目：[KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi)、
  [SPlayer](https://github.com/imsyy/SPlayer)、[ffmpeg-audio](https://github.com/apoint123/ffmpeg-audio)、
  [soundtouch-rs](https://github.com/apoint123/soundtouch-rs)、
  [MoeKoeMusic](https://github.com/MoeKoeMusic/MoeKoeMusic)。
- Electron 鸿蒙化运行时来自华为 OpenHarmony / Electron 适配工程。
