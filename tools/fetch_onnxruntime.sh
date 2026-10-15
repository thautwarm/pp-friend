#!/usr/bin/env bash
#
# 下载官方的 ONNX Runtime 运行时库（Android 的 .so + 宿主测试用的 .dylib）。
#
# 为什么不用 ort 的 download-binaries：
# 它从 pyke 的 dfbin 拿静态库，而那份 aarch64-linux-android 产物是**用 GNU
# 工具链构建的** —— 引用 std::__cxx11 和 __isoc23_strtol 这些 Bionic 上根本
# 不存在的符号（实测：7729 处 __cxx11、0 处 __ndk1）。Android 的链接器默认
# `-z now`，dlopen 时必须把所有符号解析完，一个找不到整个库就加载失败：
#
#     dlopen failed: cannot locate symbol "__isoc23_strtoll"
#
# 表现是 Dart 侧 RustLib.init() 抛异常 → 主界面挂"断句引擎加载失败"。
# 这个坑静态检查看不出来：NEEDED 列表是空的、段对齐也是对的，问题全在符号上。
#
# 官方 Maven AAR 里的 libonnxruntime.so 是 NDK 构建的，静态链了 libc++，
# NEEDED 只有 libdl/liblog/libm/libc，干净。
#
# 用法：bash tools/fetch_onnxruntime.sh [android|host|all]   （默认 all）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# 版本下限是 1.24.3，**不要降回去**。
#
# 1.23.x 有一个 SME1/SME2 指令检测 bug：ORT 从 1.23.0 起把 fp32 GEMM 交给
# Arm KleidiAI，里面带了 SME2 微内核（`ptrue pn` / `ld1w {..}, pn/z` /
# `mov za0h.s[..], {z24.s-z27.s}`）。检测逻辑把这台机器判断成"能用 SME2"，
# 但它的 CPU 只报了 SME1（/proc/cpuinfo 有 `sme`、没有 `sme2`），于是执行到
# 第一条 SME2 指令就 SIGILL。官方 issue microsoft/onnxruntime#27884，
# SM8850/SM8845（骁龙 8 Elite Gen5 那代）全中，1.24.3 起修好。
#
# 1.23.2 时的表现：dlopen 成功、RustLib.init() 成功，一开始喂音频就整个进程
# 被 DEBUG 信号的 backtrace 全是 libonnxruntime.so —— 排查时别被"库能加载"
# 骗了，问题在库**内部**的指令层面。
#
# ort 侧（rust/Cargo.toml，rc.11 = API 23）不用动：OrtApi 是只追加的，
# 请求旧版本 API 时新运行时返回结构前缀相同，向后兼容。
ORT_VERSION="1.24.3"

SCOPE="${1:-all}"
case "$SCOPE" in
  android|host|all) ;;
  *) echo "用法：$0 [android|host|all]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- 工具

sha256_of() {
  if command -v shasum >/dev/null; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

# 下载到临时目录。**不往仓库里放还没校验过的文件** —— 校验通过才 cp 出去。
download() { # url dest
  [[ -f "$2" ]] && return 0
  echo "    下载 $1" >&2
  curl -fsSL --retry 3 --retry-delay 2 -o "$2.tmp" "$1"
  mv "$2.tmp" "$2"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ANDROID_DIR="android/app/src/main/jniLibs/arm64-v8a"
HOST_DIR="rust/.ort"

# ---------------------------------------------------------------- Android

fetch_android() {
  local aar="$WORK/onnxruntime-android.aar"
  local url="https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/$ORT_VERSION/onnxruntime-android-$ORT_VERSION.aar"
  local want_aar="67397e4a970e75617f765d2015ceaf911917e1d822276cfb5792744e8085cbce"
  local want_so="4d2318b3849abb8862133d3068fc7e807ed8b2671cc6d83657fff2fcb9e1caad"

  echo "==> Android arm64 的 libonnxruntime.so"
  local dest="$ANDROID_DIR/libonnxruntime.so"
  if [[ -f "$dest" && "$(sha256_of "$dest")" == "$want_so" ]]; then
    echo "    已是最新，跳过"
    return 0
  fi

  download "$url" "$aar"
  local got; got="$(sha256_of "$aar")"
  if [[ "$got" != "$want_aar" ]]; then
    echo "    ⚠️  AAR 的 sha256 变了：$got" >&2
    echo "        官方可能重新发布了同一个版本号，或者下载被中间人改了。" >&2
    echo "        确认无误后把本脚本里的 want_aar / want_so 一起更新。" >&2
    exit 1
  fi

  mkdir -p "$ANDROID_DIR"
  unzip -o -j "$aar" "jni/arm64-v8a/libonnxruntime.so" -d "$WORK/x" >/dev/null
  got="$(sha256_of "$WORK/x/libonnxruntime.so")"
  [[ "$got" == "$want_so" ]] || { echo "    ⚠️  解出来的 .so sha256 对不上：$got" >&2; exit 1; }
  cp "$WORK/x/libonnxruntime.so" "$dest"
  echo "    → $dest ($(du -h "$dest" | cut -f1))"
}

# ---------------------------------------------------------------- 宿主

fetch_host() {
  # ort 用 load-dynamic，构建期不链接 ORT，但跑 cargo test 时要在运行时加载它。
  echo "==> 宿主 (macOS arm64) 的 libonnxruntime.dylib"
  if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "    不是 macOS arm64，跳过"
    return 0
  fi

  local tarball="$WORK/ort-host.tgz"
  local url="https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-osx-arm64-$ORT_VERSION.tgz"
  local want="c255663d40755f84b1b86373bdb9870bb65f3a2c3d779b3d7ae31aaa00cebb4f"

  local dest="$HOST_DIR/libonnxruntime.dylib"
  # 光看文件在不在会踩坑：版本号改了但旧 dylib 还在，就会一直用旧版本测。
  # 记一个版本戳，对不上就重下。
  if [[ -f "$dest" && "$(cat "$HOST_DIR/VERSION" 2>/dev/null)" == "$ORT_VERSION" ]]; then
    echo "    已是最新，跳过"
    return 0
  fi

  download "$url" "$tarball"
  local got; got="$(sha256_of "$tarball")"
  if [[ "$got" != "$want" ]]; then
    echo "    ⚠️  压缩包的 sha256 变了：$got" >&2
    echo "        确认来源无误后更新本脚本里的 want。" >&2
    exit 1
  fi

  mkdir -p "$HOST_DIR"
  # 只解这一个成员，而且先从 tarball 里查出它的确切名字再解：不同版本的
  # 打包方式不一样（1.23.2 的成员名带 `./` 前缀，1.24.3 的不带），写死路径
  # 会在某个版本上静默解不出东西。--strip-components 也别指望，BSD tar 和
  # GNU tar 的匹配行为不同。dSYM 里有个同名成员，要排除掉。
  local member
  member="$(tar -tzf "$tarball" \
    | grep -v dSYM \
    | grep -E "/lib/libonnxruntime\.[0-9.]+\.dylib$" \
    | head -1)"
  [[ -n "$member" ]] || { echo "    ⚠️  在压缩包里找不到 libonnxruntime.*.dylib" >&2; exit 1; }

  tar -xzf "$tarball" -C "$WORK" "$member"
  cp "$WORK/$member" "$dest"
  echo "$ORT_VERSION" > "$HOST_DIR/VERSION"
  echo "    → $dest ($(du -h "$dest" | cut -f1))"
}

[[ "$SCOPE" == android || "$SCOPE" == all ]] && fetch_android
[[ "$SCOPE" == host || "$SCOPE" == all ]] && fetch_host
echo "完成。"
