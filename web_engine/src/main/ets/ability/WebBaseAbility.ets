// Copyright (c) 2024 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import UIAbility from '@ohos.app.ability.UIAbility';
import LogUtil from '../utils/LogUtil';
import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import JsBindingUtils from '../utils/JsBindingUtils';
import { ChangeEventType, NativeContext, WindowPreferences } from '../interface/CommonInterface';
import { CommandType, ConfigData, ContextType, PAD_IMMERSIVE_HIDE_SYSTEM_BAR } from '../common/Constants';
import CheckEmptyUtils from '../utils/CheckEmptyUtils';
import { WebProxy } from '../interface/WebProxy';
import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import Inject from '../common/InjectModule';
import { DeviceInfoAdapter } from '../adapter/DeviceInfoAdapter';
import { systemShare } from '@kit.ShareKit';
import { CmdArgsHelper } from '../utils/CmdArgsHelper';
import { ContinueAbility } from './ContinueAbility';

const TAG: string = 'WebBaseAbility';
const SHARE_ACTION: string = 'ohos.want.action.sendData';

interface NormalizedSharedRecord {
  utd?: Object | string | number | boolean;
  content?: Object | string | number | boolean;
  uri?: Object | string | number | boolean;
  title?: Object | string | number | boolean;
  description?: Object | string | number | boolean;
}

export class WebBaseAbility extends UIAbility implements WebProxy {
  protected xcomponentId: string = '';
  protected startUri: string = '';
  protected windowStage: window.WindowStage | undefined = undefined;
  protected nativeContext: NativeContext =
    JsBindingUtils.getNativeContext(ContextType.kMainProcess);
  protected hideTitleBar: boolean = true;
  protected originWindowId: number = -1;
  protected useDarkMode: boolean = false;
  protected appId: string = '';
  protected deviceModeChangeEvent: ChangeEventType | undefined = undefined;
  private continueAbility: ContinueAbility | undefined = undefined;

  // Electron
  protected cmdArgs: Array<string> = [];
  protected minimizable: boolean = !this.hideTitleBar;
  protected maximizable: boolean = !this.hideTitleBar;
  protected closable: boolean = !this.hideTitleBar;
  protected alwaysOntop: boolean = false;
  protected resizable: boolean = true;
  protected focusable: boolean = true;
  protected isModal: boolean = false;
  protected isPanel: boolean = false;

  private initParameters(want: Want) {
    if (want && want.parameters) {
      if (want.parameters['xcomponentId'] !== undefined) {
        this.xcomponentId = want.parameters['xcomponentId'] as string;
      }
      if (want.parameters["useDarkMode"] !== undefined) {
        this.useDarkMode = want.parameters['useDarkMode'] as boolean;
      }
      if (want.parameters["hideTitleBar"] !== undefined) {
        this.hideTitleBar = want.parameters['hideTitleBar'] as boolean;
      }
      if (want.parameters['minimizable'] !== undefined) {
        this.minimizable = want.parameters['minimizable'] as boolean;
      }
      if (want.parameters['maximizable'] !== undefined) {
        this.maximizable = want.parameters['maximizable'] as boolean;
      }
      if (want.parameters['closable'] !== undefined) {
        this.closable = want.parameters['closable'] as boolean;
      }
      if (want.parameters['focusable'] !== undefined) {
        this.focusable = want.parameters['focusable'] as boolean;
      }
      if (want.parameters['isPanel'] !== undefined) {
        this.isPanel = want.parameters['isPanel'] as boolean;
      }
      this.cmdArgs = CmdArgsHelper.getCmdArgs(want.parameters['cmdArgs']);
      if (want.parameters["appId"] !== undefined) {
        this.appId = want.parameters['appId'] as string;
      }
      if (want.parameters["webappWindow"] !== undefined && want.parameters["webappWindow"] !== '') {
        this.appId = "--app-id=" + want.parameters['webappWindow'] as string;
      }

      let args = want.parameters['cmdArgs'];
      this.cmdArgs = CmdArgsHelper.getCmdArgs(args);
    }

    if (want["uri"]) {
      let storePath = want['uri'] as string;
      // convert storage path to uri
      this.startUri = storePath.replace("file://docs/", "file:///");
    }
  }

  protected getContentPath(): string {
     if (this.nativeContext.IsSupportNodeHandleFeature()) {
      return 'pages/NodeHandleWindow';
    } else {
      return 'pages/Index';
    }
  }

  private getContinueAbility(): ContinueAbility {
    if (this.continueAbility === undefined) {
      this.continueAbility = new ContinueAbility(this.context, this.nativeContext);
    }
    return this.continueAbility;
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    this.initParameters(want);
    this.handleSharedData(want);

    if (CheckEmptyUtils.isEmpty(this.xcomponentId)) {
      LogUtil.info(TAG, 'onCreate, Allocate xcomponent id');
      let widgetId = this.nativeContext.ExecuteCommand(CommandType.kGetWidget, {}).widget_Id;
      this.xcomponentId = ConfigData.WINDOW_PREFIX + widgetId;
    }

    this.handleContinueRestore(want, launchParam);
  }

  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    return this.getContinueAbility().onContinue(wantParam);
  }

  protected handleContinueRestore(want: Want, launchParam: AbilityConstant.LaunchParam) {
    this.getContinueAbility().handleContinueRestore(want, launchParam);
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    this.windowStage = windowStage;
    // 主窗尺寸记忆：让「系统启动页」与「应用主窗」从第一帧起就是同一个矩形，
    // 消除「先弹出一个启动窗口、紧接着又换成另一个窗口」的过渡。详见方法注释。
    this.enableWindowRectAutoSave(windowStage);
    this.originWindowId = windowStage?.getMainWindowSync().getWindowProperties().id;
    // 诊断用：启动页阶段系统给主窗的初始矩形 —— 用来核对「启动页」与「主窗」是否同框。
    // 若这一行的矩形与 [launchBounds] 日志里的 requested 不一致，就是两段几何的来源。
    try {
      const mainRect = windowStage?.getMainWindowSync()?.getWindowProperties().windowRect;
      LogUtil.info(TAG, `[StartWin] main window rect at stage-create: ` +
        `${mainRect?.width}x${mainRect?.height}@(${mainRect?.left},${mainRect?.top}), ` +
        `deviceType=${deviceInfo.deviceType}, sdk=${deviceInfo.sdkApiVersion}, ` +
        `xcomponentId=${this.xcomponentId}`);
    } catch (err) {
      LogUtil.warn(TAG, '[StartWin] read main window rect failed: ' + JSON.stringify(err));
    }
    // Ensure the distributed permission is granted ahead of any future
    // continuation (file) restore.
    this.getContinueAbility().requestDistributedPermissionIfNeeded();
  }

  /**
   * 开启「主窗尺寸记忆」（setWindowRectAutoSave）。
   *
   * 背景（2026-09-19 排查）：桌面冷启动时，**系统启动页**与**应用主窗**用的是
   * 同一个矩形 —— 启动页先出现在系统给的默认几何上，之后应用（Electron 侧）才
   * 把窗口挪到它自己记住的尺寸/位置。两段矩形不同，观感就是「点图标后先弹出一个
   * 启动窗口，这个页面消失的同时又打开主程序，两者大小位置不同」。
   *
   * 打开尺寸记忆后，系统在**创建窗口那一刻**就直接用上次关闭时的矩形，启动页与
   * 主窗天然同框，这段切换不再存在。系统侧的记忆规则还顺手解决了「平板全屏尺寸
   * 被带到 PC 模式」：自由窗口记住尺寸/位置，全屏、沉浸、最小化状态记住的都是
   * **进入该状态前的自由窗口矩形**，不会再留下整屏尺寸。
   *
   * 仅对主窗（browser1）启用；非 2in1 / 非自由窗口形态下系统会忽略该设置
   * （不报错、不生效），因此平板形态没有副作用。
   */
  private enableWindowRectAutoSave(windowStage: window.WindowStage): void {
    if (this.xcomponentId !== ConfigData.DEFAULT_WINDOW_ID) {
      return;
    }
    try {
      if (deviceInfo.sdkApiVersion >= 17) {
        // 双参重载：按窗口 id 单独记忆，要求 UIAbility 的 launchType 为 specified
        //（本应用 EntryAbility 正是 specified，见 electron/src/main/module.json5）
        windowStage.setWindowRectAutoSave(true, true)
          .then(() => {
            Inject.get(DeviceInfoAdapter)?.markWindowRectAutoSave(true);
            LogUtil.info(TAG, '[StartWin] setWindowRectAutoSave(true, true) succeeded');
          })
          .catch((err: BusinessError) => {
            Inject.get(DeviceInfoAdapter)?.markWindowRectAutoSave(false);
            LogUtil.warn(TAG, `[StartWin] setWindowRectAutoSave(true, true) failed: ` +
              `code=${err.code}, message=${err.message}`);
          });
      } else if (deviceInfo.sdkApiVersion >= 14) {
        windowStage.setWindowRectAutoSave(true)
          .then(() => {
            Inject.get(DeviceInfoAdapter)?.markWindowRectAutoSave(true);
            LogUtil.info(TAG, '[StartWin] setWindowRectAutoSave(true) succeeded');
          })
          .catch((err: BusinessError) => {
            Inject.get(DeviceInfoAdapter)?.markWindowRectAutoSave(false);
            LogUtil.warn(TAG, `[StartWin] setWindowRectAutoSave(true) failed: ` +
              `code=${err.code}, message=${err.message}`);
          });
      } else {
        LogUtil.info(TAG, `[StartWin] sdkApiVersion ${deviceInfo.sdkApiVersion} < 14, ` +
          `window rect auto-save is unavailable`);
      }
    } catch (err) {
      LogUtil.warn(TAG, '[StartWin] setWindowRectAutoSave threw: ' + JSON.stringify(err));
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleSharedData(want);
  }

  // implements WebProxy interface
  getWindowStage(): window.WindowStage | undefined {
    return this.windowStage;
  }

  getWindow(): window.Window | undefined {
    return this.windowStage?.getMainWindowSync();
  }

  getWindowContext(): common.Context {
    return this.context;
  }

  getWindowId(): string {
    return this.xcomponentId;
  }

  getOriginWindowId(): number {
    return this.originWindowId;
  }

  closeWindow() {
    this.context.terminateSelf()
      .then(() => {
        LogUtil.info(TAG, 'terminate Self id: ' + this.getWindowId());
      })
      .catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to terminate Self: ' + JSON.stringify(err));
      });
  }

  setWindowTitle(title: string) {
    this.context.setMissionLabel(title)
      .catch((err: BusinessError) => {
        LogUtil.error(TAG, 'Failed to set title: ' + JSON.stringify(err));
      });
  }

  createSubWindow(name: string): Promise<window.Window> {
    return new Promise<window.Window>((resolve, reject) => {
      if (!this.windowStage) {
        reject('Failed to get windowStage');
        return;
      }
      this.windowStage.createSubWindow(name)
        .then((data: window.Window) => {
          resolve(data);
        }).catch((error: BusinessError) => {
        reject(error);
      })
    });
  }

  isUIAbility(): boolean {
    return true;
  }

  public setDeviceModeChangeEvent(deviceModeChangeEvent: ChangeEventType | undefined) {
    this.deviceModeChangeEvent = deviceModeChangeEvent;
  }

  getWindowPreferences(): WindowPreferences {
    return {
      hideTitleBar: this.hideTitleBar,
      maximizable: this.maximizable,
      minimizable: this.minimizable,
      closable: this.closable
    };
  }

  setWindowPreferences(preferences: WindowPreferences) {
    this.hideTitleBar = preferences.hideTitleBar;
    this.maximizable = preferences.maximizable;
    this.minimizable = preferences.minimizable;
    this.closable = preferences.closable;
  }

  public updateAvoidAreaStatus(isFullScreen: boolean) {
    let windowClass = this.getWindow();
 
    // Set window to full screen.
    windowClass?.setWindowLayoutFullScreen(true).then(() => {
      LogUtil.info(TAG, 'Succeeded in setting the window layout to full-screen mode.');
    }).catch((err: BusinessError) => {
      LogUtil.error(TAG, 'Failed to set the window layout to full-screen mode. Cause:' + JSON.stringify(err));
    });
 
    // 平板常规（全屏）模式：真沉浸 —— 状态栏与小横条一并隐藏，内容铺满整屏。
    // （早前这里刻意**保留小横条**，再由应用内截屏取色、在小横条/状态栏位置铺两条
    //   假色条去"假装沉浸"，见 common/Constants.ets 的 PAD_IMMERSIVE_HIDE_SYSTEM_BAR。
    //   那条取色链路已整体删除，这里改为直接隐掉系统栏。）
    let padImmersive = false;
    try {
      const deviceAdapter = Inject.get(DeviceInfoAdapter);
      padImmersive = deviceInfo.deviceType === 'tablet' && deviceAdapter.isNormalWindowMode();
    } catch (err) {
      padImmersive = false;
    }

    // Hide the navigation bar here.
    // 平板常规模式 + 真全沉浸：隐藏小横条。
    // 关掉总开关时，平板常规模式仍按旧行为**保留**小横条（由应用内做底部避让 + 取色），
    // 这样这一个开关就能把整套行为（系统栏显隐 + 内容边界）完整地退回去。
    let keepNavIndicator: boolean = false;
    if (padImmersive && !PAD_IMMERSIVE_HIDE_SYSTEM_BAR) {
      keepNavIndicator = true;
    }
    if (!keepNavIndicator) {
      windowClass?.setSpecificSystemBarEnabled('navigationIndicator', false).then(() => {
        LogUtil.info(TAG, 'Succeeded in setting the navigation indicator to be invisible.');
      }).catch((err: BusinessError) => {
        LogUtil.error(TAG, `Failed to set the navigation indicator to be invisible. Code is ${err.code}, message is ${err.message}`);
      });
    }

    // The top status bar is set up to be hidden when in full-screen mode and displayed when maximized.
    // 参数语义：true = 显示，false = 隐藏。
    // 平板常规（全屏）模式下一并隐藏 —— 否则状态栏横在内容上方，沉浸感就破了。
    let showStatusBar: boolean = !isFullScreen;
    if (padImmersive && PAD_IMMERSIVE_HIDE_SYSTEM_BAR) {
      showStatusBar = false;
    }
    windowClass?.setSpecificSystemBarEnabled('status', showStatusBar).then(() => {
      LogUtil.info(TAG, 'Succeeded in setting the status bar to be invisible.');
    }).catch((err: BusinessError) => {
      LogUtil.error(TAG, `Failed to set the status bar to be invisible. Code is ${err.code}, message is ${err.message}`);
    });
  }

  private handleSharedData(want: Want): void {
    if (!want || want.action !== SHARE_ACTION) {
      return;
    }
    systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
      let records = data.getRecords();
      let sharedRecords: NormalizedSharedRecord[] = [];
      for (let i = 0; i < records.length; i++) {
        sharedRecords.push(this.normalizeSharedRecord(records[i]));
      }
      this.nativeContext.OnSharedDataReceived(JSON.stringify(sharedRecords));
    }).catch((err: BusinessError) => {
      LogUtil.error(TAG, 'Failed to get shared data: ' + JSON.stringify(err));
    });
  }

  private normalizeSharedRecord(record: systemShare.SharedRecord): NormalizedSharedRecord {
    let result: NormalizedSharedRecord = {};
    if (record.utd !== undefined && record.utd !== null) {
      result.utd = record.utd;
    }
    if (record.content !== undefined && record.content !== null) {
      result.content = record.content;
    }
    if (record.uri !== undefined && record.uri !== null) {
      result.uri = record.uri;
    }
    if (record.title !== undefined && record.title !== null) {
      result.title = record.title;
    }
    if (record.description !== undefined && record.description !== null) {
      result.description = record.description;
    }
    return result;
  }
};
