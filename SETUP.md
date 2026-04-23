# Setup guide

You'll configure 1–3 Cloudflare Workers depending on which capabilities you want. **Pick your path:**

- **Part A only** (VSCode auth fix): deploy 1 Worker. ~10 minutes.
- **Part B only** (Office add-ins): deploy 2 Workers. ~15 minutes.
- **Both**: deploy 3 Workers. Do Part A first (it's a superset of the Worker setup Part B needs), then Part B. ~20 minutes total.

If you're unsure, scroll to [Part A](#part-a--vscode-claude-code-auth-fix) and [Part B](#part-b--office-add-ins-excel--powerpoint--word) and pick based on whether they describe what you want.

---

## Prerequisites (all paths)

### Accounts you need

- **Paid Claude subscription** — Pro, Max, Team, or Enterprise. API-only accounts won't work; this uses OAuth.
- **Cloudflare account** — free tier is fine. Workers free tier is 100K requests/day.

### Tools on the blocked-network machine

- **Node.js** with `npm` — any recent version. Per-user install works, no admin needed.
- **Git** — to clone this repo. Standard Windows Git installation.
- **PowerShell** — ships with Windows.

### A second device where `claude.ai` resolves normally

This is where you'll sign in once to get a refresh token. Examples:
- Your phone on cellular data
- Your personal laptop on home wifi
- Any machine not subject to the corporate DNS filter

You only need this **once per token lifetime** (weeks to months), not per session.

### Verify your network IS actually blocking Anthropic

Before setting anything up, confirm the symptom:

```powershell
nslookup api.anthropic.com
nslookup claude.ai
```

If both return the real Anthropic IPs (`160.79.104.10` or similar), your network isn't blocking — you don't need this setup. Just use Claude normally.

If both return the same IP (typically `146.112.61.106` — a Cisco Umbrella block page), you're in the target audience.

---

## Step 0 — Clone + install Wrangler (do this once, regardless of path)

On the blocked-network machine:

```powershell
git clone https://github.com/<your-github>/claude-oauth-worker.git "$env:USERPROFILE\claude-oauth-worker"
cd "$env:USERPROFILE\claude-oauth-worker"
npm install -g wrangler
wrangler login
```

`wrangler login` opens a browser to Cloudflare. Sign in. Once.

---

## Part A — VSCode Claude Code auth fix

What this does: makes VSCode Claude Code stay logged in across restarts, even though your network blocks the OAuth refresh endpoint. Once applied, you'll never need to paste a fresh `.credentials.json` from your personal laptop again.

### A.1. Create a KV namespace

From `~/claude-oauth-worker/`:

```powershell
wrangler kv namespace create CLAUDE_TOKEN_CACHE
```

Output looks like:

```
✨ Success!
[[kv_namespaces]]
binding = "CLAUDE_TOKEN_CACHE"
id = "abcdef0123456789abcdef0123456789"
```

**Copy that `id` value.** You'll paste it into `wrangler.toml` next.

### A.2. Edit `wrangler.toml`

Open `wrangler.toml`. You need to change **name fields** (to pick Worker URLs unique to your Cloudflare account) and paste the KV id.

Pick a prefix unique to you (e.g. `yourname-claude`). Then edit the file:

```toml
name = "yourname-claude"              # Main Worker
main = "src/index.js"

[vars]
ENABLE_AUTH_INJECTION = "false"        # DO NOT CHANGE if you'll also do Part B

[[kv_namespaces]]
binding = "CLAUDE_TOKEN_CACHE"
id = "abcdef0123456789abcdef0123456789"   # ← paste your KV id here

[env.test]
name = "yourname-claude-test"          # Test Worker (this one VSCode uses)

[env.test.vars]
ENABLE_AUTH_INJECTION = "true"         # VSCode auth injection lives here

[[env.test.kv_namespaces]]
binding = "CLAUDE_TOKEN_CACHE"
id = "abcdef0123456789abcdef0123456789"   # ← same KV id (shared across envs)

[env.pivot]
name = "yourname-claude-pivot"         # Pivot Worker (only for Office add-ins)
main = "src/pivot-proxy.js"

[env.pivot.vars]
MAIN_WORKER_URL = "https://yourname-claude.<your-cloudflare-subdomain>.workers.dev"
# ↑ You'll know <your-cloudflare-subdomain> after your first deploy below.
```

> **Important:** if you're also doing Part B, leave the main env's `ENABLE_AUTH_INJECTION = "false"`. Only set `"true"` under `[env.test.vars]`. The main Worker must stay pass-through for the Office add-ins to work. See the "Role separation" table in the README.

### A.3. Deploy the main + test Workers

```powershell
wrangler deploy                   # main (pass-through)
wrangler deploy --env test        # test (auth injection ON) — this is VSCode's entry point
```

Wrangler prints the URLs:

```
Deployed yourname-claude triggers
  https://yourname-claude.<your-cloudflare-subdomain>.workers.dev
Deployed yourname-claude-test triggers
  https://yourname-claude-test.<your-cloudflare-subdomain>.workers.dev
```

**Copy both URLs.** Note the subdomain — it's the same for all your Workers. Replace `<your-cloudflare-subdomain>` in `wrangler.toml` under `MAIN_WORKER_URL` now (you'll need this for Part B, or ignore if skipping Part B).

### A.4. Get a fresh refresh token (on your second device)

On your personal laptop or phone (where `claude.ai` resolves):

1. Make sure Claude Code is signed in. (VSCode → Claude extension → if not signed in, sign in now.) This creates a fresh `~/.claude/.credentials.json`.
2. Open `~/.claude/.credentials.json` (Windows: `%USERPROFILE%\.claude\.credentials.json`; Mac: `~/.claude/.credentials.json`).
3. Find the `"refreshToken":` field. It's a 108-character string starting with `sk-ant-oat01-`.
4. **Copy the value** (just the string, not the surrounding quotes).

### A.5. Seed the refresh token on the Worker

Back on the blocked machine, from `~/claude-oauth-worker/`:

```powershell
wrangler secret put CLAUDE_REFRESH_TOKEN --env test
```

Paste the refresh token when prompted. Press Enter. The secret is stored encrypted on Cloudflare; never visible in responses.

Smoke test that the Worker can refresh:

```powershell
$uri = "https://yourname-claude-test.<your-subdomain>.workers.dev/v1/messages"
curl.exe -X POST $uri `
  -H "content-type: application/json" `
  -H "anthropic-beta: oauth-2025-04-20" `
  -H "anthropic-version: 2023-06-01" `
  -H "authorization: Bearer anything_the_worker_will_replace_this" `
  -d '{\"model\":\"claude-haiku-4-5\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"reply: OK\"}]}'
```

If you see a real Claude response (JSON with `"content":[{"type":"text","text":"OK"}]` or similar), the auth injection is working.

If you see `oauth_refresh_error`, the refresh token is bad — redo A.4 with a freshly signed-in state.

### A.6. Configure Claude Code to use the Worker

Edit `~/.claude/settings.json` (create it if it doesn't exist). Add/update the `env` block:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://yourname-claude-test.<your-subdomain>.workers.dev",
    "NODE_TLS_REJECT_UNAUTHORIZED": "0",
    "DISABLE_TELEMETRY": "1"
  }
}
```

Explanation:
- `ANTHROPIC_BASE_URL` — tells Claude Code to send all API calls to your test Worker instead of directly to `api.anthropic.com`. This is the main hook.
- `NODE_TLS_REJECT_UNAUTHORIZED: "0"` — works around some corporate TLS-inspection middleware that messes with certificate chains. Safe to leave on; only bypasses TLS cert validation for Claude Code's outbound fetches, not globally.
- `DISABLE_TELEMETRY: "1"` — silences Claude Code's telemetry subsystem, which otherwise emits 403 errors because its telemetry endpoint rejects our OAuth-scoped tokens. Harmless either way; this just quiets the log.

### A.7. Apply Shape B

Shape B edits one field in your local `.credentials.json` so Claude Code never *attempts* its own OAuth refresh. Without this, it'll try anyway at the real `expiresAt` time, hit the DNS block, and flag itself "logged out" despite the Worker working fine.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\shape-b-apply.ps1
```

This:
- Backs up your current `.credentials.json` to `~/.claude/backups/credentials.json.bak-pre-shape-b-<timestamp>`
- Sets `claudeAiOauth.expiresAt` to `9999999999000` (year 2286)

Idempotent — safe to run again.

### A.8. Reload VSCode

`Ctrl+Shift+P` → "Developer: Reload Window".

Ask Claude anything. If it responds, you're done. You should never see the "logged out" state again (unless the refresh token dies, which happens weeks/months apart — then run the re-seed script; see "Recovery" below).

**Part A is complete.** Continue to Part B if you also want Office add-ins, or you're done.

---

## Part B — Office add-ins (Excel / PowerPoint / Word)

What this does: sideloads Anthropic's real Claude for Office add-ins on your blocked machine and makes their OAuth work end-to-end via a phone-based sign-in flow.

> **Plan-tier note:** Excel and PowerPoint work on Claude Pro, Max, Team, and Enterprise. **Word is gated by Anthropic to Team and Enterprise only** — on Pro/Max the Word add-in installs fine but shows "Claude for Word is available on Team and Enterprise plans" after sign-in. The install script registers all three; just ignore the Word one if you're on Pro/Max.

### B.0. Prerequisite

You need to have done [Step 0](#step-0--clone--install-wrangler-do-this-once-regardless-of-path) already. If you're doing Part B without Part A, you still need a deployed main Worker (for the api.anthropic.com pass-through) — do `wrangler deploy` once to deploy `src/index.js` to the main env. You can skip the KV namespace and refresh token steps (A.1, A.4, A.5) if you don't want the VSCode fix.

### B.1. Update `wrangler.toml` pivot config

Open `wrangler.toml`. Under `[env.pivot.vars]`, set `MAIN_WORKER_URL` to the full URL of your main Worker (from Part A.3, or whatever you deployed):

```toml
[env.pivot]
name = "yourname-claude-pivot"
main = "src/pivot-proxy.js"

[env.pivot.vars]
MAIN_WORKER_URL = "https://yourname-claude.<your-subdomain>.workers.dev"
```

### B.2. Deploy the pivot Worker

```powershell
wrangler deploy --env pivot
```

Output:

```
Deployed yourname-claude-pivot triggers
  https://yourname-claude-pivot.<your-subdomain>.workers.dev
```

Copy that URL.

### B.3. Verify the pivot Worker is rewriting the add-in bundle correctly

```bash
bash scripts/diagnose-pivot-rewrite.sh https://yourname-claude-pivot.<your-subdomain>.workers.dev
```

(Requires a Bash shell — use Git Bash on Windows.)

All six checks should print `[OK]`. If any say `[FAIL]`, Anthropic has changed their bundle shape since this repo was last updated. See [PIVOT-PROXY.md troubleshooting](./PIVOT-PROXY.md#troubleshooting) for how to fix the regex.

### B.4. Install the Office sideloads

From `~/claude-oauth-worker/`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-office-addins.ps1 `
  -PivotWorkerUrl "https://yourname-claude-pivot.<your-subdomain>.workers.dev"
```

What it does:
- Reads templates from `manifests/`
- Substitutes your Worker URL and a fresh version stamp
- Writes the rendered XMLs to `~\ClaudeAddin\`
- Registers them in `HKCU\Software\Microsoft\Office\16.0\Wef\Developer` so Office picks them up (no admin needed)

### B.5. Load the add-ins in Office

**Fully quit** Excel / PowerPoint / Word. Check Task Manager to kill any `EXCEL.EXE`, `POWERPNT.EXE`, `WINWORD.EXE` that didn't close.

Optional but strongly recommended — clear WebView2's add-in cache so no stale HTML survives:

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef\webview2" -ErrorAction SilentlyContinue
```

Reopen whichever Office app you want to test first (Excel is a good starting point).

- **Insert → Get Add-ins** (or **Insert → My Add-ins → See All**)
- Click the tab labeled **Developer Add-ins** (or **Shared Folder** on some Office versions) at the top of the dialog
- You'll see **Claude (proxied, Excel)** in the list. Click it → **Add**

The task pane should render Anthropic's real Claude UI. It'll show a **Sign in** button.

### B.6. Sign in (one-time per device)

1. Click **Sign in** in the task pane. You'll see a URL.
2. Copy the URL to your phone (email it, message it, whatever).
3. Open the URL on your phone's browser. Sign in to your Claude account. Click **Authorize**.
4. After authorizing, your phone lands on `https://pivot.claude.ai/auth/callback?code=...`. The page may be blank or show an error — that's fine.

**In most versions of the add-in**, the task pane in Office detects the completion automatically (it polls a status endpoint) and flips to the chat UI. Done.

**If the task pane stays on the sign-in screen** even after your phone has authorized, do this manual completion:

1. Copy the full URL from your phone's address bar (including `?code=...&state=...`).
2. In Office, right-click the task pane → **Inspect** → **Console** tab.
3. Paste:

   ```js
   const cbUrl = new URL(prompt("Paste callback URL from phone:"));
   const code = cbUrl.searchParams.get("code");
   const state = cbUrl.searchParams.get("state");
   window.location.href = `/auth/callback?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`;
   ```

4. Paste the phone URL at the prompt. Enter.

The task pane navigates to its own callback handler, which completes the token exchange via your proxy. You're signed in.

Tokens persist in the add-in's localStorage (scoped to your pivot Worker's origin). Survives Office restarts, machine reboots. Silent refresh happens whenever the access token nears expiry.

### B.7. Repeat in PowerPoint

Quit and reopen PowerPoint. Same steps (**Insert → Get Add-ins → My Add-ins → Developer Add-ins → Claude (proxied, PowerPoint) → Add**). Sign in may carry over from Excel (same origin localStorage) or require a fresh phone flow.

### B.8. Optional — Word

On Team/Enterprise plans, same steps in Word.

On Pro/Max, you can still add the Word sideload — it'll install and let you sign in, but the task pane will then show "Claude for Word is available on Team and Enterprise plans." Ignore it until your plan covers Word, or uninstall it:

```powershell
# Unregister just Word:
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Office\16.0\Wef\Developer" `
  -Name ClaudeProxiedWord
```

**Part B is complete.**

---

## Recovery — when things break

### Main Worker returns `oauth_refresh_error`

Your stored refresh token died. Recovery:

1. On your personal device: sign out of Claude Code, sign back in. This issues a brand-new refresh token pair.
2. Open the fresh `~/.claude/.credentials.json` on personal. Copy the new `refreshToken` value.
3. On the blocked machine, from `~/claude-oauth-worker/`:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\re-seed-worker-tokens.ps1
   ```
4. Paste the new token when prompted. The script re-seeds the secret on both main and test Workers, then flushes the KV cache so the next request refreshes fresh.
5. Reload VSCode. You should be signed in again.

Expect to do this every few weeks to months, depending on Anthropic's token rotation behavior.

### Office add-in breaks after an Anthropic update

Most likely: one of the bundle rewrite regexes no longer matches. Run:

```bash
bash scripts/diagnose-pivot-rewrite.sh https://yourname-claude-pivot.<your-subdomain>.workers.dev
```

Find the first `[FAIL]` line. See [PIVOT-PROXY.md → troubleshooting](./PIVOT-PROXY.md#troubleshooting) for how to inspect the current bundle and update the regex.

After fixing `src/pivot-proxy.js`, redeploy and force a clean reload:

```powershell
wrangler deploy --env pivot

# Quit Office apps completely, then:
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef\webview2" -ErrorAction SilentlyContinue

# Re-run install to bump manifest version (forces Office to treat it as a fresh add-in):
.\scripts\install-office-addins.ps1 -PivotWorkerUrl "https://yourname-claude-pivot.<your-subdomain>.workers.dev"
```

Reopen the Office app, re-add the sideload.

### "Unable to connect" inside the add-in

The add-in's API calls aren't reaching Anthropic. Check the diagnostic's section 6 (api.anthropic.com rewrite). Common causes:
- Your `MAIN_WORKER_URL` in `wrangler.toml` under `[env.pivot.vars]` is wrong or unset. Fix and redeploy pivot.
- Your main Worker isn't deployed or accessible. Test: `curl -I https://yourname-claude.<subdomain>.workers.dev/v1/messages` should return HTTP 401 (Anthropic rejecting empty auth — means the proxy reached them). Anything else, redeploy.

### VSCode says "logged out" but Worker is healthy

Something unwound Shape B. Check:

```powershell
# Should print a number with many digits (not a sensible timestamp):
node -e "console.log(JSON.parse(require('fs').readFileSync(require('os').homedir() + '/.claude/.credentials.json')).claudeAiOauth.expiresAt)"
```

If it prints a normal-looking timestamp (like `1776905993711`), re-run `scripts\shape-b-apply.ps1`. Reload VSCode.

### Nuclear option: everything's broken

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\panic-rollback.ps1
```

This removes `ANTHROPIC_BASE_URL` from `settings.json` and restores `.credentials.json` from the pre-Shape-B backup. You're back to the pre-setup state. Claude Code will be logged out (because its local refresh still can't reach the blocked endpoint); use the manual paste-from-personal workflow while you investigate what broke.

---

## Uninstall

### Remove Office sideloads

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-office-addins.ps1
```

Unregisters from HKCU. Manifest XMLs stay in `~\ClaudeAddin\` (delete manually if you want).

### Undo VSCode auth fix

Run `panic-rollback.ps1`. Or manually: edit `~/.claude/settings.json` to remove the `ANTHROPIC_BASE_URL` env var, and restore `.credentials.json` from a pre-Shape-B backup under `~/.claude/backups/`.

### Delete the Workers

Cloudflare dashboard → Workers → delete each one. Delete the KV namespace too. Nothing left on Anthropic's side — you never touched anything of theirs, just your own account's tokens.
