#!/usr/bin/env bash
# terminal_menu.sh
# Interactive terminal launcher for all project scripts.
#
# Features:
#   - Color-coded menu items based on prerequisite status
#   - Prerequisites sub-menu showing detailed dependency info
#   - Automatic detection of what can run, what is already done,
#     and what still needs prerequisites fulfilled
#
# Color scheme:
#   Light green — script is ready to run (all prerequisites met)
#   Dark green  — script does not need to be run (already done)
#   Yellow      — script has unmet prerequisites (details shown)

set -eu

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── dependency check (runs once per session) ──────────────────
source "$REPO_ROOT/check_deps.sh" || exit 1

# ── ANSI color codes ─────────────────────────────────────────
CLR_LIGHT_GREEN=$'\033[92m'   # ready to run
CLR_DARK_GREEN=$'\033[32m'    # already done / not needed
CLR_YELLOW=$'\033[33m'        # unmet prerequisites
CLR_RESET=$'\033[0m'

# If output is not a terminal, disable colors
if [ ! -t 1 ]; then
    CLR_LIGHT_GREEN=""
    CLR_DARK_GREEN=""
    CLR_YELLOW=""
    CLR_RESET=""
fi

# ── Prerequisite definitions ─────────────────────────────────
# Each prerequisite has:
#   - An ID (used as a key)
#   - A human-readable description
#   - A check (performed by check_prereq)
#   - An optional provider (another script that can fulfil it)

# Returns space-separated prerequisite IDs for a given script.
get_prereqs_for_script() {
    local rel="$1"
    case "$rel" in
        build/build_offline_zip.sh)           echo "cmd:zip partition_index" ;;
        build/fetch_all_deps.sh)              echo "cmd:git cmd:curl cmd:unzip network" ;;
        core/anti_rollback.sh)                echo "boot_image" ;;
        core/apply_defaults.sh)               echo "device_profile partition_index" ;;
        core/boot_image.sh)                   echo "android_device" ;;
        core/candidate_entry.sh)              echo "device_profile partition_index" ;;
        core/device_profile.sh)               echo "android_device" ;;
        core/flash.sh)                        echo "root boot_image" ;;
        core/logging.sh)                      echo "" ;;
        core/magisk_patch.sh)                 echo "boot_image magisk_binary" ;;
        core/privacy.sh)                      echo "" ;;
        core/share.sh)                        echo "env_registry" ;;
        core/state_machine.sh)                echo "" ;;
        core/ux.sh)                           echo "" ;;
        magisk-module/collect.sh)             echo "root android_device env_registry" ;;
        magisk-module/customize.sh)           echo "root android_device" ;;
        magisk-module/env_detect.sh)          echo "android_device" ;;
        magisk-module/service.sh)             echo "root android_device" ;;
        magisk-module/setup_termux.sh)        echo "android_device network" ;;
        recovery-zip/collect_recovery.sh)     echo "root android_device" ;;
        pipeline/build_table.py)              echo "cmd:python3 schema" ;;
        pipeline/failure_analysis.py)         echo "cmd:python3" ;;
        pipeline/github_notify.py)            echo "cmd:python3 env_github_token" ;;
        pipeline/parse_logs.py)               echo "cmd:python3" ;;
        pipeline/parse_manifests.py)          echo "cmd:python3 schema" ;;
        pipeline/parse_pinctrl.py)            echo "cmd:python3 schema" ;;
        pipeline/parse_symbols.py)            echo "cmd:python3" ;;
        pipeline/report.py)                   echo "cmd:python3" ;;
        pipeline/unpack_images.py)            echo "cmd:python3" ;;
        pipeline/upload.py)                   echo "cmd:python3 env_github_token" ;;
        *)                                    echo "" ;;
    esac
}

# Human-readable label for a prerequisite ID.
prereq_label() {
    local prereq="$1"
    case "$prereq" in
        root)             echo "root (superuser) access" ;;
        network)          echo "network / internet access" ;;
        boot_image)       echo "boot image file (HOM_BOOT_IMG_PATH)" ;;
        magisk_binary)    echo "Magisk binary" ;;
        device_profile)   echo "device profile (core/device_profile.sh)" ;;
        env_registry)     echo "environment registry (/sdcard/hands-on-metal/env_registry.sh)" ;;
        android_device)   echo "Android device environment" ;;
        partition_index)  echo "partition index (build/partition_index.json)" ;;
        schema)           echo "database schema (schema/hardware_map.sql)" ;;
        env_github_token) echo "GITHUB_TOKEN environment variable" ;;
        cmd:*)            echo "command: ${prereq#cmd:}" ;;
        *)                echo "$prereq" ;;
    esac
}

# Check whether a prerequisite is satisfied.  Returns 0 if met.
check_prereq() {
    local prereq="$1"
    case "$prereq" in
        root)
            [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ] 2>/dev/null ;;
        network)
            # Quick connectivity probe (non-blocking)
            curl -s --connect-timeout 2 -o /dev/null https://github.com 2>/dev/null \
                || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 ;;
        boot_image)
            [ -n "${HOM_BOOT_IMG_PATH:-}" ] \
                && [ -f "${HOM_BOOT_IMG_PATH:-/nonexistent}" ] ;;
        magisk_binary)
            command -v magisk >/dev/null 2>&1 \
                || [ -f "/data/adb/magisk/magisk" ] 2>/dev/null ;;
        device_profile)
            [ -n "${HOM_DEV_MODEL:-}" ] ;;
        env_registry)
            [ -f "/sdcard/hands-on-metal/env_registry.sh" ] 2>/dev/null ;;
        android_device)
            [ -n "$(getprop ro.build.display.id 2>/dev/null || true)" ] \
                || [ -d "/data/data/com.termux" ] 2>/dev/null ;;
        partition_index)
            [ -f "$REPO_ROOT/build/partition_index.json" ] ;;
        schema)
            [ -f "$REPO_ROOT/schema/hardware_map.sql" ] ;;
        env_github_token)
            [ -n "${GITHUB_TOKEN:-}" ] ;;
        cmd:*)
            command -v "${prereq#cmd:}" >/dev/null 2>&1 ;;
        *)
            return 1 ;;
    esac
}

# Return the relative path of a script that can provide a prerequisite,
# or empty string if it must be resolved externally.
prereq_provider() {
    local prereq="$1"
    case "$prereq" in
        boot_image)       echo "core/boot_image.sh" ;;
        device_profile)   echo "core/device_profile.sh" ;;
        env_registry)     echo "magisk-module/env_detect.sh" ;;
        partition_index)  echo "build/fetch_all_deps.sh" ;;
        schema)           echo "build/fetch_all_deps.sh" ;;
        *)                echo "" ;;
    esac
}

# Check whether a script's work is already done (not needed).
is_already_done() {
    local rel="$1"
    case "$rel" in
        build/fetch_all_deps.sh)
            # Deps fetched if Magisk APK or busybox binary already present
            [ -d "$REPO_ROOT/build/magisk" ] 2>/dev/null \
                && [ -f "$REPO_ROOT/build/busybox" ] 2>/dev/null ;;
        build/build_offline_zip.sh)
            # ZIPs already built
            compgen -G "$REPO_ROOT/build/hands-on-metal-*.zip" >/dev/null 2>&1 ;;
        core/device_profile.sh)
            [ -n "${HOM_DEV_MODEL:-}" ] ;;
        core/apply_defaults.sh)
            [ -n "${HOM_DEFAULT_PATCH_TARGET:-}" ] ;;
        core/boot_image.sh)
            [ -n "${HOM_BOOT_IMG_PATH:-}" ] \
                && [ -f "${HOM_BOOT_IMG_PATH:-/nonexistent}" ] ;;
        core/anti_rollback.sh)
            [ -n "${HOM_ARB_RISK:-}" ] ;;
        core/magisk_patch.sh)
            [ -n "${HOM_PATCHED_IMG:-}" ] \
                && [ -f "${HOM_PATCHED_IMG:-/nonexistent}" ] 2>/dev/null ;;
        core/flash.sh)
            [ "${HOM_FLASH_VERIFIED:-}" = "1" ] 2>/dev/null ;;
        magisk-module/env_detect.sh)
            [ -f "/sdcard/hands-on-metal/env_registry.sh" ] 2>/dev/null ;;
        *)
            return 1 ;;
    esac
}

# ── Script index ─────────────────────────────────────────────
build_script_index() {
    SCRIPT_LABELS=()
    SCRIPT_PATHS=()
    SCRIPT_TYPES=()

    local path rel
    while IFS= read -r path; do
        rel="${path#"$REPO_ROOT"/}"
        SCRIPT_LABELS+=("$rel")
        SCRIPT_PATHS+=("$path")
        SCRIPT_TYPES+=("shell")
    done < <(find \
        "$REPO_ROOT/build" \
        "$REPO_ROOT/core" \
        "$REPO_ROOT/magisk-module" \
        "$REPO_ROOT/recovery-zip" \
        -type f -name "*.sh" | sort)

    while IFS= read -r path; do
        rel="${path#"$REPO_ROOT"/}"
        SCRIPT_LABELS+=("$rel")
        SCRIPT_PATHS+=("$path")
        SCRIPT_TYPES+=("python")
    done < <(find "$REPO_ROOT/pipeline" -maxdepth 1 -type f -name "*.py" | sort)
}

# ── Prerequisite status cache (rebuilt per print) ─────────────
# STATUS[i] = "ready" | "done" | "missing"
# MISSING_INFO[i] = human-readable string of what is missing
declare -a ITEM_STATUS=()
declare -a MISSING_INFO=()

refresh_status() {
    ITEM_STATUS=()
    MISSING_INFO=()

    local i rel prereqs prereq
    for i in "${!SCRIPT_LABELS[@]}"; do
        rel="${SCRIPT_LABELS[$i]}"

        # 1) Already done?
        if is_already_done "$rel" 2>/dev/null; then
            ITEM_STATUS+=("done")
            MISSING_INFO+=("")
            continue
        fi

        # 2) Check prerequisites
        prereqs="$(get_prereqs_for_script "$rel")"
        local missing=""
        if [ -n "$prereqs" ]; then
            for prereq in $prereqs; do
                if ! check_prereq "$prereq" 2>/dev/null; then
                    local lbl provider provider_idx
                    lbl="$(prereq_label "$prereq")"
                    provider="$(prereq_provider "$prereq")"
                    provider_idx=""
                    if [ -n "$provider" ]; then
                        # Find the menu number for the provider script
                        local j
                        for j in "${!SCRIPT_LABELS[@]}"; do
                            if [ "${SCRIPT_LABELS[$j]}" = "$provider" ]; then
                                provider_idx="$((j + 1))"
                                break
                            fi
                        done
                    fi

                    if [ -n "$provider_idx" ]; then
                        missing="${missing:+$missing; }$lbl -> run option $provider_idx ($provider)"
                    elif [ -n "$provider" ]; then
                        missing="${missing:+$missing; }$lbl -> $provider"
                    else
                        missing="${missing:+$missing; }$lbl"
                    fi
                fi
            done
        fi

        if [ -n "$missing" ]; then
            ITEM_STATUS+=("missing")
            MISSING_INFO+=("$missing")
        else
            ITEM_STATUS+=("ready")
            MISSING_INFO+=("")
        fi
    done
}

# ── Menu display ─────────────────────────────────────────────
print_menu() {
    refresh_status

    echo
    echo "hands-on-metal terminal menu"
    echo "Repository: $REPO_ROOT"
    echo
    echo "  Legend: ${CLR_LIGHT_GREEN}■${CLR_RESET} ready  ${CLR_DARK_GREEN}■${CLR_RESET} done  ${CLR_YELLOW}■${CLR_RESET} needs prerequisites"
    echo

    local i color status_char
    for i in "${!SCRIPT_LABELS[@]}"; do
        case "${ITEM_STATUS[$i]}" in
            ready)
                color="$CLR_LIGHT_GREEN"
                status_char="✓"
                ;;
            done)
                color="$CLR_DARK_GREEN"
                status_char="●"
                ;;
            missing)
                color="$CLR_YELLOW"
                status_char="✗"
                ;;
        esac

        printf "%s%2d) [%s] %s %s%s" \
            "$color" "$((i + 1))" "${SCRIPT_TYPES[$i]}" "${SCRIPT_LABELS[$i]}" "$status_char" "$CLR_RESET"

        if [ "${ITEM_STATUS[$i]}" = "missing" ]; then
            printf "\n      needs: %s" "${MISSING_INFO[$i]}"
        fi
        printf "\n"
    done

    echo
    echo " p) check prerequisites (detailed)"
    echo " r) refresh script list"
    echo " q) quit"
}

# ── Prerequisites sub-menu ───────────────────────────────────
print_prereq_submenu() {
    refresh_status

    echo
    echo "═══════════════════════════════════════════════════════"
    echo " Prerequisites Check"
    echo "═══════════════════════════════════════════════════════"
    echo

    local i rel prereqs prereq
    for i in "${!SCRIPT_LABELS[@]}"; do
        rel="${SCRIPT_LABELS[$i]}"
        prereqs="$(get_prereqs_for_script "$rel")"

        # Header color based on status
        local hdr_color
        case "${ITEM_STATUS[$i]}" in
            ready)   hdr_color="$CLR_LIGHT_GREEN" ;;
            done)    hdr_color="$CLR_DARK_GREEN" ;;
            missing) hdr_color="$CLR_YELLOW" ;;
        esac

        printf "%s%2d) %s%s" "$hdr_color" "$((i + 1))" "$rel" "$CLR_RESET"

        case "${ITEM_STATUS[$i]}" in
            ready)   echo "  ${CLR_LIGHT_GREEN}[READY]${CLR_RESET}" ;;
            done)    echo "  ${CLR_DARK_GREEN}[DONE — not needed]${CLR_RESET}" ;;
            missing) echo "  ${CLR_YELLOW}[BLOCKED]${CLR_RESET}" ;;
        esac

        if [ -z "$prereqs" ]; then
            echo "      No prerequisites (always runnable)"
        else
            for prereq in $prereqs; do
                local lbl provider provider_idx met_str
                lbl="$(prereq_label "$prereq")"
                provider="$(prereq_provider "$prereq")"
                provider_idx=""

                if [ -n "$provider" ]; then
                    local j
                    for j in "${!SCRIPT_LABELS[@]}"; do
                        if [ "${SCRIPT_LABELS[$j]}" = "$provider" ]; then
                            provider_idx="$((j + 1))"
                            break
                        fi
                    done
                fi

                if check_prereq "$prereq" 2>/dev/null; then
                    met_str="${CLR_LIGHT_GREEN}✓ met${CLR_RESET}"
                else
                    if [ -n "$provider_idx" ]; then
                        met_str="${CLR_YELLOW}✗ MISSING — run option $provider_idx ($provider)${CLR_RESET}"
                    elif [ -n "$provider" ]; then
                        met_str="${CLR_YELLOW}✗ MISSING — provided by: $provider${CLR_RESET}"
                    else
                        met_str="${CLR_YELLOW}✗ MISSING — resolve externally${CLR_RESET}"
                    fi
                fi

                echo "      • $lbl  $met_str"
            done
        fi
        echo
    done

    echo "═══════════════════════════════════════════════════════"
    echo
    read -r -p "Press Enter to return to main menu..."
}

# ── Run a selected script ────────────────────────────────────
run_selected() {
    local idx="$1"
    local script="${SCRIPT_PATHS[$idx]}"
    local kind="${SCRIPT_TYPES[$idx]}"
    local rel="${SCRIPT_LABELS[$idx]}"
    local args_array=()

    echo
    echo "Selected: $rel"
    echo "Note: enter space-separated arguments (embedded space quoting is not supported)."
    read -r -a args_array -p "Arguments (optional): "

    echo
    echo "Running..."
    (
        cd "$REPO_ROOT" || exit 1
        export HOM_DEPS_CHECKED
        if [ "$kind" = "python" ]; then
            if [ "${#args_array[@]}" -gt 0 ]; then
                python3 "$script" "${args_array[@]}"
            else
                python3 "$script"
            fi
        else
            if [ "${#args_array[@]}" -gt 0 ]; then
                bash "$script" "${args_array[@]}"
            else
                bash "$script"
            fi
        fi
    )
    local rc=$?
    echo
    echo "Exit code: $rc"
    echo
}

# ── Main loop ────────────────────────────────────────────────
main() {
    if [ ! -d "$REPO_ROOT/pipeline" ]; then
        echo "Error: pipeline directory not found in repository." >&2
        exit 1
    fi

    build_script_index

    if [ "${#SCRIPT_LABELS[@]}" -eq 0 ]; then
        echo "No scripts found." >&2
        exit 1
    fi

    while true; do
        print_menu
        read -r -p "Choose an option: " choice

        case "$choice" in
            q|Q)
                echo "Bye."
                exit 0
                ;;
            r|R)
                build_script_index
                continue
                ;;
            p|P)
                print_prereq_submenu
                continue
                ;;
            ''|*[!0-9]*)
                echo "Invalid choice."
                ;;
            *)
                if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#SCRIPT_LABELS[@]}" ]; then
                    echo "Invalid choice."
                else
                    run_selected "$((choice - 1))"
                fi
                ;;
        esac
    done
}

main "$@"
