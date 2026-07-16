#!/usr/bin/env python3
"""Rebrand the engine's USER-VISIBLE strings to "Fireplace" in OUR installed copy.

This is a display-string rebrand of our own install — NOT a source fork. The
upstream engine hardcodes its product / author / command name in banners, tips,
and one-time notices; we rewrite those strings so the running product reads
"Fireplace". Applied by install.sh (native venv) and the Dockerfile (image build),
and re-applied by `fireplace update`.

Safe by construction:
  - "Nous Research"                      -> "Fireplace"
  - standalone "Hermes"                  -> "Fireplace" (STRING LITERALS ONLY)
       (NOT inside an identifier like HermesConfig, and NOT "Hermes-<x>" model
        ids — the regex requires a non-word, non-dash boundary on both sides)
  - command suggestions "hermes <cmd>"   -> "fireplace <cmd>" (STRING LITERALS ONLY)
       (the shim passes unknown verbs straight through, so the rebranded command
        still works; "hermes " with a trailing space is never used to exec a
        command in the engine — only ever shown to the user)

The last two substitutions are scoped to STRING LITERAL spans only (see
_STRING_RE / _rebrand_in_strings below) — never applied to bare source code.
This is load-bearing, not cosmetic: earlier versions of this script matched
anywhere in the raw file text, including real Python identifiers. Upstream
code that happens to declare a local variable literally named `hermes`
(e.g. `hermes = metadata.get("hermes") or {}`, reading a `hermes:` frontmatter
key) got its declaration renamed to `fireplace = ...` (since "hermes " followed
by a space matched) while later bare uses of that same variable
(`hermes.get(...)`, `hermes,` — not followed by a space) did NOT match and
were left referring to a name that no longer existed, producing
`NameError: name 'hermes' is not defined` at runtime — surfacing as a
misleading "API call" error in the CLI, since the exception is caught several
frames up. Scoping every identifier-shaped substitution to string content
makes that entire class of bug structurally impossible: a bare code
identifier is never inside a string literal, so it can never match.

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

# Whole-file substitutions — safe to apply anywhere. A two-word phrase can
# never collide with a Python identifier, so no string-literal scoping needed.
WHOLE_FILE_SUBS = [
    (re.compile(r"Nous Research"), "Fireplace"),
]

# Identifier-shaped substitutions — MUST be scoped to string literals only
# (see module docstring for why). Applied via _rebrand_in_strings, not here.
IN_STRING_SUBS = [
    # standalone capitalized "Hermes" — not part of an identifier (HermesConfig)
    # and not a "Hermes-<x>" model id (dash excluded on both sides).
    (re.compile(r"(?<![\w-])Hermes(?![\w-])"), "Fireplace"),
    # lowercase command name in a suggestion: "hermes <subcommand>". The trailing
    # space and the lookbehind keep this off paths (~/.hermes, /opt/hermes) and
    # identifiers (hermes_cli).
    (re.compile(r"(?<![\w/.])hermes(?= )"), "fireplace"),
]

# Approximate Python string-literal matcher: triple-quoted (''' / \"\"\"),
# single-quoted, or double-quoted, with an optional string-prefix (f/r/b/u,
# any case/combination). Good enough to scope a rebrand pass — doesn't need
# to be a full tokenizer, just needs to never span into real code.
_STRING_RE = re.compile(
    r"""[rRbBfFuU]{0,2}(?:'''(?:[^\\]|\\.)*?'''|\"\"\"(?:[^\\]|\\.)*?\"\"\"|'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\")""",
    re.DOTALL,
)


def _rebrand_in_strings(text):
    def repl(match):
        s = match.group(0)
        for rx, rep in IN_STRING_SUBS:
            s = rx.sub(rep, s)
        return s
    return _STRING_RE.sub(repl, text)


def patch_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except Exception:
        return 0
    original = text
    for rx, rep in WHOLE_FILE_SUBS:
        text = rx.sub(rep, text)
    text = _rebrand_in_strings(text)
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
