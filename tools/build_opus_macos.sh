#!/usr/bin/env bash
#
# 为 macOS 静态编译 libopus + libogg，装到 macos/Vendor/。
#
# 只出 arm64、部署目标 14.0（和 app / ORT 对齐）。编解码层不依赖 Apple 的
# 音频框架，以后 Windows/Linux 可以复用同一套 C 库，只是换个 target。
#
# 用法：bash tools/build_opus_macos.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OPUS_VERSION="1.6.1"
OGG_VERSION="1.3.6"
OPUS_SHA="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
OGG_SHA="83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638"

VENDOR="$REPO_ROOT/macos/Vendor"
CACHE="$REPO_ROOT/macos/.build/opus"

die() { echo "错误：$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "只能在 macOS 上构建 macOS 产物"
[[ "$(uname -m)" == "arm64" ]] || die "当前只支持 Apple Silicon (arm64)"
command -v cmake >/dev/null 2>&1 || die "找不到 cmake"

mkdir -p "$CACHE" "$VENDOR"

fetch() {
  local url="$1" dest="$2" want="$3"
  if [[ -f "$dest" ]]; then
    local got
    got="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [[ "$got" == "$want" ]]; then
      echo "    已是最新，跳过"
      return 0
    fi
    echo "    sha256 不匹配，重新下载" >&2
    rm -f "$dest"
  fi
  echo "    下载 $url"
  curl -fL --retry 3 --connect-timeout 20 -o "$dest.tmp" "$url"
  local got
  got="$(shasum -a 256 "$dest.tmp" | awk '{print $1}')"
  [[ "$got" == "$want" ]] || die "sha256 不匹配：$url（拿到 $got）"
  mv "$dest.tmp" "$dest"
}

build() {
  local name="$1" src="$2" build_dir="$3"
  shift 3
  rm -rf "$build_dir"
  cmake -S "$src" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_INSTALL_PREFIX="$VENDOR" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF \
    "$@"
  cmake --build "$build_dir" --target install -j "$(sysctl -n hw.ncpu)"
}

echo "==> libogg $OGG_VERSION"
OGG_TGZ="$CACHE/libogg-$OGG_VERSION.tar.gz"
fetch "https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.gz" "$OGG_TGZ" "$OGG_SHA"
rm -rf "$CACHE/libogg-$OGG_VERSION"
tar -xzf "$OGG_TGZ" -C "$CACHE"
build "libogg" "$CACHE/libogg-$OGG_VERSION" "$CACHE/build-ogg" \
  -DBUILD_TESTING=OFF

echo "==> opus $OPUS_VERSION"
OPUS_TGZ="$CACHE/opus-$OPUS_VERSION.tar.gz"
fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" "$OPUS_TGZ" "$OPUS_SHA"
rm -rf "$CACHE/opus-$OPUS_VERSION"
tar -xzf "$OPUS_TGZ" -C "$CACHE"
build "opus" "$CACHE/opus-$OPUS_VERSION" "$CACHE/build-opus" \
  -DOPUS_BUILD_PROGRAMS=OFF \
  -DOPUS_BUILD_TESTING=OFF \
  -DOPUS_BUILD_SHARED_LIBRARY=OFF

echo
echo "==> 产物"
ls -lh "$VENDOR/lib/libopus.a" "$VENDOR/lib/libogg.a"
lipo -info "$VENDOR/lib/libopus.a"
lipo -info "$VENDOR/lib/libogg.a"
