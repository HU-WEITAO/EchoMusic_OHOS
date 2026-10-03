// Copyright (c) 2024 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import CheckEmptyUtils from '../utils/CheckEmptyUtils';
import Inject from '../common/InjectModule';
import LogUtil from '../utils/LogUtil';
import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import { AbilityManager } from '../common/AbilityManager';
import { AppLifecycleAdapter } from '../adapter/AppLifecycleAdapter';
import { BrowserCloseResponse, CaptionButtonRect, WindowBound, WindowLimits, IWebAppInfo } from '../interface/CommonInterface';
import { BusinessError, deviceInfo, settings } from '@kit.BasicServicesKit';
import { CmdArgsHelper } from '../utils/CmdArgsHelper';
import { ContextAdapter } from '../adapter/ContextAdapter';
import { CommandType, ConfigData, WebStatus, PAD_IMMERSIVE_HIDE_SYSTEM_BAR, PAD_HIDE_SYSTEM_CAPTION_BUTTONS } from '../common/Constants';
import { Configuration } from '@ohos.app.ability.Configuration';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { DeviceInfoAdapter } from '../adapter/DeviceInfoAdapter';
import { DisplayAdapter } from  '../adapter/DisplayAdapter';
import { NativeThemeAdapter } from '../adapter/NativeThemeAdapter';
import { PermissionManagerAdapter } from '../adapter/PermissionManagerAdapter';
import { WindowStyle, IStyleData, IUpdateStyle } from '../common/WindowStyle';
import { WebBaseAbility } from './WebBaseAbility';
import lazy { GlobalThisHelper } from '../utils/GlobalThisHelper';
import { image } from '@kit.ImageKit';
import { kvManager, KVStoreInterface } from '../utils/KVStore';
import { WindowVisibility } from '../utils/WindowVisibility';

const TAG: string = 'WebAbility';

// 平板「真全沉浸」总开关见 common/Constants.ets 的 PAD_IMMERSIVE_HIDE_SYSTEM_BAR
// （WebBaseAbility 的"系统栏显隐"与这里的"内容边界"必须读同一个值）。

export class WebAbility extends WebBaseAbility {
  private static WINDOW_CLOSE: number = 1000;
  private static SLEEP_INTERVAL_MS = 10;
  private static MAXIMUM_NUM_OF_SLEEP_CYCLES = 250;
  private abilityManager: AbilityManager | undefined = undefined;
  private displayAdapter : DisplayAdapter | undefined = undefined;
  private nativeThemeAdapter: NativeThemeAdapter | undefined = undefined;
  private contextAdapter: ContextAdapter | undefined = undefined;
  private deviceInfoAdapter: DeviceInfoAdapter | undefined = undefined;
  private appLifecycleAdapter: AppLifecycleAdapter | undefined = undefined;
  /** 平板常规模式下的页面 LocalStorage（同步 statusBarHeight / navIndicatorHeight 给 ArkUI 避让） */
  private padStorage: LocalStorage | undefined = undefined;
  /**
   * 常规（全屏）模式下窗口几何由系统掌管，启动/显示动画期间 windowSizeChange /
   * windowRectChange 会**逐帧**触发，每一帧都把内容边界推给原生侧，原生侧随之重排
   * —— 观感就是「启动过程极其抖动、页面点不动」（模拟器没有窗口入场动画，所以正常）。
   * 这里在动画窗口期内把这两路推送压住，等尺寸稳定后再补推一次最终值。
   */
  private normalBoundSettled: boolean = false;
  private normalSettleTimer: number = -1;
  /** 等窗口入场动画收尾的时长（ms） */
  private static NORMAL_BOUND_SETTLE_MS: number = 700;

  onConfigurationUpdate(config: Configuration) {
    if (config.colorMode !== undefined) {
      this.nativeThemeAdapter?.setSystemNativeTheme(config.colorMode);
    }
    if (config.fontSizeScale !== undefined) {
      this.displayAdapter?.onSystemFontSizeChange(config.fontSizeScale);
    } else {
      this.displayAdapter?.onSystemFontSizeChange(1.0);
    }
  }

  private async getWebappInfo() : Promise<IWebAppInfo | undefined> {
    const appIdPrefix: string = "--app-id=";
    let key = this.appId.startsWith(appIdPrefix) ? this.appId.substring(appIdPrefix.length) : this.appId;
    const kvStore: KVStoreInterface | undefined = await kvManager.getKVStore('webapp');
    const webappInfo: string | undefined = await kvStore?.getData(key);
    if (!webappInfo) {
      return Promise.resolve(undefined);
    }
    return Promise.resolve(JSON.parse(webappInfo));
  }

  private async updateWebAppIcon() {
    const webAppInfo = await this.getWebappInfo();
    const icon = webAppInfo?.icon;
    const label = webAppInfo?.label;
    const openAsWindow = webAppInfo?.openAsWindow;

    if (icon && label && openAsWindow) {
      const imageSource = image.createImageSource(icon);
      if (!imageSource) {
        LogUtil.error(TAG, 'imageSource invaild');
        return;
      }

      try {
        const pixelMap: image.PixelMap = await imageSource.createPixelMap();
        await this.context.setAbilityInstanceInfo(label, pixelMap);
      } catch (err) {
        LogUtil.error(TAG, `setAbilityInstanceInfo failed, code is ${err.code}, message is ${err.message}`);
      }
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    LogUtil.info(TAG, '[ohoswindow] in WebAbility onCreate.');
    super.onCreate(want, launchParam);
    kvManager.init(this.context);
    this.updateWebAppIcon();

    this.abilityManager = Inject.get(AbilityManager);
    this.displayAdapter = Inject.get(DisplayAdapter);
    this.nativeThemeAdapter = Inject.get(NativeThemeAdapter);
    this.contextAdapter = Inject.get(ContextAdapter);

    Inject.get(PermissionManagerAdapter).initPermissions();

    this.deviceInfoAdapter = Inject.get(DeviceInfoAdapter);
    // 必须在「本 ability 的第一扇窗口创建之前」把设备窗口模式同步进来：
    // deviceMode 初值是 kPcMode，若等到 onPadWindowStageCreate（平板分支）才同步，
    // 启动阶段的 isNormalWindowMode()/isFreeWindowsMode() 全是错的 —— 平板会隐掉
    // 小横条再显示（抽动）、首帧内容不扣状态栏（错位），PC 则永远判不出自由窗口
    // 模式、启动尺寸兜底失效（打开铺满）。详见 DeviceInfoAdapter.initWindowMode。
    this.deviceInfoAdapter.initWindowMode(this.context);
    this.appLifecycleAdapter = Inject.get(AppLifecycleAdapter);
    if (this.appLifecycleAdapter?.getWebStatus() === WebStatus.kDestroy) {
      LogUtil.warn(TAG, 'app already exit and close this window widget_id:' + this.xcomponentId);
      this.closeWindow();
    }
  }

  // Cross-device continuation restores the window stage via onWindowStageRestore
  // (NOT onWindowStageCreate). Without this, a continuation launch never loads
  // the window content, so the electron browser never starts and the window
  // hangs. Delegate to the normal create path so content loads and electron
  // comes up.
  onWindowStageRestore(windowStage: window.WindowStage): void {
    LogUtil.info(TAG, '[ohoswindow] in WebAbility onWindowStageRestore -> create path');
    this.onWindowStageCreate(windowStage);
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    LogUtil.info(TAG, '[ohoswindow] in WebAbility onWindowStageCreate.');
    super.onWindowStageCreate(windowStage);

    if (this.checkSingleInstance()) {
      LogUtil.warn(TAG, 'repeat launch from desktop, need terminate');
      return;
    }

    this.abilityManager?.addProxy(this);

    windowStage.getMainWindow((err, data) => {
      if (err.code) {
        LogUtil.error(TAG, 'Failed to obtain the main window: ' + JSON.stringify(err));
        return;
      }

      try {
        if (deviceInfo.sdkApiVersion >= 20) {
          data.on('windowStatusDidChange', (status) => {
            this.notifyWindowStatusChange(status)
          })
        } else {
          data.on('windowStatusChange', (status) => {
            this.notifyWindowStatusChange(status)
          })
        }
      } catch (exception) {
        LogUtil.error(TAG,'Failed to listener for window status changes: ' + JSON.stringify(exception));
      }

      try {
        data.on('windowSizeChange', (size) => {
          // 常规（全屏）模式 + 入场动画未收尾：逐帧推送会变成内容抖动，先压住，
          // 等 scheduleNormalBoundSettle 补推最终值
          if (this.shouldDeferNormalBoundPush()) {
            return;
          }
          const prop = data.getWindowProperties();
          let windowBound: WindowBound = {
            left: prop.windowRect.left + prop.drawableRect.left,
            top: prop.windowRect.top + prop.drawableRect.top,
            width: size.width - prop.drawableRect.left - prop.drawableRect.left,
            height: size.height - prop.drawableRect.left - prop.drawableRect.top,
          };
          this.nativeContext.OnWindowSizeChange(this.xcomponentId, windowBound);
        });
      } catch (exception) {
        LogUtil.error(TAG,'Failed to listener for window size changes: ' + JSON.stringify(exception));
      }

      try {
        data.on("windowRectChange", (option) => {
          // 同上：入场动画期间的每帧 rect 推送一律延后到 settle
          if (this.shouldDeferNormalBoundPush()) {
            return;
          }
          const prop = data.getWindowProperties();
          const rect = option.rect;
          let statusBarHeight = 0;
          let navIndicatorHeight = 0;
          if (this.deviceInfoAdapter?.isNormalWindowMode()) {
            // 真全沉浸（PAD_IMMERSIVE_HIDE_SYSTEM_BAR）下系统栏已隐藏，避让恒为 0：
            // 不读避让区（读回来是非 0，会把内容白白缩进一块）。
            if (!PAD_IMMERSIVE_HIDE_SYSTEM_BAR) {
              statusBarHeight = data.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
              // 底部小横条（导航指示条）高度，随窗口形态变化
              try {
                navIndicatorHeight =
                  data.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
              } catch (err) {
                navIndicatorHeight = 0;
              }
            }
            //The current system has a timing issue where the drawableRect lags in updating during mode switching.
            //Here, when switching to normal mode, the drawableRect is set to 0
            //to temporarily maintain normal performance until the issue is resolved.
            prop.drawableRect.height = prop.drawableRect.height + prop.drawableRect.top;
            prop.drawableRect.top = 0;
          }
          let windowBound: window.Rect = {
            left: rect.left + prop.drawableRect.left,
            top: rect.top + prop.drawableRect.top + statusBarHeight,
            width: rect.width - prop.drawableRect.left - prop.drawableRect.left,
            height: rect.height - prop.drawableRect.left - prop.drawableRect.top - statusBarHeight - navIndicatorHeight,
          };
          this.nativeContext.OnWindowRectChange(this.xcomponentId,
            windowBound,
            option.reason.valueOf());
        });
      } catch (exception) {
        LogUtil.error(TAG,'Failed to listener for window rect changes: ' + JSON.stringify(exception));
      }

      try {
        data.on('windowEvent', (type) => {
          // 把系统的可见性事件喂给 WindowVisibility —— 它是「冗余 show/hide 抑制」的
          // **唯一权威依据**（这台设备上 Electron 侧 `isVisible()` 显然不可信，否则不会
          // 每秒去 show 24 次）。SHOWN ⇒ 窗口在屏幕上；HIDDEN ⇒ 不在。
          // 只有主窗口（xcomponentId === DEFAULT_WINDOW_ID）的事件才算数：副窗口的显隐
          // 不能污染主窗口的状态。
          if (this.xcomponentId === ConfigData.DEFAULT_WINDOW_ID) {
            if (type == window.WindowEventType.WINDOW_SHOWN) {
              WindowVisibility.noteVisible('windowEvent:SHOWN');
            } else if (type == window.WindowEventType.WINDOW_HIDDEN) {
              WindowVisibility.noteHidden('windowEvent:HIDDEN');
            }
          }
          if (type == window.WindowEventType.WINDOW_SHOWN) {
            // 入场/显示动画从这一刻开始：重新计时，动画期间的逐帧推送先压住
            this.scheduleNormalBoundSettle(data);
            // 平板常规（全屏）模式：后台重开时必须重新按避让区裁剪原生内容边界。
            // 走兜底分支会用「窗口顶=屏幕顶」的旧口径推送，导致内容与状态栏/小横条
            // 避让叠加错位（后台重开严重错位的根因）。
            let padNormal = false;
            try {
              padNormal = deviceInfo.deviceType === 'tablet' &&
                (this.deviceInfoAdapter?.isNormalWindowMode() ?? false);
            } catch (err) {
              padNormal = false;
            }
            if (padNormal) {
              // 后台重开时系统可能重置全屏布局与系统栏显隐，先重设沉浸式再推内容边界
              this.updateAvoidAreaStatus(false);
              this.pushPadContentBound(data);
            } else {
              const prop = data.getWindowProperties();
              let windowBound: WindowBound = {
                left: prop.windowRect.left + prop.drawableRect.left,
                top: prop.windowRect.top + prop.drawableRect.top,
                width: prop.windowRect.width - prop.drawableRect.left - prop.drawableRect.left,
                height: prop.windowRect.height - prop.drawableRect.left - prop.drawableRect.top,
              };
              this.nativeContext.OnWindowRectChange(this.xcomponentId, windowBound, 0);
            }
          }
          this.nativeContext.OnWindowEvent(this.xcomponentId, type.valueOf());
        });
      } catch (exception) {
        LogUtil.error(TAG, 'Failed to register callback: ' + JSON.stringify(exception));
      }

      try {
        data.on("windowVisibilityChange", (visible) => {
          // 同一条可见性的第二路证据（比 windowEvent 更直白：布尔值本身）。
          // 同样只采信主窗口，避免副窗口的显隐污染主窗口状态。
          if (this.xcomponentId === ConfigData.DEFAULT_WINDOW_ID) {
            if (visible) {
              WindowVisibility.noteVisible('windowVisibilityChange');
            } else {
              WindowVisibility.noteHidden('windowVisibilityChange');
            }
          }
          this.nativeContext.OnWindowVisibilityChange(this.xcomponentId, visible);
        });
      } catch (exception) {
        LogUtil.error(TAG, 'Failed to register callback: ' + JSON.stringify(exception));
      }

      try {
        data.on('keyboardHeightChange', (height) => {
          this.nativeContext.OnKeyboardHeightChange(this.xcomponentId, height);
        });
      } catch (exception) {
        LogUtil.error(TAG, 'Failed to listener for keyboard height changes: ' + JSON.stringify(exception));
      }

      try {
        data.on('displayIdChange', (displayId) => {
          this.nativeContext.OnWindowDisplayIdChange(this.xcomponentId, displayId);
        });
      } catch (exception) {
        LogUtil.error(TAG, `register displayIdChange listener fail, xcomponentId:${this.xcomponentId},
                      exception: ${JSON.stringify(exception)}`);
      }
    });

    try {
      windowStage.on("windowStageEvent", (event) => {
        // 舞台层的显隐是「整个 ability 被切到后台」最稳的信号（用户按 Home / 切换应用）。
        // 补上它，主窗口的可见性记录在真实切走时也能及时翻成「不可见」——否则下一次
        // 「把窗口调出来」会被误判成冗余而丢掉。同样只采信主窗口。
        if (this.xcomponentId === ConfigData.DEFAULT_WINDOW_ID) {
          if (event === window.WindowStageEventType.SHOWN) {
            WindowVisibility.noteVisible('windowStageEvent:SHOWN');
          } else if (event === window.WindowStageEventType.HIDDEN) {
            WindowVisibility.noteHidden('windowStageEvent:HIDDEN');
          }
        }
        if (event === window.WindowStageEventType.ACTIVE) {
          if (!GlobalThisHelper.isWebappWindow(this.xcomponentId)) {
            GlobalThisHelper.pushActiveBrowserId(this.xcomponentId);
          }
        }
        LogUtil.info(TAG, `windowStageEvent: ${event}`);
      });
    } catch (exception) {
      LogUtil.error(TAG, 'Failed to register windowStageEvent callback: ' + JSON.stringify(exception));
    }

    this.getWebappInfo()
      .then((info) => {
        if (info?.openAsWindow) {
          GlobalThisHelper.addWindowTypeRec(this.xcomponentId, this.appId);
        }
      });

    const para: Record<string, Object | string[] | IUpdateStyle> = {
      'xcomponentId': this.xcomponentId,
      'startUri': this.startUri,
      'cmdArgs': this.cmdArgs,
      'updateStyle': {
        'registerUpdateStyleFunction': WindowStyle.registerUpdateStyleFunction,
        'removeUpdateStyleFunction': WindowStyle.removeUpdateStyleFunction
      },
      'window': windowStage.getMainWindowSync(),
      'useDarkMode': this.needDarkMode(),
      'appId': this.appId,
    };
    let storage: LocalStorage = new LocalStorage(para);
    windowStage.loadContent(this.getContentPath(), storage, (err, data) => {
      if (err.code) {
        LogUtil.error(TAG, 'Failed to load the content: ' + JSON.stringify(err));
        return;
      }

      let window: window.Window = windowStage.getMainWindowSync();

      let isPCStatus = settings.getValueSync(this.context, 'isSystemModePc', '', settings.domainName.USER_PROPERTY);
      LogUtil.info(TAG, `deviceType: ${deviceInfo.deviceType}, isSystemModePc: ${isPCStatus},` +
        ` windowMode: ${this.deviceInfoAdapter?.isNormalWindowMode() ? 'normal(fullscreen)' : 'free-window'}`);
      if (deviceInfo.deviceType === 'tablet' && isPCStatus !== 'true') {
        this.onPadWindowStageCreate(window, storage);
      }
      // 若 WINDOW_SHOWN 迟迟不来，也要有一次 settle 兜底，避免逐帧推送被永久压住
      this.scheduleNormalBoundSettle(window);

      // hide title bar
      window.setWindowDecorVisible(!this.hideTitleBar);

      if (this.useDarkMode && deviceInfo.deviceType === '2in1') {
        let buttonStyle: window.DecorButtonStyle = {
          colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        };
        window.setDecorButtonStyle(buttonStyle);
      } else if (this.useDarkMode) {
        this.setDarkModeButton(window);
      }
      this.maximizable = this.maximizable && !this.hideTitleBar;
      this.minimizable = this.minimizable && !this.hideTitleBar;
      this.closable = this.closable && !this.hideTitleBar;
      window.setResizeByDragEnabled(this.resizable);
      window.setWindowFocusable(this.focusable).then(() => {
        LogUtil.info(TAG, `Succeeded in setting initial window focusable: ${this.focusable}.`);
      }).catch((err: BusinessError) => {
        LogUtil.error(TAG, `Failed to set initial window focusable. Cause: ${JSON.stringify(err)}`);
      });
      if (this.deviceInfoAdapter?.isNormalWindowMode() === false) {
        window.setWindowTitleButtonVisible(this.maximizable, this.minimizable, this.closable);
        window.setWindowTitleMoveEnabled(!this.hideTitleBar);
        windowStage.setWindowModal(this.isModal);
        if (this.isPanel)
          window.setTitleAndDockHoverShown(false, false);
      } else {
        LogUtil.info(TAG, 'tablet free multi-window model is disabled');
      }

      // ★ 平板：关掉系统的"窗口三键"（最大化/还原、最小化、关闭）。
      //   本应用是应用自绘标题栏（hideTitleBar = true），前端 WindowControls 在
      //   openharmony 上无条件渲染最小化/关闭按钮；系统若同时画三键，两者就叠在
      //   一起 —— 用户看到的就是"右上角多了一层按钮"。
      //   上面的 isNormalWindowMode() 分支在 PC 上已经关过了，但**平板的 deviceMode
      //   恒为 kNormalWindowMode**，永远进不去那条分支，所以这里单独兜一层。
      //   详见 common/Constants.ets 的 PAD_HIDE_SYSTEM_CAPTION_BUTTONS。
      this.applySystemCaptionButtonPolicy(window);

      // window title button rect change callback must registered after loadContent/setUIContent
      try {
        window.on("windowTitleButtonRectChange", (titleButtonRect) => {
          let uiContext = window.getUIContext();
          let rect: CaptionButtonRect = {
            right: uiContext.vp2px(titleButtonRect.right),
            top: uiContext.vp2px(titleButtonRect.top),
            width: uiContext.vp2px(titleButtonRect.width),
            height: uiContext.vp2px(titleButtonRect.height)
          };
          if ((!this.maximizable && !this.minimizable && !this.closable) || !this.hideTitleBar) {
            rect = { right: 0, top: 0, width: 0, height: 0 };
          }
          this.nativeContext.OnCaptionButtonRectChange(this.xcomponentId, rect);
        });
      } catch (exception) {
        LogUtil.error(TAG, 'Failed to register window title button change callback: ' + JSON.stringify(exception));
      }

      if (deviceInfo.sdkApiVersion >= 15) {
        this.nativeContext.RegisterWindowEventFilter(window.getWindowProperties().id);
      }

      // display brightness observer
      if (deviceInfo.sdkApiVersion >= 22) {
        const context: Context = getContext(this);
        let res: boolean = settings.registerKeyObserver(context,
          settings.display.SCREEN_BRIGHTNESS_STATUS, settings.domainName.DEVICE_SHARED, () => {
            let value: string = settings.getValueSync(context, settings.display.SCREEN_BRIGHTNESS_STATUS, '10');
            this.nativeContext.UpdateDisplayBrightnessCB(value);
          });
      }

      try {
        window.on('displayIdChange', (displayId) => {
          this.nativeContext.OnWindowDisplayIdChange(this.xcomponentId, displayId);
        });
      } catch (exception) {
        LogUtil.info(TAG, `register displayIdChange listener fail, xcomponentId:${this.xcomponentId},
                      exception: ${JSON.stringify(exception)}`);
      }

      try {
        if (this.xcomponentId === ConfigData.DEFAULT_WINDOW_ID) {
          let windowLimits = this.getWindow()?.getWindowLimits();
          let uiContext = window.getUIContext();
          let limits: WindowLimits = {
            maxHeight: Math.ceil(uiContext.px2vp(windowLimits?.maxHeight ?? 0)),
            maxWidth: Math.ceil(uiContext.px2vp(windowLimits?.maxWidth ?? 0)),
            minHeight: Math.ceil(uiContext.px2vp(windowLimits?.minHeight ?? 0)),
            minWidth: Math.ceil(uiContext.px2vp(windowLimits?.minWidth ?? 0))
          }
          this.nativeContext.SetSystemWindowLimits(limits);
        }
      } catch (exception) {
        LogUtil.error(TAG, 'Failed to get window limits or get ui context:' + JSON.stringify(exception));
      }
    });

  }

  /**
   * 平板：隐藏系统的「窗口标题栏三键」（最大化/还原、最小化、关闭）。
   *
   * 只在「平板 + 本窗口由应用自绘标题栏（hideTitleBar = true）」时生效，其余情况
   * 原样返回，不影响任何既有行为：
   *
   * - **非平板**（2in1 / PC / 默认设备）：deviceMode 是 kFreeWindowsMode 或初值
   *   kPcMode，`onWindowStageCreate` 里 `isNormalWindowMode() === false` 那条分支
   *   会按 hideTitleBar 决定三键显隐，不需要这里再介入（重复设置也无害，但没必要）。
   * - **窗口要的是系统原生标题栏**（Electron 侧 frame = true ⇒ hideTitleBar = false）：
   *   三键必须保留，否则用户没法关闭/最小化这个窗口。
   *
   * ★ 为什么必须在平板单独兜这一层：平板的 deviceMode 恒为 kNormalWindowMode
   *   （DeviceInfoAdapter.getDeviceModeFromSystem 在 deviceType === 'tablet' 且
   *   系统未开 PC 模式时直接 return），所以上面那条"关三键"的分支在平板上是死代码，
   *   三键会一直保持系统默认的可见状态，压在应用自绘标题栏的右上角。
   *
   * ★ 还要注意：`setWindowDecorVisible(false)` 只隐藏标题栏**本体**，三键是独立
   *   控制的，不会被它一起关掉 —— 这是最容易漏的一点。
   */
  private applySystemCaptionButtonPolicy(windowClass: window.Window): void {
    if (!PAD_HIDE_SYSTEM_CAPTION_BUTTONS) {
      return;
    }
    if (deviceInfo.deviceType !== 'tablet') {
      return;
    }
    if (!this.hideTitleBar) {
      return;
    }
    try {
      // 三个参数依次为 最大化/还原、最小化、关闭。全 false = 三键都不画。
      windowClass.setWindowTitleButtonVisible(false, false, false);
      LogUtil.info(TAG, 'pad policy: system caption buttons hidden (app draws its own title bar)');
    } catch (exception) {
      LogUtil.error(TAG, 'pad policy: failed to hide system caption buttons: ' + JSON.stringify(exception));
    }
    try {
      // 顺带把"三键区域"归零同步给渲染层：前端自绘标题栏右侧不必再为三键留白。
      // 注意必须显式声明类型 —— 直接传对象字面量会被 ArkTS 的
      // arkts-no-untyped-obj-literals 规则拦下（本工程踩过一次）。
      const emptyRect: CaptionButtonRect = { right: 0, top: 0, width: 0, height: 0 };
      this.nativeContext.OnCaptionButtonRectChange(this.xcomponentId, emptyRect);
    } catch (exception) {
      LogUtil.warn(TAG, 'pad policy: caption rect reset skipped: ' + JSON.stringify(exception));
    }
  }

  onWindowStageDestroy() {
    LogUtil.info(TAG, '[ohoswindow] in WebAbility onWindowStageDestroy.');
    if (CheckEmptyUtils.isEmpty(this.xcomponentId)) {
      LogUtil.warn(TAG, 'onWindowStageDestroy component is not instantiated');
      return;
    }
    if (deviceInfo.sdkApiVersion >= 15) {
      let originWindowId = this.abilityManager?.getOriginWindowId(this.xcomponentId);
      this.nativeContext.ClearWindowEventFilter(originWindowId);
    }
    // Main window is destroyed, release UI related resources
    this.abilityManager?.removeProxy(this.xcomponentId);
    GlobalThisHelper.delWindowTypeRec(this.xcomponentId);
    GlobalThisHelper.delActiveBrowserId(this.xcomponentId);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogUtil.info(TAG, `[ohoswindow] in WebAbility onNewWant, want is ${JSON.stringify(want)}, param is ${JSON.stringify(launchParam)}.`);
    super.onNewWant(want, launchParam);
    this.handleContinueRestore(want, launchParam);
    const params = want?.parameters;
    let uriNotNull = want["uri"] !== undefined && want["uri"] !== '';
    if(want!== undefined && want !== null) {
      LogUtil.info(TAG, 'onNewWant begin, want: ' +
        'bundleName: ' + JSON.stringify(want.bundleName) +
        ', abilityName: ' + JSON.stringify(want.abilityName) +
        ', deviceId: ' + JSON.stringify(want.deviceId) +
        ', uri not null: ' + JSON.stringify(uriNotNull) +
        ', type: ' + JSON.stringify(want.type) +
        ', flags: ' + JSON.stringify(want.flags) +
        ', action: ' + JSON.stringify(want.action) +
        ', parameters: ' + JSON.stringify(want.parameters) +
        ', entities: ' + JSON.stringify(want.entities) +
        ', moduleName: ' + JSON.stringify(want.moduleName) +
        ', LaunchParam: ' + JSON.stringify(launchParam));
    }
    this.emitSecondInstance(want);
    if (uriNotNull) {
      let uri = want['uri'] as string;
      if (uri.startsWith("file://docs/")) {
        this.openNewWindow(uri.replace("file://docs/", "file:///"), false);
      } else {
        LogUtil.debug(TAG, `Trigger open-url event. uri = ${uri}`);
        this.openURL(uri);
      }
    } else if (params !== undefined && params["appId"] !== undefined) {
      LogUtil.info(TAG, 'else if params !== undefined');
      let appId = params["appId"] as string;
      LogUtil.info(TAG, 'let appId: ' + appId);
      let xcomponentId = GlobalThisHelper.getWebappWindow(appId);
      LogUtil.info(TAG, 'get xcomponentId: ' + xcomponentId);
      if (xcomponentId !== '') {
        LogUtil.info(TAG, 'xcomponentId !== \'\'');
        return;
      } else {
        LogUtil.info(TAG, 'xcomponentId is empty');
        let windowClass = this.abilityManager?.getProxy(this.xcomponentId)?.getWindow();
        let show = windowClass?.isWindowShowing();
        LogUtil.info(TAG, `${this.xcomponentId} isWindowShowing: ${show}`);
        if (!show) {
          windowClass?.minimize()
            .catch((err: BusinessError) => {
              LogUtil.error(TAG, 'Failed to minimize the window. Cause: ' + JSON.stringify(err));
            });
        }
        this.openNewWindow(appId, true);
        LogUtil.info(TAG, 'this.openNewWindow(appId, true), appId: ' + appId);
      }
    } else if(GlobalThisHelper.getLastActiveBrowserId() === undefined) {
      LogUtil.info(TAG, 'GlobalThisHelper.getLastActiveBrowserId() begin');
      this.openNewWindow(this.startUri, false);
      LogUtil.info(TAG, 'GlobalThisHelper.getLastActiveBrowserId() end, this.startUri: ' + this.startUri);
    }
    LogUtil.info(TAG, 'end call onNewWant func');
  }

  onPrepareToTerminate(): boolean {
    this.nativeContext.OnWindowEvent(this.xcomponentId, WebAbility.WINDOW_CLOSE);
    return true;
  }

  async onPrepareToTerminateAsync(): Promise<boolean> {
    let id: number = Number(this.xcomponentId.substring(ConfigData.WINDOW_PREFIX.length));
    let response: BrowserCloseResponse = BrowserCloseResponse.kUndetermined;
    this.nativeContext.OnWindowEvent(this.xcomponentId, WebAbility.WINDOW_CLOSE);
    for (let i = 0; i < WebAbility.MAXIMUM_NUM_OF_SLEEP_CYCLES; i++) {
      await this.sleep(WebAbility.SLEEP_INTERVAL_MS);
      response = this.nativeContext.GetBrowserCloseResponse(id);
      if (response !== BrowserCloseResponse.kUndetermined) {
        break;
      }
    }
    if (response === BrowserCloseResponse.kClosingContinue || response === BrowserCloseResponse.kClosed) {
      return false;
    }
    return true;
  }

  sleep(delay: number) {
    return new Promise<void>((resolve) => setTimeout(resolve, delay));
  }

  async onDestroy(): Promise<void> {
    LogUtil.info(TAG, ' [ohoswindow] onDestroy');
    let id: number = Number(this.xcomponentId.substring(ConfigData.WINDOW_PREFIX.length));
    while (true) {
      await this.sleep(WebAbility.SLEEP_INTERVAL_MS);
      let response = this.nativeContext.GetBrowserCloseResponse(id);
      if (this.appLifecycleAdapter?.getWebStatus() === WebStatus.kDestroy ||
        response === BrowserCloseResponse.kClosed || response === BrowserCloseResponse.kClosedAnyway) {
        break;
      }
    }
    if (this.abilityManager?.getProxyCount() === 0) {
      while (true) {
        await this.sleep(WebAbility.SLEEP_INTERVAL_MS);
        let destroyed = this.nativeContext.BrowserDestroyed();
        if (this.appLifecycleAdapter?.getWebStatus() === WebStatus.kDestroy || destroyed) {
          break;
        }
      }
    }
    return;
  }

  private checkSingleInstance(): boolean {
    if (!CheckEmptyUtils.isEmpty(this.xcomponentId)) {
      return false;
    }
    this.openNewWindow(this.startUri, false);
    this.closeWindow();
    return true;
  }

  // Forward a re-launch (new Want) of the running app to the main process so
  // that it can be dispatched as the Electron `second-instance` event. The
  // argv payload mirrors the desktop semantics: cmdArgs plus the launch uri.
  private emitSecondInstance(want: Want): void {
    // Same parser as the first-launch path (WebBaseAbility.initParameters):
    // accepts both array and shell-style string forms of cmdArgs. slice() so
    // pushing the uri below cannot mutate want.parameters['cmdArgs'].
    const argv: string[] =
      CmdArgsHelper.getCmdArgs(want?.parameters?.['cmdArgs']).slice();

    // The deep-link / file-open target arrives in want.uri, not in cmdArgs.
    // On desktop this URL is part of argv, so fold it in (normalized the same
    // way as the onNewWant uri branch).
    const uri = want?.['uri'];
    if (typeof uri === 'string' && uri !== '') {
      argv.push(uri.startsWith('file://docs/') ? uri.replace('file://docs/', 'file:///') : uri);
    }

    if (argv.length === 0) {
      argv.push('electron');
    }

    LogUtil.info(TAG, '[ohoswindow] emitSecondInstance argv=' + JSON.stringify(argv));
    this.nativeContext.ExecuteCommand(CommandType.kSecondInstance, {
      user_data: JSON.stringify(argv)
    });
  }

  private openNewWindow(open_url: string, is_webapp: boolean) {
    this.nativeContext.ExecuteCommand(CommandType.kNewWindow, { url: open_url, is_webapp: is_webapp });
  }

  private openURL(url: string) {
    LogUtil.debug(TAG, 'openURL is called, url: ' + url);
    this.nativeContext.ExecuteCommand(CommandType.kOpenURL, { url: url });
  }

  /**
   * 常规（全屏）模式下、窗口入场动画还没收尾时，暂缓逐帧的内容边界推送。
   * 非常规模式（自由多窗 / PC）返回 false，行为完全不变。
   */
  private shouldDeferNormalBoundPush(): boolean {
    if (this.normalBoundSettled) {
      return false;
    }
    return this.deviceInfoAdapter?.isNormalWindowMode() ?? false;
  }

  /**
   * 重新计时：等入场/显示动画收尾（NORMAL_BOUND_SETTLE_MS）后，补推一次最终内容边界，
   * 并恢复 windowSizeChange / windowRectChange 的逐帧推送。
   */
  private scheduleNormalBoundSettle(windowClass: window.Window): void {
    if (this.normalSettleTimer !== -1) {
      clearTimeout(this.normalSettleTimer);
      this.normalSettleTimer = -1;
    }
    this.normalBoundSettled = false;
    this.normalSettleTimer = setTimeout(() => {
      this.normalSettleTimer = -1;
      this.normalBoundSettled = true;
      try {
        // 只有常规（全屏）模式才被压住过，需要补推一次最终值；
        // 自由多窗 / PC 模式下逐帧推送从未中断，这里什么都不做。
        if (this.deviceInfoAdapter?.isNormalWindowMode() ?? false) {
          this.pushContentSize(windowClass);
          this.pushPadContentBound(windowClass);
          LogUtil.info(TAG, 'normal-mode bound settled push done');
        }
      } catch (err) {
        LogUtil.error(TAG, 'normal-mode bound settled push failed: ' + JSON.stringify(err));
      }
    }, WebAbility.NORMAL_BOUND_SETTLE_MS);
  }

  /** 内容尺寸（不含避让裁剪）推送，与 windowSizeChange 同口径 */
  private pushContentSize(windowClass: window.Window): void {
    const prop = windowClass.getWindowProperties();
    let windowBound: WindowBound = {
      left: prop.windowRect.left + prop.drawableRect.left,
      top: prop.windowRect.top + prop.drawableRect.top,
      width: prop.windowRect.width - prop.drawableRect.left - prop.drawableRect.left,
      height: prop.windowRect.height - prop.drawableRect.left - prop.drawableRect.top,
    };
    this.nativeContext.OnWindowSizeChange(this.xcomponentId, windowBound);
  }

  private onPadWindowStageCreate(windowClass: window.Window, storage: LocalStorage) {
    this.padStorage = storage;

    // 顺序很重要：先同步设备模式，再动窗口布局。
    // updateAvoidAreaStatus 内部按 isNormalWindowMode() 决定系统栏显隐策略；
    // 若模式还没同步（旧写法），平板常规模式下会先走错误分支设置一遍系统栏，
    // 紧接着又被下一段设置覆盖 —— 两个异步调用互相打架，就是「平板模式打开时
    // 窗口异常抽动」的直接来源。
    const context: Context = getContext(this);
    this.deviceInfoAdapter?.registerDeviceModeChange(context);

    // 平板常规（全屏）模式：彻底隐藏状态栏与小横条（详见 PAD_IMMERSIVE_HIDE_SYSTEM_BAR）。
    // 早前这里是"保留小横条 + 截屏取色、在系统栏位置铺两条假色条"，整条链路已删除。
    this.updateAvoidAreaStatus(false);

    // 系统栏已隐藏 ⇒ 避让高度一律按 0：内容铺满整屏，ArkUI 侧不再有色条占位。
    this.pushPadContentBound(windowClass);

    // 窗口支持模式由 module.json5 的 supportWindowMode 声明，运行期不得再调用
    // setSupportedWindowModes：该接口会把掩码由系统默认 127 改写为 15，系统随即
    // 把窗口归入「PC 应用窗口」分支，回桌面只最小化窗口、不触发 ability 退后台，
    // 媒体实况窗（状态栏胶囊）因此始终不显示。

    windowClass.on('avoidAreaChange', (data) => {
      if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
        // 全沉浸下小横条已隐藏，避让高度不参与内容计算；只记日志便于排查
        LogUtil.info(TAG, 'Avoidarea changes,navIndicatorHeight:' + data.area.bottomRect.height);
        return;
      }
      if (data.type !== window.AvoidAreaType.TYPE_SYSTEM) {
        return;
      }

      LogUtil.info(TAG, 'Avoidarea changes,statusBarHeight:' + data.area.topRect.height);
      if(!this.deviceInfoAdapter?.isNormalWindowMode()) {
        return;
      }

      this.displayAdapter?.availableAreaUpdateByStatusBar();

      // 统一走避让区重查 + 边界推送（同时刷新 ArkUI 避让值）
      this.pushPadContentBound(windowClass);
    });
  }

  /**
   * 平板常规（全屏）模式：推送原生内容边界，并把 ArkUI 侧的避让值同步过去。
   *
   * 真全沉浸（PAD_IMMERSIVE_HIDE_SYSTEM_BAR = true）下系统栏已隐藏，避让恒为 0：
   * 内容 = 整个 drawableRect，不扣任何边。
   *
   * ★ 这里**不能**采信 getWindowAvoidArea 的返回值：系统栏被隐藏后，避让区并不会
   *   随之清零（沉浸式的语义就是"布局铺满、但避让区仍然告诉你系统栏在哪"）。
   *   照抄它会让内容白白缩进一块、四周留出空白 —— 那是"不沉浸"的另一种表现。
   *   所以只有关掉该开关（回到旧的取色方案）时才去读避让区。
   *
   * 用于 avoidAreaChange 与窗口重新显示（后台重开）两条路径。
   */
  private pushPadContentBound(windowClass: window.Window): void {
    let statusBarHeight = 0;
    let navIndicatorHeight = 0;
    if (!PAD_IMMERSIVE_HIDE_SYSTEM_BAR) {
      try {
        statusBarHeight = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      } catch (err) {
        statusBarHeight = 0;
      }
      try {
        navIndicatorHeight =
          windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      } catch (err) {
        navIndicatorHeight = 0;
      }
    }
    // 同步 ArkUI 页面避让值（全沉浸下为 0，页面上不再有色条占位）
    if (this.padStorage !== undefined) {
      this.padStorage.setOrCreate('statusBarHeight', statusBarHeight);
      this.padStorage.setOrCreate('navIndicatorHeight', navIndicatorHeight);
    }
    this.displayAdapter?.setStatusBarHeight(statusBarHeight);
    if (deviceInfo.sdkApiVersion >= 20) {
      this.nativeContext.OnAvoidAreaChangeCallback(statusBarHeight);
    }

    const prop = windowClass.getWindowProperties();
    //The current system has a timing issue where the drawableRect lags in updating during mode switching.
    //Here, when switching to normal mode, the drawableRect is set to 0
    //to temporarily maintain normal performance until the issue is resolved.
    prop.drawableRect.height = prop.drawableRect.height + prop.drawableRect.top;
    prop.drawableRect.top = 0;

    let windowBound: window.Rect = {
      left: prop.windowRect.left + prop.drawableRect.left,
      top: prop.windowRect.top + prop.drawableRect.top + statusBarHeight,
      width: prop.drawableRect.width,
      height: prop.drawableRect.height - statusBarHeight - navIndicatorHeight,
    };
    this.nativeContext.OnWindowRectChange(this.xcomponentId, windowBound, 0);
    LogUtil.info(TAG, `pushPadContentBound statusBar=${statusBarHeight} nav=${navIndicatorHeight}`);
  }

  private needDarkMode(): boolean {
    let context = this.getWindowContext() as common.UIAbilityContext;
    let currentColorMode: ConfigurationConstant.ColorMode | undefined = context.config.colorMode;
    if (!currentColorMode) {
      LogUtil.warn(TAG, 'Can not get current color mode from window: ' + this.xcomponentId);
    }
    return this.useDarkMode || currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private setDarkModeButton(window: window.Window) {
    let isPadDarkButtonSupported = deviceInfo.deviceType === 'tablet' && deviceInfo.sdkApiVersion >= 18;
    if (deviceInfo.deviceType !== '2in1' && !isPadDarkButtonSupported) {
      return;
    }
    try {
      let buttonStyle: window.DecorButtonStyle = {
        colorMode: ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      };
      window.setDecorButtonStyle(buttonStyle);
    } catch (exception) {
      LogUtil.error(TAG, 'Failed to set the style of button: ' + JSON.stringify(exception));
    }
  }

  private notifyWindowStatusChange(status: window.WindowStatusType) {
    this.nativeContext.OnWindowStatusChange(this.xcomponentId, status);

    // 窗口形态刚变（进/出自由多窗、最大化 / 还原、全屏）：系统有可能在新形态下把
    // 标题栏三键**恢复显示** —— 平板上没有别的地方会再关它，所以每次形态变化都重新
    // 压一遍。非平板、或本窗口要系统原生标题栏时，该函数内部会直接返回。
    if (PAD_HIDE_SYSTEM_CAPTION_BUTTONS && this.hideTitleBar && deviceInfo.deviceType === 'tablet') {
      try {
        const win: window.Window | undefined = this.getWindow();
        if (win !== undefined) {
          this.applySystemCaptionButtonPolicy(win);
        }
      } catch (err) {
        LogUtil.warn(TAG, 'pad policy: re-assert caption buttons skipped: ' + JSON.stringify(err));
      }
    }

    if (status === window.WindowStatusType.MINIMIZE || this.deviceModeChangeEvent === undefined) {
      return;
    }
    LogUtil.info(TAG, 'Send device mode change event, xcomponentId: ' +
      this.xcomponentId + ', deviceModeChangeEvent: ' +
      this.deviceModeChangeEvent + ', status: ' + status);
    this.nativeContext.OnDeviceModeChange(this.xcomponentId, this.deviceModeChangeEvent, status);
    this.setDeviceModeChangeEvent(undefined);
  }
};
