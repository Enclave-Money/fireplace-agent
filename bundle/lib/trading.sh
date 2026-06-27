#!/usr/bin/env bash
# =============================================================================
# lib/trading.sh — `fireplace enable-trading` / `fireplace disable-trading`
# -----------------------------------------------------------------------------
# Toggles the execution-tool gate by rewriting
# mcp_servers.fireplace.tools.include in $FH/config.yaml:
#   enable  -> appends the 14 execution tools (place_*, edit_order, cancel_*,
#              redeem/merge/split_position, follow/unfollow_wallet)
#   disable -> strips them, returning to the read-only default profile.
#
# The actual YAML edit is performed by common.sh:config_set_trading (venv Python
# + ruamel/PyYAML — robust, not sed). A marker file $FH/.trading-enabled records
# the chosen state so it survives config refreshes (install/update/reset).
#
# IMPORTANT: advertising the execution tools to the model is NOT the real safety
# boundary — server-side API-key scoping is. enable-trading only un-hides the
# tools locally; the persona (SOUL.md) still requires explicit, itemized in-turn
# confirmation before any order is placed/cancelled/redeemed.
#
# Usage:  trading.sh enable|disable [--quiet]
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

MODE="${1:-}"
QUIET=0
shift || true
for arg in "$@"; do
  case "$arg" in --quiet) QUIET=1 ;; *) ;; esac
done

case "$MODE" in
  enable|disable) ;;
  *) err "Usage: trading.sh enable|disable [--quiet]"; exit 2 ;;
esac

[ -f "$CONFIG_FILE" ] || { err "config.yaml not found at $CONFIG_FILE — run 'fireplace' to set up first."; exit 1; }

if [ "$MODE" = "enable" ]; then
  if [ "$QUIET" -ne 1 ]; then
    print_banner
    warn "============================================================"
    warn " ENABLING TRADING — the agent will be able to PLACE, EDIT,"
    warn " CANCEL, REDEEM, MERGE and SPLIT positions on your account."
    warn ""
    warn " This only un-hides the execution tools locally. Your real"
    warn " protection is (1) server-side API-key scoping and (2) the"
    warn " persona's hard rule requiring explicit, itemized in-turn"
    warn " confirmation (market + side + size + price) before any order."
    warn " Run 'fireplace disable-trading' to return to read-only."
    warn "============================================================"
  fi
  if config_set_trading enable >/dev/null; then
    : > "$TRADING_MARKER"
    success "Trading ENABLED. Profile: $(trading_profile_state)."
    [ "$QUIET" -ne 1 ] && info "Approvals are set to 'manual' as defense-in-depth (see SOUL.md for the hard confirmation rule)."
  else
    err "Failed to update config.yaml. Trading NOT enabled."
    exit 1
  fi
else
  if config_set_trading disable >/dev/null; then
    rm -f "$TRADING_MARKER"
    success "Trading DISABLED — back to the read-only profile. Profile: $(trading_profile_state)."
  else
    err "Failed to update config.yaml. State unchanged."
    exit 1
  fi
fi
