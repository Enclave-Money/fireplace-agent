// Serves get.fireplace.gg/install.sh and records the FETCH server-side.
// The PostHog key lives ONLY here (Vercel env var POSTHOG_KEY) — it is NEVER
// shipped to end users. We proxy the installer from the pinned tag so the served
// script always matches a released version.
//
// Env vars (set in the Vercel project):
//   POSTHOG_KEY   PostHog project (phc_…) key — server-side only
//   POSTHOG_HOST  default https://us.i.posthog.com
//   REPO_OWNER    default Enclave-Money
//   REPO_REF      default v0.1.0  (the tag to serve)

export default async function handler(req, res) {
  const owner = process.env.REPO_OWNER || "Enclave-Money";
  const ref = process.env.REPO_REF || "v0.1.0";
  const rawUrl = `https://raw.githubusercontent.com/${owner}/fireplace-agent/${ref}/install.sh`;

  // Fire-and-forget fetch event (never blocks or breaks serving the script).
  const key = process.env.POSTHOG_KEY;
  const host = process.env.POSTHOG_HOST || "https://us.i.posthog.com";
  if (key) {
    const ip = (req.headers["x-forwarded-for"] || "").split(",")[0].trim();
    fetch(`${host}/capture/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: key,
        event: "cli_install_script_fetched",
        distinct_id: `fetch-${Date.now()}-${Math.random().toString(36).slice(2)}`,
        properties: { user_agent: req.headers["user-agent"] || "", $ip: ip },
      }),
    }).catch(() => {});
  }

  try {
    const r = await fetch(rawUrl);
    if (!r.ok) throw new Error(`raw ${r.status}`);
    const body = await r.text();
    res.setHeader("Content-Type", "text/x-shellscript; charset=utf-8");
    res.setHeader("Cache-Control", "public, max-age=300");
    return res.status(200).send(body);
  } catch (_e) {
    return res.status(502).send("# Failed to fetch the Fireplace installer. Try again shortly.\n");
  }
}
