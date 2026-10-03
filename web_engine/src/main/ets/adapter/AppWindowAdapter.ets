// Copyright (c) 2024 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import { inject, injectable } from 'inversify';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import bundleManager from '@ohos.bundle.bundleManager';
import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { contextConstant, StartOptions } from '@kit.AbilityKit';
import { display, NodeContent, window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import Want from '@ohos.app.ability.Want';

import { AbilityManager } from '../common/AbilityManager';
import { BaseAdapter } from '../common/BaseAdapter';
import { ConfigData } from '../common/Constants';
import { ContextAdapter } from './ContextAdapter';
import { IStyleData, IUpdateStyle, WindowStyle } from '../common/WindowStyle';
import LaunchHelper from '../utils/LaunchHelper';
import LogMethod from '../common/LogDecorator';
import LogUtil from '../utils/LogUtil';
import { WindowVisibility } from '../utils/WindowVisibility';
import { NewWindowParam, PointCoordinate, WindowType, WindowBound, WindowPreferences, ILoginInfo, ILogin, kAbilityMap, NotificationAdapterImage } from "../interface/CommonInterface"
import { DeviceInfoAdapter } from '../adapter/DeviceInfoAdapter';
import { NativeThemeAdapter } from './NativeThemeAdapter';
import { NodeHandleManager } from '../common/NodeHandleManager';

const TAG: string = 'AppWindow';

/**
 * 启动尺寸兜底：判定「残留的全屏尺寸」的阈值。
 *
 * 背景：应用会把退出时的窗口大小记在本地设置里（rememberWindowSize），而
 * **平板（常规全屏）模式下窗口尺寸就等于整块屏幕**。用户从平板模式切到 PC
 * 自由窗口模式后再启动，就会拿这个「整屏尺寸」去开窗 —— 表现为「一打开就
 * 铺满，只剩状态栏没盖住」，且因为并非最大化状态，「还原」按钮也救不回来，
 * 只能手动拖四个角。同样的整屏尺寸走 setBounds 时也会命中（Electron 侧
 * 「还原最大化状态」正是用整屏尺寸 + setBounds 实现的）。
 *
 * 只在「请求尺寸已基本等于整屏」时才介入，不影响应用记住的正常尺寸。
 * 高度阈值比宽度松：平板模式记录的高度有时已被扣掉状态栏。
 */
const NEARLY_FULL_SCREEN_WIDTH_RATIO: number = 0.97;
const NEARLY_FULL_SCREEN_HEIGHT_RATIO: number = 0.92;
/** 兜底后窗口占屏幕的比例（居中摆放） */
const FALLBACK_LAUNCH_SIZE_RATIO: number = 0.72;

/**
 * 启动几何干预总开关（排查用逃生舱）。
 *
 * 置 true 后：开窗几何预落位、整屏尺寸兜底、setBounds 整屏收敛**全部停用**，
 * 窗口几何完全交回系统。若把这一位打开后平板上不再抖动，说明抖动就来自这套
 * 干预；反之则与它无关，可以专心查避让区/内容边界那条线。
 */
const SAFE_LAUNCH_GEOMETRY: boolean = false;

@injectable()
export class AppWindowAdapter extends BaseAdapter {
  private abilityManager: AbilityManager;
  private bundleName: string = 'com.huawei.ohos_electron';
  private bundleFlags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION |
                        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_METADATA;
  private queryWindowNum: number = 10;  
  private ctxAdapter: ContextAdapter;
  private defaultBackgroundColor: string = '#00000000';
  private loginWindow: window.Window | null = null;
  private deviceInfoAdapter: DeviceInfoAdapter;
  private themeAdapter: NativeThemeAdapter;
  private nodeHandleManager: NodeHandleManager;
  constructor(
    @inject(AbilityManager) abilityManager: AbilityManager,
    @inject(ContextAdapter) ctxAdapter: ContextAdapter,
    @inject(DeviceInfoAdapter) deviceInfoAdapter: DeviceInfoAdapter,
    @inject(NativeThemeAdapter) themeAdapter: NativeThemeAdapter,
    @inject(NodeHandleManager) nodeHandleManager: NodeHandleManager
  ) {
    super();
    this.abilityManager = abilityManager;
    this.ctxAdapter = ctxAdapter;
    this.deviceInfoAdapter = deviceInfoAdapter;
    this.themeAdapter = themeAdapter;
    this.nodeHandleManager = nodeHandleManager;

    try {
      let data = bundleManager.getBundleInfoForSelfSync(this.bundleFlags);
      this.bundleName = data.name;
    } catch (err) {
      let message = (err as BusinessError).message;
      LogUtil.error(TAG, `getBundleInfoForSelfSync failed.: ${message}`);
    }
  }

  private getWindow(id: number): window.Window | undefined {
    return this.abilityManager.getProxy(id)?.getWindow();
  }

  private applyShadow(windowClass: window.Window, id: number, hasShadow: boolean, refresh: boolean) {
    if (deviceInfo.sdkApiVersion < 20) {
      LogUtil.warn(TAG, `[shadow] setWindowShadowEnabled requires API 20, current API is ${deviceInfo.sdkApiVersion}.`);
      return;
    }
    try {
      windowClass.setWindowShadowEnabled(hasShadow)
        .then(() => LogUtil.info(TAG, refresh
          ? `[shadow] Shadow refreshed (re-applied ${hasShadow}), id: ${id}.`
          : `[shadow] Succeeded in setting the window shadow: ${hasShadow}, id: ${id}.`))
        .catch((err: BusinessError) =>
          LogUtil.error(TAG, `[shadow] Failed to ${refresh ? 'refresh' : 'set'} the window shadow, id: ${id}. Cause: ${JSON.stringify(err)}`));
    } catch (err) {
      LogUtil.warn(TAG, `[shadow] setWindowShadowEnabled unavailable, id: ${id}. Cause: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 启动尺寸兜底。
   *
   * 仅当「请求尺寸已基本等于整块屏幕」时才介入，收敛为屏幕 72% 并居中；其余情况
   * 一律原样返回。详见文件头 NEARLY_FULL_SCREEN_* 常量的注释。
   *
   * 判据是「**确证**处于自由窗口/PC 模式」（`isFreeWindowsMode()`），而不是
   * 「不是平板常规模式」。两者差别在 deviceMode 还没同步的时候：那时它是初值
   * kPcMode，双向取反都不成立，用取反当闸门就会在平板上误放行（详见函数内注释）。
   *
   * @param source 调用来源，仅用于日志区分（launch / setBounds）
   */
  private clampNearlyFullScreen(bounds: WindowBound, source: string): WindowBound {
    try {
      // 闸门必须是「**确证**处于自由窗口/PC 模式」，即 isFreeWindowsMode()。
      //
      // 早前这里写过 isNormalWindowMode() 取反，那是错的：deviceMode 还没同步时
      // 初值是 kPcMode（既不是 free 也不是 normal），取反会放行 —— 平板上就会把
      // 系统给的全屏请求当成「残留的整屏尺寸」收敛成 72%，与系统全屏布局来回拉扯
      // （启动极其抖动、页面点不动）。用正向判据后，「模式未知 / 平板常规」一律不干预。
      if (SAFE_LAUNCH_GEOMETRY || !this.deviceInfoAdapter.isFreeWindowsMode()) {
        return bounds;
      }
      const displayInfo = display.getDefaultDisplaySync();
      const screenWidth: number = displayInfo.width;
      const screenHeight: number = displayInfo.height;
      if (!(screenWidth > 0 && screenHeight > 0)) {
        return bounds;
      }
      const nearlyFullScreen: boolean = bounds.width >= screenWidth * NEARLY_FULL_SCREEN_WIDTH_RATIO &&
        bounds.height >= screenHeight * NEARLY_FULL_SCREEN_HEIGHT_RATIO;
      if (!nearlyFullScreen) {
        return bounds;
      }
      const width: number = Math.round(screenWidth * FALLBACK_LAUNCH_SIZE_RATIO);
      const height: number = Math.round(screenHeight * FALLBACK_LAUNCH_SIZE_RATIO);
      const left: number = Math.max(0, Math.round((screenWidth - width) / 2));
      const top: number = Math.max(0, Math.round((screenHeight - height) / 2));
      LogUtil.warn(TAG, `[launchBounds] stale fullscreen size ${bounds.width}x${bounds.height} ` +
        `(screen ${screenWidth}x${screenHeight}), fallback to ${width}x${height} @(${left},${top}), from=${source}`);
      const clamped: WindowBound = { left: left, top: top, width: width, height: height };
      return clamped;
    } catch (err) {
      LogUtil.warn(TAG, `[launchBounds] fallback skipped (${source}): ${JSON.stringify(err)}`);
      return bounds;
    }
  }

  /**
   * 极早落位：把目标几何提前应用到「已存在的同 id 窗口」上。
   *
   * 桌面点击图标启动时，系统已经按 instanceKey（见 WebAbilityStage.onAcceptWant，
   * 冷启动返回 DEFAULT_WINDOW_ID）建好了这一扇窗口；随后 Electron 主进程请求
   * CreateWindow，startAbility 会**命中这个已有实例**，StartOptions 里的
   * windowLeft/Top/Width/Height 被系统丢弃。于是窗口先以系统默认尺寸出现，等
   * Electron 侧再调 SetBounds 才「跳」到应用记住的尺寸 —— 观感正是
   * 「先是一个启动动画，后面又跳出来一个窗口」。
   * 这里在窗口 show（主进程 ready-to-show 才 show）之前把目标几何落下去，
   * 把那次可见跳动消掉；平板常规（全屏）模式下窗口几何由系统决定，不介入。
   */
  private applyBoundsToExistingWindow(windowId: string, bounds: WindowBound, hasFrame: boolean): void {
    try {
      const windowClass = this.abilityManager.getProxy(windowId)?.getWindow();
      if (!windowClass) {
        // 还没有这扇窗口（新实例）→ 几何交给 StartOptions
        return;
      }
      const status = windowClass.getWindowStatus();
      if (status === window.WindowStatusType.MAXIMIZE || status === window.WindowStatusType.FULL_SCREEN) {
        return;
      }
      const prop = windowClass.getWindowProperties();
      const leftBorder: number = hasFrame ? prop?.drawableRect.left || 0 : 0;
      const topBorder: number = hasFrame ? prop?.drawableRect.top || 0 : 0;
      const left: number = bounds.left - leftBorder;
      const top: number = bounds.top - topBorder;
      const width: number = bounds.width + leftBorder + leftBorder;
      const height: number = bounds.height + topBorder + leftBorder;

      // 系统已经在替应用管理主窗矩形（setWindowRectAutoSave 生效）：窗口从被创建
      // 那一刻起就是上次关闭时的矩形，系统启动页与主窗天然同框。此时若照旧
      // move + resize，等于把「启动页 → 主窗口」这段过渡重新拉开 —— 正是用户
      // 抱怨的「两个窗口大小位置不同」。
      //   · 位置：以系统记的为准（用户上次把窗口摆在哪就还在哪），**不移动**；
      //   · 尺寸：两边本就来自同一个窗口，通常已经相等；相等就什么都不做，只有
      //     差异明显（> 2% 且 > 8px）时才 resize 对齐。
      // 例外：窗口当前尺寸已基本等于整屏（系统记忆里混进过整屏尺寸）→ 仍走完整
      // 落位把它收敛回 72% 居中，否则会退回「打开就铺满、只能手动拖角」。
      // 只对主窗（browser1）走这条路：系统尺寸记忆也只对它开启（见
      // WebBaseAbility.enableWindowRectAutoSave）。
      if (windowId === ConfigData.DEFAULT_WINDOW_ID &&
        this.deviceInfoAdapter.isWindowRectAutoSave() && !this.isNearlyFullScreenWindow(windowClass)) {
        const cur = prop.windowRect;
        const sizeDiffers: boolean = Math.abs(cur.width - width) > Math.max(8, width * 0.02) ||
          Math.abs(cur.height - height) > Math.max(8, height * 0.02);
        if (!sizeDiffers) {
          LogUtil.info(TAG, `[launchBounds] window ${windowId} already at ${cur.width}x${cur.height}` +
            `@(${cur.left},${cur.top}) (system-remembered), skip pre-apply`);
          return;
        }
        LogUtil.info(TAG, `[launchBounds] size-only align on ${windowId}: ${cur.width}x${cur.height}` +
          ` -> ${width}x${height}, position kept at (${cur.left},${cur.top})`);
        windowClass.resizeAsync(width, height).catch((err: BusinessError) => {
          LogUtil.warn(TAG, `[launchBounds] pre-apply resize failed: ${JSON.stringify(err)}`);
        });
        return;
      }
      LogUtil.info(TAG, `[launchBounds] pre-apply ${bounds.width}x${bounds.height} ` +
        `@(${bounds.left},${bounds.top}) to existing window ${windowId}`);
      windowClass.moveWindowToAsync(left, top)
        .then(() => {
          windowClass.resizeAsync(width, height).catch((err: BusinessError) => {
            LogUtil.warn(TAG, `[launchBounds] pre-apply resize failed: ${JSON.stringify(err)}`);
          });
        })
        .catch((err: BusinessError) => {
          LogUtil.warn(TAG, `[launchBounds] pre-apply move failed: ${JSON.stringify(err)}`);
        });
    } catch (err) {
      LogUtil.warn(TAG, `[launchBounds] pre-apply skipped: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 窗口**当前真实矩形**是否已基本等于整屏。
   *
   * 只用于回答一个问题：系统记住的那个矩形里，是不是混进了「平板模式下的整屏
   * 尺寸」。是 → 开窗落位照旧完整执行（收敛成 72% 居中）；否 → 说明记忆是正常
   * 的自由窗口矩形，位置交还系统、尺寸只在明显不符时才对齐，
   * 避免把「启动页 → 主窗口」这段过渡重新拉开。
   */
  private isNearlyFullScreenWindow(windowClass: window.Window): boolean {
    try {
      const rect = windowClass.getWindowProperties().windowRect;
      const displayInfo = display.getDefaultDisplaySync();
      if (!(displayInfo.width > 0 && displayInfo.height > 0)) {
        return false;
      }
      return rect.width >= displayInfo.width * NEARLY_FULL_SCREEN_WIDTH_RATIO &&
        rect.height >= displayInfo.height * NEARLY_FULL_SCREEN_HEIGHT_RATIO;
    } catch (err) {
      LogUtil.warn(TAG, `[launchBounds] nearly-fullscreen check skipped: ${JSON.stringify(err)}`);
      return false;
    }
  }

  private backgroundColor(useDarkMode: boolean): string {
    if (useDarkMode || this.themeAdapter.isDarkMode()) {
      return NativeThemeAdapter.DARK_BACKGROUND_COLOR;
    }
    return NativeThemeAdapter.LIGHT_BACKGROUND_COLOR;
  }

  @LogMethod
  createWindow(param: NewWindowParam) {
    LogUtil.info(TAG, `[ohoswindow] in AppWindowAdapter createWindow, param is ${JSON.stringify(param)}`);
    let abilityName: string = kAbilityMap.get(param.ability_type) ?? 'EntryAbility';
    const want: Want = {
      bundleName: this.bundleName,
      abilityName: abilityName,
      parameters: {
        'xcomponentId': param.window_id,
        'windowType': WindowType.MAIN_WINDOW,
        instanceKey: param.window_id,
        'hideTitleBar': param.hide_title_bar,
        'useDarkMode': param.use_dark_mode,
        'minimizable': param.minimizable,
        'maximizable': param.maximizable,
        'closable': param.closable,
        'alwaysOntop': param.always_on_top,
        'resizable': param.resizable,
        'focusable': param.focusable,
        'isModal': param.is_modal,
        'isPanel': param.is_panel,
        'webappWindow': param.app_id
      }
    };

    let windowClass = this.ctxAdapter.getActiveProxy().getWindow();
    const windowProp = windowClass?.getWindowProperties();
    let leftBorder: number = param.hide_title_bar ? 0 : windowProp?.drawableRect.left || 0;
    let topBorder: number = param.hide_title_bar ? 0 : windowProp?.drawableRect.top || 0;
    // 启动尺寸兜底：把「PC 上残留的整屏尺寸」收敛回默认窗口尺寸（仅自由窗口模式生效）
    const launchBounds: WindowBound = this.clampNearlyFullScreen(param.bounds, 'launch');
    // 若这一扇窗口已经存在（桌面冷启动那一次），趁它还没 show，先把目标几何落下去，
    // 避免「先默认尺寸 → 再 setBounds 跳到目标尺寸」的可见跳动。
    // 闸门同样用正向判据 isFreeWindowsMode()：平板常规（全屏）模式与「模式未知」都
    // 绝不 move/resize 窗口 —— 启动窗口动画期间动它，观感就是整屏抖动、点不动。
    // 面板/模态窗尺寸由系统或应用另行决定，也跳过。
    const canMoveLaunchWindow: boolean = !SAFE_LAUNCH_GEOMETRY &&
      this.deviceInfoAdapter.isFreeWindowsMode() && !param.is_panel && !param.is_modal;
    LogUtil.info(TAG, `[launchBounds] window_id=${param.window_id}, panel=${param.is_panel},` +
      ` modal=${param.is_modal}, safe=${SAFE_LAUNCH_GEOMETRY},` +
      ` freeWindowMode=${this.deviceInfoAdapter.isFreeWindowsMode()},` +
      ` normalWindowMode=${this.deviceInfoAdapter.isNormalWindowMode()},` +
      ` rectAutoSave=${this.deviceInfoAdapter.isWindowRectAutoSave()},` +
      ` requested=${param.bounds.width}x${param.bounds.height}@(${param.bounds.left},${param.bounds.top}),` +
      ` launch=${launchBounds.width}x${launchBounds.height}@(${launchBounds.left},${launchBounds.top}),` +
      ` preApply=${canMoveLaunchWindow}`);
    if (canMoveLaunchWindow) {
      this.applyBoundsToExistingWindow(param.window_id, launchBounds, !param.hide_title_bar);
    }
    let imagePixelMap: image.PixelMap;
    let color = new ArrayBuffer(0);

    image.createPixelMap(color, {
      size: {
        height: launchBounds.height + leftBorder + topBorder,
        width: launchBounds.width + leftBorder + leftBorder,
      }
    }).then((data) => {
      imagePixelMap = data;
      let options: StartOptions = {
        processMode: contextConstant.ProcessMode.ATTACH_TO_STATUS_BAR_ITEM,
        startupVisibility: param.show ? contextConstant.StartupVisibility.STARTUP_SHOW : contextConstant.StartupVisibility.STARTUP_HIDE,
        windowLeft: launchBounds.left - leftBorder,
        windowTop: launchBounds.top - topBorder,
        windowWidth: launchBounds.width + leftBorder + leftBorder,
        windowHeight: launchBounds.height + leftBorder + topBorder,
        startWindowIcon: imagePixelMap,
        startWindowBackgroundColor: this.backgroundColor(param.use_dark_mode)
      }
      if (param.is_panel) {
        options.windowMode = AbilityConstant.WindowMode.WINDOW_MODE_FULLSCREEN;
      }
      if (param.display_id != -1) {
        options.displayId = param.display_id;
      }
      LaunchHelper.LaunchWithOptions(this.ctxAdapter.getActiveContext(), want, options);
    })
  }

  @LogMethod
  closeWindow(id: number) {
    let context = this.abilityManager.getProxy(id)?.getWindowContext() as common.UIAbilityContext;
    context?.terminateSelf()
      .catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to close window. Cause: ' + JSON.stringify(err));
      });
  }

  @LogMethod
  setMaximizable(id: number, maximizable: boolean) {
    let proxy = this.abilityManager.getProxy(id);
    let preferences: WindowPreferences | undefined = proxy?.getWindowPreferences();
    if (preferences) {
      preferences.maximizable = maximizable;
      proxy?.setWindowPreferences(preferences);
      if (!preferences.hideTitleBar && !this.deviceInfoAdapter.isNormalWindowMode())
        proxy?.getWindow()?.setWindowTitleButtonVisible(preferences.maximizable, preferences.minimizable, preferences.closable);
    }
    // 不得在此调用 setSupportedWindowModes：该接口会把窗口支持模式掩码由系统
    // 默认 127 改写为 15，系统据此把窗口归入「PC 应用窗口」分支，回桌面只做窗口
    // 最小化，不产生 ability 退后台（BackgroundLifecycle），媒体实况窗被
    // 「事件落地页在前台则无胶囊」规则抑制。
    // 窗口模式统一由 module.json5 的 supportWindowMode 声明，运行期不再收窄。
  }

  @LogMethod
  setMinimizable(id: number, minimizable: boolean) {
    let proxy = this.abilityManager.getProxy(id);
    let preferences: WindowPreferences | undefined = proxy?.getWindowPreferences();
    if (preferences) {
      preferences.minimizable = minimizable;
      proxy?.setWindowPreferences(preferences);
      if (!preferences.hideTitleBar && !this.deviceInfoAdapter.isNormalWindowMode())
        proxy?.getWindow()?.setWindowTitleButtonVisible(preferences.maximizable, preferences.minimizable, preferences.closable);
    }
  }

  @LogMethod
  setClosable(id: number, closable: boolean) {
    let proxy = this.abilityManager.getProxy(id);
    let preferences: WindowPreferences | undefined = proxy?.getWindowPreferences();
    if (preferences) {
      preferences.closable = closable;
      proxy?.setWindowPreferences(preferences);
      if (!preferences.hideTitleBar && !this.deviceInfoAdapter.isNormalWindowMode())
        proxy?.getWindow()?.setWindowTitleButtonVisible(preferences.maximizable, preferences.minimizable, preferences.closable);
    }
  }

  @LogMethod
  setWindowButtonVisibility(id: number, visible: boolean) {
    let proxy = this.abilityManager.getProxy(id);
    let preferences: WindowPreferences | undefined = proxy?.getWindowPreferences();
    if (preferences) {
      preferences.maximizable = visible;
      preferences.minimizable = visible;
      preferences.closable = visible;
      proxy?.setWindowPreferences(preferences);
      if (!this.deviceInfoAdapter.isNormalWindowMode())
        proxy?.getWindow()?.setWindowTitleButtonVisible(preferences.maximizable, preferences.minimizable, preferences.closable);
    }
  }

  @LogMethod
  getWindowButtonVisibility(id: number): boolean {
    let proxy = this.abilityManager.getProxy(id);
    let preferences: WindowPreferences | undefined = proxy?.getWindowPreferences();
    if (preferences) {
      return preferences.maximizable || preferences.minimizable || preferences.closable;
    }
    return false;
  }

  @LogMethod
  setAlwaysOnTop(id: number, onTop: boolean) {
    let windowClass = this.getWindow(id);
    let promise = windowClass?.setWindowTopmost(onTop);
    promise?.then(() => {
      LogUtil.info(TAG, `Succeeded in setting the window to be topmost.`);
    }).catch((err: BusinessError) => {
      LogUtil.error(TAG, `Failed to set the window to be topmost. Cause code: ${err.code}, message: ${err.message}`);
    });
  }

  @LogMethod
  showWindow(id: number) {
    LogUtil.info(TAG, `[ohoswindow] in AppWindowAdapter showWindow, id is ${id}`);
    // 冗余 show 抑制：窗口已经在屏幕上时，再来一次 showAbility() 对结果毫无贡献，只会让
    // 系统**重放一遍窗口打开动效** —— 实测每秒 24 次，窗口因此永远停在开场动效的某一帧
    // （截图里窗口是倾斜的、每张位置都不同），即「在屏幕上乱蹦、根本没法用」。
    // 判定依据与规则见 utils/WindowVisibility.ts。
    if (WindowVisibility.shouldSkipShow(id)) {
      return;
    }
    let context = this.abilityManager.getProxy(id)?.getWindowContext() as common.UIAbilityContext;
    context?.showAbility().then(() => {
      WindowVisibility.noteVisible('showAbility');
      LogUtil.info(TAG, `showAbility success`);
    }).catch((err: BusinessError) => {
      LogUtil.error(TAG, '[ohoswindow] Failed to showAbility. Cause:' + JSON.stringify(err));
    });
  }

  @LogMethod
  hideWindow(id: number) {
    // 冗余 hide 抑制：系统已经报告窗口不可见时，再 hide 一次没有意义（与 showWindow 同一套规则）。
    if (WindowVisibility.shouldSkipHide(id, 'hideWindow')) {
      return;
    }
    let context = this.abilityManager.getProxy(id)?.getWindowContext() as common.UIAbilityContext;
    context?.hideAbility().then(() => {
      WindowVisibility.noteHidden('hideAbility');
      LogUtil.info(TAG, `hideAbility success`);
    }).catch((err: BusinessError) => {
      LogUtil.error(TAG, `hideAbility fail, err: ${JSON.stringify(err)}`);
    });
  }

  @LogMethod
  activateWindow(id: number) {
    LogUtil.info(TAG, `[ohoswindow] in AppWindowAdapter activateWindow, id is ${id}`);
    this.showWindow(id);
  }

  @LogMethod
  setFullScreen(fullScreen: boolean, id: number) {
    if (fullScreen) {
      let windowClass = this.getWindow(id);
      if (!windowClass) {
        LogUtil.error(TAG, 'Failed to obtain the main window.');
        return;
      }

      if (this.deviceInfoAdapter.isNormalWindowMode()) {
        this.abilityManager.getProxy(id)?.updateAvoidAreaStatus(true);
      }

      windowClass.maximize(window.MaximizePresentation.ENTER_IMMERSIVE)
      .catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to maximize the window. Cause:' + JSON.stringify(err));
      });
    } else {
      this.unMaximize(id);
    }
  }

  @LogMethod
  setSimpleFullScreen(fullScreen: boolean, id: number) {
    if (fullScreen) {
      let windowClass = this.getWindow(id);
      if (!windowClass) {
        LogUtil.error(TAG, 'Failed to obtain the main window.');
        return;
      }

      windowClass.maximize(window.MaximizePresentation.ENTER_IMMERSIVE_DISABLE_TITLE_AND_DOCK_HOVER)
        .then(() => {
          LogUtil.info(TAG, 'Succeeded in maximizing the window.');
        }).catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to maximize the window. Cause:' + JSON.stringify(err));
      });
    } else {
      this.unMaximize(id);
    }
  }

  @LogMethod
  restore(id: number) {
    let windowClass = this.getWindow(id);
    if (!windowClass) {
      LogUtil.error(TAG, 'Failed to obtain the main window.');
      return;
    }

    windowClass.restore().then(() => {
      LogUtil.info(TAG, 'Succeeded in restoring the window.');
    }).catch((err: BusinessError) => {
      LogUtil.error(TAG, `Failed to restore the window. Cause code: ${err.code}, message: ${err.message}`);
    })
  }

  @LogMethod
  setBounds(id: number,
            hasFrame: boolean,
            bounds: WindowBound) {
    let windowClass = this.getWindow(id);
    if (!windowClass) {
      LogUtil.error(TAG, 'Failed to obtain the main window.');
      return;
    }

    // 平板常规（全屏）模式：窗口几何完全由系统决定，应用层的任何 move / resize
    // 都会与系统布局打架 —— 启动瞬间「窗口先按应用记住的尺寸缩一下、再被系统拉
    // 回全屏」表现为异常抽动，进而内容边界错位（无法正常显示）。这里直接忽略。
    // 注意 DeviceInfoAdapter.getDeviceModeFromSystem 已保证「平板且系统未开电脑
    // 模式」一定要落到 kNormalWindowMode，所以这一道能真正拦住平板。
    if (this.deviceInfoAdapter.isNormalWindowMode()) {
      LogUtil.info(TAG, `[setBounds] ignored in tablet normal mode, id: ${id}`);
      return;
    }

    // PC / 自由窗口模式：Electron 侧「还原最大化状态」是用「整屏尺寸 + setBounds」
    // 实现的，照做会得到「铺满整屏但并非最大化、还原按钮也救不回」的状态（用户
    // 只能手动拖四个角）。这里与开窗路径共用同一套兜底：≈整屏 → 收敛为 72% 居中。
    // 该兜底内部只在 isFreeWindowsMode() 时生效，模式未知时原样放行。
    const clamped: WindowBound = this.clampNearlyFullScreen(bounds, `setBounds id=${id}`);
    bounds.left = clamped.left;
    bounds.top = clamped.top;
    bounds.width = clamped.width;
    bounds.height = clamped.height;

    const windowProp = windowClass?.getWindowProperties();

    // xComponent bounds need to add a border
    let leftBorder: number = hasFrame ? windowProp?.drawableRect.left || 0 : 0;
    let topBorder: number = hasFrame ? windowProp?.drawableRect.top || 0 : 0;
    bounds.left -= leftBorder;
    bounds.top -= topBorder;
    bounds.width = bounds.width + leftBorder + leftBorder;
    bounds.height = bounds.height + topBorder + leftBorder;
     try {
      if (windowClass.getWindowStatus() !== window.WindowStatusType.MAXIMIZE &&
        windowClass.getWindowStatus() !== window.WindowStatusType.FULL_SCREEN) {
        windowClass.moveWindowToAsync(bounds.left, bounds.top)
          .then(() => {
            if (windowClass?.getWindowStatus() !== window.WindowStatusType.MAXIMIZE &&
              windowClass?.getWindowStatus() !== window.WindowStatusType.FULL_SCREEN) {
              windowClass?.resizeAsync(bounds.width, bounds.height)
                .catch((err: BusinessError) => {
                  LogUtil.error(TAG,
                    'Failed to change the window size. Cause:' + JSON.stringify(err) + ' window status:' +
                    windowClass?.getWindowStatus());
                });
            }
          }).catch((err: BusinessError) => {
          LogUtil.error(TAG, 'Failed to move the window. Cause:' + JSON.stringify(err) + ' window status:' +
          windowClass?.getWindowStatus());
        });
      }
     } catch (exception) {
       LogUtil.error(TAG, 'move the window exception. Cause:' + JSON.stringify(exception));
     }
  }

  @LogMethod
  setEnabled(enable: boolean, id: number): boolean {
    let windowClass = this.getWindow(id);
    if (!windowClass) {
      LogUtil.error(TAG, 'Failed to obtain the main window.');
      return false;
    }
    windowClass.setWindowTouchable(enable)
      .catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to set the window to be touchable. Cause:' + JSON.stringify(err));
        return false;
      });
    return true;
  }

  @LogMethod
  setWindowLimits(minWidth: number,
                  minHeight: number,
                  maxWidth: number,
                  maxHeight: number,
                  id: number) {
    let windowClass = this.getWindow(id);
    if (!windowClass) {
      LogUtil.error(TAG, 'Failed to obtain the main window.');
      return;
    }

    const windowProp = windowClass.getWindowProperties();
    let xComBorder: number = windowProp?.drawableRect.left || 0;
    let xComTop: number = windowProp?.drawableRect.top || 0;

    try {
      let windowLimits: window.WindowLimits = {
        minWidth: minWidth === 0 ? minWidth : minWidth + xComBorder + xComBorder,
        minHeight: minHeight === 0 ? minHeight : minHeight + xComTop + xComBorder,
        maxWidth: maxWidth === 0 ? maxWidth : maxWidth + xComBorder + xComBorder,
        maxHeight: maxHeight === 0 ? maxHeight : maxHeight + xComTop + xComBorder,
      };

      windowClass.setWindowLimits(windowLimits, true)
        .catch((err: BusinessError) => {
          LogUtil.error(TAG, 'Failed to change the window limits. Cause: ' + JSON.stringify(err));
        });
    } catch (exception) {
      LogUtil.error(TAG, 'change the window limits exception. Cause:' + JSON.stringify(exception));
    }
  }

  @LogMethod
  maximize(id: number) {
    let windowClass = this.getWindow(id);
    if (!windowClass) {
      LogUtil.error(TAG, 'Failed to obtain the main window.');
      return;
    }

    if (windowClass.getWindowStatus() === window.WindowStatusType.MAXIMIZE) {
      return;
    }

    try {
      windowClass.maximize(window.MaximizePresentation.EXIT_IMMERSIVE).then(() => {
        LogUtil.info(TAG, 'Succeeded in maximizing the window.');
      }).catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to maximize the window. Cause:' + JSON.stringify(err));
      });

      // 原写法 isPcMode()：其真实语义是「deviceMode 还没被初始化过」，一旦
      // initWindowMode 把 2in1/PC 正确同步成 kFreeWindowsMode，这里就会误判为
      // 「需要按避让区重排布局」。改用「PC 语义（含自由窗口）」判断，保持行为不变。
      if (!this.deviceInfoAdapter.isPcOrFreeWindowsMode()) {
        this.abilityManager.getProxy(id)?.updateAvoidAreaStatus(false);
      }
    } catch (exception) {
      LogUtil.error(TAG, 'maximize the window exception. Cause:' + JSON.stringify(exception));
    }
  }

  @LogMethod
  unMaximize(id: number) {
    let windowClass = this.getWindow(id);
    if (!windowClass) {
      LogUtil.error(TAG, 'Failed to obtain the main window.');
      return;
    }

    try {
      windowClass.recover().then(() => {
        LogUtil.info(TAG, 'Succeeded in setting the system bar to be invisible.');
      }).catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to recover the window. Cause: ' + JSON.stringify(err));
      });
    } catch (exception) {
      LogUtil.error(TAG, 'recover the window exception. Cause:' + JSON.stringify(exception));
    }
  }

  @LogMethod
  minimize(id: number) {
    // 冗余 hide 抑制（与 hideWindow 同一套）：确证不可见时再最小化没有意义。
    if (WindowVisibility.shouldSkipHide(id, 'minimize')) {
      return;
    }
    let windowClass = this.getWindow(id);
    if (!windowClass) {
      LogUtil.error(TAG, 'Failed to obtain the main window.');
      return;
    }
    windowClass.minimize()
      .catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to minimize the window. Cause: ' + JSON.stringify(err));
      });
  }

  @LogMethod
  setTitle(id: number, title: string) {
    let proxy = this.abilityManager.getProxy(id);
    proxy?.setWindowTitle(title);
  }

  @LogMethod
  setAspectRatio(id: number, aspectRatio: number) {
    let windowClass = this.getWindow(id);
    try {
      if ( aspectRatio <= 0 ) {
        windowClass?.resetAspectRatio()?.then(() => {
          LogUtil.info(TAG, 'Succeeded in setting aspect ratio of window.');
        }).catch((err: BusinessError) => {
          LogUtil.error(TAG, 'Failed to set the aspect ratio of window. Cause:' + JSON.stringify(err));
        });
      } else {
        let promise = deviceInfo.sdkApiVersion < 21 ? windowClass?.setAspectRatio(aspectRatio) : 
          windowClass?.setContentAspectRatio(aspectRatio, false, true);
        promise?.then(() => {
          LogUtil.info(TAG, 'Succeeded in setting aspect ratio of window.');
        }).catch((err: BusinessError) => {
          LogUtil.error(TAG, 'Failed to set the aspect ratio of window. Cause:' + JSON.stringify(err));
        });
      } 
    } catch (exception) {
      LogUtil.error(TAG, 'Failed to set the aspect ratio of window. Cause: ' + JSON.stringify(exception));
    }
  }

  @LogMethod
  setUseNativeFrame(id: number, useNativeFrame: boolean) {
    let windowClass = this.getWindow(id);

    // 平板：本窗口是"应用自绘标题栏"（hideTitleBar = true）时，不允许前端把系统
    // 标题栏 / 三键再打开 —— 前端 WindowControls 在 openharmony 上无条件渲染自己的
    // 最小化与关闭按钮，系统若同时画三键，就会叠成两层按钮，落在应用标题栏右上方。
    // 这里是与 WebAbility.applySystemCaptionButtonPolicy 配套的第二道闸：那道管
    // 窗口创建与形态变化，这道管运行期前端主动调用。
    let effectiveNativeFrame: boolean = useNativeFrame;
    if (useNativeFrame && deviceInfo.deviceType === 'tablet') {
      const preferences: WindowPreferences | undefined =
        this.abilityManager.getProxy(id)?.getWindowPreferences();
      const appDrawsOwnTitleBar: boolean = preferences === undefined ? true : preferences.hideTitleBar;
      if (appDrawsOwnTitleBar) {
        effectiveNativeFrame = false;
        LogUtil.info(TAG, 'pad policy: ignore setUseNativeFrame(true) - app draws its own title bar');
      }
    }

    try {
      windowClass?.setWindowDecorVisible(effectiveNativeFrame);
      windowClass?.setWindowTitleButtonVisible(effectiveNativeFrame, effectiveNativeFrame, effectiveNativeFrame);
      if (!this.deviceInfoAdapter.isNormalWindowMode()) {
        windowClass?.setWindowTitleMoveEnabled(effectiveNativeFrame);
      } else {
        LogUtil.info(TAG, 'tablet free multi-window model is disabled');
      }
    } catch (exception) {
      LogUtil.error(TAG, `Failed to set the visibility of window decor. Cause code: ${exception.code}, message: ${exception.message}`);
    }
  }

  @LogMethod
  setBackgroundColor(id: number, argbColor: number) {
    let windowClass = this.getWindow(id);
    let data = WindowStyle.getStyleData(id);
    if (data !== undefined) {
      data.backgroundColor = `${WindowStyle.decimalColorToHex(argbColor)}`;
      WindowStyle.getUpdateStyleFunc(id)?.(data);
      windowClass?.setWindowBackgroundColor(`#${WindowStyle.decimalColorToHex(argbColor)}`);
      WindowStyle.updateStyleData(id, data);
    }
  }

  @LogMethod
  setOpacity(id: number, opacity: number) {
    let windowClass = this.getWindow(id);
    let data = WindowStyle.getStyleData(id);
    if (data !== undefined) {
      data.opacity = opacity;
      WindowStyle.getUpdateStyleFunc(id)?.(data);
      let lastColor = data.backgroundColor;
      windowClass?.setWindowBackgroundColor(`#${WindowStyle.decimalOpacityToHex(opacity)}${lastColor.slice(2)}`);
      WindowStyle.updateStyleData(id, data);
    }
  }

  @LogMethod
  setContentProtection(id: number, enable: boolean) {
    let windowClass = this.getWindow(id);
    try {
      windowClass?.setWindowPrivacyMode(enable, (err: BusinessError) => {
        const errCode: number = err.code;
        if (errCode) {
          LogUtil.error(TAG, `Failed to set the window to privacy mode. Cause code: ${err.code}, message: ${err.message}`);
          return;
        }
        LogUtil.info(TAG, 'Succeeded in setting the window to privacy mode.');
      });
    } catch (exception) {
      LogUtil.error(TAG, `Failed to set the window to privacy mode. Cause code: ${exception.code}, message: ${exception.message}`);
    }
  }

  @LogMethod
  setMovable(id: number, movable: boolean) {
    let windowClass = this.getWindow(id);
    try {
      windowClass?.setWindowTitleMoveEnabled(movable);
    } catch (exception) {
      LogUtil.error(TAG, `Failed to set the window Movable. Cause code: ${exception.code}, message: ${exception.message}`);
    }
  }

  @LogMethod
  setResizable(id: number, resizable: boolean) {
    let windowClass = this.getWindow(id);
    try {
      windowClass?.setResizeByDragEnabled(resizable).then(() => {}).catch((err: BusinessError) => {
        LogUtil.error(TAG, `Failed to set the window resizable. Cause ${JSON.stringify(err)}`);
      });
    } catch (exception) {
      LogUtil.error(TAG, `Failed to set the window resizable. Cause code: ${exception.code}, message: ${exception.message}`);
    }
  }

  @LogMethod
  setFocusable(id: number, focusable: boolean) {
    let windowClass = this.getWindow(id);
    try {
      windowClass?.setWindowFocusable(focusable).then(() => {
        LogUtil.info(TAG, `Succeeded in setting the window focusable: ${focusable}.`);
      }).catch((err: BusinessError) => {
        LogUtil.error(TAG, `Failed to set the window focusable. Cause ${JSON.stringify(err)}`);
      });
    } catch (exception) {
      LogUtil.error(TAG, `Failed to set the window focusable. Cause code: ${exception.code}, message: ${exception.message}`);
    }
  }

  @LogMethod
  startWindowMoving(id: number) {
    let window = this.getWindow(id);
    window?.startMoving().then(() => {
    }).catch((err: BusinessError) => {
      LogUtil.error(TAG, `startWindowMoving fail, error info: ${JSON.stringify(err)}`);
    });
  }

  @LogMethod
  startWindowMovingWithOffset(id: number, offsetX: number, offsetY: number) {
    let window = this.getWindow(id);
    if (deviceInfo.sdkApiVersion >= 15) {
      window?.startMoving(offsetX, offsetY).then(() => {
      }).catch((err: BusinessError) => {
        LogUtil.error(TAG, `startWindowMovingWithOffset fail, error info: ${JSON.stringify(err)}`);
      });
    } else {
      LogUtil.error(TAG, 'startWindowMovingWithOffset fail, sdkApiVersion is less than 15');
    }
  }

  @LogMethod
  getWindowsByCoordinate(coordinate: PointCoordinate,
                         callback: (windowIds: Array<string>) => void) {
    let windowIds = new Array<string>();
    try {
      let displayId: number = display.getDefaultDisplaySync().id;
      window.getWindowsByCoordinate(displayId, this.queryWindowNum,
                                    coordinate.x, coordinate.y).then((windows) => {
        for (let win of windows) {
          let originWindowId: number = win.getWindowProperties().id
          let windowId = this.abilityManager.getWindowIdByOriginWindow(originWindowId);
          if (windowId) {
            windowIds.push(windowId);
          }
        }
        callback(windowIds);
      }).catch((err: BusinessError) => {
        LogUtil.error(TAG, 'window.getWindowsByCoordinate fail, code:' + JSON.stringify(err.code) +
          ',message:' + JSON.stringify(err.message));
        callback(windowIds);
      });
    } catch (err) {
      LogUtil.error(TAG, 'getWindowsByCoordinate fail, error:' + JSON.stringify(err));
      callback(windowIds);
    }
	}

  @LogMethod
  setWindowModal(modal: boolean, id: number) {
    if (this.deviceInfoAdapter.isNormalWindowMode()) {
      LogUtil.info(TAG, 'tablet free multi-window model is disabled');
      return;
    }
    let windowStage = this.abilityManager.getProxy(id)?.getWindowStage();
    windowStage?.setWindowModal(modal);
  }

  @LogMethod
  getWindowStatus(id: number): window.WindowStatusType {
    let windowClass = this.getWindow(id);
    let type = windowClass?.getWindowStatus();
    if (type !== undefined) {
      return type;
    }
    return window.WindowStatusType.UNDEFINED;
  }

  @LogMethod
  getOriginWindowIds(windowIds: Array<number>): Array<number> {
    let originWindowIds = new Array<number>();
    try {
      for (let i = 0; i < windowIds.length; i++) {
        let originWindowId = this.abilityManager.getProxy(windowIds[i])?.getOriginWindowId();
        originWindowIds.push(originWindowId ? originWindowId : -1);
      }
    } catch (err) {
      let message = (err as BusinessError).message;
      LogUtil.error(TAG, `getOriginWindowIds failed.: ${message}`);
    }
    return originWindowIds;
  }

  @LogMethod
  shiftWindowMouseEvent(sourceId: number, targetId: number,
    callback: (result: boolean) => void): void {
    if (deviceInfo.sdkApiVersion >= 15) {
      try {
        let sourceOriginWindowId = this.abilityManager.getProxy(sourceId)?.getOriginWindowId();
        let targetOriginWindowId = this.abilityManager.getProxy(targetId)?.getOriginWindowId();
        window.shiftAppWindowPointerEvent(sourceOriginWindowId, targetOriginWindowId).then(() => {
          LogUtil.info(TAG, 'shiftWindowEvent success.');
          callback(true);
        }).catch((err: BusinessError) => {
          LogUtil.error(TAG, 'Failed to shiftWindowEvent. Cause: ' + JSON.stringify(err));
          callback(false);
        })
      } catch (err) {
        let message = (err as BusinessError).message;
        LogUtil.error(TAG, `shiftWindowEvent failed.: ${message}`);
        callback(false);
      }
    } else {
      LogUtil.error(TAG, 'shiftWindowEvent fail, sdkApiVersion is less than 15');
      callback(false);
    }
  }

  @LogMethod
  showHuaweiQuickLogin(
      id: number,
      show: boolean,
      bounds: WindowBound,
      callback: (loginInfo: ILoginInfo) => void) {
    const loginFailInfo: ILoginInfo = {
      status: false,
      authCode: '',
      unionId: '',
      openId: '',
      idToken: '',
      anonymousPhone: ''
    };

    if (!show && this.loginWindow) {
      this.loginWindow.destroyWindow((err: BusinessError) => {
        let errCode: number = err.code;
        if (errCode) {
          LogUtil.error(TAG, 'Failed to destroy the window. Cause: ' + JSON.stringify(err));
          return;
        }
        LogUtil.info(TAG, 'Succeeded in destroying the window.');

        this.loginWindow = null;
      });
      return;
    };

    if (this.loginWindow) {
      callback(loginFailInfo);
      return;
    }

    let activeContext = this.ctxAdapter.getActiveContext() as common.UIAbilityContext;
    if (!activeContext) {
      LogUtil.error(TAG, 'Failed to get active context');
      return;
    }
    let config: window.Configuration = {
      name: 'login',
      windowType: window.WindowType.TYPE_DIALOG,
      ctx: activeContext
    };
    window.createWindow(config, (err: BusinessError, data) => {
      if (err.code) {
        LogUtil.error(TAG, 'Failed to create window. Cause: ' + JSON.stringify(err));
        return;
      }
      let windowClass: window.Window = data;
      if (!this.loginWindow) {
        this.loginWindow = windowClass;
      }
      windowClass.moveWindowTo(bounds.left, bounds.top, (err: BusinessError) => {
        let errCode: number = err.code;
        if (errCode) {
          LogUtil.error(TAG, `Failed to move the window. Cause:${JSON.stringify(err)}`);
          return;
        }
        LogUtil.info(TAG, `succeeded in moving the window.`);
      });
      windowClass.resize(bounds.width, bounds.height, (err: BusinessError) => {
        let errCode: number = err.code;
        if (errCode) {
          LogUtil.error(TAG, `Failed to change the window size. Cause:${JSON.stringify(err)}`);
          return;
        }
        LogUtil.info(TAG, `succeeded in changing the window size.`);
      });
      windowClass.showWindow((err: BusinessError) => {
        const errCode: number = err.code;
        if (errCode) {
          LogUtil.error(TAG, `Failed to show the window. Cause: ${JSON.stringify(err)}`);
          return;
        }
        LogUtil.info(TAG, 'Succeeded in showing the window.');
      });
      const para: Record<string, ILogin> = {
        'login': {
          'loginCallbackFunc': callback
        }
      };
      let storage: LocalStorage = new LocalStorage(para);
      windowClass.loadContent("pages/Login", storage, (err, data) => {
        let errCode: number = err.code;
        if (errCode) {
          LogUtil.error(TAG, 'Failed to load the content. Cause:' + JSON.stringify(err));
          return;
        }
        windowClass.setWindowBackgroundColor('#00000000'); // argb
      });
    });
  }

  @LogMethod
  getWindowId(id: number): number {
    let windowClass = this.getWindow(id);
    let windowId = windowClass?.getWindowProperties().id;
    if (windowId === undefined) {
      LogUtil.error(TAG, 'getWindowId failed, return -1.');
      return -1;
    }
    return windowId;
  }

  @LogMethod
  shiftWindowTouchEvent(sourceId: number, targetId: number,
    fingerId: number, callback: (result: boolean) => void): void {
    if (deviceInfo.sdkApiVersion >= 20) {
      try {
        let sourceOriginWindowId = this.abilityManager.getProxy(sourceId)?.getOriginWindowId();
        let targetOriginWindowId = this.abilityManager.getProxy(targetId)?.getOriginWindowId();
        window.shiftAppWindowTouchEvent(sourceOriginWindowId, targetOriginWindowId, fingerId).then(() => {
          LogUtil.info(TAG, 'shiftWindowTouchEvent success.');
          callback(true);
        }).catch((err: BusinessError) => {
          LogUtil.error(TAG, 'Failed to shiftWindowTouchEvent. Cause: ' + JSON.stringify(err));
          callback(false);
        })
      } catch (err) {
        let message = (err as BusinessError).message;
        LogUtil.error(TAG, `shiftWindowTouchEvent failed.: ${message}`);
        callback(false);
      }
    } else {
      LogUtil.error(TAG, 'shiftWindowTouchEvent fail, sdkApiVersion is less than 20');
      callback(false);
    }
  }

  bind(id: string, callback: (nodeContent: NodeContent | undefined) => void) {
    let nodeContent = this.nodeHandleManager.getNodeContent(id);
    if (!nodeContent) {
      LogUtil.warn(TAG, 'bind node handle with node content failed, not find node content for id' + id);
      callback(undefined);
      return;
    }
    callback(nodeContent);
  }

  @LogMethod
  unbind(id: string, callback: (nodeContent: NodeContent | undefined) => void) {
    let nodeContent = this.nodeHandleManager.getNodeContent(id);
    if (!nodeContent) {
      LogUtil.warn(TAG, 'unbind node handle with node content failed, not find node content for id' + id);
      callback(undefined);
      return;
    }
    callback(nodeContent);
  }

  @LogMethod
  setWindowShadow(id: number, hasShadow: boolean) {
    let windowClass = this.getWindow(id);
    if (!windowClass) {
      LogUtil.info(TAG, `[shadow] Window is not ready; shadow state queued by native, id: ${id}.`);
      return;
    }
    this.applyShadow(windowClass, id, hasShadow, false);
  }

  @LogMethod
  SetWindowIcon(id: number, icon: NotificationAdapterImage) {
    if (deviceInfo.sdkApiVersion >= 22) {
      let context = this.abilityManager.getProxy(id)?.getWindowContext() as common.UIAbilityContext;
      if (context === undefined) {
        LogUtil.error(TAG, `getWindowContext() failed, windowId: ${id}`);
        return;
      }
      let opts: image.InitializationOptions = {
        editable: false,
        pixelFormat: image.PixelMapFormat.BGRA_8888,
        size: {
          height: icon.height,
          width: icon.width
        }
      };
      image.createPixelMap(icon.buff, opts).then((data) => {
        context.setMissionWindowIcon(data).catch((err: BusinessError) => {
          LogUtil.error(TAG, `setMissionWindowIcon failed, err: ${JSON.stringify(err)}`);
        });
      }).catch((err: BusinessError) => {
        LogUtil.error(TAG, `createPixelMap failed, err: ${JSON.stringify(err)}`);
      });
    } else {
      LogUtil.error(TAG, 'SetWindowIcon fail, sdkApiVersion is less than 22');
    }
  }
};
