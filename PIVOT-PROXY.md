# <your-pivot-name>: Proxy for Anthropic's official Claude-for-Office add-in

**Status: working but fragile.** See the "Known fragility" section before making changes.

## What this is

A Cloudflare Worker that lets you install and use Anthropic's official **Claude for Excel / PowerPoint / Word** add-in (Microsoft AppSource `WA200009404`) on a laptop where LG's Umbrella DNS filter blocks every Anthropic domain.

Without it: AppSource install fails with *"Add-in Claude failed to download a required resource"* because `pivot.claude.ai`, `claude.ai`, and `platform.claude.com` are all blocked.

With it: the official add-in runs inside Excel, authenticated against your real Claude Max account. All Anthropic traffic routes through `<your-pivot>.workers.dev` (Cloudflare, unblocked). Phone-based OAuth completes the sign-in.

- **Worker URL:** `https://<your-pivot>.workers.dev`
- **Source:** `src/pivot-proxy.js`
- **Deploy:** `wrangler deploy --env pivot`
- **Sideloaded manifests:**
  - Excel: `~/ClaudeAddin/manifest-official-claude-excel.xml`, registry `ClaudeProxiedExcel`
  - PowerPoint: `~/ClaudeAddin/manifest-official-claude-powerpoint.xml`, registry `ClaudeProxiedExcelPPT`
  - Both load the same React bundle; the bundle detects its host via `Office.onReady().host` and adapts (Excel = "sheet" surface, PowerPoint = "slides" surface)

---

## How it works (request flow)

```
Excel (task pane, WebView2)                             <your-pivot>.workers.dev (Cloudflare)
        │                                                         │
   ┌────┴─────────────┐        GET /?v=<time>                     │
   │ Modified manifest│ ─────────────────────────────────────────▶│ proxy → pivot.claude.ai/
   │ SourceLocation = │                                            │  (rewrites HTML: cache-bust
   │ /?v=<build>      │                                            │   asset URLs, strip caching)
   └──────────────────┘                                            │
                                                                   │
        GET /m-addin/assets/index-<hash>.js?_v=<time>  ───────────▶│ proxy → pivot.claude.ai
                                                                   │  (rewrites JS):
                                                                   │   - E0() → returns
                                                                   │     "https://pivot.claude.ai/auth/callback"
                                                                   │     (registered redirect_uri, not
                                                                   │      <your-pivot-name>.../auth/callback)
                                                                   │   - tokenEndpoint → string literal
                                                                   │     "https://<your-pivot-name>.../v1/oauth/token"
                                                                   │     (so the add-in's token exchange
                                                                   │      goes through this Worker, which
                                                                   │      reaches real claude.ai)
                                                                   │   - pivot.claude.ai → this Worker's
                                                                   │     origin (for asset URLs)
                                                                   │
        Click Sign-in                                              │
        → authorize URL opened (claude.ai/oauth/authorize          │
        with valid registered redirect_uri=pivot.claude.ai/...)    │
        → user copies URL to phone                                 │
                                                                   │
   Phone: hits claude.ai (resolves normally), user auths,          │
   redirected to pivot.claude.ai/auth/callback?code=xxx            │
                                                                   │
   Add-in (still alive in Excel's task pane, sessionStorage        │
   has code_verifier) navigates to /auth/callback?code=xxx         │
                                                                   │
        POST /v1/oauth/token                                       │
        (code + code_verifier + redirect_uri)           ──────────▶│ proxy POST → claude.ai/v1/oauth/token
                                                                   │
        ◀────────────────────────── {access_token, refresh_token, ...}
                                                                   │
   Add-in stores tokens in localStorage (origin <your-pivot-name>...).    │
   On every API call, add-in reads access_token and sends          │
   Authorization: Bearer <token> to api.anthropic.com (via main    │
   main Worker, which ALSO auth-injects — but since the add-in     │
   provides its own valid token, main Worker's injection is        │
   cosmetic here).                                                 │
                                                                   │
   When access token nears expiry, add-in silently POSTs           │
   a refresh-token grant to /v1/oauth/token via this Worker        │
   → claude.ai → new tokens → stored → no user interaction.        │
```

---

## The surgical bundle rewrites

All applied in `src/pivot-proxy.js` when serving text/JS responses.

| Rewrite | Why | Pattern |
|---|---|---|
| `https://pivot.claude.ai` → Worker origin | Asset URLs in HTML/JS reference the origin | `body.replaceAll("https://pivot.claude.ai", workerOrigin)` |
| ``` `${window.location.origin}/auth/callback` ``` → `"https://pivot.claude.ai/auth/callback"` | The add-in's `E0()` builds the redirect_uri from `window.location.origin`, which on our proxy resolves to <your-pivot-name> — not a registered URI with Anthropic's OAuth. Hardcoded to the registered URI. | Regex on the template literal |
| `tokenEndpoint:`` `${AZ()}${U8e}` `` → `tokenEndpoint:"<workerOrigin>/v1/oauth/token"` | OAuth client's token exchange endpoint. Rewriting just this (not the whole base URL) sends the token POST through our proxy while leaving `claude.ai` API calls alone. | Regex on the tokenEndpoint construction |
| Cache-busting `?_v=<timestamp>` on `/m-addin/*` asset URLs in HTML | Forces WebView2 to refetch bundle when HTML is re-served, so rewrites propagate | `body.replace(/(src\|href)="(\/m-addin\/[^"]+)"/g, ...)` |
| `Cache-Control: no-store` on all responses | Prevents Office-level caching of stale bundle | Set on outgoing headers |

---

## Auth flow — from scratch

If you don't have a working sign-in yet:

1. **Make sure the proxied add-in loads cleanly.** Open Excel → Insert → My Add-ins → Developer Add-ins → "Claude (proxied)". Task pane should render (not blank). If blank, go to Troubleshooting → "task pane is blank".
2. **Click Sign in.** The add-in shows a URL or a popup with a URL.
3. **Copy the URL.** Sanity-check: `redirect_uri=https%3A%2F%2Fpivot.claude.ai%2Fauth%2Fcallback`. If it's not that, go to Troubleshooting → "redirect_uri wrong".
4. **Paste URL on phone (or any device where claude.ai resolves).** Sign in with your Claude account, click Authorize.
5. Phone lands on `https://pivot.claude.ai/auth/callback?code=...`. The page may be blank/error — that's fine.
6. **In some versions of the add-in, the phone completion automatically signals back** (Anthropic uses a device-code-style mechanism and the add-in polls). If that works, you're signed in with no further steps.
7. **If step 6 doesn't complete automatically:** copy the full phone URL. In Excel's task pane: right-click → Inspect → Console. Paste:

    ```js
    const cbUrl = new URL(prompt("Paste callback URL from phone:"));
    const code  = cbUrl.searchParams.get("code");
    const state = cbUrl.searchParams.get("state");
    window.location.href = `/auth/callback?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`;
    ```
    Paste the phone URL at the prompt. Task pane navigates to its own callback handler, the add-in completes the token exchange via the proxy, and you're signed in.

Once signed in, tokens persist across Excel restarts. Refresh happens silently.

---

## Troubleshooting

### Task pane is blank

Most likely cause: a bundle rewrite broke initialization. If you recently edited `pivot-proxy.js` and changed a rewrite pattern, revert and redeploy.

Diagnose:
1. Right-click task pane → Inspect → Console.
2. Look for red errors. If "Uncaught SyntaxError" or "function X is not defined", a rewrite mangled the bundle.
3. Network tab → check if `/m-addin/assets/index-*.js` returned 200 and has reasonable size (~6 MB).

Fix: `wrangler rollback --env pivot` to the previous Worker version. Or revert the offending commit in `pivot-proxy.js`.

### "Redirect URI ... is not supported by client" when authorizing

Means the `E0()` rewrite failed — the OAuth URL has `redirect_uri=https://<your-pivot-name>...` instead of `pivot.claude.ai`.

Diagnose:
1. In DevTools console:
    ```js
    fetch('/m-addin/assets/' + document.querySelector('script[src*="index-"]').src.split('/').pop())
      .then(r => r.text())
      .then(t => {
        const m = t.match(/function [A-Za-z0-9_$]{1,5}\(\)\{return"[^"]*\/auth\/callback"\}/);
        console.log('Callback function:', m && m[0]);
        console.log('Template literal still present?', /\${[^}]*location\.origin[^}]*}\/auth\/callback/.test(t));
      });
    ```
2. If "Template literal still present? true", our regex didn't match. Anthropic changed the minification.

Fix: fetch the current bundle (`curl https://<your-pivot>.workers.dev/m-addin/assets/<hash>.js > /tmp/b.js`), find how the new bundle constructs the callback URL, update the regex in `pivot-proxy.js`, redeploy.

### Sign-in URL has `redirect_uri=https%3A%2F%2F<your-pivot-name>...`

Same as above — E0 rewrite failed. Fix the regex.

### Sign-in URL has the right redirect_uri but auth still fails after phone

Check the Network tab in DevTools when the add-in attempts the token exchange:
- Request URL should be `https://<your-pivot>.workers.dev/v1/oauth/token` (NOT `claude.ai/v1/oauth/token` directly).
- If it's hitting `claude.ai` directly, the `tokenEndpoint` rewrite missed. Current regex targets ``` `${AZ()}${U8e}` ``` — check the bundle to see if the minified form changed.
- If request URL is our Worker but response is 4xx, check response body. Common errors:
  - `invalid_grant` — the auth code was already used, or `code_verifier` doesn't match. Start over with a fresh sign-in.
  - `invalid_client` — the client_id is wrong. Unlikely; means Anthropic changed the add-in's registration.
  - 5xx — our Worker failed to forward. Check Cloudflare Worker logs via dashboard.

### Randomly logged out / "sign in again" after a while

The refresh token chain died. Causes:
- Anthropic revoked it (security policy, signed out elsewhere, manual revocation).
- Bundle rewrite broke silently, so refresh attempts failed and the add-in concluded you're logged out.
- WebView2 wiped localStorage (rare — only on manual clear).

Recovery: redo the phone sign-in flow. Should take ~2 minutes.

### "Claude for Word is available on Team and Enterprise plans"

Not a rewrite failure — it means the proxy is working correctly. Your plan-verification call succeeded and Anthropic responded that your subscription tier doesn't include Word. Max/Pro cover Excel and PowerPoint; Word needs Team/Enterprise. Upgrade or skip Word.

Symptom distinguisher: if you see "We couldn't verify your plan" *instead*, that IS a proxy issue (likely a new Anthropic hardcoded URL we need to rewrite). If you see "available on Team and Enterprise plans", auth + plan-check all worked — there's nothing to fix on our end.

### "Add-in Claude failed to download a required resource" during install

We shouldn't hit this anymore — we sideload rather than install from AppSource. If you're seeing it, you're trying to install from Microsoft AppSource instead of adding the sideload from Developer Add-ins. Go to Insert → **My Add-ins** → Developer Add-ins tab → "Claude (proxied)".

### Anthropic deployed a new bundle — how to tell if rewrites still work

Run this diagnostic script:

```bash
bash ~/claude-oauth-worker/scripts/diagnose-pivot-rewrite.sh
```

(Created below.) It fetches the current bundle and checks whether each critical rewrite is still matching. Output tells you which patterns broke.

### Anthropic bundle minification renamed functions

Common pattern: they redeploy, and `E0()`, `G9()`, `U8e`, etc. get renamed to other random-looking identifiers. Our rewrites use generic regex patterns (matching any function that returns `"https://pivot.claude.ai/auth/callback"`, etc.) — so small changes usually survive. But structural changes (e.g., moving from template literal to string concatenation, or moving OAuth config to a different shape) will break.

Fix procedure:
1. Fetch current bundle
2. Grep for the old semantic (e.g., `auth/callback`, `tokenEndpoint`)
3. Look at the surrounding code: what's the new minified form?
4. Update the regex in `pivot-proxy.js`
5. `wrangler deploy --env pivot`
6. Force Excel reload (quit Excel, clear Wef cache, reopen)

---

## Re-registering the sideload

If you need to nuke and re-register the proxied add-in:

```powershell
# Unregister:
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\Wef\Developer" -Name "ClaudeProxiedExcel"

# Rebuild the manifest with a fresh version/URL:
node ~/claude-oauth-worker/scripts/build-modified-manifest.mjs

# Re-register:
New-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\Wef\Developer" `
  -Name "ClaudeProxiedExcel" `
  -Value "$env:USERPROFILE\ClaudeAddin\manifest-official-claude-excel.xml" `
  -PropertyType String -Force
```

Then close Excel completely, optionally wipe WebView2 cache, reopen.

```powershell
# Aggressive cache wipe:
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef\webview2" -ErrorAction SilentlyContinue
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef" -Directory |
  Where-Object { $_.Name -like "{*}" } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
```

---

## Known fragility

- **Pattern-based minified-code rewrites.** When Anthropic deploys a new bundle, function names change and structural forms sometimes shift. A given set of regex patterns has a useful life measured in weeks, not years.
- **OAuth PKCE flow with split-device completion.** Works because the add-in's React app handles the callback route using its own sessionStorage. If Anthropic moves to a flow that demands end-to-end browser context (e.g., full cookie-based auth), the split-device trick breaks.
- **Cloudflare Worker is the single point of failure.** Account suspension, quota exhaustion, or Anthropic IP-banning Cloudflare would kill this.
- **Anthropic's ToS.** Routing the official add-in through a user-controlled proxy may be frowned upon even though tokens are yours and usage counts against your Max sub. Ask permission before sharing this pattern publicly.
- **Not supported by Anthropic.** You can't file bug reports for this setup. When it breaks, you fix it.

If any of these bite too hard, you can build your own sideloaded add-in using the `/addin/` stub route in `src/index.js` as a starting point — slower to evolve but entirely under your control (not subject to Anthropic bundle changes).

---

## File index

| Path | What |
|---|---|
| `src/pivot-proxy.js` | The Worker itself |
| `wrangler.toml` → `[env.pivot]` | Deploy config, Worker name `<your-pivot-name>` |
| `scripts/build-modified-manifest.mjs` | Rebuilds manifest with bumped version + cache-buster SourceLocation |
| `scripts/diagnose-pivot-rewrite.sh` | Fetches current bundle, checks rewrite patterns |
| `~/ClaudeAddin/manifest-official-claude-excel.xml` | The sideloaded manifest |
| `~/claude-oauth-worker-backup/manifest-official-pristine.xml` | Stashed pristine copy of the Microsoft-signed original (source of truth for regenerating the modified manifest) |

Registry entry: `HKCU:\Software\Microsoft\Office\16.0\Wef\Developer\ClaudeProxiedExcel`
