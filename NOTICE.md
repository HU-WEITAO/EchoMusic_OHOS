# NOTICE · 衍生关系与修改声明

本文件依据 **GNU GPL v3.0 第 5(a) 条**（修改版本须带有显著的修改声明与修改日期）编写，
说明本仓库与上游项目的关系、修改范围与版权归属。

---

## 一、上游来源

| 项目 | 内容 |
| --- | --- |
| 项目名 | **EchoMusic** —— 一个简约的第三方酷狗概念版音乐播放器 |
| 仓库 | <https://github.com/hoowhoami/EchoMusic> |
| 作者 | [@hoowhoami](https://github.com/hoowhoami) |
| 协议 | GNU General Public License v3.0 |
| 著作权 | 归上游作者及各贡献者所有 |

## 二、本仓库性质

本仓库 **EchoMusic 鸿蒙版（EchoMusic for HarmonyOS）** 是上述上游项目的
**HarmonyOS（鸿蒙）平台移植版本**，属于 GPLv3 意义上的「基于该程序的作品」。

- 本仓库**不是原创项目**，不主张对上游代码的任何著作权。
- 播放器本体（界面、交互、插件体系、音效引擎、本地 Node 服务、数据接口）**均来自上游，未做功能性改写**。
- 本仓库的原创部分仅限于：**鸿蒙平台适配层、构建工程配置、以及为让上游代码在鸿蒙上正常运行而必须做的修改**。

## 三、修改声明

修改起始日期：**2026-09-19**（改动持续进行中，见提交历史与 `README-编译说明.md`）。

修改内容概述：

1. **新增鸿蒙工程**：`AppScope/`、`electron/`、`web_engine/` 三个目录及其 `build-profile.json5`、`module.json5`、
   `hvigorfile.ts` 等构建配置，构成一个可在 DevEco Studio 中直接编译的 HarmonyOS 应用工程。
2. **引入运行时**：`web_engine/` 模块承载 Electron 鸿蒙化运行时与 Chromium 载荷，
   `electron/src/main/resources/../../resfile/resources/` 内为**已构建完毕的上游 Electron 载荷
   （主进程 bundle、前端 `dist`、本地服务端）**，并打过 addon 路径补丁。
3. **重编原生模块**：上游 `native/` 下的 `echo-audio-player`、`echo-audio-capture`、`echo-media-controls`、
   `echo-sqlite-store` 四个 Rust napi 模块，使用鸿蒙交叉编译工具链重新编译为 **arm64-v8a** 产物，
   存放于 `electron/libs/arm64-v8a/`。**上游 Rust 源码本身未修改。**
4. **SDK 版本**：由上游要求的 API 26（HarmonyOS 26.0.0）降至 **API 23（6.1.0(23)）**，
   并相应调整了少量 ArkTS 写法以通过 API 23 的编译检查。
5. **平台适配与缺陷修复**：启动流程、窗口抖动、沉浸式系统栏、自由窗口尺寸与比例限制、
   系统窗口三键隐藏、后台播放与媒体实况窗等，详见 `README-编译说明.md` 第 8 ~ 18 节。
6. **移除内容**：上游的桌面平台打包配置（electron-builder）、CI 工作流、macOS / Windows / Linux
   专项代码路径不适用于鸿蒙，本仓库未包含或未启用。

> 未在本文件中逐文件列出全部改动。完整改动清单请对照上游对应版本与 `README-编译说明.md`。

## 四、协议继承

依照 GPLv3 的传染性条款，本移植版**同样以 GNU General Public License v3.0 发布**，
完整协议全文见仓库根目录 [`LICENSE`](LICENSE)。

分发本项目的二进制包时，**必须同时提供**：

1. 完整的对应源码（含本节所述的修改）；
2. GPLv3 协议全文；
3. 本衍生与修改声明。

## 五、第三方组件

本移植版未引入上游之外的第三方组件。上游所打包的第三方组件（FFmpeg、soundtouch-rs、Electron、
Vue、Vite、napi-rs、cpal、rubato、rusqlite/SQLite 等）及其授权说明，
见上游仓库的 [`THIRD_PARTY_NOTICES.md`](https://github.com/hoowhoami/EchoMusic/blob/main/THIRD_PARTY_NOTICES.md)。

其中需特别注意：

- `ffmpeg-audio` 与 FFmpeg 相关组件为 **GPL / LGPL** 授权，这是上游整体采用 GPLv3 的原因。
- 分发二进制时须保留 `LICENSES/LGPL-2.1.txt` 等上游要求的许可文本。

## 六、免责声明

本移植版完整继承上游的免责声明：

- 本项目是基于公开 API 接口开发的第三方音乐客户端，**仅供个人学习和技术研究使用**。
- 所有音乐数据通过公开接口获取，本项目**不存储、不传播任何音频文件**。
- 音乐内容版权归原平台及版权方所有，请尊重知识产权、支持正版音乐。
- **禁止用于任何商业用途或违法行为**，因使用本项目产生的法律纠纷或损失由使用者自行承担。
- **本项目不接受任何商业合作、广告或捐赠。**
