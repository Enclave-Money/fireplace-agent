#!/usr/bin/env python3
"""Rebrand the engine's USER-VISIBLE strings to "Fireplace" in OUR installed copy.

This is a display-string rebrand of our own install — NOT a source fork. The
upstream engine hardcodes its product / author / command name in banners, tips,
and one-time notices; we rewrite those strings so the running product reads
"Fireplace". Applied by install.sh (native venv) and the Dockerfile (image build),
and re-applied by `fireplace update`.

Safe by construction:
  - "Nous Research"                      -> "Fireplace"
  - standalone "Hermes"                  -> "Fireplace"
       (NOT inside an identifier like HermesConfig, and NOT "Hermes-<x>" model
        ids — the regex requires a non-word, non-dash boundary on both sides)
  - command suggestions "hermes <cmd>"   -> "fireplace <cmd>"
       (the shim passes unknown verbs straight through, so the rebranded command
        still works; "hermes " with a trailing space is never used to exec a
        command in the engine — only ever shown to the user)

Usage: brand-patch.py <site-packages-dir>
Best-effort: never raises, never blocks an install. Only the engine's own
packages/modules are touched — never third-party dependencies.
"""
import os
import re
import sys

SITE = sys.argv[1] if len(sys.argv) > 1 else ""

# The engine's own top-level packages and modules (relative to site-packages).
TARGETS = [
    "hermes_cli", "agent", "gateway", "tools", "tui_gateway",
    "cli.py", "hermes_constants.py", "mcp_serve.py", "run_agent.py", "toolsets.py",
]

SUBS = [
    (re.compile(r"Nous Research"), "Fireplace"),
    # standalone capitalized "Hermes" — not part of an identifier (HermesConfig)
    # and not a "Hermes-<x>" model id (dash excluded on both sides).
    (re.compile(r"(?<![\w-])Hermes(?![\w-])"), "Fireplace"),
    # lowercase command name in a suggestion: "hermes <subcommand>". The trailing
    # space and the lookbehind keep this off paths (~/.hermes, /opt/hermes) and
    # identifiers (hermes_cli).
    (re.compile(r"(?<![\w/.])hermes(?= )"), "fireplace"),
]


def patch_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except Exception:
        return 0
    original = text
    for rx, rep in SUBS:
        text = rx.sub(rep, text)
    if text == original:
        return 0
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        return 1
    except Exception:
        return 0


def main():
    if not SITE or not os.path.isdir(SITE):
        return
    changed = 0
    for target in TARGETS:
        path = os.path.join(SITE, target)
        if os.path.isfile(path) and path.endswith(".py"):
            changed += patch_file(path)
        elif os.path.isdir(path):
            for dirpath, _dirs, files in os.walk(path):
                for name in files:
                    if name.endswith(".py"):
                        changed += patch_file(os.path.join(dirpath, name))
    print("brand-patch: rewrote %d engine file(s)" % changed)


main()
