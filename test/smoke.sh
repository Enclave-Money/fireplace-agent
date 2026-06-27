#!/usr/bin/env bash
#
# Fireplace Agent — end-to-end smoke test (spec §10 / §15)
# ============================================================================
# Installs Fireplace into a FULLY ISOLATED temporary HOME, simulates the
# first-run wizard with TEST keys, and asserts every static / config invariant
# that makes the default profile safe and on-brand. It NEVER touches a real
# install, a real ~/.fireplace, or ~/.hermes.
#
# By default this runs OFFLINE: it does not pull the pinned Hermes wheel and
# does not launch the real `hermes` binary (both need network + real keys).
# Set SMOKE_LIVE=1 to additionally exercise the real Hermes install + a clean
# launch (requires `uv`, network, and valid keys in the environment).
#
# Exit code: 0 only if every assertion passes; non-zero otherwise.
# Must pass `bash -n test/smoke.sh`.
#
# ----------------------------------------------------------------------------
# TEST-HOOK CONTRACT (coordination point for the install.sh / wizard.sh authors)
# ----------------------------------------------------------------------------
# This test drives the real shipped scripts via documented, non-interactive
# hooks. The scripts MUST honor these so CI can run without a TTY / network:
#
#   install.sh:
#     HOME                         install root  ($HOME/.fireplace, $HOME/.local/bin/fireplace)
#     FIREPLACE_SRC=<repo path>    use a local checkout as the bundle source
#                                  instead of downloading the bundle from GitHub
#     FIREPLACE_SKIP_HERMES_INSTALL=1
#                                  skip `uv pip install hermes-agent...` (network/time);
#                                  still lay down venv/ skeleton + bundle + $FH static files
#     FIREPLACE_NONINTERACTIVE=1   never prompt; do NOT auto-launch the wizard/TUI
#
#   wizard.sh:
#     FIREPLACE_TEST_MODE=1        non-interactive: take keys from the env, SKIP all
#                                  live (network) validation, write $FH/.env (chmod 600)
#                                  and (re)render $FH/config.yaml from the template,
#                                  then EXIT 0 WITHOUT `exec hermes`.
#     (equivalently: wizard.sh --test / --skip-validation)
#     Reads OPENROUTER_API_KEY, FIREPLACE_API_KEY (required) and
#     TELEGRAM_BOT_TOKEN (optional) from the environment.
#
# If these hooks are absent the test fails LOUDLY with a pointer here, which is
# the intended signal to wire them up — it is not a flaky failure.
# ============================================================================

set -euo pipefail

# --- Authoritative constants (must match the build contract) ----------------
readonly EXPECT_VERSION="0.1.0"
readonly EXPECT_ENGINE_VERSION="v2026.6.19"
readonly EXPECT_MCP_URL="https://data.fireplace.gg/mcp"
readonly EXPECT_MODEL_DEFAULT="anthropic/claude-sonnet-4.5"
readonly EXPECT_MODEL_PROVIDER="openrouter"

# Test (fake) secrets — ASCII only, never sent anywhere in offline mode.
readonly TEST_FIREPLACE_API_KEY="fp_test_0000000000000000000000000000"
readonly TEST_OPENROUTER_API_KEY="sk-or-test-0000000000000000000000000000"

# The 43 read tools that MUST be present in tools.include (default profile).
readonly READ_TOOLS=(
  get_market_overview get_market_by_id get_market_orderbook
  get_market_orderbook_snapshots get_market_historical_candles
  get_market_latest_candles get_market_open_interest get_market_recent_trades
  get_market_top_positions get_event_by_id get_event_open_interest
  search_markets search_events search_wallets get_trader_overview
  get_trader_positions get_trader_unredeemed_positions get_trader_recent_trades
  get_trader_activity get_trader_historical_pnl get_wallet_trades
  get_wallet_market_trades get_wallet_net_flows get_smart_money_wallets
  get_smart_money_trades my_overview my_positions my_recent_trades
  my_followed_wallets followed_wallets_recent_trades followed_wallets_net_flows
  get_open_orders get_order_status get_order_fills get_order_audit
  get_recent_trades_order_view get_leaderboard_categories get_leaderboard_user
  get_news get_news_events get_news_event_stories get_news_cluster
  get_dispute_stats
)

# The 14 execution tools that MUST NOT appear in the default profile.
readonly EXEC_TOOLS=(
  place_limit_order place_market_order place_stop_limit place_stop_market
  place_iceberg place_sticky_bbo edit_order cancel_order cancel_all_orders
  redeem_positions merge_positions split_position follow_wallet unfollow_wallet
)

# --- Pass/fail bookkeeping --------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL  %s\n' "$1" >&2; }

# assert_true <desc> <cmd...> : PASS if the command succeeds.
assert_true() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# assert_false <desc> <cmd...> : PASS if the command FAILS.
assert_false() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

section() { printf '\n=== %s ===\n' "$1"; }

# YAML list-item matcher: matches a line like  "        - <tool>"  exactly,
# so substrings (e.g. follow_wallet vs my_followed_wallets) never collide.
yaml_has_list_item() {
  local file="$1" item="$2"
  grep -Eq "^[[:space:]]*-[[:space:]]+${item}[[:space:]]*$" "$file"
}

# Cross-platform "octal mode of a file".
file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"          # BSD / macOS
  else
    stat -c '%a' "$1"           # GNU / Linux
  fi
}

# --- Resolve the repo root from this script's location ----------------------
SCRIPT_PATH="${BASH_SOURCE[0]}"
# realpath fallback for macOS where coreutils may be absent.
if command -v realpath >/dev/null 2>&1; then
  SCRIPT_PATH="$(realpath "$SCRIPT_PATH")"
else
  SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$(basename "$SCRIPT_PATH")"
fi
readonly REPO_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

readonly INSTALL_SH="$REPO_ROOT/install.sh"

# --- Build an isolated sandbox HOME -----------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/fireplace-smoke.XXXXXX")"
readonly SANDBOX
readonly FAKE_HOME="$SANDBOX/home"
mkdir -p "$FAKE_HOME"

# Everything below operates against the sandbox HOME only.
readonly FP_ROOT="$FAKE_HOME/.fireplace"     # ~/.fireplace
readonly FH="$FP_ROOT/home"                  # $FH == HERMES_HOME for this install
readonly SHIM="$FAKE_HOME/.local/bin/fireplace"
readonly CONFIG="$FH/config.yaml"
readonly ENV_FILE="$FH/.env"
readonly SOUL="$FH/SOUL.md"
readonly SKIN="$FH/skins/fireplace.yaml"

cleanup() {
  local code=$?
  if [[ -n "${SMOKE_KEEP:-}" ]]; then
    printf '\n[smoke] SMOKE_KEEP set; leaving sandbox at %s\n' "$SANDBOX"
  else
    rm -rf "$SANDBOX"
  fi
  exit "$code"
}
trap cleanup EXIT INT TERM

printf '[smoke] repo root : %s\n' "$REPO_ROOT"
printf '[smoke] sandbox   : %s\n' "$SANDBOX"
printf '[smoke] mode      : %s\n' "$([[ -n "${SMOKE_LIVE:-}" ]] && echo LIVE || echo OFFLINE)"

# ===========================================================================
section "0. Preconditions"
# ===========================================================================
assert_true "install.sh exists in repo root"            test -f "$INSTALL_SH"
assert_true "install.sh is syntactically valid (bash -n)" bash -n "$INSTALL_SH"

# ===========================================================================
section "1. Run installer (isolated, non-interactive, offline by default)"
# ===========================================================================
# Live mode performs the real Hermes install; offline skips it.
SKIP_HERMES_FLAG=1
[[ -n "${SMOKE_LIVE:-}" ]] && SKIP_HERMES_FLAG=0

if [[ -f "$INSTALL_SH" ]]; then
  if env -i \
        HOME="$FAKE_HOME" \
        PATH="$PATH" \
        TMPDIR="$SANDBOX" \
        FIREPLACE_SRC="$REPO_ROOT" \
        FIREPLACE_SKIP_HERMES_INSTALL="$SKIP_HERMES_FLAG" \
        FIREPLACE_RUNTIME=native \
        FIREPLACE_NONINTERACTIVE=1 \
        bash "$INSTALL_SH" >"$SANDBOX/install.log" 2>&1; then
    pass "install.sh completed (FIREPLACE_SKIP_HERMES_INSTALL=$SKIP_HERMES_FLAG)"
  else
    fail "install.sh exited non-zero — see $SANDBOX/install.log"
    sed 's/^/    | /' "$SANDBOX/install.log" >&2 || true
  fi
else
  fail "install.sh missing; cannot run installer phase"
fi

# ===========================================================================
section "2. Simulate the first-run wizard with TEST keys"
# ===========================================================================
# Prefer the installed copy of the wizard (realistic); fall back to the repo.
WIZARD=""
for candidate in "$FP_ROOT/bundle/wizard.sh" "$REPO_ROOT/bundle/wizard.sh"; do
  [[ -f "$candidate" ]] && { WIZARD="$candidate"; break; }
done

if [[ -n "$WIZARD" ]]; then
  assert_true "wizard.sh is syntactically valid (bash -n)" bash -n "$WIZARD"
  if env -i \
        HOME="$FAKE_HOME" \
        PATH="$PATH" \
        TMPDIR="$SANDBOX" \
        HERMES_HOME="$FH" \
        FIREPLACE_TEST_MODE=1 \
        FIREPLACE_API_KEY="$TEST_FIREPLACE_API_KEY" \
        OPENROUTER_API_KEY="$TEST_OPENROUTER_API_KEY" \
        bash "$WIZARD" --test >"$SANDBOX/wizard.log" 2>&1; then
    pass "wizard.sh test-mode completed without launching hermes"
  else
    fail "wizard.sh test-mode exited non-zero — see $SANDBOX/wizard.log (does it honor FIREPLACE_TEST_MODE?)"
    sed 's/^/    | /' "$SANDBOX/wizard.log" >&2 || true
  fi
else
  fail "wizard.sh not found under bundle/ — cannot simulate first run"
fi

# Hard gate: the rest of the assertions need these to exist. If they don't,
# the install/wizard hook contract above was not satisfied.
if [[ ! -f "$CONFIG" || ! -f "$ENV_FILE" ]]; then
  fail "config.yaml and/or .env were not produced (config=$CONFIG env=$ENV_FILE)"
  printf '\n[smoke] Cannot continue config assertions without those files.\n' >&2
  printf '[smoke] See the TEST-HOOK CONTRACT at the top of this file.\n' >&2
fi

# ===========================================================================
section "3. Shim: installed, executable, on PATH, exports HERMES_HOME"
# ===========================================================================
assert_true  "shim installed at ~/.local/bin/fireplace" test -f "$SHIM"
assert_true  "shim is executable"                       test -x "$SHIM"

# Resolve `fireplace` on a PATH that mirrors a real shell session.
RESOLVED="$(PATH="$FAKE_HOME/.local/bin:$PATH" command -v fireplace 2>/dev/null || true)"
if [[ "$RESOLVED" == "$SHIM" ]]; then
  pass "fireplace resolves on PATH to the installed shim"
else
  fail "fireplace did not resolve to the shim (got: '${RESOLVED:-<none>}')"
fi

if [[ -f "$SHIM" ]]; then
  assert_true  "shim exports HERMES_HOME (isolation footgun #18594)" \
    grep -Eq 'export[[:space:]]+HERMES_HOME' "$SHIM"
  assert_true  "shim points HERMES_HOME at ~/.fireplace/home" \
    grep -q '.fireplace/home' "$SHIM"
fi

# ===========================================================================
section "4. config.yaml — Fireplace MCP block + read-only allow-list"
# ===========================================================================
if [[ -f "$CONFIG" ]]; then
  assert_true  "config.yaml has the fireplace MCP server block" \
    grep -Eq '^[[:space:]]*fireplace:' "$CONFIG"
  assert_true  "config.yaml points at the real MCP endpoint ($EXPECT_MCP_URL)" \
    grep -Fq "$EXPECT_MCP_URL" "$CONFIG"
  assert_true  "config.yaml MCP auth uses \${FIREPLACE_API_KEY} placeholder" \
    grep -Fq 'Bearer ${FIREPLACE_API_KEY}' "$CONFIG"

  # All 41 read tools present as YAML list items.
  missing_reads=0
  for t in "${READ_TOOLS[@]}"; do
    yaml_has_list_item "$CONFIG" "$t" || { missing_reads=$((missing_reads + 1)); printf '        missing read tool: %s\n' "$t" >&2; }
  done
  if [[ "$missing_reads" -eq 0 ]]; then
    pass "all 43 read tools present in tools.include"
  else
    fail "$missing_reads / 43 read tools missing from tools.include"
  fi

  # None of the 14 execution tools present (the PRIMARY hard safety boundary).
  present_execs=0
  for t in "${EXEC_TOOLS[@]}"; do
    if yaml_has_list_item "$CONFIG" "$t"; then
      present_execs=$((present_execs + 1)); printf '        LEAKED execution tool: %s\n' "$t" >&2
    fi
  done
  if [[ "$present_execs" -eq 0 ]]; then
    pass "no execution tools in default profile (read-only by construction)"
  else
    fail "$present_execs execution tool(s) leaked into the default profile"
  fi

  # Model posture A (BYO OpenRouter).
  assert_true  "model.default = $EXPECT_MODEL_DEFAULT" \
    grep -Eq "default:[[:space:]]*${EXPECT_MODEL_DEFAULT//./\\.}" "$CONFIG"
  assert_true  "model.provider = $EXPECT_MODEL_PROVIDER" \
    grep -Eq "provider:[[:space:]]*${EXPECT_MODEL_PROVIDER}" "$CONFIG"
  assert_true  "model.api_key uses \${OPENROUTER_API_KEY}" \
    grep -Fq '${OPENROUTER_API_KEY}' "$CONFIG"

  # Layered guardrails.
  assert_true  "approvals.mode: manual (defense-in-depth, set explicitly)" \
    grep -Eq 'mode:[[:space:]]*manual' "$CONFIG"
  assert_true  "disabled_toolsets includes browser" \
    yaml_has_list_item "$CONFIG" browser
  assert_true  "disabled_toolsets includes image_gen (real name, not image_generation)" \
    yaml_has_list_item "$CONFIG" image_gen
  assert_false "image_generation (wrong name) NOT used" \
    grep -q 'image_generation' "$CONFIG"

  # Branding + skills wiring.
  assert_true  "display.skin: fireplace" \
    grep -Eq 'skin:[[:space:]]*fireplace' "$CONFIG"
  assert_true  "skills.external_dirs references fireplace-skills" \
    grep -q 'fireplace-skills' "$CONFIG"
fi

# ===========================================================================
section "5. .env — secrets, permissions, ASCII"
# ===========================================================================
if [[ -f "$ENV_FILE" ]]; then
  MODE="$(file_mode "$ENV_FILE")"
  if [[ "$MODE" == "600" ]]; then
    pass ".env is chmod 600 (got $MODE)"
  else
    fail ".env permissions are $MODE, expected 600"
  fi
  assert_true  ".env contains OPENROUTER_API_KEY with the test value" \
    grep -Eq "^OPENROUTER_API_KEY=${TEST_OPENROUTER_API_KEY}$" "$ENV_FILE"
  assert_true  ".env contains FIREPLACE_API_KEY with the test value" \
    grep -Eq "^FIREPLACE_API_KEY=${TEST_FIREPLACE_API_KEY}$" "$ENV_FILE"

  # ASCII-only (credential vars become HTTP headers; Hermes sanitizes, we pre-check).
  if command -v perl >/dev/null 2>&1; then
    if perl -ne 'exit 1 if /[^\x00-\x7F]/' "$ENV_FILE"; then
      pass ".env is ASCII-only"
    else
      fail ".env contains non-ASCII bytes"
    fi
  else
    printf '  SKIP  ASCII check (perl unavailable)\n'
  fi
fi

# ===========================================================================
section "6. SOUL.md — rebranded persona (Fireplace, not Hermes/Nous)"
# ===========================================================================
if [[ -f "$SOUL" ]]; then
  assert_true  "SOUL.md mentions Fireplace" \
    grep -qi 'Fireplace' "$SOUL"
  # The default Hermes persona literally says "You are Hermes Agent ... Nous Research".
  # Our pre-written persona must not carry that branding.
  assert_false "SOUL.md does NOT contain 'Hermes Agent'" \
    grep -q 'Hermes Agent' "$SOUL"
  assert_false "SOUL.md does NOT contain 'Nous Research'" \
    grep -q 'Nous Research' "$SOUL"
else
  fail "SOUL.md missing from \$FH"
fi

# ===========================================================================
section "7. Skills isolation — marker + shipped read-only dir"
# ===========================================================================
assert_true  ".no-bundled-skills marker present (stops upstream re-seeding)" \
  test -f "$FH/.no-bundled-skills"
assert_true  "fireplace-skills/ shipped dir present" \
  test -d "$FH/fireplace-skills"
assert_true  "fireplace-skills/MANIFEST present" \
  test -f "$FH/fireplace-skills/MANIFEST"

# ===========================================================================
section "8. Skin file — branded agent name"
# ===========================================================================
if [[ -f "$SKIN" ]]; then
  assert_true  "skins/fireplace.yaml sets agent_name: Fireplace Agent" \
    grep -Eq 'agent_name:[[:space:]]*"?Fireplace Agent"?' "$SKIN"
else
  fail "skins/fireplace.yaml missing from \$FH"
fi

# ===========================================================================
section "9. Version stamps + isolation from ~/.hermes"
# ===========================================================================
if [[ -f "$FP_ROOT/VERSION" ]]; then
  assert_true  "VERSION == $EXPECT_VERSION" \
    grep -Fxq "$EXPECT_VERSION" "$FP_ROOT/VERSION"
else
  fail "~/.fireplace/VERSION missing"
fi
if [[ -f "$FP_ROOT/ENGINE_VERSION" ]]; then
  assert_true  "ENGINE_VERSION == $EXPECT_ENGINE_VERSION" \
    grep -Fxq "$EXPECT_ENGINE_VERSION" "$FP_ROOT/ENGINE_VERSION"
else
  fail "~/.fireplace/ENGINE_VERSION missing"
fi
# Nothing in this flow should ever create ~/.hermes in the sandbox HOME.
assert_false "install/wizard did NOT create ~/.hermes (isolation holds)" \
  test -e "$FAKE_HOME/.hermes"

# ===========================================================================
section "10. LIVE checks (only with SMOKE_LIVE=1)"
# ===========================================================================
if [[ -n "${SMOKE_LIVE:-}" ]]; then
  # Requires the real Hermes install + valid keys in the environment.
  if env \
        HOME="$FAKE_HOME" \
        PATH="$FAKE_HOME/.local/bin:$PATH" \
        fireplace self-check >"$SANDBOX/selfcheck.log" 2>&1; then
    pass "fireplace self-check passed (live)"
  else
    fail "fireplace self-check failed (live) — see $SANDBOX/selfcheck.log"
  fi
else
  printf '  SKIP  live hermes install + launch + self-check (set SMOKE_LIVE=1)\n'
fi

# ===========================================================================
section "11. LLM provider matrix — token substitution (openrouter/anthropic/openai)"
# ===========================================================================
# render_config() must substitute the four @@FP_*@@ provider tokens from the
# $FH/.llm-provider profile (default OpenRouter) into a valid, token-free config.
provider_render_ok() {
  # provider_render_ok <provider> <expect_provider> <expect_model> <expect_keyvar>
  # Run in a FRESH bash process (not a subshell) so smoke's `readonly FH/ENV_FILE`
  # are not inherited — common.sh reassigns those and would abort under `set -e`.
  bash -c '
    set -e
    REPO_ROOT="$1"; prov="$2"; xprov="$3"; xmodel="$4"; xvar="$5"
    PMROOT="$(mktemp -d)"; export FIREPLACE_ROOT="$PMROOT"
    mkdir -p "$PMROOT/bundle" "$PMROOT/home"
    cp "$REPO_ROOT/bundle/config.template.yaml" "$PMROOT/bundle/config.template.yaml"
    . "$REPO_ROOT/bundle/lib/common.sh"
    IFS="|" read -r P V M A K <<EOF2
$(llm_preset "$prov")
EOF2
    write_provider_profile "$P" "$V" "$M" "$A"
    render_config >/dev/null 2>&1
    grep -qE "provider:[[:space:]]*${xprov}([[:space:]]|$)" "$CONFIG_FILE"
    grep -qE "default:[[:space:]]*${xmodel}([[:space:]]|$|#)" "$CONFIG_FILE"
    grep -Fq "\${${xvar}}" "$CONFIG_FILE"
    ! grep -q "@@FP_" "$CONFIG_FILE"
    rm -rf "$PMROOT"
  ' _ "$REPO_ROOT" "$1" "$2" "$3" "$4"
}
assert_true "openrouter renders (provider+model+\${OPENROUTER_API_KEY}, no tokens)" \
  provider_render_ok openrouter openrouter "anthropic/claude-sonnet-4.5" OPENROUTER_API_KEY
assert_true "anthropic renders (provider+claude-sonnet-4-5+\${ANTHROPIC_API_KEY})" \
  provider_render_ok anthropic anthropic "claude-sonnet-4-5" ANTHROPIC_API_KEY
assert_true "openai renders (provider+gpt-4.1+\${OPENAI_API_KEY})" \
  provider_render_ok openai openai "gpt-4.1" OPENAI_API_KEY

# ===========================================================================
section "12. Docker-first runtime wiring (static, no daemon needed)"
# ===========================================================================
DOCKERFILE="$REPO_ROOT/bundle/docker/Dockerfile"
COMMON="$REPO_ROOT/bundle/lib/common.sh"
SHIM_SRC="$REPO_ROOT/bundle/bin/fireplace"
GATEWAY_SH="$REPO_ROOT/bundle/lib/gateway.sh"

assert_true "Dockerfile present"                         test -f "$DOCKERFILE"
assert_true "Dockerfile base is python:3.11-slim"        grep -q 'FROM python:3.11-slim' "$DOCKERFILE"
assert_true "Dockerfile installs the pinned Hermes"      grep -Eq 'hermes-agent\[all\]' "$DOCKERFILE"
assert_true "Dockerfile sets HERMES_HOME=/data"          grep -q 'HERMES_HOME=/data' "$DOCKERFILE"
assert_true "Dockerfile ENTRYPOINT is the hermes binary" grep -q 'ENTRYPOINT.*hermes' "$DOCKERFILE"
assert_true "common.sh defines agent_exec launcher"      grep -q 'agent_exec()' "$COMMON"
assert_true "common.sh detects docker daemon"            grep -q 'docker_daemon_ok()' "$COMMON"
assert_true "common.sh reads the .runtime stamp"         grep -q 'FP_RUNTIME=' "$COMMON"
assert_true "common.sh mounts \$FH at /data"             grep -Fq '$FH:/data' "$COMMON"
assert_true "shim sources common.sh + launches agent"    grep -q 'agent_exec' "$SHIM_SRC"
assert_true "gateway.sh present (managed service)"       test -f "$GATEWAY_SH"
assert_true "help.sh present (branded overview screen)"  test -f "$REPO_ROOT/bundle/lib/help.sh"
assert_true "shim intercepts the 'help' verb"            grep -Eq 'help\|--help\|-h' "$SHIM_SRC"
assert_true "help screen renders (exit 0)"               env FIREPLACE_ROOT="$SANDBOX/none" bash "$REPO_ROOT/bundle/lib/help.sh"
assert_true "help screen shows version line"             sh -c "FIREPLACE_ROOT='$SANDBOX/none' bash '$REPO_ROOT/bundle/lib/help.sh' | grep -q 'Fireplace Agent'"
assert_true "help screen highlights cron + Telegram"     sh -c "FIREPLACE_ROOT='$SANDBOX/none' bash '$REPO_ROOT/bundle/lib/help.sh' | grep -qi 'SCHEDULED ALERTS'"
assert_true "help screen has NO 'Hermes' mention"        sh -c "! FIREPLACE_ROOT='$SANDBOX/none' bash '$REPO_ROOT/bundle/lib/help.sh' | grep -qi hermes"
assert_true "install.sh has the docker build path"       grep -q 'docker build' "$INSTALL_SH"
assert_true "install.sh decides a runtime"               grep -q 'RUNTIME=' "$INSTALL_SH"
# The offline install forced FIREPLACE_RUNTIME=native; the stamp must reflect it.
assert_true ".runtime stamp written = native"            grep -qx 'native' "$FP_ROOT/.runtime"

# ===========================================================================
section "Summary"
# ===========================================================================
printf 'Passed: %d   Failed: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf 'SMOKE TEST: FAIL\n' >&2
  exit 1
fi
printf 'SMOKE TEST: PASS\n'
exit 0
