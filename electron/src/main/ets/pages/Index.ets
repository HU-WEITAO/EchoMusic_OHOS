// Copyright (c) 2024 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import { WebWindow } from 'web_engine';
import { KeyCode } from '@kit.InputKit';
import CustomChildProcess from '../process/CustomChildProcess';

interface IStyleData {
  backgroundColor: string,
  opacity: number
};

interface IUpdateStyle {
  registerUpdateStyleFunction: Function,
  removeUpdateStyleFunction: Function
};

CustomChildProcess.toString();
let storage = LocalStorage.getShared();
@Entry(storage)
@Component
struct Index {
  @LocalStorageLink('updateStyle') updateStyle: IUpdateStyle = {
    registerUpdateStyleFunction: (id: string, initStyle: IStyleData, func: (style: IStyleData) => void) => {},
    removeUpdateStyleFunction: (id: string) => {}
  };
  @LocalStorageLink('xcomponentId') xcomponentId: string = '';
  // 沉浸式：状态栏/小横条背后的底色跟随系统深浅色，避免深色模式下出现白色断带
  @LocalStorageProp('useDarkMode') useDarkMode: boolean = false;

  private initStyle: IStyleData = {
    backgroundColor: 'ffffffff',
    opacity: 1
  };

  @State private backgroundColor_: string =
    this.useDarkMode ? '#FF26262A' : `#${this.initStyle.backgroundColor}`;
  @State private opacity_: number = this.initStyle.opacity;

  aboutToAppear() {
    // registerUpdateStyleFunction
    this.updateStyle.registerUpdateStyleFunction(this.xcomponentId, this.initStyle, (style: IStyleData) => {
      this.backgroundColor_ = `#${style.backgroundColor}`;
      this.opacity_ = style.opacity;
    });
  }

  aboutToDisappear() {
    // removeUpdateStyleFunction
    this.updateStyle.removeUpdateStyleFunction(this.xcomponentId);
  }

  build() {
    // 平板常规模式已改为"真正隐藏状态栏与小横条"（见 web_engine/common/Constants.ets
    // 的 PAD_IMMERSIVE_HIDE_SYSTEM_BAR）：系统栏位置不再需要色条去补色，
    // 原生内容直接铺满整屏 —— 原先的「顶部色条 + 内容 + 底部色条」三段式布局随之取消，
    // 那条 400ms 一次的全窗口截屏取色链路（ImmersiveColorSampler）也一并删除。
    Row() {
      WebWindow()
    }.onKeyEvent((event?: KeyEvent) => {
      if (event) {
        if (event.type == KeyType.Down && event.keyCode == KeyCode.KEYCODE_ESCAPE) {
          event.stopPropagation();
        }
      }
    })
    .backgroundColor(this.backgroundColor_)
    .opacity(this.opacity_)
    .width('100%')
    .height('100%')
  }
}
