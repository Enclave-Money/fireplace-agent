#!/usr/bin/env bash
# =============================================================================
# Fireplace Agent — common.sh
# -----------------------------------------------------------------------------
# Shared library sourced by the lifecycle scripts (wizard.sh, lib/update.sh,
# lib/uninstall.sh, lib/doctor.sh, lib/trading.sh). It defines:
#   - canonical on-disk paths (FIREPLACE_ROOT / $FH home / venv / bundle)
#   - the HERMES_HOME export (isolation: every child must inherit it)
#   - colored logging (info/warn/err/success) + the Fireplace banner
#   - small helpers: require_cmd, url_status, mcp_probe, render_config,
#     config_set_trading (the YAML edit used by enable/disable-trading)
#
# It is intentionally side-effect-light: sourcing it sets variables, exports
# HERMES_HOME, and defines functions. It does NOT mutate any files on its own.
#
# Compatibility note: targets bash 3.2 (macOS system bash). No `declare -n`,
# associative arrays, or ${var^^} are used.
# =============================================================================

# ----- canonical paths -------------------------------------------------------
# FIREPLACE_ROOT can be overridden for tests; everything else derives from it.
: "${FIREPLACE_ROOT:=$HOME/.fireplace}"

FH="$FIREPLACE_ROOT/home"            # == HERMES_HOME for this install
VENV="$FIREPLACE_ROOT/venv"          # dedicated uv venv with pinned Hermes
BUNDLE="$FIREPLACE_ROOT/bundle"      # installed copy of the product bundle
ENV_FILE="$FH/.env"                  # secrets (chmod 600)
CONFIG_FILE="$FH/config.yaml"        # rendered Hermes config
SOUL_FILE="$FH/SOUL.md"              # Fireplace persona
SKINS_DIR="$FH/skins"               # custom skin(s)
FP_SKILLS_DIR="$FH/fireplace-skills" # shipped read-only skills (installer-owned)
NO_BUNDLED_SKILLS_MARKER="$FH/.no-bundled-skills"
TRADING_MARKER="$FH/.trading-enabled" # presence => trading profile is active
PROVIDER_PROFILE="$FH/.llm-provider"  # LLM provider choice (sourceable; written by wizard)
SHIM_PATH="$HOME/.local/bin/fireplace"

# Version stamps (single source of truth: files under FIREPLACE_ROOT; fall back
# to the compiled-in constants when those files are not present yet).
BUNDLE_VERSION="$(cat "$FIREPLACE_ROOT/VERSION" 2>/dev/null || echo "0.1.0")"
ENGINE_VERSION_REF="$(cat "$FIREPLACE_ROOT/ENGINE_VERSION" 2>/dev/null || echo "v2026.6.19")"

# Product constants.
BRAND="Fireplace"
AGENT_NAME="Fireplace Agent"
ACCENT_HEX="#FF6A3D"
MCP_URL="https://data.fireplace.gg/mcp"
INSTALL_URL="https://get.fireplace.gg/install.sh"
HERMES_DIST_FALLBACK="0.17.0"        # PyPI pin used if the git ref install fails

# The 14 execution (write) tools. The read-only default omits them entirely;
# `fireplace enable-trading` appends them to mcp_servers.fireplace.tools.include.
FP_EXEC_TOOLS="place_limit_order place_market_order place_stop_limit place_stop_market place_iceberg place_sticky_bbo edit_order cancel_order cancel_all_orders redeem_positions merge_positions split_position follow_wallet unfollow_wallet"

# ----- LLM provider presets --------------------------------------------------
# The supported BYO LLM providers. Provider ids + env-var names are from Hermes'
# PROVIDER_REGISTRY (hermes_cli/auth.py): openrouter / anthropic / openai are all
# auth_type "api_key". For each we ship a sensible default + a cheap auxiliary
# model id; the user can override the main model in the wizard.
#
# llm_preset <id> echoes five '|'-separated fields:
#   PROVIDER|API_KEY_VAR|MODEL_DEFAULT|AUX_MODEL|VALIDATE_KIND
# Unknown ids fall back to openrouter (also the no-profile default).
llm_preset() {
  case "$1" in
    anthropic) printf 'anthropic|ANTHROPIC_API_KEY|claude-sonnet-4-5|claude-haiku-4-5|anthropic\n' ;;
    openai)    printf 'openai|OPENAI_API_KEY|gpt-4.1|gpt-4.1-mini|openai\n' ;;
    *)         printf 'openrouter|OPENROUTER_API_KEY|anthropic/claude-sonnet-4.5|anthropic/claude-haiku-4.5|openrouter\n' ;;
  esac
}

# ----- isolation: export HERMES_HOME for this process and all children -------
# Documented Hermes footgun #18594: HERMES_HOME is read at import from 30+ sites
# and is NOT auto-propagated to subprocesses. Exporting it here guarantees every
# tool we spawn (hermes, gateway, cron, telegram) lands in the isolated home.
export FIREPLACE_ROOT
export HERMES_HOME="$FH"

# ----- runtime: docker (default, sandboxed) or native (venv fallback) ---------
# install.sh stamps the chosen runtime in $FIREPLACE_ROOT/.runtime. Absent =>
# native (back-compat). The container image bundles only the Hermes engine; all
# Fireplace config/skin/skills/secrets/state live in $FH, mounted at /data.
FP_RUNTIME="$(cat "$FIREPLACE_ROOT/.runtime" 2>/dev/null || echo native)"
FP_IMAGE="${FP_IMAGE:-fireplace-agent:${BUNDLE_VERSION}}"
FP_GATEWAY_CONTAINER="fireplace-gateway"

# docker_daemon_ok -> 0 if the docker CLI exists AND its daemon is reachable.
docker_daemon_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# Every container invocation mounts $FH at /data (= HERMES_HOME in the image) and
# passes the secrets file + HERMES_UID/GID (so Hermes can chown state back to the
# host user on Linux). HERMES_CONTAINER is baked into the image.
# agent_exec <hermes args...> : run the agent INTERACTIVELY (execs; replaces us).
# Docker runtime -> ephemeral container with a TTY; native -> the venv hermes.
agent_exec() {
  if [ "$FP_RUNTIME" = "docker" ]; then
    docker_daemon_ok || { err "Docker isn't running. Start Docker Desktop and retry (or reinstall with FIREPLACE_RUNTIME=native)."; exit 1; }
    local ti="-i"; [ -t 0 ] && [ -t 1 ] && ti="-it"
    exec docker run --rm "$ti" \
      -v "$FH:/data" --env-file "$ENV_FILE" \
      -e HERMES_UID="$(id -u)" -e HERMES_GID="$(id -g)" \
      "$FP_IMAGE" "$@"
  else
    [ -x "$VENV/bin/hermes" ] || { err "Hermes binary missing at $VENV/bin/hermes — run 'fireplace update'."; exit 1; }
    export VIRTUAL_ENV="$VENV"; PATH="$VENV/bin:$PATH"; export PATH
    exec "$VENV/bin/hermes" "$@"
  fi
}

# agent_run <hermes args...> : NON-interactive run (no TTY); returns the exit
# status and streams output. Used by doctor. Does not exec.
agent_run() {
  if [ "$FP_RUNTIME" = "docker" ]; then
    docker_daemon_ok || return 3
    docker run --rm \
      -v "$FH:/data" --env-file "$ENV_FILE" \
      -e HERMES_UID="$(id -u)" -e HERMES_GID="$(id -g)" \
      "$FP_IMAGE" "$@"
  else
    [ -x "$VENV/bin/hermes" ] || return 3
    "$VENV/bin/hermes" "$@"
  fi
}

# ----- logging ---------------------------------------------------------------
# Colors only on a TTY; #FF6A3D maps closest to 256-color index 209 (orange).
if [ -t 2 ]; then
  C_ACCENT='\033[38;5;209m'
  C_DIM='\033[2m'
  C_OK='\033[32m'
  C_WARN='\033[33m'
  C_ERR='\033[31m'
  C_RST='\033[0m'
else
  C_ACCENT=''; C_DIM=''; C_OK=''; C_WARN=''; C_ERR=''; C_RST=''
fi

info()    { printf '%b\n' "${C_ACCENT}[fireplace]${C_RST} $*" >&2; }
success() { printf '%b\n' "${C_OK}[fireplace] ✓${C_RST} $*" >&2; }
warn()    { printf '%b\n' "${C_WARN}[fireplace] !${C_RST} $*" >&2; }
err()     { printf '%b\n' "${C_ERR}[fireplace] ✗${C_RST} $*" >&2; }

# Print the Fireplace block wordmark (matches the TUI skin's banner_logo). On a
# TTY it uses a warm top->bottom truecolor gradient; otherwise plain monochrome.
print_banner() {
  printf '\n' >&2
  if [ -t 2 ]; then
    printf '\033[1;38;2;255;194;75m%s\033[0m\n' '███████╗██╗██████╗ ███████╗██████╗ ██╗      █████╗  ██████╗███████╗' >&2
    printf '\033[1;38;2;255;170;60m%s\033[0m\n' '██╔════╝██║██╔══██╗██╔════╝██╔══██╗██║     ██╔══██╗██╔════╝██╔════╝' >&2
    printf '\033[1;38;2;255;142;43m%s\033[0m\n' '█████╗  ██║██████╔╝█████╗  ██████╔╝██║     ███████║██║     █████╗  ' >&2
    printf '\033[1;38;2;255;115;34m%s\033[0m\n' '██╔══╝  ██║██╔══██╗██╔══╝  ██╔═══╝ ██║     ██╔══██║██║     ██╔══╝  ' >&2
    printf '\033[1;38;2;255;94;26m%s\033[0m\n'  '██║     ██║██║  ██║███████╗██║     ███████╗██║  ██║╚██████╗███████╗' >&2
    printf '\033[1;38;2;232;73;12m%s\033[0m\n'  '╚═╝     ╚═╝╚═╝  ╚═╝╚══════╝╚═╝     ╚══════╝╚═╝  ╚═╝ ╚═════╝╚══════╝' >&2
  else
    cat >&2 <<'BANNER'
███████╗██╗██████╗ ███████╗██████╗ ██╗      █████╗  ██████╗███████╗
██╔════╝██║██╔══██╗██╔════╝██╔══██╗██║     ██╔══██╗██╔════╝██╔════╝
█████╗  ██║██████╔╝█████╗  ██████╔╝██║     ███████║██║     █████╗
██╔══╝  ██║██╔══██╗██╔══╝  ██╔═══╝ ██║     ██╔══██║██║     ██╔══╝
██║     ██║██║  ██║███████╗██║     ███████╗██║  ██║╚██████╗███████╗
╚═╝     ╚═╝╚═╝  ╚═╝╚══════╝╚═╝     ╚══════╝╚═╝  ╚═╝ ╚═════╝╚══════╝
BANNER
  fi
  printf '\n' >&2
}

# ----- small helpers ---------------------------------------------------------

# require_cmd <name>  -> 0 if on PATH, else err + return 1.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; return 1; }
}

# fireplace_python -> absolute path to the venv interpreter (echoed).
fireplace_python() {
  if [ -x "$VENV/bin/python" ]; then
    printf '%s\n' "$VENV/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  else
    return 1
  fi
}

# url_status <url> [timeout] -> echoes the HTTP status code (or 000 on error).
url_status() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time "${2:-20}" "$1" 2>/dev/null || echo "000"
}

# mcp_probe <bearer-key>  -> 0 if the Fireplace MCP answers tools/list with 200
# and a tools/result payload. Param-free, auth-aware reachability check used by
# the wizard (key validation) and doctor (health check).
mcp_probe() {
  local key="$1" out code body
  out="$(curl -sS --max-time 25 \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    -w $'\n%{http_code}' "$MCP_URL" 2>/dev/null)" || return 1
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  [ "$code" = "200" ] || return 1
  case "$body" in
    *'"tools"'*|*'"result"'*) return 0 ;;
    *) return 1 ;;
  esac
}

# render_config -> write $FH/config.yaml from the bundled template.
# The template hardcodes every non-secret value (incl. the real MCP URL). The
# only substitutions are the four @@FP_*@@ provider tokens (resolved from the
# $FH/.llm-provider profile, defaulting to OpenRouter); ${SECRET} vars and
# ${HERMES_HOME} are left LITERAL for Hermes to resolve at runtime. We use a
# token sed (not envsubst) precisely so the secret placeholders stay literal.
# After writing, if the trading profile was previously enabled, re-apply it
# (config refreshes default to read-only).
render_config() {
  local tpl="${1:-$BUNDLE/config.template.yaml}"
  [ -f "$tpl" ] || { err "Config template not found: $tpl"; return 1; }
  mkdir -p "$FH"

  # Provider profile (written by the wizard); default to the OpenRouter preset so
  # an un-onboarded / test render still produces a valid config.
  local FP_PROVIDER FP_API_KEY_VAR FP_MODEL_DEFAULT FP_AUX_MODEL
  if [ -f "$PROVIDER_PROFILE" ]; then
    # shellcheck disable=SC1090
    . "$PROVIDER_PROFILE"
  fi
  local prov var mdef aux
  prov="${FP_PROVIDER:-openrouter}"
  var="${FP_API_KEY_VAR:-OPENROUTER_API_KEY}"
  mdef="${FP_MODEL_DEFAULT:-anthropic/claude-sonnet-4.5}"
  aux="${FP_AUX_MODEL:-anthropic/claude-haiku-4.5}"

  # Slugs may contain '/', so use '|' as the sed delimiter (slugs never contain it).
  sed -e "s|@@FP_PROVIDER@@|${prov}|g" \
      -e "s|@@FP_API_KEY_VAR@@|${var}|g" \
      -e "s|@@FP_MODEL_DEFAULT@@|${mdef}|g" \
      -e "s|@@FP_AUX_MODEL@@|${aux}|g" \
      "$tpl" > "$CONFIG_FILE" || { err "Failed to render $CONFIG_FILE"; return 1; }

  if [ -f "$TRADING_MARKER" ]; then
    config_set_trading enable >/dev/null 2>&1 || \
      warn "Could not re-apply trading profile after config refresh."
  fi
}

# write_provider_profile <provider> <api_key_var> <model_default> <aux_model>
# Persists the LLM provider choice (sourceable KEY=VALUE) so render_config and
# doctor stay provider-aware across update/reset. Survives config refreshes.
write_provider_profile() {
  mkdir -p "$FH"
  {
    printf 'FP_PROVIDER=%s\n' "$1"
    printf 'FP_API_KEY_VAR=%s\n' "$2"
    printf 'FP_MODEL_DEFAULT=%s\n' "$3"
    printf 'FP_AUX_MODEL=%s\n' "$4"
  } > "$PROVIDER_PROFILE"
}

# llm_key_var -> echoes the env-var name holding the LLM key for the chosen
# provider (from the profile), defaulting to OPENROUTER_API_KEY.
llm_key_var() {
  local FP_API_KEY_VAR=""
  # shellcheck disable=SC1090
  [ -f "$PROVIDER_PROFILE" ] && . "$PROVIDER_PROFILE"
  printf '%s\n' "${FP_API_KEY_VAR:-OPENROUTER_API_KEY}"
}

# config_set_trading <enable|disable>
# Robustly edits mcp_servers.fireplace.tools.include in $FH/config.yaml with
# Python (ruamel.yaml to preserve comments, else PyYAML). On 'enable' it appends
# the 14 execution tools (de-duped); on 'disable' it strips them. Idempotent.
# Runtime-aware: the Docker runtime has NO host venv (and a stock host python3
# usually lacks PyYAML), so the edit runs INSIDE the image (which ships Python +
# Hermes' YAML deps), against the config at /data/config.yaml in the mounted volume.
config_set_trading() {
  local mode="$1" prog
  case "$mode" in enable|disable) ;; *) err "config_set_trading: bad mode '$mode'"; return 2 ;; esac
  [ -f "$CONFIG_FILE" ] || { err "config.yaml not found at $CONFIG_FILE"; return 1; }

  # The program reads itself from stdin ('python - <path> <mode>'), so it works
  # identically whether run by the host venv or the container's interpreter.
  prog="$(cat <<'PYEOF'
import os, sys

path, mode = sys.argv[1], sys.argv[2]
exec_tools = os.environ.get("EXEC_TOOLS", "").split()

# Prefer ruamel (round-trips comments/quotes); fall back to PyYAML.
dumper = None
data = None
try:
    from ruamel.yaml import YAML
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    with open(path) as fh:
        data = yaml.load(fh)
    dumper = ("ruamel", yaml)
except Exception:
    import yaml as pyyaml
    with open(path) as fh:
        data = pyyaml.safe_load(fh)
    dumper = ("pyyaml", pyyaml)

try:
    srv = data["mcp_servers"]["fireplace"]
except Exception:
    sys.stderr.write("config.yaml: mcp_servers.fireplace not found\n")
    sys.exit(3)

tools = srv.get("tools")
if tools is None:
    tools = {}
    srv["tools"] = tools

include = tools.get("include") or []
# Always strip exec tools first so the op is idempotent and order-stable.
base = [t for t in include if t not in exec_tools]
if mode == "enable":
    base = list(base) + list(exec_tools)
tools["include"] = base

kind, mod = dumper
with open(path, "w") as fh:
    if kind == "ruamel":
        mod.dump(data, fh)
    else:
        mod.safe_dump(data, fh, sort_keys=False, default_flow_style=False)
print("ok")
PYEOF
)"

  if [ "$FP_RUNTIME" = "docker" ]; then
    docker_daemon_ok || { err "Docker isn't running; cannot change the trading profile. Start Docker Desktop and retry."; return 1; }
    # --user keeps the rewritten config owned by the host user (not root); the
    # image's site-packages are world-readable, and /data is the mounted volume.
    printf '%s' "$prog" | docker run --rm -i \
      --user "$(id -u):$(id -g)" \
      -e EXEC_TOOLS="$FP_EXEC_TOOLS" \
      -v "$FH:/data" \
      --entrypoint /opt/hermes/bin/python \
      "$FP_IMAGE" - /data/config.yaml "$mode"
  else
    local py
    py="$(fireplace_python)" || { err "No Python interpreter available."; return 1; }
    printf '%s' "$prog" | EXEC_TOOLS="$FP_EXEC_TOOLS" "$py" - "$CONFIG_FILE" "$mode"
  fi
}

# trading_profile_state -> echoes "trading" or "read-only" based on whether any
# execution tool is currently present in the config include list.
trading_profile_state() {
  if [ -f "$CONFIG_FILE" ] && grep -qE '^[[:space:]]*-[[:space:]]+place_(limit|market)_order([[:space:]]|$)' "$CONFIG_FILE"; then
    printf 'trading\n'
  else
    printf 'read-only\n'
  fi
}
