<!-- Fireplace Agent — product README -->

# Fireplace Agent

**Fireplace Agent** is a terminal copilot for prediction markets. Ask it about
markets, events, order books, traders, smart-money flows, leaderboards, and
news — it answers from live Fireplace data and helps you reason about positions
and risk. By default it is **read-only**: it can look at everything and place
**nothing**.

```
  🔥 Fireplace Agent — your prediction-market copilot
```

Fireplace Agent is a single-tenant, branded CLI. Under the hood it runs a
**pinned, unmodified** build of the open-source
[`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent)
harness, isolated into its own home directory and wired to the **Fireplace MCP**
data server. We do not fork Hermes — we pin it (`v2026.6.19` / distribution
`0.17.0`) and wrap it with Fireplace config, persona, skin, and a small CLI shim.

---

## Install

One command. No Docker commands, no Python setup, no fiddling:

```bash
curl -fsSL https://get.fireplace.gg/install.sh | bash
```

The installer:

- **Picks a runtime automatically.** If Docker is available it builds a sandboxed
  **Fireplace runtime image** and runs the agent inside a container (recommended —
  see [Runtime](#runtime-docker-first) below). If Docker isn't installed, it
  transparently falls back to a **native** install (a dedicated `uv` virtualenv
  with the pinned Hermes build). Either way you just run `fireplace`.
- creates an isolated install under `~/.fireplace/` — it never touches a system
  Python or `~/.hermes`,
- installs the `fireplace` command to `~/.local/bin/` and makes sure it is on your
  `PATH` (it detects `zsh` vs `bash` and updates the right rc file),
- writes the Fireplace config, persona, skin, and skills into this install's
  private home (`~/.fireplace/home`), which is also the container's mounted data
  volume — so all your sessions, memory, and secrets persist on the host.

**Requirements:** macOS or Linux + `curl`. For the default container runtime,
**Docker** (Docker Desktop on macOS) installed and running. For the native
fallback, Python **3.11–3.13** via [`uv`](https://github.com/astral-sh/uv) (the
installer provisions both if missing).

Force a runtime if you like: `FIREPLACE_RUNTIME=docker` or `FIREPLACE_RUNTIME=native`.

### Runtime (Docker-first)

By default the agent runs in a container built from `bundle/docker/Dockerfile`
(`python:3.11-slim` + the pinned `hermes-agent[all]`). The image is **just the
engine**; everything that makes it Fireplace — config, persona, skin, skills,
your `.env`, and all state — lives in `~/.fireplace/home`, mounted at `/data`
(`HERMES_HOME`). Benefits:

- **Sandboxing.** Hermes' default toolset includes `terminal` + `code_execution`;
  in a container, anything the agent runs is confined off your host.
- **Reproducible + clean.** No host Python/PATH pollution; upgrades just rebuild.
- **Persistence.** Sessions/memory/secrets survive restarts via the mounted volume.

You never type a `docker` command — `fireplace`, `fireplace gateway`,
`fireplace doctor`, etc. all drive the container for you. The **gateway** runs as
a managed, auto-restarting service: `fireplace gateway` (start),
`fireplace gateway logs` / `stop` / `status`. (On the native runtime the gateway
runs in the foreground instead.)

> **Heads-up:** `hermes-agent[all]` pulls heavy browser/Playwright deps, so the
> first image build is large and takes a few minutes. We disable the `browser`
> toolset anyway; the build is a one-time cost.

---

## First run — the setup wizard

The first time you run `fireplace` (or any time you run `fireplace reset`), a
short wizard collects and **validates** three things before saving anything:

| # | Key | Required? | Validated against |
|---|-----|-----------|-------------------|
| 1 | **Fireplace API key** | Required | a live `tools/list` call to `https://data.fireplace.gg/mcp` |
| 2 | **Telegram bot token** | Optional (skippable) | `https://api.telegram.org/bot<token>/getMe` (`ok: true`) |
| 3 | **LLM provider + key** | Required | the chosen provider's API (see below) |

Validated secrets are written to `~/.fireplace/home/.env` (mode `600`). CLI-only
users skip Telegram and can add it later with `fireplace gateway setup`.

### Choose your LLM provider

**Bring-your-own LLM key.** Step 3 of the wizard lets you pick which provider
powers the agent — you are **not** locked into OpenRouter:

| Choice | Provider id | Env var | Default model | Key validated against |
|--------|-------------|---------|---------------|-----------------------|
| **OpenRouter** (default) | `openrouter` | `OPENROUTER_API_KEY` | `anthropic/claude-sonnet-4.5` | `GET https://openrouter.ai/api/v1/key` |
| **Anthropic** | `anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-4-5` | `GET https://api.anthropic.com/v1/models` |
| **OpenAI** | `openai` | `OPENAI_API_KEY` | `gpt-4.1` | `GET https://api.openai.com/v1/models` |

The wizard lets you override the default model id, then stores your choice in
`~/.fireplace/home/.llm-provider` so `config.yaml` renders (and `fireplace
doctor` checks) the right `provider` + env var. To change provider later, run
`fireplace reset`.

> **OpenAI note:** this needs an **OpenAI API key** (platform.openai.com, billed
> separately) — a ChatGPT Plus *subscription login* is not an API key and won't
> work. Provider ids/env vars come from Hermes' `PROVIDER_REGISTRY`; Anthropic
> also accepts `ANTHROPIC_TOKEN`.

A **hosted posture** — where Fireplace fronts the LLM behind one endpoint — is a
localized `model:` change, documented inline in `config.template.yaml`.

---

## Command surface

`fireplace <verb>` owns a small set of **branded lifecycle verbs** and forwards
everything else straight to the underlying agent (always with the isolated
`HERMES_HOME` exported). Just run `fireplace` with no arguments to start chatting.

### Branded verbs (intercepted by the shim)

| Command | What it does |
|---|---|
| `fireplace` | Start the chat TUI (runs the wizard automatically on first launch). |
| `fireplace help` | Show the branded overview screen: version, the full command grid, capabilities, and the **⏰ scheduled-alerts / cron** section. (Also `--help` / `-h`.) |
| `fireplace gateway` | Run the **Telegram bot** as a managed service — `start` / `stop` / `restart` / `logs` / `status` (Docker runtime); foreground on native. |
| `fireplace update` | Re-pin & refresh Hermes, the bundle, config, skin, and shipped skills. **Preserves** your `.env`, sessions, `MEMORY.md`, `auth.json`, and any agent-authored skills. |
| `fireplace reset` | Re-run the setup wizard. Backs up your existing `.env` to `.env.bak` first. |
| `fireplace uninstall` | Remove `~/.fireplace` and the shim (after confirmation). Offers to keep a backup of your `.env`/sessions. |
| `fireplace doctor` | Health check: runs the underlying `doctor` **plus** Fireplace checks — `HERMES_HOME` export, required config keys, `.env` placeholders resolve non-empty, MCP reachable (`get_leaderboard_categories`), and whether you're in the read-only or trading profile. |
| `fireplace enable-trading` | **Opt in to trading.** Rewrites config to add the 14 execution tools. |
| `fireplace disable-trading` | Revert to the read-only default profile. |

> **Note on shadowing:** these verbs intentionally shadow same-named subcommands
> in the underlying harness so Fireplace presents one clean branded surface
> (e.g. `fireplace update` runs *our* updater, not the harness's). Everything
> that is **not** in the table above is passed through verbatim — for example
> `fireplace gateway setup`, `fireplace sessions`, `fireplace memory`,
> `fireplace mcp`, `fireplace status`.

---

## ⏰ Scheduled alerts & automation (cron + Telegram)

Fireplace doesn't just answer questions — it can **run on a schedule and push you
Telegram alerts**, powered by the harness's cron + messaging toolsets. Just tell
the agent what to watch, in plain language:

- *"Every 15 minutes, DM me when smart money opens a position over $10k."*
- *"At 8am daily, send my open positions, P&L, and any markets resolving today."*
- *"Alert me on Telegram if YES on `<market>` drops below 0.40."*
- *"Watch for newly listed markets matching 'election' and ping me when one appears."*

It wires up a recurring job that re-runs the research and messages you on the
trigger. Manage jobs with `fireplace cron …`, or just describe (or cancel) the
alert in chat. **Requires** a Telegram bot token (add via `fireplace reset`) and
the gateway running (`fireplace gateway`). Run `fireplace help` to see this and
the full capability list on one screen.

---

## Guardrails — *can this agent place a trade without my approval?*

**In the default (shipped) profile: NO.** Here is exactly where every guard
lives, so you can audit it yourself.

| Layer | Where it lives | Strength | What it guarantees |
|---|---|---|---|
| **Tool allow-list** | `mcp_servers.fireplace.tools.include` in `config.yaml` — lists **only the 43 read tools** | **HARD (primary boundary)** | The 14 execution tools (`place_*`, `edit_order`, `cancel_*`, `redeem_positions`, `merge_positions`, `split_position`, `follow_wallet`, `unfollow_wallet`) are **never advertised to the model**, so it cannot call them. Safety **by construction** — no engine to misfire. |
| **Persona rule** | `SOUL.md` | Soft | Scope is markets/trading only; the agent must **never** place/cancel/redeem without an explicit, itemized in-turn confirmation of market + side + size + price. |
| **Approvals** | `approvals.mode: manual` in `config.yaml` | Defense-in-depth | Prompts before dangerous *shell* command execution. It does **NOT** gate MCP tool calls (confirmed in Hermes 0.17.0) — that is why the read-only boundary is the tool allow-list, not this prompt. |
| **Disabled toolsets** | `agent.disabled_toolsets: [browser, image_gen]` | Hardening | Removes browser automation and image generation from a trading CLI. |
| **Server-side key scoping** | Fireplace API key permissions (**server side, out of this repo's scope**) | **HARD (the real guarantee)** | A read-only-scoped key cannot execute trades **even if** a tool were somehow invoked. This is the ultimate backstop and is enforced by the Fireplace API, not by this CLI. |

### Turning on trading (opt-in)

`fireplace enable-trading` appends the 14 execution tools to the allow-list and
keeps `approvals.mode: manual` plus the `SOUL.md` confirmation rule in force.
Even then, **the real guarantee is server-side key scoping**: trading only works
if your Fireplace API key is itself scoped to allow it. `fireplace disable-trading`
reverts to the read-only allow-list.

---

## Honest limits

We aim to be a clean, purpose-built product, but a few rough edges are inherent
to wrapping (not forking) an upstream harness:

- **Residual upstream strings.** The on-disk binary is still named `hermes`, and
  deep `--help` text, stack traces, and `--version` output can surface
  "Hermes"/"Nous" strings. The Fireplace skin and persona cover the normal
  in-chat surface; the deep internals are not fully rebranded.
- **Approvals do not gate MCP tool calls.** Confirmed in Hermes 0.17.0:
  `approvals.mode: manual` only intercepts dangerous *shell* commands, never the
  agent's outbound MCP tool calls. That is *why* the default profile is read-only
  by tool-exclusion and trading leans on server-side key scoping + the persona
  confirmation rule — not on the approval prompt.
- **Clean-home caveat.** The wizard is suppressed by writing real config/keys.
  On a developer box, unrelated pre-existing credentials (GitHub Copilot,
  `~/.claude/.credentials.json`, a Nous `auth.json`) can *also* suppress it and
  mask a misconfiguration. Verify configuration in a clean `HOME` (the smoke
  test does exactly this).

---

## Isolation & upgrade model

Everything Fireplace manages lives under **`~/.fireplace/`** and is isolated via
the `HERMES_HOME` environment variable, which the `fireplace` shim exports so it
is inherited by the agent **and every child process it spawns** (gateway, cron,
Telegram worker). This matters: `HERMES_HOME` is read at import time from many
call sites and is **not** auto-propagated to subprocesses — a missed export would
silently write to `~/.hermes`. **Fireplace never touches `~/.hermes`.**

```
~/.fireplace/
├── .runtime                  # 'docker' or 'native' (chosen at install)
├── venv/                     # dedicated uv venv with pinned Hermes (native runtime only)
├── home/                     # this install's HERMES_HOME ($FH); mounted at /data in the container
│   ├── config.yaml           # model, MCP server, allow-list, guardrails, skin
│   ├── .env                  # secrets (chmod 600)
│   ├── SOUL.md               # Fireplace persona
│   ├── skins/fireplace.yaml  # branded skin (#FF6A3D accent)
│   ├── fireplace-skills/     # shipped read-only skills (+ MANIFEST)
│   ├── .no-bundled-skills    # stops upstream skill re-seeding
│   └── sessions/ MEMORY.md auth.json   # runtime state — never clobbered on upgrade
├── bundle/                   # product bundle (wizard, lib, templates, skills, skins)
├── VERSION                   # 0.1.0
└── HERMES_VERSION            # v2026.6.19
```

**Upgrades (`fireplace update`)** re-pin Hermes and refresh the bundle, config,
skin, and the shipped `fireplace-skills/` directory wholesale, while
**preserving** your `.env`, `sessions/`, `MEMORY.md`, `auth.json`, and any
skills you or the agent authored in `~/.fireplace/home/skills/`. Shipped skills
use the reserved `fireplace-` name prefix and are installer-owned; your own
skills must **not** use that prefix and are never overwritten.

---

## Testing

```bash
bash test/smoke.sh            # offline: installs into an isolated temp HOME and
                              # asserts every static/config invariant
SMOKE_LIVE=1 bash test/smoke.sh   # additionally installs real Hermes and runs a live self-check
```

The smoke test never touches your real install or `~/.hermes`. See the
TEST-HOOK CONTRACT comment at the top of `test/smoke.sh` for the non-interactive
hooks it expects from `install.sh` and `wizard.sh`.

---

## TODO

- [ ] **Homebrew tap.** `Formula/fireplace.rb` is a non-functional placeholder.
      Stand up the `fireplace/tap` tap and publish a release tarball so users can
      `brew install fireplace/tap/fireplace`. See that file for the checklist.
