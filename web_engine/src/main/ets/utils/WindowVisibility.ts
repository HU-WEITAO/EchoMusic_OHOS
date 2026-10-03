// Copyright (c) 2024 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import LogUtil from './LogUtil';

const TAG: string = 'WindowVisibility';

/** 「冗余 show 抑制」总开关。置 false 即完全回到原行为（每次都照调 showAbility）。 */
const SKIP_REDUNDANT_SHOW: boolean = true;

/** 「冗余 hide 抑制」总开关。与上面成对，避免「show 被压住、hide 却照做」反而把窗口藏掉。 */
const SKIP_REDUNDANT_HIDE: boolean = true;

/** 高频合并窗口（ms）：判定为高频后，同一方向的动作最多每这么久放行一次。 */
const STORM_COALESCE_MS: number = 1500;

/** 速率统计窗口长度（ms）。 */
const STORM_WINDOW_MS: number = 500;

/** 判定为「高频请求」的门槛：STORM_WINDOW_MS 内出现这么多次 show/hide 请求。 */
const STORM_MIN_REQUESTS: number = 5;

/** 主窗口的数字 id（详见 isMainWindow 的说明）。 */
const MAIN_WINDOW_ID: number = 1;

/** 被丢弃的请求的日志节流间隔（ms）——抖动时是 24 次/秒，不能每次都打。 */
const DROP_LOG_GAP_MS: number = 5000;

/**
 * 窗口可见性的**权威记录** + 冗余 show/hide 的抑制器。
 *
 * ## 为什么需要它
 *
 * 平板实机实测（2026-09-19，屏幕上直接读到的事件计数）：
 *
 * - `windowEvent#1`（`WINDOW_SHOWN`）**24 次/秒**
 * - `AppWindowAdapter.showWindow` 被调 **48 次/秒**（= 24 次「显示」+ 24 次「聚焦」：
 *   Electron 侧 `focus()` 在本工程里映射到 `activateWindow()` → `showWindow()`）
 *
 * 也就是说：**有人每秒 24 次要求「把主窗口显示出来」。**
 * 而在这台设备上，每一次 `showAbility()` 都会让系统重新播放一遍「窗口打开」动效 ——
 * 于是窗口永远停在开场动效的中间某一帧（截图里窗口是倾斜的、每张位置都不同），
 * 这就是用户看到的「在屏幕上乱蹦、根本没法用」。
 *
 * 调用方在 Electron 的 JS 里（`dist-electron/main/app-BOCPSy33.js`），本工程内能
 * 产生 `show + moveTop + focus` 的只有这几处：
 *
 * - `cb()`：显示主窗口，`isVisible() || show()` + `moveTop()` + `focus()`
 * - `plugins:host:show-on-top` 处理器：同样的 `isVisible() || show()` + `moveTop()` + `focus()`
 * - 托盘 / 媒体控制 / 全局快捷键 / mini-player 切回，最终都汇到 `cb()`
 *
 * 它们**都先问 `isVisible()`**。而在这台设备上 `isVisible()` 显然没有可靠地反映
 * 真实可见性（否则不会每秒调 24 次 `show()`），所以只能由**我们自己**记录真实状态，
 * 在 ArkTS 边界把重复的 show/hide 丢掉 —— 这是唯一能覆盖所有调用方的位置。
 *
 * ## 状态从哪来（必须来自系统事件，不能靠猜）
 *
 * `WebAbility` 里把系统回调喂进来，见 `noteVisible()` / `noteHidden()`：
 * `windowEvent` 的 `WINDOW_SHOWN` / `WINDOW_HIDDEN`、`windowVisibilityChange`、
 * `windowStageEvent` 的 SHOWN / HIDDEN，以及我们自己 `showAbility()` /
 * `hideAbility()` 的成功回调。只采信主窗口的事件，副窗口的显隐不污染主窗口状态。
 *
 * ## 两条抑制规则（都只影响「冗余」的请求，不改变正常使用）
 *
 * 1. **状态幂等**：窗口已经可见时再要求「显示」、已经不可见时再要求「隐藏」，
 *    对结果没有任何贡献，只会重放动效 —— 直接丢弃。
 * 2. **高频合并（反压）**：当请求速率本身很高（`STORM_MIN_REQUESTS` 次 /
 *    `STORM_WINDOW_MS` 内）时，同一方向的动作最多每 `STORM_COALESCE_MS` 放行一次。
 *    规则 1 已经把闭环掐死；规则 2 是**兜底**：万一可见性状态记录得不准，也不至于
 *    回到 24Hz。
 *
 * ## 失败模式（刻意设计成安全的）
 *
 * 最坏情况：状态记录错了（把「不可见」当成「可见」）⇒ 窗口被压制。此时规则 2 仍在
 * 生效 —— 每 `STORM_COALESCE_MS` 会**放行一次**，窗口最迟 1.5 秒内一定会重新出现。
 * 正常使用（低频请求）两条规则都不触发，一次都不会被拦。
 *
 * ## 抑制范围
 *
 * **只作用于主窗口**（`MAIN_WINDOW_ID`）。插件窗口、分享窗口等其它 id 一律原样放行 ——
 * 避免出现「窗口创建了却始终不显示」这种更难定位的问题。
 */
export class WindowVisibility {
  /** 最近一次「窗口可见」的系统事件时刻（0 = 还没收到过） */
  private static shownAtMs: number = 0;
  /** 最近一次「窗口不可见」的系统事件时刻（0 = 还没收到过） */
  private static hiddenAtMs: number = 0;

  /** 速率统计窗口起点 */
  private static reqWindowStartMs: number = 0;
  /** 速率统计窗口内的请求数（show + hide 合计） */
  private static reqCount: number = 0;

  private static lastShowPassMs: number = 0;
  private static lastHidePassMs: number = 0;
  private static skippedShows: number = 0;
  private static skippedHides: number = 0;
  private static lastDropLogMs: number = 0;

  /** 系统报告窗口可见（`windowEvent:SHOWN` / `windowVisibilityChange(true)` / 本工程 showAbility 成功） */
  static noteVisible(source: string): void {
    WindowVisibility.shownAtMs = Date.now();
    WindowVisibility.hiddenAtMs = 0;
    LogUtil.debug(TAG, `visible <- ${source}`);
  }

  /** 系统报告窗口不可见（`windowEvent:HIDDEN` / `windowVisibilityChange(false)` / 本工程 hideAbility 成功） */
  static noteHidden(source: string): void {
    WindowVisibility.hiddenAtMs = Date.now();
    LogUtil.debug(TAG, `hidden <- ${source}`);
  }

  /** 窗口当前是否可见（收到过 SHOWN，且其后没有 HIDDEN） */
  static isVisible(): boolean {
    return WindowVisibility.shownAtMs > 0 &&
      WindowVisibility.hiddenAtMs <= WindowVisibility.shownAtMs;
  }

  /**
   * 是否**有依据地**认为窗口已不可见。
   *
   * 与 `!isVisible()` 的区别：冷启动时还没收到过任何 SHOWN，`isVisible()` 也是 false，
   * 但那是「不知道」而不是「不可见」—— 那种情况下不该拦 hide（用户开机就想关到托盘
   * 是合理操作）。只有「见过 SHOWN 之后又来了 HIDDEN」才算确证不可见。
   */
  static isConfirmedHidden(): boolean {
    return WindowVisibility.shownAtMs > 0 &&
      WindowVisibility.hiddenAtMs > WindowVisibility.shownAtMs;
  }

  /**
   * 是否应该丢弃这次「让窗口显示」的请求。
   *
   * @param id 窗口 id（只用于判定是否主窗口）
   */
  static shouldSkipShow(id: number): boolean {
    if (!SKIP_REDUNDANT_SHOW || !WindowVisibility.isMainWindow(id)) {
      return false;
    }
    const now: number = Date.now();
    WindowVisibility.noteRequest(now);

    // 规则 1：窗口已可见 —— 再 show 一次只会重放动效
    if (WindowVisibility.isVisible()) {
      WindowVisibility.skippedShows++;
      WindowVisibility.logDrop(`skip show: window already visible (id=${id})`);
      return true;
    }

    // 规则 2：请求速率很高 ⇒ 同一方向最多每 STORM_COALESCE_MS 放行一次
    if (WindowVisibility.isStormy() &&
      now - WindowVisibility.lastShowPassMs < STORM_COALESCE_MS) {
      WindowVisibility.skippedShows++;
      WindowVisibility.logDrop(`skip show: high request rate (id=${id})`);
      return true;
    }

    WindowVisibility.lastShowPassMs = now;
    return false;
  }

  /**
   * 是否应该丢弃这次「让窗口消失」的请求（`hideWindow` / `minimize` 共用）。
   *
   * @param id 窗口 id（只用于判定是否主窗口）
   * @param action 日志用的动作名（'hideWindow' / 'minimize'）
   */
  static shouldSkipHide(id: number, action: string): boolean {
    if (!SKIP_REDUNDANT_HIDE || !WindowVisibility.isMainWindow(id)) {
      return false;
    }
    const now: number = Date.now();
    WindowVisibility.noteRequest(now);

    // 规则 1：窗口已经不可见 —— 再 hide 一次没有意义
    if (WindowVisibility.isConfirmedHidden()) {
      WindowVisibility.skippedHides++;
      WindowVisibility.logDrop(`skip ${action}: window already hidden (id=${id})`);
      return true;
    }

    // 规则 2：同「显示」侧
    if (WindowVisibility.isStormy() &&
      now - WindowVisibility.lastHidePassMs < STORM_COALESCE_MS) {
      WindowVisibility.skippedHides++;
      WindowVisibility.logDrop(`skip ${action}: high request rate (id=${id})`);
      return true;
    }

    WindowVisibility.lastHidePassMs = now;
    return false;
  }

  /**
   * 是否为主窗口。
   *
   * `AppWindowAdapter` 拿到的是 Electron 侧的数字窗口 id，`AbilityManager` 用
   * `ConfigData.WINDOW_PREFIX`（='browser'）把它归一成 `browser<N>`；而主窗口就是
   * `browser1`（= `ConfigData.DEFAULT_WINDOW_ID`，WebAbility 的 xcomponentId 也是它）。
   * 所以数字 id 1 即主窗口。
   */
  private static isMainWindow(id: number): boolean {
    return id === MAIN_WINDOW_ID;
  }

  /** 统计请求速率（滑动窗口的简化实现：窗口过期就清零重来） */
  private static noteRequest(now: number): void {
    if (now - WindowVisibility.reqWindowStartMs > STORM_WINDOW_MS) {
      WindowVisibility.reqWindowStartMs = now;
      WindowVisibility.reqCount = 0;
    }
    WindowVisibility.reqCount++;
  }

  /** 当前是否处于「高频请求」状态 */
  private static isStormy(): boolean {
    return WindowVisibility.reqCount >= STORM_MIN_REQUESTS;
  }

  /** 抖动时被丢弃的请求是 24 次/秒，日志按间隔节流，避免刷爆日志 */
  private static logDrop(message: string): void {
    const now: number = Date.now();
    if (now - WindowVisibility.lastDropLogMs < DROP_LOG_GAP_MS) {
      return;
    }
    WindowVisibility.lastDropLogMs = now;
    LogUtil.warn(TAG, `${message}; total skipped: show=${WindowVisibility.skippedShows}` +
      ` hide=${WindowVisibility.skippedHides}`);
  }
}
