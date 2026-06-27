#!/usr/bin/env bash
# =============================================================================
# lib/doctor.sh — `fireplace doctor`
# -----------------------------------------------------------------------------
# Runs the underlying `hermes doctor`, then a battery of Fireplace-specific
# checks and prints a pass/fail summary. Exits non-zero if any CRITICAL check
# fails.
#
# Checks:
#   1. HERMES_HOME is exported and points at this install's home ($FH).
#   2. config.yaml exists and carries the load-bearing keys.
#   3. .env exists (chmod 600) and the LLM key + FIREPLACE_API_KEY resolve
#      non-empty (the silent ${VAR}-passthrough failure mode).
#   4. The Fireplace MCP is reachable + the key is accepted (tools/list POST).
#   5. Reports the active profile: read-only vs trading.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

PASS=0
FAIL=0
CRIT_FAIL=0

ok()   { success "$*"; PASS=$((PASS + 1)); }
bad()  { err "$*"; FAIL=$((FAIL + 1)); }
crit() { err "$*"; FAIL=$((FAIL + 1)); CRIT_FAIL=$((CRIT_FAIL + 1)); }

print_banner
info "Running diagnostics for ${AGENT_NAME}…"

# ----- 0. runtime (docker | native) + engine availability --------------------
info "Runtime: $FP_RUNTIME"
if [ "$FP_RUNTIME" = "docker" ]; then
  if ! docker_daemon_ok; then
    crit "Docker daemon not reachable — start Docker Desktop (or reinstall with FIREPLACE_RUNTIME=native)."
  elif ! docker image inspect "$FP_IMAGE" >/dev/null 2>&1; then
    crit "Runtime image '$FP_IMAGE' not found — run 'fireplace update' to (re)build it."
  else
    ok "Docker runtime OK (image $FP_IMAGE present, daemon up)."
  fi
else
  [ -x "$VENV/bin/hermes" ] && ok "Native runtime OK (engine present)." \
    || crit "Engine is missing (run 'fireplace update')."
fi

# ----- underlying hermes doctor (best-effort; never aborts our checks) -------
if { [ "$FP_RUNTIME" = "docker" ] && docker_daemon_ok && docker image inspect "$FP_IMAGE" >/dev/null 2>&1; } \
   || { [ "$FP_RUNTIME" != "docker" ] && [ -x "$VENV/bin/hermes" ]; }; then
  info "----- engine diagnostics -----"
  agent_run doctor || warn "engine diagnostics reported issues (see above)."
  info "----- fireplace checks -----"
fi

# ----- 1. HERMES_HOME isolation ----------------------------------------------
if [ "${HERMES_HOME:-}" = "$FH" ]; then
  ok "Isolated data home is set -> $FH"
else
  crit "Isolated data home is wrong ('${HERMES_HOME:-<unset>}', expected '$FH'). The shim must set it."
fi

# ----- 2. config.yaml + load-bearing keys ------------------------------------
if [ -f "$CONFIG_FILE" ]; then
  ok "config.yaml present at $CONFIG_FILE"
  miss=""
  # Provider is whatever the user picked (openrouter/anthropic/openai); assert the
  # model.provider line matches the recorded profile (default openrouter).
  DOC_PROVIDER="$(FP_PROVIDER=""; [ -f "$PROVIDER_PROFILE" ] && . "$PROVIDER_PROFILE"; printf '%s' "${FP_PROVIDER:-openrouter}")"
  grep -qE "provider:[[:space:]]*${DOC_PROVIDER}" "$CONFIG_FILE" 2>/dev/null || miss="$miss model.provider"
  grep -qE '^[[:space:]]*default:[[:space:]]*[^[:space:]]' "$CONFIG_FILE" 2>/dev/null || miss="$miss model.default"
  grep -q 'mcp_servers:' "$CONFIG_FILE" 2>/dev/null         || miss="$miss mcp_servers"
  grep -q 'fireplace:' "$CONFIG_FILE" 2>/dev/null           || miss="$miss mcp_servers.fireplace"
  grep -q 'Authorization:' "$CONFIG_FILE" 2>/dev/null       || miss="$miss mcp auth header"
  grep -q 'mode: manual' "$CONFIG_FILE" 2>/dev/null         || miss="$miss approvals.mode"
  grep -q 'skin: fireplace' "$CONFIG_FILE" 2>/dev/null      || miss="$miss display.skin"
  grep -q 'external_dirs' "$CONFIG_FILE" 2>/dev/null        || miss="$miss skills.external_dirs"
  grep -q 'get_leaderboard_categories' "$CONFIG_FILE" 2>/dev/null || miss="$miss read-tool-allowlist"
  if [ -z "$miss" ]; then
    ok "config.yaml carries all load-bearing keys."
  else
    crit "config.yaml is missing keys:$miss"
  fi
else
  crit "config.yaml not found at $CONFIG_FILE (run 'fireplace' to set up)."
fi

# ----- 3. .env + secret resolution -------------------------------------------
if [ -f "$ENV_FILE" ]; then
  perms="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')"
  if [ "$perms" = "600" ]; then
    ok ".env present with 600 permissions."
  else
    bad ".env present but permissions are '$perms' (expected 600); fixing."
    chmod 600 "$ENV_FILE" 2>/dev/null || true
  fi
  # Read values without exporting the file into our shell broadly. The LLM key
  # var depends on the chosen provider (OPENROUTER_API_KEY / ANTHROPIC_API_KEY /
  # OPENAI_API_KEY); resolve its name from the provider profile.
  LLM_VAR="$(llm_key_var)"
  # `|| true`: a missing key makes grep exit 1, which under `set -euo pipefail`
  # would abort the script BEFORE we can report it as the crit below.
  OR_VAL="$(grep -E "^${LLM_VAR}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  FP_VAL="$(grep -E '^FIREPLACE_API_KEY=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  [ -n "$OR_VAL" ] && ok "$LLM_VAR resolves non-empty." || crit "$LLM_VAR is empty/unset in .env."
  [ -n "$FP_VAL" ] && ok "FIREPLACE_API_KEY resolves non-empty." || crit "FIREPLACE_API_KEY is empty/unset in .env."
else
  crit ".env not found at $ENV_FILE (run 'fireplace' to onboard)."
  OR_VAL=""; FP_VAL=""
fi

# Assert no unresolved ${VAR} placeholder leaked literally into a header value
# (silent failure mode). The template SHOULD keep them literal; that's expected.
# Here we only warn if the *resolved* secrets are missing while the config still
# references them — handled above. No extra check needed.

# ----- 4. MCP reachability (Authorization: Bearer <key> tools/list) ----------
if [ -n "$FP_VAL" ]; then
  if mcp_probe "$FP_VAL"; then
    ok "Fireplace MCP reachable and key accepted ($MCP_URL)."
  else
    crit "Fireplace MCP not reachable or key rejected at $MCP_URL."
  fi
else
  bad "Skipping MCP probe (no FIREPLACE_API_KEY)."
fi

# ----- 5. profile report -----------------------------------------------------
PROFILE="$(trading_profile_state)"
if [ "$PROFILE" = "trading" ]; then
  warn "Active profile: TRADING (execution tools are exposed). Run 'fireplace disable-trading' to revert."
else
  ok "Active profile: READ-ONLY (execution tools omitted by construction)."
fi

# ----- summary ---------------------------------------------------------------
info "----- summary -----"
info "Passed: $PASS   Failed: $FAIL   Critical failures: $CRIT_FAIL"
if [ "$CRIT_FAIL" -gt 0 ]; then
  err "Fireplace is NOT healthy — resolve the critical issues above."
  exit 1
fi
if [ "$FAIL" -gt 0 ]; then
  warn "Fireplace is usable but some non-critical checks failed."
  exit 0
fi
success "Fireplace is healthy."
