#!/usr/bin/env bash
# =============================================================================
# lib/update.sh — `fireplace update`
# -----------------------------------------------------------------------------
# Re-pins the engine to the current ENGINE_VERSION and refreshes the bundle, config,
# skin, and shipped (fireplace-) skills, while PRESERVING all user state: .env,
# sessions/, MEMORY.md, auth.json, and agent-authored skills (the normal
# $FH/skills/ tree).
#
# Strategy:
#   • Remote-first: re-fetch this repo at its pinned ref and exec its installer,
#     which is itself idempotent/upgrade-safe (refreshes the bundle too). This is
#     the only way to pick up new bundle CODE.
#   • Offline fallback: if the repo can't be fetched, do a LOCAL refresh from the
#     already-installed bundle — re-pin Hermes into the venv and re-render config
#     + re-copy skin/SOUL/shipped-skills.
#
# Flags:  --local   force the offline/local refresh (skip the repo fetch)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

FORCE_LOCAL=0
for arg in "$@"; do
  case "$arg" in --local) FORCE_LOCAL=1 ;; *) ;; esac
done

FIREPLACE_REPO="${FIREPLACE_REPO:-https://github.com/fireplace-gg/fireplace-agent}"
FIREPLACE_REF="${FIREPLACE_REF:-v$BUNDLE_VERSION}"

print_banner
info "Updating Fireplace (current bundle $BUNDLE_VERSION, engine $ENGINE_VERSION_REF)…"

run_timed() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

# ----- remote-first: fetch repo and re-run the installer ---------------------
if [ "$FORCE_LOCAL" -ne 1 ] && command -v git >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
  info "Fetching latest bundle from $FIREPLACE_REPO …"
  if run_timed 300 git clone --depth 1 --branch "$FIREPLACE_REF" "$FIREPLACE_REPO" "$TMP/repo" >&2 2>&1 \
     || run_timed 300 git clone --depth 1 "$FIREPLACE_REPO" "$TMP/repo" >&2 2>&1; then
    if [ -f "$TMP/repo/install.sh" ]; then
      info "Running refreshed installer (preserves .env, sessions, memory, agent skills)…"
      exec bash "$TMP/repo/install.sh"
    fi
    warn "Fetched repo has no install.sh; falling back to local refresh."
  else
    warn "Could not fetch the repo; falling back to a local refresh."
  fi
fi

# ----- offline/local refresh -------------------------------------------------
info "Local refresh from installed bundle."

# Re-pin / rebuild the engine, runtime-aware.
PIN_HERMES="$ENGINE_VERSION_REF"
if [ "$FP_RUNTIME" = "docker" ]; then
  if [ -f "$BUNDLE/docker/Dockerfile" ] && docker_daemon_ok; then
    info "Rebuilding the runtime image ${FP_IMAGE}…"
    if run_timed 1800 docker build -t "$FP_IMAGE" \
        --build-arg HERMES_SPEC="hermes-agent[all]==${HERMES_DIST_FALLBACK}" \
        "$BUNDLE/docker" >&2; then
      success "Rebuilt runtime image ${FP_IMAGE}."
    else
      warn "Image rebuild failed; keeping the current image."
    fi
  else
    warn "Docker not available (or Dockerfile missing) — skipping image rebuild."
  fi
else
  GIT_SPEC="hermes-agent[all] @ git+https://github.com/NousResearch/hermes-agent@${PIN_HERMES}"
  PYPI_SPEC="hermes-agent[all]==${HERMES_DIST_FALLBACK}"
  if [ -x "$VENV/bin/python" ]; then
    info "Re-pinning the engine (${PIN_HERMES}) into the venv…"
    if run_timed 600 uv pip install --python "$VENV/bin/python" "$GIT_SPEC" >&2; then
      success "Engine re-pinned from git ref ${PIN_HERMES}."
    elif run_timed 600 uv pip install --python "$VENV/bin/python" "$PYPI_SPEC" >&2; then
      success "Engine re-pinned from PyPI ${PYPI_SPEC}."
    else
      warn "Engine re-pin failed; keeping the currently installed version."
    fi
  else
    warn "venv missing — run the installer to recreate it."
  fi
fi

# Refresh brand assets from the installed bundle.
if [ -f "$BUNDLE/SOUL.md" ]; then
  cp "$BUNDLE/SOUL.md" "$SOUL_FILE"
fi
mkdir -p "$SKINS_DIR"
if [ -f "$BUNDLE/skins/fireplace.yaml" ]; then
  cp "$BUNDLE/skins/fireplace.yaml" "$SKINS_DIR/fireplace.yaml"
fi
# Shipped skills: installer-owned, overwritten wholesale.
rm -rf "$FP_SKILLS_DIR"
mkdir -p "$FP_SKILLS_DIR"
cp -R "$BUNDLE/skills/." "$FP_SKILLS_DIR/"
# Ensure the no-bundled-skills marker stays in place.
: > "$NO_BUNDLED_SKILLS_MARKER"

# Re-render config (render_config re-applies the trading profile if marked).
render_config "$BUNDLE/config.template.yaml" \
  && success "Refreshed $CONFIG_FILE" \
  || warn "Failed to refresh config.yaml."

info "Profile after update: $(trading_profile_state)."
success "Fireplace update complete."
