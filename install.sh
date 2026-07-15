#!/usr/bin/env bash
# =============================================================================
# Fireplace Agent — installer
# -----------------------------------------------------------------------------
# One-shot target for:   curl -fsSL https://get.fireplace.gg/install.sh | bash
# Also runnable from a cloned repo:   bash install.sh
#
# It is STANDALONE on purpose (no dependency on bundle/lib/common.sh) because in
# the curl|bash path the bundle does not exist on disk yet.
#
# What it does (idempotent / upgrade-safe):
#   1. Preflight: detect macOS/Linux, ensure curl + git, ensure `uv`
#      (auto-install via astral.sh), ensure a Python 3.11 interpreter via uv.
#   2. Lay out ~/.fireplace/{home,bundle,venv} and create the venv.
#   3. Install the pinned Hermes harness into that venv (git ref form; PyPI
#      fallback).
#   4. Copy the product bundle -> ~/.fireplace/bundle and the runtime assets
#      (SOUL.md, skins/, fireplace-skills/) into ~/.fireplace/home, drop the
#      .no-bundled-skills marker, and render config.template.yaml -> config.yaml
#      (secrets stay as ${VAR}).
#   5. Install the shim to ~/.local/bin/fireplace and ensure it's on PATH.
#   6. Stamp VERSION + ENGINE_VERSION, print next steps.
#
# UPGRADE SAFETY: if ~/.fireplace/home/.env already exists this is treated as an
# upgrade — venv/Hermes/bundle/config/skin/shipped-skills are refreshed, but
# .env, sessions/, MEMORY.md, auth.json, and agent-authored skills are NEVER
# touched.
#
# It does NOT collect API keys and does NOT auto-launch — `fireplace` runs the
# onboarding wizard on first use.
# =============================================================================
set -euo pipefail

# ----- overridable knobs -----------------------------------------------------
FIREPLACE_ROOT="${FIREPLACE_ROOT:-$HOME/.fireplace}"
FIREPLACE_REPO="${FIREPLACE_REPO:-https://github.com/Enclave-Money/fireplace-agent}"
# Git ref of THIS repo to fetch in the curl|bash path. Defaults to the bundle
# release tag, then falls back to the default branch if that tag is absent.
FIREPLACE_REF="${FIREPLACE_REF:-v0.1.2}"
PIP_TIMEOUT="${PIP_TIMEOUT:-600}"   # seconds; the engine[all] is a large install
# Runtime: 'auto' (default) prefers Docker for a sandboxed agent and falls back
# to a native venv when Docker is unavailable. Force with 'docker' or 'native'.
FIREPLACE_RUNTIME="${FIREPLACE_RUNTIME:-auto}"
# Prebuilt runtime image: the installer PULLS this (fast) for the Docker runtime,
# falling back to a local build if the pull fails. Set FIREPLACE_BUILD_IMAGE=1 to
# always build locally instead of pulling.
FIREPLACE_IMAGE_REPO="${FIREPLACE_IMAGE_REPO:-ghcr.io/enclave-money/fireplace-agent}"
# Engine spec used when BUILDING the image locally (override to pin a git ref).
FIREPLACE_HERMES_SPEC="${FIREPLACE_HERMES_SPEC:-hermes-agent[all]==${HERMES_DIST_FALLBACK:-0.17.0}}"
DOCKER_BUILD_TIMEOUT="${DOCKER_BUILD_TIMEOUT:-1800}"  # seconds; first image build
# Anonymous, keyless install telemetry: on success the installer pings OUR OWN
# endpoint (no API key in this script). That endpoint records the event to
# analytics server-side. Opt out with FIREPLACE_NO_ANALYTICS=1 or DO_NOT_TRACK=1.
FIREPLACE_TELEMETRY_URL="${FIREPLACE_TELEMETRY_URL:-https://get.fireplace.gg/api/installed}"

# ----- test/CI hooks (honored by test/smoke.sh; safe no-ops in normal use) ----
# FIREPLACE_SRC                 use this local checkout as the bundle source
#                               (skip the curl|bash git clone).
# FIREPLACE_SKIP_HERMES_INSTALL skip the `uv pip install hermes-agent` step AND
#                               the uv venv/python provisioning (offline CI). Lays
#                               down a venv skeleton + bundle + $FH static files.
# FIREPLACE_NONINTERACTIVE      never prompt and never auto-launch (already true;
#                               accepted for contract compatibility).
SKIP_HERMES="${FIREPLACE_SKIP_HERMES_INSTALL:-0}"
: "${FIREPLACE_NONINTERACTIVE:=0}"

FH="$FIREPLACE_ROOT/home"
VENV="$FIREPLACE_ROOT/venv"
BUNDLE_DST="$FIREPLACE_ROOT/bundle"
ENV_FILE="$FH/.env"
LOCAL_BIN="$HOME/.local/bin"
SHIM_DST="$LOCAL_BIN/fireplace"

# ----- minimal logging (no color dependency on a pipe) -----------------------
if [ -t 2 ]; then A='\033[38;5;209m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; Z='\033[0m'
else A=''; G=''; Y=''; R=''; Z=''; fi
info()    { printf '%b\n' "${A}[fireplace]${Z} $*" >&2; }
success() { printf '%b\n' "${G}[fireplace] ✓${Z} $*" >&2; }
warn()    { printf '%b\n' "${Y}[fireplace] !${Z} $*" >&2; }
err()     { printf '%b\n' "${R}[fireplace] ✗${Z} $*" >&2; }
die()     { err "$*"; exit 1; }

# run_timed <seconds> <cmd...> — apply a timeout when the binary is available
# (it usually isn't on stock macOS); otherwise run unbounded.
run_timed() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

cleanup() { [ -n "${TMPDIR_CLONE:-}" ] && rm -rf "$TMPDIR_CLONE" 2>/dev/null || true; }
trap cleanup EXIT

# brand_patch_venv — rebrand the engine's USER-VISIBLE display strings in OUR
# installed copy (the native venv). This is a string rebrand of our own install,
# not a source fork: it rewrites the upstream product/author name so the in-agent
# TUI banner and defaults read "Fireplace", not the upstream name. Best-effort —
# it must never fail the install. (The Docker image does the same at build time.)
brand_patch_venv() {
  local site script
  site="$("$VENV/bin/python" -c 'import hermes_cli,os;print(os.path.dirname(os.path.dirname(hermes_cli.__file__)))' 2>/dev/null)" || return 0
  [ -n "$site" ] && [ -d "$site" ] || return 0
  script="$SRC/bundle/docker/brand-patch.py"
  [ -f "$script" ] || script="$BUNDLE_DST/docker/brand-patch.py"
  [ -f "$script" ] || return 0
  info "Applying Fireplace branding to the engine…"
  "$VENV/bin/python" "$script" "$site" >&2 || true
}

# track_install — keyless, anonymous install telemetry. Pings OUR OWN endpoint
# (no API key in this script); that endpoint records the event server-side.
# Non-blocking, short timeout, never fails the install. Opt out via
# FIREPLACE_NO_ANALYTICS / DO_NOT_TRACK, and skipped in CI (SKIP_HERMES).
track_install() {
  [ -n "${FIREPLACE_NO_ANALYTICS:-}${DO_NOT_TRACK:-}" ] && return 0
  [ "$SKIP_HERMES" = "1" ] && return 0
  [ -n "$FIREPLACE_TELEMETRY_URL" ] || return 0
  curl -fsS -m 4 -G "$FIREPLACE_TELEMETRY_URL" \
    --data-urlencode "event=cli_install_completed" \
    --data-urlencode "os=${OS:-?}" \
    --data-urlencode "arch=$(uname -m 2>/dev/null || echo '?')" \
    --data-urlencode "runtime=${RUNTIME:-unknown}" \
    --data-urlencode "version=${BUNDLE_VERSION:-?}" \
    --data-urlencode "engine=${PIN_HERMES:-?}" \
    --data-urlencode "upgrade=${IS_UPGRADE:-0}" \
    >/dev/null 2>&1 || true
}

# ----- 1. preflight ----------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) : ;;
  *) die "Unsupported OS: $OS (Fireplace supports macOS and Linux)." ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required but not found."

# ----- decide the runtime (Docker preferred; native venv fallback) -----------
# We never auto-install Docker: on macOS it's a licensed GUI app (Docker Desktop)
# that needs admin + a manual launch; on Linux it's a root/systemd daemon. Either
# is too intrusive for an unattended installer. Instead we detect, fall back to a
# native venv so the one-command install always works, and tell the user how to
# get Docker if they want the sandboxed runtime.
docker_cli_present() { command -v docker >/dev/null 2>&1; }
docker_daemon_ok()  { docker_cli_present && docker info >/dev/null 2>&1; }
docker_install_hint() {
  if [ "$OS" = "Darwin" ]; then
    warn "    Install Docker Desktop:  https://docs.docker.com/desktop/install/mac-install/"
    warn "    (or:  brew install --cask docker )  then open it so the daemon starts."
  else
    warn "    Install Docker Engine:   https://docs.docker.com/engine/install/"
    warn "    (or:  curl -fsSL https://get.docker.com | sh )  then:  sudo systemctl enable --now docker"
  fi
}

RUNTIME=""
case "$FIREPLACE_RUNTIME" in
  native)
    RUNTIME="native" ;;
  docker)
    # Explicitly requested Docker — do NOT silently fall back; guide and stop.
    if docker_daemon_ok; then
      RUNTIME="docker"
    elif docker_cli_present; then
      err "FIREPLACE_RUNTIME=docker, but the Docker daemon isn't running."
      err "Start Docker (the Desktop app, or 'sudo systemctl start docker') and re-run — or use FIREPLACE_RUNTIME=native."
      exit 1
    else
      err "FIREPLACE_RUNTIME=docker, but Docker is not installed."
      docker_install_hint
      err "…then re-run this installer — or use FIREPLACE_RUNTIME=native for a no-Docker install."
      exit 1
    fi ;;
  auto|*)
    if [ "$SKIP_HERMES" = "1" ]; then
      RUNTIME="native"                       # offline/CI: never build an image
    elif docker_daemon_ok; then
      RUNTIME="docker"
    elif docker_cli_present; then
      warn "Docker is installed but its daemon isn't running — using the NATIVE (venv) runtime for now."
      warn "For the sandboxed container runtime, start Docker and re-run this installer."
      RUNTIME="native"
    else
      warn "Docker isn't installed — using the NATIVE (venv) runtime (this one-command install still works)."
      warn "For the recommended sandboxed container runtime, install Docker and re-run:"
      docker_install_hint
      RUNTIME="native"
    fi ;;
esac
info "Runtime: $RUNTIME"

# Native runtime needs uv + a Python 3.11 interpreter; Docker needs neither.
if [ "$SKIP_HERMES" = "1" ]; then
  warn "FIREPLACE_SKIP_HERMES_INSTALL=1 — skipping engine provisioning (CI/offline)."
elif [ "$RUNTIME" = "native" ]; then
  if ! command -v uv >/dev/null 2>&1; then
    info "Installing uv (Python toolchain manager)…"
    curl -LsSf https://astral.sh/uv/install.sh | sh || die "uv installation failed."
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  fi
  command -v uv >/dev/null 2>&1 || die "uv is still not on PATH after install. Open a new shell and re-run."
  info "Provisioning Python 3.11…"
  if ! run_timed 300 uv python install 3.11 >&2; then
    warn "uv could not pre-provision Python 3.11; will try during venv creation."
  fi
fi

# ----- locate the bundle source (explicit FIREPLACE_SRC > local clone > fetch)
SRC=""
# Test/CI override: an explicit local checkout to use as the bundle source.
if [ -n "${FIREPLACE_SRC:-}" ] && [ -d "${FIREPLACE_SRC}/bundle/bin" ]; then
  SRC="$FIREPLACE_SRC"
fi
SELF="${BASH_SOURCE[0]:-}"
if [ -z "$SRC" ] && [ -n "$SELF" ] && [ -f "$SELF" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
  if [ -d "$SCRIPT_DIR/bundle/bin" ]; then
    SRC="$SCRIPT_DIR"
  fi
fi
if [ -z "$SRC" ]; then
  command -v git >/dev/null 2>&1 || die "git is required to fetch the Fireplace bundle (curl|bash path)."
  TMPDIR_CLONE="$(mktemp -d)"
  info "Fetching Fireplace bundle from $FIREPLACE_REPO …"
  if run_timed 300 git clone --depth 1 --branch "$FIREPLACE_REF" "$FIREPLACE_REPO" "$TMPDIR_CLONE/repo" >&2 2>&1; then
    SRC="$TMPDIR_CLONE/repo"
  elif run_timed 300 git clone --depth 1 "$FIREPLACE_REPO" "$TMPDIR_CLONE/repo" >&2 2>&1; then
    warn "Ref '$FIREPLACE_REF' not found; using the repository default branch."
    SRC="$TMPDIR_CLONE/repo"
  else
    die "Failed to fetch the Fireplace bundle. Set FIREPLACE_REPO to a reachable repo."
  fi
fi
[ -d "$SRC/bundle/bin" ] || die "Bundle layout not found under $SRC (missing bundle/bin)."

# Pinned engine ref — single source of truth in the repo's ENGINE_VERSION file.
PIN_HERMES="$(cat "$SRC/ENGINE_VERSION" 2>/dev/null || echo "v2026.6.19")"
BUNDLE_VERSION="$(cat "$SRC/VERSION" 2>/dev/null || echo "0.1.0")"

# Detect upgrade vs fresh install.
IS_UPGRADE=0
[ -f "$ENV_FILE" ] && IS_UPGRADE=1
if [ "$IS_UPGRADE" -eq 1 ]; then
  info "Existing install detected — upgrading in place (secrets & sessions preserved)."
else
  info "Performing a fresh install."
fi

# ----- 2. layout + venv ------------------------------------------------------
mkdir -p "$FH" "$BUNDLE_DST" "$LOCAL_BIN"
chmod 700 "$FH" 2>/dev/null || true
# Stamp the runtime early: render_config (sourced from common.sh below) reads it
# to decide the container-vs-native path when re-applying a trading profile.
printf '%s\n' "$RUNTIME" > "$FIREPLACE_ROOT/.runtime"

IMAGE="fireplace-agent:${BUNDLE_VERSION}"
if [ "$SKIP_HERMES" = "1" ]; then
  # CI/offline: lay down a venv skeleton only (no uv, no docker, no network).
  mkdir -p "$VENV/bin"
  info "Skipping engine install (FIREPLACE_SKIP_HERMES_INSTALL=1); wrote venv skeleton."
elif [ "$RUNTIME" = "docker" ]; then
  # ----- 3a. get the runtime image (the user runs no docker commands) --------
  # Prefer the prebuilt image (fast); fall back to a local build. The agent uses
  # the local tag $IMAGE, so a pulled image is re-tagged to it.
  PULL_REF="${FIREPLACE_IMAGE_REPO}:${BUNDLE_VERSION}"
  if [ "${FIREPLACE_BUILD_IMAGE:-0}" != "1" ] && run_timed 600 docker pull "$PULL_REF" >&2 2>&1; then
    docker tag "$PULL_REF" "$IMAGE"
    success "Pulled prebuilt runtime image ($PULL_REF)."
  else
    if [ "${FIREPLACE_BUILD_IMAGE:-0}" = "1" ]; then
      info "FIREPLACE_BUILD_IMAGE=1 — building the runtime image locally."
    else
      warn "Prebuilt image unavailable ($PULL_REF) — building locally instead."
    fi
    info "Building the runtime image ($IMAGE) — the first build can take several minutes…"
    if ! run_timed "$DOCKER_BUILD_TIMEOUT" docker build \
          -t "$IMAGE" \
          --build-arg HERMES_SPEC="$FIREPLACE_HERMES_SPEC" \
          "$SRC/bundle/docker" >&2; then
      die "Docker image build failed. Ensure Docker has network access, or re-run with FIREPLACE_RUNTIME=native."
    fi
  fi
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Image $IMAGE not present after pull/build."
else
  # ----- 3b. native venv install --------------------------------------------
  if [ ! -x "$VENV/bin/python" ]; then
    info "Creating virtualenv at $VENV (Python 3.11)…"
    run_timed 300 uv venv "$VENV" --python 3.11 >&2 || die "Failed to create venv with Python 3.11."
  else
    info "Reusing existing venv at $VENV."
  fi
  GIT_SPEC="hermes-agent[all] @ git+https://github.com/NousResearch/hermes-agent@${PIN_HERMES}"
  PYPI_SPEC="hermes-agent[all]==${HERMES_DIST_FALLBACK:-0.17.0}"
  info "Installing the agent engine (${PIN_HERMES}) into the venv — this can take a few minutes…"
  if run_timed "$PIP_TIMEOUT" uv pip install --python "$VENV/bin/python" "$GIT_SPEC" >&2; then
    success "Installed the engine from git ref ${PIN_HERMES}."
  else
    warn "Git-ref install failed; falling back to PyPI pin ${PYPI_SPEC}."
    run_timed "$PIP_TIMEOUT" uv pip install --python "$VENV/bin/python" "$PYPI_SPEC" >&2 \
      || die "Engine installation failed (both git and PyPI). Aborting without a half-install."
    success "Installed the engine from PyPI pin ${PYPI_SPEC}."
  fi
  [ -x "$VENV/bin/hermes" ] || die "Engine installed but its entry point is missing."
  brand_patch_venv
fi

# ----- 4. copy bundle + runtime assets ---------------------------------------
info "Installing product bundle -> $BUNDLE_DST"
# Refresh the bundle wholesale (scripts/templates/skins/skills are wrapper-owned).
rm -rf "$BUNDLE_DST"
mkdir -p "$BUNDLE_DST"
cp -R "$SRC/bundle/." "$BUNDLE_DST/"
chmod +x "$BUNDLE_DST/bin/fireplace" "$BUNDLE_DST/wizard.sh" 2>/dev/null || true
chmod +x "$BUNDLE_DST"/lib/*.sh 2>/dev/null || true

# Runtime brand assets into $FH (these are wrapper-owned, refreshed each install).
# SOUL.md is the Fireplace persona — refreshed so branding/safety rules stay current.
if [ -f "$SRC/bundle/SOUL.md" ]; then
  cp "$SRC/bundle/SOUL.md" "$FH/SOUL.md"
fi
# Custom skin.
mkdir -p "$FH/skins"
if [ -f "$SRC/bundle/skins/fireplace.yaml" ]; then
  cp "$SRC/bundle/skins/fireplace.yaml" "$FH/skins/fireplace.yaml"
fi
# Shipped read-only skills: the installer owns $FH/fireplace-skills wholesale.
rm -rf "$FH/fireplace-skills"
mkdir -p "$FH/fireplace-skills"
cp -R "$SRC/bundle/skills/." "$FH/fireplace-skills/"

# Marker: stop Hermes' per-launch sync_skills() from re-seeding upstream skills.
: > "$FH/.no-bundled-skills"

# Render config.template.yaml -> $FH/config.yaml via the bundled render_config(),
# run in a subshell so its environment doesn't leak into the installer. It
# substitutes the four @@FP_*@@ provider tokens from $FH/.llm-provider (defaulting
# to OpenRouter when absent) and keeps ${SECRET}/${HERMES_HOME} literal. Using the
# shared helper — instead of a hardcoded OpenRouter sed — means an UPGRADE PRESERVES
# the user's chosen provider (Anthropic/OpenAI) rather than resetting it, and
# re-applies an opted-in trading profile in a runtime-aware way (the $FH/.runtime
# stamp was written above, so render_config's container/native branch is correct).
info "Rendering config.yaml (secrets remain as \${VAR} placeholders)."
( . "$BUNDLE_DST/lib/common.sh" && render_config ) \
  || die "Failed to render config.yaml from the template."

# ----- 5. install shim + ensure PATH -----------------------------------------
info "Installing shim -> $SHIM_DST"
cp "$SRC/bundle/bin/fireplace" "$SHIM_DST"
chmod +x "$SHIM_DST"

ensure_on_path() {
  case ":$PATH:" in *":$LOCAL_BIN:"*) return 0 ;; esac
  local rc line='export PATH="$HOME/.local/bin:$PATH"'
  case "${SHELL:-}" in
    */zsh)  rc="$HOME/.zshrc" ;;
    */bash) if [ "$OS" = "Darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *)      rc="$HOME/.profile" ;;
  esac
  if [ -f "$rc" ] && grep -qF "$LOCAL_BIN" "$rc" 2>/dev/null; then
    return 0
  fi
  printf '\n# Added by Fireplace installer\n%s\n' "$line" >> "$rc"
  warn "Added $LOCAL_BIN to PATH in $rc — run 'source $rc' or open a new terminal."
}
ensure_on_path

# ----- 6. stamp versions + finish --------------------------------------------
printf '%s\n' "$BUNDLE_VERSION" > "$FIREPLACE_ROOT/VERSION"
printf '%s\n' "$PIN_HERMES"    > "$FIREPLACE_ROOT/ENGINE_VERSION"
# ($FIREPLACE_ROOT/.runtime was already stamped before the config render above.)

if [ "$IS_UPGRADE" -eq 1 ]; then
  success "Fireplace ${BUNDLE_VERSION} upgraded (engine ${PIN_HERMES}, ${RUNTIME} runtime)."
else
  success "Fireplace ${BUNDLE_VERSION} installed (engine ${PIN_HERMES}, ${RUNTIME} runtime)."
fi
track_install   # anonymous, keyless, opt-out (see FIREPLACE_TELEMETRY_URL above)
if [ "$RUNTIME" = "docker" ]; then
  info "The agent runs in a sandboxed Docker container; your data persists in $FH."
fi

# Show the full branded overview — the SAME screen as `fireplace help`: block logo
# + version line + command grid + capabilities + the cron/Telegram alerts section.
# Redirected to fd2 so it shares the installer's stream (and stays colored on a TTY).
if [ -r "$BUNDLE_DST/lib/help.sh" ]; then
  bash "$BUNDLE_DST/lib/help.sh" >&2 || true
fi
info "Run \`fireplace\` to get started — or \`fireplace help\` to see this screen again."
