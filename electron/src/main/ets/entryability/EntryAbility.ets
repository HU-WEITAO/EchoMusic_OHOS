// Copyright (c) 2024 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { image } from '@kit.ImageKit';
import commonEventManager from '@ohos.commonEventManager';
import hilog from '@ohos.hilog';
import { emitter } from '@kit.BasicServicesKit';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';

import { WebAbility } from 'web_engine';

/** 原生层 → ArkTS：播放状态外发事件（JSON 数据） */
const EVENT_STATE = 'echomusic.mc.state';
/** ArkTS → 原生层：播控命令回传事件（纯文本数据） */
const EVENT_CMD = 'echomusic.mc.cmd';
/**
 * 本应用包名（订阅过滤 / 长时任务 WantAgent / 日志用）。
 *
 * ★ 2026-10-04 改为运行时填充，**不要再写死字面量**。
 *
 * 此前是 `const BUNDLE_NAME = 'com.example.echomusic'`，改包名后没跟着改，
 * 直接导致「媒体实况窗 + 播控中心一起消失」，且**后台保活也失效**：
 *   - L~171 `publisherBundleName: BUNDLE_NAME`：状态事件是本应用自己发的，
 *     订阅方却指向一个不存在的包 ⇒ 收不到事件 ⇒ `setAVMetadata` /
 *     `setAVPlaybackState` 全部不上报 ⇒ 实况窗没有内容、播控中心空白；
 *   - `wants: [{ bundleName: BUNDLE_NAME }]`：AUDIO_PLAYBACK 长时任务的
 *     WantAgent 指向旧包 ⇒ 目标 Ability 不存在 ⇒ 后台保活申请失败。
 * 桌面歌词依赖同一条系统链路，因此也一并失效（三个现象同一个根因）。
 *
 * 现在在 `onCreate` 里从 `context.abilityInfo.bundleName` 取真值。
 * 该字段自 API 9 起提供，取的是**最终生效的 bundleName**（即
 * `AppScope/app.json5` 与 `build-profile.json5` 里 product 级那个），
 * 以后再改包名也不会失配。取不到时兜底为 `''`（订阅的 publisherBundleName
 * 传空串表示不限定发布方，比写错一个包名更安全）。
 */
let BUNDLE_NAME: string = '';
const TAG = 'MediaBridge';

/**
 * 媒体传输类命令的去重窗口（毫秒）。
 *
 * 系统播控中心有可能把一次点击投递成多条命令（或用户连击）。重复命令会让应用
 * 一次跳好几首 —— 表现为「播控中心切下一首直接乱跳」，且最终显示的曲目与软件
 * 内实际播放的不一致。同一命令在窗口期内只放行第一条。
 * 注意 seek 不走这个逻辑：拖动进度条本就可能连续发送。
 */
const TRANSPORT_CMD_DEDUP_MS = 300;

export default class EntryAbility extends WebAbility {
  private mediaSession: AVSessionManager.AVSession | undefined = undefined;
  private stateSubscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  /** 最近一次播放状态（timeline 事件只带进度，需与状态合并上报） */
  private lastState: AVSessionManager.PlaybackState = AVSessionManager.PlaybackState.PLAYBACK_STATE_INITIAL;
  private lastPosition: number = 0;
  private lastUpdateTime: number = 0;
  /** 上一条媒体传输命令及其到达时间（用于抑制重复投递导致的「一次跳好几首」） */
  private lastTransportCmd: string = '';
  private lastTransportCmdAt: number = 0;
  /** 状态栏（托盘）同步状态 */
  private trayReady: boolean = false;
  private trayIsPlaying: boolean = false;
  private trayLyricVisible: boolean = false;
  private trayHoverText: string = '';
  /** 已成功下发的菜单标题（menuCode → title），用于变化检测，避免无效更新触发系统限流 */
  private traySentTitles: Map<string, string> = new Map();
  /** 限流重试定时器句柄（-1 = 无挂起重试） */
  private traySyncRetryTimer: number = -1;
  /** 状态栏能力检测重试次数 */
  private traySetupRetries: number = 0;
  /** 长时任务（AUDIO_PLAYBACK）当前是否已申请：退后台保活 + 媒体实况窗的前置条件 */
  private continuousTaskActive: boolean = false;
  /** 长时任务绑定的 wantAgent（通知卡片点击回到应用），首次申请时创建并复用 */
  private continuousTaskWantAgent: WantAgent | undefined = undefined;
  /** 长时任务同步去抖定时器句柄（-1 = 无挂起） */
  private continuousTaskSyncTimer: number = -1;
  /** 去抖等待期内待同步的目标播放态 */
  private pendingContinuousTaskPlaying: boolean = false;
  /** 是否存在待同步的长时任务目标态 */
  private continuousTaskSyncPending: boolean = false;

  onConfigurationUpdate(config: Configuration) {
    super.onConfigurationUpdate(config);
    // 系统深浅色切换 → 实时同步主进程（窗口背景 / 渲染层主题跟随）
    // 注意：必须用回调参数 config——this.context.config 此刻可能还是旧值，
    // 用旧值会把刚切换的主题又改回去（表现为「不跟随系统」）。
    this.publishColorMode(config.colorMode);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    super.onCreate(want, launchParam);
    // 必须在 setupMediaSessionBridge() 之前赋值：订阅的 publisherBundleName
    // 与长时任务 WantAgent 都要用它。取最终生效的 bundleName，改包名自动跟随。
    try {
      // ★ 用 `abilityInfo.bundleName` 而不是 `applicationInfo.bundleName` ——
      //   后者在 API 23 的 ApplicationInfo 上不存在，编译直接报
      //   "Property 'bundleName' does not exist on type 'ApplicationInfo'"。
      //   AbilityInfo.bundleName 自 API 9 起就有，工程内 `ElectronAppAdapter.ets:170`
      //   的 distributedDeviceManager 也是这么取的，两处保持一致。
      BUNDLE_NAME = this.context.abilityInfo.bundleName;
      hilog.info(0x0000, TAG, `bundleName resolved = ${BUNDLE_NAME}`);
    } catch (e) {
      BUNDLE_NAME = '';
      hilog.warn(0x0000, TAG,
        `resolve bundleName failed, fallback to empty: ${(e as BusinessError).message}`);
    }
    this.setupMediaSessionBridge();
    this.setupStatusBarIcon();
    this.publishColorMode();
  }

  /**
   * 系统深浅色 → 主进程（壳层 nativeTheme 不感知系统主题，经 CommonEvent 桥同步）。
   * @param mode 指定模式（onConfigurationUpdate 必须传回调参数）；缺省读 context.config
   */
  private publishColorMode(mode?: ConfigurationConstant.ColorMode): void {
    try {
      const effective = mode !== undefined ? mode : this.context.config?.colorMode;
      hilog.info(0x0000, TAG, `publishColorMode mode=${effective}`);
      if (effective === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        this.publishCmd('colormode:dark');
      } else if (effective === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
        this.publishCmd('colormode:light');
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, `publishColorMode failed: ${(e as BusinessError).message}`);
    }
  }

  /**
   * 真实媒体会话（含桌面歌词）。
   *
   * 桌面歌词组件只能由 ArkTS 独有 API（enableDesktopLyric / setDesktopLyricVisible）
   * 启用，NDK 层做不到，因此 AVSession 在壳层创建：
   *   - 原生 addon（echo-media-controls）通过 CommonEvent(EVENT_STATE) 外发
   *     元数据 / 播放状态 / 进度，这里转成会话上报；
   *   - 会话控制命令（播放 / 暂停 / 上下曲 / 定位）通过 CommonEvent(EVENT_CMD)
   *     回传原生层，走既有 TSFN → 渲染层链路。
   */
  private async setupMediaSessionBridge(): Promise<void> {
    try {
      const session: AVSessionManager.AVSession =
        await AVSessionManager.createAVSession(this.context, 'echomusic.media', 'audio');
      this.mediaSession = session;

      // ---- 控制命令 → 回传原生层 ----
      // 1.0.0 移除了每条命令的 hilog.info：播控是高频事件，正式版会刷屏。
      // 排查投递链路请看渲染层日志与主进程 `[MediaControls] System media event:`。
      session.on('play', () => {
        this.publishTransportCmd('play');
      });
      session.on('pause', () => {
        this.publishTransportCmd('pause');
      });
      session.on('playNext', () => {
        this.publishTransportCmd('next');
      });
      session.on('playPrevious', () => {
        this.publishTransportCmd('previous');
      });
      session.on('seek', (time: number) => {
        this.publishCmd(`seek:${time}`);
      });
      session.on('fastForward', () => {
        this.publishTransportCmd('fastforward');
      });
      session.on('rewind', () => {
        this.publishTransportCmd('rewind');
      });

      // ---- 桌面歌词（ArkTS 独有能力）----
      try {
        const supported: boolean = await AVSessionManager.isDesktopLyricSupported();
        hilog.info(0x0000, TAG, `desktopLyricSupported=${supported}`);
        if (supported) {
          session.onDesktopLyricVisibilityChanged((visible: boolean) => {
            this.trayLyricVisible = visible;
            // 回传原生层 → 渲染层，同步应用内「开启桌面歌词」开关状态
            this.publishCmd(`lyricvisible:${visible ? 1 : 0}`);
          });
          await session.enableDesktopLyric(true);
          hilog.info(0x0000, TAG, 'desktop lyric ENABLED');
          // 注意：这里不再强制 setDesktopLyricVisible(true)。
          // 初始可见性以应用内持久化开关为准：渲染层启动后（initDesktopLyricSync）
          // 会按应用内开关状态主动推 show/hide，再由本文件 applyLyricVisible 落到系统。
          // 强制显示会导致「应用内 OFF / 系统悬浮窗仍显示」的初始状态不一致。
        }
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(0x0000, TAG, `desktop lyric setup failed: code=${err.code} msg=${err.message}`);
      }

      // ---- 原生层状态事件 → 会话上报 ----
      const info: commonEventManager.CommonEventSubscribeInfo = {
        events: [EVENT_STATE],
        publisherBundleName: BUNDLE_NAME
      };
      const subscriber: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber(info);
      this.stateSubscriber = subscriber;
      commonEventManager.subscribe(subscriber, (err, data) => {
        if (err) {
          hilog.error(0x0000, TAG, `state event error: ${JSON.stringify(err)}`);
          return;
        }
        this.applyStateEvent(data);
      });

      await session.activate();
      hilog.info(0x0000, TAG, `media session ready: echomusic.media bundle=${BUNDLE_NAME}`);
      // 「退后台继续播放 / 媒体实况窗」的真正开关在 electron/src/main/module.json5：
      //   abilities[EntryAbility].backgroundModes = ["audioPlayback"]
      //   requestPermissions 含 ohos.permission.KEEP_BACKGROUND_RUNNING（配合长时任务申请）
      // 原代码在此额外调用 session.setBackgroundPlayMode(avSession.BackgroundPlayMode.
      // ENABLE_BACKGROUND_PLAY) 以「显式对齐官方指引」，且其注释本身已说明 audio 类型
      // 会话默认即为 ENABLE_BACKGROUND_PLAY。该接口为 API 26 新增，本工程降到 API 23
      // 编译后其类型声明不存在（ArkTS 报 "Property 'setBackgroundPlayMode' does not exist
      // on type 'AVSession'"），故移除；回到 API 26 工具链时可恢复此调用。
      hilog.info(0x0000, TAG, 'background play: backgroundModes=audioPlayback + continuous task');
      // 主进程事件回调此时必然已注册，补发一次系统深浅色（onCreate 时发出可能被丢弃）
      this.publishColorMode();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `bridge setup failed: code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * PC 状态栏（托盘）图标：后台播放入口。
   *
   * 图标双色（深色壁纸用白、浅色壁纸用黑）；左键点击 → 显示主窗口；
   * 右键菜单：播放/暂停、上一首、下一首、桌面歌词开关、显示主窗口、退出。
   * 菜单点击经 rightMenuClick 事件回传原生层（CommonEvent EVENT_CMD），
   * 由 Rust 层 parse_and_emit_cmd → 主进程/渲染层既有链路处理。
   */
  private async setupStatusBarIcon(): Promise<void> {
    try {
      // 原代码先调用 statusBarManager.isStatusBarCapabilitySupported() 探测状态栏能力是否
      // 就绪，不就绪则 2s × 3 次延迟重试。该探针为 API 26 新增，API 23 的 d.ts 无此声明，
      // 故改为「直接下发 + 失败重试」：同样的 2s × 3 次重试挪到 addToStatusBar 的错误回调
      // （scheduleTraySetupRetry），语义一致且不依赖新接口。
      const white = await this.loadPixelMap('statusbar_icon_white.png');
      const black = await this.loadPixelMap('statusbar_icon_black.png');
      const item: statusBarManager.StatusBarItem = {
        icons: { white: white, black: black },
        // abilityName 传空串：左键点击不走扩展弹窗，由 statusBarIconClick 事件处理
        quickOperation: { title: 'EchoMusic', height: 1, abilityName: '' },
        hoverTips: 'EchoMusic'
      };

      // StatusBarGroupMenu 是「分组数组」：外层数组的每个元素是一组菜单（一级项数组）。
      // 2026-10-04 起自定义菜单项全部移除（见 trayMenuEntries 的说明），为空时**不下发**
      // statusBarGroupMenu 字段，避免传出 `[[]]` 这种空分组。
      if (this.trayMenuEntries().length > 0) {
        item.statusBarGroupMenu = [this.buildTrayMenuGroup()];
      }

      statusBarManager.addToStatusBar(this.context, item, (err) => {
        if (err) {
          hilog.error(0x0000, TAG, `addToStatusBar failed: code=${err.code} msg=${err.message}`);
          // 冷启动过早调用时系统能力可能尚未就绪（原实现靠 isStatusBarCapabilitySupported
          // 探针识别，该探针 API 23 无声明）→ 延迟重试，最多 3 次
          this.scheduleTraySetupRetry();
          return;
        }
        this.trayReady = true;
        // 记录初始菜单标题（与 addToStatusBar 下发的完全一致），供变化检测基线
        this.rememberTrayTitles();
        hilog.info(0x0000, TAG, 'status bar icon added');
      });

      // 左键点击图标 → 显示主窗口
      statusBarManager.on('statusBarIconClick', () => {
        this.publishCmd('show');
      });
      // 右键菜单点击 → 按菜单码分发
      statusBarManager.on('rightMenuClick', (data: emitter.EventData) => {
        let code = '';
        try {
          const payload = data.data as Record<string, Object>;
          code = payload?.menuCode as string ?? '';
        } catch (e) {
          hilog.error(0x0000, TAG, `rightMenuClick parse failed: ${(e as BusinessError).message}`);
        }
        this.handleTrayMenu(code);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `status bar setup failed: code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 右键菜单一级项定义：[菜单码, 标题]。
   *
   * 2026-10-04 全部移除，返回空数组 ⇒ 状态栏右键不再下发任何自定义菜单项。
   *
   * 移除的两类项及原因：
   *
   * 1. 「播放/暂停」「上一首」「下一首」
   *    与系统媒体实况窗（状态栏胶囊 / 播控中心 / 锁屏页）的控制重复。
   *    更关键的是：鸿蒙的状态栏菜单项**必须**填 `menuAction.abilityName`（d.ts 里
   *    Optional=No，语义是「点击时触发的 Ability 名」），点了就会把 Ability 拉起 ——
   *    即便额外带上 `notifyOnly: true` + `menuCode`（只保证额外派发 `rightMenuClick`）
   *    也拦不住。结果就是「点暂停反而把最小化的应用弹出来」。
   *    既然播控中心已经能完整控制，这三项没有保留价值，直接去掉最干净。
   *
   * 2. 「开启/关闭桌面歌词」
   *    桌面歌词在鸿蒙上是 AVSession 的系统级能力（`isDesktopLyricSupported` /
   *    `enableDesktopLyric`），由系统媒体实况窗自己管理，菜单里再放开关属于重复。
   *
   * 保留项：无。系统会在菜单末尾自动附加一个「退出」按钮，不需要我们自己加。
   *
   * 相关代码（`handleTrayMenu` 的 `toggle`/`previous`/`next`/`lyric` 分支、
   * `trayIsPlaying` / `trayLyricVisible` 字段、`buildTrayMenuItem`）全部保留，
   * 将来要恢复菜单项，把条目加回这个数组即可。
   */
  private trayMenuEntries(): Array<Array<string>> {
    return [];
  }

  /** 把当前菜单标题记为「已下发」基线（与下发的菜单内容保持一致，供变化检测） */
  private rememberTrayTitles(): void {
    const entries: Array<Array<string>> = this.trayMenuEntries();
    for (let i = 0; i < entries.length; i++) {
      this.traySentTitles.set(entries[i][0], entries[i][1]);
    }
  }

  /**
   * 构造单个右键菜单项。
   *
   * 菜单码必须挂在 `menuAction.menuCode` 上：API 26 的 `StatusBarMenuItem` 也允许项级
   * `menuCode`，但 API 23 的 d.ts 只在 `StatusBarMenuAction` 上有该字段（本工程
   * web_engine 的 `StatusBarManager.transformMenuItem` 同样如此），而 `rightMenuClick`
   * 事件回传的 `payload.menuCode` 正是取自这里。
   *
   * ★ `abilityName` 不能置空（2026-10-04 实测）
   *
   * `StatusBarMenuAction.abilityName` 必填（d.ts Optional=No），语义是
   * 「菜单项点击时**触发的**应用 Ability 名」。曾尝试置空以表达「点了别拉起」，
   * 结果系统照样去解析目标、解析不到就弹「暂无可用打开方式」，整个菜单失效。
   * `notifyOnly: true` + `menuCode` 只额外派发 `rightMenuClick`，**不阻止**拉起。
   *
   * 当前 `trayMenuEntries()` 返回空数组，本方法不会被调用，保留仅为将来恢复菜单项时可用。
   */
  private buildTrayMenuItem(code: string, title: string): statusBarManager.StatusBarMenuItem {
    const menuAction: statusBarManager.StatusBarMenuAction = {
      abilityName: 'EntryAbility',
      moduleName: 'electron',
      notifyOnly: true,
      menuCode: code
    };
    const menuItem: statusBarManager.StatusBarMenuItem = {
      title: title,
      menuAction: menuAction
    };
    return menuItem;
  }

  /** 构造「一组」菜单（statusBarGroupMenu 外层数组的一个元素） */
  private buildTrayMenuGroup(): statusBarManager.StatusBarGroupMenu {
    const entries: Array<Array<string>> = this.trayMenuEntries();
    const items: Array<statusBarManager.StatusBarMenuItem> = [];
    for (let i = 0; i < entries.length; i++) {
      items.push(this.buildTrayMenuItem(entries[i][0], entries[i][1]));
    }
    return items;
  }

  /** addToStatusBar 失败后延迟重试（2s，最多 3 次）：替代 API 26 才有的状态栏能力探针 */
  private scheduleTraySetupRetry(): void {
    if (this.traySetupRetries >= 3) {
      hilog.warn(0x0000, TAG, `status bar setup gave up after ${this.traySetupRetries} retries`);
      return;
    }
    this.traySetupRetries++;
    setTimeout(() => {
      this.setupStatusBarIcon();
    }, 2000);
  }

  /** 状态栏右键菜单分发 */
  private handleTrayMenu(code: string): void {
    switch (code) {
      case 'toggle':
        // 传输类命令统一走 publishTransportCmd：与播控中心同一条去重规则，
        // 避免状态栏菜单被连点、或与播控中心同时投递时一次跳好几首。
        this.publishTransportCmd(this.trayIsPlaying ? 'pause' : 'play');
        break;
      case 'previous':
        this.publishTransportCmd('previous');
        break;
      case 'next':
        this.publishTransportCmd('next');
        break;
      case 'lyric':
        this.publishCmd(`lyricvisible:${this.trayLyricVisible ? 0 : 1}`);
        this.trayLyricVisible = !this.trayLyricVisible;
        this.syncTrayMenuItems();
        break;
      case 'quit':
        this.publishCmd('quit');
        break;
      default:
        break;
    }
  }

  /** 从 rawfile 加载状态栏图标 PixelMap */
  private async loadPixelMap(name: string): Promise<image.PixelMap> {
    const mgr = this.context.resourceManager;
    const content = await mgr.getRawFileContent(name);
    const source = image.createImageSource(content.buffer as ArrayBuffer);
    const pixelMap = await source.createPixelMap();
    await source.release();
    return pixelMap;
  }

  /** 播放状态 / 歌词状态变化 → 更新右键菜单「播放/暂停」「开关桌面歌词」标题 */
  private syncTrayMenuItems(): void {
    if (!this.trayReady) {
      return;
    }
    const entries: Array<Array<string>> = this.trayMenuEntries();
    // 变化检测：所有标题都没变就不调用，避免无效更新触发系统限流（1010710003）
    let changed: boolean = false;
    for (let i = 0; i < entries.length; i++) {
      if (this.traySentTitles.get(entries[i][0]) !== entries[i][1]) {
        changed = true;
        break;
      }
    }
    if (!changed) {
      return;
    }
    // 原实现逐项调用 updateStatusBarMenuItem（API 26 新增，API 23 的 d.ts 无此声明），
    // 改用 API 23 就有的 updateStatusBarMenu 一次性下发「整组」菜单，顺带绕开限流问题：
    // 原本「播放/暂停」与「歌词开关」总是成对更新，第二发几乎必然撞 1010710003 被静默
    // 丢弃——这正是「开启桌面歌词后菜单标题不翻转」的根因；现在两个标题在同一次调用里
    // 一起生效。
    const menus: statusBarManager.StatusBarGroupMenu[] = [this.buildTrayMenuGroup()];
    statusBarManager.updateStatusBarMenu(this.context, menus, (err) => {
      if (err) {
        if (err.code === 1010710003) {
          // 调用过于频繁：延迟重试
          this.scheduleTrayMenuRetry();
        } else if (err.code !== 1010710006) {
          hilog.warn(0x0000, TAG, `updateStatusBarMenu failed: code=${err.code} msg=${err.message}`);
        }
        return;
      }
      this.rememberTrayTitles();
    });
  }

  /** 限流后延迟重试菜单更新（600ms，单飞） */
  private scheduleTrayMenuRetry(): void {
    if (this.traySyncRetryTimer >= 0) {
      return;
    }
    this.traySyncRetryTimer = setTimeout(() => {
      this.traySyncRetryTimer = -1;
      this.syncTrayMenuItems();
    }, 600);
  }

  /** 曲目元数据变化 → 更新状态栏图标 hover 提示 */
  private syncTrayHoverTips(title: string, artist: string): void {
    if (!this.trayReady) {
      return;
    }
    const tips = artist && artist.length > 0 ? `${title} - ${artist}` : title;
    if (tips === this.trayHoverText || tips.length === 0) {
      return;
    }
    if (tips.length > 128) {
      return;
    }
    this.trayHoverText = tips;
    statusBarManager.updateStatusBarHoverTips(this.context, tips).catch((err: BusinessError) => {
      if (err.code !== 1010710003) {
        hilog.warn(0x0000, TAG, `updateStatusBarHoverTips failed: code=${err.code} msg=${err.message}`);
      }
    });
  }

  /**
   * 回传一条「媒体传输类」命令（play / pause / next / previous / fastforward / rewind）。
   *
   * 与 publishCmd 的唯一区别是做去重：同一命令在 TRANSPORT_CMD_DEDUP_MS 内重复到达
   * 只放行第一条。系统播控中心把一次点击投递成多条、或用户连击时，重复命令会让
   * 应用一次跳好几首（表现为「切下一首乱跳」），这里把它压掉。
   *
   * seek 不走此路径：拖动进度条本就可能连续发送多条不同位置的 seek。
   */
  private publishTransportCmd(text: string): void {
    const now: number = Date.now();
    if (text === this.lastTransportCmd && now - this.lastTransportCmdAt < TRANSPORT_CMD_DEDUP_MS) {
      hilog.warn(0x0000, TAG,
        `drop duplicated media cmd '${text}' (+${now - this.lastTransportCmdAt}ms)`);
      return;
    }
    this.lastTransportCmd = text;
    this.lastTransportCmdAt = now;
    this.publishCmd(text);
  }

  /** 回传一条控制命令给原生层（纯文本，详见 ohos.rs 的 parse_and_emit_cmd） */
  private publishCmd(text: string): void {
    const pubData: commonEventManager.CommonEventPublishData = { data: text };
    commonEventManager.publish(EVENT_CMD, pubData, (err) => {
      if (err) {
        hilog.error(0x0000, TAG, `publishCmd ${text} failed: ${JSON.stringify(err)}`);
      }
    });
  }

  /** 应用原生层外发的一条状态事件（JSON：{type: metadata|playstate|timeline, ...}） */
  private applyStateEvent(data: commonEventManager.CommonEventData): void {
    const session = this.mediaSession;
    if (!session || !data.data) {
      return;
    }
    try {
      const obj: Record<string, Object> = JSON.parse(data.data) as Record<string, Object>;
      const type: string = obj.type as string;
      if (type === 'metadata') {
        this.applyMetadata(obj);
      } else if (type === 'playstate') {
        this.lastState = obj.state as AVSessionManager.PlaybackState;
        this.applyPlaybackState();
      } else if (type === 'timeline') {
        this.lastPosition = obj.positionMs as number;
        this.lastUpdateTime = obj.updateTime as number;
        this.applyPlaybackState();
      } else if (type === 'lyricVisible') {
        this.applyLyricVisible((obj.visible as number) === 1);
      } else if (type === 'immersive') {
        // 渲染层沉浸取色：状态栏 / 小横条区域背景与界面主背景同色
        AppStorage.setOrCreate('immersiveTopColor', obj.top as string);
        AppStorage.setOrCreate('immersiveBottomColor', obj.bottom as string);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, `applyStateEvent parse failed: ${(e as BusinessError).message}`);
    }
  }

  /** 全量元数据上报（桌面歌词的 LRC 也随 metadata 下发） */
  private applyMetadata(obj: Record<string, Object>): void {
    const session = this.mediaSession;
    if (!session) {
      return;
    }
    const title: string = obj.title as string;
    const artist: string = obj.artist as string;
    this.syncTrayHoverTips(title && title.length > 0 ? title : 'EchoMusic', artist);
    // assetId 必须能唯一标识「一首歌」。原先只用标题，会让同名歌曲（不同歌手 /
    // 翻唱 / 现场版）以及标题为空的多首歌塌成同一个资产；系统是按 assetId 识别
    // 当前媒体的，一旦塌陷，播控中心的条目就会与实际播放曲目错位 —— 这正是
    // 「播控中心和软件内播放歌曲不一样」的典型成因。这里补上歌手做区分。
    const displayTitle: string = title && title.length > 0 ? title : 'EchoMusic';
    const assetId: string = title && title.length > 0
      ? (artist && artist.length > 0 ? `${title} - ${artist}` : title)
      : 'echomusic';
    const meta: AVSessionManager.AVMetadata = {
      assetId: assetId,
      title: displayTitle,
      artist: artist,
      album: obj.album as string
    };
    const durationMs: number = obj.durationMs as number;
    if (typeof durationMs === 'number' && durationMs > 0) {
      meta.duration = durationMs;
    }
    if (typeof obj.coverUri === 'string') {
      meta.mediaImage = obj.coverUri as string;
    }
    const skipSeconds: number = obj.skipSeconds as number;
    if (typeof skipSeconds === 'number' && skipSeconds > 0) {
      meta.skipIntervals = skipSeconds;
    }
    if (typeof obj.lyric === 'string') {
      meta.lyric = obj.lyric as string;
    }
    // 切歌时把进度归零并立即补发一次播放状态。
    // timeline 与 metadata 两条事件的到达顺序没有保证：若 metadata 先到、timeline
    // 里还是上一首的进度，播控中心就会拿到「新曲目 + 旧进度」的组合 —— 进度条乱跳、
    // 且看起来与软件内不一致。这里主动清零，让系统先看到 0。
    this.lastPosition = 0;
    this.lastUpdateTime = Date.now();
    this.applyPlaybackState();
    // 1.0.0 移除逐曲的 metadata 成功日志（含歌名）：切歌高频，正式版刷屏
    session.setAVMetadata(meta).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, `setAVMetadata failed: code=${err.code} msg=${err.message}`);
    });
  }

  /** 应用内「开启桌面歌词」开关 → 系统歌词悬浮窗显隐 */
  private applyLyricVisible(visible: boolean): void {
    this.trayLyricVisible = visible;
    // 状态栏菜单「开启/关闭桌面歌词」标题跟随真实状态
    this.syncTrayMenuItems();
    const session = this.mediaSession;
    if (!session) {
      return;
    }
    // 1.0.0 移除 setDesktopLyricVisible 的成功日志：跟随切歌高频触发
    session.setDesktopLyricVisible(visible).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, `setDesktopLyricVisible(${visible}) failed: code=${err.code} msg=${err.message}`);
    });
  }

  /**
   * 长时任务同步去抖（400ms）。
   *
   * 切歌或连续 play-pause 会让播放态在毫秒级来回抖动（实测出现
   * started→stopped→started 间隔仅 5~36ms），直接同步会让 AUDIO_PLAYBACK
   * 长时任务被反复取消/重建；系统每次取消都会「通知相关子系统」拆除媒体实况窗，
   * 用户观感就是「有实况窗收回动作但最终不显示」。去抖后只在状态稳定时同步一次。
   */
  private scheduleContinuousTaskSync(playing: boolean): void {
    this.pendingContinuousTaskPlaying = playing;
    this.continuousTaskSyncPending = true;
    if (this.continuousTaskSyncTimer >= 0) {
      clearTimeout(this.continuousTaskSyncTimer);
    }
    this.continuousTaskSyncTimer = setTimeout(() => {
      this.continuousTaskSyncTimer = -1;
      this.continuousTaskSyncPending = false;
      this.updateContinuousTask(this.pendingContinuousTaskPlaying);
    }, 400);
  }

  /** 立即落盘去抖中的长时任务目标态（退后台/退出等关键时机不再等待） */
  private flushContinuousTaskSync(): void {
    if (!this.continuousTaskSyncPending) {
      return;
    }
    if (this.continuousTaskSyncTimer >= 0) {
      clearTimeout(this.continuousTaskSyncTimer);
      this.continuousTaskSyncTimer = -1;
    }
    this.continuousTaskSyncPending = false;
    this.updateContinuousTask(this.pendingContinuousTaskPlaying);
  }

  /**
   * 按播放状态同步 AUDIO_PLAYBACK 长时任务。
   *
   * 官方指引：仅声明 backgroundModes + 接入 AVSession 不足以触发系统媒体实况窗，
   * 退后台前必须申请 AUDIO_PLAYBACK 长时任务；且「暂停时取消、播放时重新申请」，
   * 否则后台无音频播放时系统可能冻结应用/取消任务。
   */
  private updateContinuousTask(playing: boolean): void {
    if (playing === this.continuousTaskActive) {
      return;
    }
    if (playing) {
      this.startContinuousTask();
    } else {
      this.stopContinuousTask();
    }
  }

  /** 申请长时任务（幂等，由 updateContinuousTask 门控） */
  private async startContinuousTask(): Promise<void> {
    try {
      if (!this.continuousTaskWantAgent) {
        const info: wantAgent.WantAgentInfo = {
          wants: [{ bundleName: BUNDLE_NAME, abilityName: 'EntryAbility' }],
          operationType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        this.continuousTaskWantAgent = await wantAgent.getWantAgent(info);
      }
      await backgroundTaskManager.startBackgroundRunning(
        this.context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, this.continuousTaskWantAgent);
      this.continuousTaskActive = true;
      hilog.info(0x0000, TAG, 'continuous task AUDIO_PLAYBACK started');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `startBackgroundRunning failed: code=${err.code} msg=${err.message}`);
    }
  }

  /** 取消长时任务（幂等，由 updateContinuousTask / onDestroy 调用） */
  private async stopContinuousTask(): Promise<void> {
    if (!this.continuousTaskActive) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.continuousTaskActive = false;
      hilog.info(0x0000, TAG, 'continuous task stopped');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, `stopBackgroundRunning failed: code=${err.code} msg=${err.message}`);
    }
  }

  /** 用「最近状态 + 最近进度」合成一次播放状态上报 */
  private applyPlaybackState(): void {
    const session = this.mediaSession;
    if (!session) {
      return;
    }
    // 同步状态栏「播放/暂停」菜单标题（仅在状态翻转时更新，避免频繁调用被限流）
    const playing = this.lastState === AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY;
    if (playing !== this.trayIsPlaying) {
      this.trayIsPlaying = playing;
      this.syncTrayMenuItems();
      // 播放时申请 AUDIO_PLAYBACK 长时任务 / 暂停时取消（实况窗前置条件）
      // 注意：切歌/连续 play-pause 会在毫秒级来回抖动，直接同步会让长时任务被
      // 反复取消重建（系统随之拆除/重建媒体实况窗），故此处做去抖。
      this.scheduleContinuousTaskSync(playing);
    }
    const state: AVSessionManager.AVPlaybackState = {
      state: this.lastState
    };
    if (this.lastUpdateTime > 0) {
      state.position = {
        elapsedTime: this.lastPosition,
        updateTime: this.lastUpdateTime
      };
    }
    session.setAVPlaybackState(state).catch((err: BusinessError) => {
      hilog.error(0x0000, TAG, `setAVPlaybackState failed: code=${err.code} msg=${err.message}`);
    });
  }

  async onPrepareToTerminateAsync(): Promise<boolean> {
    return await super.onPrepareToTerminateAsync();
  }

  async onDestroy(): Promise<void> {
    if (this.continuousTaskSyncTimer >= 0) {
      clearTimeout(this.continuousTaskSyncTimer);
      this.continuousTaskSyncTimer = -1;
    }
    this.continuousTaskSyncPending = false;
    await this.stopContinuousTask();
    if (this.trayReady) {
      try {
        statusBarManager.removeFromStatusBar(this.context);
      } catch (e) {
        hilog.error(0x0000, TAG, `removeFromStatusBar failed: ${(e as BusinessError).message}`);
      }
      this.trayReady = false;
    }
    if (this.stateSubscriber) {
      try {
        commonEventManager.unsubscribe(this.stateSubscriber);
      } catch (e) {
        hilog.error(0x0000, TAG, `unsubscribe failed: ${(e as BusinessError).message}`);
      }
      this.stateSubscriber = undefined;
    }
    if (this.mediaSession) {
      try {
        await this.mediaSession.destroy();
      } catch (e) {
        hilog.error(0x0000, TAG, `session destroy failed: ${(e as BusinessError).message}`);
      }
      this.mediaSession = undefined;
    }
    await super.onDestroy();
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    super.onWindowStageCreate(windowStage);
  }

  onWindowStageDestroy() {
    super.onWindowStageDestroy();
  }

  /**
   * 退后台：媒体实况窗（状态栏胶囊）与后台保活的关键时机。
   * 不等去抖，立即落盘长时任务目标态；若仍在播放而长时任务未申请
   * （状态事件异常丢失），此处补申请。
   */
  onBackground() {
    super.onBackground();
    this.flushContinuousTaskSync();
    if (this.trayIsPlaying && !this.continuousTaskActive) {
      this.startContinuousTask();
    }
  }
};
