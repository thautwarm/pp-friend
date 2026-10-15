#!/usr/bin/env bash
#
# 把 Rust 侧的本地断句（Silero VAD）交叉编译到 Android arm64，产物放进 jniLibs。
#
# 为什么不用 flutter_rust_bridge 自带的构建集成（cargokit）：
# 本工程是 Gradle 9 + AGP 9，而 cargokit 的 plugin.gradle 用了
# `Project.exec()` 和 `project.buildDir` —— 这两个 API 在 Gradle 9 里都被删了。
# 它在这条工具链上必然构建失败。所以这里只借 frb 的**代码生成**
# （flutter_rust_bridge_codegen generate），构建自己来，Gradle 侧零插件改动。
#
# 代价：改完 Rust 要手动跑一次这个脚本。VAD 不是日常改动，可以接受。
# 注意 `flutter clean` **不会**删 jniLibs/（那是源目录不是构建目录），
# 所以脚本结尾会把 ABI 和文件时间戳打出来，免得拿旧的 .so 去测。
#
# 用法：bash tools/build_rust_android.sh [--debug]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# 和 android/app/build.gradle.kts 里的 ndkVersion 必须一致 —— 不一致的话
# 构建期和运行期的 C 库会悄悄错开，出错时很难查。
NDK_VERSION="28.2.13676358"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
NDK="$ANDROID_SDK/ndk/$NDK_VERSION"

TARGET="aarch64-linux-android"
# 手机和 Apple Silicon 上的模拟器都是 arm64 —— 只出这一个 ABI，不做 fat APK。
ABI="arm64-v8a"
# 29 和 minSdk 对齐：用低于 minSdk 的 API level 编译出来的原生代码
# 可能引到设备上没有的符号。
API_LEVEL=29

LIB_STEM="rust_lib_pp_friend"
JNI_DIR="android/app/src/main/jniLibs/$ABI"

PROFILE="release"
CARGO_FLAGS=(--release --target "$TARGET")
if [[ "${1:-}" == "--debug" ]]; then
  PROFILE="debug"
  CARGO_FLAGS=(--target "$TARGET")
fi

die() { echo "错误：$*" >&2; exit 1; }

# ---------------------------------------------------------------- 环境检查

[[ -d "$NDK" ]] || die "找不到 NDK $NDK_VERSION：$NDK
装了别的版本的话改这里的 NDK_VERSION（记得同步改 build.gradle.kts）。"

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
[[ -d "$TOOLCHAIN" ]] || die "NDK 里没有 darwin-x86_64 工具链：$TOOLCHAIN"

CLANG="$TOOLCHAIN/bin/${TARGET}${API_LEVEL}-clang"
CLANGXX="$TOOLCHAIN/bin/${TARGET}${API_LEVEL}-clang++"
STRIP="$TOOLCHAIN/bin/llvm-strip"
READELF="$TOOLCHAIN/bin/llvm-readelf"
NM="$TOOLCHAIN/bin/llvm-nm"
AR="$TOOLCHAIN/bin/llvm-ar"
SYSROOT_LIB="$TOOLCHAIN/sysroot/usr/lib/$TARGET"

for f in "$CLANG" "$CLANGXX" "$STRIP" "$READELF" "$NM" "$AR"; do
  [[ -x "$f" ]] || die "缺少 $f"
done

command -v cargo >/dev/null || die "找不到 cargo"
rustup target list --installed 2>/dev/null | grep -qx "$TARGET" \
  || die "没装 target $TARGET：rustup target add $TARGET"

# ---------------------------------------------------------------- ONNX Runtime

# ort 走 load-dynamic：构建期不链接 ORT，运行时 dlopen libonnxruntime.so。
# 那份 .so 来自官方 Maven AAR（见 tools/fetch_onnxruntime.sh 里的原因说明），
# 单独一个脚本管，因为它和 Rust 改动无关、不该每次重编都重下。
bash "$REPO_ROOT/tools/fetch_onnxruntime.sh" android

# ---------------------------------------------------------------- 编译

echo "==> 交叉编译 $LIB_STEM ($PROFILE / $TARGET)"
# 环境变量传而不是写 .cargo/config.toml，是为了不把本机的 SDK 路径固化进仓库。
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
# flutter_rust_bridge 默认开着 `dart-opaque`，会拖进 dart-sys —— 它用 cc-rs
# 现场编一个 C 壳，而 cc-rs 不会自己去找 NDK，只会去 PATH 上找
# `aarch64-linux-android-clang`。必须显式告诉它。
export CC_aarch64_linux_android="$CLANG"
export CXX_aarch64_linux_android="$CLANGXX"
export AR_aarch64_linux_android="$AR"

# 把编译期的绝对路径改写成中性前缀。
#
# 不这么做的话，rustc 会把本机的 `file!()` 路径原样写进二进制 —— 我们的
# 家目录、cargo 注册表目录、rustup 工具链目录全会留在 .so 里。这个 .so 是
# 要入库分发的（见 .gitignore 里的说明），等于把开发机的用户名一起发出去。
# 老玩家看一眼 `strings librust_lib_pp_friend.so` 就知道你叫啥。
#
# 连带好处：别人编出来的 .so 和我们这份逐字节一致，可以做可重现构建比对。
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/build/home --remap-path-prefix=$REPO_ROOT=/build/src"

cargo build "${CARGO_FLAGS[@]}" --manifest-path rust/Cargo.toml

SO_SRC="rust/target/$TARGET/$PROFILE/lib$LIB_STEM.so"
[[ -f "$SO_SRC" ]] || die "cargo 跑完了却没有 $SO_SRC"

# ---------------------------------------------------------------- 落地

mkdir -p "$JNI_DIR"
cp "$SO_SRC" "$JNI_DIR/lib$LIB_STEM.so"
# 顺带清掉历史遗留的其它 ABI 目录，避免旧产物混进 APK。
find android/app/src/main/jniLibs -mindepth 1 -maxdepth 1 -type d \
  ! -name "$ABI" -exec rm -rf {} +
# 早期版本静态链 ORT 时要把 NDK 的 libc++_shared.so 一起打包；现在 ORT 是
# 动态加载的、我们自己也不产生 C++ 符号，所以不需要它了。留着反而会多带 1.2MB。
rm -f "$JNI_DIR/libc++_shared.so"

"$STRIP" --strip-unneeded "$JNI_DIR/lib$LIB_STEM.so"

# ---------------------------------------------------------------- 静态检查

echo
echo "==> 动态依赖"
NEEDED="$("$READELF" -d "$JNI_DIR/lib$LIB_STEM.so" | grep NEEDED || true)"
echo "$NEEDED"

# 这一段是本脚本最有价值的部分，务必保留。
#
# Android 的链接器默认 `-z now`：dlopen 时必须把所有未定义符号解析完，
# **一个找不到整个库就加载失败**，Dart 侧看到的是 RustLib.init() 抛异常。
# 而 NEEDED 列表和段对齐都完全正常 —— 光看那两个数什么都发现不了。
# 曾经就是这么翻车的：ort 默认从 pyke 拿的 Android 静态库是 GNU 工具链构建的，
# 引用了 std::__cxx11 和 __isoc23_strtol 这些 Bionic 上不存在的符号。
#
# 规则：把符号名（去掉 @版本）和"可能在运行时提供它们的东西"对一遍 ——
#   * 我们 NEEDED 里列出的库
#   * NDK 的 bionic stub（libc/libm/libdl/liblog/libandroid/libz）
#   * jniLibs 里随 APK 一起发出去的其它 .so
# 剩下找不到的，就是会在真机上炸的。
SYMCHECK_TMP="$(mktemp -d)"
trap 'rm -rf "$SYMCHECK_TMP"' EXIT

dynsyms() { "$READELF" --dyn-syms "$1" 2>/dev/null | awk 'NF>=8 {print $7, $8}'; }
{
  # 未定义：Ndx 是 UND
  dynsyms "$JNI_DIR/lib$LIB_STEM.so" | awk '$1=="UND"{print $2}' | sed 's/@.*//'
} | sort -u > "$SYMCHECK_TMP/und.txt"

{
  for f in "$JNI_DIR"/*.so "$SYSROOT_LIB/$API_LEVEL"/libc.so \
           "$SYSROOT_LIB/$API_LEVEL"/libm.so "$SYSROOT_LIB/$API_LEVEL"/libdl.so \
           "$SYSROOT_LIB/$API_LEVEL"/liblog.so "$SYSROOT_LIB/$API_LEVEL"/libandroid.so \
           "$SYSROOT_LIB/$API_LEVEL"/libz.so; do
    [[ -f "$f" ]] || continue
    dynsyms "$f" | awk '$1!="UND"{print $2}' | sed 's/@.*//'
  done
} | sort -u > "$SYMCHECK_TMP/prov.txt"

comm -23 "$SYMCHECK_TMP/und.txt" "$SYMCHECK_TMP/prov.txt" > "$SYMCHECK_TMP/missing.txt"
echo
echo "==> 符号解析检查（未定义 $(wc -l < "$SYMCHECK_TMP/und.txt" | tr -d ' ') 个）"
if [[ -s "$SYMCHECK_TMP/missing.txt" ]]; then
  echo "⚠️  以下未定义符号在运行时找不到提供者，真机上 dlopen 会直接失败：" >&2
  sed 's/^/      /' "$SYMCHECK_TMP/missing.txt" >&2
  die "先修符号，别装机"
fi
echo "    全部可解析"

echo
echo "==> 段对齐（Android 15+ 起要求 16KB 页，LOAD 段必须是 0x4000）"
LOADS="$("$READELF" -l "$JNI_DIR/lib$LIB_STEM.so" | grep -E '^\s+LOAD' || true)"
echo "$LOADS"
if echo "$LOADS" | grep -qE '0x1000$'; then
  die "有 LOAD 段还是 4KB 对齐。在 rust/.cargo/config.toml 里给 $TARGET
加 rustflags = [\"-C\", \"link-arg=-Wl,-z,max-page-size=16384\"] 再重编。"
fi

echo
echo "==> 产物"
ls -la "$JNI_DIR"
echo
echo "ABI=$ABI  profile=$PROFILE  时间=$(date '+%Y-%m-%d %H:%M:%S')"
echo "改动 Rust 之后必须重跑本脚本，否则装上去的还是旧 .so。"
