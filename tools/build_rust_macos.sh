#!/usr/bin/env bash
#
# 把 Rust 侧的本地断句（Silero VAD）编译成 macOS dylib，并把
# ONNX Runtime 一起暂存到 macos/Frameworks/，供 Xcode 的嵌入 phase 使用。
#
# 和 Android 那边一样，不用 flutter_rust_bridge 自带的 cargokit，
# 只借它的代码生成；构建自己来。
#
# 用法：bash tools/build_rust_macos.sh [--debug]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LIB_STEM="rust_lib_pp_friend"
# 第一版只出 Apple Silicon。以后要 Universal2 再补 x86_64-apple-darwin + lipo。
TARGET="aarch64-apple-darwin"
FRAMEWORKS_DIR="macos/Frameworks"

PROFILE="release"
CARGO_FLAGS=(--release --target "$TARGET")
if [[ "${1:-}" == "--debug" ]]; then
  PROFILE="debug"
  CARGO_FLAGS=(--target "$TARGET")
fi

die() { echo "错误：$*" >&2; exit 1; }

# Xcode 的 Run Script 环境不一定带 ~/.cargo/bin（从 GUI 构建时尤其明显）。
if ! command -v cargo >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || die "找不到 cargo，先装 Rust 和 ~/.cargo/env"
command -v rustup >/dev/null 2>&1 || die "找不到 rustup"

# ---------------------------------------------------------------- 环境检查

[[ "$(uname -s)" == "Darwin" ]] || die "只能在 macOS 上构建 macOS 产物"
[[ "$(uname -m)" == "arm64" ]] || die "当前只支持 Apple Silicon (arm64)"

if ! rustup target list --installed | grep -qx "$TARGET"; then
  die "没装 Rust target $TARGET：
  rustup target add $TARGET"
fi

# ---------------------------------------------------------------- 构建

echo "==> cargo build ($PROFILE, $TARGET)"
cargo build "${CARGO_FLAGS[@]}" --manifest-path rust/Cargo.toml

DYLIB="rust/target/$TARGET/$PROFILE/librust_lib_pp_friend.dylib"
[[ -f "$DYLIB" ]] || die "没找到 $DYLIB"

# 开发期（flutter run 从仓库根启动）frb 的默认加载路径是
# rust/target/release/，顺手放一份，省得每次手动拷。
mkdir -p rust/target/release
cp -f "$DYLIB" "rust/target/release/librust_lib_pp_friend.dylib"

# 打成 app 时从这里嵌入 Contents/Frameworks。
mkdir -p "$FRAMEWORKS_DIR"
cp -f "$DYLIB" "$FRAMEWORKS_DIR/librust_lib_pp_friend.dylib"
# 让加载器能按裸名找到（frb 在 macOS 上会先试目录、再试裸名）。
install_name_tool -id "@rpath/librust_lib_pp_friend.dylib" \
  "$FRAMEWORKS_DIR/librust_lib_pp_friend.dylib" 2>/dev/null || true

# ---------------------------------------------------------------- ONNX Runtime

# ort 用 load-dynamic：构建期不链接，运行期从 ORT_DYLIB_PATH 或
# 可执行文件旁边加载。host 包已经在 fetch_onnxruntime.sh 里下好。
bash tools/fetch_onnxruntime.sh host
ORT_DYLIB="rust/.ort/libonnxruntime.dylib"
[[ -f "$ORT_DYLIB" ]] || die "没找到 $ORT_DYLIB"
cp -f "$ORT_DYLIB" "$FRAMEWORKS_DIR/libonnxruntime.dylib"

# ---------------------------------------------------------------- 结果

echo
echo "==> 产物"
ls -lh "$FRAMEWORKS_DIR/librust_lib_pp_friend.dylib" "$FRAMEWORKS_DIR/libonnxruntime.dylib"
lipo -info "$FRAMEWORKS_DIR/librust_lib_pp_friend.dylib"
lipo -info "$FRAMEWORKS_DIR/libonnxruntime.dylib"
echo
echo "提示：改了 Rust 之后要重跑本脚本；Xcode 的构建 phase 也会自动跑。"
