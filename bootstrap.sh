#!/usr/bin/env bash
# =============================================================================
# XHTTP-Wasmer Bootstrap (one-liner entry point)
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/behbahani-trader/xhttp-wasmer-installer/main/bootstrap.sh)
#
# Build: avc-7f3a92e1-2025-wasmer
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'

info() { echo -e "${CYAN}  --> ${RESET}$*"; }
ok()   { echo -e "${GREEN}  ✔  ${RESET}$*"; }
warn() { echo -e "\033[1;33m  !  ${RESET}$*"; }
die()  { echo -e "${RED}  ✘  ${RESET}$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash <(curl ...)"

BUILD_ID="avc-7f3a92e1-2025-wasmer"
REPO_URL="https://github.com/behbahani-trader/xhttp-wasmer-installer"
INSTALL_DIR="/root/XHTTP-Wasmer"

# Install git if missing
if ! command -v git &>/dev/null; then
    info "Installing git…"
    apt-get update -qq && apt-get install -y -qq git
fi
ok "git available"

# Clone or update repository
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing installation…"
    git -C "$INSTALL_DIR" pull --quiet
    ok "Repository updated"
else
    info "Cloning XHTTP-Wasmer repository…"
    git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR" 2>/dev/null \
        || { warn "Clone failed — running from current directory"; INSTALL_DIR="$(pwd)"; }
    ok "Repository ready"
fi

info "Build ID: $BUILD_ID"

# Hand off to main installer
chmod +x "$INSTALL_DIR/install.sh"
exec bash "$INSTALL_DIR/install.sh" "$@"
