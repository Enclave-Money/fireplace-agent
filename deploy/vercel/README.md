# Fireplace installer host (Vercel)

Serves `https://get.fireplace.gg/install.sh` and records anonymous install
analytics to PostHog **server-side** — the PostHog key lives only in a Vercel env
var and is **never** shipped inside the `curl | bash` script.

## What's here

- `vercel.json` — rewrites `/install.sh` → the `api/install` function.
- `api/install.js` — serves the installer (proxied from the pinned GitHub tag) and
  logs a `cli_install_script_fetched` event.
- `api/installed.js` — the keyless endpoint `install.sh` pings on a **completed**
  install; logs `cli_install_completed` with os / arch / runtime / version.

## Deploy

```bash
cd deploy/vercel
vercel deploy --prod            # or connect this dir as a Vercel project

# Set env vars (Project → Settings → Environment Variables):
#   POSTHOG_KEY   = phc_… (your "Fireplace Pro" project key; server-side only)
#   POSTHOG_HOST  = https://us.i.posthog.com   (optional; this is the default)
#   REPO_OWNER    = Enclave-Money              (optional)
#   REPO_REF      = v0.1.0                     (bump per release)

# Add the domain:  Project → Settings → Domains → get.fireplace.gg
```

Then `curl -fsSL https://get.fireplace.gg/install.sh | bash` works, and you get:

- **Fetches** (every curl of the installer) → `cli_install_script_fetched`
- **Completed installs** (the installer finished) → `cli_install_completed`,
  with OS / architecture / runtime (docker|native) / version breakdowns.

Build PostHog insights/dashboards on those two events for an accurate funnel.

## Notes

- The installer's completion ping is **opt-out** (`DO_NOT_TRACK=1` or
  `FIREPLACE_NO_ANALYTICS=1`) and **keyless** — it only hits your own domain.
- Bump `REPO_REF` (and redeploy) when you cut a new release tag so the served
  script matches the published version.
