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
 
import { WebNodeHandleWindow } from 'web_engine';
import CustomChildProcess from '../process/CustomChildProcess';
import { KeyCode } from '@kit.InputKit';

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
struct NodeHandleWindow {
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
 
  aboutToAppear(): void {
    // registerUpdateStyleFunction
    this.updateStyle.registerUpdateStyleFunction(this.xcomponentId, this.initStyle, (style: IStyleData) => {
      this.backgroundColor_ = `#${style.backgroundColor}`;
      this.opacity_ = style.opacity;
    });
  }
 
  aboutToDisappear(): void {
    // removeUpdateStyleFunction
    this.updateStyle.removeUpdateStyleFunction(this.xcomponentId);
  }
 
  build() {
    // 平板常规模式已改为"真正隐藏状态栏与小横条"（见 web_engine/common/Constants.ets
    // 的 PAD_IMMERSIVE_HIDE_SYSTEM_BAR）：系统栏位置不再需要色条去补色，
    // 原生内容直接铺满整屏 —— 原先的「顶部色条 + 内容 + 底部色条」三段式布局随之取消，
    // 那条 400ms 一次的全窗口截屏取色链路（ImmersiveColorSampler）也一并删除。
    Row() {
      WebNodeHandleWindow()
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
