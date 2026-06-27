// get.fireplace.gg/api/installed — the keyless endpoint install.sh pings on a
// COMPLETED install. The script sends no API key; this function records the event
// to PostHog server-side using the POSTHOG_KEY env var (never exposed to clients).
//
// install.sh calls:
//   GET /api/installed?event=cli_install_completed&os=Darwin&arch=arm64
//       &runtime=docker&version=0.1.0&engine=v2026.6.19&upgrade=0

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  const key = process.env.POSTHOG_KEY;
  const host = process.env.POSTHOG_HOST || "https://us.i.posthog.com";
  try {
    if (key) {
      const q = req.query || {};
      const ip = (req.headers["x-forwarded-for"] || "").split(",")[0].trim();
      await fetch(`${host}/capture/`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          api_key: key,
          event: String(q.event || "cli_install_completed"),
          distinct_id: `cli-${ip || "anon"}-${Date.now()}`,
          properties: {
            os: q.os, arch: q.arch, runtime: q.runtime,
            version: q.version, engine: q.engine, upgrade: q.upgrade,
            user_agent: req.headers["user-agent"] || "", $ip: ip,
          },
        }),
      });
    }
  } catch (_e) {
    // Telemetry must never surface an error to the installer.
  }
  return res.status(204).end();
}
