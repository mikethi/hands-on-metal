#!/usr/bin/env bash
# build/host_flash.sh
# ============================================================
# hands-on-metal — Host-Assisted Flash (Mode C)
#
# Runs on a PC (host machine) connected to a device via USB.
# Handles devices that have NO custom recovery and NO root.
#
# Supports three sub-paths:
#   C1 — Temporary TWRP boot:  fastboot boot twrp.img
#   C2 — Direct fastboot flash of a pre-patched boot image
#   C3 — ADB sideload (requires recovery on device)
#
# Prerequisites (checked automatically):
#   - adb and fastboot commands available (cmd:adb cmd:fastboot)
#   - USB-connected Android device (detected via adb/fastboot)
#   - Unlocked bootloader (for C1 and C2)
#
# Usage:
#   bash build/host_flash.sh              # interactive menu
#   bash build/host_flash.sh --c1 TWRP    # boot TWRP image
#   bash build/host_flash.sh --c2 IMG     # flash pre-patched image
#   bash build/host_flash.sh --c3 ZIP     # sideload recovery ZIP
#
# This script follows the same conventions as the terminal menu:
#   - Prerequisite checking via check_deps.sh IDs
#   - Color-coded output
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
CLR_RESET=$'\033[0m'

if [ ! -t 1 ]; then
    CLR_GREEN="" CLR_YELLOW="" CLR_RED="" CLR_RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────

info()  { printf "%s  ℹ  %s%s\n" "$CLR_GREEN"  "$1" "$CLR_RESET"; }
warn()  { printf "%s  ⚠  %s%s\n" "$CLR_YELLOW" "$1" "$CLR_RESET"; }
fail()  { printf "%s  ✗  %s%s\n" "$CLR_RED"    "$1" "$CLR_RESET" >&2; exit 1; }
ok()    { printf "%s  ✓  %s%s\n" "$CLR_GREEN"  "$1" "$CLR_RESET"; }

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
    local count
    count=$(adb devices 2>/dev/null | grep -cE '\t(device|recovery|sideload)' || true)
    [ "$count" -gt 0 ]
}

check_device_fastboot() {
    local count
    # On Windows, fastboot may show "fastboot" or "fastbootd"
    count=$(fastboot devices 2>/dev/null | grep -cE 'fastboot' || true)
    [ "$count" -gt 0 ]
}

wait_for_device() {
    local mode="$1" timeout="${2:-30}"
    local elapsed=0

    info "Waiting for device in $mode mode (${timeout}s timeout)..."

    # Platform-specific hints while waiting
    if [ "$mode" = "fastboot" ] && [ "$HOM_HOST_OS" = "termux" ]; then
        warn "Fastboot in Termux requires USB OTG cable — wireless ADB does not support fastboot."
    elif [ "$mode" = "fastboot" ] && [ "$HOM_HOST_OS" = "windows" ]; then
        info "Windows: if device is not detected, check USB driver installation."
    elif [ "$mode" = "adb" ] && [ "$HOM_HOST_OS" = "termux" ]; then
        info "Termux ADB: ensure wireless debugging is connected (adb connect <ip>:<port>)."
    fi

    while [ "$elapsed" -lt "$timeout" ]; do
        case "$mode" in
            adb)      check_device_adb && { ok "Device found (ADB)"; return 0; } ;;
            fastboot) check_device_fastboot && { ok "Device found (fastboot)"; return 0; } ;;
        esac
        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Helpful failure message per platform
    echo ""
    case "$HOM_HOST_OS" in
        linux)
            warn "Device not found. Check:"
            echo "    • USB cable is data-capable (not charge-only)"
            echo "    • USB debugging is enabled on device"
            echo "    • Run: sudo adb devices  (if permission denied)"
            echo "    • Check udev rules: lsusb | grep -i android"
            ;;
        macos)
            warn "Device not found. Check:"
            echo "    • USB cable is data-capable"
            echo "    • USB debugging is enabled"
            echo "    • Click 'Allow' on any macOS accessory prompts"
            echo "    • Try: adb kill-server && adb start-server"
            ;;
        windows)
            warn "Device not found. Check:"
            echo "    • USB cable is data-capable"
            echo "    • USB debugging is enabled"
            echo "    • USB driver is installed (Device Manager → show device)"
            echo "    • Try: adb kill-server && adb start-server"
            echo "    • Download driver: https://developer.android.com/studio/run/oem-usb"
            ;;
        termux)
            warn "Device not found. Check:"
            echo "    • Wireless debugging is enabled and paired"
            echo "    • Run: adb connect <ip>:<port>"
            echo "    • For fastboot: USB OTG cable is required"
            ;;
        *)
            warn "Device not found. Check USB connection and debugging settings."
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
    info "This boots TWRP temporarily (in RAM). After reboot, stock recovery returns."
    echo ""

    # Validate TWRP image
    if [ -z "$twrp_img" ]; then
        echo "  Enter the path to your TWRP .img file:"
        echo "  (Download from https://twrp.me/Devices/ for your device)"
        echo ""
        read -r -p "  TWRP image path: " twrp_img
    fi

    if [ ! -f "$twrp_img" ]; then
        fail "TWRP image not found at: $twrp_img"
    fi

    ok "TWRP image: $twrp_img"

    # Get device into fastboot
    if check_device_fastboot; then
        ok "Device already in fastboot mode"
    elif check_device_adb; then
        info "Rebooting device to bootloader..."
        adb reboot bootloader
        wait_for_device fastboot 30 || fail "Device did not enter fastboot mode"
    else
        echo ""
        warn "No device detected."
        case "$HOM_HOST_OS" in
            linux|macos)
                echo "    Connect your device via USB, then either:"
                echo "      • Enable USB debugging and run: adb reboot bootloader"
                echo "      • Or power off, then hold Power + Volume Down to enter fastboot"
                ;;
            windows)
                echo "    1. Ensure USB driver is installed (Device Manager)"
                echo "    2. Connect device via USB, then either:"
                echo "       • Run: adb reboot bootloader"
                echo "       • Or power off, hold Power + Volume Down"
                ;;
            termux)
                echo "    Fastboot requires USB OTG cable — wireless ADB cannot enter fastboot."
                echo "    Connect target device via OTG, then:"
                echo "      Power off target → hold Power + Volume Down"
                ;;
            *)
                echo "    Connect device and enter fastboot mode (Power + Volume Down)"
                ;;
        esac
        echo ""
        wait_for_device fastboot 60 || fail "No device found in fastboot mode"
    fi

    # Boot TWRP
    info "Booting TWRP image (temporary, RAM only)..."
    if ! fastboot boot "$twrp_img"; then
        fail "fastboot boot failed. Your device may not support booting unsigned images.
  Try instead:
    fastboot flash recovery $twrp_img
    fastboot reboot recovery"
    fi

    ok "TWRP booted successfully"
    echo ""

    # Offer to sideload the recovery ZIP
    local zip
    zip=$(find_recovery_zip)
    if [ -n "$zip" ]; then
        echo "  Found recovery ZIP: $zip"
        echo ""
        read -r -p "  Sideload this ZIP now? [y/N]: " do_sideload
        if [ "$do_sideload" = "y" ] || [ "$do_sideload" = "Y" ]; then
            echo ""
            info "Waiting for TWRP to start ADB..."
            echo "  On device: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            wait_for_device adb 120 || fail "Device not detected in ADB mode. Start ADB sideload in TWRP first."

            info "Sideloading: $zip"
            adb sideload "$zip"
            local rc=$?
            if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
                # adb sideload returns 1 on some TWRP versions even on success
                ok "Sideload complete (exit code $rc)"
            else
                fail "Sideload failed (exit code $rc)"
            fi
        fi
    else
        echo "  No recovery ZIP found in $DIST_DIR/"
        echo "  Run 'build/build_offline_zip.sh' first, or push manually:"
        echo "    adb push <recovery-zip> /sdcard/"
        echo "    Then flash from TWRP: Install → select ZIP"
    fi

    echo ""
    echo "  Next steps:"
    echo "    1. If not sideloaded: flash the ZIP from TWRP → Install"
    echo "    2. After flash: device reboots automatically"
    echo "    3. Open Magisk app → confirm root"
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
    info "Flashes a pre-patched boot image directly via fastboot."
    info "No recovery needed. Boot image must be patched on PC first."
    echo ""

    # Validate patched image
    if [ -z "$patched_img" ]; then
        echo "  Enter the path to your Magisk-patched boot image:"
        echo "  (Patch via Magisk app on another device, or extract from factory image)"
        echo ""
        read -r -p "  Patched boot image path: " patched_img
    fi

    if [ ! -f "$patched_img" ]; then
        fail "Patched boot image not found at: $patched_img"
    fi

    ok "Patched image: $patched_img"

    # Detect partition type from filename
    local part_name="boot"
    case "$patched_img" in
        *init_boot*) part_name="init_boot" ;;
    esac
    info "Target partition: $part_name (detected from filename)"

    # Get device into fastboot
    if check_device_fastboot; then
        ok "Device already in fastboot mode"
    elif check_device_adb; then
        info "Rebooting device to bootloader..."
        adb reboot bootloader
        wait_for_device fastboot 30 || fail "Device did not enter fastboot mode"
    else
        echo ""
        warn "No device detected. Connect and enter fastboot mode:"
        echo "    Power off → hold Power + Volume Down"
        echo ""
        wait_for_device fastboot 60 || fail "No device found in fastboot mode"
    fi

    # Confirm before flashing
    echo ""
    echo "  ${CLR_YELLOW}WARNING: This will overwrite the $part_name partition.${CLR_RESET}"
    echo "  Image : $patched_img"
    echo "  Target: $part_name"
    echo ""
    read -r -p "  Proceed with flash? [y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Flash cancelled."
        return 0
    fi

    # Flash
    info "Flashing $part_name..."
    if ! fastboot flash "$part_name" "$patched_img"; then
        fail "fastboot flash failed. Check:
  • Is the bootloader unlocked?
  • Is the image the correct format for your device?
  • Try: fastboot flashing unlock"
    fi

    ok "Flash successful"

    # Reboot
    read -r -p "  Reboot now? [Y/n]: " do_reboot
    if [ "$do_reboot" != "n" ] && [ "$do_reboot" != "N" ]; then
        fastboot reboot
        ok "Device rebooting"
    fi

    echo ""
    echo "  Next steps:"
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
    info "Sideloads the recovery ZIP to a device in TWRP/OrangeFox recovery."
    warn "Stock recovery does NOT accept unsigned ZIPs — custom recovery required."
    echo ""

    # Find ZIP
    if [ -z "$zip" ]; then
        zip=$(find_recovery_zip)
        if [ -n "$zip" ]; then
            info "Found recovery ZIP: $zip"
            read -r -p "  Use this ZIP? [Y/n]: " use_found
            if [ "$use_found" = "n" ] || [ "$use_found" = "N" ]; then
                read -r -p "  Enter ZIP path: " zip
            fi
        else
            echo "  No recovery ZIP found in $DIST_DIR/"
            echo "  Run 'build/build_offline_zip.sh' first, or enter a path:"
            echo ""
            read -r -p "  Recovery ZIP path: " zip
        fi
    fi

    if [ ! -f "$zip" ]; then
        fail "Recovery ZIP not found at: $zip"
    fi

    ok "Recovery ZIP: $zip"

    # Check device state
    if check_device_adb; then
        # Check if already in recovery/sideload
        local state
        state=$(adb devices 2>/dev/null | grep -oE '(recovery|sideload)' | head -1 || true)
        if [ "$state" = "sideload" ]; then
            ok "Device already in sideload mode"
        elif [ "$state" = "recovery" ]; then
            info "Device is in recovery mode."
            echo "  On device: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            read -r -p "  Press Enter when sideload mode is active..."
        else
            info "Device detected in normal ADB mode. Rebooting to recovery..."
            adb reboot recovery
            echo ""
            echo "  Waiting for TWRP to boot..."
            echo "  When TWRP loads: tap Advanced → ADB Sideload → Swipe to start"
            echo ""
            read -r -p "  Press Enter when sideload mode is active..."
        fi
    else
        echo ""
        warn "No device detected via ADB."
        echo "    1. Boot into recovery (Power + Volume Down, or 'adb reboot recovery')"
        echo "    2. In TWRP: Advanced → ADB Sideload → Swipe to start"
        echo ""
        read -r -p "  Press Enter when device is in sideload mode..."
    fi

    # Sideload
    info "Sideloading: $zip"
    adb sideload "$zip"
    local rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
        ok "Sideload complete (exit code $rc — normal for TWRP)"
    else
        fail "Sideload failed (exit code $rc).
  Check that the device is in TWRP sideload mode.
  Stock recovery rejects unsigned ZIPs."
    fi

    echo ""
    echo "  Next steps:"
    echo "    1. Device reboots automatically after the installer finishes"
    echo "    2. Open Magisk app → confirm root"
    echo "    3. Check /sdcard/hands-on-metal/ for hardware data"
    echo ""
}

# ── Interactive menu ──────────────────────────────────────────

show_menu() {
    check_host_prereqs

    local zip
    zip=$(find_recovery_zip)

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  hands-on-metal — Host-Assisted Flash (Mode C)"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Choose a sub-path:"
    echo ""
    echo "    1) C1 — Temporary TWRP boot (fastboot boot twrp.img)"
    echo "           No recovery needed. Boots TWRP in RAM, then sideload."
    echo ""
    echo "    2) C2 — Direct fastboot flash (pre-patched boot image)"
    echo "           No recovery needed. Requires image patched on PC."
    echo ""
    echo "    3) C3 — ADB sideload (requires TWRP/OrangeFox on device)"
    echo "           Fastest if you already have custom recovery."
    echo ""

    if [ -n "$zip" ]; then
        echo "  ${CLR_GREEN}Recovery ZIP found: $(basename "$zip")${CLR_RESET}"
    else
        echo "  ${CLR_YELLOW}No recovery ZIP found — run 'build/build_offline_zip.sh' first${CLR_RESET}"
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
    case "${1:-}" in
        --c1) shift; check_host_prereqs; run_c1 "$@" ;;
        --c2) shift; check_host_prereqs; run_c2 "$@" ;;
        --c3) shift; check_host_prereqs; run_c3 "$@" ;;
        --help|-h)
            echo "Usage: bash build/host_flash.sh [--c1 TWRP_IMG | --c2 PATCHED_IMG | --c3 ZIP]"
            echo ""
            echo "  --c1 TWRP_IMG      Temporarily boot TWRP, then sideload"
            echo "  --c2 PATCHED_IMG   Flash pre-patched boot image via fastboot"
            echo "  --c3 ZIP           ADB sideload recovery ZIP to TWRP"
            echo ""
            echo "  No arguments: show interactive menu"
            ;;
        *)  show_menu ;;
    esac
}

main "$@"
