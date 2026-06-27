#!/usr/bin/env bash
# =============================================================================
# wizard.sh — Fireplace Agent onboarding
# -----------------------------------------------------------------------------
# Runs on first launch (no $FH/.env) or via `fireplace reset` (--reset). It
# collects, VALIDATES-BEFORE-SAVING, and persists three secrets, then refreshes
# config.yaml from the template (so Hermes' own first-run wizard stays
# suppressed) and execs into the branded Hermes TUI.
#
#   1. Fireplace API key   (REQUIRED) — validated live against the Fireplace MCP
#   2. Telegram bot token  (OPTIONAL) — validated via getMe if provided
#   3. LLM provider + key  (REQUIRED) — pick OpenRouter / Anthropic / OpenAI, then
#                                       validate the key against that provider's API
#
# Secrets are written to $FH/.env (chmod 600, ASCII). The LLM key is stored under
# the provider's env-var name (OPENROUTER_API_KEY / ANTHROPIC_API_KEY /
# OPENAI_API_KEY) and the choice is recorded in $FH/.llm-provider so render_config
# and doctor stay provider-aware. With --reset, an existing .env is first backed
# up to .env.bak.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

RESET=0
TEST_MODE=0
[ "${FIREPLACE_TEST_MODE:-0}" = "1" ] && TEST_MODE=1
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    --test|--skip-validation) TEST_MODE=1 ;;
    *) ;;
  esac
done

# ----- non-interactive test mode (CI hook; see test/smoke.sh contract) -------
# Take the three keys from the environment, SKIP all live validation, write
# $FH/.env (chmod 600) + render $FH/config.yaml, then exit 0 WITHOUT exec'ing
# hermes. Required vars: FIREPLACE_API_KEY, OPENROUTER_API_KEY. Optional:
# TELEGRAM_BOT_TOKEN.
if [ "$TEST_MODE" -eq 1 ]; then
  mkdir -p "$FH"
  FP_KEY="${FIREPLACE_API_KEY:-}"
  OR_KEY="${OPENROUTER_API_KEY:-}"
  TG_KEY="${TELEGRAM_BOT_TOKEN:-}"
  [ -n "$FP_KEY" ] || { err "test mode: FIREPLACE_API_KEY is required in the environment."; exit 1; }
  [ -n "$OR_KEY" ] || { err "test mode: OPENROUTER_API_KEY is required in the environment."; exit 1; }
  umask 077
  {
    printf 'OPENROUTER_API_KEY=%s\n' "$OR_KEY"
    printf 'FIREPLACE_API_KEY=%s\n' "$FP_KEY"
    [ -n "$TG_KEY" ] && printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TG_KEY"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  render_config || { err "test mode: failed to render config.yaml from template."; exit 1; }
  success "test mode: wrote $ENV_FILE (chmod 600) and rendered $CONFIG_FILE (no agent launch)."
  exit 0
fi

# __VALUE is the out-parameter set by read_validated (avoids bash-4 namerefs).
__VALUE=""

# read_validated <prompt> <validator-fn> <required:yes|no>
# Reads a secret (no echo), runs <validator-fn> against it, retries up to 3x.
# Sets __VALUE on success ("" for a skipped optional field). Returns non-zero
# only when a REQUIRED field cannot be validated within the retry cap.
read_validated() {
  local prompt="$1" validator="$2" required="$3"
  local attempts=0 max=3 val
  __VALUE=""
  while : ; do
    printf '%b' "${C_ACCENT}?${C_RST} $prompt " >&2
    IFS= read -r -s val < /dev/tty || val=""
    printf '\n' >&2
    if [ -z "$val" ]; then
      if [ "$required" = "no" ]; then
        return 0
      fi
      warn "This value is required."
      attempts=$((attempts + 1))
      [ "$attempts" -ge "$max" ] && { err "No value provided after $max attempts."; return 1; }
      continue
    fi
    printf '%b' "${C_DIM}  validating…${C_RST}\n" >&2
    if "$validator" "$val"; then
      success "validated."
      __VALUE="$val"
      return 0
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max" ]; then
      err "Validation failed after $max attempts."
      return 1
    fi
    warn "Validation failed — please re-enter (attempt $attempts/$max)."
  done
}

# --- validators (each takes the candidate secret, returns 0 = valid) ---------

validate_fireplace_key() {
  # A 200 tools/list with a tools/result array == a valid Fireplace MCP bearer.
  mcp_probe "$1"
}

validate_openrouter_key() {
  # GET /api/v1/key returns 200 for a valid key, 401 otherwise.
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 \
    -H "Authorization: Bearer $1" \
    "https://openrouter.ai/api/v1/key" 2>/dev/null || echo "000")"
  [ "$code" = "200" ]
}

validate_anthropic_key() {
  # GET /v1/models returns 200 for a valid key (x-api-key auth + version header).
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 \
    -H "x-api-key: $1" -H "anthropic-version: 2023-06-01" \
    "https://api.anthropic.com/v1/models" 2>/dev/null || echo "000")"
  [ "$code" = "200" ]
}

validate_openai_key() {
  # GET /v1/models returns 200 for a valid key, 401 otherwise.
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 25 \
    -H "Authorization: Bearer $1" \
    "https://api.openai.com/v1/models" 2>/dev/null || echo "000")"
  [ "$code" = "200" ]
}

# validate_llm_key dispatches to the validator for the provider chosen in the
# wizard (LLM_KIND is set by choose_provider before this is used).
LLM_KIND="openrouter"
validate_llm_key() {
  case "$LLM_KIND" in
    anthropic) validate_anthropic_key "$1" ;;
    openai)    validate_openai_key "$1" ;;
    *)         validate_openrouter_key "$1" ;;
  esac
}

# choose_provider -> interactive menu; echoes the provider id (openrouter default).
choose_provider() {
  local sel
  {
    printf '\n'
    printf '%b\n' "  ${C_ACCENT}1${C_RST}) OpenRouter   — one key, routes to most models (default)"
    printf '%b\n' "  ${C_ACCENT}2${C_RST}) Anthropic    — your Anthropic API key (console.anthropic.com)"
    printf '%b\n' "  ${C_ACCENT}3${C_RST}) OpenAI       — your OpenAI API key (platform.openai.com; NOT a ChatGPT login)"
  } >&2
  printf '%b' "${C_ACCENT}?${C_RST} Choose your LLM provider [1-3, Enter=1]: " >&2
  IFS= read -r sel < /dev/tty || sel=""
  case "$sel" in
    2) printf 'anthropic\n' ;;
    3) printf 'openai\n' ;;
    *) printf 'openrouter\n' ;;
  esac
}

# read_optional <prompt> <default>  -> echoes a plain (visible) line, default on Enter.
read_optional() {
  local prompt="$1" default="$2" val
  printf '%b' "${C_ACCENT}?${C_RST} $prompt [${C_DIM}${default}${C_RST}]: " >&2
  IFS= read -r val < /dev/tty || val=""
  [ -n "$val" ] && printf '%s\n' "$val" || printf '%s\n' "$default"
}

validate_telegram_token() {
  # getMe returns {"ok":true,...} for a valid bot token.
  local body
  body="$(curl -sS --max-time 20 "https://api.telegram.org/bot$1/getMe" 2>/dev/null || echo "")"
  case "$body" in *'"ok":true'*) return 0 ;; *) return 1 ;; esac
}

# --- main --------------------------------------------------------------------

print_banner
info "Welcome to the $AGENT_NAME setup."
require_cmd curl || exit 1

mkdir -p "$FH"

# On --reset, preserve the prior secrets file for safety.
if [ "$RESET" -eq 1 ] && [ -f "$ENV_FILE" ]; then
  cp "$ENV_FILE" "$ENV_FILE.bak"
  chmod 600 "$ENV_FILE.bak" 2>/dev/null || true
  info "Backed up existing secrets to $ENV_FILE.bak"
fi

# 1. Fireplace API key (required).
info "1/3  Fireplace API key — your access to live markets data (required)."
if ! read_validated "Paste your Fireplace API key:" validate_fireplace_key yes; then
  err "Cannot continue without a valid Fireplace API key. Run 'fireplace reset' to retry."
  exit 1
fi
FIREPLACE_API_KEY_VALUE="$__VALUE"

# 2. Telegram bot token (optional).
info "2/3  Telegram bot token — optional; press Enter to skip (add later with 'fireplace gateway setup')."
TELEGRAM_BOT_TOKEN_VALUE=""
if read_validated "Paste your Telegram bot token (or Enter to skip):" validate_telegram_token no; then
  TELEGRAM_BOT_TOKEN_VALUE="$__VALUE"
  [ -n "$TELEGRAM_BOT_TOKEN_VALUE" ] || info "Skipped Telegram setup."
else
  warn "Skipping Telegram (validation failed); you can add it later."
  TELEGRAM_BOT_TOKEN_VALUE=""
fi

# 3. LLM provider + key (required for posture A).
info "3/3  LLM provider — powers the agent (required)."
LLM_PROVIDER="$(choose_provider)"
# Parse the preset: PROVIDER|API_KEY_VAR|MODEL_DEFAULT|AUX_MODEL|VALIDATE_KIND
IFS='|' read -r LLM_PROVIDER LLM_VAR LLM_MODEL_DEFAULT LLM_AUX_MODEL LLM_KIND <<EOF
$(llm_preset "$LLM_PROVIDER")
EOF
info "Provider: $LLM_PROVIDER  (key stored as $LLM_VAR)."

# Let the user override the default main model id (Enter keeps the default).
LLM_MODEL_DEFAULT="$(read_optional "Default model id" "$LLM_MODEL_DEFAULT")"

if ! read_validated "Paste your $LLM_PROVIDER API key:" validate_llm_key yes; then
  err "Cannot continue without a valid $LLM_PROVIDER API key. Run 'fireplace reset' to retry."
  exit 1
fi
LLM_API_KEY_VALUE="$__VALUE"

# --- persist validated secrets to $FH/.env (chmod 600, ASCII) ----------------
umask 077
{
  printf '%s=%s\n' "$LLM_VAR" "$LLM_API_KEY_VALUE"
  printf 'FIREPLACE_API_KEY=%s\n' "$FIREPLACE_API_KEY_VALUE"
  if [ -n "$TELEGRAM_BOT_TOKEN_VALUE" ]; then
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TELEGRAM_BOT_TOKEN_VALUE"
  fi
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
success "Saved secrets to $ENV_FILE (chmod 600)."

# Record the provider choice so render_config + doctor stay provider-aware.
write_provider_profile "$LLM_PROVIDER" "$LLM_VAR" "$LLM_MODEL_DEFAULT" "$LLM_AUX_MODEL"
success "Recorded LLM provider profile ($LLM_PROVIDER) at $PROVIDER_PROFILE."

# --- (re)render config.yaml so the native Hermes wizard stays suppressed -----
if render_config; then
  success "Wrote $CONFIG_FILE"
else
  err "Failed to render config.yaml from template."
  exit 1
fi

info "Profile: $(trading_profile_state)  (trading is opt-in via 'fireplace enable-trading')."
info "Tip: run 'fireplace help' anytime for all commands, capabilities, and ⏰ scheduled Telegram alerts."
success "Setup complete. Launching ${AGENT_NAME}…"

# --- launch the branded TUI (Docker container or native venv, per runtime) ---
agent_exec
