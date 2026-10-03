// Copyright (c) 2024 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export class ConfigData {
  static DOMAIN: number = 0x0000;
  static TAG: string = '[WebEngine]';
  static WINDOW_PREFIX: string = 'browser';
  static DEFAULT_WINDOW_ID: string = 'browser1';
  static INVALID_DISPLAY_ID: number = -1;
}
let configData = new ConfigData();
export default configData as ConfigData;

export enum PanAction {
  kStart = 0,
  kUpdate,
  kEnd,
  kCancel,
}

export enum ContextType {
  kMainProcess = 0,
  kRenderProcess,
  kCrashpadHandler,
}

export enum WebStatus {
  kInit = 0,
  kStart,
  kDestroy,
}

// Values must stay in sync with CommandType in
// ohos/adapter/browser/browser_adapter.h.
export enum CommandType {
  kNewWindow = 0,
  kNewWebContent = 1,
  kNewWidget = 2,
  kGetWidget = 3,
  kGetLastActiveWidget = 4,
  kOpenURL = 5,
  kAppQuit = 6,
  kAppExit = 7,
  kSecondInstance = 8,
  // Cross-device continuation (handoff). Must stay in sync with the native
  // CommandType enum in ohos/adapter/browser/browser_adapter.h.
  kSaveContinue = 9,
  kRestoreContinueData = 10,
  kRestoreContinueFile = 11,
  kTrayQuitRequest = 12,
};

/**
 * 平板「真全沉浸」总开关（默认 true）。
 *
 * true ：平板常规（全屏）模式下**直接隐藏状态栏与小横条**，原生内容铺满整屏。
 * false：回到旧行为 —— 保留小横条，并由应用按窗口像素取色、在系统栏位置铺两条
 *        假色条（旧实现 web_engine/src/main/ets/utils/ImmersiveColorSampler.ets，
 *        每 400ms 截一张整窗口位图做采样，3120×2080 下每次 24.8MB 的分配 + GPU
 *        回读，只为把两条窄带涂成"看起来像页面背景"的颜色；已整体删除，
 *        备份见 EchoMusic_OHOS-backups/*.bak-before-hidesysbar-*）。
 *
 * ★ 开关只有这一个：WebAbility（内容边界）与 WebBaseAbility（系统栏显隐）
 *   都读它，两边必须一致 —— 所以放在共享常量里，不要各自定义一份。
 */
export const PAD_IMMERSIVE_HIDE_SYSTEM_BAR: boolean = true;

/**
 * 平板「隐藏系统窗口三键」总开关（默认 true）。
 *
 * 背景：本应用在鸿蒙上是 `frame = false` + `titleBarStyle: 'hidden'` —— 窗口标题栏
 * **由应用自己画**（前端 Vue 的 WindowControls 组件，含最小化 / 关闭 / 全屏按钮，
 * 见 dist/assets/WindowControls-*.js），原生侧 hideTitleBar 因此为 true。
 *
 * 但 `setWindowDecorVisible(false)` 只隐藏标题栏本体，**右上角的"窗口三键"
 * （最大化/还原、最小化、关闭）默认仍然显示**（系统的设计意图：隐藏装饰栏是为了
 * 让页面铺到标题栏区域，三键保留给用户操作窗口）。结果就是系统三键压在应用自绘
 * 标题栏的右上角，看起来像"多了一层按钮"。
 *
 * 前端 WindowControls 在 openharmony 上是**无条件渲染**最小化/关闭按钮的
 * （源码里 `platform === 'openharmony'` 时该显示条件恒为 true），可见它本来就假定
 * "系统不画三键"。所以这里必须把系统三键关掉，否则两套按钮必然重叠。
 *
 * 为什么 PC 上没这个毛病：PC/2in1 的 deviceMode 是 kFreeWindowsMode，
 * 会走 `onWindowStageCreate` 里 `isNormalWindowMode() === false` 那条分支，
 * 本来就会调 `setWindowTitleButtonVisible(false, false, false)`；而**平板的
 * deviceMode 恒为 kNormalWindowMode**（见 DeviceInfoAdapter.getDeviceModeFromSystem
 * 的第一个 return），那条分支永远进不去，三键就一直保持默认可见。
 *
 * 置 false 可回退到"由系统画三键"的旧观感（代价是与应用自绘按钮重叠）。
 */
export const PAD_HIDE_SYSTEM_CAPTION_BUTTONS: boolean = true;
