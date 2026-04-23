// Dedicated Worker for proxying Anthropic's official Claude for Office
// add-in (hosted at pivot.claude.ai). Lets the sideloaded add-in load and
// authenticate from a DNS-blocked environment.
//
// Deploy target: your pivot Worker URL (set `name` in wrangler.toml).
// Used by the sideloaded official Claude add-in with SourceLocation changed
// from pivot.claude.ai → this Worker's URL.
//
// Runtime config via env vars (set in wrangler.toml [env.pivot.vars]):
//   MAIN_WORKER_URL   URL of your main api.anthropic.com proxy Worker
//                     (the thing your VSCode Claude Code points at). The
//                     add-in's inference calls to api.anthropic.com get
//                     rewritten to hit MAIN_WORKER_URL instead, so they
//                     route through your existing Anthropic proxy rather
//                     than the DNS-blocked api.anthropic.com.

// Paste-in helper: lets the user capture localStorage from a successful
// sign-in on another machine / phone and inject it into this Worker's origin
// so the proxied add-in thinks it's signed in. Accessed at /_/inject.
const INJECT_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>Inject auth</title>
<style>
  body{font-family:system-ui;max-width:760px;margin:20px auto;padding:0 16px;font-size:14px;}
  h2{margin-top:0;}
  textarea{width:100%;height:260px;font-family:monospace;font-size:12px;padding:8px;box-sizing:border-box;}
  button{padding:8px 14px;margin-top:8px;cursor:pointer;}
  .hint{color:#555;font-size:13px;margin:6px 0;}
  code{background:#f4f4f4;padding:2px 5px;border-radius:3px;}
  pre{background:#f4f4f4;padding:10px;overflow-x:auto;border-radius:4px;}
  #out{background:#eef;padding:8px;border-radius:3px;margin-top:8px;}
  .row{display:flex;gap:12px;align-items:center;flex-wrap:wrap;}
</style></head><body>
<h2>Inject auth into ccvs-pivot (this origin)</h2>
<p class="hint">Use this to transplant localStorage + sessionStorage captured
from a successful Claude-add-in sign-in elsewhere (phone, personal laptop).
The proxied add-in at this origin will then behave as if signed in.</p>

<h3>Step 1 &mdash; on the device where sign-in works</h3>
<p>Load <code>https://pivot.claude.ai</code> in Excel (or a desktop Chrome/Edge with
Office.js), sign in. Then in that device's DevTools console, run:</p>
<pre id="snippet">JSON.stringify({
  localStorage:   Object.fromEntries(Object.entries(localStorage)),
  sessionStorage: Object.fromEntries(Object.entries(sessionStorage)),
  cookie:         document.cookie
}, null, 2)</pre>
<button onclick="navigator.clipboard.writeText(document.getElementById('snippet').innerText)">Copy snippet</button>

<h3>Step 2 &mdash; paste the output below</h3>
<textarea id="payload" placeholder='{"localStorage":{...},"sessionStorage":{...},"cookie":"..."}'></textarea>
<div class="row">
  <button onclick="inject()">Inject &rarr; open add-in</button>
  <button onclick="dump()">Dump current (ccvs-pivot) storage for comparison</button>
  <button onclick="clearAll()" style="color:#b00;">Clear all storage on this origin</button>
</div>
<pre id="out"></pre>

<script>
function setOut(s){document.getElementById("out").innerText = s;}
function inject(){
  let data;
  try { data = JSON.parse(document.getElementById("payload").value); }
  catch(e){ setOut("Invalid JSON: " + e.message); return; }
  let n = 0;
  if (data.localStorage) for (const [k,v] of Object.entries(data.localStorage)) {
    localStorage.setItem(k, v); n++;
  }
  if (data.sessionStorage) for (const [k,v] of Object.entries(data.sessionStorage)) {
    sessionStorage.setItem(k, v); n++;
  }
  if (data.cookie) {
    data.cookie.split(/;\\s*/).forEach(pair => {
      if (pair) document.cookie = pair + "; path=/; secure; samesite=none";
    });
  }
  setOut("Injected " + n + " storage entries. Opening /...");
  setTimeout(() => location.href = "/", 600);
}
function dump(){
  const d = {
    localStorage: Object.fromEntries(Object.entries(localStorage)),
    sessionStorage: Object.fromEntries(Object.entries(sessionStorage)),
    cookie: document.cookie
  };
  setOut(JSON.stringify(d, null, 2));
}
function clearAll(){
  if (!confirm("Wipe localStorage, sessionStorage, and cookies on this origin?")) return;
  localStorage.clear();
  sessionStorage.clear();
  document.cookie.split(";").forEach(c => {
    const eq = c.indexOf("=");
    const name = (eq > -1 ? c.slice(0, eq) : c).trim();
    document.cookie = name + "=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/";
  });
  setOut("Cleared.");
}
</script>
</body></html>`;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Built-in helper page (doesn't hit pivot.claude.ai).
    if (url.pathname === "/_/inject") {
      return new Response(INJECT_HTML, {
        status: 200,
        headers: {
          "content-type": "text/html; charset=utf-8",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }

    // Proxy the Anthropic OAuth token endpoint. The add-in hits this with a
    // POST (grant_type=authorization_code + code + code_verifier + redirect_uri)
    // to exchange the authorize code for real tokens. We forward to claude.ai
    // from Cloudflare's network (which isn't DNS-blocked on the client's side).
    if (url.pathname === "/v1/oauth/token") {
      const fwdHeaders = new Headers(request.headers);
      fwdHeaders.delete("Host");
      fwdHeaders.delete("Origin");
      fwdHeaders.delete("Referer");
      if (!fwdHeaders.has("user-agent")) {
        fwdHeaders.set("user-agent", "Mozilla/5.0 (Office; Claude-add-in)");
      }
      const fwd = await fetch("https://claude.ai/v1/oauth/token", {
        method: request.method,
        headers: fwdHeaders,
        body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
        redirect: "manual",
      });
      const h = new Headers(fwd.headers);
      h.set("Access-Control-Allow-Origin", "*");
      h.set("Access-Control-Allow-Methods", "POST, OPTIONS");
      h.set("Access-Control-Allow-Headers", "*");
      h.delete("content-length");
      h.delete("content-encoding");
      return new Response(fwd.body, { status: fwd.status, headers: h });
    }

    // Same pattern for the authorize endpoint — used if the add-in fetches
    // its OAuth authorize URL from a base of our Worker origin (after bundle
    // rewrite). Returns a 302 to the real claude.ai/oauth/authorize so the
    // user's device follows the redirect to the Anthropic login page.
    if (url.pathname === "/oauth/authorize") {
      return Response.redirect("https://claude.ai/oauth/authorize" + url.search, 302);
    }

    const upstream = "https://pivot.claude.ai" + url.pathname + url.search;

    const upstreamHeaders = new Headers(request.headers);
    upstreamHeaders.delete("Host");
    upstreamHeaders.delete("Origin");
    upstreamHeaders.delete("Referer");
    if (!upstreamHeaders.has("user-agent")) {
      upstreamHeaders.set("user-agent", "Mozilla/5.0 (Office; Claude-add-in)");
    }

    const resp = await fetch(upstream, {
      method: request.method,
      headers: upstreamHeaders,
      body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
      redirect: "manual",
    });

    const workerOrigin = url.origin;
    const outHeaders = new Headers(resp.headers);
    outHeaders.delete("content-length");
    outHeaders.delete("content-encoding");
    outHeaders.set("Access-Control-Allow-Origin", "*");
    // Prevent WebView2 / browser from caching the HTML or JS we rewrite —
    // otherwise Office serves a stale copy and our surgical OAuth-URL
    // rewrite never takes effect.
    outHeaders.set("Cache-Control", "no-store, must-revalidate");
    outHeaders.delete("etag");
    outHeaders.delete("last-modified");

    // Rewrite absolute redirects back to pivot.claude.ai → this Worker.
    const loc = outHeaders.get("location");
    if (loc && loc.startsWith("https://pivot.claude.ai")) {
      outHeaders.set("location", loc.replace("https://pivot.claude.ai", workerOrigin));
    }

    const contentType = resp.headers.get("content-type") || "";
    const textual = /\b(text\/|application\/(javascript|json|xml|xhtml)|image\/svg\+xml)/.test(contentType);

    if (textual) {
      let body = await resp.text();
      body = body.replaceAll("https://pivot.claude.ai", workerOrigin);
      body = body.replaceAll("//pivot.claude.ai", "//" + url.hostname);

      // Surgical rewrite for OAuth: force the registered redirect_uri so
      // Anthropic's authorize endpoint accepts the request. User completes
      // sign-in on a device where pivot.claude.ai resolves, then transfers
      // auth state back via /_/inject.
      body = body.replace(
        /`\$\{window\.location\.origin\}\/auth\/callback`/g,
        '"https://pivot.claude.ai/auth/callback"'
      );
      body = body.replace(
        /window\.location\.origin\s*\+\s*["']\/auth\/callback["']/g,
        '"https://pivot.claude.ai/auth/callback"'
      );

      // Targeted rewrite of just the tokenEndpoint in the OAuth client
      // construction: force the token exchange POST to go through our proxy
      // (which can reach claude.ai), while leaving all other uses of the
      // claude.ai base URL alone (profile fetch, org queries, etc).
      // Original: tokenEndpoint:`${AZ()}${U8e}`  (evaluates to claude.ai/v1/oauth/token)
      body = body.replace(
        /tokenEndpoint:`\$\{[A-Za-z_$][A-Za-z0-9_$]*\(\)\}\$\{[A-Za-z_$][A-Za-z0-9_$]*\}`/g,
        `tokenEndpoint:"${workerOrigin}/v1/oauth/token"`
      );

      // Rewrite A1() (returns "https://api.anthropic.com") to return the
      // main Anthropic-API proxy Worker instead. The add-in's inference
      // calls to /v1/messages then route through there (which proxies to
      // the real api.anthropic.com from Cloudflare's network, not from
      // the DNS-blocked client). Skipped if MAIN_WORKER_URL isn't set
      // (add-in will then try to hit api.anthropic.com directly and fail
      // in a DNS-blocked environment).
      const mainWorker = (env.MAIN_WORKER_URL || "").replace(/\/$/, "");
      if (mainWorker) {
        body = body.replace(
          /(function\s+[A-Za-z_$][A-Za-z0-9_$]*\s*\(\)\s*\{\s*return)\s*"https:\/\/api\.anthropic\.com"(\s*\})/g,
          `$1"${mainWorker}"$2`
        );
      }

      // WebView2 / Office aggressively caches add-in resources by URL.
      // To force fresh loads when the HTML entry page is fetched, append a
      // cache-busting query to the asset URLs it references.
      if (contentType.includes("text/html")) {
        const bust = "_v=" + Date.now();
        body = body.replace(
          /(src|href)="(\/m-addin\/[^"]+)"/g,
          (_, attr, path) => `${attr}="${path}${path.includes('?') ? '&' : '?'}${bust}"`
        );
      }

      return new Response(body, { status: resp.status, headers: outHeaders });
    }
    return new Response(resp.body, { status: resp.status, headers: outHeaders });
  },
};
