#!/usr/bin/env bash
# setup.sh
# ============================================================
# hands-on-metal — One-Step Bootstrap
#
# Downloads (clones) the full repository, verifies host-side
# dependencies, fetches all binaries, and builds the flashable
# ZIPs in one shot.
#
# Usage (run from anywhere):
#   curl -fsSL https://raw.githubusercontent.com/mikethi/hands-on-metal/main/setup.sh | bash
#
# Or clone first and run locally:
#   bash setup.sh
#
# The script is safe to re-run — it skips steps that are
# already complete (existing clone, existing binaries, etc.).
# ============================================================

set -e

# ── git is needed to clone — check before anything else ──────
if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is not installed." >&2
    echo "  Debian / Ubuntu : sudo apt install git" >&2
    echo "  Termux          : pkg install git"      >&2
    echo "  Fedora          : sudo dnf install git"  >&2
    echo "  Arch / Manjaro  : sudo pacman -S git"    >&2
    echo "  macOS           : xcode-select --install" >&2
    exit 1
fi

# ── If we are already inside the repo, use it in-place ────────
if [ -f "check_deps.sh" ] && [ -d "build" ] && [ -f "build/fetch_all_deps.sh" ]; then
    echo "Running inside an existing hands-on-metal checkout."
else
    if [ -d "hands-on-metal" ]; then
        echo "Directory 'hands-on-metal' already exists — pulling latest..."
        git -C hands-on-metal pull --ff-only || true
    else
        git clone https://github.com/mikethi/hands-on-metal.git
    fi
    cd hands-on-metal
fi

# ── Verify host tools (optional — fetch_all_deps.sh runs it too) ─
bash check_deps.sh

# ── Fetch binaries + build flashable ZIPs ─────────────────────
bash build/fetch_all_deps.sh
