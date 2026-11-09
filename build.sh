#!/usr/bin/env bash
# VoltageOS kernel_xiaomi_raphael, branch 17.
# Downloads Google Clang 22.0.2 and builds with 4 parallel jobs.
set -Eeuo pipefail

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [[ ${1:-} == --help ]]; then
    cat <<'EOF'
Usage: ./build.sh [make targets/options ...]

Environment:
  TOOLCHAIN  Toolchain directory (default: ./clang-22)
  OUT_DIR    Output directory (default: ./out)
  DEFCONFIG  Configuration (default: raphael_defconfig)
  JOBS       Parallel jobs (default: 4)

Examples:
  ./build.sh
  JOBS=8 ./build.sh
  TOOLCHAIN=/opt/clang-22 ./build.sh
  ./build.sh menuconfig

Debian/Ubuntu host dependencies:
  sudo apt-get install build-essential bc bison flex libssl-dev \
    libelf-dev zlib1g-dev python3 perl pkg-config cpio gzip lz4 curl tar

A missing toolchain is downloaded from Google's official Android prebuilts.
Requires Linux x86_64. Outputs are placed in out/.
EOF
    exit 0
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$ROOT"

[[ -f Makefile && -d arch/arm64 ]] ||
    die 'Place build.sh in the kernel repository root.'

TOOLCHAIN=${TOOLCHAIN:-"$ROOT/clang-22"}
[[ $TOOLCHAIN = /* ]] || TOOLCHAIN="$ROOT/$TOOLCHAIN"
TOOLCHAIN=${TOOLCHAIN%/}

download_google_clang() {
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
        die 'Google Clang requires a Linux x86_64 host.'

    for tool in curl tar mktemp; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "Missing download dependency: $tool"
    done

    # Google clang-r596125 is Clang 22.0.2.
    # Pin the source commit for a consistent toolchain.
    local revision=clang-r596125
    local commit=4a7d0a5e443c27d8f68fbd46abfab464e1355a69
    local base=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86
    local url="$base/+archive/$commit/$revision.tar.gz"
    local staging

    [[ ! -e $TOOLCHAIN ]] ||
        die "Incomplete toolchain at $TOOLCHAIN; move it aside and retry."

    mkdir -p -- "$(dirname -- "$TOOLCHAIN")"
    staging=$(mktemp -d "${TOOLCHAIN}.download.XXXXXX")

    printf 'Downloading Google %s (Clang 22.0.2)...\n' "$revision"

    if ! curl --fail --location --retry 3 --connect-timeout 30 \
        "$url" -o "$staging/toolchain.tar.gz"; then
        rm -rf -- "$staging"
        die 'Toolchain download failed.'
    fi

    mkdir -- "$staging/unpacked"

    if ! tar -xzf "$staging/toolchain.tar.gz" \
        -C "$staging/unpacked"; then
        rm -rf -- "$staging"
        die 'Toolchain extraction failed.'
    fi

    if [[ ! -x $staging/unpacked/bin/clang ]]; then
        rm -rf -- "$staging"
        die 'Downloaded archive is missing bin/clang.'
    fi

    mv -- "$staging/unpacked" "$TOOLCHAIN"
    rm -rf -- "$staging"
}

if [[ ! -x $TOOLCHAIN/bin/clang && ! -x $TOOLCHAIN/clang ]]; then
    download_google_clang
fi

# Accept either an installation directory or its bin directory.
if [[ -d $TOOLCHAIN/bin ]]; then
    TOOLCHAIN="$TOOLCHAIN/bin"
fi

TOOLCHAIN=$(cd -- "$TOOLCHAIN" && pwd -P)
export PATH="$TOOLCHAIN:$PATH"

for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy \
            llvm-objdump llvm-readelf llvm-strip llvm-dis; do
    [[ -x $TOOLCHAIN/$tool ]] ||
        die "Missing toolchain executable: $TOOLCHAIN/$tool"

    version=$("$TOOLCHAIN/$tool" --version)
    [[ $version =~ version[[:space:]]+22\. ||
       $version =~ LLD[[:space:]]+22\. ]] ||
        die "$tool must be version 22: ${version%%$'\n'*}"
done

for tool in make gcc g++ bc bison flex python3 perl pkg-config gzip; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "Missing host dependency: $tool (see ./build.sh --help)."
done

OUT_DIR=${OUT_DIR:-"$ROOT/out"}
[[ $OUT_DIR = /* ]] || OUT_DIR="$ROOT/$OUT_DIR"

mkdir -p -- "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)

[[ $OUT_DIR != "$ROOT" ]] ||
    die 'OUT_DIR must differ from the source directory.'

DEFCONFIG=${DEFCONFIG:-raphael_defconfig}
[[ -f arch/arm64/configs/$DEFCONFIG ]] ||
    die "Unknown configuration: $DEFCONFIG"

# Default to four parallel build jobs.
JOBS=${JOBS:-4}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] ||
    die 'JOBS must be a positive integer.'

# This 4.14 tree supports LLVM=1.
# PATH selects LLVM utilities invoked internally for LTO.
args=(
    O="$OUT_DIR"
    ARCH=arm64
    SUBARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    CC="$TOOLCHAIN/clang"
    LD="$TOOLCHAIN/ld.lld"
    HOSTCC=gcc
    HOSTCXX=g++
    PYTHON=python3
)

export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-$(id -un)}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-$(hostname)}

compiler_version=$("$TOOLCHAIN/clang" --version)
printf 'Compiler: %s\nConfig: %s\nOutput: %s\nJobs: %s\n' \
    "${compiler_version%%$'\n'*}" "$DEFCONFIG" "$OUT_DIR" "$JOBS"

# Preserve configuration changes on subsequent builds.
# Use a new OUT_DIR when changing DEFCONFIG.
if [[ ! -f $OUT_DIR/.config ]]; then
    make "${args[@]}" "$DEFCONFIG"
fi

make "${args[@]}" olddefconfig

if (( $# )); then
    make -j"$JOBS" "${args[@]}" "$@"
else
    make -j"$JOBS" "${args[@]}" all Image.gz
fi

printf '\nMake completed successfully.\n'
printf 'Build output: %s\n' "$OUT_DIR"
printf 'Kernel images: %s/arch/arm64/boot/\n' "$OUT_DIR"
printf 'Device trees: %s/arch/arm64/boot/dts/\n' "$OUT_DIR"
