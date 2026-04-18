#!/usr/bin/env bash
# build/host_flash.sh
# ============================================================
# hands-on-metal — Host-Assisted Flash (Mode C)
#
# Flashes a TARGET device from the system running this script
# (the HOST). The host can be a PC (Linux/macOS/Windows) or
# another Android device (Termux via USB OTG or wireless ADB).
#
# Terminology:
#   HOST   = the machine running this script
#   TARGET = the device being flashed (connected via USB/OTG/wireless)
#
# Supports three sub-paths:
#   C1 — Temporary TWRP boot:  fastboot boot twrp.img
#   C2 — Direct fastboot flash of a pre-patched boot image
#   C3 — ADB sideload (requires recovery on target device)
#
# Prerequisites (checked automatically):
#   - adb and fastboot commands available on HOST
#   - TARGET device connected and detected via ADB or fastboot
#   - Unlocked bootloader on TARGET (for C1 and C2)
#
# Usage:
#   bash build/host_flash.sh                          # interactive menu
#   bash build/host_flash.sh --c1 TWRP                # boot TWRP image
#   bash build/host_flash.sh --c2 IMG                 # flash pre-patched image
#   bash build/host_flash.sh --c3 ZIP                 # sideload recovery ZIP
#   bash build/host_flash.sh -s SERIAL --c2 IMG       # target specific device
#
# Options:
#   -s SERIAL    Target a specific device by serial number.
#                Required when multiple devices are connected.
#                Use 'adb devices' or 'fastboot devices' to list serials.
#
# This script follows the same conventions as the terminal menu:
#   - Prerequisite checking via check_deps.sh IDs
#   - Color-coded output (host ℹ green, target ▸ cyan)
#   - Completion and next-step messages
#   - Non-destructive by default (confirms before flashing)
# ============================================================

set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/build/dist"

# ── Host OS detection ─────────────────────────────────────────
# Detect the host platform so commands, paths, and instructions
# are tailored to the system this script is running on.

_detect_host_os() {
    local os_name
    os_name="$(uname -s 2>/dev/null || echo unknown)"
    case "$os_name" in
        Linux*)
            if [ -d "/data/data/com.termux/files/usr" ] || [ -n "${TERMUX_VERSION:-}" ]; then
                HOM_HOST_OS="termux"
            elif [ -n "$(getprop ro.build.display.id 2>/dev/null || true)" ]; then
                HOM_HOST_OS="android"
            else
                HOM_HOST_OS="linux"
            fi
            ;;
        Darwin*)  HOM_HOST_OS="macos" ;;
        MINGW*|MSYS*|CYGWIN*)  HOM_HOST_OS="windows" ;;
        *)        HOM_HOST_OS="unknown" ;;
    esac
}

_detect_host_os

# ── Colors ────────────────────────────────────────────────────
CLR_GREEN=$'\033[92m'
CLR_YELLOW=$'\033[33m'
CLR_RED=$'\033[91m'
CLR_CYAN=$'\033[96m'
CLR_RESET=$'\033[0m'

if [ ! -t 1 ]; then
    CLR_GREEN="" CLR_YELLOW="" CLR_RED="" CLR_CYAN="" CLR_RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────

info()  { printf "%s  ℹ  %s%s\n" "$CLR_GREEN"  "$1" "$CLR_RESET"; }
warn()  { printf "%s  ⚠  %s%s\n" "$CLR_YELLOW" "$1" "$CLR_RESET"; }
fail()  { printf "%s  ✗  %s%s\n" "$CLR_RED"    "$1" "$CLR_RESET" >&2; exit 1; }
ok()    { printf "%s  ✓  %s%s\n" "$CLR_GREEN"  "$1" "$CLR_RESET"; }
# Target-prefixed messages (cyan ▸) to distinguish from host (green ℹ)
tgt()   { printf "%s  ▸  [TARGET] %s%s\n" "$CLR_CYAN" "$1" "$CLR_RESET"; }

# ── Target device serial ─────────────────────────────────────
# If set, all adb/fastboot commands are routed to this device.
# Set via -s <serial> option.
HOM_TARGET_SERIAL="${HOM_TARGET_SERIAL:-}"

# Wrappers that inject -s <serial> when a target is specified.
# All device commands MUST go through these wrappers.
_adb() {
    if [ -n "$HOM_TARGET_SERIAL" ]; then
        adb -s "$HOM_TARGET_SERIAL" "$@"
    else
        adb "$@"
    fi
}

_fastboot() {
    if [ -n "$HOM_TARGET_SERIAL" ]; then
        fastboot -s "$HOM_TARGET_SERIAL" "$@"
    else
        fastboot "$@"
    fi
}

# ── Target device identification ─────────────────────────────
# Reads model, build, serial from the target to display in headers
# and confirmation prompts. Called once after connection is established.

HOM_TARGET_MODEL=""
HOM_TARGET_BUILD=""
HOM_TARGET_SERIAL_DISPLAY=""
HOM_TARGET_ANDROID_VER=""

_identify_target_adb() {
    HOM_TARGET_MODEL=$(_adb shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "unknown")
    HOM_TARGET_BUILD=$(_adb shell getprop ro.build.display.id 2>/dev/null | tr -d '\r' || echo "unknown")
    HOM_TARGET_ANDROID_VER=$(_adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' || echo "unknown")
    HOM_TARGET_SERIAL_DISPLAY=$(_adb get-serialno 2>/dev/null | tr -d '\r' || echo "${HOM_TARGET_SERIAL:-unknown}")
}

_identify_target_fastboot() {
    HOM_TARGET_SERIAL_DISPLAY=$(_fastboot getvar serialno 2>&1 | grep 'serialno:' | awk '{print $2}' || echo "${HOM_TARGET_SERIAL:-unknown}")
    HOM_TARGET_MODEL=$(_fastboot getvar product 2>&1 | grep 'product:' | awk '{print $2}' || echo "unknown")
    HOM_TARGET_BUILD=""
    HOM_TARGET_ANDROID_VER=""
}

_print_target_banner() {
    echo ""
    echo "  ┌──────────────────────────────────────────────────┐"
    printf "  │  HOST   : %-40s│\n" "$HOM_HOST_OS ($(uname -m 2>/dev/null || echo unknown))"
    printf "  │  TARGET : %-40s│\n" "${HOM_TARGET_MODEL:-not yet detected}"
    if [ -n "$HOM_TARGET_BUILD" ]; then
        printf "  │  Build  : %-40s│\n" "$HOM_TARGET_BUILD"
    fi
    if [ -n "$HOM_TARGET_ANDROID_VER" ]; then
        printf "  │  Android: %-40s│\n" "$HOM_TARGET_ANDROID_VER"
    fi
    printf "  │  Serial : %-40s│\n" "${HOM_TARGET_SERIAL_DISPLAY:-auto-detect}"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""

    # Device-to-device warning
    if [ "$HOM_HOST_OS" = "termux" ] || [ "$HOM_HOST_OS" = "android" ]; then
        local host_model
        host_model=$(getprop ro.product.model 2>/dev/null || echo "this device")
        if [ "$HOM_TARGET_MODEL" = "$host_model" ] && [ "$HOM_TARGET_MODEL" != "unknown" ]; then
            warn "HOST and TARGET appear to be the same device ($host_model)."
            echo "    You cannot flash the device you're running on via ADB/fastboot."
            echo "    To flash THIS device, use Mode A (Magisk) or Mode B (Recovery) instead."
            echo ""
            read -r -p "  Continue anyway? [y/N]: " cont
            [ "$cont" = "y" ] || [ "$cont" = "Y" ] || exit 0
        else
            info "Device-to-device mode: $host_model (HOST) → ${HOM_TARGET_MODEL} (TARGET)"
        fi
    fi
}

# Resolve which target device to use when multiple are connected.
_resolve_target_serial() {
    local mode="$1"  # "adb" or "fastboot"
    local devices=""
    local count=0

    if [ -n "$HOM_TARGET_SERIAL" ]; then
        return 0  # already set via -s option
    fi

    if [ "$mode" = "adb" ]; then
        devices=$(adb devices 2>/dev/null | grep -E '\t(device|recovery|sideload)' | awk '{print $1}')
    else
        devices=$(fastboot devices 2>/dev/null | awk '{print $1}')
    fi

    count=$(echo "$devices" | grep -c . 2>/dev/null || echo 0)

    if [ "$count" -eq 0 ]; then
        return 1  # no devices
    elif [ "$count" -eq 1 ]; then
        HOM_TARGET_SERIAL="$devices"
        return 0
    else
        # Multiple devices — user must pick
        echo ""
        warn "Multiple devices detected. Select the TARGET device to flash:"
        echo ""
        local i=1
        local serials=()
        while IFS= read -r serial; do
            serials+=("$serial")
            local label=""
            if [ "$mode" = "adb" ]; then
                label=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "")
            else
                label=$(fastboot -s "$serial" getvar product 2>&1 | grep 'product:' | awk '{print $2}' || echo "")
            fi
            printf "    %d) %s  %s\n" "$i" "$serial" "${label:+($label)}"
            i=$((i + 1))
        done <<< "$devices"

        echo ""
        read -r -p "  Select target [1-$count]: " pick
        if [ -z "$pick" ] || [ "$pick" -lt 1 ] 2>/dev/null || [ "$pick" -gt "$count" ] 2>/dev/null; then
            fail "Invalid selection. Use -s <serial> to specify the target device."
        fi
        HOM_TARGET_SERIAL="${serials[$((pick - 1))]}"
        ok "Selected target: $HOM_TARGET_SERIAL"
        return 0
    fi
}

# ── Prerequisite checks (OS-tailored) ─────────────────────────

# Print the correct install instructions for this host OS.
_install_instructions() {
    case "$HOM_HOST_OS" in
        linux)
            echo "  Install Android Platform Tools:"
            if command -v apt-get >/dev/null 2>&1; then
                echo "    sudo apt-get install android-tools-adb android-tools-fastboot"
            elif command -v dnf >/dev/null 2>&1; then
                echo "    sudo dnf install android-tools"
            elif command -v pacman >/dev/null 2>&1; then
                echo "    sudo pacman -S android-tools"
            else
                echo "    Download from https://developer.android.com/tools/releases/platform-tools"
                echo "    Extract and add the directory to your PATH."
            fi
            echo ""
            echo "  USB permissions (if 'no permissions' error):"
            echo "    sudo usermod -aG plugdev \$USER"
            echo "    # Then add a udev rule or install android-udev-rules:"
            echo "    sudo apt-get install android-sdk-platform-tools-common  # includes udev rules"
            echo "    # Log out and back in for group changes to take effect."
            ;;
        macos)
            echo "  Install Android Platform Tools:"
            if command -v brew >/dev/null 2>&1; then
                echo "    brew install android-platform-tools"
            else
                echo "    Install Homebrew first: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                echo "    Then: brew install android-platform-tools"
            fi
            echo ""
            echo "  Note: macOS may prompt 'Allow accessory to connect' — click Allow."
            echo "  If adb/fastboot is not found after install, restart your terminal."
            ;;
        windows)
            echo "  Install Android Platform Tools:"
            echo "    1. Download from https://developer.android.com/tools/releases/platform-tools"
            echo "    2. Extract the ZIP (e.g. to C:\\platform-tools)"
            echo "    3. Add the folder to your system PATH:"
            echo "       Settings → System → About → Advanced → Environment Variables → Path → Edit → New"
            echo "    4. Install your device's USB driver (Google USB Driver or OEM driver)"
            echo "       https://developer.android.com/studio/run/oem-usb"
            echo ""
            echo "  If using Git Bash/MSYS2, run this script from there."
            echo "  If using PowerShell/CMD, use .\\adb.exe and .\\fastboot.exe instead."
            ;;
        termux)
            echo "  Install Android Platform Tools in Termux:"
            echo "    pkg install android-tools"
            echo ""
            echo "  Note: ADB in Termux requires either:"
            echo "    a) Wireless debugging (Android 11+): Settings → Developer options → Wireless debugging"
            echo "       adb pair <ip>:<pair_port>    # enter the pairing code"
            echo "       adb connect <ip>:<port>"
            echo "    b) USB OTG cable connecting another device"
            echo ""
            echo "  Fastboot from Termux requires USB OTG — wireless does not support fastboot."
            ;;
        android)
            echo "  ADB is not typically available in native Android shell."
            echo "  Install Termux from F-Droid and use Termux instead,"
            echo "  or run this script from a PC connected to the device."
            ;;
        *)
            echo "  Install Android Platform Tools from:"
            echo "    https://developer.android.com/tools/releases/platform-tools"
            ;;
    esac
}

check_host_prereqs() {
    local missing=""

    info "Host OS detected: $HOM_HOST_OS"

    # Termux/Android: warn about limitations
    if [ "$HOM_HOST_OS" = "termux" ]; then
        warn "Running from Termux — fastboot requires USB OTG; ADB requires wireless debugging or OTG."
    elif [ "$HOM_HOST_OS" = "android" ]; then
        warn "Running from native Android shell — limited ADB/fastboot support."
        echo "  Consider using a PC or Termux instead."
    fi

    if ! command -v adb >/dev/null 2>&1; then
        missing="${missing}adb "
    fi
    if ! command -v fastboot >/dev/null 2>&1; then
        missing="${missing}fastboot "
    fi

    if [ -n "$missing" ]; then
        echo ""
        echo "  ${CLR_RED}✗  Missing required tools: ${missing}${CLR_RESET}" >&2
        echo ""
        _install_instructions
        exit 1
    fi

    ok "Host tools found: adb $(adb version 2>/dev/null | head -1 | awk '{print $NF}'), fastboot $(fastboot --version 2>/dev/null | head -1 | awk '{print $NF}')"

    # Platform-specific USB permission check
    if [ "$HOM_HOST_OS" = "linux" ]; then
        # Check if user can access USB devices (common Linux issue)
        if ! adb devices >/dev/null 2>&1; then
            warn "ADB could not list devices. You may need USB permissions:"
            echo "    sudo usermod -aG plugdev \$USER  # then log out and back in"
        fi
    elif [ "$HOM_HOST_OS" = "windows" ]; then
        info "Windows: ensure your device's USB driver is installed."
        echo "    https://developer.android.com/studio/run/oem-usb"
    fi
}

# Check if a device is connected in the given mode.
# Returns 0 if found, 1 if not.
check_device_adb() {
    if [ -n "$HOM_TARGET_SERIAL" ]; then
        # Check specific serial
        adb devices 2>/dev/null | grep -qE "^${HOM_TARGET_SERIAL}\s+(device|recovery|sideload)"
    else
        local count
        count=$(adb devices 2>/dev/null | grep -cE '\t(device|recovery|sideload)' || true)
        [ "$count" -gt 0 ]
    fi
}

check_device_fastboot() {
    if [ -n "$HOM_TARGET_SERIAL" ]; then
        fastboot devices 2>/dev/null | grep -qE "^${HOM_TARGET_SERIAL}\s"
    else
        local count
        count=$(fastboot devices 2>/dev/null | grep -cE 'fastboot' || true)
        [ "$count" -gt 0 ]
    fi
}

wait_for_device() {
    local mode="$1" timeout="${2:-30}"
    local elapsed=0
    local serial_hint=""
    [ -n "$HOM_TARGET_SERIAL" ] && serial_hint=" (serial: $HOM_TARGET_SERIAL)"

    info "Waiting for TARGET device in $mode mode${serial_hint} (${timeout}s timeout)..."

    # Platform-specific hints while waiting
    if [ "$mode" = "fastboot" ] && [ "$HOM_HOST_OS" = "termux" ]; then
        warn "Fastboot in Termux requires USB OTG cable — wireless ADB does not support fastboot."
    elif [ "$mode" = "fastboot" ] && [ "$HOM_HOST_OS" = "windows" ]; then
        info "Windows: if TARGET is not detected, check USB driver installation."
    elif [ "$mode" = "adb" ] && [ "$HOM_HOST_OS" = "termux" ]; then
        info "Termux ADB: ensure wireless debugging is connected (adb connect <ip>:<port>)."
    fi

    while [ "$elapsed" -lt "$timeout" ]; do
        case "$mode" in
            adb)      check_device_adb && { ok "TARGET device found (ADB)${serial_hint}"; return 0; } ;;
            fastboot) check_device_fastboot && { ok "TARGET device found (fastboot)${serial_hint}"; return 0; } ;;
        esac
        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Helpful failure message per platform
    echo ""
    case "$HOM_HOST_OS" in
        linux)
            warn "TARGET device not found. Check:"
            echo "    • USB cable is data-capable (not charge-only)"
            echo "    • USB debugging is enabled on TARGET device"
            echo "    • Run: sudo adb devices  (if permission denied)"
            echo "    • Check udev rules: lsusb | grep -i android"
            ;;
        macos)
            warn "TARGET device not found. Check:"
            echo "    • USB cable is data-capable"
            echo "    • USB debugging is enabled on TARGET"
            echo "    • Click 'Allow' on any macOS accessory prompts"
            echo "    • Try: adb kill-server && adb start-server"
            ;;
        windows)
            warn "TARGET device not found. Check:"
            echo "    • USB cable is data-capable"
            echo "    • USB debugging is enabled on TARGET"
            echo "    • USB driver is installed for TARGET (Device Manager → show device)"
            echo "    • Try: adb kill-server && adb start-server"
            echo "    • Download driver: https://developer.android.com/studio/run/oem-usb"
            ;;
        termux)
            warn "TARGET device not found. Check:"
            echo "    • For wireless: TARGET has wireless debugging enabled and paired"
            echo "    • Run: adb pair <ip>:<pair_port>  then  adb connect <ip>:<port>"
            echo "    • For USB OTG: OTG cable connected to TARGET"
            echo "    • Fastboot requires USB OTG — wireless does not support fastboot"
            ;;
        android)
            warn "TARGET device not found."
            echo "    Consider using Termux (with wireless debugging) or a PC instead."
            ;;
        *)
            warn "TARGET device not found. Check USB connection and debugging settings."
            ;;
    esac
    return 1
}

# Find the latest recovery ZIP in dist/.
find_recovery_zip() {
    local latest=""
    if [ -d "$DIST_DIR" ]; then
        latest=$(ls -t "$DIST_DIR"/hands-on-metal-recovery-*.zip 2>/dev/null | head -1 || true)
    fi
    echo "$latest"
}

# ── C1: Temporary TWRP boot ──────────────────────────────────

run_c1() {
    local twrp_img="${1:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Mode C1 — Temporary TWRP Boot via fastboot"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "HOST ($HOM_HOST_OS) will boot TWRP on TARGET via fastboot."
    info "TWRP runs in RAM only — TARGET's stock recovery is unchanged."
    echo ""

    # Validate TWRP image
    if [ -z "$twrp_img" ]; then
        echo "  Enter the path to your TWRP .img file (on this $HOM_HOST_OS machine):"
        echo "  (Download from https://twrp.me/Devices/ for your TARGET device)"
        echo ""
        read -r -p "  TWRP image path: " twrp_img
    fi

    if [ ! -f "$twrp_img" ]; then
        fail "TWRP image not found at: $twrp_img (on HOST)"
    fi

    ok "TWRP image (on HOST): $twrp_img"

    # Get TARGET device into fastboot
    if check_device_fastboot; then
        _resolve_target_serial fastboot
        _identify_target_fastboot
        ok "TARGET already in fastboot mode"
    elif check_device_adb; then
        _resolve_target_serial adb
        _identify_target_adb
        tgt "Rebooting TARGET to bootloader..."
        _adb reboot bootloader
        wait_for_device fastboot 30 || fail "TARGET did not enter fastboot mode"
    else
        echo ""
        warn "No TARGET device detected."
        case "$HOM_HOST_OS" in
            linux|macos)
                echo "    Connect TARGET device via USB, then either:"
                echo "      • Enable USB debugging on TARGET and run: adb reboot bootloader"
                echo "      • Or power off TARGET, hold Power + Volume Down to enter fastboot"
                ;;
            windows)
                echo "    1. Ensure USB driver for TARGET is installed (Device Manager)"
                echo "    2. Connect TARGET via USB, then either:"
                echo "       • Run: adb reboot bootloader"
                echo "       • Or power off TARGET, hold Power + Volume Down"
                ;;
            termux)
                echo "    Fastboot requires USB OTG cable from this device to TARGET."
                echo "    Wireless ADB cannot enter fastboot."
                echo "    Connect TARGET via OTG, then:"
                echo "      Power off TARGET → hold Power + Volume Down"
                ;;
            *)
                echo "    Connect TARGET and enter fastboot mode (Power + Volume Down)"
                ;;
        esac
        echo ""
        wait_for_device fastboot 60 || fail "No TARGET device found in fastboot mode"
        _resolve_target_serial fastboot
        _identify_target_fastboot
    fi

    _print_target_banner

    # Boot TWRP on TARGET
    tgt "Booting TWRP image on TARGET (temporary, RAM only)..."
    if ! _fastboot boot "$twrp_img"; then
        fail "fastboot boot failed on TARGET. The device may not support booting unsigned images.
  Try instead:
    fastboot${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} flash recovery $twrp_img
    fastboot${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} reboot recovery"
    fi

    ok "TWRP booted on TARGET"
    echo ""

    # Offer to sideload the recovery ZIP
    local zip
    zip=$(find_recovery_zip)
    if [ -n "$zip" ]; then
        echo "  Found recovery ZIP (on HOST): $zip"
        echo ""
        read -r -p "  Sideload this ZIP to TARGET now? [y/N]: " do_sideload
        if [ "$do_sideload" = "y" ] || [ "$do_sideload" = "Y" ]; then
            echo ""
            info "Waiting for TWRP ADB on TARGET..."
            echo "  On TARGET device: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            wait_for_device adb 120 || fail "TARGET not detected in ADB mode. Start ADB sideload in TWRP on TARGET first."

            tgt "Sideloading to TARGET: $zip"
            _adb sideload "$zip"
            local rc=$?
            if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
                # adb sideload returns 1 on some TWRP versions even on success
                ok "Sideload to TARGET complete (exit code $rc)"
            else
                fail "Sideload to TARGET failed (exit code $rc)"
            fi
        fi
    else
        echo "  No recovery ZIP found in $DIST_DIR/ (on HOST)"
        echo "  Run 'build/build_offline_zip.sh' on HOST first, or push manually:"
        echo "    adb${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} push <recovery-zip> /sdcard/"
        echo "    Then flash from TWRP on TARGET: Install → select ZIP"
    fi

    echo ""
    echo "  Next steps:"
    echo "    1. If not sideloaded: flash the ZIP from TWRP on TARGET → Install"
    echo "    2. After flash: TARGET reboots automatically"
    echo "    3. On TARGET: open Magisk app → confirm root"
    echo ""
}

# ── C2: Direct fastboot flash ────────────────────────────────

run_c2() {
    local patched_img="${1:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Mode C2 — Direct Fastboot Flash"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "HOST ($HOM_HOST_OS) will flash a pre-patched boot image to TARGET via fastboot."
    info "No recovery needed on TARGET. Boot image must be patched on HOST first."
    echo ""

    # Validate patched image (must exist on HOST)
    if [ -z "$patched_img" ]; then
        echo "  Enter the path to your Magisk-patched boot image (on this $HOM_HOST_OS machine):"
        echo "  (Patch via Magisk app on another device, or extract from factory image)"
        echo ""
        read -r -p "  Patched boot image path (on HOST): " patched_img
    fi

    if [ ! -f "$patched_img" ]; then
        fail "Patched boot image not found at: $patched_img (on HOST)"
    fi

    ok "Patched image (on HOST): $patched_img"

    # Detect partition type from filename
    local part_name="boot"
    case "$patched_img" in
        *init_boot*) part_name="init_boot" ;;
    esac
    info "Target partition on TARGET: $part_name (detected from filename)"

    # Get TARGET into fastboot
    if check_device_fastboot; then
        _resolve_target_serial fastboot
        _identify_target_fastboot
        ok "TARGET already in fastboot mode"
    elif check_device_adb; then
        _resolve_target_serial adb
        _identify_target_adb
        tgt "Rebooting TARGET to bootloader..."
        _adb reboot bootloader
        wait_for_device fastboot 30 || fail "TARGET did not enter fastboot mode"
    else
        echo ""
        warn "No TARGET device detected."
        case "$HOM_HOST_OS" in
            termux)
                echo "    Connect TARGET device via USB OTG cable, then:"
                echo "      Power off TARGET → hold Power + Volume Down"
                ;;
            *)
                echo "    Connect TARGET and enter fastboot mode:"
                echo "      Power off TARGET → hold Power + Volume Down"
                ;;
        esac
        echo ""
        wait_for_device fastboot 60 || fail "No TARGET device found in fastboot mode"
        _resolve_target_serial fastboot
        _identify_target_fastboot
    fi

    _print_target_banner

    # Confirm before flashing TARGET
    echo ""
    echo "  ${CLR_YELLOW}WARNING: This will overwrite the $part_name partition on TARGET.${CLR_RESET}"
    echo "  HOST     : $HOM_HOST_OS"
    echo "  TARGET   : ${HOM_TARGET_MODEL:-unknown} (serial: ${HOM_TARGET_SERIAL_DISPLAY:-auto})"
    echo "  Partition: $part_name"
    echo "  Image    : $patched_img (on HOST)"
    echo ""
    read -r -p "  Proceed with flash to TARGET? [y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Flash cancelled."
        return 0
    fi

    # Flash TARGET
    tgt "Flashing $part_name on TARGET..."
    if ! _fastboot flash "$part_name" "$patched_img"; then
        fail "fastboot flash failed on TARGET. Check:
  • Is TARGET's bootloader unlocked?
  • Is the image the correct format for TARGET?
  • Try: fastboot${HOM_TARGET_SERIAL:+ -s $HOM_TARGET_SERIAL} flashing unlock"
    fi

    ok "Flash to TARGET successful"

    # Reboot TARGET
    read -r -p "  Reboot TARGET now? [Y/n]: " do_reboot
    if [ "$do_reboot" != "n" ] && [ "$do_reboot" != "N" ]; then
        _fastboot reboot
        ok "TARGET rebooting"
    fi

    echo ""
    echo "  Next steps (on TARGET device):"
    echo "    1. Install Magisk app (APK) if not already installed"
    echo "    2. Open Magisk → confirm root"
    echo "    3. Flash the hands-on-metal Magisk module ZIP via Magisk app"
    echo ""
}

# ── C3: ADB sideload ─────────────────────────────────────────

run_c3() {
    local zip="${1:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Mode C3 — ADB Sideload"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    info "HOST ($HOM_HOST_OS) will sideload the recovery ZIP to TARGET."
    warn "Stock recovery on TARGET does NOT accept unsigned ZIPs — custom recovery required."
    echo ""

    # Find ZIP (on HOST)
    if [ -z "$zip" ]; then
        zip=$(find_recovery_zip)
        if [ -n "$zip" ]; then
            info "Found recovery ZIP (on HOST): $zip"
            read -r -p "  Use this ZIP? [Y/n]: " use_found
            if [ "$use_found" = "n" ] || [ "$use_found" = "N" ]; then
                read -r -p "  Enter ZIP path (on HOST): " zip
            fi
        else
            echo "  No recovery ZIP found in $DIST_DIR/ (on HOST)"
            echo "  Run 'build/build_offline_zip.sh' on HOST first, or enter a path:"
            echo ""
            read -r -p "  Recovery ZIP path (on HOST): " zip
        fi
    fi

    if [ ! -f "$zip" ]; then
        fail "Recovery ZIP not found at: $zip (on HOST)"
    fi

    ok "Recovery ZIP (on HOST): $zip"

    # Check TARGET device state
    if check_device_adb; then
        _resolve_target_serial adb
        _identify_target_adb

        # Check if already in recovery/sideload
        local state
        state=$(adb devices 2>/dev/null | grep -E "^${HOM_TARGET_SERIAL:-[^\t]+}\s" | grep -oE '(recovery|sideload)' | head -1 || true)
        if [ "$state" = "sideload" ]; then
            ok "TARGET already in sideload mode"
        elif [ "$state" = "recovery" ]; then
            tgt "TARGET is in recovery mode."
            echo "  On TARGET: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            read -r -p "  Press Enter when sideload mode is active on TARGET..."
        else
            tgt "TARGET detected in normal ADB mode. Rebooting TARGET to recovery..."
            _adb reboot recovery
            echo ""
            echo "  Waiting for TWRP to boot on TARGET..."
            echo "  When TWRP loads on TARGET: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            read -r -p "  Press Enter when sideload mode is active on TARGET..."
        fi
    else
        echo ""
        warn "No TARGET device detected via ADB."
        case "$HOM_HOST_OS" in
            termux)
                echo "    For wireless ADB:"
                echo "      1. On TARGET: Settings → Developer options → Wireless debugging"
                echo "      2. On this device: adb pair <ip>:<pair_port>"
                echo "      3. On this device: adb connect <ip>:<port>"
                echo "    For USB OTG:"
                echo "      Connect TARGET via OTG cable"
                ;;
            *)
                echo "    1. Connect TARGET via USB"
                echo "    2. Boot TARGET into recovery (Power + Volume Down, or 'adb reboot recovery')"
                echo "    3. In TWRP on TARGET: Advanced → ADB Sideload → Swipe to start"
                ;;
        esac
        echo ""
        read -r -p "  Press Enter when TARGET is in sideload mode..."
        _resolve_target_serial adb
        _identify_target_adb
    fi

    _print_target_banner

    # Sideload to TARGET
    tgt "Sideloading to TARGET: $zip"
    _adb sideload "$zip"
    local rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
        ok "Sideload to TARGET complete (exit code $rc — normal for TWRP)"
    else
        fail "Sideload to TARGET failed (exit code $rc).
  Check that TARGET is in TWRP sideload mode.
  Stock recovery rejects unsigned ZIPs."
    fi

    echo ""
    echo "  Next steps (on TARGET device):"
    echo "    1. TARGET reboots automatically after the installer finishes"
    echo "    2. On TARGET: open Magisk app → confirm root"
    echo "    3. On TARGET: check /sdcard/hands-on-metal/ for hardware data"
    echo ""
}

# ── Interactive menu ──────────────────────────────────────────

show_menu() {
    check_host_prereqs

    local zip
    zip=$(find_recovery_zip)

    # Try to detect and identify target
    local target_status="not detected"
    if check_device_adb; then
        _resolve_target_serial adb
        _identify_target_adb
        target_status="${HOM_TARGET_MODEL} (Android ${HOM_TARGET_ANDROID_VER}, serial: ${HOM_TARGET_SERIAL_DISPLAY})"
    elif check_device_fastboot; then
        _resolve_target_serial fastboot
        _identify_target_fastboot
        target_status="${HOM_TARGET_MODEL} (fastboot, serial: ${HOM_TARGET_SERIAL_DISPLAY})"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  hands-on-metal — Host-Assisted Flash (Mode C)"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    printf "  HOST   : %s (%s)\n" "$HOM_HOST_OS" "$(uname -m 2>/dev/null || echo unknown)"
    printf "  TARGET : %s\n" "$target_status"
    echo ""
    echo "  Choose a sub-path:"
    echo ""
    echo "    1) C1 — Temporary TWRP boot (fastboot boot twrp.img)"
    echo "           Boots TWRP in RAM on TARGET, then sideload."
    echo ""
    echo "    2) C2 — Direct fastboot flash (pre-patched boot image)"
    echo "           Flashes boot image from HOST to TARGET. No recovery needed."
    echo ""
    echo "    3) C3 — ADB sideload (requires TWRP/OrangeFox on TARGET)"
    echo "           Sends recovery ZIP from HOST to TARGET."
    echo ""

    if [ -n "$zip" ]; then
        echo "  ${CLR_GREEN}Recovery ZIP found (on HOST): $(basename "$zip")${CLR_RESET}"
    else
        echo "  ${CLR_YELLOW}No recovery ZIP found on HOST — run 'build/build_offline_zip.sh' first${CLR_RESET}"
    fi

    echo ""
    echo "    q) Back to main menu"
    echo ""

    read -r -p "  Choose [1/2/3/q]: " choice
    case "$choice" in
        1) run_c1 ;;
        2) run_c2 ;;
        3) run_c3 ;;
        q|Q) return 0 ;;
        *) warn "Invalid choice"; show_menu ;;
    esac
}

# ── CLI entry point ───────────────────────────────────────────

main() {
    # Parse global options first (-s serial)
    while [ $# -gt 0 ]; do
        case "$1" in
            -s)
                shift
                if [ $# -eq 0 ]; then
                    fail "Option -s requires a serial number argument."
                fi
                HOM_TARGET_SERIAL="$1"
                info "Target serial set: $HOM_TARGET_SERIAL"
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    case "${1:-}" in
        --c1) shift; check_host_prereqs; run_c1 "$@" ;;
        --c2) shift; check_host_prereqs; run_c2 "$@" ;;
        --c3) shift; check_host_prereqs; run_c3 "$@" ;;
        --help|-h)
            echo "Usage: bash build/host_flash.sh [-s SERIAL] [--c1 TWRP_IMG | --c2 PATCHED_IMG | --c3 ZIP]"
            echo ""
            echo "  Flashes a TARGET device from this HOST machine."
            echo ""
            echo "  -s SERIAL        Target a specific device by serial number"
            echo "                   (required when multiple devices are connected)"
            echo "  --c1 TWRP_IMG    Temporarily boot TWRP on TARGET, then sideload"
            echo "  --c2 PATCHED_IMG Flash pre-patched boot image to TARGET via fastboot"
            echo "  --c3 ZIP         ADB sideload recovery ZIP to TARGET in TWRP"
            echo ""
            echo "  No arguments: show interactive menu"
            echo ""
            echo "  HOST   = this machine ($(uname -s)/$(uname -m))"
            echo "  TARGET = the device being flashed (connected via USB/OTG/wireless)"
            ;;
        *)  show_menu ;;
    esac
}

main "$@"
