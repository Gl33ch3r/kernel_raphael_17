#!/usr/bin/env bash
# VoltageOS kernel_xiaomi_raphael branch 17.
set -Eeuo pipefail

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [[ ${1:-} == --help ]]; then
    cat <<'EOF'
Usage:
  ./build.sh
  ./build.sh dtbs
  ./build.sh menuconfig
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh --bootimg-only

Environment:
  TOOLCHAIN       Default: ./toolchain/clang22
  OUT_DIR         Default: ./out
  DEFCONFIG       Default: raphael_defconfig
  JOBS            Default: 4
  DTC_EXT         External dtc executable; defaults to dtc from PATH
  STOCK_BOOT_IMG  Working boot.img from the same Raphael ROM
  MAGISKBOOT      Optional existing magiskboot executable

Debian/Ubuntu dependencies:
  sudo apt-get install build-essential bc bison flex libssl-dev \
    libelf-dev zlib1g-dev python3 perl pkg-config cpio gzip lz4 \
    curl tar zstd device-tree-compiler

Boolx Clang 22 is downloaded automatically when missing.
Boot packaging preserves the template ramdisk and device trees.
ROM-specific signing is separate.
EOF
    exit 0
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$ROOT"

[[ -f Makefile && -d arch/arm64 ]] ||
    die 'Place build.sh in the kernel repository root.'

command -v python3 >/dev/null 2>&1 ||
    die 'python3 is required.'

TOOLCHAIN=${TOOLCHAIN:-"$ROOT/toolchain/clang22"}
[[ $TOOLCHAIN = /* ]] || TOOLCHAIN="$ROOT/$TOOLCHAIN"
TOOLCHAIN=${TOOLCHAIN%/}

OUT_DIR=${OUT_DIR:-"$ROOT/out"}
[[ $OUT_DIR = /* ]] || OUT_DIR="$ROOT/$OUT_DIR"
mkdir -p -- "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)

[[ $OUT_DIR != "$ROOT" ]] ||
    die 'OUT_DIR must differ from the source directory.'

BOOTIMG_ONLY=0
if [[ ${1:-} == --bootimg-only ]]; then
    BOOTIMG_ONLY=1
    shift
    (( $# == 0 )) ||
        die '--bootimg-only does not accept make targets.'
    [[ -n ${STOCK_BOOT_IMG:-} ]] ||
        die 'Set STOCK_BOOT_IMG to a working boot.img from the same ROM.'
fi

if [[ -n ${STOCK_BOOT_IMG:-} ]]; then
    [[ -s $STOCK_BOOT_IMG ]] ||
        die "Working boot image not found: $STOCK_BOOT_IMG"

    (( $# == 0 )) ||
        die 'Use STOCK_BOOT_IMG with the default build, without make targets.'

    STOCK_BOOT_IMG=$(realpath -- "$STOCK_BOOT_IMG")

    python3 - "$STOCK_BOOT_IMG" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    if f.read(8) != b"ANDROID!":
        sys.exit("Error: STOCK_BOOT_IMG must be an Android boot.img.")
PY
fi

make_boot_image() (
    local STOCK=$STOCK_BOOT_IMG
    local KERNEL="$OUT_DIR/arch/arm64/boot/Image"
    local OUTPUT="$OUT_DIR/boot.img"
    local WORK

    [[ -s $KERNEL ]] ||
        die "Missing compiled kernel: $KERNEL"

    STOCK=$(realpath -- "$STOCK")
    KERNEL=$(realpath -- "$KERNEL")
    OUTPUT=$(realpath -m -- "$OUTPUT")

    [[ $OUTPUT != "$STOCK" && $OUTPUT != "$KERNEL" ]] ||
        die 'Output must differ from both inputs.'

    [[ ! -d $OUTPUT ]] ||
        die 'Output must be a filename.'

    python3 - "$KERNEL" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    header = f.read(64)
    if header[56:60] != b"ARM\x64":
        sys.exit("Error: use the raw ARM64 Image, not Image.gz.")
PY

    WORK=$(mktemp -d "$OUT_DIR/.bootimg.XXXXXX")
    trap 'rm -rf -- "$WORK"' EXIT

    if [[ -n ${MAGISKBOOT:-} ]]; then
        MAGISKBOOT=$(command -v -- "$MAGISKBOOT") ||
            die 'MAGISKBOOT executable not found.'
    elif [[ -x $ROOT/toolchain/magiskboot ]]; then
        MAGISKBOOT="$ROOT/toolchain/magiskboot"
    elif command -v magiskboot >/dev/null 2>&1; then
        MAGISKBOOT=$(command -v magiskboot)
    else
        [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
            die 'Automatic tool download requires Linux x86_64.'

        for tool in curl sha256sum; do
            command -v "$tool" >/dev/null 2>&1 ||
                die "Missing dependency: $tool"
        done

        printf 'Downloading the official Magisk boot-image tool...\n'

        curl --fail --location --retry 3 --connect-timeout 30 \
            https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk \
            -o "$WORK/Magisk.apk"

        printf '%s  %s\n' \
            89cefac0a318afa39fb3880c45c87b036c05bc1ebf02a7a715b7f8d7c26ac6e7 \
            "$WORK/Magisk.apk" |
            sha256sum --check --status ||
            die 'Magisk APK checksum mismatch.'

        # Extract only the boot-image tool; do not install Magisk.
        python3 - "$WORK/Magisk.apk" "$WORK/magiskboot" <<'PY'
import pathlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as apk:
    binary = pathlib.Path(sys.argv[2])
    binary.write_bytes(apk.read("lib/x86_64/libmagiskboot.so"))
    binary.chmod(0o755)
PY

        mkdir -p -- "$ROOT/toolchain"
        mv -- "$WORK/magiskboot" "$ROOT/toolchain/magiskboot"
        MAGISKBOOT="$ROOT/toolchain/magiskboot"
    fi

    MAGISKBOOT=$(realpath -- "$MAGISKBOOT")
    [[ -x $MAGISKBOOT ]] ||
        die 'magiskboot must be executable.'

    mkdir -- "$WORK/unpacked"

    (
        cd -- "$WORK/unpacked"

        "$MAGISKBOOT" unpack -h "$STOCK"
        [[ -s kernel ]] || die 'Template has no kernel.'

        cp -- "$KERNEL" kernel

        # Preserve ramdisk, device trees, header and original compression.
        "$MAGISKBOOT" repack "$STOCK" "$WORK/boot.img"
    )

    [[ -s $WORK/boot.img ]] ||
        die 'Repacking did not produce boot.img.'

    mv -f -- "$WORK/boot.img" "$OUTPUT"
    printf '\nBoot image created: %s\n' "$OUTPUT"
)

if (( BOOTIMG_ONLY )); then
    make_boot_image
    exit 0
fi

# Use an external DTC: the bundled 1.4.4 rejects Raphael overlay syntax.
DTC_EXT=${DTC_EXT:-$(command -v dtc || true)}
[[ -n $DTC_EXT ]] ||
    die 'Install device-tree-compiler or set DTC_EXT=/path/to/modern/dtc.'

DTC_EXT=$(command -v -- "$DTC_EXT") ||
    die 'DTC_EXT executable not found.'
DTC_EXT=$(realpath -- "$DTC_EXT")

# Check the required overlay syntax before starting a long build.
printf '/dts-v1/; /plugin/; &external { status = "okay"; };\n' |
    "$DTC_EXT" -@ -I dts -O dtb -o /dev/null 2>/dev/null ||
    die 'Install a newer device-tree-compiler with external-node overlay support.'

download_toolchain() (
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
        die 'Boolx Clang requires a Linux x86_64 host.'

    for tool in curl tar zstd sha256sum mktemp; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "Missing download dependency: $tool"
    done

    local url=https://github.com/onettboots/boolx-clang-build/releases/download/Boolx-22/boolx-clang22.tar.zst
    local checksum=5a5778d43b6f1f1531e8939213746b2b0b10d1445c3e0db84f5c24f29ce0a131
    local staging

    [[ ! -e $TOOLCHAIN ]] ||
        die "Incomplete toolchain at $TOOLCHAIN; move it aside and retry."

    mkdir -p -- "$(dirname -- "$TOOLCHAIN")"
    staging=$(mktemp -d "${TOOLCHAIN}.download.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT

    printf 'Downloading Boolx Clang 22...\n'

    curl --fail --location --retry 3 --connect-timeout 30 \
        "$url" -o "$staging/toolchain.tar.zst"

    printf '%s  %s\n' "$checksum" "$staging/toolchain.tar.zst" |
        sha256sum --check --status ||
        die 'Toolchain checksum verification failed.'

    mkdir -- "$staging/unpacked"

    # Strip the archive's top-level boolx-clang/ directory.
    tar --zstd -xf "$staging/toolchain.tar.zst" \
        --strip-components=1 -C "$staging/unpacked"

    [[ -x $staging/unpacked/bin/clang ]] ||
        die 'Archive does not contain bin/clang.'

    mv -- "$staging/unpacked" "$TOOLCHAIN"
)

if [[ ! -x $TOOLCHAIN/bin/clang && ! -x $TOOLCHAIN/clang ]]; then
    download_toolchain
fi

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
        die "Missing dependency: $tool (see ./build.sh --help)."
done

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
    DTC_EXT="$DTC_EXT"
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
printf 'Compiler: %s\nDTC: %s\nConfig: %s\nOutput: %s\nJobs: %s\n' \
    "${compiler_version%%$'\n'*}" "$DTC_EXT" \
    "$DEFCONFIG" "$OUT_DIR" "$JOBS"

# Preserve configuration edits on subsequent builds.
if [[ ! -f $OUT_DIR/.config ]]; then
    make "${args[@]}" "$DEFCONFIG"
fi

make "${args[@]}" olddefconfig

if (( $# )); then
    make -j"$JOBS" "${args[@]}" "$@"
else
    make -j"$JOBS" "${args[@]}" all Image.gz
fi

printf '\nKernel build completed: %s\n' "$OUT_DIR"

if [[ -n ${STOCK_BOOT_IMG:-} ]]; then
    make_boot_image
fi
