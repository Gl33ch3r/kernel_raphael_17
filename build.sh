#!/usr/bin/env bash
# VoltageOS kernel_xiaomi_raphael branch 17, Boolx Clang 22.
set -Eeuo pipefail

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [[ ${1:-} == --help ]]; then
    cat <<'EOF'
Usage: ./build.sh [make targets/options ...]

Environment:
  TOOLCHAIN  Toolchain directory (default: ./toolchain/clang22)
  OUT_DIR    Output directory (default: ./out)
  DEFCONFIG  Configuration (default: raphael_defconfig)
  JOBS       Parallel jobs (default: 4)

Debian/Ubuntu dependencies:
  sudo apt-get install build-essential bc bison flex libssl-dev \
    libelf-dev zlib1g-dev python3 perl pkg-config cpio gzip lz4 \
    curl tar zstd

The missing toolchain is downloaded automatically.
Requires Linux x86_64.
EOF
    exit 0
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$ROOT"

[[ -f Makefile && -d arch/arm64 ]] ||
    die 'Place build.sh in the kernel repository root.'

TOOLCHAIN=${TOOLCHAIN:-"$ROOT/toolchain/clang22"}
[[ $TOOLCHAIN = /* ]] || TOOLCHAIN="$ROOT/$TOOLCHAIN"
TOOLCHAIN=${TOOLCHAIN%/}

download_toolchain() (
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
        die 'Boolx Clang requires a Linux x86_64 host.'

    for tool in curl tar zstd sha256sum mktemp; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "Missing download dependency: $tool"
    done

    local url=https://github.com/onettboots/boolx-clang-build/releases/download/Boolx-22/boolx-clang22.tar.zst
    local checksum=5a5778d43b6f1f1531e8939213746b2b0b10d1445c3e0db84f5c24f29ce0a131
    local destination=$TOOLCHAIN
    local staging

    [[ ! -e $destination ]] ||
        die "Incomplete toolchain at $destination; move it aside and retry."

    mkdir -p -- "$(dirname -- "$destination")"
    staging=$(mktemp -d "${destination}.download.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT

    printf 'Downloading Boolx Clang 22 to %s...\n' "$destination"

    if ! curl --fail --location --retry 3 --connect-timeout 30 \
        "$url" -o "$staging/toolchain.tar.zst"; then
        die 'Boolx Clang download failed.'
    fi

    printf '%s  %s\n' "$checksum" "$staging/toolchain.tar.zst" |
        sha256sum --check --status ||
        die 'Toolchain checksum verification failed.'

    mkdir -- "$staging/unpacked"

    # Remove the archive's top-level boolx-clang/ directory.
    if ! tar --zstd -xf "$staging/toolchain.tar.zst" \
        --strip-components=1 -C "$staging/unpacked"; then
        die 'Could not extract Boolx Clang.'
    fi

    [[ -x $staging/unpacked/bin/clang ]] ||
        die 'Archive does not contain bin/clang.'

    mv -- "$staging/unpacked" "$destination"
)

if [[ ! -x $TOOLCHAIN/bin/clang && ! -x $TOOLCHAIN/clang ]]; then
    download_toolchain
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

JOBS=${JOBS:-4}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] ||
    die 'JOBS must be a positive integer.'

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

# Preserve configuration edits on subsequent builds.
# Use a new OUT_DIR when changing DEFCONFIG or toolchains.
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
