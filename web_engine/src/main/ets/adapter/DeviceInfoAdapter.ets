/*
 * Copyright (c) 2023-2025 Huawei Device Co., Ltd.
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this list of
 *    conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice, this list
 *    of conditions and the following disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors may be used
 *    to endorse or promote products derived from this software without specific prior written
 *    permission.
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
 
import { injectable } from 'inversify';
import Inject from '../common/InjectModule';
import { ChangeEventType, DeviceMode, NativeContext } from '../interface/CommonInterface';
import JsBindingUtils from '../utils/JsBindingUtils';
import { ContextType } from '../common/Constants';
import { deviceInfo, settings } from '@kit.BasicServicesKit';
import LogUtil from '../utils/LogUtil';
import { AbilityManager } from '../common/AbilityManager';
 
const TAG: string = 'DeviceInfoAdapter';
 
@injectable()
export class DeviceInfoAdapter{
  private isRegisterDeviceModeChange: boolean = false;
  private nativeContext: NativeContext =
    JsBindingUtils.getNativeContext(ContextType.kMainProcess);
  private deviceMode: DeviceMode = DeviceMode.kPcMode;
  private abilityManager: AbilityManager = Inject.get(AbilityManager);;
 
  /**
   * 在**第一扇窗口创建之前**同步一次设备窗口模式。
   *
   * 背景（2026-09-19 排查）：deviceMode 的初值是 kPcMode，而唯一的同步入口
   * registerDeviceModeChange 原先只在 WebAbility.onPadWindowStageCreate（平板
   * 分支）里被调用——也就是说**首扇窗口走过的所有 isNormalWindowMode() /
   * isFreeWindowsMode() 判断拿到的都是 kPcMode**：
   *   - 平板模式下：启动时误判为 PC 模式 → updateAvoidAreaStatus 隐掉小横条、
   *     紧接着又被重新显示（启动瞬间窗口抽动）；WebNodeHandleWindow 首帧不扣
   *     状态栏高度（内容错位、显示异常）；标题栏按钮走 PC 分支。
   *   - 2in1 / PC 模式下：永远判不出「自由窗口模式」，AppWindowAdapter 里
   *     「残留整屏尺寸」的启动兜底直接失效（表现为打开就铺满）。
   * 由 UIAbility.onCreate 在开窗前调用本方法即可让后续所有判断拿到正确值。
   */
  public initWindowMode(context: Context) : void {
    // 1) 先同步模式本身：这一步与观察者注册解耦 —— 观察者注册失败
    //    （registerKeyObserver 返回 false）也必须让模式先正确起来。
    try {
      this.updateDeviceMode(this.getDeviceModeFromSystem(context));
    } catch (err) {
      LogUtil.error(TAG, 'initWindowMode sync failed, err:' + JSON.stringify(err));
    }
    // 2) 再补齐「平板模式 ↔ PC 模式」运行期切换的监听（内部幂等）
    try {
      this.registerDeviceModeChange(context);
    } catch (err) {
      LogUtil.error(TAG, 'initWindowMode observer failed, err:' + JSON.stringify(err));
    }
  }
 
  public registerDeviceModeChange(context: Context) : void {
    if (this.isRegisterDeviceModeChange) {
      return;
    }
 
    let res: boolean = settings.registerKeyObserver(context,
      'window_pcmode_switch_status', settings.domainName.USER_PROPERTY, () => {
        this.updateWindowDeviceModeSwitch(context);
      });
    if (!res) {
      LogUtil.error(TAG, 'Failed to register window_pcmode_switch_status.');
      return;
    }

    this.updateDeviceMode(this.getDeviceModeFromSystem(context));
    let proxyList = this.abilityManager.getProxyList();
    for (let i = 0; i < proxyList.length; i++) {
      this.abilityManager.getProxy(proxyList[i].getWindowId())?.updateAvoidAreaStatus(false);
    }

    this.isRegisterDeviceModeChange = true;
  }
 
  private updateWindowDeviceModeSwitch(context: Context) : void {
    try {
      this.updateDeviceMode(this.getDeviceModeFromSystem(context));
 
      let proxyList = this.abilityManager.getProxyList();
      for (let i = 0; i < proxyList.length; i++) {
        this.abilityManager.getProxy(proxyList[i].getWindowId())?.updateAvoidAreaStatus(false);
        if (this.deviceMode === DeviceMode.kNormalWindowMode) {
          this.abilityManager.getProxy(proxyList[i].getWindowId())?.setDeviceModeChangeEvent(ChangeEventType.CHANGE_TO_NORMAL_MODE);
        } else if (this.deviceMode === DeviceMode.kFreeWindowsMode) {
          this.abilityManager.getProxy(proxyList[i].getWindowId())?.setDeviceModeChangeEvent(ChangeEventType.CHANGE_TO_FREE_MODE);
        }
      }
    } catch (err) {
      LogUtil.error(TAG, 'Failed to update window devicemode, err:' + JSON.stringify(err));
    }
  }
 
  /**
   * 判定当前设备窗口模式。
   *
   * 系统里其实有**两个**互相独立的开关，必须一起看，只看一个会判错：
   *   - `isSystemModePc`：系统是否处于「电脑模式」。它决定窗口由**系统**全屏掌管，
   *     还是交给应用当桌面窗口用。WebAbility.onWindowStageCreate 触发
   *     onPadWindowStageCreate（沉浸避让那一整套）用的就是它。
   *   - `window_pcmode_switch_status`：窗口是否按自由窗口/多窗渲染。
   *
   * 关键坑（2026-09-19 定位）：支持「多窗 / 电脑模式」的平板上，
   * `window_pcmode_switch_status` 可能是 `'true'` —— 只读它就会把一台**平板**
   * 判成 kFreeWindowsMode，于是「启动尺寸兜底」「开窗几何预落位」「setBounds
   * 整屏收敛」这些**只在 PC 上才成立**的几何干预全部启动，与系统的全屏布局相互
   * 拉扯：启动过程窗口/内容每帧互推，表现为「极其抖动、页面点不动」，而模拟器
   * （没有这两个开关、默认走常规模式）完全正常。
   *
   * 所以：**先按 `isSystemModePc` 判**，平板形态且系统没开电脑模式 → 一律
   * kNormalWindowMode（窗口几何交还系统，应用侧不干预）。这个条件与
   * WebAbility.onWindowStageCreate 里 `deviceType === 'tablet' && isPCStatus !== 'true'`
   * 完全一致，保证「谁掌管窗口」与「走哪套避让逻辑」不会各说各话。
   */
  private getDeviceModeFromSystem(context: Context) : DeviceMode {
    let isPcSystemMode: string = '';
    try {
      isPcSystemMode = settings.getValueSync(context, 'isSystemModePc', '',
        settings.domainName.USER_PROPERTY);
      LogUtil.info(TAG, 'Get isSystemModePc value:' + isPcSystemMode +
        ', deviceType:' + deviceInfo.deviceType);
    } catch (err) {
      LogUtil.warn(TAG, 'Get isSystemModePc failed: ' + JSON.stringify(err));
    }
    if (deviceInfo.deviceType === 'tablet' && isPcSystemMode !== 'true') {
      return DeviceMode.kNormalWindowMode;
    }

    let value = settings.getValueSync(context, 'window_pcmode_switch_status', 'false',
      settings.domainName.USER_PROPERTY);
    LogUtil.info(TAG, 'Get devicemode from system window_pcmode_switch_status, ' +
      'value:' + value);

    let newDeviceMode = value === 'true' ? DeviceMode.kFreeWindowsMode : DeviceMode.kNormalWindowMode;
    return newDeviceMode;
  }
 
  private updateDeviceMode(newDeviceMode: DeviceMode) : void {
    if (this.deviceMode === newDeviceMode) {
      return;
    }
    this.deviceMode = newDeviceMode;
    LogUtil.info(TAG, 'device window mode -> ' + (newDeviceMode === DeviceMode.kFreeWindowsMode
      ? 'kFreeWindowsMode' : newDeviceMode === DeviceMode.kNormalWindowMode
        ? 'kNormalWindowMode' : 'kPcMode'));
    this.nativeContext.UpdateWindowDeviceModeSwitchCB(newDeviceMode);
  }
 
  public isPcMode() : boolean {
    return this.deviceMode === DeviceMode.kPcMode;
  }
 
  /**
   * 「PC 语义」模式：2in1 默认态 (kPcMode) 与自由窗口态 (kFreeWindowsMode)。
   *
   * 专供「只在 PC 上成立、平板上必须跳过」的分支使用（如 maximize 后不需要再按
   * 避让区重排布局）。早前这些分支写的是 isPcMode()，而 isPcMode() 实际含义是
   * 「deviceMode 还没初始化过」——一旦按 initWindowMode 把模式同步正确，
   * 2in1/PC 会变成 kFreeWindowsMode，isPcMode() 就为假，行为会被意外改变。
   */
  public isPcOrFreeWindowsMode() : boolean {
    return this.deviceMode === DeviceMode.kPcMode || this.deviceMode === DeviceMode.kFreeWindowsMode;
  }
 
  public isNormalWindowMode() : boolean {
    return this.deviceMode === DeviceMode.kNormalWindowMode;
  }
 
  public isFreeWindowsMode() : boolean {
    return this.deviceMode === DeviceMode.kFreeWindowsMode;
  }

  /** 系统主窗尺寸记忆（setWindowRectAutoSave）当前是否已启用 */
  private windowRectAutoSave: boolean = false;

  public markWindowRectAutoSave(enabled: boolean) : void {
    this.windowRectAutoSave = enabled;
  }

  /**
   * 系统是否已经在替应用管理主窗矩形（尺寸 + 位置）。**仅主窗（browser1）会开启**
   * （见 WebBaseAbility.enableWindowRectAutoSave）。
   *
   * 为真时，窗口**从被创建的那一刻起**就是上次关闭时的矩形 —— 系统启动页与主窗
   * 天然同框，观感上不再有「两个窗口」的切换。此时应用侧任何 move / resize 都会
   * 把这段过渡重新拉开，所以 AppWindowAdapter 的开窗几何落位必须让路。
   * 唯一的例外是「当前尺寸已基本等于整屏」（记忆里混进了整屏尺寸），仍需收敛，
   * 见 AppWindowAdapter.applyBoundsToExistingWindow。
   */
  public isWindowRectAutoSave() : boolean {
    return this.windowRectAutoSave;
  }

}