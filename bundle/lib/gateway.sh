#!/usr/bin/env bash
# =============================================================================
# lib/gateway.sh — `fireplace gateway [start|stop|restart|logs|status]`
# -----------------------------------------------------------------------------
# Manages the Telegram (and friends) gateway bot.
#
#   docker runtime : runs the gateway as a managed, auto-restarting detached
#                    container named `fireplace-gateway` (the user never types a
#                    docker command). start/stop/restart/logs/status wrap it.
#   native runtime : `start` runs `hermes gateway` in the FOREGROUND (Ctrl-C to
#                    stop); the service subcommands don't apply.
#
# `fireplace gateway setup` and any other gateway subcommand are NOT handled here
# — the shim routes those to an interactive agent run (pairing, etc.).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

action="${1:-start}"

# Telegram needs a bot token; warn early if it isn't configured.
_warn_if_no_telegram() {
  if [ -f "$ENV_FILE" ] && ! grep -q '^TELEGRAM_BOT_TOKEN=..*' "$ENV_FILE"; then
    warn "No TELEGRAM_BOT_TOKEN in $ENV_FILE — add one with 'fireplace reset' (or pair another platform)."
  fi
}

# ----- native runtime: foreground only ---------------------------------------
if [ "$FP_RUNTIME" != "docker" ]; then
  case "$action" in
    start)
      _warn_if_no_telegram
      [ -x "$VENV/bin/hermes" ] || { err "Engine is missing — run 'fireplace update'."; exit 1; }
      info "Starting the gateway in the foreground (native runtime). Ctrl-C to stop."
      export VIRTUAL_ENV="$VENV"; PATH="$VENV/bin:$PATH"; export PATH
      exec "$VENV/bin/hermes" gateway ;;
    stop|restart|logs|status)
      err "'gateway $action' is only available with the Docker runtime."
      err "On the native runtime the gateway runs in the foreground (just 'fireplace gateway')."
      exit 2 ;;
    *) err "Unknown gateway action: $action"; exit 2 ;;
  esac
fi

# ----- docker runtime: managed detached service ------------------------------
docker_daemon_ok || { err "Docker isn't running. Start Docker Desktop and retry."; exit 1; }

_running() { docker ps --filter "name=^/${FP_GATEWAY_CONTAINER}$" --format '{{.Names}}' 2>/dev/null | grep -q "$FP_GATEWAY_CONTAINER"; }
_exists()  { docker ps -a --filter "name=^/${FP_GATEWAY_CONTAINER}$" --format '{{.Names}}' 2>/dev/null | grep -q "$FP_GATEWAY_CONTAINER"; }

gw_start() {
  [ -f "$ENV_FILE" ] || { err "Not onboarded yet — run 'fireplace' first."; exit 1; }
  _warn_if_no_telegram
  if _running; then
    info "Gateway already running. Logs: fireplace gateway logs"
    return 0
  fi
  _exists && docker rm -f "$FP_GATEWAY_CONTAINER" >/dev/null 2>&1 || true
  info "Starting the gateway service (container '$FP_GATEWAY_CONTAINER', auto-restart)…"
  docker run -d \
    --name "$FP_GATEWAY_CONTAINER" \
    --restart unless-stopped \
    -v "$FH:/data" \
    --env-file "$ENV_FILE" \
    -e HERMES_UID="$(id -u)" -e HERMES_GID="$(id -g)" \
    "$FP_IMAGE" gateway >/dev/null \
    || { err "Failed to start the gateway container."; exit 1; }
  success "Gateway is up. Follow logs with: fireplace gateway logs   (stop: fireplace gateway stop)"
}

case "$action" in
  start)   gw_start ;;
  stop)
    if _exists; then docker rm -f "$FP_GATEWAY_CONTAINER" >/dev/null 2>&1 && success "Gateway stopped." || err "Could not stop the gateway."
    else info "Gateway is not running."; fi ;;
  restart) docker rm -f "$FP_GATEWAY_CONTAINER" >/dev/null 2>&1 || true; gw_start ;;
  logs)    _exists || { err "Gateway container does not exist (start it with 'fireplace gateway')."; exit 1; }; exec docker logs -f "$FP_GATEWAY_CONTAINER" ;;
  status)
    if _running; then success "Gateway is RUNNING."; docker ps --filter "name=^/${FP_GATEWAY_CONTAINER}$" --format '  {{.Names}}  {{.Status}}'
    elif _exists; then warn "Gateway container exists but is STOPPED.";
    else info "Gateway is not set up (run 'fireplace gateway')."; fi ;;
  *) err "Unknown gateway action: $action (use start|stop|restart|logs|status)"; exit 2 ;;
esac
