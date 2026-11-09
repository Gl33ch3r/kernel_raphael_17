#!/usr/bin/env bash
# All-in-one Raphael branch 17 build: Boolx Clang 22, NetHunter, 88x2bu,
# KernelSU-Next legacy manual hooks, external DTC and boot.img repacking.
# "KSU_GIT_VERSION not defined! It is better to make KernelSU-Next a git repository!"
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

show_help() {
    cat <<'EOF'
Usage: ./build.sh [--ksu] [--nethunter] [make targets/options ...]

Defaults: raphael_defconfig, out/, all + Image.gz, Clang 22, built-in 88x2bu.
KernelSU-Next and NetHunter are disabled unless their flags are supplied.
Options:
  --ksu          Download/integrate KernelSU-Next legacy with manual hooks
  --nethunter    Enable the NetHunter kernel configuration profile
  --bootimg-only Package an existing compiled kernel using STOCK_BOOT_IMG
  --wifi-diagnose Collect adapter diagnostics through adb
  --help, -h     Show this help
Feature flags can be combined and may appear before or after make targets.
They cannot be used with --bootimg-only or --wifi-diagnose.
Environment:
  TOOLCHAIN  LLVM 22 installation directory (default: ./toolchain/clang22)
  OUT_DIR    Build directory (default: out, relative to the source tree)
  DEFCONFIG  Configuration in arch/arm64/configs (default: raphael_defconfig)
  JOBS       Parallel jobs (default: 4)
  LLVM_IAS   Use LLVM assembler: 1 (default); 0 requires GNU cross-binutils
  DTC_EXT    External dtc executable (default: dtc from PATH)
  STOCK_BOOT_IMG  Working boot.img from the same ROM; enables boot.img packaging

Examples:
  ./build.sh
  ./build.sh --ksu
  ./build.sh --nethunter
  ./build.sh --ksu --nethunter
  TOOLCHAIN=/opt/clang-22 JOBS=8 ./build.sh
  ./build.sh menuconfig
  ./build.sh --wifi-diagnose
  ./build.sh Image.gz dtbs
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh --bootimg-only

Missing toolchains are downloaded from the Boolx-22 GitHub release.
The pinned 88x2bu driver is downloaded and enabled for Archer T3U Plus (2357:0138).
With --ksu, official KernelSU-Next legacy is pinned for this 4.14 kernel.
All source/configuration fixes and boot.img packaging are embedded in this file;
copy only build.sh into the root of a complete branch 17 checkout to use it.
With --nethunter, enable chroot IPC, USB gadgets/serial, USB Bluetooth, mac80211,
and packet filtering. The Kali rootfs and Android apps are installed separately.
Enabled NetHunter settings are recorded in out/nethunter-config.txt.
Repeat the desired flags on every build; changing flags restores pre-feature
settings and preserves unrelated configuration edits. Old configurations are
backed up when migrating from the previous always-enabled script.
Requires a Linux x86_64 host.
Debian/Ubuntu host dependencies:
  build-essential bc bison flex libssl-dev libelf-dev zlib1g-dev
  python3 perl pkg-config cpio gzip lz4 curl tar zstd device-tree-compiler

Outputs: out/arch/arm64/boot/Image, Image.gz, device trees under boot/dts/,
         out/vmlinux, out/System.map, and modules when enabled.
Set STOCK_BOOT_IMG, or place stock_boot.img beside this script, to create out/boot.img.
Use a template from the same Raphael ROM. Its ramdisk and device trees are
preserved. magiskboot is downloaded automatically; MAGISKBOOT can override it.
ROM-specific image signing is separate.
EOF
}

WITH_KSU=0
WITH_NETHUNTER=0
MODE=build
make_options=()
while (( $# )); do
    case "$1" in
        --ksu) WITH_KSU=1 ;;
        --nethunter) WITH_NETHUNTER=1 ;;
        --help|-h) show_help; exit 0 ;;
        --bootimg-only|--wifi-diagnose)
            [[ $MODE == build || $MODE == "${1#--}" ]] || die 'Choose only one build mode.'
            MODE=${1#--}
            ;;
        --) shift; make_options+=("$@"); break ;;
        *) make_options+=("$1") ;;
    esac
    shift
done
set -- "${make_options[@]}"
if [[ $MODE != build ]]; then
    (( WITH_KSU == 0 && WITH_NETHUNTER == 0 )) ||
        die '--ksu and --nethunter require a build; they cannot change an already compiled kernel or run diagnostics.'
    (( $# == 0 )) || die "--$MODE does not accept make targets/options."
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$ROOT"
wifi_diagnose() {
    command -v adb >/dev/null 2>&1 || die 'Install adb on the host and enable USB debugging on the phone.'
    local log="$ROOT/out/t3u-plus-diagnostics.txt"
    mkdir -p -- "$(dirname -- "$log")"
    adb get-state >/dev/null || die 'No phone connected through adb.'
    {
        adb shell '
            echo "=== Running kernel ==="
            uname -a
            echo "=== Built-in driver and USB registration ==="
            ls -ld /sys/module/88x2bu /sys/bus/usb/drivers/rtl88x2bu 2>&1
            echo "=== USB devices and interface bindings ==="
            for d in /sys/bus/usb/devices/*; do
                if [ -r "$d/idVendor" ]; then
                    printf "%s %s:%s\n" "$d" "$(cat "$d/idVendor")" "$(cat "$d/idProduct")"
                fi
                if [ -L "$d/driver" ]; then
                    printf "%s driver=" "$d"
                    readlink "$d/driver"
                fi
            done
            echo "=== Network interfaces ==="
            ip link
            echo "=== Kernel configuration when available ==="
            if [ -r /proc/config.gz ]; then
                gzip -dc /proc/config.gz | grep -E "CONFIG_(RTL8822BU|KSU|KPROBES|USB_DWC3|CFG80211)="
            fi
        '
        printf '\n=== USB/Wi-Fi probe messages (root may be required) ===\n'
        adb shell 'su -c dmesg' 2>&1 |
            grep -iE 'rtw|rtl|88x2|8822|8812|usb|cfg80211|wiphy|firmware|denied|not found' |
            tail -n 120 || true
    } | tee "$log"
    printf '\nDiagnostic report saved to: %s\n' "$log"
}

if [[ $MODE == wifi-diagnose ]]; then
    wifi_diagnose
    exit 0
fi

TOOLCHAIN=${TOOLCHAIN:-"$ROOT/toolchain/clang22"}
[[ $TOOLCHAIN = /* ]] || TOOLCHAIN="$ROOT/$TOOLCHAIN"
TOOLCHAIN=${TOOLCHAIN%/}
[[ -f Makefile && -d arch/arm64 ]] || die 'Run from a complete kernel checkout.'

command -v python3 >/dev/null 2>&1 || die 'python3 is required.'
OUT_DIR=${OUT_DIR:-"$ROOT/out"}
[[ $OUT_DIR = /* ]] || OUT_DIR="$ROOT/$OUT_DIR"
mkdir -p -- "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)
[[ $OUT_DIR != "$ROOT" ]] || die 'OUT_DIR must differ from the source directory.'

# A template beside the script enables packaging on a default build.
if [[ -z ${STOCK_BOOT_IMG:-} && -s $ROOT/stock_boot.img ]] &&
   (( $# == 0 )); then
    STOCK_BOOT_IMG="$ROOT/stock_boot.img"
fi

BOOTIMG_ONLY=0
if [[ $MODE == bootimg-only ]]; then
    BOOTIMG_ONLY=1
    (( $# == 0 )) || die '--bootimg-only does not accept make targets.'
    [[ -n ${STOCK_BOOT_IMG:-} ]] || die 'Set STOCK_BOOT_IMG to a working boot.img from the same ROM.'
fi
if [[ -n ${STOCK_BOOT_IMG:-} ]]; then
    [[ -s $STOCK_BOOT_IMG ]] || die "Working boot image not found: $STOCK_BOOT_IMG"
    (( $# == 0 )) || die 'Use STOCK_BOOT_IMG with the default build (no make targets).'
    STOCK_BOOT_IMG=$(realpath -- "$STOCK_BOOT_IMG")
    python3 - "$STOCK_BOOT_IMG" <<'PY'
import sys
with open(sys.argv[1], 'rb') as f:
    if f.read(8) != b'ANDROID!':
        sys.exit('Error: STOCK_BOOT_IMG must be an Android boot.img.')
PY
fi

make_boot_image() (
    command -v python3 >/dev/null 2>&1 || die 'python3 is required.'

    local STOCK=$STOCK_BOOT_IMG
    local KERNEL="$OUT_DIR/arch/arm64/boot/Image"
    local OUTPUT="$OUT_DIR/boot.img"
    local WORK
    [[ -s $STOCK ]] || die "Missing working boot image: $STOCK"
    [[ -s $KERNEL ]] || die "Missing compiled kernel: $KERNEL"
    STOCK=$(realpath -- "$STOCK")
    KERNEL=$(realpath -- "$KERNEL")
    mkdir -p -- "$(dirname -- "$OUTPUT")"
    OUTPUT=$(realpath -m -- "$OUTPUT")
    [[ $OUTPUT != "$STOCK" && $OUTPUT != "$KERNEL" ]] || die 'Output must differ from both inputs.'
    [[ ! -d $OUTPUT ]] || die 'Output must be a filename, not a directory.'

    python3 - "$STOCK" "$KERNEL" <<'PY'
import sys
with open(sys.argv[1], 'rb') as f:
    if f.read(8) != b'ANDROID!':
        sys.exit('Error: template must be an Android boot.img.')
with open(sys.argv[2], 'rb') as f:
    header = f.read(64)
    if header[56:60] != b'ARM\x64':
        sys.exit('Error: use the raw ARM64 Image, not Image.gz or boot.img.')
PY

    WORK=$(mktemp -d "$(dirname -- "$OUTPUT")/.bootimg.XXXXXX")
    trap 'rm -rf -- "$WORK"' EXIT

    if [[ -n ${MAGISKBOOT:-} ]]; then
        MAGISKBOOT=$(command -v -- "$MAGISKBOOT") || die 'MAGISKBOOT executable not found.'
    elif [[ -x $ROOT/toolchain/magiskboot ]]; then
        MAGISKBOOT=$ROOT/toolchain/magiskboot
    elif command -v magiskboot >/dev/null 2>&1; then
        MAGISKBOOT=$(command -v magiskboot)
    else
        [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Automatic tool download requires Linux x86_64.'
        for tool in curl sha256sum; do
            command -v "$tool" >/dev/null 2>&1 || die "Missing dependency: $tool"
        done
        printf 'Downloading the official Magisk boot-image tool...\n'
        curl --fail --location --retry 3 --connect-timeout 30 \
            https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk \
            -o "$WORK/Magisk.apk"
        printf '%s  %s\n' \
            89cefac0a318afa39fb3880c45c87b036c05bc1ebf02a7a715b7f8d7c26ac6e7 \
            "$WORK/Magisk.apk" | sha256sum --check --status || die 'Magisk APK checksum mismatch.'
        python3 - "$WORK/Magisk.apk" "$WORK/magiskboot" <<'PY'
import pathlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as apk:
    binary = pathlib.Path(sys.argv[2])
    binary.write_bytes(apk.read('lib/x86_64/libmagiskboot.so'))
    binary.chmod(0o755)
PY
        mkdir -p -- "$ROOT/toolchain"
        mv -- "$WORK/magiskboot" "$ROOT/toolchain/magiskboot"
        MAGISKBOOT=$ROOT/toolchain/magiskboot
    fi
    MAGISKBOOT=$(realpath -- "$MAGISKBOOT")
    [[ -x $MAGISKBOOT ]] || die 'magiskboot must be executable.'

    mkdir -- "$WORK/unpacked"
    (
        cd -- "$WORK/unpacked"
        "$MAGISKBOOT" unpack -h "$STOCK"
        [[ -s kernel ]] || die 'Template has no kernel.'
        cp -- "$KERNEL" kernel
        "$MAGISKBOOT" repack "$STOCK" "$WORK/boot.img"
    )
    [[ -s $WORK/boot.img ]] || die 'Repacking did not produce boot.img.'
    mv -f -- "$WORK/boot.img" "$OUTPUT"
    printf '\nBoot image created: %s\n' "$OUTPUT"
)



if (( BOOTIMG_ONLY )); then
    make_boot_image
    exit 0
fi

# The bundled DTC 1.4.4 cannot parse Raphael's external-node overlays.
DTC_EXT=${DTC_EXT:-$(command -v dtc || true)}
[[ -n $DTC_EXT ]] || die 'Install device-tree-compiler or set DTC_EXT=/path/to/modern/dtc.'
DTC_EXT=$(command -v -- "$DTC_EXT") || die 'DTC_EXT executable not found.'
DTC_EXT=$(realpath -- "$DTC_EXT")
printf '/dts-v1/; /plugin/; &external { status = "okay"; };\n' |
    "$DTC_EXT" -@ -I dts -O dtb -o /dev/null 2>/dev/null ||
    die 'DTC_EXT cannot parse external-node overlays; install a newer device-tree-compiler.'

download_toolchain() (
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
        die 'Boolx Clang requires a Linux x86_64 host.'
    for tool in curl tar zstd sha256sum mktemp; do
        command -v "$tool" >/dev/null 2>&1 || die "Downloading requires $tool."
    done
    local url=https://github.com/onettboots/boolx-clang-build/releases/download/Boolx-22/boolx-clang22.tar.zst
    local checksum=5a5778d43b6f1f1531e8939213746b2b0b10d1445c3e0db84f5c24f29ce0a131
    local destination=$TOOLCHAIN staging
    [[ ! -e $destination ]] || die "Incomplete toolchain at $destination; move it aside and retry."
    mkdir -p -- "$(dirname -- "$destination")"
    staging=$(mktemp -d "${destination}.download.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    printf 'Downloading Boolx Clang 22 to %s...\n' "$destination"
    if ! curl --fail --location --retry 3 --connect-timeout 30 \
        "$url" -o "$staging/toolchain.tar.zst"; then
        die 'Boolx Clang download failed.'
    fi
    printf '%s  %s\n' "$checksum" "$staging/toolchain.tar.zst" |
        sha256sum --check --status || die 'Toolchain checksum verification failed.'
    mkdir -- "$staging/unpacked"
    # The release archive contains a top-level boolx-clang/ directory.
    if ! tar --zstd -xf "$staging/toolchain.tar.zst" \
        --strip-components=1 -C "$staging/unpacked"; then
        die 'Could not extract Boolx Clang.'
    fi
    [[ -x $staging/unpacked/bin/clang ]] || die 'Archive does not contain bin/clang.'
    mv -- "$staging/unpacked" "$destination"
)

if [[ ! -x $TOOLCHAIN/bin/clang && ! -x $TOOLCHAIN/clang ]]; then
    download_toolchain
fi

[[ -d $TOOLCHAIN/bin ]] && TOOLCHAIN=$TOOLCHAIN/bin
[[ -d $TOOLCHAIN ]] || die "Toolchain directory not found: $TOOLCHAIN"
TOOLCHAIN=$(cd -- "$TOOLCHAIN" && pwd -P)
export PATH="$TOOLCHAIN:$PATH"
for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip llvm-dis; do
    [[ -x $TOOLCHAIN/$tool ]] || die "Missing $TOOLCHAIN/$tool; use a complete LLVM 22 toolchain."
    version=$("$TOOLCHAIN/$tool" --version)
    [[ $version =~ version[[:space:]]+22\. || $version =~ LLD[[:space:]]+22\. ]] ||
        die "$tool must be version 22: ${version%%$'\n'*}"
done
for tool in make gcc g++ bc bison flex python3 perl pkg-config gzip; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing host dependency: $tool (see ./build.sh --help)."
done

setup_rtl88x2bu() (
    local driver="$ROOT/drivers/net/wireless/realtek/rtl88x2bu"
    local revision=465ae7cb522a382adc85ea5c31f228af8d172148
    local checksum=2fb1915e3711912101cd1b8924fdec944900fcebaec45d62624e11b63b92a76d
    local staging
    if [[ ! -f $driver/Makefile ]]; then
        [[ ! -e $driver ]] || die "Incomplete driver directory: $driver"
        for tool in curl tar sha256sum; do
            command -v "$tool" >/dev/null 2>&1 || die "Driver setup requires $tool."
        done
        staging=$(mktemp -d "$ROOT/.rtl88x2bu.XXXXXX")
        trap 'rm -rf -- "$staging"' EXIT
        printf 'Downloading RTL8812BU/RTL8822BU driver for Archer T3U Plus...\n'
        curl --fail --location --retry 3 --connect-timeout 30 \
            "https://codeload.github.com/RinCat/RTL88x2BU-Linux-Driver/tar.gz/$revision" \
            -o "$staging/driver.tar.gz"
        printf '%s  %s\n' "$checksum" "$staging/driver.tar.gz" |
            sha256sum --check --status || die 'Driver archive checksum mismatch.'
        mkdir -- "$staging/source"
        tar -xzf "$staging/driver.tar.gz" --strip-components=1 -C "$staging/source"
        mkdir -p -- "$(dirname -- "$driver")"
        mv -- "$staging/source" "$driver"
    fi
    python3 - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
driver = root / 'drivers/net/wireless/realtek/rtl88x2bu'

# Keep these edits idempotent and refuse unexpected driver source changes.
def replace_once(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        sys.exit(f'Error: unexpected source contents in {path}; check the pinned driver version.')
    path.write_text(text.replace(old, new, 1))

replace_once(driver / 'Makefile',
    'CONFIG_PLATFORM_I386_PC = y', 'CONFIG_PLATFORM_I386_PC = n')
replace_once(driver / 'Makefile',
    'CONFIG_RTW_LOG_LEVEL = 3', 'CONFIG_RTW_LOG_LEVEL = 4')
replace_once(driver / 'Makefile',
    'ccflags-y += $(USER_EXTRA_CFLAGS)\n',
    'ccflags-y += $(USER_EXTRA_CFLAGS)\n'
    "# Built-in ARM64 kernel integration; use the parent kernel's architecture/tools.\n"
    'ccflags-y += -DCONFIG_LITTLE_ENDIAN\n'
    'ccflags-y += -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT\n')

# This small Kconfig belongs to the pinned imported driver.
(driver / 'Kconfig').write_text('''config RTL8822BU
\ttristate "Realtek RTL8812BU/RTL8822BU USB WiFi"
\tdepends on USB && CFG80211
\tselect CFG80211_WEXT
\tselect WEXT_PRIV
\thelp
\t  Support Realtek RTL8812BU and RTL8822BU USB wireless adapters,
\t  including TP-Link Archer T3U Plus (USB ID 2357:0138).
''')
parent = driver.parent
path = parent / 'Kconfig'
text = path.read_text()
include = 'source "drivers/net/wireless/realtek/rtl88x2bu/Kconfig"'
if include not in text:
    marker = 'endif # WLAN_VENDOR_REALTEK'
    if marker not in text:
        sys.exit('Error: unexpected Realtek Kconfig layout.')
    path.write_text(text.replace(marker, include + '\n\n' + marker))
path = parent / 'Makefile'
text = path.read_text()
if 'obj-$(CONFIG_RTL8822BU)' not in text:
    path.write_text(text.rstrip() + '\nobj-$(CONFIG_RTL8822BU) += rtl88x2bu/\n')
path = root / 'arch/arm64/configs/raphael_defconfig'
text = path.read_text()
for option in ('CFG80211_WEXT', 'WLAN_VENDOR_REALTEK', 'RTL8822BU'):
    pattern = rf'^(?:CONFIG_{option}=.*|# CONFIG_{option} is not set)$'
    line = f'CONFIG_{option}=y'
    if re.search(pattern, text, re.M):
        text = re.sub(pattern, line, text, flags=re.M)
    else:
        text = text.rstrip() + '\n' + line + '\n'
path.write_text(text)

# Consume all llvm-nm output to avoid LLVM 22 broken-pipe messages.
path = root / 'scripts/Makefile.build'
text = path.read_text()
path.write_text(text.replace('| grep -q __ksymtab;', '| grep __ksymtab >/dev/null;'))
(driver / 'RAPHAEL_UPSTREAM').write_text(
    'https://github.com/RinCat/RTL88x2BU-Linux-Driver\n'
    '465ae7cb522a382adc85ea5c31f228af8d172148\n')
PY
)

setup_rtl88x2bu

setup_kernelsu_next() (
    local source="$ROOT/KernelSU-Next"
    local revision=b933b1f728116a456fbebf27b6a8772a640cdf23
    local checksum=e68647c65d416245e2e6ca1c86b84ffc4bb5736a8947ce73946902ae9b8586c6
    local staging backup
    if [[ ! -f $source/RAPHAEL_UPSTREAM ]] ||
       ! grep -qx "$revision" "$source/RAPHAEL_UPSTREAM"; then
        for tool in curl tar sha256sum; do
            command -v "$tool" >/dev/null 2>&1 || die "KernelSU-Next setup requires $tool."
        done
        staging=$(mktemp -d "$ROOT/.ksunext.XXXXXX")
        trap 'rm -rf -- "$staging"' EXIT
        printf 'Downloading official KernelSU-Next legacy for Linux 4.14...\n'
        curl --fail --location --retry 3 --connect-timeout 30 \
            "https://codeload.github.com/KernelSU-Next/KernelSU-Next/tar.gz/$revision" \
            -o "$staging/source.tar.gz"
        printf '%s  %s\n' "$checksum" "$staging/source.tar.gz" |
            sha256sum --check --status || die 'KernelSU-Next legacy source checksum mismatch.'
        mkdir -- "$staging/source"
        tar -xzf "$staging/source.tar.gz" --strip-components=1 -C "$staging/source"
        if [[ -e $source ]]; then
            backup="$ROOT/KernelSU-Next.backup-$(date -u +%Y%m%dT%H%M%S)-$$"
            mv -- "$source" "$backup"
            printf 'Previous source preserved at %s\n' "$backup"
        fi
        mv -- "$staging/source" "$source"
    fi
    python3 - "$ROOT" <<'PY'
from pathlib import Path
import json, re, sys
root = Path(sys.argv[1])
# Manual hooks and any 4.14 compatibility edits are pinned to this source tree.
replacements = json.loads(r'''{
    "drivers/input/input.c": [["#define pr_fmt(fmt) KBUILD_BASENAME \": \" fmt\n\n#include <linux/init.h>\n#include <linux/types.h>\n#include <linux/idr.h>\n#include <linux/input/mt.h>\n", "#define pr_fmt(fmt) KBUILD_BASENAME \": \" fmt\n\n#include <linux/init.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/types.h>\n#include <linux/idr.h>\n#include <linux/input/mt.h>\n"], ["static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n\tint disposition = input_get_disposition(dev, type, code, &value);\n\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n\t\tadd_input_randomness(type, code, value);\n\n", "static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n\tint disposition;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n\tdisposition = input_get_disposition(dev, type, code, &value);\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n\t\tadd_input_randomness(type, code, value);\n\n"]],
    "fs/exec.c": [[" */\n\n#include <linux/slab.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n#include <linux/mm.h>\n", " */\n\n#include <linux/slab.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n#include <linux/mm.h>\n"], ["\tstruct files_struct *displaced;\n\tint retval;\n\n\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n", "\tstruct files_struct *displaced;\n\tint retval;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t/* execve_file() may provide a file without a filename. */\n\tif (filename && !IS_ERR(filename))\n\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif\n\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n"]],
    "fs/open.c": [[" */\n\n#include <linux/string.h>\n#include <linux/mm.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n", " */\n\n#include <linux/string.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/mm.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n"], ["\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */\n\t\treturn -EINVAL;\n\n", "\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_su_compat_enabled))\n\t\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */\n\t\treturn -EINVAL;\n\n"]],
    "fs/stat.c": [[" *  Copyright (C) 1991, 1992  Linus Torvalds\n */\n\n#include <linux/export.h>\n#include <linux/mm.h>\n#include <linux/errno.h>\n#include <linux/file.h>\n#include <linux/highuid.h>\n", " *  Copyright (C) 1991, 1992  Linus Torvalds\n */\n\n#include <linux/export.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/mm.h>\n#include <linux/errno.h>\n#include <linux/file.h>\n#include <linux/highuid.h>\n"], ["\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |\n\t\t       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)\n\t\treturn -EINVAL;\n\n", "\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_su_compat_enabled))\n\t\tksu_handle_stat(&dfd, &filename, &flags);\n#endif\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |\n\t\t       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)\n\t\treturn -EINVAL;\n\n"], ["\n\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat, int, dfd, const char __user *, pathname,\n", "\n\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (!error && unlikely(ksu_init_rc_hook))\n\t\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat, int, dfd, const char __user *, pathname,\n"], ["\n\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n", "\n\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (!error && unlikely(ksu_init_rc_hook))\n\t\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n"]],
    "fs/read_write.c": [[" */\n\n#include <linux/slab.h>\n#include <linux/stat.h>\n#include <linux/sched/xacct.h>\n#include <linux/fcntl.h>\n", " */\n\n#include <linux/slab.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/stat.h>\n#include <linux/sched/xacct.h>\n#include <linux/fcntl.h>\n"], ["\nSYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f = fdget_pos(fd);\n\tssize_t ret = -EBADF;\n\n\tif (f.file) {\n\t\tloff_t pos = file_pos_read(f.file);\n\t\tret = vfs_read(f.file, buf, count, &pos);\n", "\nSYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f;\n\tssize_t ret = -EBADF;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd);\n#endif\n\tf = fdget_pos(fd);\n\tif (f.file) {\n\t\tloff_t pos = file_pos_read(f.file);\n\t\tret = vfs_read(f.file, buf, count, &pos);\n"]],
    "kernel/reboot.c": [["#define pr_fmt(fmt)\t\"reboot: \" fmt\n\n#include <linux/ctype.h>\n#include <linux/export.h>\n#include <linux/kexec.h>\n#include <linux/kmod.h>\n", "#define pr_fmt(fmt)\t\"reboot: \" fmt\n\n#include <linux/ctype.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/export.h>\n#include <linux/kexec.h>\n#include <linux/kmod.h>\n"], ["\tchar buffer[256];\n\tint ret = 0;\n\n\t/* We only trust the superuser with rebooting the system. */\n\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))\n\t\treturn -EPERM;\n", "\tchar buffer[256];\n\tint ret = 0;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\t/* We only trust the superuser with rebooting the system. */\n\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))\n\t\treturn -EPERM;\n"]],
    "fs/namespace.c": [["\n#endif\n\nstatic bool is_mnt_ns_file(struct dentry *dentry)\n{\n\t/* Is this a proxy for a mount namespace? */\n", "\n#endif\n\nstatic int can_umount(const struct path *path, int flags)\n {\n\t struct mount *mnt = real_mount(path->mnt);\n\t if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))\n\t\t return -EINVAL;\n\t if (!may_mount())\n\t\t return -EPERM;\n\t if (path->dentry != path->mnt->mnt_root)\n\t\t return -EINVAL;\n\t if (!check_mnt(mnt))\n\t\t return -EINVAL;\n\t if (mnt->mnt.mnt_flags & MNT_LOCKED)\n\t\t return -EINVAL;\n\t if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))\n\t\t return -EPERM;\n\t return 0;\n }\n\nint path_umount(struct path *path, int flags)\n {\n\t struct mount *mnt = real_mount(path->mnt);\n\t int ret;\n\t ret = can_umount(path, flags);\n\t if (!ret)\n\t\t ret = do_umount(mnt, flags);\n\t dput(path->dentry);\n\t mntput_no_expire(mnt);\n\t return ret;\n }\n\nstatic bool is_mnt_ns_file(struct dentry *dentry)\n{\n\t/* Is this a proxy for a mount namespace? */\n"]],
    "fs/internal.h": [["extern int sb_prepare_remount_readonly(struct super_block *);\n\nextern void __init mnt_init(void);\n\nextern int __mnt_want_write(struct vfsmount *);\nextern int __mnt_want_write_file(struct file *);\n", "extern int sb_prepare_remount_readonly(struct super_block *);\n\nextern void __init mnt_init(void);\nint path_umount(struct path *path, int flags);\n\nextern int __mnt_want_write(struct vfsmount *);\nextern int __mnt_want_write_file(struct file *);\n"]],
    "include/linux/seccomp.h": [["#ifdef CONFIG_SECCOMP\n\n#include <linux/thread_info.h>\n#include <asm/seccomp.h>\n\nstruct seccomp_filter;\n", "#ifdef CONFIG_SECCOMP\n\n#include <linux/thread_info.h>\n#include <linux/atomic.h>\n#include <asm/seccomp.h>\n\nstruct seccomp_filter;\n"], [" */\nstruct seccomp {\n\tint mode;\n\tstruct seccomp_filter *filter;\n};\n\n", " */\nstruct seccomp {\n\tint mode;\n\tatomic_t filter_count;\n\tstruct seccomp_filter *filter;\n};\n\n"]],
    "KernelSU-Next/kernel/Kbuild": [["ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR\nendif\n\n# Handle optional backports\nifeq ($(shell grep -q \"strncpy_from_user_nofault\" $(srctree)/include/linux/uaccess.h; echo $$?),0)\nccflags-y += -DKSU_OPTIONAL_STRNCPY\n", "ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR\nendif\n\n# Detect Android/vendor kernels that backported __poll_t before 4.16.\nifeq ($(shell grep -Eq \"typedef.*__poll_t\" $(srctree)/include/uapi/linux/types.h $(srctree)/include/linux/types.h; echo $$?),0)\nccflags-y += -DKSU_HAS_POLL_T\nendif\n\n# Handle optional backports\nifeq ($(shell grep -q \"strncpy_from_user_nofault\" $(srctree)/include/linux/uaccess.h; echo $$?),0)\nccflags-y += -DKSU_OPTIONAL_STRNCPY\n"]],
    "KernelSU-Next/kernel/infra/event_queue.h": [["#include <linux/wait.h>\n\n#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 16, 0)\ntypedef unsigned int __poll_t;\n#endif\n\n", "#include <linux/wait.h>\n\n#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 16, 0) && !defined(KSU_HAS_POLL_T)\ntypedef unsigned int __poll_t;\n#endif\n\n"]],
    "KernelSU-Next/kernel/feature/sucompat.c": [["\tconst char su[] = SU_PATH;\n\tstatic const char ksud_path[] = KSUD_PATH;\n\tstruct ksu_sulog_pending_event *pending_root = NULL;\n\tconst char *const *sucompat_argv = (const char *const *)__never_use_argv;\n\n\tif (unlikely(!filename_ptr))\n\t\treturn 0;\n", "\tconst char su[] = SU_PATH;\n\tstatic const char ksud_path[] = KSUD_PATH;\n\tstruct ksu_sulog_pending_event *pending_root = NULL;\n\n\tif (unlikely(!filename_ptr))\n\t\treturn 0;\n"], ["\n\tpr_info(\"do_execveat_common su found\\n\");\n\n\tpending_root = ksu_sulog_capture_root_execve_kern(filename->name, sucompat_argv, GFP_KERNEL);\n\n\tmemcpy((void *)filename->name, ksud_path, sizeof(ksud_path));\n\n", "\n\tpr_info(\"do_execveat_common su found\\n\");\n\n\t/* argv is a struct user_arg_ptr, not an array of kernel strings. */\n\tpending_root = ksu_sulog_capture_root_execve_kern(filename->name, NULL, GFP_KERNEL);\n\n\tmemcpy((void *)filename->name, ksud_path, sizeof(ksud_path));\n\n"]],
    "include/linux/ksu_manual_hooks.h": [["", "/* SPDX-License-Identifier: GPL-2.0 */\n#ifndef _LINUX_KSU_MANUAL_HOOKS_H\n#define _LINUX_KSU_MANUAL_HOOKS_H\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n#include <linux/compiler.h>\n#include <linux/types.h>\n\nstruct filename;\nstruct stat;\nstruct stat64;\nextern bool ksu_su_compat_enabled;\nextern bool ksu_init_rc_hook;\nextern bool ksu_input_hook;\n\nint ksu_handle_execveat(int *fd, struct filename **filename, void *argv,\n\t\t       void *envp, int *flags);\nint ksu_handle_faccessat(int *dfd, const char __user **filename, int *mode,\n\t\t       int *flags);\nint ksu_handle_stat(int *dfd, const char __user **filename, int *flags);\nvoid ksu_handle_sys_read(unsigned int fd);\nvoid ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf);\nvoid ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf);\nint ksu_handle_input_handle_event(unsigned int *type, unsigned int *code,\n\t\t\t\t int *value);\nint ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n\t\t\t void __user **arg);\n#endif\n\n#endif /* _LINUX_KSU_MANUAL_HOOKS_H */\n"]]
}''')
for name, changes in replacements.items():
    path = root / name
    text = path.read_text() if path.exists() else ''
    original = text
    for old, new in changes:
        if new in text:
            continue
        if old == '' and text == '':
            text = new
        elif old and text.count(old) == 1:
            text = text.replace(old, new, 1)
        else:
            sys.exit(f'Error: cannot apply KernelSU-Next integration to {name}; source tree differs.')
    if text != original:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

link = root / 'drivers/kernelsu'
if link.is_symlink():
    resolved = link.resolve()
    if resolved == (root / 'KernelSU/kernel').resolve():
        link.unlink()
        link.symlink_to('../KernelSU-Next/kernel', target_is_directory=True)
    elif resolved != (root / 'KernelSU-Next/kernel').resolve():
        sys.exit('Error: another KernelSU integration already occupies drivers/kernelsu.')
elif link.exists():
    sys.exit('Error: drivers/kernelsu already exists; refusing to replace it.')
else:
    link.symlink_to('../KernelSU-Next/kernel', target_is_directory=True)
path = root / 'drivers/Makefile'
text = path.read_text()
if 'obj-$(CONFIG_KSU)' not in text:
    # Match the tested tree's built-in initialization order.
    marker = re.search(r'^obj-y[ \t]+\+=[ \t]+bus/\n', text, re.M)
    if not marker:
        sys.exit('Error: unexpected drivers/Makefile layout.')
    at = marker.end()
    path.write_text(text[:at] + 'obj-$(CONFIG_KSU)\t\t+= kernelsu/\n' + text[at:])
path = root / 'drivers/Kconfig'
text = path.read_text()
include = 'source "drivers/kernelsu/Kconfig"'
if include not in text:
    at = text.rfind('endmenu')
    if at < 0:
        sys.exit('Error: unexpected drivers/Kconfig layout.')
    path.write_text(text[:at] + include + '\n\n' + text[at:])
(root / 'KernelSU-Next/RAPHAEL_UPSTREAM').write_text(
    'https://github.com/KernelSU-Next/KernelSU-Next/tree/legacy\n'
    'b933b1f728116a456fbebf27b6a8772a640cdf23\n'
    'Built-in manual hooks for Raphael Linux 4.14; reported KSU version 33318.\n')
PY
)

if (( WITH_KSU )); then
    setup_kernelsu_next
fi


DEFCONFIG=${DEFCONFIG:-raphael_defconfig}
[[ -f arch/arm64/configs/$DEFCONFIG ]] || die "Unknown configuration: $DEFCONFIG"
JOBS=${JOBS:-4}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer.'
LLVM_IAS=${LLVM_IAS:-1}
[[ $LLVM_IAS == 0 || $LLVM_IAS == 1 ]] || die 'LLVM_IAS must be 0 or 1.'

# This 4.14 tree accepts LLVM=1, not modern LLVM=-22 suffix selection.
# PATH also selects unversioned LLVM_AR/LLVM_NM used internally for LTO.
args=(O="$OUT_DIR" ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS="$LLVM_IAS"
      DTC_EXT="$DTC_EXT"
      CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-
      CC="$TOOLCHAIN/clang" LD="$TOOLCHAIN/ld.lld"
      HOSTCC=gcc HOSTCXX=g++ PYTHON=python3)
if (( WITH_KSU )); then
    args+=(KSU_VERSION_OVERRIDE=33318 KSU_VERSION_TAG_OVERRIDE=v3.4.0-legacy-b933b1f)
fi
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-$(id -un)}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-$(hostname)}
compiler_version=$("$TOOLCHAIN/clang" --version)
printf 'Compiler: %s\nConfig: %s\nOutput: %s\nJobs: %s\n' \
    "${compiler_version%%$'\n'*}" "$DEFCONFIG" "$OUT_DIR" "$JOBS"

# NetHunter kernel profile for this 4.14 tree. The vendor 88x2bu driver uses
# cfg80211 directly; enabling mac80211 does not change that driver's TX path.
# Keep the Android module ABI settings, release string and SELinux policy unchanged.
nethunter_options=(
    # Kali chroot, IPC and normal Linux userspace interfaces.
    SYSVIPC POSIX_MQUEUE NAMESPACES UTS_NS IPC_NS PID_NS NET_NS
    FHANDLE UNIX98_PTYS PROC_FS SYSFS TMPFS TMPFS_POSIX_ACL TMPFS_XATTR
    BLK_DEV_LOOP IKCONFIG IKCONFIG_PROC MODULES MODULE_UNLOAD
    # Packet capture, tunnels, forwarding and the existing Android iptables ABI.
    NET UNIX PACKET INET IPV6 NETDEVICES TUN VETH BRIDGE BRIDGE_NETFILTER
    NETFILTER NETFILTER_ADVANCED NETFILTER_NETLINK
    NETFILTER_NETLINK_QUEUE NETFILTER_NETLINK_LOG
    NF_CONNTRACK NF_CONNTRACK_IPV4 NF_CONNTRACK_IPV6 NF_NAT NF_NAT_IPV4
    NETFILTER_XTABLES NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MATCH_STATE
    NETFILTER_XT_MATCH_COMMENT NETFILTER_XT_MATCH_STRING
    NETFILTER_XT_TARGET_NFQUEUE NETFILTER_XT_TARGET_NFLOG
    NETFILTER_XT_TARGET_REDIRECT NETFILTER_XT_TARGET_TPROXY
    IP_NF_IPTABLES IP_NF_FILTER IP_NF_MANGLE IP_NF_RAW IP_NF_NAT
    IP_NF_TARGET_MASQUERADE IP_NF_TARGET_REDIRECT
    IP6_NF_IPTABLES IP6_NF_FILTER IP6_NF_MANGLE IP6_NF_RAW
    IP_SET IP_SET_HASH_IP IP_SET_HASH_NET IP_SET_HASH_IPPORT
    IP_SET_LIST_SET NETFILTER_XT_SET
    # USB host peripherals and external Bluetooth; drivers are built in.
    USB USB_XHCI_HCD USB_DWC3 USB_DWC3_DUAL_ROLE USB_ACM USB_MON
    USB_SERIAL USB_SERIAL_FTDI_SIO USB_SERIAL_CP210X
    USB_SERIAL_PL2303 USB_SERIAL_CH341
    USB_USBNET USB_NET_CDCETHER USB_NET_RNDIS_HOST USB_RTL8150 USB_RTL8152
    BT BT_BREDR BT_RFCOMM BT_RFCOMM_TTY
    BT_HCIBTUSB BT_HCIBTUSB_BCM BT_HCIBTUSB_RTL
    CFG80211 CFG80211_WEXT MAC80211 MAC80211_MESH
    WLAN WLAN_VENDOR_REALTEK RTL8822BU
    # Modern configfs gadgets already implement HID; no legacy HID patch needed.
    USB_GADGET CONFIGFS_FS USB_CONFIGFS USB_CONFIGFS_F_FS
    USB_CONFIGFS_SERIAL USB_CONFIGFS_ACM USB_CONFIGFS_OBEX
    USB_CONFIGFS_NCM USB_CONFIGFS_ECM USB_CONFIGFS_ECM_SUBSET
    USB_CONFIGFS_RNDIS USB_CONFIGFS_EEM USB_CONFIGFS_MASS_STORAGE
    USB_CONFIGFS_F_HID
)
apply_nethunter_config() {
    local config=$1 option
    local changes=()
    for option in "${nethunter_options[@]}"; do
        changes+=(-e "$option")
    done
    "$ROOT/scripts/config" --file "$config" "${changes[@]}"
}
verify_nethunter_config() {
    local option missing=0 report="$OUT_DIR/nethunter-config.txt"
    {
        printf 'NetHunter kernel configuration for Raphael (Linux 4.14)\n'
        printf 'Compiler: %s\n\n' "${compiler_version%%$'\n'*}"
        for option in "${nethunter_options[@]}"; do
            if grep -Fqx "CONFIG_${option}=y" "$OUT_DIR/.config"; then
                printf 'CONFIG_%s=y\n' "$option"
            else
                printf 'MISSING: CONFIG_%s=y\n' "$option"
                printf 'NetHunter: CONFIG_%s did not resolve to y.\n' "$option" >&2
                missing=1
            fi
        done
        printf '\nKali rootfs/apps, Android USB gadget setup and firmware are separate.\n'
        printf 'Phone boot, USB peripherals and Wi-Fi monitor/injection need device testing.\n'
    } > "$report"
    (( missing == 0 )) || die "NetHunter configuration is incomplete; see $report"
    printf 'NetHunter kernel profile verified: %s\n' "$report"
}

migrate_legacy_defconfig() {
    # Earlier versions wrote optional features into the source defconfig.
    # Undo only those recognized edits, retaining the independent Wi-Fi driver.
    python3 - "$ROOT" "$OUT_DIR" "${nethunter_options[@]}" <<'PY'
from pathlib import Path
import datetime, json, os, re, shutil, sys
root, output = map(Path, sys.argv[1:3])
nh = set(sys.argv[3:])
path = root / 'arch/arm64/configs/raphael_defconfig'
text = path.read_text()
lines = text.splitlines()
def key(line):
    m = re.match(r'(?:CONFIG_([A-Z0-9_]+)=|# CONFIG_([A-Z0-9_]+) is not set$)', line)
    return (m[1] or m[2]) if m else None
values = {key(line): line for line in lines if key(line)}
stock = json.loads(r'''{"FHANDLE":"# CONFIG_FHANDLE is not set","IKCONFIG":"CONFIG_IKCONFIG=y","IKCONFIG_PROC":"CONFIG_IKCONFIG_PROC=y","NAMESPACES":"CONFIG_NAMESPACES=y","PID_NS":"# CONFIG_PID_NS is not set","MODULES":"CONFIG_MODULES=y","MODULE_UNLOAD":"CONFIG_MODULE_UNLOAD=y","NET":"CONFIG_NET=y","PACKET":"CONFIG_PACKET=y","UNIX":"CONFIG_UNIX=y","INET":"CONFIG_INET=y","NETFILTER":"CONFIG_NETFILTER=y","BRIDGE_NETFILTER":"# CONFIG_BRIDGE_NETFILTER is not set","NF_CONNTRACK":"CONFIG_NF_CONNTRACK=y","NETFILTER_XT_TARGET_NFLOG":"CONFIG_NETFILTER_XT_TARGET_NFLOG=y","NETFILTER_XT_TARGET_NFQUEUE":"CONFIG_NETFILTER_XT_TARGET_NFQUEUE=y","NETFILTER_XT_TARGET_TPROXY":"CONFIG_NETFILTER_XT_TARGET_TPROXY=y","NETFILTER_XT_MATCH_COMMENT":"CONFIG_NETFILTER_XT_MATCH_COMMENT=y","NETFILTER_XT_MATCH_CONNTRACK":"CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y","NETFILTER_XT_MATCH_STATE":"CONFIG_NETFILTER_XT_MATCH_STATE=y","NETFILTER_XT_MATCH_STRING":"CONFIG_NETFILTER_XT_MATCH_STRING=y","NF_CONNTRACK_IPV4":"CONFIG_NF_CONNTRACK_IPV4=y","IP_NF_IPTABLES":"CONFIG_IP_NF_IPTABLES=y","IP_NF_FILTER":"CONFIG_IP_NF_FILTER=y","IP_NF_NAT":"CONFIG_IP_NF_NAT=y","IP_NF_TARGET_MASQUERADE":"CONFIG_IP_NF_TARGET_MASQUERADE=y","IP_NF_TARGET_REDIRECT":"CONFIG_IP_NF_TARGET_REDIRECT=y","IP_NF_MANGLE":"CONFIG_IP_NF_MANGLE=y","IP_NF_RAW":"CONFIG_IP_NF_RAW=y","NF_CONNTRACK_IPV6":"CONFIG_NF_CONNTRACK_IPV6=y","IP6_NF_IPTABLES":"CONFIG_IP6_NF_IPTABLES=y","IP6_NF_FILTER":"CONFIG_IP6_NF_FILTER=y","IP6_NF_MANGLE":"CONFIG_IP6_NF_MANGLE=y","IP6_NF_RAW":"CONFIG_IP6_NF_RAW=y","BRIDGE":"CONFIG_BRIDGE=y","BT":"CONFIG_BT=y","CFG80211":"CONFIG_CFG80211=y","BLK_DEV_LOOP":"CONFIG_BLK_DEV_LOOP=y","NETDEVICES":"CONFIG_NETDEVICES=y","TUN":"CONFIG_TUN=y","VETH":"CONFIG_VETH=y","USB_RTL8152":"CONFIG_USB_RTL8152=y","USB_USBNET":"CONFIG_USB_USBNET=y","USB_XHCI_HCD":"CONFIG_USB_XHCI_HCD=y","USB_DWC3":"CONFIG_USB_DWC3=y","USB_GADGET":"CONFIG_USB_GADGET=y","USB_CONFIGFS":"CONFIG_USB_CONFIGFS=y","USB_CONFIGFS_NCM":"CONFIG_USB_CONFIGFS_NCM=y","USB_CONFIGFS_RNDIS":"CONFIG_USB_CONFIGFS_RNDIS=y","USB_CONFIGFS_MASS_STORAGE":"CONFIG_USB_CONFIGFS_MASS_STORAGE=y","USB_CONFIGFS_F_FS":"CONFIG_USB_CONFIGFS_F_FS=y","USB_CONFIGFS_F_HID":"CONFIG_USB_CONFIGFS_F_HID=y","TMPFS_POSIX_ACL":"CONFIG_TMPFS_POSIX_ACL=y","STATIC_USERMODEHELPER":"CONFIG_STATIC_USERMODEHELPER=y","STATIC_USERMODEHELPER_PATH":"CONFIG_STATIC_USERMODEHELPER_PATH=\"\""}''')
owned = set()
expected = {}
if all(values.get(k) == f'CONFIG_{k}=y' for k in nh):
    owned |= nh - {'CFG80211_WEXT', 'WLAN_VENDOR_REALTEK', 'RTL8822BU'}
    expected.update({k: f'CONFIG_{k}=y' for k in owned})
if values.get('KSU_MANUAL_HOOK') == 'CONFIG_KSU_MANUAL_HOOK=y':
    enabled = {'KSU', 'KSU_MANUAL_HOOK', 'KPROBES', 'KRETPROBES', 'KPROBE_EVENTS'}
    disabled = {'KSU_DEBUG', 'KSU_KPROBES_HOOK', 'KSU_SYSCALL_TABLE_HOOK', 'STATIC_USERMODEHELPER'}
    owned |= enabled | disabled
    expected.update({k: f'CONFIG_{k}=y' for k in enabled})
    expected.update({k: f'# CONFIG_{k} is not set' for k in disabled})
    # The earlier integration removed this stock path together with its enable.
    if 'STATIC_USERMODEHELPER_PATH' not in values:
        lines.append(stock['STATIC_USERMODEHELPER_PATH'])
result = []
for line in lines:
    k = key(line)
    if k in owned and line == expected[k]:
        if k in stock:
            result.append(stock[k])
    else:
        result.append(line)
updated = '\n'.join(result) + '\n'
if updated != text:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')
    backup = output / f'raphael_defconfig.before-optional-{stamp}-{os.getpid()}'
    shutil.copy2(path, backup)
    path.write_text(updated)
    print(f'Migrated legacy optional-feature defconfig; backup: {backup}')
PY
}

prepare_feature_config() {
    # Save pre-feature settings so switching flags in one OUT_DIR is reversible.
    python3 - "$OUT_DIR" "$DEFCONFIG" "$WITH_KSU" "$WITH_NETHUNTER" \
        "${nethunter_options[@]}" <<'PY'
from pathlib import Path
import datetime, json, os, re, shutil, sys
output = Path(sys.argv[1])
defconfig = sys.argv[2]
requested = {'ksu': bool(int(sys.argv[3])), 'nethunter': bool(int(sys.argv[4]))}
groups = {
    'ksu': set(('KSU KSU_MANUAL_HOOK KSU_DEBUG KSU_KPROBES_HOOK '
                'KSU_SYSCALL_TABLE_HOOK KPROBES KRETPROBES KPROBE_EVENTS '
                'STATIC_USERMODEHELPER STATIC_USERMODEHELPER_PATH').split()),
    'nethunter': set(sys.argv[5:]),
}
def key(line):
    m = re.match(r'(?:CONFIG_([A-Z0-9_]+)=|# CONFIG_([A-Z0-9_]+) is not set$)', line)
    return (m[1] or m[2]) if m else None
def values(lines):
    return {key(line): line for line in lines if key(line)}
config = output / '.config'
base = values((output / '.raphael-base.config').read_text().splitlines())
lines = config.read_text().splitlines()
current = values(lines)
state_path = output / '.raphael-features.json'
state = json.loads(state_path.read_text()) if state_path.exists() else None
if state and state.get('defconfig') != defconfig:
    sys.exit('Error: DEFCONFIG changed; select a new OUT_DIR to preserve your configuration.')
previous = state['features'] if state else {
    'ksu': current.get('KSU') in ('CONFIG_KSU=y', 'CONFIG_KSU=m'),
    'nethunter': (output / 'nethunter-config.txt').exists() or all(
        current.get(k) == f'CONFIG_{k}=y' for k in groups['nethunter']),
}
before = state['before'] if state else {k: current.get(k) for g in groups.values() for k in g}
if not state:
    # Existing always-enabled builds have no trustworthy pre-feature snapshot.
    for name, options in groups.items():
        if previous[name]:
            before.update({k: base.get(k) for k in options})
restore = {k for name, options in groups.items() if previous[name] for k in options}
if restore:
    lines = [line for line in lines if key(line) not in restore]
    lines.extend(before[k] for k in sorted(restore) if before.get(k) is not None)
restored = values(lines)
before = {k: restored.get(k) for g in groups.values() for k in g}
if not state or previous != requested:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')
    backup = output / f'.config.before-features-{stamp}-{os.getpid()}'
    shutil.copy2(config, backup)
    print(f'Configuration before feature selection saved to: {backup}')
config.write_text('\n'.join(lines) + '\n')
state = {'defconfig': defconfig, 'features': requested, 'before': before}
temporary = state_path.with_suffix('.tmp')
temporary.write_text(json.dumps(state, indent=2) + '\n')
temporary.replace(state_path)
PY
}

migrate_legacy_defconfig
# Resolve the unmodified optional-feature baseline without replacing .config.
make "${args[@]}" KCONFIG_CONFIG="$OUT_DIR/.raphael-base.config" "$DEFCONFIG"
if [[ ! -f $OUT_DIR/.config ]]; then
    cp -- "$OUT_DIR/.raphael-base.config" "$OUT_DIR/.config"
fi
prepare_feature_config
# Enable the USB driver in existing build directories as well as new configs.
"$ROOT/scripts/config" --file "$OUT_DIR/.config" \
    -e WLAN -e WLAN_VENDOR_REALTEK -e CFG80211 -e CFG80211_WEXT -e RTL8822BU
if (( WITH_KSU )); then
    "$ROOT/scripts/config" --file "$OUT_DIR/.config" \
        -e KSU -e KSU_MANUAL_HOOK -e KPROBES -e KRETPROBES -e KPROBE_EVENTS \
        -d KSU_KPROBES_HOOK -d KSU_SYSCALL_TABLE_HOOK -d KSU_DEBUG -d STATIC_USERMODEHELPER
else
    "$ROOT/scripts/config" --file "$OUT_DIR/.config" -d KSU -d KSU_MANUAL_HOOK
fi
if (( WITH_NETHUNTER )); then
    apply_nethunter_config "$OUT_DIR/.config"
else
    rm -f -- "$OUT_DIR/nethunter-config.txt"
fi
make "${args[@]}" olddefconfig
if (( WITH_NETHUNTER )); then
    verify_nethunter_config
fi
grep -qx 'CONFIG_RTL8822BU=y' "$OUT_DIR/.config" ||
    die 'RTL8822BU could not be enabled; check USB and cfg80211 configuration.'
if (( WITH_KSU )); then
    for option in KSU KSU_MANUAL_HOOK KPROBES KRETPROBES KPROBE_EVENTS; do
        grep -qx "CONFIG_${option}=y" "$OUT_DIR/.config" || die "$option could not be enabled."
    done
    # Required for the embedded KernelSU-Next pre-init runner.
    make "${args[@]}" headers_install
    printf 'KernelSU-Next: enabled (--ksu)\n'
else
    if grep -Eq '^CONFIG_KSU=(y|m)$' "$OUT_DIR/.config"; then
        die 'KernelSU remained enabled without --ksu.'
    fi
    printf 'KernelSU-Next: disabled (use --ksu to enable)\n'
fi
if (( WITH_NETHUNTER )); then
    printf 'NetHunter profile: enabled (--nethunter)\n'
else
    printf 'NetHunter profile: disabled (use --nethunter to enable)\n'
fi


if (( $# )); then
    make -j"$JOBS" "${args[@]}" "$@"
else
    make -j"$JOBS" "${args[@]}" all Image.gz
fi
printf '\nMake completed successfully. Artifacts are under %s\n' "$OUT_DIR"
if [[ -n ${STOCK_BOOT_IMG:-} ]]; then
    printf '\nPackaging boot.img using template: %s\n' "$STOCK_BOOT_IMG"
    make_boot_image
else
    printf '\nboot.img was not created because STOCK_BOOT_IMG was not supplied.\n'
    printf 'To package the compiled kernel, run:\n'
    printf '  STOCK_BOOT_IMG=/absolute/path/to/working/boot.img ./build.sh --bootimg-only\n'
fi
