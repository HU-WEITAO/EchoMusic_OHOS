/*
 * Copyright (c) 2023-2025 Huawei Device Co., Ltd.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors
 * may be used to endorse or promote products derived from this software without
 * specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
 
import { NativeContext, WindowBound } from '../interface/CommonInterface';
import LogUtil from '../utils/LogUtil';
import JsBindingUtils from '../utils/JsBindingUtils';
import { NodeContent, window } from '@kit.ArkUI';
import { ConfigData, ContextType, PAD_IMMERSIVE_HIDE_SYSTEM_BAR } from '../common/Constants';
import { NodeHandleManager } from '../common/NodeHandleManager';
import Inject from '../common/InjectModule';
import { ContextAdapter } from '../adapter/ContextAdapter';
import { MessageBox } from '../components/MessageBox';
import { IMessageBoxParams } from '../adapter/DialogAdapter';
import { AbilityManager } from '../common/AbilityManager';
import { DeviceInfoAdapter } from '../adapter/DeviceInfoAdapter';
import { CmdArgsHelper } from '../utils/CmdArgsHelper';

@Component
export struct WebNodeHandleWindow {
  private static TAG: string = 'WebNodeHandleWindow';
  @LocalStorageLink('xcomponentId') xComponentId: string = '';
  @LocalStorageLink('startUri') startUri: string = '';
  @LocalStorageLink('appId') appId: string = '';
  @LocalStorageLink('window') window: window.Window | undefined = undefined;
  @LocalStorageLink('statusBarHeight') statusBarHeight: number = 0;
  @LocalStorageProp('navIndicatorHeight') navIndicatorHeight: number = 0;
  @LocalStorageLink('cmdArgs') cmdArgs: string[] = [];
  private nativeContext: NativeContext = JsBindingUtils.getNativeContext(ContextType.kMainProcess);
  private nodeHandleManager = Inject.get(NodeHandleManager);
  private contextAdapter = Inject.get(ContextAdapter);
  private deviceInfoAdapter =  Inject.get(DeviceInfoAdapter);
  @State nodeContent: NodeContent = new NodeContent();
  private kBundleInstallDir = 'bundle-installation-dir';
  private abilityManager = Inject.get(AbilityManager);
  @State private messageBoxParams: IMessageBoxParams = {
    messageBoxSettings: undefined,
    icon: undefined,
    callback: () => {}
  };

  private dialogController: CustomDialogController = new CustomDialogController({
    builder: MessageBox({
      title: this.messageBoxParams.messageBoxSettings?.title,
      message: this.messageBoxParams.messageBoxSettings?.message,
      detail: this.messageBoxParams.messageBoxSettings?.detail,
      buttons: this.messageBoxParams.messageBoxSettings?.buttons,
      checkboxLabel: this.messageBoxParams.messageBoxSettings?.checkbox_label,
      checkboxChecked: this.messageBoxParams.messageBoxSettings?.checkbox_checked,
      icon: this.messageBoxParams?.icon,
      callback: this.messageBoxParams.callback
    }),
    cancel: () => {},
    autoCancel: false,
    alignment: DialogAlignment.Center,
    customStyle: false,
  })

  setMessageBoxParams() {
    const that = this;
    return (messageBoxParams: IMessageBoxParams) => {
      that.messageBoxParams = messageBoxParams;
    }
  }

  aboutToAppear(): void {
    LogUtil.info(WebNodeHandleWindow.TAG, 'WebNodeHandleWindow aboutToAppear ' + this.xComponentId);
    this.nodeHandleManager.addNodeContent(this.xComponentId, this.nodeContent);
    this.nativeContext.OnAbilityStartedCB(this.xComponentId);
    this.contextAdapter.setActiveWindow(this.xComponentId);
    this.abilityManager.addMessageBox({
      id: this.xComponentId,
      setMessageBoxParams: this.setMessageBoxParams(),
      dialogController: this.dialogController
    });
    this.setDefaultBounds();
    let vec_args = CmdArgsHelper.buildArgs(this.startUri, this.cmdArgs, this.appId);
    CmdArgsHelper.preProcessArgs(vec_args);
    this.nativeContext.runBrowser(vec_args);
  }
 
  aboutToDisappear(): void {
    this.nodeHandleManager.removeNodeContent(this.xComponentId);
  }
 
  build() {
    ContentSlot(this.nodeContent)
  }
 
  private setDefaultBounds() {
    if (this.xComponentId !== ConfigData.DEFAULT_WINDOW_ID) {
      return;
    }
 
    let prop = this.window?.getWindowProperties();
    if (prop) {
      let windowRect: WindowBound = {
        left: prop.windowRect.left,
        top: prop.windowRect.top,
        width: prop.windowRect.width,
        height: prop.windowRect.height
      }

      // 平板常规（全屏）模式下首帧就得按**真实避让区**裁剪：状态栏高度没扣 → 内容
      // 会被状态栏压住（表现为「打开后无法正常显示」），所以这里向窗口查一次。
      // 小横条高度沿用 LocalStorage 里的 navIndicatorHeight（由 WebAbility 的
      // onPadWindowStageCreate / avoidAreaChange 写入），这里不另行查避让区 ——
      // 多一路查询只会在启动阶段引入第三个不同的值。
      let statusBarHeight = this.statusBarHeight;
      let navIndicatorHeight = this.navIndicatorHeight;
      // 真全沉浸（PAD_IMMERSIVE_HIDE_SYSTEM_BAR）下系统栏已隐藏，避让恒为 0：不再向窗口
      // 查避让区 —— 查回来也是非 0（避让区不随系统栏显隐清零），照抄会让首帧就被缩进一块。
      // 此时 statusBarHeight / navIndicatorHeight 均来自 LocalStorage，而 WebAbility 写的就是 0。
      if (!PAD_IMMERSIVE_HIDE_SYSTEM_BAR && this.deviceInfoAdapter?.isNormalWindowMode() && this.window) {
        try {
          statusBarHeight = this.window.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
          this.statusBarHeight = statusBarHeight;
        } catch (error) {
          LogUtil.error(WebNodeHandleWindow.TAG, `getWindowAvoidArea(SYSTEM) error, error = ${JSON.stringify(error)}`);
        }
      }
      LogUtil.info(WebNodeHandleWindow.TAG,
        `setDefaultBounds statusBar=${statusBarHeight} navIndicator=${navIndicatorHeight}`);

      let drawableRect: WindowBound = {
        left: prop.drawableRect.left,
        top: prop.drawableRect.top + statusBarHeight,
        width: prop.drawableRect.width,
        // 底部同时扣除小横条（导航指示条）高度，避免内容底边被遮挡
        height: prop.drawableRect.height - statusBarHeight - navIndicatorHeight
      }
      let displayId = prop.displayId ?? ConfigData.INVALID_DISPLAY_ID;
      this.nativeContext.OnWindowInitSize(windowRect, drawableRect, displayId);
    }
 
    let state = this.window?.getWindowStatus();
    if (state) {
      this.nativeContext.OnWindowInitState(state);
    }
  }
}