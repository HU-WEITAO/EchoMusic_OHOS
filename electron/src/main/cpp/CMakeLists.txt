# AVScreenCapture 内录音频模块（听歌识曲 · 系统音频）
#
# 产物 libecho_screen_capture.so 已预编译并放在 electron/libs/arm64-v8a/，
# 因此 hvigor 的 HAP 构建不需要 externalNativeOptions，直接随 collectAllLibs 打包。
# 本文件用于在 SDK 升级后重新编译该 so（OHOS NDK 交叉编译）。
#
# 手动复现（Git Bash，等价于本 CMake 配置）：
#   CLANG="D:/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/bin/clang++.exe"
#   SYSROOT="D:/Huawei/DevEco Studio/sdk/default/openharmony/native/sysroot"
#   LIB="$SYSROOT/usr/lib/aarch64-linux-ohos"
#   "$CLANG" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -std=c++17 \
#       -fPIC -shared -O2 -I"$SYSROOT/usr/include" \
#       -o ../../../libs/arm64-v8a/libecho_screen_capture.so echo_screen_capture.cpp \
#       -L"$LIB" -lnative_avscreen_capture -lnative_media_core \
#       -l:libace_napi.z.so -l:libhilog_ndk.z.so -ldl
#
# 注意：libace_napi / libhilog_ndk 的真实文件名带 .z，必须用 -l:<完整名>，
#       直接写 -lace_napi / -lhilog_ndk 会报 unable to find library。

cmake_minimum_required(VERSION 3.16)
project(echo_screen_capture CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED OHOS_NATIVE_SYSROOT)
  set(OHOS_NATIVE_SYSROOT "$ENV{DEVECO_SDK_HOME}/default/openharmony/native/sysroot")
endif()
set(OHOS_NATIVE_LIBS "${OHOS_NATIVE_SYSROOT}/usr/lib/aarch64-linux-ohos")

add_library(echo_screen_capture SHARED echo_screen_capture.cpp)

target_include_directories(echo_screen_capture PRIVATE "${OHOS_NATIVE_SYSROOT}/usr/include")
target_link_directories(echo_screen_capture PRIVATE "${OHOS_NATIVE_LIBS}")
target_link_libraries(echo_screen_capture PRIVATE
  native_avscreen_capture
  native_media_core
  "${OHOS_NATIVE_LIBS}/libace_napi.z.so"
  "${OHOS_NATIVE_LIBS}/libhilog_ndk.z.so"
  dl
)
