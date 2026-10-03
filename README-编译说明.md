# EchoMusic 鸿蒙版 · DevEco 工程（可直接编译）

这个文件夹**就是 DevEco Studio 的工程根目录**，直接 `File → Open` 打开本文件夹即可编译出 HAP。

---

## 一、拷到鸿蒙电脑上后，只做两件事

### 1. 配上自己的签名（必做，否则编译报错）

`build-profile.json5` 里原先的 `signingConfigs` 指向的是**原机器的绝对路径证书**：

```
C:\Users\47990\.ohos\config\default_ohos_hap_...=.p12 / .cer / .p7b
```

这些文件是 DevEco 在原机器上**用华为账号自动签名**时生成的，换台电脑必然不存在。
（**2026-09-19 更新**：该段连同 `products[0].signingConfig` 引用已一并删除，工程现已处于「未配置签名」状态，Sync 不会再因证书路径报错；原值完整保留在 `build-profile.json5.bak-sdk26.0.0`。）

在目标机的 DevEco 里改成自己的签名：

> `File → Project Structure → Project → Signing Configs` → 勾选 **Automatically generate signature**（需登录华为账号）

或者手动指定你自己申请好的 `.p12 / .cer / .p7b`。

### 2. 编译

DevEco 里直接：

> `Build → Build Hap(s)/APP(s) → Build Hap(s)`

命令行方式：

```bash
# 工程根目录下
ohpm install
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物路径：`electron/build/default/outputs/default/electron-default-signed.hap`

---

## 二、环境要求

| 项目 | 要求 |
| --- | --- |
| DevEco Studio | **原始要求**：带 HarmonyOS SDK API 26（HarmonyOS 26.0.0），在 `DS-261.23567.138.36.2600821` 上验证通过。<br>**当前副本**：已降至 API 23，详见文末「七、SDK 版本降级说明」 |
| SDK 版本 | **当前值**：`compatibleSdkVersion` = `targetSdkVersion` = `6.1.0(23)`，`modelVersion` = `6.1.0`（原均为 `26.0.0`） |
| 目标设备 | arm64-v8a（`electron/libs/arm64-v8a/`） |
| 网络 | 首次 Sync 会执行 `ohpm install`；已内置 `oh_modules`，离线也能编 |

---

## 三、已经内置、千万不要删的东西

这两块是**编译必需但目标机上无法重新生成**的资产，随工程一起打包好了：

### 1. 原生库 —— `electron/libs/arm64-v8a/`（约 187 MB）

```
echo-audio-capture.node      1.4 MB   音频采集
echo-audio-player.node       7.7 MB   音频播放
echo-media-controls.node     1.3 MB   媒体控制 / AVSession
echo-sqlite-store.node       3.0 MB   本地存储
libelectron.so             166.8 MB   Electron 运行时
libffmpeg.so                 2.2 MB   编解码
libadapter.so / libc++_shared.so
```

这些是在**本机用鸿蒙交叉编译工具链**从 EchoMusic 的 Rust/C++ 源码编出来的，目标机上没有对应工具链，删了补不回来。

### 2. Electron 载荷 —— `web_engine/src/main/resources/resfile/resources/`

```
app/      28 MB   Chromium/Electron 主进程 + 渲染层 dist（已打好 addon 绝对路径补丁）
native/  3.0 MB
server/   15 MB   Node 服务端
```

同理：前端 dist 和主进程 bundle 都已构建并打好补丁，**不需要**在目标机上重新跑前端或 Rust 构建。

---

## 四、相对源工程做了哪些清理

拷贝前我剔除了以下几类内容，让它可以干净地跨机编译：

| 已移除 | 原因 |
| --- | --- |
| `.hvigor`（目录联结点 → `/d/hvigor-work`） | 那是本机沙箱禁止写 `.hvigor` 时的绕行方案，指向不存在的路径，跨机后会变成断链。目标机上 hvigor 会自行创建 |
| `electron/build/`、`web_engine/build/` | 约 900 MB 的构建缓存/中间产物，与机器强绑定，DevEco 会重新生成 |
| `.idea/` | IDE 本地配置，含绝对路径 |
| `oh_modules/` 内的**符号链接** | ohpm 生成的是指向本机的**绝对路径**链接（`C:\Users\47990\...`），跨机必断。已改为解引用后的实体目录，所以本工程内**符号链接数为 0** |

保留 `docs/`（Electron 鸿蒙化参考文档）。

> 附带影响：`oh_modules` 的三个位置原本是指向 `.ohpm` 缓存和 `web_engine` 模块的链接，解引用后变成了实体拷
> 贝，因此 `electron/oh_modules/web_engine/` 是 `web_engine/` 模块的一份副本（约 60 MB 冗余）。
> 这是 ohpm 的 `file:` 依赖机制使然，不影响编译；目标机首次 Sync 时 ohpm 会自动把它还原成链接。

---

## 五、已验证

本副本已在隔离位置执行过一次**从零全量构建**（就是本文档第一节的流程）：

```
ohpm install                     → install completed
hvigorw assembleHap ...          → BUILD SUCCESSFUL in 47 s 698 ms
                                   41 tasks in total: 41 executed, 0 up-to-date
产物 electron-default-signed.hap → 246,400,213 字节
```

41 个任务全部实际执行（`0 up-to-date`），说明不是靠本地缓存蒙混过关——这份文件夹本身是自洽、可独立编译的，
不依赖 `echomusic-pkg/` 或 `ohos-port/` 下的任何其他内容。

---

## 六、易踩的坑

- **别拷错目录**：工作区里 `echomusic-ohos/ohos_hap` 是**陈旧副本**，不是这份。本文档所在目录才是当前版本。
- **首次 Sync 若报依赖错误**：删掉 `oh_modules`、`electron/oh_modules`、`web_engine/oh_modules` 三个目录，让 DevEco 重新 Sync 即可。
- **签名相关报错**（`code 9568289`、`signing config not found` 等）基本都指向第一节的签名未替换。
- `deviceTypes: ["phone","tablet","2in1"]`（**必须包含 phone**）是修复「媒体实况窗不显示」的关键配置，**请勿改回**。
- `supportWindowMode` 的取值需要在两个诉求间取舍（2026-09-19 调整）：
  - `["fullscreen","split"]`（不含 floating）→ 回桌面会触发窗口最小化路径，媒体实况窗容易正常出现；但 2in1/PC 上窗口**无法进入悬浮窗形态**，只能以全屏/最大化启动，且自绘标题栏的「最大化/还原」按钮两个方向都无效果（表现为失灵）。
  - `["fullscreen","split","floating"]`（**当前值**）→ 系统以自由窗口模式启动，窗口可缩放、「最大化/还原」按钮生效；代价是实况窗可能需要实机再验证。
  - 回退用 `electron/src/main/module.json5.bak-nosplit`。
- 注：本节原先引用的「同级的 V35 发布说明」在本目录并不存在（悬空引用），上述取舍依据以 `electron/src/main/module.json5` 内的注释为准。

---

## 七、SDK 版本降级说明（2026-09-19）

### 为什么降

在**鸿蒙电脑（HarmonyOS PC）**上打开工程时 Sync 直接失败：

```
Invalid value of compileSdkVersion, compatibleSdkVersion, or targetSdkVersion (if set).
Correct the value by following the instructions in the guide.
Sync cancelled
```

根因：工程声明 `26.0.0`（HarmonyOS 7 / API 26），而该机 IDE 为 **DevEco Studio 6.1.5 Preview**（鸿蒙电脑版预览版，基于 BitFun Platform 0.38.1-B661），**内置 SDK 最高只到 API 23**。

官方规则：`compileSdkVersion` 只能取「当前 DevEco Studio 自带的 SDK 版本」，`SDK 随 IDE 一起安装、无法单独安装`；三者需满足 `compatibleSdkVersion ≤ targetSdkVersion ≤ compileSdkVersion`。
**API 26 目前只有 Windows / macOS 版的 DevEco Studio 26.0.0 Release（26.0.0.821，2026-08-28）支持**，鸿蒙电脑版尚停在 6.1 预览版。

### 改了什么（共 4 处，缺一处就换一种报错）

| 文件 | 字段 | 原值 | 现值 |
| --- | --- | --- | --- |
| `build-profile.json5` | `compatibleSdkVersion` | `"26.0.0"` | `"6.1.0(23)"` |
| `build-profile.json5` | `targetSdkVersion` | `"26.0.0"` | `"6.1.0(23)"` |
| `oh-package.json5` | `modelVersion` | `"26.0.0"` | `"6.1.0"` |
| `hvigor/hvigor-config.json5` | `modelVersion` | `"26.0.0"` | `"6.1.0"` |

另：`compileSdkVersion` **保持不写**（缺省 = IDE 自带 SDK），这样必然满足三者的约束关系。
另：`signingConfigs` 连同 `products[0].signingConfig` 已删除（原值指向 `C:\Users\47990\...`，本机不存在）。

> 版本字符串格式差异：API 26 用语义化版本 `"26.0.0"`，API ≤ 24 用「主版本(API号)」的 `"6.1.0(23)"` 写法，**两种格式不能混用**。
> 若你的 IDE 自带 SDK 不是 API 23 而是 API 24，把四处对应改成 `"6.1.1(24)"` / `"6.1.1"`。
> 最准的取法：`File → New → Create Project` 建个空工程，照抄它生成的 `build-profile.json5`、`oh-package.json5`。

### 备份与回退

原始 26.0.0 配置已就地备份，**未删除**：

```
build-profile.json5.bak-sdk26.0.0
oh-package.json5.bak-sdk26.0.0
hvigor/hvigor-config.json5.bak-sdk26.0.0
README-编译说明.md.bak-sdk26.0.0
```

**回退（要出正式 API 26 包时）**：用上述 `.bak-sdk26.0.0` 覆盖回对应文件，然后在 Windows / macOS 上用 **DevEco Studio 26.0.0 Release** 打开本工程。
（工程里的 `libelectron.so` 等原生库是按 API 26 工具链预编译的产物，只有 API 26 工具链出的包才最稳妥。）

### 降级后在鸿蒙电脑上能编到什么程度

- 构建期**不需要重编 C++**：`web_engine/src/main/cpp` 下只有 `types/libadapter` 的声明文件，`libelectron.so`、`echo-*.node` 都是预编译产物直接打包 → **编译通过是有可能的**。
- 设备侧无碍：该机系统为 HarmonyOS 7.0.0.105（API 26），装低 target 的 HAP 没问题。
- 实际会撞上的风险已出现并已处理：ArkTS 代码里用到 API 24~26 独有接口会报「属性/接口不存在」。首轮 `CompileArkTS` 报了 9 个，全部在 `electron/src/main/ets/entryability/EntryAbility.ets`，**已改写为 API 23 的等价写法**（见下节）。

### 为通过 API 23 编译改过的 ArkTS 代码

| 原写法（API 26 才有） | 现写法（API 23 等价） |
| --- | --- |
| 项级 `StatusBarMenuItem.menuCode` | 改挂 `menuAction.menuCode`（与 `web_engine/.../adapter/StatusBarManager.ets` 一致） |
| `statusBarManager.updateStatusBarMenuItem(ctx, item)` | `statusBarManager.updateStatusBarMenu(ctx, menus, cb)`，整组菜单一次性下发 |
| `statusBarManager.isStatusBarCapabilitySupported(ctx)` 探针 | 直接 `addToStatusBar`，失败在错误回调里 2s×3 次重试 |
| `session.setBackgroundPlayMode(BackgroundPlayMode.ENABLE_BACKGROUND_PLAY)` | 移除。后台播放/媒体实况窗由 `module.json5` 的 `backgroundModes:["audioPlayback"]` + `KEEP_BACKGROUND_RUNNING` 长时任务保证；音频类型会话默认即 `ENABLE_BACKGROUND_PLAY` |

顺带的收益：`updateStatusBarMenu` 整组下发后，原先「播放/暂停」与「歌词开关」成对更新时第二发必被限流（1010710003）丢弃、导致**桌面歌词菜单标题不翻转**的老问题一并消失。

**备份**：`electron/src/main/ets/entryability/EntryAbility.ets.bak-api26`（未删，可整体回退）。
**回退方案**：回到 API 26 工具链后，用 `.bak-api26` 覆盖 `EntryAbility.ets` 即可恢复原始的 API 26 写法。

---

## 八、启动过程两个问题的修复（2026-09-19 第二轮）

### 现象

1. PC 模式打开：先是应用自己的启动动画（波形 + EchoMusic + “正在启动 EchoMusic...”），
   随后窗口再「跳」一下（换尺寸/位置）才稳定。
2. 平板模式打开：启动过程窗口异常抽动，且内容显示不正常（被状态栏压住 / 底边被小横条遮住）。

### 根因

| # | 根因 | 说明 |
| --- | --- | --- |
| A | **设备窗口模式同步得太晚** | `DeviceInfoAdapter.deviceMode` 初值是 `kPcMode`，唯一的同步入口 `registerDeviceModeChange` 原先只在 `WebAbility.onPadWindowStageCreate`（平板分支）里调用。于是**首扇窗口**走过的 `isNormalWindowMode()/isFreeWindowsMode()` 全是错的：平板下启动即误判为 PC 模式（先隐小横条、马上又显示 → 抽动；首帧不扣状态栏 → 内容错位）；2in1/PC 下永远判不出自由窗口模式 → 启动尺寸兜底失效。 |
| B | **启动动画期间的几何被后置** | 桌面冷启动时系统已按 `instanceKey`（见 `WebAbilityStage.onAcceptWant`）建好窗口，随后 Electron 主进程请求 `CreateWindow`，`startAbility` 命中已有实例 → `StartOptions` 里的 `windowLeft/Top/Width/Height` 被系统丢弃。窗口先以系统默认尺寸出现，等 Electron 侧再 `SetBounds` 才跳到目标尺寸 → 观感就是「启动动画之后窗口又跳一下」。 |
| C | **平板常规模式仍被应用层改几何** | `AppWindowAdapter.setBounds` 没有拦「平板常规（全屏）模式」，应用记住的尺寸会直接落到全屏窗口上 → 抽动 + 内容边界错位。 |
| D | **首帧内容边界用的是可能为 0 的避让值** | `WebNodeHandleWindow.setDefaultBounds` 读的是 LocalStorage 里的 `statusBarHeight/navIndicatorHeight`，而这两个值由 `onPadWindowStageCreate` 写入，页面 `aboutToAppear` 往往更早 → 首帧扣 0 → 内容错位。 |

> 顺带确认：**「启动动画」不是系统启动页，而是应用前端自带的 splash** ——
> `web_engine/src/main/resources/resfile/resources/app/dist/index.html` 里的
> `#startup-placeholder`（波形 + EchoMusic + 正在启动…），首帧即可绘制、不依赖脚本。
> 它属于前端产物，改它需要重新构建前端 dist，不在本次 ArkTS 侧改动范围内。

### 改了什么

| 文件 | 改动 | 备份 |
| --- | --- | --- |
| `web_engine/.../adapter/DeviceInfoAdapter.ets` | 新增 `initWindowMode(context)`（先同步模式、再补观察者，两者解耦）；新增 `isPcOrFreeWindowsMode()`；`updateDeviceMode` 加模式切换日志 | `.bak-before-devicemode-init` |
| `web_engine/.../ability/WebAbility.ets` | `onCreate` 里在开窗前调用 `initWindowMode`；`onPadWindowStageCreate` 把 `registerDeviceModeChange` 提到 `updateAvoidAreaStatus` 之前（避免小横条「先隐后显」互相打架） | `.bak-before-devicemode-init` |
| `web_engine/.../adapter/AppWindowAdapter.ets` | `clampLaunchBounds` → `clampNearlyFullScreen`（闸门由「是自由窗口模式」改成「不是平板常规模式」，PC 上才真正生效）；`setBounds` 增加平板常规模式直拦 + 整屏请求收敛；新增 `applyBoundsToExistingWindow`（show 之前把目标几何落到已有窗口）；`maximize` 的 `isPcMode()` 换成 `isPcOrFreeWindowsMode()` 保持 PC 行为不变 | `.bak-before-geom-guard` |
| `web_engine/.../components/WebNodeHandleWindow.ets` | `setDefaultBounds` 改为直接向窗口查避让区（不再依赖可能为 0 的 LocalStorage 值），并打印首帧边界日志 | `.bak-before-bound-fix` |

### 怎么验证（hilog 过滤建议）

```
hdc shell hilog | grep -E "DeviceInfoAdapter|AppWindow|WebNodeHandleWindow|WebAbility"
```

重点关注这几条：
- `device window mode -> kNormalWindowMode / kFreeWindowsMode`：启动早期就应该出现（证明 A 修好）。
- `[setBounds] ignored in tablet normal mode`：平板模式下应用层不再改窗口几何。
- `[launchBounds] pre-apply ... to existing window browser1`：PC 模式下几何提前落位。
- `[launchBounds] stale fullscreen size ...`：命中整屏兜底（PC 模式下打开不再铺满）。
- `setDefaultBounds statusBar=... navIndicator=...`：首帧避让值应该是真实高度而不是 0。

### 回退

四个 `.bak-before-*` 就近覆盖即可单独回退任一文件；四处互不依赖。

---

## 九、平板模式「启动极其抖动、页面点不动」修复（2026-09-19 11:50）

### 现象

鸿蒙**平板**（或支持多窗/电脑模式的设备）在**平板模式**下启动：过程极其抖动、页面点不动；
**模拟器下完全正常**。

### 根因

系统里有**两个互相独立**的窗口模式开关，之前的代码只看了一个：

| 开关 | 含义 | 谁在用 |
| --- | --- | --- |
| `isSystemModePc` | 系统是否处于「电脑模式」 | `WebAbility.onWindowStageCreate` 用它决定要不要走 `onPadWindowStageCreate`（沉浸避让那一整套） |
| `window_pcmode_switch_status` | 窗口是否按自由窗口渲染 | `DeviceInfoAdapter.getDeviceModeFromSystem` 用它算 `DeviceMode` |

支持多窗的平板上 `window_pcmode_switch_status` 可能是 `'true'`，于是应用把**一台平板**
判成了 `kFreeWindowsMode`。上一轮新增的三处「PC 专属几何干预」——开窗几何预落位、
整屏尺寸兜底、`setBounds` 整屏收敛——随即全部在平板上生效，和系统的全屏布局每帧互推：
**启动极其抖动、页面点不动**。模拟器没有这两个开关（默认常规模式），所以正常。

另外两层放大因素：

1. 几何干预的闸门当时写的是 `!isNormalWindowMode()`。`deviceMode` 未同步时的初值是
   `kPcMode`（既不是 free 也不是 normal），取反会**放行**，把平板的全屏请求误当成
   「残留的整屏尺寸」收敛成 72%。
2. 常规（全屏）模式下窗口由系统掌管，入场动画期间 `windowSizeChange` /
   `windowRectChange` 会**逐帧**触发，每一帧都把内容边界推给原生侧 → 原生侧跟着重排。

### 改动

| 文件 | 改动 |
| --- | --- |
| `DeviceInfoAdapter.ets` | `getDeviceModeFromSystem` 改为**先判 `isSystemModePc`**：`deviceType === 'tablet'` 且系统未开电脑模式 → 一律 `kNormalWindowMode`（与 `onWindowStageCreate` 触发 pad 分支的条件完全一致，保证「谁掌管窗口」和「走哪套避让」不会各说各话）。同时打印两个开关的原始值。 |
| `AppWindowAdapter.ets` | 几何干预闸门全部改成**正向判据** `isFreeWindowsMode()`（「模式未知 / 平板常规」一律不干预）；新增排查用总开关 `SAFE_LAUNCH_GEOMETRY`；`createWindow` 打印一条完整的几何决策日志。 |
| `WebAbility.ets` | 新增 `shouldDeferNormalBoundPush()` / `scheduleNormalBoundSettle()`：**常规（全屏）模式**下，窗口显示后 700ms 内的逐帧内容边界推送先压住，动画收尾后补推一次最终值；自由多窗/PC 模式行为完全不变。 |
| `WebNodeHandleWindow.ets` | 首帧的小横条高度改回读 LocalStorage（与 `pushPadContentBound` 同口径），不再额外查一次避让区；首帧日志打印 `windowRect/drawableRect/normalMode`。 |

### 排查用逃生舱

`web_engine/src/main/ets/adapter/AppWindowAdapter.ets` 顶部：

```ts
const SAFE_LAUNCH_GEOMETRY: boolean = false;   // 改成 true = 停用全部启动几何干预
```

改成 `true` 重新编译：窗口几何完全交回系统。若平板上不再抖动 → 抖动就来自那套干预；
若仍抖动 → 与它无关，按下面日志查内容边界那条线。

### 验收日志

```bash
hdc shell hilog | grep -E "DeviceInfoAdapter|AppWindow|WebNodeHandleWindow|WebAbility"
```

期望看到：

- `Get isSystemModePc value:false, deviceType:tablet` + `device window mode -> kNormalWindowMode`
  → 平板上不会再被误判成自由窗口模式。
- `[setBounds] ignored in tablet normal mode` → 应用层不再动平板窗口几何。
- `[launchBounds] ... freeWindowMode=false ... preApply=false` → 开窗不干预。
- `normal-mode bound settled push done` → 入场动画结束后补推过一次最终内容边界。
- `setDefaultBounds id=browser1 statusBar=.. navIndicator=.. normalMode=true windowRect=.. drawable=..`
  → 首帧避让值与窗口矩形（用来核对内容是否被错位/裁掉）。

### 回退

```
web_engine/src/main/ets/adapter/DeviceInfoAdapter.ets.bak-before-pad-jitter-fix
web_engine/src/main/ets/adapter/AppWindowAdapter.ets.bak-before-pad-jitter-fix
web_engine/src/main/ets/ability/WebAbility.ets.bak-before-pad-jitter-fix
web_engine/src/main/ets/components/WebNodeHandleWindow.ets.bak-before-pad-jitter-fix
```

四处互不依赖，可就近覆盖单独回退。改后已过括号配平自检（与备份的差值均为 0）。

---

## 十、启动「两个窗口切换」的消除（2026-09-19 12:05）

### 现象

点击桌面图标后，先出现一个**启动窗口界面**（系统启动页：底色 + 应用图标），这个页面消失的
同时主程序窗口出现，**两者大小位置不同** —— 观感像两个窗口在切换。

### 根因

冷启动其实只有**一扇窗口**，但它的矩形被两个来源先后设定：

| 阶段 | 谁在设矩形 | 用户看到的内容 |
| --- | --- | --- |
| ① 窗口创建 | **系统**（默认几何或系统已有记忆） | **系统启动页**（`startWindowIcon` + `startWindowBackground`），矩形 = G_sys |
| ② 前端起来后 | **Electron 主进程**（`createWindow` 的几何落位 + 后续 `SetBounds`） | 主程序界面，矩形 = G_app |

G_sys ≠ G_app 时，就表现为「启动页消失、主程序在另一个位置尺寸出现」。启动页底色
（`#FFFFFF` / `#101418`）与窗口首帧底色（`#F5F5F7` / `#26262A`）不同，又进一步放大了
「换了一屏」的感觉。

### 改动

| 文件 | 改动 |
| --- | --- |
| `web_engine/.../ability/WebBaseAbility.ets` | `onWindowStageCreate` 调用新增的 `enableWindowRectAutoSave()`：主窗（browser1）开启**系统主窗尺寸记忆**（API ≥ 17 用双参重载，≥ 14 用单参，更低版本跳过并记日志）。同处打印启动页阶段的窗口真实矩形（tag `[StartWin]`）。 |
| `web_engine/.../adapter/DeviceInfoAdapter.ets` | 新增 `markWindowRectAutoSave()` / `isWindowRectAutoSave()`，把「系统是否已在管主窗矩形」暴露给几何逻辑。 |
| `web_engine/.../adapter/AppWindowAdapter.ets` | 系统记忆生效时，开窗落位**不再移动主窗位置**（以系统记的用户上次摆放位置为准），尺寸仅在差异 > 2% 且 > 8px 时才对齐；唯一例外是「当前尺寸≈整屏」仍走 72% 收敛兜底。新增 `isNearlyFullScreenWindow()`。 |
| `electron/.../base/element/color.json`、`electron/.../dark/element/color.json` | `start_window_background`：`#FFFFFF` → `#F5F5F7`、`#101418` → `#26262A`，与窗口首帧底色对齐，启动页与主窗之间不再有颜色跳。 |

### 为什么选「系统尺寸记忆」

- 系统在**创建窗口那一刻**就用上次的矩形 → 启动页与主窗天然同框，切换从源头消失；
- 系统记忆规则还会顺手消化「平板全屏尺寸被带到 PC 模式」：自由窗口记住尺寸/位置，
  全屏、沉浸、最小化状态记住的都是**进入该状态前的自由窗口矩形**；
- 该 API 在非 2in1 / 非自由窗口状态下**不生效也不报错**，平板形态没有副作用。

### 验收

```bash
hdc shell hilog | grep -E "StartWin|launchBounds"
```

| 期望日志 | 说明 |
| --- | --- |
| `[StartWin] setWindowRectAutoSave(true, true) succeeded` | 尺寸记忆已开启 |
| `[StartWin] main window rect at stage-create: WxH@(x,y)` | 启动页阶段主窗的真实矩形 |
| `[launchBounds] ... requested=WxH@(x,y)` | **与上一行的矩形一致** → 启动页与主窗同框 |
| `[launchBounds] window browser1 already at WxH@(x,y) (system-remembered), skip pre-apply` | 应用不再挪动主窗 → 没有第二段几何 |

> **注意**：尺寸记忆是「关闭时保存、下次启动使用」，所以**第一次启动仍会看到一次切换**；
> 正常退出后再启动，才是这段修复的效果。

### 还嫌有过渡？把启动页整个关掉

如果希望「点图标 → 直接出主窗口、完全没有启动页」，在 `electron/src/main/module.json5`
的 EntryAbility 里加一行（API 20+，仅 PC/2in1 设备或平板自由多窗模式下生效）：

```json5
"startWindowType": "REQUIRED_HIDE",
```

代价：冷启动期间屏幕上没有任何反馈（几百 ms ~ 数秒），用户可能以为「点了没反应」。
**本工程默认不加**，先看尺寸记忆 + 底色统一的效果。

### 回退

```
web_engine/src/main/ets/ability/WebBaseAbility.ets.bak-before-startwin-merge
web_engine/src/main/ets/adapter/DeviceInfoAdapter.ets.bak-before-startwin-merge
web_engine/src/main/ets/adapter/AppWindowAdapter.ets.bak-before-startwin-merge
```

两个 `color.json` 的备份**不能放回 `resources/` 下**（原因见下），已统一移到工程外：

```
../EchoMusic_OHOS-backups/startwin-merge/color.base.json.bak-before-startwin-merge
../EchoMusic_OHOS-backups/startwin-merge/color.dark.json.bak-before-startwin-merge
```

覆盖时请改名回 `color.json` 再放回 `electron/src/main/resources/{base,dark}/element/`。

三处 ArkTS 改动互不依赖；两个 color.json 只是常量改值。改后已过括号配平自检
（与备份的差值均为 0）与 JSON 语法校验。

### ⚠️ 不要在 `resources/` 目录里放任何备份文件

`hvigor` 的资源编译阶段（`CompileResource` / `Resource Pack Error`，错误码 **11211117**）
会**整体扫描 `resources/` 下的所有文件**，不按扩展名过滤。把 `color.json.bak-xxx` 放在
`base/element/` 里，会被当成第二份资源清单，报：

```
Resource 'start_window_background' conflict. It is first declared at
'.../base/element/color.json' and declared again at
'.../base/element/color.json.bak-before-startwin-merge'
```

**约定**：备份一律写到工程**外**的 `../EchoMusic_OHOS-backups/<轮次>/`；
`ets/`、`src/main/module.json5` 等按固定文件名读取的位置，`.bak-*` 后缀安全。

---

## 十一、平板模式「频繁抖动、在屏幕上乱蹦」二轮定位（2026-09-19 12:20）

### 为什么第七轮的修复没解决

第七轮把「几何干预」的闸门改回正向判据 `isFreeWindowsMode()`，方向是对的，但**抖动的来源不止几何干预那一处**。
本轮先确认了一件事：**模拟器完全不进入平板沉浸分支**（`deviceInfo.deviceType === 'tablet' && isSystemModePc !== 'true'`
在模拟器上不成立），而真机平板会进入 —— 所以「模拟器正常、真机抖」这条线索直指
`onPadWindowStageCreate` 那条链路：它一边改系统栏（`setSpecificSystemBarEnabled`）和全屏布局
（`setWindowLayoutFullScreen`），一边把内容边界推给原生侧。

### 新的关键线索：下拉控制中心能「刹车」

用户补充：**下拉控制中心 / 通知中心可以立刻结束抖动**，且过程中播控中心仍能控制歌曲（说明应用进程本身是好的，
是窗口/布局层在自激）。**能被一个外部事件打断 + 频率极高，说明这是一个闭环**，而不是一次性错误。

### 本轮做的四件事

| # | 位置 | 改动 | 意图 |
| --- | --- | --- | --- |
| 1 | `WebBaseAbility.updateAvoidAreaStatus` | 加**防抖闸门**：500ms 内重复下发同一目标状态直接跳过（`AVOID_AREA_REAPPLY_GAP_MS`） | 每次调用都会让系统重走「系统栏可见性 → 避让区 → 窗口布局」。它是 `WINDOW_SHOWN` 分支的调用点，一旦「改系统栏 → 窗口重新显示 → WINDOW_SHOWN → 再改系统栏」闭环就是乱蹦。**刻意做成时间窗而不是永久幂等**：从后台回来时系统确实可能重置全屏布局，那时必须重新下发 |
| 2 | `WebAbility.requestPadContentBound`（新） | 内容边界推送**合并**（100ms 尾随）+ **去重**（状态栏高/小横条高/内容矩形四个值的指纹不变就不推） | 逐帧推送会让原生侧逐帧重排；指纹不变时这次推送没有任何信息量 |
| 3 | `WebAbility.avoidAreaChange` 处理器 | 避让高度**值**没变就不写 LocalStorage、不再转发 | 直接写 LocalStorage 会绕过第 2 条的合并，白白触发一轮 ArkUI 重排（顶部/底部色条高度变化 = 内容区域跳一下） |
| 4 | `WebAbility` 开窗处 | 平板常规模式下**不再主动**调 `setSpecificSystemBarEnabled('navigationIndicator', true)` | `updateAvoidAreaStatus` 在平板常规模式下本来就「不隐藏小横条」，这次「显示」是冗余的。**每一次系统栏调用都会触发一轮 避让区 → 窗口布局 重算**，是最可疑的一根火柴 |

另新增一个**纯诊断**工具：`web_engine/src/main/ets/utils/WindowEventWatch.ts`，tag 为 `JitterWatch`。
它按 1 秒窗口统计各来源的事件次数，只有总数 ≥ 30 才打 WARN（稳态不刷屏）。

### 两个开关（都在 `WebAbility.ets` 顶部）

```ts
const PAD_IMMERSIVE_SAFE_MODE: boolean = true;      // 上表 2/4 的安全策略；false = 回到改动前
const PAD_WINDOW_STAGE_DISABLED: boolean = false;   // 应急总闸：true = 完全跳过平板沉浸分支
```

`PAD_WINDOW_STAGE_DISABLED = true` 的效果是**让真机平板跑模拟器那条路径**（不做沉浸布局、不注册避让、
不推边界），代价是顶部/底部色条归 0、失去内容沉浸效果，布局交回系统。

### 验收（请务必抓一次日志）

平板启动、让它抖起来，**然后下拉控制中心把抖动止住**，抓这一段：

```bash
hdc shell hilog | grep -E "JitterWatch|WebAbility|AppWindow|DeviceInfoAdapter|WebNodeHandleWindow"
```

| 看什么 | 结论 |
| --- | --- |
| `[JitterWatch] N window events / 1000ms ... -> a=.. b=..` | **谁在狂飙谁就是闭环入口**。若是 `windowEvent=...` → 窗口在反复显示；`avoidAreaChange=...` → 避让区在反复变；`windowRectChange/windowSizeChange=...` → 窗口几何在反复变；`setBounds(blocked,pad)=...` → Electron 在空转请求；`pcmodeSwitchObserver=...` → 系统那个模式开关在反复通知 |
| `updateAvoidAreaStatus skipped (...)` 高频出现 | 确认第 1 条正中靶心 |
| `flushPadContentBound ... ` 与 `[padBound] unchanged, skip push` 的比例 | 前者应当很少；后者多说明第 2 条在有效拦重复推送 |

**如果还是抖**，按顺序做两步二分（每次改一个布尔值重编）：

1. `PAD_WINDOW_STAGE_DISABLED = true` → 不抖了 ⇒ 抖动 100% 在平板沉浸分支里，把 `JitterWatch` 那行日志发我；
   照样抖 ⇒ 与这条分支无关，别再往这个方向查。
2. `PAD_IMMERSIVE_SAFE_MODE = false` → 用来对照上表第 2/4 条各自的贡献。

### 回退

```
web_engine/src/main/ets/ability/WebBaseAbility.ets.bak-before-pad-jitter2
web_engine/src/main/ets/ability/WebAbility.ets.bak-before-pad-jitter2
web_engine/src/main/ets/adapter/AppWindowAdapter.ets.bak-before-pad-jitter2
web_engine/src/main/ets/adapter/DeviceInfoAdapter.ets.bak-before-pad-jitter-fix
```

（`utils/WindowEventWatch.ts` 是新增文件，删除即可；`WindowEventWatch.note(...)` 的调用点保留也不会报错 ——
但若连文件一起删，需同时删掉 4 个文件里的 `import` 与调用，故建议保留。）

改后已过括号配平自检（与备份的差值均为 0）。

---

## 十二、平板抖动：直接关掉沉浸分支做二分（2026-09-19 12:2x）

第十一轮（上一节）的四处置换 + 看门狗之后，用户反馈**还是抖动**。既然逐点减震没能压住，
本轮不再继续「减震」，而是**一次性把那整条分支关掉**，把问题一刀切成两半。

### 为什么直接关掉这条分支

把已知事实排一遍，指向非常集中：

| 事实 | 推论 |
| --- | --- |
| 模拟器上完全正常 | 抖动与「模拟器不走的那些代码」强相关 |
| 真机平板抖 | 真机比模拟器**只多走一条分支**：`WebAbility.onPadWindowStageCreate`（进入条件是 `deviceType === 'tablet' && isSystemModePc !== 'true'`，模拟器 `deviceType` 不是 tablet，永远进不去） |
| 抖动能被「下拉控制中心」立刻打断 | 是**闭环**（自激），不是一次性错误；外部事件一抢焦点/一叠一层就断链 |
| 抖动期间播控中心仍能控制歌曲 | 应用进程健康，出问题的是**窗口 / 布局层** |
| 上一轮做了合并、去重、值去重、防抖，仍抖 | 说明这几处置换**没有命中闭环的关键那一环** —— 继续在同一层加减震是低收益的 |

所以本轮改做一件事：**让真机平板走与模拟器完全相同的路径**，先确定抖动到底在不在这一支。

### 改动

新增 `web_engine/src/main/ets/utils/WindowTuning.ts` —— 把窗口行为开关集中到一处，
每个开关都写清「置 true/false 会发生什么」与判定依据，避免在几个文件里翻。
`WebAbility.ets` 顶部原来的两个 `const` 保留为指向它的**别名**（调用点不必改）：

```ts
// utils/WindowTuning.ts
PAD_IMMERSIVE_DISABLED             = true   // 平板沉浸/避让分支总闸：true = 关闭（本轮改为 true）
PAD_IMMERSIVE_SAFE_MODE            = true   // 分支内部的减震（合并 + 去重），仅在总闸为 false 时有意义
WINDOW_RECT_AUTOSAVE_ON_TABLET     = false  // 平板上是否启用「系统窗口矩形记忆」
```

| # | 位置 | 改动 |
| --- | --- | --- |
| 1 | `WebAbility.onWindowStageCreate` | 平板常规模式下**不再进入** `onPadWindowStageCreate`：不做 `setWindowLayoutFullScreen`、不调 `setSpecificSystemBarEnabled`、不注册 `avoidAreaChange`、不推裁剪后的内容边界 |
| 2 | `WebAbility` 的 `windowEvent → WINDOW_SHOWN` 分支 | `padNormal` 判据补上 `!PAD_WINDOW_STAGE_DISABLED`。**这一条必须一起改** —— 否则窗口每次显示仍会走 `updateAvoidAreaStatus` + 避让区裁剪推送，总闸形同虚设 |
| 3 | `WebBaseAbility.updateAvoidAreaStatus` | 平板常规模式下整体跳过。这里是**唯一的系统栏下发出口**（`onPadWindowStageCreate` / `maximize` / `setFullScreen` 都汇到它），闸门放这一层就不漏 |
| 4 | `WebBaseAbility.enableWindowRectAutoSave` | 平板常规模式下不启用系统矩形记忆（只拦「平板 + 系统未开电脑模式」，同一台平板切到电脑模式不受影响） |
| 5 | `WindowEventWatch` | 阈值 30 → 15 次/秒。30/s 是「屏幕明显在蹦」的量级，而视觉上已经很抖的循环可能只有 10~20/s，阈值定高了会出现「人眼在抖、日志却安静」 |
| 6 | `WebAbility` 启动日志 | 新增一行 `[Tuning] padImmersiveDisabled=... sdk=...`，一眼看出「装的是哪一版档位」，免得出现「改了没编进去 / 编了没装上」的空转 |

**PC / 2in1 完全不受影响**：上述 1~4 条的判据都要求 `deviceType === 'tablet'` 且系统未开电脑模式；
用户已确认的「PC 模式连续启动 OK」走的路径一个字节都没动。

**观感变化（预期内）**：关掉沉浸后窗口不再占满整屏、不盖到状态栏下（非全屏布局下
`getWindowAvoidArea(TYPE_SYSTEM)` 读数为 0），所以页面顶部/底部那两条沉浸色条高度会变成 0，
内容不再钻进状态栏下面 —— 与模拟器上看到的效果一致。

### 验收：这一次是**二分**，不是修复

重编装包，平板模式下启动：

| 结果 | 结论 | 下一步 |
| --- | --- | --- |
| **不抖了** | 抖动 100% 在平板沉浸分支内 | 不永久关掉这个功能。从该分支里**逐项恢复**：先只恢复 `setWindowLayoutFullScreen`，再恢复系统栏调用，最后恢复 `avoidAreaChange` —— 哪一项一恢复就抖，那就是元凶。同时把 `hdc` 抓到的 `[JitterWatch]` 一行发我 |
| **照样抖** | 与沉浸/避让整条链路无关 | 方向转到窗口几何与 Electron 主进程的显示/激活链路。此时**务必抓一次日志**（见下），`[JitterWatch]` 里计数最高的那一路就是出口 |

### 抓日志（本次一定要抓，否则下一轮只能继续猜）

DevEco 的 Log 窗口：

1. 底部 **Log** 面板 → 右上角过滤框输入 `JitterWatch`（或 `WebAbility|AppWindow|DeviceInfoAdapter|JitterWatch`）。
2. 让平板抖起来，**然后下拉控制中心把抖动止住**，把这段日志复制出来。

`hdc` 命令行等价写法：

```bash
hdc shell hilog | grep -E "JitterWatch|WebAbility|AppWindow|DeviceInfoAdapter|WebNodeHandleWindow"
```

关键行形如：

```
[JitterWatch] 42 window events / 1000ms (anomaly #1) -> windowRectChange#3=18 avoidAreaChange#13=9 ...
```

| 计数最高的来源 | 指向 |
| --- | --- |
| `windowEvent#...` | 窗口在反复显示/失活（显示事件闭环） |
| `avoidAreaChange#...` | 避让区在反复变（系统栏可见性在抖） |
| `windowRectChange#` / `windowSizeChange` | 窗口几何在反复变（谁在改窗口） |
| `setBounds(blocked,pad)` | Electron 主进程在「请求 → 被拒 → 复查不符 → 再请求」地空转 |
| `pcmodeSwitchObserver` | 系统那个电脑模式开关在反复通知 |
| `updateAvoidAreaStatus(skipped)` | 上一轮的防抖闸门在命中（说明系统栏重复下发确实是压力点） |

### 回退

```
web_engine/src/main/ets/ability/WebAbility.ets.bak-before-pad-immersion-off
web_engine/src/main/ets/ability/WebBaseAbility.ets.bak-before-pad-immersion-off
```

`utils/WindowTuning.ts` 是新增文件，删除即可；`WindowEventWatch.ts` 同理。
把 `WindowTuning.PAD_IMMERSIVE_DISABLED` 改回 `false` 就恢复沉浸分支（**不必**回滚文件），
这也是最快的对照实验手段。

改后已过括号配平自检（与备份的差值：`WebAbility.ets` `{}`+1 / `()`+1，`WebBaseAbility.ets` `{}`+9 / `()`+11，
均为本轮新增的 if / try 块与日志行，左右相等）。

---

## 十三、平板抖动三轮：四条内容边界推送路径**口径不一致**（2026-09-19 12:4x）

### 触发

第十二轮把整条平板沉浸分支关掉（`PAD_IMMERSIVE_DISABLED = true`）后，用户反馈
**照样抖**。⇒ 排除整条「避让区 / 系统栏 / 全屏布局」链路，不再往那个方向加东西。

### 重新读代码后的发现

关掉沉浸只切断了 `onPadWindowStageCreate` / `updateAvoidAreaStatus` / `avoidAreaChange`，
**但向原生侧推内容边界这件事一点没停** —— 而且一共有**四条路**在各自算矩形：

| 调用点 | 口径（改动前） |
| --- | --- |
| `WebNodeHandleWindow.setDefaultBounds`（启动一次） | `drawableRect.top + statusBar`，高 `- statusBar - navIndicator` |
| `WebAbility.windowSizeChange` → `OnWindowSizeChange` | `windowRect.top + drawableRect.top`，**不扣状态栏**；宽高用 `size` 参数 |
| `WebAbility.windowRectChange` → `OnWindowRectChange` | `rect.top + drawableRect.top + statusBar`，**扣**状态栏与小横条 |
| `WebAbility` 的 `WINDOW_SHOWN` else 分支 → `OnWindowRectChange` | 同 `windowSizeChange`，**不扣** |
| `WebAbility.flushPadContentBound` → `OnWindowRectChange` | 先原地改写 `drawableRect`，再用 `drawableRect` 口径 |

**要害在于**：`windowSizeChange` 与 `windowRectChange` 在 HarmonyOS 里本来就是
**同一个尺寸变化成对触发**的（改尺寸、改位置、进出全屏都会两个回调都来）。
一个不扣状态栏、一个扣 —— 原生侧（Chromium surface）于是**交替收到两个不同的
矩形**，每次都按新尺寸重排一次渲染视口。观感就是「内容在屏幕上乱蹦」。

而这两路是**唯一没有任何抑制**的推送：`shouldDeferNormalBoundPush()`
只在启动 700ms 内压制，之后逐次照推；去重只做在 `padBound` 那条路上。

副产物：`windowRectChange` 和 `flushPadContentBound` 里都有

```ts
prop.drawableRect.height = prop.drawableRect.height + prop.drawableRect.top;
prop.drawableRect.top = 0;
```

这是**对 `getWindowProperties()` 返回对象的原地改写**。一旦该对象不是每次新建的
副本，`height` 就会**逐次累加**（每推一次涨一个 `top`）。改成局部变量后此风险消失。

### 改动

1. **`WebAbility.computeContentBound(windowClass)`** —— 新增，**唯一口径**：
   - 沉浸开启（`PAD_WINDOW_STAGE_DISABLED = false`）→ 扣状态栏与小横条（原 `windowRectChange` 口径）
   - 沉浸关闭（当前档位）→ 不扣任何东西，内容 = 窗口 drawable 全域
   - 全程只用局部变量，不再碰 `getWindowProperties()` 的返回对象
2. **`WebAbility.pushContentBound(kind, bound, reason, source)`** —— 新增，
   向原生推边界的**唯一出口**，按 `WindowTuning.CONTENT_PUSH_MODE` 决定推不推；
   `'dedup'` 时按指纹跳过重复（`size` / `rect` 各记一份指纹，互不干扰）。
3. 四个调用点全部改走统一出口；`pushContentSize` 也改为走同一口径。
4. **ArkUI 侧布局静止**：`Index.ets` / `NodeHandleWindow.ets` 的顶部 / 底部色条高度
   改由 `WindowTuning.IMMERSIVE_BARS_ENABLED` 控制，当前为 **false ⇒ 恒为 0**，
   Column 布局完全不动，切断「避让值抖动 → ArkUI 重排 → XComponent 尺寸变化」。
5. **`WebNodeHandleWindow.setDefaultBounds`**：沉浸关闭时既不扣避让高度、也不回写
   LocalStorage（去掉首帧「写 LocalStorage → 重排」这条路径）。
6. **屏幕浮层 `JitterHud`**（新增，`electron/src/main/ets/pages/JitterHud.ets`）：
   页面左上角实时显示最近 1 秒的窗口事件统计，抖动时背景变红。**不用抓日志**。

### 三个开关（都在 `web_engine/src/main/ets/utils/WindowTuning.ts`）

```ts
CONTENT_PUSH_MODE     = 'dedup'   // 'all' | 'dedup' | 'off'
IMMERSIVE_BARS_ENABLED= false     // 色条高度是否随避让高度变化
SHOW_JITTER_HUD       = true      // 左上角诊断浮层
```

### 怎么看结论（这次不需要抓日志）

重编安装后看**左上角那行 `JitterWatch`**：

| 看到什么 | 结论 | 下一步 |
| --- | --- | --- |
| `0/s`，也不抖了 | 抖动就是「两路口径不一致 → 视口交替重排」 | 完成。可把 `SHOW_JITTER_HUD` 改回 false 收尾 |
| 还在抖，浮层数字很大（几十~几百/s） | 闭环仍在，**看冒号后计数最高的那个来源** | 把那一路的名字发我即可精准定位 |
| 还在抖，但浮层显示 `0/s` | 窗口事件根本不频繁 ⇒ 抖动**不在 ArkTS 事件链路**，在原生/系统层 | 转查原生渲染与系统窗口管理，不要再改这些回调 |

想把实验做绝：把 `CONTENT_PUSH_MODE` 改成 `'off'`（这两路一次都不推）重编。
不抖 ⇒ 100% 是内容推送这条线；**照样抖 ⇒ 与内容推送彻底无关**，直接换层查。
（`'off'` 的代价：窗口尺寸真变化时内容不重排，仅用于定位。）

### 本轮备份

```
web_engine/src/main/ets/ability/WebAbility.ets.bak-before-bound-unify
web_engine/src/main/ets/ability/WebBaseAbility.ets.bak-before-bound-unify
web_engine/src/main/ets/utils/WindowEventWatch.ts.bak-before-bound-unify
electron/src/main/ets/pages/Index.ets.bak-before-jitter-hud
electron/src/main/ets/pages/NodeHandleWindow.ets.bak-before-jitter-hud
```

`JitterHud.ets` 为新增文件。改后括号配平自检：左右相等。

---

## 十四、浮层实测定位到根因层：窗口在以 **20Hz 被「隐藏→显示」**（2026-09-19 13:0x）

### 1. 实拍数据（平板，屏幕左上角 JitterWatch）

```
106/s  windowEvent#3=22 windowEvent#2=22 windowEvent#1=21 pushSkip(same)#rect=20 ...(+1 more)
102/s  windowEvent#4=21 windowEvent#1=21 pushSkip(same)#rect=20 windowEvent#2=21 ...
 87/s  pushSkip(same)#rect=18 windowEvent#4=18 windowEvent#2=18 ...
```

### 2. 解读：`windowEvent#N` 的 N 就是 `WindowEventType`

| 计数键 | 含义 | 实测频率 |
| --- | --- | --- |
| `windowEvent#1` | `WINDOW_SHOWN` | 21/s |
| `windowEvent#2` | `WINDOW_ACTIVE` | 22/s |
| `windowEvent#3` | `WINDOW_INACTIVE` | 22/s |
| `windowEvent#4` | `WINDOW_HIDDEN` | 22/s |
| `pushSkip(same)#rect` | `windowRectChange` 触发了，但矩形没变、被去重跳过 | 20/s |

四个生命周期事件**齐刷刷 20+/秒** ⇒ **窗口在以约 20Hz 循环「隐藏 → 显示」**。
一次循环正好产生 SHOWN + ACTIVE + HIDDEN + INACTIVE 各一次，并伴随一次
`windowRectChange`（窗口被重新摆放）—— 这就是「在屏幕上乱蹦」的直接来源，
也是截图里窗口位置/尺寸每张都不同的原因。

### 3. 这一行数据直接排除掉的东西

| 结论 | 依据 |
| --- | --- |
| **与避让区 / 系统栏 / 全屏布局无关** | 那是布局层，不可能产生 SHOWN/HIDDEN 事件。第十二轮「关掉整条沉浸分支照样抖」由此得到解释 |
| **与我们推给原生的内容边界无关** | HUD 显示 `pushSkip(same)` ⇒ 我们**已经在跳过**这些推送，一分钱没花在它上面，却照抖。第十三轮的口径统一是必要的清理，但不是病根 |
| **ArkUI 侧布局是静止的** | 色条恒为 0（`IMMERSIVE_BARS_ENABLED=false`），没有任何避让值驱动的重排 |
| **抖动在「窗口生命周期」层** | 只有窗口被真的收起/展开，才会产生 SHOWN/HIDDEN |

### 4. 病根所在的那道门：`showAbility()` / `hideAbility()`

全工程搜过，应用自身**没有任何主动 show/hide 调用**（只有用户手动最小化那一条）。
在本工程里能让窗口「消失」的入口只有一处：

```
Electron(JS/native) ──绑定调用──▶ AppWindowAdapter.showWindow / hideWindow / activateWindow
                                    └─▶ UIAbilityContext.showAbility() / hideAbility()
```

也就是说：**窗口只能是被 Electron 侧回调进来的**。它约 20Hz 地让窗口隐藏又显示，
每次重新显示窗口管理器就重新摆放一次窗口 —— 现象与数据完全吻合。

### 5. 本轮改动

**A. 把「能拨动窗口的每一个入口」全部计数**（纯埋点，不改行为）—— 下一版谁在飙一目了然：

`adapter/AppWindowAdapter.ets`：`showWindow` / `hideWindow` / `activateWindow` /
`setFullScreen` / `setSimpleFullScreen` / `maximize` / `unMaximize` / `minimize` /
`restore` / `setWindowButtonVisibility` / `setAlwaysOnTop`
`ability/WebAbility.ets`：`windowStatus` / `windowVisibility` / `windowStageEvent` / `displayIdChange`

后四个用来做**层级判别**：

- `windowStageEvent` 与 `windowEvent` 数值同名（1~4）但层级不同（舞台 vs 窗口）。
  两者**同频** ⇒ 整个 ability 被反复切前后台；**只有 windowEvent 飙** ⇒ 窗口对象层面。
- `windowVisibility` 与 `windowEvent#1/#4` 同频 ⇒ 窗口是真的在可见/不可见之间来回。
- `displayIdChange` 有计数 ⇒ 窗口在「本屏 ↔ 虚拟屏」之间被反复搬迁（电脑模式下的冷门路径）。

**B. 立刻止抖的闸门**：`WindowTuning.SUPPRESS_RAPID_ABILITY_HIDE`（默认 **true**）

`hideWindow` 与 `minimize` 共用 `AppWindowAdapter.dropRapidHide()`：距离上次
`showAbility` 不足 `RAPID_ABILITY_HIDE_GUARD_MS`（默认 **500ms**，实测循环周期约 50ms）
的「让窗口消失」请求**直接丢弃**并计数（HUD 上显示 `hideWindow(guarded)#<ms>`）。

作用有二：
1. **止抖** —— 把「隐藏→显示」从中间掐断，窗口不再消失、也不再被重新摆放；抖动期间
   应用本来就不可用，先可用优先。
2. **定性** —— 若置 true 后不抖了，就 100% 确认闭环就在这条 Electron↔ArkTS 可见性回流上。

代价：用户「刚把窗口调出来就立刻按 Home」这一种极限操作会被吞掉，需要再按一次；
正常使用（间隔 > 500ms）不受影响。完全回到原行为：置为 `false` 重编。

**C. 浮层扩容**：`WindowEventWatch.SNAPSHOT_TOP_N` 4 → 5，`JitterHud` 允许 5 行、宽度 94%
（埋点变多后，Top-4 会把真凶挤出可见范围）。

### 6. 重编后怎么读结论

看平板左上角那一行：

| 看到 | 结论 | 下一步 |
| --- | --- | --- |
| **不抖了**，且出现 `hideWindow(guarded)#xx` / `minimize(guarded)#xx` 计数很高 | 确认：Electron 侧在以高频回调隐藏窗口 | 收工前把闸门参数收紧（如 300ms）；根因需在 Electron 侧修「窗口可见性回流」 |
| 不抖了，但 `(guarded)` 计数很低甚至为 0 | 抖动另有其因（闸门没被触发却好了 → 说明是别的东西在同一个时间窗里被顺带改变了） | 抓 HUD 全行发我 |
| 照样抖，且 `showWindow` / `hideWindow` / `activateWindow` 之一在飙 | 就是它，但闸门没拦住（例如走的是 `showAbility` 之外的路） | 把飙的那一路名字发我 |
| 照样抖，`windowEvent#1~4` 仍 20+/s，但上面所有入口计数都接近 0 | 说明隐藏不是从 ArkTS 侧发起的 ⇒ 系统窗口管理器层面 | 转查系统侧：把应用声明为非自由窗口/强制全屏，或找设备侧窗口模式开关 |

### 7. 本轮备份

```
web_engine/src/main/ets/adapter/AppWindowAdapter.ets.bak-before-hide-guard
web_engine/src/main/ets/ability/WebAbility.ets.bak-before-hide-guard
web_engine/src/main/ets/utils/WindowEventWatch.ts.bak-before-hide-guard
web_engine/src/main/ets/utils/WindowTuning.ts.bak-before-hide-guard
```

改后括号配平自检：`{ } ( ) [ ]` 左右全部相等；`resources/` 下无任何 `.bak` 文件。

---

## 十五、读 Electron 主进程 JS，锁定「48 次/秒在 show 主窗口」的调用方（2026-09-19 13:2x）

### 1. 本轮的实拍数据（平板，屏幕左上角 JitterWatch）

```
262/s  showWindow=48  windowEvent#1=24  pushSkip(same)#rect=24  windowStageEvent#2=24 ...
259/s  showWindow=47  windowEvent#3=24  windowStageEvent#1=24  windowStageEvent#2=24 ...
```

上一轮埋的 `showWindow` 计数第一次**出现在榜首**，这是决定性的：

- `showWindow=48/s` = `AppWindowAdapter.showWindow` 每秒被调 48 次。而本工程里
  `activateWindow()` 内部也是 `this.showWindow(id)`（并各自计数），
  即 **48 = 24 次「显示」+ 24 次「聚焦」** ⇒ 真实节奏是 **24 次/秒的「show + focus」**。
- `windowEvent#1`（`WINDOW_SHOWN`）也是 24/s，与之一一对应。

**每一次 `showAbility()` 都会让系统重放一遍「窗口打开」动效。**
24 次/秒地重放 ⇒ 窗口永远停在开场动效的某一帧 —— 这正好解释了截图里
窗口为什么是**倾斜的、每张的位置都不一样**（不是布局在抖，是动画被无限重启）。

### 2. 谁在调？—— 客户端自己的 JS 就在工程里

`web_engine/src/main/resources/resfile/resources/app/dist-electron/main/app-BOCPSy33.js`
（Electron 主进程 bundle，`package.json` 的 `main` 指向它）。里面只有三处会产生
`show + moveTop + focus` 这组动作：

```js
// ① 显示主窗口（托盘 / 二次启动 / 媒体控制 / mini-player 切回都汇到这里）
function cb(){
  if(!ob(J)) return;
  Al(`main`);
  let e=J.isVisible(), t=J.isMinimized(), n=J.isFocused();
  t&&J.restore();
  e||J.show();                                  // ← 不可见才 show
  Py()||J.setSkipTaskbar(!1);
  (!e||t||!n)&&(J.moveTop(), J.focus());        // ← 未聚焦就 moveTop + focus
}

// ② 「把宿主窗口顶到最前」（插件 API：plugins:host:show-on-top）
W.registerHandler(`plugins:host:show-on-top`,(t,n=`main`,r)=>{
  let i=r?.focus!==!1;
  ...
  return (a.isMinimized()&&a.restore(),
          a.isVisible()||(i?a.show():a.showInactive()),   // ← 不可见才 show
          typeof a.moveTop==`function`&&a.moveTop(),      // ← moveTop
          i&&a.focus(),                                   // ← focus
          {ok:!0,target:`main`})
})
```

两者都**先问 `isVisible()`**。既然每秒调 24 次 `show()`，说明在这台设备上
这个查询**没有真实反映窗口可见性**（端口层的 `isVisible()` 不可信）。
而 `focus()` 在本工程映射到 `activateWindow()` → `showWindow()` → `showAbility()`，
所以一次「show + focus」正好是 2 次 `showWindow` 计数 —— 与 48 完全吻合。

> 注：渲染进程侧只有插件桥（`network-*.js` / `pluginWindow-*.js`，7KB 级别的小文件）
> 暴露了 `host.showOnTop`，主 UI bundle 里没有大量轮询。也就是说这 24Hz 很可能来自
> **桌面歌词之类的插件在定时「保持置顶」**（插件代码装在用户数据目录，不在本工程内）。
> 所以不去改 JS，而是在 **ArkTS 边界**统一拦 —— 那是唯一能覆盖所有调用方的位置。

### 3. 本轮改动：在 ArkTS 边界把「冗余的 show / hide」丢掉

新增 `web_engine/src/main/ets/utils/WindowVisibility.ts`（**窗口可见性的权威记录 + 抑制器**）：

- **状态从系统事件来**，不靠猜：`windowEvent` 的 `WINDOW_SHOWN` / `WINDOW_HIDDEN`、
  `windowVisibilityChange`、`windowStageEvent` 的 SHOWN/HIDDEN，以及本工程
  `showAbility()` / `hideAbility()` 的成功回调（都在 `WebAbility` 里喂进去）。
- **规则 1 · 状态幂等**：窗口**已经可见**时再来的「显示」请求直接丢弃
  （HUD 显示 `showWindow(skip:visible)`）；**已确证不可见**时再来的 hide 丢弃。
  被丢掉的那一次不会重放动效 —— 闭环就地消失。
- **规则 2 · 高频合并（反压）**：`STORM_WINDOW_MS`(500ms) 内请求数 ≥
  `STORM_MIN_REQUESTS`(5) 时进入「高频」状态，同一方向最多每
  `STORM_COALESCE_MS`(1500ms) 放行一次（HUD 显示 `...(skip:storm)`）。
  这一条**不依赖状态记录是否准确** —— 万一状态记错，最坏也只是每 1.5 秒重放一次，
  不会回到 24Hz。这两条合起来，把「24 次/秒重放动效」压到「理论上 0 次、最坏 1 次/1.5 秒」。
- **只作用于主窗口**：`WindowTuning.MAIN_WINDOW_ID`（=1，即 `browser1`）。
  其它 id（插件窗口、分享窗口）**一律原样放行**，避免出现「窗口创建了却不显示」
  这种更难查的问题。
- 被丢弃的 show **同样会刷新** `lastAbilityShowMs`，保持上一轮「高频 hide 闸门」
  处于武装状态，避免「show 被压住、hide 却漏过去」反而把窗口藏掉。

### 4. 三个开关（都在 `web_engine/src/main/ets/utils/WindowTuning.ts`）

```ts
SKIP_REDUNDANT_SHOW = true      // 冗余 show 抑制（本轮主开关）
SKIP_REDUNDANT_HIDE = true      // 冗余 hide 抑制（成对）
STORM_COALESCE_MS   = 1500      // 高频合并窗口 = 兜底放行间隔
MAIN_WINDOW_ID      = 1         // 只抑制这个窗口（browser1）
```

### 5. 重编后看左上角（仍然不用抓日志）

| 看到 | 结论 |
| --- | --- |
| **不抖了**，且出现 `showWindow(skip:visible)#1` 大计数 | 闭环确认：24Hz 重放动效所致，已就地压掉 |
| 不抖了，但几乎全是 `showWindow(skip:storm)` | 规则 1 没生效（可见性状态没喂准）、靠规则 2 兜住；下一步只需调状态来源 |
| 仍然抖，且 `showWindow#<id>` 的大计数**不是 1** | 在刷的不是主窗口 —— 把那个 id 发我，改 `MAIN_WINDOW_ID` 或按 id 分流 |
| 仍然抖，`showWindow#1` 已经很小甚至为 0 | 与 Electron→ArkTS 这条 show 链路**彻底无关**，方向转原生渲染/系统窗口管理 |

想让实验做绝：把 `SKIP_REDUNDANT_SHOW` 改回 `false` 重编，就回到本轮之前的行为，无需回滚文件。

### 6. 顺带交给上游（EchoMusic 源码仓库）的修复建议

本轮的闸门是**边界兜底**，根治要在客户端侧：

1. 端口层把 `BrowserWindow.isVisible()` 做对（返回真实可见性）—— 现在它显然常返回 false，
   才导致「show + focus」被反复执行；
2. 或者让 `moveTop()` / `focus()` 在「窗口已经可见且已聚焦」时**不落到 `showAbility()`**；
3. 插件侧（`host.showOnTop`）轮询「保持置顶」时，只在状态**变化时**调用，别按帧调。

### 7. 本轮备份

```
web_engine/src/main/ets/adapter/AppWindowAdapter.ets.bak-before-show-guard
web_engine/src/main/ets/ability/WebAbility.ets.bak-before-show-guard
web_engine/src/main/ets/utils/WindowTuning.ts.bak-before-show-guard
```

`utils/WindowVisibility.ts` 为新增文件。改后括号配平自检：`{ } ( ) [ ]` 左右全部相等；
`resources/` 下无任何 `.bak` 文件。


---

## 十六、收尾：回退排查期操作，只保留根因修复（2026-09-19 13:3x）

### 0. 结论

平板抖动**已修复**。真正起作用的只有第十五节那一条机制：

> Electron 侧每秒 24 次要求「把主窗口显示出来」（`show()` + `focus()`），而在这台设备上
> 每一次 `showAbility()` 都会**重放一遍窗口打开动效** —— 窗口永远停在开场动效的某一帧，
> 于是「在屏幕上乱蹦」。在 ArkTS 边界把**冗余的 show/hide 丢掉**（`utils/WindowVisibility.ts`）
> 即解决。

**第十一 ~ 第十四节的改动全部是定位过程中的尝试，已被实测证明不是病因**（关掉沉浸照样抖、
推送早就在被跳过却照抖），本轮**全部回退**，只保留这一条机制。

### 1. 现在的代码状态

| 文件 | 状态 |
| --- | --- |
| `web_engine/src/main/ets/utils/WindowVisibility.ts` | **新增**（根因修复本体，自包含，只依赖 `LogUtil`） |
| `web_engine/src/main/ets/adapter/AppWindowAdapter.ets` | `showWindow` / `hideWindow` / `minimize` 三个入口接闸门（+18 行） |
| `web_engine/src/main/ets/ability/WebAbility.ets` | 把系统的可见性事件喂给 `WindowVisibility`（+32 行） |
| 其余所有文件 | 与「抖动排查开始之前」的基线**逐字节一致**（`WebBaseAbility` / `Index.ets` / `NodeHandleWindow.ets` 差异为 0） |

### 2. 已回退清单（第十一 ~ 第十四节）

| 被回退的东西 | 哪一节 | 为什么能删 |
| --- | --- | --- |
| `utils/WindowEventWatch.ts`（事件频率看门狗）+ 4 个文件里 30+ 处计数埋点 | 十一 ~ 十四 | 纯诊断，不改变行为 |
| `electron/src/main/ets/pages/JitterHud.ets`（屏幕浮层）+ 两个页面里的 `Stack` 叠加 | 十三 | 纯诊断 UI |
| `utils/WindowTuning.ts`（集中开关文件，10 个开关） | 十二 | 十个开关里只有 show 抑制那一族是对的；常量已收进 `WindowVisibility.ts` |
| `PAD_IMMERSIVE_DISABLED`（关掉整条平板沉浸分支） | 十二 | 关掉之后**照样抖** ⇒ 该分支不是病因；沉浸避让已恢复 |
| `updateAvoidAreaStatus` 的防抖闸门 / 平板常规模式整体跳过 | 十一、十二 | 同上 |
| `IMMERSIVE_BARS_ENABLED`（顶部/底部色条恒定 0） | 十三 | 随沉浸分支一并恢复 |
| `requestPadContentBound` / `flushPadContentBound`（推送合并 + 指纹去重） | 十一 | 实测浮层上写的是 `pushSkip(same)` —— **早就在跳过**这些推送，却照抖 ⇒ 不是病因 |
| `computeContentBound` / `pushContentBound`（四条推送路径口径统一）、`CONTENT_PUSH_MODE` | 十三 | 同上（口径统一是必要的清理，但与本问题无关） |
| `avoidAreaChange` 的值去重、去掉冗余的 `setSpecificSystemBarEnabled('navigationIndicator', true)` | 十一 | 同「沉浸分支」一条 |
| `dropRapidHide` / `SUPPRESS_RAPID_ABILITY_HIDE`（高频隐藏闸门） | 十四 | 加它的那一版**照样抖**；实测高频的是 **show**，不是 hide |
| `enableWindowRectAutoSave` 在平板上不启用 | 十二 | 系统矩形记忆本就是「启动页与主窗同框」（第十节）的正解，不该屏蔽 |
| `WebNodeHandleWindow.setDefaultBounds` 的沉浸开关分支 | 十三 | 回到「首帧沿用同一套避让值」的写法 |

### 3. 保留的（更早的已确认修复，未被回退）

- 第八 ~ 第十节：`setWindowRectAutoSave` + 两屏底色对齐（启动页与主窗同框）、
  `DeviceInfoAdapter.initWindowMode` / `getDeviceModeFromSystem` 两个开关的判据、
  启动几何兜底与 `clampNearlyFullScreen`、平板沉浸避让分支本体。

### 4. 备份与回退

- **能跑通的那一版全量快照**：`../EchoMusic_OHOS-backups/working-round14/`
  （第十一 ~ 第十五节那套「带诊断」的版本，含 `WindowEventWatch.ts` / `WindowTuning.ts` /
  `JitterHud.ets`）—— 按原相对路径覆盖回工程即可回到那版。
- **排查期 32 个 `.bak`**：`../EchoMusic_OHOS-backups/history/`（按原相对路径存放）。
  **源码树内已无任何 `.bak` 文件**（含 `resources/` 与构建中间产物）。
- 想单独恢复某个被回退项：从上面两处取对应文件即可，不必重写。

### 5. 若此后又出现窗口异常

看日志里 `WindowVisibility` 这个 tag：`skippedShows` 在涨 ⇒ 抑制在工作。
需要做对照实验时，把 `WindowVisibility.SKIP_REDUNDANT_SHOW` 改成 `false` 重编即回到原行为。

> ⚠️ 本节之前（第十一 ~ 第十五节）描述的都是**已被回退**的定位过程，保留作为排错记录，
> 不要照着改代码。真正的结论只看本节与第十五节的机制说明。

---

## 十七、平板沉浸：系统栏区域改成「按窗口像素取色」（2026-09-19 13:5x）

### 1. 现象（用户反馈）

平板模式下**小横条与状态栏都不沉浸，主界面和歌词页都一样**：这两处永远是两条与页面
不连续的灰带。

### 2. 根因：色条取错了变量，取到的是固定中性灰

`Index.ets` / `NodeHandleWindow.ets` 的「三段式沉浸布局」用两条色条铺在系统栏区域：

```
Column { 顶部色条(statusBarHeight) | 网页内容(layoutWeight 1) | 底部色条(navIndicatorHeight) }
```

色条颜色来自渲染层上报：`dist/assets/immersiveColor-*.js` 每秒读一次
`getComputedStyle(document.documentElement)` 的 `--app-background-color`，
主进程把值经 CommonEvent 送到 `EntryAbility` → `AppStorage.immersiveTopColor/BottomColor`。

问题就在这一步：

| 查证 | 结果 |
| --- | --- |
| `--app-background-color` 在前端 CSS 里是否定义 | **全量 grep 未找到任何定义**（1145 个 dist 资源里只有 js 里引用它） |
| 该脚本的回退值 | `--surface-main-base`，而它只有两个值：深色 `#26262a` / 浅色 `#f5f5f7` |
| `Index.ets` 里的兜底常量 | `'#26262A' : '#F5F5F7'` —— **和回退值一模一样** |

也就是说：**色条无论走哪条路，拿到的都是固定中性灰**。而页面真实背景是随当前歌曲/封面
变化的彩色（主界面是主题粉、歌词页是封面色棕渐变），于是系统栏位置必然出现一条
"不跟页面走"的灰带，**歌词页最刺眼**（页面棕色、色带灰色）。

小横条本身是系统绘制的，色条只能垫在它下面，遮不住它 —— 所以"小横条不沉浸"的观感
只能靠**让底部色条与页面底边同色**来消除（底层不再是灰带，灰条就有了"贴边"的底座）。

### 3. 改法：把"上报色"换成"照窗口像素取色"

新增 `web_engine/src/main/ets/utils/ImmersiveColorSampler.ets`：

1. `window.snapshot()` 取一张**本窗口**位图（不含系统栏，也不需要任何权限）；
2. 读**紧贴避让边界的那一行**：顶部取 `statusBarHeight + 4`，底部取 `height - navIndicatorHeight - 4`；
   用 `pixelMap.readPixels(region, buffer)` 只读一行（几十 KB），不再整块拷位图；
3. 该行横向取 9 个等分点，**逐通道取中位数** —— 个别点落在搜索框/按钮/文字上也不会带偏结果；
4. 按 `getImageInfoSync().pixelFormat` 决定通道顺序（窗口截图一般为 `RGBA_8888`；
   若是 `BGRA_8888` 必须红蓝对调，否则棕色会读成蓝紫）；`release()` 掉位图；
5. 结果写 `AppStorage.immersiveSampledTopColor / immersiveSampledBottomColor`，
   页面用 `@StorageProp` 消费（**优先于**原来的上报色，上报色降级为兜底）。

为什么这比"改前端取色脚本"更稳：色条取的是**边界那一行的真实像素**，纯色、渐变、封面图、
视频一律接得上，且页面换页/换肤会在下一次采样自动跟上，不依赖任何 CSS 变量名。

### 4. 改动清单

| 文件 | 改动 |
| --- | --- |
| `web_engine/.../utils/ImmersiveColorSampler.ets` | **新增**：窗口取样 + 中位数取色 + 通道容差比较（自包含，只依赖 `LogUtil`） |
| `web_engine/.../ability/WebAbility.ets` | 新增 `startPadEdgeColorWatch` / `stopPadEdgeColorWatch` / `samplePadEdgeColors`；记录 `padStatusBarHeight` / `padNavIndicatorHeight` 供定位采样行；在 `onPadWindowStageCreate`（启动）、`windowEvent SHOWN`（后台重开）启动，在 `WINDOW_HIDDEN` / `windowStageEvent HIDDEN` / `onWindowStageDestroy` 停止 |
| `electron/.../pages/Index.ets`、`pages/NodeHandleWindow.ets` | 各 +2 个 `@StorageProp`，`getImmersiveTopColor/BottomColor` 改为"采样色 → 上报色 → 深浅色默认值"三级回落 |

**只做加法，没有删除任何既有逻辑**：不动 `WebBaseAbility.updateAvoidAreaStatus`，
不动避让边界推送口径，不动状态栏/小横条的显隐（两条系统栏照旧可见）。

### 5. 开销与稳定性

- 采样周期 **2s**（`WebAbility.PAD_EDGE_COLOR_INTERVAL_MS`），空转时只有一次窗口截图 +
  两行 `readPixels`；窗口不可见/后台时定时器已停，不在后台空跑。
- 颜色变化小于每通道 6/255 视为"没变"，**不写 AppStorage** ⇒ 不会因为边缘像素轻微浮动
  造成色条闪烁或多余重绘。
- 取色失败（窗口不可见等）只记一条 warn，**保持上一次颜色**，不写空值。

### 6. 验证

```
hdc shell hilog | grep -E "Immersive|WebAbility"
```

- 出现 `[Immersive] top edge color -> #xxxxxx` / `bottom edge color -> #xxxxxx`
  ⇒ 采样生效（颜色变化时才打印，正常使用下只在换页/换肤时出现）。
- `[Immersive] snapshot/readPixels failed` ⇒ 该设备/该时机拿不到窗口位图，
  色条会自动停在渲染层上报色（即第 2 节说的固定灰），不影响其他功能。

观感上应有的变化：

| 位置 | 改前 | 改后 |
| --- | --- | --- |
| 状态栏区域 | 固定灰带（歌词页最明显） | 与页面顶边同色（主界面主题粉、歌词页棕色…） |
| 小横条区域 | 固定灰带 | 与页面底边同色，小横条落在自己的底色上 |

启动后 1~2 秒内色条会从兜底灰"跟上"页面真实颜色，属正常（第一次采样即刻执行）。

### 7. 回退

把 `WebAbility.ets` 顶部的 `PAD_EDGE_COLOR_SAMPLING` 改成 `false` 重编即可 ——
采样定时器不再启动，色条回到"渲染层上报色 → 深浅色默认"，行为与本节之前完全一致。

### 8. 编译修正：PixelMap 读像素的 API 用错了（同日补）

第一次编译 `CompileArkTS` 失败，**3 个报错全部集中在新增的 `ImmersiveColorSampler.ets`**，
其余文件零报错：

```
1 ERROR: 10605038 Object literal must correspond to some explicitly declared class
          or interface (arkts-no-untyped-obj-literals)   ... :82:11
2 ERROR: 10505001 Namespace 'image' has no exported member 'ImageRegion'.  ... :79:23
3 ERROR: 10505001 Argument of type 'ArrayBuffer' is not assignable to parameter of type
          'AsyncCallback<void, void>'                     ... :85:37
```

### 起因：凭印象写了 `readPixels(region, buffer)`

`@ohos.multimedia.image` 的 `PixelMap.readPixels` **只有一个入参**，且**不回传数据**：

```ts
// 正确（区域类型是 PositionArea，像素写进它自己的 pixels 字段）
readPixels(area: PositionArea): Promise<void>;
readPixels(area: PositionArea, callback: AsyncCallback<void>): void;
```

- 报错 2：区域类型名是 `image.PositionArea`，**不存在** `image.ImageRegion`
  （`region` 是 `PositionArea` 里的一个字段，不是类型名）。
- 报错 1：因为上面的类型名不存在，对象字面量失去上下文类型，连带触发
  `arkts-no-untyped-obj-literals`（改对类型名即同时消失）。
- 报错 3：两参调用被当成 callback 形式匹配 —— 报错里那个 `AsyncCallback<void, void>`
  恰好印证了"读出来的数据不走回调、只落进 `area.pixels`"。

### 另一处必须一起改：通道顺序是固定的 BGRA_8888

官方约定：**非 YUV 位图的 `readPixels` 输出一律转成 BGRA_8888**，与源位图自己是
RGBA 还是 BGRA 无关。所以取色要按 B/G/R/A 读：`blues = pixels[base]`、
`greens = pixels[base+1]`、`reds = pixels[base+2]`。

原来那套"按 `getImageInfoSync().pixelFormat` 判断要不要红蓝对调"的逻辑是多余的，
已删除（顺带也就不会因为枚举差异出问题）。**若真机上发现颜色红蓝颠倒，只需改
`ImmersiveColorSampler.sampleRow()` 里那三行的取值顺序。**

### 改后的调用形态（也是最终形态）

```ts
const stride: number = width * 4;
const area: image.PositionArea = {
  pixels: new ArrayBuffer(stride),
  offset: 0,
  stride: stride,
  region: { x: 0, y: row, size: { width: width, height: 1 } }
};
await pixelMap.readPixels(area);          // 数据被写进 area.pixels
const pixels: Uint8Array = new Uint8Array(area.pixels);
```

依然是"只读一行"：一行 `width * 4` 字节，不需要把整张窗口位图整块拷出来。

### 9. 取色"慢几秒"：2s 固定周期 → 400ms 稳态 + 跳变后 120ms 追赶（同日补）

**现象（用户反馈）**：取色生效了，但切页后颜色要慢几秒才跟上；歌词页效果很好，
主界面下方小横条那条带子效果差，上方状态栏还可以。

**慢的根因是采样周期本身**：原实现是 `setInterval(..., 2000)` —— 一次采样最长要等 2 秒，
叠上页面自己的过渡动画，感知就是"慢好几秒"。而且换页瞬间恰好是最需要快的那一下。

**改成递归调度 + 自适应周期**（`WebAbility`）：

| 参数 | 值 | 作用 |
| --- | --- | --- |
| `PAD_EDGE_COLOR_INTERVAL_MS` | 400ms | 稳态周期。窗口截图本身有开销，这是"响应速度 ↔ 开销"的平衡点 |
| `PAD_EDGE_COLOR_BURST_MS` | 120ms | 一旦发现颜色跳变（换页/换肤/换歌），用这个周期连追几拍，快速收敛到最终色 |

实现要点：

- 用 `setTimeout` **递归调度**而不是 `setInterval`：一张截图有可能比周期还慢，递归调度天然
  不会堆积重叠的采样；同时才能按"颜色是不是刚变过"动态改周期。
- 新增 `padEdgeColorActive` / `padEdgeColorWindow` 两个字段：窗口隐藏时置为不可用，
  在途的采样回来时据此**不再续期**（否则停表后会被在途结果重新拉起）。
- 采样本来就"颜色没变不写 AppStorage"，所以稳态下加速**不会**带来多余重绘。

**顺带把采样从"一行"改成"一条窄带"**（`ImmersiveColorSampler`）：

- 原来读紧贴边界的那**一行**；现在读 `BAND_HEIGHT_PX = 20` 行（离边界 4px 起，向内容侧延伸），
  带内 9 列 × 20 行一起逐通道取中位数。
- 好处正是冲着"主界面小横条效果差"去的：边缘上那条**细描边 / 阴影 / 圆角抗锯齿 / 一像素暗线**
  在原来会整条决定颜色（于是那条带子偏暗、看起来"不沉浸"）；进带宽 + 中位数之后，它只占
  40 个采样值里的少数，直接被投票掉。中位数大约落在带的中间（离边缘 ~14px），仍然贴近真实边缘。
- 仍然是一次 `readPixels` 调用读整条带（`width * 4 * rows` 字节），不是读 20 次。

**调参入口**（都在文件顶部常量区）：嫌慢就调小 `PAD_EDGE_COLOR_INTERVAL_MS`；嫌截图开销大
（个别机器可能察觉卡顿）就调大它；嫌边缘太"钝"就调小 `BAND_HEIGHT_PX`。

### 10. 仍有两处色差：色条卡在旧色（死区过大）+ 横向只有一种颜色（同日补）

**现象（用户反馈）**：取色确实快了，但**上、下都能看到色差**；用户猜测"主界面是取色位置太靠上方，
应该贴着边缘取色"，顶部则说不清原因。

**这次不再靠肉眼判断**：沙箱里没有 PIL / ffmpeg，本机 SDK 的 d.ts 也读不到，于是写了一个纯 JS 的
基线 JPEG 解码器（现随技能自带，路径见第十九节：
`~/.workbuddy/skills/harmonyos-sdk-downgrade-compat/assets/jpeg_probe.js`）**直接读用户截图的像素**，把两条色条的实测颜色
和页面真实颜色逐行对出来。四处的实测结果：

| 位置 | 色条实际颜色 | 紧贴边界的页面真实色 | 结论 |
| --- | --- | --- | --- |
| 歌词页 顶部 | `#233648` | `#233a4d`（y88 起稳定） | 色条**卡在旧色**，差 0/4/5 |
| 歌词页 底部 | `#233648` | `#233a4d` | 同上（上下两条都卡住） |
| 主界面 顶部 | `#383d45` | `#383d45` | 一致，无问题 |
| 主界面 底部 | `#363539`（全宽单色） | 中间 `#363539`／**左侧侧边栏 `#29282a`** | **横向**色差：整条一个色，压不住左右不同色 |

两条色条与页面的分界非常干净（全宽一致、只有 1 行过渡），可以确认不是"取色位置不对"，而是：

- **原因一：颜色死区（`COLOR_DEAD_BAND`）原为 6，太大。**
  歌词页真实底色 `#233a4d` 与色条里卡住的旧色 `#233648` 只差 **0 / 4 / 5**，全部落在死区内
  ⇒ `isSameColor()` 永远判"没变"，更新被**永久跳过**。色条一直停在页面刚打开时的旧色上，
  于是上下各出现一条"和页面差一点点"的色带。这也解释了为什么"看起来像没生效"。
- **原因二：整条色条只有一个颜色，而窗口内容左右不同色。**
  主界面左侧是一整块侧边栏（`#29282a`），右侧才是主体（`#363539`），实测左下角差 **13/255**，
  肉眼可见。整条填哪个值都会在另一侧留下色带。
- **顺带纠正用户的猜测**：主界面底部**紧贴边界的 5 行是播放条的下边框**（`#18171b`，近黑）。
  真"贴着边缘取色"会把色条填成近黑色，比现在更糟。所以采样仍要留 `EDGE_OFFSET_PX = 4`
  并取一条 20 行的带（让边框线在投票里输掉）。

**改法（三件事，`ImmersiveColorSampler` + `WebAbility` + 两个页面）**：

1. **死区 6 → 2**：`COLOR_DEAD_BAND = 2`。这种"差一点点"的真实变化现在能正常写进去。
   颜色本身是"整条带取中位数"得来的，很稳，2 不会造成闪烁。
2. **横向分桶（16 段）**：按窗口宽度切 `SAMPLE_BUCKETS = 16` 段，每段单独取色，写成逗号分隔的
   分段色串 `immersiveSampledTopColors / immersiveSampledBottomColors`；ArkUI 侧色条用
   `ForEach` 铺成 16 个等宽小格，每格一个颜色 —— 页面左右不同色时能接上（主界面底部左侧
   现在会取到 `#29282a`，和侧边栏连成一片）。仍然只写一份"中间段单色"给只认单色的地方兜底。
3. **近带 + 远带双采样 + 印证规则**：分桶之后出现新风险 —— 贴着边界的**控件**会独占某个桶。
   实测主界面顶部的搜索框（下沿离边界仅 8px）会让第 4~6 桶取到药丸灰 `#444951`，色条上出现亮斑。
   所以同时读一条更深的"远带"（离边界 80px 起 20 行）：只有**偏离整条主色这件事在深处依然成立**
   时，才认为它是背景结构（侧边栏），采纳该桶自己的颜色；否则（控件、描边、阴影）退回整条主色。
   两条带拼在同一块 `readPixels` 区域里一次读完（`SAMPLE_SPAN = 96` 行），不额外增加调用。
4. **心跳刷新**：每 10s 无条件重写一次 AppStorage（`PAD_EDGE_COLOR_FORCE_WRITE_MS`），
   万一还有别的路径让色条卡住，最坏也只偏差一个心跳周期。

**上线前的本地预演**（不依赖真机）：`jpeg_probe.js` 里的 `sim` 子命令把改后的算法**逐像素复现**
在用户截图上跑一遍，四条边全部符合预期：

```
歌词页 顶部/底部  →  16 段全部 #233a4d（= 页面真实色，卡住的旧色消失）
主界面 顶部      →  第 4/5/6 桶被远带否决、退回 #383d45（搜索框亮斑不会出现）
主界面 底部      →  #29282a #29282a #29282a #363539 ×13（左侧接上侧边栏）
```

**改动清单**：

| 文件 | 改动 |
| --- | --- |
| `web_engine/.../utils/ImmersiveColorSampler.ets` | 分桶取色 + 近/远带印证 + 死区降到 2；新增 `joinColors` / `middleColor` / `isSameColorList`；接口 `ImmersiveEdgeColors` 由 `string` 变为 `string[]` |
| `web_engine/.../ability/WebAbility.ets` | 写 `immersiveSampledTopColors/BottomColors`（分段串）+ 保留单色键；改用心跳 + 分段比较判"变了" |
| `electron/.../pages/Index.ets`、`NodeHandleWindow.ets` | 色条由"一个 Column 单色"改为"Row + ForEach 的 16 段"；新增 `getImmersiveSegments()` 解析分段串（格式不对就退化成单色） |

**依旧只动"颜色怎么来、怎么铺"，不动避让口径、不动系统栏显隐、不动抖动抑制逻辑。**

**调参入口**（`ImmersiveColorSampler` 顶部常量区）：

| 常量 | 现值 | 作用 |
| --- | --- | --- |
| `SAMPLE_BUCKETS` | 16 | 横向分段数（改这里要保证 ArkUI 侧解析同一串颜色，无需同步改别的） |
| `COLOR_DEAD_BAND` | 2 | 颜色死区；调大更稳但会漏掉细微变化（6 就是踩过的坑） |
| `EDGE_OFFSET_PX` | 4 | 距边界的空隙（躲色条自身与贴边描边） |
| `NEAR_ROWS` / `FAR_OFFSET_PX` | 20 / 80 | 近带高度、远带起点（远带要深过贴边控件的厚度） |
| `CORROBORATE_TOLERANCE` | 2 | 远带印证的松紧；调大更倾向于采纳分桶色 |

**回退**：`WebAbility.ets` 顶部 `PAD_EDGE_COLOR_SAMPLING` 置 `false` 即回到"渲染层上报色 → 默认值"。

### 11. 「采样时间能不能压到 10ms 内」——先量再答（同日补）

**结论：**
- 「**单次采样的分析耗时**」早就在 10ms 以内（实测 1.3ms），这一项本来就达标；
- 「**一整轮采样**」进不了 10ms，卡在 `window.snapshot()`（系统合成器的全窗口 GPU 回读，
  十几~几十 ms，不是我们的代码能优化的）；
- 「**采样周期 10ms**」（100Hz 连拍）物理上做不到，也没有意义（见下面的算术）。

**先把一轮采样拆开看**（3120×2080 平板；分析部分用 `sample_bench.js` / `sample_bench2.js`
复刻同一套循环实测 —— 这三个基准脚本已随取色方案一并移除，见第十九节；结论保留如下）：

| 环节 | 体量 / 耗时 | 谁决定 | 能不能优化 |
| --- | --- | --- | --- |
| `window.snapshot()` | 全窗口位图 **24.8MB** 分配 + GPU 回读，**十几~几十 ms** | 系统合成器 | **不能** |
| `readPixels` 窄带 | 2 × 0.24MB 搬运（改前是 2.29MB） | 我们的行数 | 已最小 |
| 分桶 + 中位数分析 | 改前 3.10ms/轮 → 改后 **1.25ms**（纯色）/ 2.25ms（需印证） | 我们的循环 | 已优化 |

**为什么不能把周期设成 10ms**：一轮必然要分配并回读一张全窗口位图。
400ms 稳态 = 每秒 2.5 次 = 每秒约 **62MB**；压到 10ms 就是每秒 100 次 = **2.4GB/s**
的位图分配 + 回读，还要跟 UI 渲染抢合成器 —— 结果是色条更卡、耗电飙升，而不是更跟手。
**snapshot 的实际耗时就是一拍的物理下限，把周期排到它以下只会让请求排队。**

**所以这一轮改的是"少做无用功 + 该跟时立刻跟"，共四处：**

1. **近带优先，远带按需**（`ImmersiveColorSampler.sampleEdge`）：先用一次 `readPixels` 读近带；
   只有当**确实存在偏离整条主色的桶**（才需要远带印证）时，才补读远带。
   绝大多数页面（纯色 / 渐变背景、没有贴边控件）第一趟就结束。
2. **缓冲复用 + 去掉每桶小数组**（同上文件）：行缓冲按字节数缓存复用（不再每轮 new 0.24MB×N）；
   桶内中位数改用模块级 scratch **原地排序**，不再每桶新建 6 个小数组（原来一轮建 384 个）。
3. **跳变后阶梯追赶**（`WebAbility.PAD_EDGE_COLOR_BURST_STEPS`）：原来"变过就一直 120ms"，
   改成 **50 → 80 → 130 → 200 → 400(稳态)**。跳变后前 500ms 采样很密（感知上跟得住），
   随后迅速放宽 —— 比"把稳态周期整体压小"省得多，也比"变完立刻回 400ms"跟得紧。
4. **事件驱动补拍**（`WebAbility.kickPadEdgeColorSample`）：几何/避让刚变化的时刻
   （`windowSizeChange` 转屏/分屏、`avoidAreaChange` 系统栏高度变化、入场动画收尾）
   立刻重采一拍，不再死等周期。带两层合并：在途时只留一个待办标记（多次请求合成一次），
   距上次起拍不足 `PAD_EDGE_COLOR_MIN_KICK_GAP_MS`(120ms) 时改为短延时补拍。

**实测收益**（`sample_bench2.js`）：

```
                          分析耗时（一整轮，上下两条边）   readPixels 数据量
旧实现                            3.096 ms                    2.29 MB
新实现·纯色背景（最常见）           1.252 ms  ↓59.6%            0.48 MB  ↓79.2%
新实现·左右两色（需印证）           2.247 ms  ↓27.4%            0.95 MB  ↓58.5%
```

**等价性验证（重构不能改变颜色）**：`sample_equiv.js` 把两版算法喂同一份像素，
覆盖 3 种宽度 × 7 个场景（纯色 / 左右两色 / 贴边药丸控件 / 贴边控件+真实色带 / 横向渐变 /
贴近死区 / 底部近黑下边框），断言 **16 段颜色逐段完全相同**：

```
✓ 全部通过：3 种宽度 × 7 个场景，新旧实现输出的 16 段颜色逐段完全相同
```

**调参入口（新增两个，都在 `WebAbility.ets` 顶部常量区）**：

| 常量 | 现值 | 作用 |
| --- | --- | --- |
| `PAD_EDGE_COLOR_BURST_STEPS` | `[50, 80, 130, 200]` | 跳变后的追赶阶梯（ms）；数组长度 = 追赶拍数 |
| `PAD_EDGE_COLOR_MIN_KICK_GAP_MS` | 120 | 事件补拍之间的最小间隔（限流用） |

**还想要"更跟手"的话，只剩一条路**：不要再截图。仓库里已经有一条 0 截图的上报通道 ——
`web_engine/src/main/resources/resfile/resources/app/dist/assets/immersiveColor-*.js`
（前端构建产物，electron 侧有一份同样的），它现在做的是：

```js
// 每 1000ms 轮询一次计算样式，读 --app-background-color，读不到就回落到 --surface-main-base
setInterval(n, 1e3)
```

两个问题：**① 轮询 1s**；**② `--app-background-color` 默认根本不存在**
（它只在用户「设置了自定义窗口背景色」时才由 `setProperty('--app-background-color', ...)` 写上，
默认走 `removeProperty`），所以永远回落到固定中性灰。这条路走通可以把延迟降到
CommonEvent 单程（几毫秒级），代价是要改前端构建产物、并且只能拿到 CSS 里的颜色
（渐变色条 / 封面取色这类拿不到，仍要靠像素采样兜底）。

**回退**：本轮的四处改动互相独立，单独回退任何一处都不影响其他三处；
整条取色链路依旧由 `PAD_EDGE_COLOR_SAMPLING` 一个开关兜住。

### 12. 取色方案整体下线：改为「直接隐藏系统栏」（同日 14:4x，用户拍板）

**用户决定：** 「把屏幕取色采样的代码删了吧，太耗性能了。本身就是网页应用，直接应用打开时
隐藏小横条和状态栏就彻底解决这个问题了。」

**思路转变：** 第 8~11 小节的全部工作量，本质是"保留系统栏 + 把系统栏背后那两条窄带涂成
页面背景色" —— 用 400ms 一次的整窗口截屏（3120×2080 下每次 24.8MB 分配 + GPU 回读，
稳态约 62MB/s）去维持一个**纯装饰性**的效果，还永远差一点色差。既然这是个网页应用壳，
直接把系统栏隐掉即可：问题从根上消失，周期截屏归零。

**行为变化：**

| | 改前 | 改后 |
| --- | --- | --- |
| 平板常规模式 · 小横条 | **保留**（应用内做底部抬升避让） | **隐藏** |
| 平板常规模式 · 状态栏 | 显示 | **隐藏** |
| 平板常规模式 · 内容边界 | drawableRect 扣状态栏 + 小横条 | 整个 drawableRect（避让按 0） |
| 平板常规模式 · 色条 | 三段式（色条 + 内容 + 色条） | 无（内容直接铺满） |
| 自由多窗 / PC 模式 | 隐藏小横条；状态栏随全屏切换 | **完全不变** |
| 周期截屏取色 | 400ms 一拍 | **已删除** |

**改动清单（7 改 1 删）：**

- **删除** `web_engine/src/main/ets/utils/ImmersiveColorSampler.ets`（取色实现，477 行）
- `web_engine/src/main/ets/common/Constants.ets` — 新增共享总开关 `PAD_IMMERSIVE_HIDE_SYSTEM_BAR`
- `web_engine/src/main/ets/ability/WebBaseAbility.ets` — `updateAvoidAreaStatus`：平板常规模式下
  不再保留小横条，并隐藏状态栏（由同一个开关控制，可完整回退）
- `web_engine/src/main/ets/ability/WebAbility.ets` — 删掉取色字段 / 6 个方法 / 全部补拍调用
  （净减约 180 行）；`onPadWindowStageCreate` 不再 `setSpecificSystemBarEnabled(navigationIndicator, true)`；
  `pushPadContentBound` 与 `windowRectChange` 在全沉浸下按 0 处理避让
- `web_engine/src/main/ets/components/WebWindow.ets`、`WebNodeHandleWindow.ets` — 首帧尺寸不再按避让区裁剪
- `electron/src/main/ets/pages/Index.ets`、`NodeHandleWindow.ets` — 去掉三段式色条，结构简化为
  `Row { WebWindow() }` 铺满；删掉 `immersiveSampled*` / `getImmersiveSegments` / 避让 prop 等

**★ 关键坑（后续改动必须知道）：系统栏隐藏 ≠ 避让区归零。**
`setWindowLayoutFullScreen(true)` + `setSpecificSystemBarEnabled(..., false)` 之后，
`getWindowAvoidArea()` 仍会返回状态栏 / 小横条的高度 —— 沉浸式的语义就是「布局铺满，
但避让区照旧告诉你系统栏在哪」。所以**不能**继续照抄避让区去裁剪内容，否则内容会被白白
缩进一块、四周留白，那是"不沉浸"的另一种表现。本次所有裁剪点都加了
`!PAD_IMMERSIVE_HIDE_SYSTEM_BAR` 判断，共 4 处：
`WebAbility.pushPadContentBound`、`WebAbility` 的 `windowRectChange` 回调、
`WebWindow.setDefaultBounds`、`WebNodeHandleWindow.setDefaultBounds`。

**回退：** 把 `common/Constants.ets` 的 `PAD_IMMERSIVE_HIDE_SYSTEM_BAR` 改成 `false`，
即可恢复「保留小横条 + 按避让裁剪」的旧行为（但取色链路已删，色条不会回来；
要完整旧版从 `EchoMusic_OHOS-backups/*.bak-before-hidesysbar-*` 还原）。

**备份：** `EchoMusic_OHOS-backups/*.bak-before-hidesysbar-20260919-144113`（5 个文件）。

**待真机验证：**

1. 打开应用后状态栏与小横条是否都不显示、内容是否铺满（不留白、不被压住）；
2. **媒体实况窗（状态栏胶囊）**：应用退到后台后胶囊是否正常出现 —— 隐藏的是本窗口的状态栏，
   理论上退后台由桌面接管、不受影响，但需实测确认（这是本方案唯一需要留意的副作用）；
3. 手势上滑回桌面是否正常（小横条只是不可见，手势本身由系统提供）；
4. 转屏 / 进出分屏后内容边界是否仍然铺满。

---

## 十八、自由窗口比例限制 + 干掉系统"窗口三键"（2026-09-19 15:0x）

用户在原「隐藏系统栏」验收通过后，提出两个新问题：

1. 平板小窗（悬浮窗、全景多窗）能被拖成很离谱的形状，界面会错位 —— 想限制比例；
2. 平板自由多窗模式下，应用自己的标题栏**右上角多压了一层按钮**。

### 1. 问题一：用 module.json5 声明式限制，不要用代码跟拖拽对抗

官方给了现成字段（[一次开发多端部署 FAQ · 如何限制自由窗口的尺寸调节范围]），
配在 `abilities[]` 里，**单位是 vp**（不是 px）：

| 字段 | 含义 |
| --- | --- |
| `minWindowWidth` / `minWindowHeight` | 允许的最小窗口宽 / 高 |
| `maxWindowWidth` / `maxWindowHeight` | 允许的最大窗口宽 / 高 |
| `minWindowRatio` / `maxWindowRatio` | 允许的最小 / 最大**宽高比**（宽 ÷ 高） |

生效优先级：**运行期 `setWindowLimits()` > `startAbility` 的 `StartOptions` >
`module.json5` > 系统默认**（取交集）。

本次加到 `electron/src/main/module.json5` 的 **EntryAbility**（应用所有窗口，
含主界面与歌词页，都是它的实例）：

```json5
"minWindowWidth": 640,
"minWindowHeight": 400,
"minWindowRatio": 1.0,     // 宽 ÷ 高 ≥ 1，不允许"高于宽"的竖条
"maxWindowRatio": 2.5,     // 宽 ÷ 高 ≤ 2.5，挡住最扁的极端形状
```

`maxWindowWidth` / `maxWindowHeight` 故意不写 —— 省略即保持系统默认上限，用户也说过
"宽到无所谓"。**没有改动** `BrowserAbility` / `StatelessAbility`（减小影响面）。

> **为什么不用运行期 `windowSizeChange` 监听 + `resize()` 纠正**：那等于在用户拖拽的
> 每一帧里反向抢尺寸，观感是抖动与"拖不动"，而且和系统的手势/吸附相互打架。
> 声明式配置由系统在拖拽过程中直接约束，平滑且零代码。

> **⚠️ 唯一需要留意的副作用：分屏 / 全景多窗。** 横屏平板左右对半分出来的窗口，
> 比例约 **0.75**，低于这次的 `minWindowRatio = 1.0`。若验收时发现**左右分屏或
> 全景多窗被限制住 / 排不出布局**，把 `minWindowRatio` 下调到 `0.7 ~ 0.75` 即可
> （就在同一个文件里，改完重编，不需要动任何代码）。

### 2. 问题二：`setWindowDecorVisible(false)` 并不会关掉右上角三键

这是本轮最容易踩的坑。

**现状链路**（都是既有代码，不是这次引入的）：应用在鸿蒙上是 `frame = false` +
`titleBarStyle: 'hidden'`，即**窗口标题栏由应用前端自己画**（Vue 的 `WindowControls`
组件，含最小化 / 关闭 / 全屏按钮），原生侧 `hideTitleBar` 因此为 `true`
（`WebBaseAbility` 默认值），于是 `onWindowStageCreate` 里调
`window.setWindowDecorVisible(false)`。

**但**：`setWindowDecorVisible(false)` 只隐藏标题栏**本体**，**右上角的"窗口三键"
（最大化/还原、最小化、关闭）是独立控制的，默认仍然显示**。系统这么设计是有意的 ——
隐藏装饰栏是为了让页面铺到标题栏区域，三键保留给用户操作窗口。

于是平板上就出现：系统三键压在应用自绘标题栏的右上角，看起来"多了一层按钮"。

**为什么 PC 上没这个毛病、只有平板有**（这是本轮真正的根因）：

```js
// WebAbility.onWindowStageCreate
if (this.deviceInfoAdapter?.isNormalWindowMode() === false) {
  window.setWindowTitleButtonVisible(this.maximizable, this.minimizable, this.closable); // ← 关三键
  ...
} else {
  LogUtil.info(TAG, 'tablet free multi-window model is disabled');
}
```

而 `DeviceInfoAdapter.getDeviceModeFromSystem()` 的第一条分支是：

```js
if (deviceInfo.deviceType === 'tablet' && isPcSystemMode !== 'true') {
  return DeviceMode.kNormalWindowMode;      // ← 平板恒为 kNormalWindowMode
}
```

也就是说 **平板的 deviceMode 恒为 `kNormalWindowMode`，`isNormalWindowMode()` 永远为
true，上面那条"关三键"的分支在平板上是死代码**。而 2in1 / PC 的 deviceMode 是
`kFreeWindowsMode`（或初值 `kPcMode`），能正常进那条分支，所以只有平板暴露问题。

> 讽刺的是 `else` 分支打印的日志文案是 `'tablet free multi-window model is disabled'`，
> 但它恰恰是**平板**走的那条路 —— 这句日志本身就是误导。

**改法**：平板单独兜一层，两道闸 + 一次形态变化重压。

| 位置 | 作用 |
| --- | --- |
| `WebAbility.applySystemCaptionButtonPolicy()`（新增） | 平板 + `hideTitleBar === true` 时，`setWindowTitleButtonVisible(false, false, false)`，并把三键区域 rect 归零同步给渲染层 |
| `WebAbility.onWindowStageCreate` | 在原分支**之后**调用一次（原分支在平板上是死代码，必须补） |
| `WebAbility.notifyWindowStatusChange` | 窗口形态每次变化（进/出自由多窗、最大化/还原、全屏）重新压一遍 —— 系统可能在新形态下把三键**恢复显示** |
| `AppWindowAdapter.setUseNativeFrame` | 第二道闸：平板上若本窗口是应用自绘标题栏，忽略前端传来的 `useNativeFrame = true`（运行期前端主动调用的那条路） |

**闸门条件**（三者同时满足才动手，其余情况原样返回、零影响）：

- `deviceType === 'tablet'`；
- `hideTitleBar === true`（应用自绘标题栏 —— 若某窗口真要系统原生标题栏，
  三键必须留着，否则用户没法关闭/最小化它）；
- 总开关 `PAD_HIDE_SYSTEM_CAPTION_BUTTONS === true`。

**新增开关**（`web_engine/src/main/ets/common/Constants.ets`）：

| 常量 | 现值 | 作用 |
| --- | --- | --- |
| `PAD_HIDE_SYSTEM_CAPTION_BUTTONS` | `true` | 平板是否隐藏系统窗口三键；置 `false` 回到"系统画三键"的旧观感（代价：与自绘按钮重叠） |

### 3. 改动清单（4 改）

| 文件 | 改动 |
| --- | --- |
| `electron/src/main/module.json5` | EntryAbility 新增 `minWindowWidth` / `minWindowHeight` / `minWindowRatio` / `maxWindowRatio` |
| `web_engine/src/main/ets/common/Constants.ets` | 新增开关 `PAD_HIDE_SYSTEM_CAPTION_BUTTONS` |
| `web_engine/src/main/ets/ability/WebAbility.ets` | 新增 `applySystemCaptionButtonPolicy()`；`onWindowStageCreate` 调用一次；`notifyWindowStatusChange` 形态变化时重压 |
| `web_engine/src/main/ets/adapter/AppWindowAdapter.ets` | `setUseNativeFrame()` 增加平板闸门（`effectiveNativeFrame`） |

**备份**：`EchoMusic_OHOS-backups/*.bak-before-winratio-20260919-150035`（4 个文件）。

**回退**：任一处独立回退都不影响其他处；整体回退用上面的备份。

### 4. 编译风险与验收入口

- `minWindowRatio` / `maxWindowRatio` 是**官方文档明确列出的 module.json5 字段**，
  但如果当前 SDK 的 schema 未收录，`hvigor` 会在解析 `module.json5` 阶段直接报
  "unknown field"。真遇到这种情况：**先删掉这四个字段**保证能编过，
  再改用运行期 `window.setWindowLimits()`（注意它**只管宽高、管不了比例**，
  比例只能靠 module.json5）。
- 验收：① 平板拖拽悬浮窗边角，看是否拖不出"高于宽"的形状、也拖不出极扁的条；
  ② 平板进自由多窗，看应用标题栏右上角是否只剩应用自己的按钮；
  ③ 进/出自由多窗、最大化/还原几次，看三键会不会自己冒回来；
  ④ **重点看左右分屏 / 全景多窗是否仍能正常排出布局**（见上面的比例副作用）。

---

## 十九、临时产物与取证脚本清理（2026-09-20）

一次空间整理，不影响任何功能代码。**已释放约 1.04 GB**（工程从 1246 MB → 289 MB）。

| 处置 | 对象 | 体积 |
| --- | --- | --- |
| 删除 | `electron/build/`（构建产物，含两个 ~245 MB 的 hap） | 896.8 MB |
| 删除 | `.hvigor/cache/`（构建缓存，构建时自动重建） | 4.6 MB |
| 删除 | 根目录 `EchoMusic-OHOS-DevEco-Project.zip` | 145 MB |
| 删除 | `.workbuddy/tools/` 下 5 个取证脚本与测试截图（目录一并移除） | 512 KB |
| 保留 | `.hvigor/outputs/build-logs/`、`.hvigor/report/`（用户明确要求保留） | 约 7 MB |

### 归档包是「先验后删」的，不是直接删

删 `EchoMusic-OHOS-DevEco-Project.zip` 之前做了内容比对（排除依赖/构建目录后）：

- 归档内 **1640 个源文件在工作区一个不缺**；
- 与归档**内容不一致**的源文件 **20 个**，其"原始版本"合计只有 **151 KB**；
- 于是先把这 20 个原始版本抽到
  `EchoMusic_OHOS-backups/original-from-zip-20260920-181338/`，再删掉 145 MB 的包 —— **零损失**。

> **★ 比对时的坑：`electron/oh_modules/web_engine` 是指向 `../../web_engine` 的软链接。**
> 直接 `os.walk` 比对（默认不跟软链）会凭空报出 **8000+ 个"缺失文件"**，
> 看上去像工程残缺。同理 `electron/oh_modules/` 只有几 KB 不是漏了依赖。
> **这个工程里"按模块对称性推断文件位置"是错的**：`resfile` 只存在于
> `web_engine/src/main/resources/resfile/`，`electron/src/main/resources/` 下**没有**。

### 代码日志：扫完的结论（与直觉不同）

全工程 **884 处**打点（error 500 / info 226 / warn 50 / debug 10），**没有大批可删的调试残留**：

- **高频回调干净**：`windowSizeChange` / `windowRectChange` 只在**注册失败**时记一次，
  **不逐帧打点** —— 真正的刷屏风险点实测不存在，无需处理。
- **唯一真缺陷已修**：`AppWindowAdapter.restore()` 里有全工程仅有的 2 处 `console` 直调，
  且 `console.error` 的模板串**跨了行**（缩进会作为字面量进日志）。已改为
  `LogUtil.info/error(TAG, ...)` 并合并为单行。全工程 `console.*` 现为 **0 处**。
- **厂商标记式埋点共 79 处，经确认保留**（低频、一次性，是排查依据）：
  `[ohoswindow]` 31、`[CPM20251222017870]` 12、`[CPM20251218017238]` 11、`[launchBounds]` 11、
  `[StartWin]` 8、`[shadow]` 4、`[fold]` 1、`[setBounds]` 1。

### 取证脚本的去向（本节此前引用的旧路径已作废）

- `jpeg_probe.js`（纯 JS 基线 JPEG 解码器）**已迁入技能自带的资源目录**，技能实现自包含：
  `/storage/Users/currentUser/.workbuddy/skills/harmonyos-sdk-downgrade-compat/assets/jpeg_probe.js`
  —— 第十七节内引用该工具的旧路径已就地替换为新路径。
- `sample_bench.js` / `sample_bench2.js` / `sample_equiv.js` 与**已删除的取色方案**是同一批产物，
  一并移除；它们测出的结论（分析耗时 3.10 ms → 1.25 ms、readPixels 2.29 MB → 0.48 MB、
  等价性 21 个场景全通过）保留在第十七节，结论不受影响。

**回退**：本轮全部是删除可再生成的产物与临时脚本，无需回退。唯一不可再生的
`EchoMusic-OHOS-DevEco-Project.zip` 已按上面的方式把有价值部分留档。
