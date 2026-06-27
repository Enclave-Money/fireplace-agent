#!/usr/bin/env bash
# =============================================================================
# lib/uninstall.sh — `fireplace uninstall`
# -----------------------------------------------------------------------------
# Removes the entire ~/.fireplace install and the ~/.local/bin/fireplace shim.
# Confirms first (unless --yes), and offers to back up secrets + sessions to a
# tarball before deleting.
#
# Flags:  -y | --yes     skip the confirmation prompt
#         --no-backup     do not offer/keep a backup
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

ASSUME_YES=0
DO_BACKUP=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --no-backup) DO_BACKUP=0 ;;
    *) ;;
  esac
done

print_banner
warn "This will remove the entire Fireplace install:"
warn "  • $FIREPLACE_ROOT  (venv, config, secrets, sessions, skills)"
warn "  • $SHIM_PATH  (the 'fireplace' command)"

if [ "$ASSUME_YES" -ne 1 ]; then
  printf '%b' "${C_ACCENT}?${C_RST} Type 'yes' to confirm uninstall: " >&2
  ans=""
  IFS= read -r ans < /dev/tty || ans=""
  if [ "$ans" != "yes" ]; then
    info "Aborted. Nothing was removed."
    exit 0
  fi
fi

# Offer a backup of irreplaceable state (secrets + sessions + memory).
if [ "$DO_BACKUP" -eq 1 ] && [ -d "$FH" ]; then
  do_bk="n"
  if [ "$ASSUME_YES" -eq 1 ]; then
    do_bk="y"
  else
    printf '%b' "${C_ACCENT}?${C_RST} Back up secrets & sessions first? [Y/n]: " >&2
    IFS= read -r do_bk < /dev/tty || do_bk="y"
    [ -z "$do_bk" ] && do_bk="y"
  fi
  case "$do_bk" in
    y|Y|yes|YES)
      bk="$HOME/fireplace-backup-$(date +%Y%m%d-%H%M%S).tgz"
      # Tar only the preservable, irreplaceable bits that actually exist.
      members=""
      [ -f "$FH/.env" ]      && members="$members .env"
      [ -d "$FH/sessions" ]  && members="$members sessions"
      [ -f "$FH/MEMORY.md" ] && members="$members MEMORY.md"
      [ -f "$FH/auth.json" ] && members="$members auth.json"
      [ -d "$FH/skills" ]    && members="$members skills"
      if [ -n "$members" ]; then
        # shellcheck disable=SC2086
        tar -czf "$bk" -C "$FH" $members 2>/dev/null || true
      fi
      if [ -f "$bk" ]; then
        chmod 600 "$bk" 2>/dev/null || true
        success "Backed up to $bk"
      else
        warn "Backup produced no archive (nothing to back up or tar failed)."
      fi
      ;;
    *) info "Skipping backup." ;;
  esac
fi

# Docker runtime: tear down the gateway container + runtime image (best-effort).
if [ "$FP_RUNTIME" = "docker" ] && command -v docker >/dev/null 2>&1; then
  info "Removing Docker artifacts (gateway container + runtime image)…"
  docker rm -f "$FP_GATEWAY_CONTAINER" >/dev/null 2>&1 || true
  docker image rm "$FP_IMAGE" >/dev/null 2>&1 || true
fi

info "Removing $FIREPLACE_ROOT …"
rm -rf "$FIREPLACE_ROOT"
info "Removing shim $SHIM_PATH …"
rm -f "$SHIM_PATH"

success "Fireplace has been uninstalled."
info "Note: a PATH line added to your shell rc (if any) was left in place; remove it by hand if desired."
