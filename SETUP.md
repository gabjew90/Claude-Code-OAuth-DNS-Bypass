# Setup guide

Two independent capabilities, pick either or both:

- **A. VSCode Claude Code auth fix** — stop having to re-paste credentials from a personal laptop. Expect ~15 min.
- **B. Office add-ins (Excel / PowerPoint / Word)** — install and authenticate Anthropic's real Claude add-ins on the blocked network. Expect another ~15 min after A.

## Prerequisites (both)

- **Claude Max subscription** on your Anthropic account (Pro might work, untested).
- **Cloudflare account** (free tier is fine — 100K Worker requests/day).
- **Node.js** (for `wrangler`). Windows per-user install works, no admin needed.
- **A second device or network** where `claude.ai` / `pivot.claude.ai` are reachable — phone on cellular, personal laptop on home wifi, etc.

---

## A. VSCode Claude Code auth fix

### Step 1 — Clone + install Wrangler

```powershell
git clone https://github.com/<you>/claude-oauth-worker.git ~\claude-oauth-worker
cd ~\claude-oauth-worker
npm install -g wrangler
wrangler login
```

### Step 2 — Configure `wrangler.toml`

Open `wrangler.toml`. Three `name =` lines near the top — pick something unique under your Cloudflare account (e.g. `myname-claude-worker`) and apply consistently:
- default: `<name>` → e.g. `myname-claude-worker`
- `[env.test]` → `<name>-test` → `myname-claude-worker-test`
- `[env.pivot]` → `<name>-pivot` → `myname-claude-worker-pivot`

### Step 3 — Create the KV namespace

```powershell
wrangler kv namespace create CLAUDE_TOKEN_CACHE
```

Copy the `id` from the output. Paste it into **both** `[[kv_namespaces]]` blocks in `wrangler.toml` where it says `REPLACE_ME_WITH_KV_NAMESPACE_ID`.

### Step 4 — First deploy (behavior-neutral)

```powershell
wrangler deploy
```

Confirm it's reachable: `curl https://<your-main>.workers.dev/v1/messages` should return an Anthropic auth error (expected — you didn't send a token). That's enough to prove the proxy works.

### Step 5 — Get a fresh refresh token

On a network where `claude.ai` resolves (personal laptop, phone hotspot):

1. Sign out of Claude Code.
2. Sign back in. This issues a fresh pair.
3. Open `~/.claude/.credentials.json` (Windows: `%USERPROFILE%\.claude\.credentials.json`).
4. Copy the `refreshToken` value (~108-character string starting with `sk-ant-oat01-`).

### Step 6 — Seed the Worker

Back on the blocked-network laptop:

```powershell
wrangler secret put CLAUDE_REFRESH_TOKEN
```

Paste the refresh token when prompted.

### Step 7 — Activate auth injection

Edit `wrangler.toml`:

```toml
[vars]
ENABLE_AUTH_INJECTION = "true"
```

Redeploy: `wrangler deploy`.

Smoke test:

```powershell
curl.exe -X POST https://<your-main>.workers.dev/v1/messages `
  -H "content-type: application/json" `
  -H "anthropic-beta: oauth-2025-04-20" `
  -H "anthropic-version: 2023-06-01" `
  -H "authorization: Bearer any_value_worker_replaces_it" `
  -d '{\"model\":\"claude-haiku-4-5\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"reply: OK\"}]}'
```

Should return a real Claude response. If yes, the Worker is minting tokens correctly.

### Step 8 — Point Claude Code at the Worker

Edit `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<your-main>.workers.dev",
    "NODE_TLS_REJECT_UNAUTHORIZED": "0",
    "DISABLE_TELEMETRY": "1"
  }
}
```

### Step 9 — Apply Shape B

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\shape-b-apply.ps1
```

This sets `claudeAiOauth.expiresAt` to year 2286 so Claude Code stops attempting local refresh (which would hit the DNS block). Makes a backup first.

### Step 10 — Reload VSCode

`Ctrl+Shift+P` → "Developer: Reload Window". Ask Claude anything. If it responds, you're done.

---

## B. Office add-ins (Excel / PowerPoint / Word)

Only needed if you want to use Anthropic's official Claude add-ins in Office on the blocked network.

### Step B1 — Update wrangler.toml for the pivot Worker

In `wrangler.toml` under `[env.pivot.vars]`, set `MAIN_WORKER_URL` to the URL of your main Worker from Part A:

```toml
[env.pivot.vars]
MAIN_WORKER_URL = "https://<your-main>.workers.dev"
```

### Step B2 — Deploy the pivot Worker

```powershell
wrangler deploy --env pivot
```

Your pivot Worker URL is now `https://<your-name>-pivot.<your-subdomain>.workers.dev`.

### Step B3 — Install the Office sideloads

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-office-addins.ps1 `
  -PivotWorkerUrl "https://<your-name>-pivot.<your-subdomain>.workers.dev"
```

This:
- Generates Excel / PowerPoint / Word manifests with your pivot Worker URL baked in
- Writes them to `~\ClaudeAddin\`
- Registers them in `HKCU\Software\Microsoft\Office\16.0\Wef\Developer` (no admin needed)

### Step B4 — Load the add-ins in Office

Fully quit Excel / PowerPoint / Word (Task Manager if needed). Optionally clear WebView2 cache:

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef\webview2" -ErrorAction SilentlyContinue
```

Reopen the Office app → **Insert → Get Add-ins → My Add-ins → Developer Add-ins tab** → `Claude (proxied, <App>)` → **Add**.

### Step B5 — Sign in (one-time per device)

First time the task pane opens, click **Sign in**. It'll give you a URL. Copy it → paste in your phone's browser (where `claude.ai` resolves normally). Authorize. The add-in completes the flow via the pivot Worker and stores your tokens locally.

Done. Tokens persist across Office restarts.

---

## Failure handling

### Worker returns `{"error":{"type":"oauth_refresh_error",...}}`

Means the main Worker's stored refresh token died. Recovery:

1. On personal laptop: sign out of Claude Code, sign back in.
2. Copy the new `refreshToken` from `~/.claude/.credentials.json`.
3. Run `powershell -ExecutionPolicy Bypass -File .\scripts\re-seed-worker-tokens.ps1` — paste the new token when prompted.
4. Reload VSCode.

### Office add-in stops working after an Anthropic bundle update

Anthropic ships new bundles frequently (the minified variable names change). Run:

```bash
bash scripts/diagnose-pivot-rewrite.sh https://<your-pivot>.workers.dev
```

First `[FAIL]` tells you which rewrite needs updating in `src/pivot-proxy.js`. See [PIVOT-PROXY.md](./PIVOT-PROXY.md) for detailed troubleshooting.

### Something is on fire, get me back to yesterday

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\panic-rollback.ps1
```

Reverts `ANTHROPIC_BASE_URL` to unset, restores credentials from the pre-Shape-B backup, puts you back in the pre-fix state (manual paste ritual works). Run any of the setup steps above to rebuild.

---

## Optional: test environment

`wrangler.toml` defines `[env.test]` which deploys to `<name>-test.workers.dev` with `ENABLE_AUTH_INJECTION=true` by default. Useful for testing changes without touching the main Worker. Deploy with `wrangler deploy --env test`. Point VSCode at the test URL while validating, then switch back to main.
