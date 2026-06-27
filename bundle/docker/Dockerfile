# =============================================================================
# Fireplace Agent — Hermes runtime image
# -----------------------------------------------------------------------------
# This image contains ONLY the pinned Hermes engine. Everything that makes it
# "Fireplace" — config.yaml, SOUL.md, the skin, the shipped skills, the .env
# secrets, and all runtime state (sessions, memory) — lives in the host
# directory ~/.fireplace/home, which install.sh renders and the shim mounts at
# /data (== HERMES_HOME). So upgrading branding/config never needs an image
# rebuild; only a Hermes version bump does.
#
# Built automatically by install.sh:
#   docker build -t fireplace-agent:<version> \
#     --build-arg HERMES_SPEC='hermes-agent[all]==0.17.0' bundle/docker
# The user never runs this by hand.
# =============================================================================
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HERMES_HOME=/data \
    HERMES_CONTAINER=1 \
    PATH=/opt/hermes/bin:$PATH

# git + ca-certificates: needed for git-ref installs and TLS to the LLM/MCP
# endpoints. curl: in-container health checks. tini: proper PID-1 signal
# handling so Ctrl-C / SIGTERM reach Hermes cleanly in the TUI and the gateway.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl tini \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

# Pinned Hermes harness, installed into a dedicated venv at /opt/hermes. Override
# the spec at build time, e.g. to pin the git ref instead of the PyPI release:
#   --build-arg HERMES_SPEC='hermes-agent[all] @ git+https://github.com/NousResearch/hermes-agent@v2026.6.19'
ARG HERMES_SPEC=hermes-agent[all]==0.17.0
RUN uv venv /opt/hermes --python 3.11 \
 && uv pip install --python /opt/hermes/bin/python --no-cache "${HERMES_SPEC}" \
 && /opt/hermes/bin/hermes --version

# Rebrand the engine's user-visible display strings in this installed copy so the
# TUI banner, tips, and notices read "Fireplace" (a string rebrand of our own
# image, not a source fork). Best-effort; never fails the build.
COPY brand-patch.py /tmp/brand-patch.py
RUN SITE="$(/opt/hermes/bin/python -c 'import hermes_cli,os;print(os.path.dirname(os.path.dirname(hermes_cli.__file__)))')" \
 && /opt/hermes/bin/python /tmp/brand-patch.py "$SITE" || true

# State + config live in the mounted volume.
VOLUME ["/data"]
WORKDIR /data

# ENTRYPOINT is the hermes binary, so `docker run <image> <args>` == `hermes <args>`
# (the shim appends the user's subcommand/args). tini reaps zombies and forwards
# signals. No CMD: a bare `docker run` launches the interactive Hermes TUI.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/hermes/bin/hermes"]
