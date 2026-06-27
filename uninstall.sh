#!/usr/bin/env bash
# =============================================================================
# Fireplace Agent — standalone uninstaller
# -----------------------------------------------------------------------------
# Same behavior as `fireplace uninstall`. If a Fireplace install is present, this
# delegates to its bundled lib/uninstall.sh (so the logic lives in one place);
# otherwise it performs a self-contained removal.
#
# Usage:  bash uninstall.sh [-y|--yes] [--no-backup]
# =============================================================================
set -euo pipefail

FIREPLACE_ROOT="${FIREPLACE_ROOT:-$HOME/.fireplace}"
LIB_UNINSTALL="$FIREPLACE_ROOT/bundle/lib/uninstall.sh"
SHIM_PATH="$HOME/.local/bin/fireplace"

if [ -f "$LIB_UNINSTALL" ]; then
  exec bash "$LIB_UNINSTALL" "$@"
fi

# ----- self-contained fallback (no installed bundle to delegate to) ----------
if [ -t 2 ]; then R='\033[31m'; G='\033[32m'; Y='\033[33m'; Z='\033[0m'
else R=''; G=''; Y=''; Z=''; fi
info()    { printf '%b\n' "${Y}[fireplace]${Z} $*" >&2; }
success() { printf '%b\n' "${G}[fireplace] ✓${Z} $*" >&2; }

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in -y|--yes) ASSUME_YES=1 ;; *) ;; esac
done

info "This will remove $FIREPLACE_ROOT and $SHIM_PATH."
if [ "$ASSUME_YES" -ne 1 ]; then
  printf '%b' "${R}?${Z} Type 'yes' to confirm uninstall: " >&2
  ans=""
  IFS= read -r ans < /dev/tty || ans=""
  [ "$ans" = "yes" ] || { info "Aborted. Nothing was removed."; exit 0; }
fi

rm -rf "$FIREPLACE_ROOT"
rm -f "$SHIM_PATH"
success "Fireplace has been uninstalled."
