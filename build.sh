#!/usr/bin/env bash
# All-in-one Raphael branch 17 build: Boolx Clang 22, NetHunter, 88x2bu,
# KernelSU-Next legacy, MIUICX display modes, boot/DTBO packaging.
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
  --high-refresh Enable MIUICX R6.1 69/75 Hz SS panel modes
  --bootimg-only Package an existing compiled kernel using STOCK_BOOT_IMG
  --dtbo-only    Create a DTBO image using STOCK_DTBO_IMG
  --wifi-diagnose Collect adapter diagnostics through adb
  --help, -h     Show this help
Feature flags can be combined and may appear before or after make targets.
--ksu and --nethunter require a build. --high-refresh also works with --dtbo-only.
Environment:
  TOOLCHAIN  LLVM 22 installation directory (default: ./toolchain/clang22)
  OUT_DIR    Build directory (default: out, relative to the source tree)
  DEFCONFIG  Configuration in arch/arm64/configs (default: raphael_defconfig)
  JOBS       Parallel jobs (default: 4)
  LLVM_IAS   Use LLVM assembler: 1 (default); 0 requires GNU cross-binutils
  DTC_EXT    External dtc executable (default: dtc from PATH)
  STOCK_BOOT_IMG  Working boot.img from the same ROM; enables boot.img packaging
  STOCK_DTBO_IMG  Working dtbo.img from the same ROM; enables DTBO packaging

Examples:
  ./build.sh
  ./build.sh --ksu
  ./build.sh --nethunter
  ./build.sh --ksu --nethunter
  ./build.sh --ksu --nethunter --high-refresh
  TOOLCHAIN=/opt/clang-22 JOBS=8 ./build.sh
  ./build.sh menuconfig
  ./build.sh --wifi-diagnose
  ./build.sh Image.gz dtbs
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh
  STOCK_BOOT_IMG=/path/to/working/boot.img ./build.sh --bootimg-only
  STOCK_DTBO_IMG=/path/to/original/dtbo.img ./build.sh --dtbo-only

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
Display mode defaults to stock 60 Hz. --high-refresh enables experimental
MIUICX R6.1 69/75 Hz for two SS EA8076 panels; 60 Hz remains preferred.
The panel overclock requires physical testing on this ROM and screen.
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
DTBO packaging accepts the reviewed original LineageOS 17 Raphael image only.
Without --high-refresh it copies the original byte for byte. With the option it
creates a fixed experimental image. Preserve the original for recovery.
Parent AVB acceptance and panel behavior require device testing.
EOF
}

WITH_KSU=0
WITH_NETHUNTER=0
WITH_HIGH_REFRESH=0
MODE=build
make_options=()
while (( $# )); do
    case "$1" in
        --ksu) WITH_KSU=1 ;;
        --nethunter) WITH_NETHUNTER=1 ;;
        --high-refresh) WITH_HIGH_REFRESH=1 ;;
        --rom-dtbo-patch) die '--rom-dtbo-patch was removed; use the original ROM DTBO with --dtbo-only.' ;;
        --help|-h) show_help; exit 0 ;;
        --bootimg-only|--dtbo-only|--wifi-diagnose)
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
if (( WITH_HIGH_REFRESH )); then
    [[ $MODE == build || $MODE == dtbo-only ]] ||
        die '--high-refresh can only be used with a build or --dtbo-only.'
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
if [[ $MODE != dtbo-only && -z ${STOCK_BOOT_IMG:-} && -s $ROOT/stock_boot.img ]] &&
   (( $# == 0 )); then
    STOCK_BOOT_IMG="$ROOT/stock_boot.img"
fi

BOOTIMG_ONLY=0
if [[ $MODE == bootimg-only ]]; then
    BOOTIMG_ONLY=1
    (( $# == 0 )) || die '--bootimg-only does not accept make targets.'
    [[ -n ${STOCK_BOOT_IMG:-} ]] || die 'Set STOCK_BOOT_IMG to a working boot.img from the same ROM.'
fi
if [[ $MODE != dtbo-only && -n ${STOCK_BOOT_IMG:-} ]]; then
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

if [[ $MODE == dtbo-only && -z ${STOCK_DTBO_IMG:-} ]]; then
    die 'Set STOCK_DTBO_IMG to a working dtbo.img from the same Raphael ROM.'
fi
if [[ -n ${STOCK_DTBO_IMG:-} ]]; then
    [[ -s $STOCK_DTBO_IMG ]] || die "Working DTBO image not found: $STOCK_DTBO_IMG"
    STOCK_DTBO_IMG=$(realpath -- "$STOCK_DTBO_IMG")
    python3 - "$STOCK_DTBO_IMG" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    raw = f.read(32)
if len(raw) != 32:
    sys.exit('Error: truncated Android DTBO table header.')
magic, total, header, entry, count, offset, page, version = struct.unpack('>8I', raw)
if magic != 0xd7b7ab1e or version not in (0, 1):
    sys.exit('Error: STOCK_DTBO_IMG must be an Android DTBO table image (v0/v1).')
PY
fi

pack_dtbo_image() (
    command -v python3 >/dev/null 2>&1 || die 'python3 is required.'
    if (( WITH_HIGH_REFRESH )); then
        command -v zstd >/dev/null 2>&1 || die 'zstd is required to create the MIUICX DTBO.'
    fi
    [[ -n ${STOCK_DTBO_IMG:-} ]] || die 'Set STOCK_DTBO_IMG to the original ROM DTBO image.'
    python3 - "$STOCK_DTBO_IMG" "$OUT_DIR/dtbo.img" "$WITH_HIGH_REFRESH" <<'PYEVDTBO'
"""Reconstruct a reviewed Raphael ROM DTBO, preserving ROM-specific data."""
import hashlib, os, pathlib, shutil, sys, tempfile

source, output = map(pathlib.Path, sys.argv[1:3])
high_refresh = sys.argv[3] == '1'
original_hash = '2a7fedf9e370b421227879ae1ca035b30028bbdbf7f7265b553770d3c60a9674'
result_hash = 'ee78571812e57f3faa97bc2e14b8630ea284872e28c805204b82d585b7db7ad7'
def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            h.update(chunk)
    return h.hexdigest()
if source.resolve() == output.resolve() or (output.exists() and os.path.samefile(source, output)):
    sys.exit('Error: DTBO output must differ from the original image.')
if sha256(source) != original_hash:
    sys.exit('Error: DTBO packaging supports only the verified original LineageOS 17 Raphael DTBO from this setup; other ROM images need a separately reviewed port.')
if not high_refresh:
    with tempfile.TemporaryDirectory(prefix='.stock-dtbo-', dir=output.parent) as work:
        result = pathlib.Path(work) / 'dtbo.img'
        shutil.copyfile(source, result)
        if sha256(result) != original_hash:
            sys.exit('Error: stock DTBO copy failed its SHA-256 check.')
        os.replace(result, output)
    print(f'Original ROM DTBO copied unchanged: {output}')
    print('The stock image keeps its original AVB footer and display settings.')
    sys.exit(0)
import base64, lzma, subprocess
# Fixed MIUICX R6.1 SS panel delta for the original 32 MiB DTBO (entry 11).
encoded = b"""
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
D9MAAfkXriQAAJRX+LGxxGf7AgAAAAAEWVo=
"""
with tempfile.TemporaryDirectory(prefix='.evo-dtbo-', dir=output.parent) as work:
    patch = pathlib.Path(work) / 'patch.zst'
    result = pathlib.Path(work) / 'dtbo.img'
    try:
        patch.write_bytes(lzma.decompress(base64.b64decode(encoded)))
        subprocess.run(['zstd', '-q', '-d', '--patch-from=' + str(source), str(patch), '-o', str(result)], check=True)
    except (lzma.LZMAError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f'Error: cannot reconstruct the reviewed DTBO: {exc}')
    if sha256(result) != result_hash:
        sys.exit('Error: reconstructed DTBO failed its SHA-256 check.')
    os.replace(result, output)
print(f'Experimental MIUICX R6.1 DTBO created: {output}')
print('This is a fixed ROM-specific 60/69/75 Hz image, not the current compiled overlay.')
print('Keep the original; parent AVB acceptance and panel behavior require device testing.')
PYEVDTBO
)

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
if [[ $MODE == dtbo-only ]]; then
    pack_dtbo_image
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

setup_raphael_display() {
    # Remove the previously embedded high-refresh port, if installed, without
    # replacing unrelated source files or requiring network/Git history.
    python3 - "$ROOT" "$OUT_DIR" "${WITH_HIGH_REFRESH:-0}" <<'PYDISPLAY'
from pathlib import Path
import hashlib, json, re, sys

root, output = map(Path, sys.argv[1:3])
high_refresh = sys.argv[3] == '1'
base = Path('arch/arm64/boot/dts/qcom')
panels = json.loads(r'''{"dsi-panel-ss-fhd-ea8076-cmd.dtsi":"dsi_ss_fhd_ea8076_cmd","dsi-panel-ss-fhd-ea8076-global-cmd.dtsi":"dsi_ss_fhd_ea8076_global_cmd","dsi-panel-samsung-fhd-ea8076-f1-cmd.dtsi":"dsi_samsung_fhd_ea8076_f1_cmd","dsi-panel-samsung-fhd-ea8076-f1mp-cmd.dtsi":"dsi_samsung_fhd_ea8076_f1mp_cmd","dsi-panel-samsung-fhd-ea8076-f1p2-cmd.dtsi":"dsi_samsung_fhd_ea8076_f1p2_cmd","dsi-panel-samsung-fhd-ea8076-f1p2-2-cmd.dtsi":"dsi_samsung_fhd_ea8076_f1p2_2_cmd"}''')
driver_edits = json.loads(r'''{"drivers/gpu/drm/msm/dsi-staging/dsi_panel.c":[["\ttiming = &mode->timing;\n\n\tif (panel_mode == DSI_OP_CMD_MODE) {\n","\ttiming = &mode->timing;\n\n\t/* Opt-in timings derive the command-mode pixel clock from the transfer\n\t * budget directly. Dividing by transfer time before multiplication would\n\t * truncate to a whole Hz and undershoot the matching DSI link clock.\n\t * Existing timings keep the original calculation below.\n\t */\n\tif (utils->read_bool(utils->data,\n\t\t\t\"qcom,mdss-dsi-transfer-time-pclk\")) {\n\t\tif (panel_mode != DSI_OP_CMD_MODE || timing->dsc_enabled ||\n\t\t    !timing->refresh_rate || !timing->clk_rate_hz ||\n\t\t    !priv_info->mdp_transfer_time_us ||\n\t\t    priv_info->mdp_transfer_time_us >=\n\t\t\tTICKS_IN_MICRO_SECOND / timing->refresh_rate) {\n\t\t\tpr_err(\"invalid clock-derived command-mode transfer budget\\n\");\n\t\t\treturn -EINVAL;\n\t\t}\n\t\tpixel_clk_khz = (u64)DSI_H_ACTIVE_DSC(timing) *\n\t\t\ttiming->v_active * 1000;\n\t\tdo_div(pixel_clk_khz, priv_info->mdp_transfer_time_us);\n\t\tmode->pixel_clk_khz = pixel_clk_khz;\n\t\treturn 0;\n\t}\n\n\tif (panel_mode == DSI_OP_CMD_MODE) {\n"]],"drivers/gpu/drm/msm/dsi-staging/dsi_drm.c":[["\t\t/* No DMS/VRR when drm pipeline is changing */\n\t\tif (!drm_mode_equal(&cur_mode, adjusted_mode) &&\n","\t\t/* Without panel timing-switch commands, use a complete modeset so\n\t\t * the destination mode's full on/off command sequences are sent.\n\t\t * No DMS/VRR when the DRM pipeline is changing.\n\t\t */\n\t\tif (display->panel->dms_mode != DSI_DMS_MODE_DISABLED &&\n\t\t\t!drm_mode_equal(&cur_mode, adjusted_mode) &&\n"],["static void dsi_drm_update_dtd(struct edid *edid,\n\t\tstruct dsi_display_mode *modes, u32 modes_count)\n","static void dsi_drm_update_dtd(struct edid *edid,\n\t\tstruct dsi_display_mode *modes, u32 modes_count,\n\t\tu32 preferred_index, bool nominal_preferred)\n"],["\t\tstruct dsi_display_mode *mode = &modes[i];\n\t\tstruct dsi_mode_info *timing = &mode->timing;\n","\t\tu32 mode_index = i == 0 ? preferred_index :\n\t\t\t(i <= preferred_index ? i - 1 : i);\n\t\tstruct dsi_display_mode *mode = &modes[mode_index];\n\t\tstruct dsi_mode_info *timing = &mode->timing;\n"],["\t\tdtd->pixel_clock = mode->pixel_clk_khz / 10;\n","\t\t/* A command-mode transfer clock is not its nominal scan clock. */\n\t\tif (i == 0 && nominal_preferred)\n\t\t\tdtd->pixel_clock = div_u64((u64)(timing->h_active + h_blank) *\n\t\t\t\t(timing->v_active + v_blank) * timing->refresh_rate +\n\t\t\t\t5000, 10000);\n\t\telse\n\t\t\tdtd->pixel_clock = mode->pixel_clk_khz / 10;\n"],["\tu32 count = 0, edid_size;\n\tstruct dsi_display_mode *modes = NULL;\n","\tu32 count = 0, edid_size, preferred_index = 0, preferred_rate = 0;\n\tbool nominal_preferred = false;\n\tstruct dsi_display_mode *modes = NULL;\n"],["\tfor (i = 0; i < count; i++) {\n\t\tstruct drm_display_mode *m;\n","\t/* Keep source mode order and bootloader timing indices unchanged. */\n\tif (display->panel &&\n\t    !display->panel->utils.read_u32(display->panel->utils.data,\n\t\t\t\"qcom,mdss-dsi-preferred-refresh-rate\",\n\t\t\t&preferred_rate)) {\n\t\tfor (i = 0; i < count; i++) {\n\t\t\tif (modes[i].timing.refresh_rate == preferred_rate) {\n\t\t\t\tpreferred_index = i;\n\t\t\t\tnominal_preferred = true;\n\t\t\t\tbreak;\n\t\t\t}\n\t\t}\n\t}\n\n\tfor (i = 0; i < count; i++) {\n\t\tstruct drm_display_mode *m;\n"],["\t\t/* set the first mode in list as preferred */\n\t\tif (i == 0)\n","\t\t/* Prefer the requested rate, or the first mode if unspecified. */\n\t\tif (i == preferred_index)\n"],["\tdsi_drm_update_dtd(&edid, modes, count);\n","\tdsi_drm_update_dtd(&edid, modes, count, preferred_index, nominal_preferred);\n"]],"Documentation/devicetree/bindings/drm/msm/mdss-dsi-panel.txt":[["- qcom,mdss-dsi-on-command-state:","- qcom,mdss-dsi-transfer-time-pclk: Boolean on a command-mode timing node.\n\t\t\t\t\tCalculate pixel clock directly from active pixels and\n\t\t\t\t\tqcom,mdss-mdp-transfer-time-us, avoiding whole-Hz\n\t\t\t\t\ttruncation. Requires an explicit nonzero panel clock,\n\t\t\t\t\ta positive transfer time shorter than one frame,\n\t\t\t\t\tand an uncompressed command-mode timing.\n\t\t\t\t\tAbsent: retain the existing pixel-clock calculation.\n- qcom,mdss-dsi-on-command-state:"],["- qcom,mdss-dsi-transfer-time-pclk: Boolean on a command-mode timing node.\n","- qcom,mdss-dsi-preferred-refresh-rate: Preferred display mode refresh rate, in Hz.\n\t\t\t\t\tIf unavailable, the first timing remains preferred.\n- qcom,mdss-dsi-transfer-time-pclk: Boolean on a command-mode timing node.\n"]],"drivers/gpu/drm/msm/sde/sde_encoder.c":[["void sde_encoder_kickoff(struct drm_encoder *drm_enc, bool is_error)\n{\n\tstruct sde_encoder_virt *sde_enc;\n","void sde_encoder_kickoff(struct drm_encoder *drm_enc, bool is_error)\n{\n\tstatic bool first_primary_dsi_kickoff = true;\n\tstruct sde_encoder_virt *sde_enc;\n"],["\t/* allow phys encs to handle any post-kickoff business */\n\tfor (i = 0; i < sde_enc->num_phys_encs; i++) {\n\t\tphys = sde_enc->phys_encs[i];\n\t\tif (phys && phys->ops.handle_post_kickoff)\n\t\t\tphys->ops.handle_post_kickoff(phys);\n\t}\n\n\tif (sde_enc->disp_info.intf_type == DRM_MODE_CONNECTOR_DSI &&\n","\t/* allow phys encs to handle any post-kickoff business */\n\tfor (i = 0; i < sde_enc->num_phys_encs; i++) {\n\t\tphys = sde_enc->phys_encs[i];\n\t\tif (phys && phys->ops.handle_post_kickoff)\n\t\t\tphys->ops.handle_post_kickoff(phys);\n\t}\n\n\t/* The bootloader initializes the panel at 60 Hz. If userspace selects a\n\t * different mode for the first continuous-splash frame, request one\n\t * existing ESD-recovery cycle to send that mode's complete on sequence.\n\t * Consume the flag only for a valid primary DSI kickoff; a normal 60 Hz\n\t * boot does not reset, and DisplayPort/secondary kickoffs cannot claim it.\n\t */\n\tif (!is_error && sde_enc->disp_info.intf_type == DRM_MODE_CONNECTOR_DSI &&\n\t\t\tsde_enc->disp_info.is_primary && sde_enc->crtc &&\n\t\t\tsde_enc->cur_master && sde_enc->cur_master->connector &&\n\t\t\tcmpxchg(&first_primary_dsi_kickoff, true, false) &&\n\t\t\tsde_enc->crtc->mode.vrefresh != 60) {\n\t\tstruct sde_connector *conn = container_of(\n\t\t\tsde_enc->cur_master->connector, struct sde_connector, base);\n\t\tstruct drm_event event = {\n\t\t\t.type = DRM_EVENT_PANEL_DEAD,\n\t\t\t.length = sizeof(bool),\n\t\t};\n\n\t\tif (!conn->panel_dead) {\n\t\t\tconn->panel_dead = true;\n\t\t\tmsm_mode_object_event_notify(&conn->base.base,\n\t\t\t\tconn->base.dev, &event, (u8 *)&conn->panel_dead);\n\t\t}\n\t}\n\n\tif (sde_enc->disp_info.intf_type == DRM_MODE_CONNECTOR_DSI &&\n"],["\tdrm_set_preferred_mode(conn, drm_mode->hdisplay, drm_mode->vdisplay);\n","\t/* Keep an explicit 75 Hz DSI preference instead of marking all modes\n\t * with the same resolution preferred during continuous splash.\n\t */\n\tif (sde_enc->disp_info.intf_type == DRM_MODE_CONNECTOR_DSI &&\n\t    sde_enc->disp_info.is_primary) {\n\t\tstruct drm_display_mode *candidate;\n\t\tbool has_preferred_75 = false;\n\n\t\tlist_for_each_entry(candidate, &conn->probed_modes, head) {\n\t\t\tif (candidate->vrefresh == 75 &&\n\t\t\t    (candidate->type & DRM_MODE_TYPE_PREFERRED)) {\n\t\t\t\thas_preferred_75 = true;\n\t\t\t\tbreak;\n\t\t\t}\n\t\t}\n\t\tif (!has_preferred_75)\n\t\t\tdrm_set_preferred_mode(conn, drm_mode->hdisplay,\n\t\t\t\t\tdrm_mode->vdisplay);\n\t} else {\n\t\tdrm_set_preferred_mode(conn, drm_mode->hdisplay, drm_mode->vdisplay);\n\t}\n"]]}''')
marker = '/* Bool-X 75/90 Hz modes; Copyright (C) 2021 XiaoMi, Inc.; GPL-2.0. */'
evo_marker = '/* Evolution-X 72/81/90 Hz modes, commit 2c772d3fd9a042835a1f8489b91aa97b90be5b7f. */'
evo_legacy_marker = '/* Evolution-X 81/90 Hz modes, commit 2c772d3fd9a042835a1f8489b91aa97b90be5b7f. */'
evo_panels = {
    'dsi-panel-ss-fhd-ea8076-cmd.dtsi': ('dsi_ss_fhd_ea8076_cmd', '545901f796377160d8a650db47d0afdbd1615d25ccc932345888c148575025e3'),
    'dsi-panel-ss-fhd-ea8076-global-cmd.dtsi': ('dsi_ss_fhd_ea8076_global_cmd', '64cf89985b4cc7eed0799c1ee691290006c0acfb54fcaa5f89dc27e696eb85b3'),
}
miuicx_marker = '/* MIUICX R6.1 SS panel modes: 69/75 Hz. */'
miuicx_previous_marker = '/* MIUICX R6.1 SS panel modes: 69/75/81/90 Hz. */'
miuicx_rates = {1: (69, 1150000000), 2: (75, 1250000000),
                3: (81, 1350000000), 4: (90, 1500000000)}
miuicx_enabled = (1, 2)
# DRM mode equality ignores the explicit vrefresh field. The MIUICX modes
# share porch totals, so distinct transfer budgets give enabled modes distinct
# pixel clocks and prevent Android from collapsing 75 Hz into 69 Hz.
miuicx_transfers = {1: 13334, 2: 12196, 3: 11364, 4: 10205}
miuicx_switch = {
    'dsi-panel-ss-fhd-ea8076-cmd.dtsi':
        '39 00 00 00 00 00 03 F0 5A 5A 39 00 00 00 00 00 03 FC 5A 5A '
        '39 00 00 00 00 00 02 B0 23 39 00 00 00 00 00 02 D1 0F '
        '39 00 00 00 00 00 0C E9 11 55 A6 75 A3 A9 A1 4A 00 8A 18 '
        '39 00 00 00 00 00 03 F0 A5 A5 39 01 00 00 00 00 03 FC A5 A5',
    'dsi-panel-ss-fhd-ea8076-global-cmd.dtsi':
        '39 00 00 00 00 00 03 F0 5A 5A 39 00 00 00 00 00 03 FC 5A 5A '
        '39 00 00 00 00 00 02 B0 23 39 00 00 00 00 00 02 D1 11 '
        '39 00 00 00 00 00 0C E9 11 55 A6 75 A3 A9 A1 4A 00 8A 18 '
        '39 00 00 00 00 00 03 F0 A5 A5 39 01 00 00 00 00 03 FC A5 A5',
}
mode_hashes = {
    1: 'a393251def29ea7aaefb1343bf60d5b851f8bd92ea58258a86e74010dc8a9077',
    3: '406e95d47e638eb55bd092148fe1a5570ab143c0454d34f95cac4c7105ad8a63',
}
phy_hashes = {
    1: '97b7b4c39e37794d261cdaacd058f500060a7da56b90325843e33df55b46a2a6',
    3: '11ecd9150f95ed00eee7d4bd1bcde852a118513c1cb6fa06a92503b4bb4565ae',
}

def fail(message):
    sys.exit('Error: display cleanup: ' + message)

def node(text, pattern):
    matches = list(re.finditer(pattern, text, re.M))
    if len(matches) != 1:
        fail(f'expected one node matching {pattern!r}, found {len(matches)}')
    match = matches[0]
    opening = text.index('{', match.start())
    depth = 0
    for token in re.finditer(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|[{}]', text[opening:], re.S):
        value = token.group()
        if value == '{':
            depth += 1
        elif value == '}':
            depth -= 1
            if depth == 0:
                end = opening + token.end()
                while end < len(text) and text[end] in '; \t':
                    end += 1
                if end < len(text) and text[end] == '\n':
                    end += 1
                return match.start(), end, text[match.start():end]
    fail('unbalanced node braces')

def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()

def evo_mode(name, stock, index):
    # Build from the local 60 Hz node so this ROM's command sets and optional
    # FOD/AOD features are preserved. Only Evolution-X timing values change.
    command = re.search(r'qcom,mdss-dsi-on-command\s*=\s*\[(.*?)\]', stock, re.S)
    if not command:
        fail(f'{name}: missing stock panel-on commands')
    command_text = re.sub(r'/\*.*?\*/|//[^\n]*', '', command.group(1), flags=re.S)
    try:
        command_hash = hashlib.sha256(bytes.fromhex(command_text)).hexdigest()
    except ValueError:
        fail(f'{name}: invalid stock panel-on commands')
    if command_hash != evo_panels[name][1]:
        fail(f'{name}: stock panel-on commands do not match the reviewed source')
    rate, clock, transfer = {1: (72, 1320000000, 11486), 2: (81, 1485000000, 10210), 3: (90, 1650000000, 9189)}[index]
    values = {'h-front-porch': 22, 'h-back-porch': 16, 'h-pulse-width': 16,
              'v-back-porch': 16 if index == 2 and 'global' in name else 22,
              'v-front-porch': 16, 'v-pulse-width': 12 if index == 2 and 'global' in name else 16,
              'panel-framerate': rate, 'panel-clockrate': clock}
    result, count = re.subn(r'timing@0(?=\s*\{)', f'timing@{index}', stock, count=1)
    if count != 1:
        fail(f'{name}: cannot locate the stock timing node')
    for key, value in values.items():
        pattern = rf'(qcom,mdss-dsi-{key}\s*=\s*<)\d+(>;)'
        result, count = re.subn(pattern, lambda m: m[1] + str(value) + m[2], result)
        if count != 1:
            fail(f'{name}: expected one {key} setting')
    if 'qcom,mdss-mdp-transfer-time-us' in result or 'qcom,mdss-dsi-transfer-time-pclk' in result:
        fail(f'{name}: stock timing has unexpected transfer overrides')
    opening = result.index('{') + 1
    return (result[:opening] + f'\n\t\t\t\tqcom,mdss-mdp-transfer-time-us = <{transfer}>;'
            + '\n\t\t\t\tqcom,mdss-dsi-transfer-time-pclk;' + result[opening:])

def evo_phy(index):
    return (f'\t\ttiming@{index}{{\n'
            '\t\t\tqcom,mdss-dsi-panel-phy-timings = [00 24 0A 0A 26 24 0A\n'
            '\t\t\t\t0A 06 02 04 00 1E 1A];\n'
            '\t\t\tqcom,display-topology = <1 0 1>;\n'
            '\t\t\tqcom,default-topology-index = <0>;\n\t\t};\n')

def miuicx_mode(name, stock, index, with_transfer=True):
    rate, clock = miuicx_rates[index]
    command = re.search(r'qcom,mdss-dsi-on-command\s*=\s*\[(.*?)\]', stock, re.S)
    if not command:
        fail(f'{name}: missing stock panel-on commands')
    command_text = re.sub(r'/\*.*?\*/|//[^\n]*', '', command[1], flags=re.S)
    try:
        command_bytes = bytes.fromhex(command_text)
    except ValueError:
        fail(f'{name}: invalid stock panel-on commands')
    if hashlib.sha256(command_bytes).hexdigest() != evo_panels[name][1]:
        fail(f'{name}: stock panel commands do not match the reviewed MIUICX panel')
    result, count = re.subn(r'timing@0(?=\s*\{)', f'timing@{index}', stock, count=1)
    if count != 1:
        fail(f'{name}: cannot locate stock timing')
    values = {'h-front-porch': 22, 'h-back-porch': 16, 'h-pulse-width': 16,
              'v-front-porch': 16, 'v-back-porch': 22, 'v-pulse-width': 16,
              'panel-framerate': rate, 'panel-clockrate': clock}
    for key, value in values.items():
        pattern = rf'(qcom,mdss-dsi-{key}\s*=\s*<)\d+(>;)'
        result, count = re.subn(pattern, lambda m: m[1] + str(value) + m[2], result)
        if count != 1:
            fail(f'{name}: expected one {key} setting')
    command = re.search(r'(qcom,mdss-dsi-on-command\s*=\s*\[)(.*?)(\];)', result, re.S)
    old = 'E9 11 55 A6 75 A3 B9 A1 4A 00 1A B8'
    new = 'E9 11 55 A6 75 A3 A9 A1 4A 00 1A B8'
    if not command or command[2].count(old) != 1:
        fail(f'{name}: cannot safely install MIUICX high-mode panel command')
    result = result[:command.start(2)] + command[2].replace(old, new, 1) + result[command.end(2):]
    if len(bytes.fromhex(miuicx_switch[name])) != 77 or 'qcom,mdss-dsi-timing-switch-command' in result:
        fail(f'{name}: unexpected timing-switch command layout')
    end = result.rfind('\t\t\t};')
    if end < 0:
        fail(f'{name}: cannot locate timing node end')
    transfer = (f'\t\t\t\tqcom,mdss-mdp-transfer-time-us = <{miuicx_transfers[index]}>;\n'
                if with_transfer else '')
    addition = (transfer + '\t\t\t\tqcom,mdss-dsi-timing-switch-command = ['
                + miuicx_switch[name] + '];\n'
                '\t\t\t\tqcom,mdss-dsi-timing-switch-command-state = "dsi_lp_mode";\n')
    return result[:end] + addition + result[end:]

def miuicx_phy(stock, index):
    result, count = re.subn(r'timing@0(?=\s*\{)', f'timing@{index}', stock, count=1)
    if count != 1:
        fail('cannot clone stock SS PHY timing')
    return result

# Stage every change before writing; custom changes to previously installed
# mode nodes abort instead of being silently removed.
changes = {}
central_path = root / base / 'sm8150-sde-display.dtsi'
central_original = central_path.read_text()
central = central_original
for name, label in panels.items():
    path = root / base / name
    original = path.read_text()
    updated = original
    miuicx_installed = miuicx_marker in original or miuicx_previous_marker in original
    if miuicx_installed:
        installed_marker = (miuicx_previous_marker if miuicx_previous_marker in original
                            else miuicx_marker)
        installed_indices = (1, 2, 3, 4) if installed_marker == miuicx_previous_marker else miuicx_enabled
        if name not in evo_panels or original.count(installed_marker) != 1 or (miuicx_marker in original and miuicx_previous_marker in original):
            fail(f'{name}: unexpected MIUICX mode marker')
        ids = re.findall(r'^\t{3}timing@(\d+)\s*\{', updated, re.M)
        if ids not in (['0'] + [str(i) for i in installed_indices],
                       [str(i) for i in reversed(installed_indices)] + ['0']):
            fail(f'{name}: unexpected MIUICX timing nodes')
        stock = node(updated, r'^\t{3}timing@0\s*\{')[2]
        for index in installed_indices:
            left, right, content = node(updated, rf'^\t{{3}}timing@{index}\s*\{{')
            if content not in (miuicx_mode(name, stock, index),
                               miuicx_mode(name, stock, index, False)):
                fail(f'{name}: MIUICX timing@{index} has local modifications')
            updated = updated[:left] + updated[right:]
        marker_line = '\t\t\t' + installed_marker + '\n'
        preferred = '\t\tqcom,mdss-dsi-preferred-refresh-rate = <60>;\n'
        if updated.count(marker_line) != 1 or updated.count(preferred) != 1:
            fail(f'{name}: unexpected MIUICX marker or preference')
        updated = updated.replace(marker_line, '', 1).replace(preferred, '', 1)
    evo_installed = evo_marker in original or evo_legacy_marker in original
    existing_evo_marker = evo_marker if evo_marker in original else evo_legacy_marker
    evo_indices = (1, 2, 3) if existing_evo_marker == evo_marker else (2, 3)
    if evo_installed:
        if name not in evo_panels or original.count(existing_evo_marker) != 1 or (evo_marker in original and evo_legacy_marker in original):
            fail(f'{name}: unexpected Evolution-X mode marker')
        ids = re.findall(r'^\t{3}timing@(\d+)\s*\{', updated, re.M)
        if ids != ['0'] + [str(i) for i in evo_indices]:
            fail(f'{name}: unexpected Evolution-X timing nodes')
        stock = node(updated, r'^\t{3}timing@0\s*\{')[2]
        for index in evo_indices:
            left, right, content = node(updated, rf'^\t{{3}}timing@{index}\s*\{{')
            if content != evo_mode(name, stock, index):
                fail(f'{name}: Evolution-X timing@{index} has local modifications')
            updated = updated[:left] + updated[right:]
        line = '\t\t\t' + existing_evo_marker + '\n'
        if updated.count(line) != 1:
            fail(f'{name}: unexpected Evolution-X marker layout')
        updated = updated.replace(line, '', 1)
        preferred = '\t\tqcom,mdss-dsi-preferred-refresh-rate = <60>;\n'
        if updated.count(preferred) != 1:
            fail(f'{name}: unexpected Evolution-X preferred-rate setting')
        updated = updated.replace(preferred, '', 1)
    installed = marker in original
    mode_ids = re.findall(r'^\t{3}timing@(\d+)\s*\{', updated, re.M)
    if installed:
        if original.count(marker) != 1:
            fail(f'{name}: multiple installed high-refresh markers')
        if mode_ids != ['0', '1', '3']:
            fail(f'{name}: unexpected display timing nodes; preserve local changes and resolve manually')
        for index in (1, 3):
            start, end, content = node(updated, rf'^\t{{3}}timing@{index}\s*\{{')
            if digest(content) != mode_hashes[index]:
                fail(f'{name}: installed timing@{index} was modified; preserve it and resolve manually')
            updated = updated[:start] + updated[end:]
        marker_line = '\t\t\t' + marker + '\n'
        if updated.count(marker_line) != 1:
            fail(f'{name}: unexpected high-refresh marker layout')
        updated = updated.replace(marker_line, '', 1)
        preference = re.compile(r'^\t\tqcom,mdss-dsi-preferred-refresh-rate = <(?:60|75)>;\n', re.M)
        if 'qcom,mdss-dsi-preferred-refresh-rate' in updated:
            updated, count = preference.subn('', updated)
            if count != 1 or 'qcom,mdss-dsi-preferred-refresh-rate' in updated:
                fail(f'{name}: custom preferred-refresh property; preserve it and resolve manually')
    elif mode_ids != ['0']:
        fail(f'{name}: unrecognized display timing nodes; preserve local changes and resolve manually')
    changes[path] = (original, updated)

    start, end, parent = node(central, rf'^&{label}\s*\{{')
    if miuicx_installed:
        ids = re.findall(r'^\t{2}timing@(\d+)\s*\{', parent, re.M)
        if ids not in (['0'] + [str(i) for i in installed_indices],
                       [str(i) for i in reversed(installed_indices)] + ['0']):
            fail(f'{label}: unexpected MIUICX PHY timing nodes')
        stock_phy = node(parent, r'^\t{2}timing@0\s*\{')[2]
        for index in installed_indices:
            left, right, content = node(parent, rf'^\t{{2}}timing@{index}\s*\{{')
            if content != miuicx_phy(stock_phy, index):
                fail(f'{label}: MIUICX PHY timing@{index} has local modifications')
            parent = parent[:left] + parent[right:]
    if evo_installed:
        ids = re.findall(r'^\t{2}timing@(\d+)\s*\{', parent, re.M)
        if ids != ['0'] + [str(i) for i in evo_indices]:
            fail(f'{label}: unexpected Evolution-X PHY timing nodes')
        for index in evo_indices:
            left, right, content = node(parent, rf'^\t{{2}}timing@{index}\s*\{{')
            if content != evo_phy(index):
                fail(f'{label}: Evolution-X PHY timing@{index} has local modifications')
            parent = parent[:left] + parent[right:]
    parent_ids = re.findall(r'^\t{2}timing@(\d+)\s*\{', parent, re.M)
    if any(index not in ('0', '1', '3') for index in parent_ids):
        fail(f'{label}: unrecognized PHY timing nodes; preserve local changes and resolve manually')
    if not installed and parent_ids != ['0']:
        fail(f'{label}: PHY timing nodes lack the installed high-refresh marker; preserve local changes and resolve manually')
    for index in (1, 3):
        pattern = rf'^\t{{2}}timing@{index}\s*\{{'
        if not re.search(pattern, parent, re.M):
            continue
        left, right, content = node(parent, pattern)
        if digest(content) != phy_hashes[index]:
            fail(f'{label}: installed PHY timing@{index} was modified; preserve it and resolve manually')
        parent = parent[:left] + parent[right:]
    central = central[:start] + parent + central[end:]
changes[central_path] = (central_original, central)

# The high-refresh port rewrote a continuous-splash preference block in two
# successive versions. Reverse either exact reviewed variant before the rest.
encoder_rules = driver_edits['drivers/gpu/drm/msm/sde/sde_encoder.c']
legacy = next((new for old, new in encoder_rules if 'has_preferred_75' in new), None)
if legacy is None:
    fail('missing embedded splash migration rule')
general = (legacy.replace('an explicit 75 Hz DSI preference', 'the DSI preferred mode')
    .replace('has_preferred_75', 'has_preferred_mode')
    .replace('candidate->vrefresh == 75 &&',
             'candidate->hdisplay == drm_mode->hdisplay &&\n'
             '\t\t\t    candidate->vdisplay == drm_mode->vdisplay &&'))
if general == legacy or 'candidate->vrefresh == 75' in general:
    fail('unexpected embedded splash migration rule')

for name, replacements in driver_edits.items():
    path = root / name
    # The MIUICX port does not edit this binding. Some branch 17 trees use a
    # different copy, so leave their documentation untouched.
    if name == 'Documentation/devicetree/bindings/drm/msm/mdss-dsi-panel.txt':
        continue
    original = path.read_text()
    updated = original
    if name == 'drivers/gpu/drm/msm/sde/sde_encoder.c':
        if general in updated:
            if updated.count(general) != 1:
                fail(f'{name}: multiple splash preference blocks')
            updated = updated.replace(general, legacy, 1)
    # Reverse in the opposite order: a few original edits overlapped.
    for old, new in reversed(replacements):
        if updated.count(new) == 1:
            updated = updated.replace(new, old, 1)
        elif updated.count(new) > 1:
            fail(f'{name}: multiple copies of a high-refresh edit')
        elif old not in updated:
            fail(f'{name}: cannot safely reverse high-refresh edit; preserve local changes and resolve manually')
    # Keep the independent bool-return correctness fix for failed mode lookups.
    if name == 'drivers/gpu/drm/msm/dsi-staging/dsi_drm.c':
        before = ('\trc = dsi_display_find_mode(display, &dsi_mode, &panel_dsi_mode);\n'
                  '\tif (rc)\n\t\treturn rc;\n')
        after = ('\trc = dsi_display_find_mode(display, &dsi_mode, &panel_dsi_mode);\n'
                 '\tif (rc)\n\t\treturn false;\n')
        if updated.count(before) == 1:
            updated = updated.replace(before, after, 1)
        elif updated.count(after) != 1:
            fail(f'{name}: unexpected mode-lookup error handling')
    changes[path] = (original, updated)

# Apply the MIUICX R6.1 SS panel modes while retaining the ROM's 60 Hz node.
# Six other ROM variants are deliberately left at their stock timings.
central_original, central = changes[central_path]
for name, (label, _) in (evo_panels.items() if high_refresh else ()):
    path = root / base / name
    original, updated = changes[path]
    if 'qcom,mdss-dsi-panel-type = "dsi_cmd_mode";' not in updated or 'qcom,mdss-dsi-bpp = <24>;' not in updated:
        fail(f'{name}: expected a 24-bit command-mode panel')
    if any(f'qcom,mdss-dsi-lane-{i}-state;' not in updated for i in range(4)):
        fail(f'{name}: expected four DSI lanes')
    panel_type = '\t\tqcom,mdss-dsi-panel-type = "dsi_cmd_mode";\n'
    if updated.count(panel_type) != 1 or 'qcom,mdss-dsi-preferred-refresh-rate' in updated:
        fail(f'{name}: unexpected existing preferred refresh rate')
    updated = updated.replace(panel_type, panel_type + '\t\tqcom,mdss-dsi-preferred-refresh-rate = <60>;\n', 1)
    stock_start, stock_end, stock = node(updated, r'^\t{3}timing@0\s*\{')
    # Overlay application prepends children, so emit high modes before the
    # stock node in reverse order to make merged timing index zero 60 Hz.
    addition = ('\t\t\t' + miuicx_marker + '\n'
                + ''.join(miuicx_mode(name, stock, i) for i in reversed(miuicx_enabled)))
    updated = updated[:stock_start] + addition + stock + updated[stock_end:]
    changes[path] = (original, updated)
    start, end, parent = node(central, rf'^&{label}\s*\{{')
    phy_start, phy_end, stock_phy = node(parent, r'^\t{2}timing@0\s*\{')
    parent = (parent[:phy_start]
              + ''.join(miuicx_phy(stock_phy, i) for i in reversed(miuicx_enabled))
              + stock_phy + parent[phy_end:])
    central = central[:start] + parent + central[end:]
changes[central_path] = (central_original, central)

# Gate DMS on panel support and retain the preferred 60 Hz splash mode.
for name, rule_index, new_override in ((
    ('drivers/gpu/drm/msm/dsi-staging/dsi_drm.c', 0, None),
    ('drivers/gpu/drm/msm/sde/sde_encoder.c', 2, general),
) if high_refresh else ()):
    path = root / name
    original, updated = changes[path]
    old, new = driver_edits[name][rule_index]
    if new_override is not None:
        new = new_override
    if new not in updated:
        if updated.count(old) != 1:
            fail(f'{name}: cannot apply reviewed MIUICX driver compatibility edit')
        updated = updated.replace(old, new, 1)
    changes[path] = (original, updated)

# libfdt prepends newly overlaid timing nodes. The ROM DTBO emits the new
# children in reverse order so the merged tree starts at the stock 60 Hz mode.
# Keep the DRM preference at 60 Hz under other overlay implementations too.
display_path = root / 'drivers/gpu/drm/msm/dsi-staging/dsi_display.c'
display_original = display_path.read_text()
display_updated = display_original
mode_order_old = ('\t\t_dsi_display_populate_bit_clks(display, start, end, &array_idx);\n'
                  '\t}\n\nexit:\n\t*out_modes = display->modes;\n')
mode_order_new = '''\t\t_dsi_display_populate_bit_clks(display, start, end, &array_idx);
\t}

\t/* The MIUICX Raphael DTBO overlay prepends timing@2 and @1.
\t * Sort only its exact 60/69/75 Hz mode set, so index zero remains
\t * the stock 60 Hz mode regardless of the overlay implementation.
\t */
\t{
\t\tconst u32 rates[] = { 60, 69, 75 };
\t\tstruct dsi_display_mode temp;
\t\tu32 preferred_rate;
\t\tu32 j;

\t\tif (!display->panel->utils.read_u32(display->panel->utils.data,
\t\t\t\t"qcom,mdss-dsi-preferred-refresh-rate",
\t\t\t\t&preferred_rate) && preferred_rate == 60) {
\t\t\tif (array_idx != ARRAY_SIZE(rates)) {
\t\t\t\trc = -EINVAL;
\t\t\t\tgoto error;
\t\t\t}
\t\t\tfor (i = 0; i < (int)ARRAY_SIZE(rates); i++) {
\t\t\t\tfor (j = i; j < ARRAY_SIZE(rates); j++)
\t\t\t\t\tif (display->modes[j].timing.refresh_rate ==
\t\t\t\t\t\t\trates[i])
\t\t\t\t\t\tbreak;
\t\t\t\tif (j == ARRAY_SIZE(rates)) {
\t\t\t\t\trc = -EINVAL;
\t\t\t\t\tgoto error;
\t\t\t\t}
\t\t\t\ttemp = display->modes[i];
\t\t\t\tdisplay->modes[i] = display->modes[j];
\t\t\t\tdisplay->modes[j] = temp;
\t\t\t}
\t\t}
\t}

exit:
\t*out_modes = display->modes;
'''
mode_order_previous = (mode_order_new
    .replace('The MIUICX Raphael DTBO overlay prepends timing@2 and @1.',
             'The MIUICX Raphael DTBO overlay prepends timing@4 through @1.')
    .replace('60/69/75 Hz mode set', '60/69/75/81/90 Hz mode set')
    .replace('{ 60, 69, 75 }', '{ 60, 69, 75, 81, 90 }'))
mode_order_legacy = (mode_order_previous
    .replace('The MIUICX Raphael DTBO overlay prepends timing@4 through @1.',
             'The reviewed Raphael DTBO overlay prepends timing@3, @2 and @1.')
    .replace('60/69/75/81/90 Hz mode set', '60/72/81/90 Hz mode set')
    .replace('{ 60, 69, 75, 81, 90 }', '{ 60, 72, 81, 90 }'))
for installed_order in (mode_order_new, mode_order_previous, mode_order_legacy):
    if display_updated.count(installed_order) == 1:
        display_updated = display_updated.replace(installed_order, mode_order_old, 1)
    elif display_updated.count(installed_order) > 1:
        fail('multiple installed display mode order blocks')
if display_updated.count(mode_order_old) != 1:
    fail('cannot safely locate display mode order code')
if high_refresh:
    if display_updated.count(mode_order_old) != 1:
        fail('cannot safely install display mode ordering fix')
    display_updated = display_updated.replace(mode_order_old, mode_order_new, 1)
# An unsuccessful parse must not leave a freed mode cache for the next probe.
cache_error_old = '\nerror:\n\tif (rc)\n\t\tkfree(display->modes);\n\n\tmutex_unlock(&display->display_lock);\n'
cache_error_new = '\nerror:\n\tif (rc) {\n\t\tkfree(display->modes);\n\t\tdisplay->modes = NULL;\n\t}\n\n\tmutex_unlock(&display->display_lock);\n'
if display_updated.count(cache_error_old) == 1:
    display_updated = display_updated.replace(cache_error_old, cache_error_new, 1)
elif display_updated.count(cache_error_new) != 1:
    fail('cannot safely fix the display mode cache error path')
changes[display_path] = (display_original, display_updated)

for path, (original, updated) in changes.items():
    if original != updated:
        path.write_text(updated)
output.mkdir(parents=True, exist_ok=True)
report = output / 'display-modes.txt'
if high_refresh:
    report.write_text('MIUICX R6.1 SS EA8076 restricted port: '
                      '60, 69 and 75 Hz; original 60 Hz preferred.\n'
                      'Experimental: full modesets and physical display behavior require testing.\n'
                      'Rebuild the kernel and device tree before packaging.\n')
    print('Raphael display: MIUICX 60/69/75 Hz prepared for SS EA8076 panels.')
else:
    report.write_text('Raphael display setup: stock panel timings; experimental high-refresh modes disabled.\n'
                      'Rebuild the kernel and device tree before packaging.\n')
    print('Raphael display: stock 60 Hz timings; experimental high-refresh modes disabled.')
print(f'Display source report: {report}')
PYDISPLAY
}

setup_raphael_display

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
    "drivers/input/input.c": [
        [
            "#define pr_fmt(fmt) KBUILD_BASENAME \": \" fmt\n\n#include <linux/init.h>\n#include <linux/types.h>\n#include <linux/idr.h>\n#include <linux/input/mt.h>\n",
            "#define pr_fmt(fmt) KBUILD_BASENAME \": \" fmt\n\n#include <linux/init.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/types.h>\n#include <linux/idr.h>\n#include <linux/input/mt.h>\n"
        ],
        [
            "static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n\tint disposition = input_get_disposition(dev, type, code, &value);\n\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n\t\tadd_input_randomness(type, code, value);\n\n",
            "static void input_handle_event(struct input_dev *dev,\n\t\t\t       unsigned int type, unsigned int code, int value)\n{\n\tint disposition;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(&type, &code, &value);\n#endif\n\tdisposition = input_get_disposition(dev, type, code, &value);\n\tif (disposition != INPUT_IGNORE_EVENT && type != EV_SYN)\n\t\tadd_input_randomness(type, code, value);\n\n"
        ]
    ],
    "fs/exec.c": [
        [
            " */\n\n#include <linux/slab.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n#include <linux/mm.h>\n",
            " */\n\n#include <linux/slab.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n#include <linux/mm.h>\n"
        ],
        [
            "\tstruct files_struct *displaced;\n\tint retval;\n\n\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n",
            "\tstruct files_struct *displaced;\n\tint retval;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\t/* execve_file() may provide a file without a filename. */\n\tif (filename && !IS_ERR(filename))\n\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n#endif\n\tif (IS_ERR(filename))\n\t\treturn PTR_ERR(filename);\n\n"
        ]
    ],
    "fs/open.c": [
        [
            " */\n\n#include <linux/string.h>\n#include <linux/mm.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n",
            " */\n\n#include <linux/string.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/mm.h>\n#include <linux/file.h>\n#include <linux/fdtable.h>\n"
        ],
        [
            "\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */\n\t\treturn -EINVAL;\n\n",
            "\tint res;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_su_compat_enabled))\n\t\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif\n\tif (mode & ~S_IRWXO)\t/* where's F_OK, X_OK, W_OK, R_OK? */\n\t\treturn -EINVAL;\n\n"
        ]
    ],
    "fs/stat.c": [
        [
            " *  Copyright (C) 1991, 1992  Linus Torvalds\n */\n\n#include <linux/export.h>\n#include <linux/mm.h>\n#include <linux/errno.h>\n#include <linux/file.h>\n#include <linux/highuid.h>\n",
            " *  Copyright (C) 1991, 1992  Linus Torvalds\n */\n\n#include <linux/export.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/mm.h>\n#include <linux/errno.h>\n#include <linux/file.h>\n#include <linux/highuid.h>\n"
        ],
        [
            "\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |\n\t\t       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)\n\t\treturn -EINVAL;\n\n",
            "\tstruct path path;\n\tint error = -EINVAL;\n\tunsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_su_compat_enabled))\n\t\tksu_handle_stat(&dfd, &filename, &flags);\n#endif\n\tif ((flags & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |\n\t\t       AT_EMPTY_PATH | KSTAT_QUERY_FLAGS)) != 0)\n\t\treturn -EINVAL;\n\n"
        ],
        [
            "\n\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat, int, dfd, const char __user *, pathname,\n",
            "\n\tif (!error)\n\t\terror = cp_new_stat(&stat, statbuf);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (!error && unlikely(ksu_init_rc_hook))\n\t\tksu_handle_newfstat_ret(&fd, &statbuf);\n#endif\n\treturn error;\n}\n\nSYSCALL_DEFINE4(readlinkat, int, dfd, const char __user *, pathname,\n"
        ],
        [
            "\n\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n",
            "\n\tif (!error)\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (!error && unlikely(ksu_init_rc_hook))\n\t\tksu_handle_fstat64_ret(&fd, &statbuf);\n#endif\n\treturn error;\n}\n\nSYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,\n"
        ]
    ],
    "fs/read_write.c": [
        [
            " */\n\n#include <linux/slab.h>\n#include <linux/stat.h>\n#include <linux/sched/xacct.h>\n#include <linux/fcntl.h>\n",
            " */\n\n#include <linux/slab.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/stat.h>\n#include <linux/sched/xacct.h>\n#include <linux/fcntl.h>\n"
        ],
        [
            "\nSYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f = fdget_pos(fd);\n\tssize_t ret = -EBADF;\n\n\tif (f.file) {\n\t\tloff_t pos = file_pos_read(f.file);\n\t\tret = vfs_read(f.file, buf, count, &pos);\n",
            "\nSYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)\n{\n\tstruct fd f;\n\tssize_t ret = -EBADF;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tif (unlikely(ksu_init_rc_hook))\n\t\tksu_handle_sys_read(fd);\n#endif\n\tf = fdget_pos(fd);\n\tif (f.file) {\n\t\tloff_t pos = file_pos_read(f.file);\n\t\tret = vfs_read(f.file, buf, count, &pos);\n"
        ]
    ],
    "kernel/reboot.c": [
        [
            "#define pr_fmt(fmt)\t\"reboot: \" fmt\n\n#include <linux/ctype.h>\n#include <linux/export.h>\n#include <linux/kexec.h>\n#include <linux/kmod.h>\n",
            "#define pr_fmt(fmt)\t\"reboot: \" fmt\n\n#include <linux/ctype.h>\n#include <linux/ksu_manual_hooks.h>\n#include <linux/export.h>\n#include <linux/kexec.h>\n#include <linux/kmod.h>\n"
        ],
        [
            "\tchar buffer[256];\n\tint ret = 0;\n\n\t/* We only trust the superuser with rebooting the system. */\n\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))\n\t\treturn -EPERM;\n",
            "\tchar buffer[256];\n\tint ret = 0;\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\t/* We only trust the superuser with rebooting the system. */\n\tif (!ns_capable(pid_ns->user_ns, CAP_SYS_BOOT))\n\t\treturn -EPERM;\n"
        ]
    ],
    "fs/namespace.c": [
        [
            "\n#endif\n\nstatic bool is_mnt_ns_file(struct dentry *dentry)\n{\n\t/* Is this a proxy for a mount namespace? */\n",
            "\n#endif\n\nstatic int can_umount(const struct path *path, int flags)\n {\n\t struct mount *mnt = real_mount(path->mnt);\n\t if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))\n\t\t return -EINVAL;\n\t if (!may_mount())\n\t\t return -EPERM;\n\t if (path->dentry != path->mnt->mnt_root)\n\t\t return -EINVAL;\n\t if (!check_mnt(mnt))\n\t\t return -EINVAL;\n\t if (mnt->mnt.mnt_flags & MNT_LOCKED)\n\t\t return -EINVAL;\n\t if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))\n\t\t return -EPERM;\n\t return 0;\n }\n\nint path_umount(struct path *path, int flags)\n {\n\t struct mount *mnt = real_mount(path->mnt);\n\t int ret;\n\t ret = can_umount(path, flags);\n\t if (!ret)\n\t\t ret = do_umount(mnt, flags);\n\t dput(path->dentry);\n\t mntput_no_expire(mnt);\n\t return ret;\n }\n\nstatic bool is_mnt_ns_file(struct dentry *dentry)\n{\n\t/* Is this a proxy for a mount namespace? */\n"
        ]
    ],
    "fs/internal.h": [
        [
            "extern int sb_prepare_remount_readonly(struct super_block *);\n\nextern void __init mnt_init(void);\n\nextern int __mnt_want_write(struct vfsmount *);\nextern int __mnt_want_write_file(struct file *);\n",
            "extern int sb_prepare_remount_readonly(struct super_block *);\n\nextern void __init mnt_init(void);\nint path_umount(struct path *path, int flags);\n\nextern int __mnt_want_write(struct vfsmount *);\nextern int __mnt_want_write_file(struct file *);\n"
        ]
    ],
    "include/linux/seccomp.h": [
        [
            "#ifdef CONFIG_SECCOMP\n\n#include <linux/thread_info.h>\n#include <asm/seccomp.h>\n\nstruct seccomp_filter;\n",
            "#ifdef CONFIG_SECCOMP\n\n#include <linux/thread_info.h>\n#include <linux/atomic.h>\n#include <asm/seccomp.h>\n\nstruct seccomp_filter;\n"
        ],
        [
            " */\nstruct seccomp {\n\tint mode;\n\tstruct seccomp_filter *filter;\n};\n\n",
            " */\nstruct seccomp {\n\tint mode;\n\tatomic_t filter_count;\n\tstruct seccomp_filter *filter;\n};\n\n"
        ]
    ],
    "KernelSU-Next/kernel/Kbuild": [
        [
            "# If there is no .git directory, use default version\n$(warning \"KSU_GIT_VERSION not defined! It is better to make KernelSU-Next a git repository!\")\nKSU_VERSION_FALLBACK := 1\n$(info -- KernelSU-Next version fallback: $(KSU_VERSION_FALLBACK))\nKSU_VERSION := $(KSU_VERSION_FALLBACK)\n",
            "# An archive can supply an explicit version without Git metadata.\nifndef KSU_VERSION_OVERRIDE\n$(warning \"KSU_GIT_VERSION not defined! It is better to make KernelSU-Next a git repository!\")\nKSU_VERSION_FALLBACK := 1\n$(info -- KernelSU-Next version fallback: $(KSU_VERSION_FALLBACK))\nKSU_VERSION := $(KSU_VERSION_FALLBACK)\nendif\n"
        ],
        [
            "$(warning \"KSU_VERSION_TAG not defined! It is better to make KernelSU-Next a git submodule!\")\nKSU_VERSION_TAG_FALLBACK := v0.0.1\nKSU_VERSION_TAG=$(KSU_VERSION_TAG_FALLBACK)\n",
            "ifndef KSU_VERSION_TAG_OVERRIDE\n$(warning \"KSU_VERSION_TAG not defined! It is better to make KernelSU-Next a git submodule!\")\nKSU_VERSION_TAG_FALLBACK := v0.0.1\nKSU_VERSION_TAG=$(KSU_VERSION_TAG_FALLBACK)\nendif\n"
        ],
        [
            "ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR\nendif\n\n# Handle optional backports\nifeq ($(shell grep -q \"strncpy_from_user_nofault\" $(srctree)/include/linux/uaccess.h; echo $$?),0)\nccflags-y += -DKSU_OPTIONAL_STRNCPY\n",
            "ccflags-y += -DKSU_COMPAT_HAS_BACKPORTED_CPUS_PTR\nendif\n\n# Detect Android/vendor kernels that backported __poll_t before 4.16.\nifeq ($(shell grep -Eq \"typedef.*__poll_t\" $(srctree)/include/uapi/linux/types.h $(srctree)/include/linux/types.h; echo $$?),0)\nccflags-y += -DKSU_HAS_POLL_T\nendif\n\n# Handle optional backports\nifeq ($(shell grep -q \"strncpy_from_user_nofault\" $(srctree)/include/linux/uaccess.h; echo $$?),0)\nccflags-y += -DKSU_OPTIONAL_STRNCPY\n"
        ]
    ],
    "KernelSU-Next/kernel/infra/event_queue.h": [
        [
            "#include <linux/wait.h>\n\n#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 16, 0)\ntypedef unsigned int __poll_t;\n#endif\n\n",
            "#include <linux/wait.h>\n\n#include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 16, 0) && !defined(KSU_HAS_POLL_T)\ntypedef unsigned int __poll_t;\n#endif\n\n"
        ]
    ],
    "KernelSU-Next/kernel/feature/sucompat.c": [
        [
            "\tconst char su[] = SU_PATH;\n\tstatic const char ksud_path[] = KSUD_PATH;\n\tstruct ksu_sulog_pending_event *pending_root = NULL;\n\tconst char *const *sucompat_argv = (const char *const *)__never_use_argv;\n\n\tif (unlikely(!filename_ptr))\n\t\treturn 0;\n",
            "\tconst char su[] = SU_PATH;\n\tstatic const char ksud_path[] = KSUD_PATH;\n\tstruct ksu_sulog_pending_event *pending_root = NULL;\n\n\tif (unlikely(!filename_ptr))\n\t\treturn 0;\n"
        ],
        [
            "\n\tpr_info(\"do_execveat_common su found\\n\");\n\n\tpending_root = ksu_sulog_capture_root_execve_kern(filename->name, sucompat_argv, GFP_KERNEL);\n\n\tmemcpy((void *)filename->name, ksud_path, sizeof(ksud_path));\n\n",
            "\n\tpr_info(\"do_execveat_common su found\\n\");\n\n\t/* argv is a struct user_arg_ptr, not an array of kernel strings. */\n\tpending_root = ksu_sulog_capture_root_execve_kern(filename->name, NULL, GFP_KERNEL);\n\n\tmemcpy((void *)filename->name, ksud_path, sizeof(ksud_path));\n\n"
        ]
    ],
    "include/linux/ksu_manual_hooks.h": [
        [
            "",
            "/* SPDX-License-Identifier: GPL-2.0 */\n#ifndef _LINUX_KSU_MANUAL_HOOKS_H\n#define _LINUX_KSU_MANUAL_HOOKS_H\n\n#ifdef CONFIG_KSU_MANUAL_HOOK\n#include <linux/compiler.h>\n#include <linux/types.h>\n\nstruct filename;\nstruct stat;\nstruct stat64;\nextern bool ksu_su_compat_enabled;\nextern bool ksu_init_rc_hook;\nextern bool ksu_input_hook;\n\nint ksu_handle_execveat(int *fd, struct filename **filename, void *argv,\n\t\t       void *envp, int *flags);\nint ksu_handle_faccessat(int *dfd, const char __user **filename, int *mode,\n\t\t       int *flags);\nint ksu_handle_stat(int *dfd, const char __user **filename, int *flags);\nvoid ksu_handle_sys_read(unsigned int fd);\nvoid ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf);\nvoid ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf);\nint ksu_handle_input_handle_event(unsigned int *type, unsigned int *code,\n\t\t\t\t int *value);\nint ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\n\t\t\t void __user **arg);\n#endif\n\n#endif /* _LINUX_KSU_MANUAL_HOOKS_H */\n"
        ]
    ],
    "KernelSU-Next/kernel/supercall/dispatch.c": [
        [
            "static int do_get_app_profile(void __user *arg)\n{\n#ifdef CONFIG_KSU_DISABLE_POLICY\n    return -EOPNOTSUPP;\n#endif\n    uid_t uid;\n    struct app_profile *profile;\n    int ret = 0;\n\n    if (copy_from_user(&uid, (char __user *)arg + offsetof(struct ksu_get_app_profile_cmd, profile.curr_uid),\n                       sizeof(uid_t))) {\n        pr_err(\"get_app_profile: copy_from_user failed\\n\");\n        return -EFAULT;\n    }\n\n    rcu_read_lock();\n    profile = ksu_get_app_profile(uid);\n    rcu_read_unlock();\n    if (!profile) {\n        ret = -ENOENT;\n    } else {\n        if (copy_to_user((char __user *)arg + offsetof(struct ksu_get_app_profile_cmd, profile), profile,\n                         sizeof(struct app_profile))) {\n            pr_err(\"get_app_profile: copy_to_user failed\\n\");\n            ret = -EFAULT;\n        }\n        ksu_put_app_profile(profile);\n    }\n    return ret;\n}\n\nstatic int do_set_app_profile(void __user *arg)\n{\n#ifdef CONFIG_KSU_DISABLE_POLICY\n    return -EOPNOTSUPP;\n#endif\n\n    struct ksu_set_app_profile_cmd cmd;\n    int ret;\n\n\tif (copy_from_user(&cmd, arg, sizeof(cmd))) {\n\t\tpr_err(\"set_app_profile: copy_from_user failed\\n\");\n\t\treturn -EFAULT;\n\t}\n\n    ret = ksu_set_app_profile(&cmd.profile);\n    if (!ret) {\n        ksu_persistent_allow_list();\n#ifdef KSU_KPROBES_HOOK\n        ksu_mark_running_process();\n#endif\n    }\n    return ret;\n}\n\n",
            "/* Manager v3.2 uses profile format 3, the same ABI prefix without flags.\n * Do not copy a v4-sized object to or from that smaller userspace buffer.\n */\n#define KSU_APP_PROFILE_V3_SIZE offsetof(struct app_profile, rp_config.profile.flags)\n\nstatic int do_get_app_profile(void __user *arg)\n{\n#ifdef CONFIG_KSU_DISABLE_POLICY\n    return -EOPNOTSUPP;\n#endif\n    uid_t uid;\n    __u32 requested_version;\n    struct app_profile *profile;\n    int ret = 0;\n\n    if (copy_from_user(&requested_version, (char __user *)arg +\n                       offsetof(struct ksu_get_app_profile_cmd, profile.version),\n                       sizeof(requested_version)) ||\n        copy_from_user(&uid, (char __user *)arg +\n                       offsetof(struct ksu_get_app_profile_cmd, profile.curr_uid),\n                       sizeof(uid))) {\n        pr_err(\"get_app_profile: copy_from_user failed\\n\");\n        return -EFAULT;\n    }\n\n    rcu_read_lock();\n    profile = ksu_get_app_profile(uid);\n    rcu_read_unlock();\n    if (!profile) {\n        ret = -ENOENT;\n    } else {\n        if (requested_version == 3) {\n            struct app_profile legacy = *profile;\n\n            legacy.version = 3;\n            if (copy_to_user((char __user *)arg +\n                             offsetof(struct ksu_get_app_profile_cmd, profile),\n                             &legacy, KSU_APP_PROFILE_V3_SIZE))\n                ret = -EFAULT;\n        } else if (copy_to_user((char __user *)arg +\n                                offsetof(struct ksu_get_app_profile_cmd, profile),\n                                profile, sizeof(struct app_profile))) {\n            ret = -EFAULT;\n        }\n        if (ret)\n            pr_err(\"get_app_profile: copy_to_user failed\\n\");\n        ksu_put_app_profile(profile);\n    }\n    return ret;\n}\n\nstatic int do_set_app_profile(void __user *arg)\n{\n#ifdef CONFIG_KSU_DISABLE_POLICY\n    return -EOPNOTSUPP;\n#endif\n    struct ksu_set_app_profile_cmd cmd = {};\n    __u32 requested_version;\n    size_t copy_size;\n    int ret;\n\n    if (copy_from_user(&requested_version, (char __user *)arg +\n                       offsetof(struct ksu_set_app_profile_cmd, profile.version),\n                       sizeof(requested_version))) {\n        pr_err(\"set_app_profile: copy_from_user version failed\\n\");\n        return -EFAULT;\n    }\n    copy_size = requested_version == 3 ? KSU_APP_PROFILE_V3_SIZE : sizeof(cmd);\n    if (copy_from_user(&cmd, arg, copy_size)) {\n        pr_err(\"set_app_profile: copy_from_user failed\\n\");\n        return -EFAULT;\n    }\n    if (cmd.profile.version != requested_version)\n        return -EINVAL;\n    if (requested_version == 3) {\n        cmd.profile.version = KSU_APP_PROFILE_VER;\n        /* Match the kernel's existing v3 on-disk migration semantics. */\n        if (cmd.profile.allow_su)\n            cmd.profile.rp_config.profile.flags = FLAG_KSU_NO_NEW_PRIVS;\n    }\n\n    ret = ksu_set_app_profile(&cmd.profile);\n    if (!ret) {\n        ksu_persistent_allow_list();\n#ifdef KSU_KPROBES_HOOK\n        ksu_mark_running_process();\n#endif\n    }\n    return ret;\n}\n\n"
        ]
    ]
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
    'ksu': set(('KSU KSU_MANUAL_HOOK KSU_DEBUG KSU_DISABLE_POLICY KSU_DISABLE_MANAGER KSU_KPROBES_HOOK '
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
        -d KSU_KPROBES_HOOK -d KSU_SYSCALL_TABLE_HOOK -d KSU_DEBUG \
        -d KSU_DISABLE_POLICY -d KSU_DISABLE_MANAGER -d STATIC_USERMODEHELPER
else
    "$ROOT/scripts/config" --file "$OUT_DIR/.config" -d KSU -d KSU_MANUAL_HOOK
fi
if (( WITH_NETHUNTER )); then
    apply_nethunter_config "$OUT_DIR/.config"
else
    rm -f -- "$OUT_DIR/nethunter-config.txt"
fi
if (( WITH_KSU && WITH_NETHUNTER )); then
    localversion='-G0N-Nethunter-KSU-🇵🇭'
elif (( WITH_KSU )); then
    localversion='-G0N-KSU-🇵🇭'
else
    localversion='-G0N-🇵🇭'
fi
"$ROOT/scripts/config" --file "$OUT_DIR/.config" --set-str LOCALVERSION "$localversion"
make "${args[@]}" olddefconfig
grep -Fxq "CONFIG_LOCALVERSION=\"$localversion\"" "$OUT_DIR/.config" ||
    die 'CONFIG_LOCALVERSION could not be set.'
if (( WITH_NETHUNTER )); then
    verify_nethunter_config
fi
grep -qx 'CONFIG_RTL8822BU=y' "$OUT_DIR/.config" ||
    die 'RTL8822BU could not be enabled; check USB and cfg80211 configuration.'
if (( WITH_KSU )); then
    for option in KSU KSU_MANUAL_HOOK KPROBES KRETPROBES KPROBE_EVENTS; do
        grep -qx "CONFIG_${option}=y" "$OUT_DIR/.config" || die "$option could not be enabled."
    done
    for option in KSU_DISABLE_POLICY KSU_DISABLE_MANAGER; do
        if grep -Eq "^CONFIG_${option}=(y|m)$" "$OUT_DIR/.config"; then
            die "$option must be disabled for Manager app profiles to work."
        fi
    done
    # Required for the embedded KernelSU-Next pre-init runner.
    make "${args[@]}" headers_install
    # KernelSU includes generated SELinux headers even for a standalone target.
    # Build the SELinux directory first so its Kbuild rule generates them.
    make "${args[@]}" security/selinux/
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
if [[ -n ${STOCK_DTBO_IMG:-} ]]; then
    pack_dtbo_image
else
    printf '\nDisplay device tree: %s/arch/arm64/boot/dts/qcom/raphael-sm8150-overlay.dtbo\n' "$OUT_DIR"
    if [[ -e $OUT_DIR/dtbo.img ]]; then
        printf 'Warning: existing %s/dtbo.img was not regenerated and may contain old display changes.\n' "$OUT_DIR"
    fi
    printf 'To copy the original stock DTBO, set STOCK_DTBO_IMG and run ./build.sh --dtbo-only.\n'
    printf 'The MIUICX high-refresh port is experimental and has not been tested on this ROM.\n'
fi
