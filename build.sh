#!/usr/bin/env bash
# VoltageOS kernel_xiaomi_raphael, branch 17.
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

Defaults:
  Toolchain: toolchain/clang22
  Config:    raphael_defconfig
  Output:    out/
  Jobs:      4
  Wi-Fi:     Built-in RTL8812BU/RTL8822BU, including T3U Plus 2357:0138

Environment:
  TOOLCHAIN       Override the LLVM 22 installation directory
  OUT_DIR         Override the build directory
  DEFCONFIG       Override the kernel configuration
  JOBS            Override parallel jobs
  DTC_EXT         External device-tree compiler
  STOCK_BOOT_IMG  Working boot image from the same Raphael ROM
  MAGISKBOOT      Optional existing magiskboot executable

A stock_boot.img beside this script enables boot-image packaging automatically
for default builds and --bootimg-only.

Dependencies:
  sudo apt-get install build-essential bc bison flex libssl-dev \
    libelf-dev zlib1g-dev python3 perl pkg-config cpio gzip lz4 \
    curl tar zstd device-tree-compiler

ROM-specific boot-image signing is separate.
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

# Automatically use a template beside the script.
if [[ -z ${STOCK_BOOT_IMG:-} && -s $ROOT/stock_boot.img ]] &&
   [[ $# == 0 || ${1:-} == --bootimg-only ]]; then
    STOCK_BOOT_IMG="$ROOT/stock_boot.img"
fi

BOOTIMG_ONLY=0
if [[ ${1:-} == --bootimg-only ]]; then
    BOOTIMG_ONLY=1
    shift
    (( $# == 0 )) ||
        die '--bootimg-only does not accept make targets.'
    [[ -n ${STOCK_BOOT_IMG:-} ]] ||
        die 'Supply stock_boot.img or set STOCK_BOOT_IMG.'
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

    [[ -s $STOCK ]] || die "Missing working boot image: $STOCK"
    [[ -s $KERNEL ]] || die "Missing compiled kernel: $KERNEL"

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

        # Extract only magiskboot; this does not install Magisk.
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

# The bundled DTC 1.4.4 cannot parse Raphael's overlay syntax.
DTC_EXT=${DTC_EXT:-$(command -v dtc || true)}
[[ -n $DTC_EXT ]] ||
    die 'Install device-tree-compiler or set DTC_EXT=/path/to/modern/dtc.'

DTC_EXT=$(command -v -- "$DTC_EXT") ||
    die 'DTC_EXT executable not found.'
DTC_EXT=$(realpath -- "$DTC_EXT")

printf '/dts-v1/; /plugin/; &external { status = "okay"; };\n' |
    "$DTC_EXT" -@ -I dts -O dtb -o /dev/null 2>/dev/null ||
    die 'Install a newer device-tree-compiler with overlay support.'

download_toolchain() (
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
        die 'Boolx Clang requires Linux x86_64.'

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

setup_rtl88x2bu() (
    local driver="$ROOT/drivers/net/wireless/realtek/rtl88x2bu"
    local revision=465ae7cb522a382adc85ea5c31f228af8d172148
    local checksum=2fb1915e3711912101cd1b8924fdec944900fcebaec45d62624e11b63b92a76d
    local staging

    if [[ ! -f $driver/Makefile ]]; then
        [[ ! -e $driver ]] ||
            die "Incomplete driver directory: $driver"

        for tool in curl tar sha256sum; do
            command -v "$tool" >/dev/null 2>&1 ||
                die "Driver setup requires $tool."
        done

        staging=$(mktemp -d "$ROOT/.rtl88x2bu.XXXXXX")
        trap 'rm -rf -- "$staging"' EXIT

        printf 'Downloading the RTL8812BU/RTL8822BU driver...\n'

        curl --fail --location --retry 3 --connect-timeout 30 \
            "https://codeload.github.com/RinCat/RTL88x2BU-Linux-Driver/tar.gz/$revision" \
            -o "$staging/driver.tar.gz"

        printf '%s  %s\n' "$checksum" "$staging/driver.tar.gz" |
            sha256sum --check --status ||
            die 'Driver archive checksum mismatch.'

        mkdir -- "$staging/source"
        tar -xzf "$staging/driver.tar.gz" \
            --strip-components=1 -C "$staging/source"

        mkdir -p -- "$(dirname -- "$driver")"
        mv -- "$staging/source" "$driver"
    fi

    python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
driver = root / "drivers/net/wireless/realtek/rtl88x2bu"

def replace_once(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        sys.exit(
            f"Error: unexpected source contents in {path}; "
            "check the pinned driver version."
        )
    path.write_text(text.replace(old, new, 1))

# Adapt the vendor Makefile for the parent kernel's ARM64 build.
replace_once(
    driver / "Makefile",
    "CONFIG_PLATFORM_I386_PC = y",
    "CONFIG_PLATFORM_I386_PC = n",
)

replace_once(
    driver / "Makefile",
    "ccflags-y += $(USER_EXTRA_CFLAGS)\n",
    "ccflags-y += $(USER_EXTRA_CFLAGS)\n"
    "# Built-in ARM64 kernel integration; use the parent kernel's architecture/tools.\n"
    "ccflags-y += -DCONFIG_LITTLE_ENDIAN\n"
    "ccflags-y += -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT\n",
)

(driver / "Kconfig").write_text(
    'config RTL8822BU\n'
    '\ttristate "Realtek RTL8812BU/RTL8822BU USB WiFi"\n'
    '\tdepends on USB && CFG80211\n'
    '\tselect CFG80211_WEXT\n'
    '\tselect WEXT_PRIV\n'
    '\thelp\n'
    '\t  Support Realtek RTL8812BU and RTL8822BU USB wireless adapters,\n'
    '\t  including TP-Link Archer T3U Plus (USB ID 2357:0138).\n'
)

parent = driver.parent
path = parent / "Kconfig"
text = path.read_text()
include = 'source "drivers/net/wireless/realtek/rtl88x2bu/Kconfig"'

if include not in text:
    marker = "endif # WLAN_VENDOR_REALTEK"
    if marker not in text:
        sys.exit("Error: unexpected Realtek Kconfig layout.")
    path.write_text(text.replace(marker, include + "\n\n" + marker))

path = parent / "Makefile"
text = path.read_text()
if "obj-$(CONFIG_RTL8822BU)" not in text:
    path.write_text(
        text.rstrip() + "\nobj-$(CONFIG_RTL8822BU) += rtl88x2bu/\n"
    )

path = root / "arch/arm64/configs/raphael_defconfig"
text = path.read_text()
for option in ("CFG80211_WEXT", "WLAN_VENDOR_REALTEK", "RTL8822BU"):
    pattern = rf"^(?:CONFIG_{option}=.*|# CONFIG_{option} is not set)$"
    line = f"CONFIG_{option}=y"
    if re.search(pattern, text, re.M):
        text = re.sub(pattern, line, text, flags=re.M)
    else:
        text = text.rstrip() + "\n" + line + "\n"
path.write_text(text)

# Avoid early-exit pipes causing LLVM 22 broken-pipe messages.
path = root / "scripts/Makefile.build"
text = path.read_text()
path.write_text(
    text.replace(
        "| grep -q __ksymtab;",
        "| grep __ksymtab >/dev/null;",
    )
)

(driver / "RAPHAEL_UPSTREAM").write_text(
    "https://github.com/RinCat/RTL88x2BU-Linux-Driver\n"
    "465ae7cb522a382adc85ea5c31f228af8d172148\n"
)
PY
)

setup_rtl88x2bu

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

if [[ ! -f $OUT_DIR/.config ]]; then
    make "${args[@]}" "$DEFCONFIG"
fi

# Also enable the USB driver in configurations from previous builds.
"$ROOT/scripts/config" --file "$OUT_DIR/.config" \
    -e WLAN \
    -e WLAN_VENDOR_REALTEK \
    -e CFG80211 \
    -e CFG80211_WEXT \
    -e RTL8822BU

make "${args[@]}" olddefconfig

grep -qx 'CONFIG_RTL8822BU=y' "$OUT_DIR/.config" ||
    die 'RTL8822BU could not be enabled; check USB and cfg80211.'

if (( $# )); then
    make -j"$JOBS" "${args[@]}" "$@"
else
    make -j"$JOBS" "${args[@]}" all Image.gz
fi

printf '\nKernel build completed: %s\n' "$OUT_DIR"

if [[ -n ${STOCK_BOOT_IMG:-} ]]; then
    printf '\nPackaging boot.img using: %s\n' "$STOCK_BOOT_IMG"
    make_boot_image
else
    printf '\nboot.img was not created because no template was supplied.\n'
    printf 'Place stock_boot.img beside build.sh, then run:\n'
    printf '  ./build.sh --bootimg-only\n'
fi
