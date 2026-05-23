#!/usr/bin/env bash
# =============================================================================
# XHTTP-Wasmer – Deploy-Ubuntu.sh
# Main deployment script (called by install.sh after repo clone)
#
# Copyright (C) 2025 – adapted from avacocloud/XHTTP-Installer (GPL-3.0)
# Build: avc-7f3a92e1-2025-wasmer
# =============================================================================
# This file simply delegates to install.sh so that the repo structure
# mirrors the original XHTTP-Installer project layout.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/install.sh" "$@"
