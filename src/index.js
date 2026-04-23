// Claude OAuth Worker — template
//
// Cloudflare Worker that sits between VSCode Claude Code (or any other Claude
// Max client) and Anthropic's API. Does three things:
//   1. Proxies `/v1/messages` and other API paths to `api.anthropic.com`.
//   2. When `ENABLE_AUTH_INJECTION === "true"`, refreshes Claude OAuth access
//      tokens server-side using a refresh token stored as a Worker secret,
//      caches them in Cloudflare KV, and attaches them to outbound requests.
//   3. Serves a stub at `/addin/*` for building sideloaded Office add-ins
//      later. (Optional — remove if not needed.)
//
// Why: some networks DNS-block `api.anthropic.com` and `platform.claude.com`
// (the OAuth refresh endpoint). Cloudflare Worker URLs `*.workers.dev` are
// typically not blocked. Point your Claude Code `ANTHROPIC_BASE_URL` at this
// Worker, and OAuth refresh happens from Cloudflare's network instead of
// your laptop.
//
// Paired with the "Shape B" trick (fake `expiresAt` in `~/.claude/.credentials.json`)
// this gives you an indefinite no-logout experience. See README for setup.

const CLAUDE_OAUTH = {
  // Claude Code's OAuth token endpoint (reverse-engineered from the public
  // claude-code VSCode extension — same values are in its `extension.js`).
  TOKEN_URL: "https://platform.claude.com/v1/oauth/token",
  // Production client ID from claude-code. Same for everyone.
  CLIENT_ID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  SCOPE: "user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code",
};

async function getFreshAccessToken(env) {
  // Serve from KV cache if still valid (60s safety buffer).
  const cached = await env.CLAUDE_TOKEN_CACHE.get("access_token", { type: "json" });
  if (cached && cached.expiresAt > Date.now() + 60_000) {
    return cached.accessToken;
  }

  // Prefer the KV-stored refresh token (which may have been rotated from the
  // original seed). Fall back to the secret if KV is empty.
  let refreshToken = await env.CLAUDE_TOKEN_CACHE.get("refresh_token");
  if (!refreshToken) refreshToken = env.CLAUDE_REFRESH_TOKEN;
  if (!refreshToken) {
    throw new Error(
      "No refresh token seeded. Run: wrangler secret put CLAUDE_REFRESH_TOKEN"
    );
  }

  const resp = await fetch(CLAUDE_OAUTH.TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: CLAUDE_OAUTH.CLIENT_ID,
      scope: CLAUDE_OAUTH.SCOPE,
    }),
  });

  if (!resp.ok) {
    const errBody = await resp.text();
    throw new Error(`OAuth refresh failed: ${resp.status} ${errBody.slice(0, 300)}`);
  }

  const data = await resp.json();
  const expiresAt = Date.now() + data.expires_in * 1000;

  await env.CLAUDE_TOKEN_CACHE.put(
    "access_token",
    JSON.stringify({ accessToken: data.access_token, expiresAt }),
    { expirationTtl: Math.max(60, data.expires_in - 60) }
  );

  // Handle refresh-token rotation: persist the new one so future refreshes
  // use it instead of the (now-dead) seed.
  const newRefresh = data.refresh_token || refreshToken;
  if (newRefresh !== refreshToken) {
    await env.CLAUDE_TOKEN_CACHE.put("refresh_token", newRefresh);
  }

  return data.access_token;
}

// Placeholder served at `/addin/taskpane.html`. Replace with real Office.js
// content once you start building a sideloaded Excel/PowerPoint add-in, or
// delete the /addin branch below if you don't need it.
const ADDIN_STUB_HTML = `<!doctype html>
<meta charset="utf-8">
<title>Claude add-in stub</title>
<body style="font-family:system-ui;padding:2rem">
<h3>Claude add-in stub</h3>
<p>Replace this with your Office.js task pane.</p>
</body>`;

export default {
  async fetch(request, env) {
    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, GET, OPTIONS, PUT, DELETE",
          "Access-Control-Allow-Headers": "*",
        },
      });
    }

    const url = new URL(request.url);

    // Optional: static assets for a sideloaded Office add-in.
    if (url.pathname.startsWith("/addin/")) {
      const sub = url.pathname.slice("/addin/".length);
      if (sub === "" || sub === "taskpane.html") {
        return new Response(ADDIN_STUB_HTML, {
          status: 200,
          headers: {
            "content-type": "text/html; charset=utf-8",
            "Access-Control-Allow-Origin": "*",
          },
        });
      }
      return new Response("Not found", { status: 404 });
    }

    // Default: proxy to api.anthropic.com
    const targetUrl = "https://api.anthropic.com" + url.pathname + url.search;

    const proxyHeaders = new Headers(request.headers);
    proxyHeaders.delete("Host");
    proxyHeaders.delete("Origin");
    proxyHeaders.delete("Referer");

    // Feature-flagged auth injection. When OFF (default), the Worker is a
    // transparent pass-through — same behavior as before this extension was
    // added. When ON, the Worker mints a fresh access token server-side and
    // overwrites whatever the client sent.
    if (env.ENABLE_AUTH_INJECTION === "true") {
      try {
        const freshToken = await getFreshAccessToken(env);
        proxyHeaders.set("Authorization", `Bearer ${freshToken}`);
      } catch (e) {
        return new Response(
          JSON.stringify({
            error: { type: "oauth_refresh_error", message: String((e && e.message) || e) },
          }),
          {
            status: 502,
            headers: {
              "content-type": "application/json",
              "Access-Control-Allow-Origin": "*",
            },
          }
        );
      }
    }

    const response = await fetch(targetUrl, {
      method: request.method,
      headers: proxyHeaders,
      body: request.body,
    });

    const newHeaders = new Headers(response.headers);
    newHeaders.set("Access-Control-Allow-Origin", "*");
    return new Response(response.body, { status: response.status, headers: newHeaders });
  },
};
