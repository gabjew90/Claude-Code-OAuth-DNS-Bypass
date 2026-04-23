# Setup guide

End-to-end walkthrough: from cloning this repo to Claude Code working on a DNS-blocked network. Expect ~10–15 minutes.

## Prerequisites

- **Claude Max subscription** on an Anthropic account you control. (Pro might work — untested. API-only accounts won't; this uses OAuth, not API keys.)
- **Cloudflare account** (free tier is plenty — Workers free tier is 100,000 requests/day).
- **Node.js** (for `wrangler`, `npm`). Windows user-profile install is fine; no admin needed.
- **Access to a second device or network** where `claude.ai` and `platform.claude.com` are reachable, so you can do an OAuth login and extract a fresh refresh token. (Typically your personal laptop on home WiFi.)
- **VSCode** (or any Claude Code client) on the blocked-network laptop.

## Step 1 — Clone + install Wrangler

```powershell
git clone https://github.com/<you>/claude-oauth-worker.git ~\claude-oauth-worker
cd ~\claude-oauth-worker
npm install -g wrangler
wrangler login
```

`wrangler login` opens a browser for Cloudflare OAuth. Sign in to your Cloudflare account. One time.

## Step 2 — Configure `wrangler.toml`

Open `wrangler.toml` and change one field:

```toml
name = "claude-oauth-worker"   ← change this to anything unique under YOUR Cloudflare account
```

This becomes your Worker's URL: `https://<name>.<your-subdomain>.workers.dev`. You'll need that URL a couple steps from now.

## Step 3 — Create the KV namespace

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

Copy that `id` and paste it into **both** places in `wrangler.toml` (main env and `env.test`) where it says `REPLACE_ME_WITH_KV_NAMESPACE_ID`.

## Step 4 — First deploy (behavior-neutral)

```powershell
wrangler deploy
```

This uploads the Worker with `ENABLE_AUTH_INJECTION = "false"` — which means pure pass-through, no auth injection yet. Confirm it's alive:

```powershell
curl https://<your-worker-name>.<subdomain>.workers.dev/v1/messages
```

You'll get an auth error from Anthropic (expected — no token attached), but the fact that you got an Anthropic response at all means the proxy is working.

## Step 5 — Get a fresh refresh token

Do this on a **network where `claude.ai` is reachable**, e.g. your personal laptop.

1. Sign out of Claude Code (or any Claude client).
2. Sign back in. This issues you a fresh OAuth pair.
3. Open `~/.claude/.credentials.json` (Windows: `%USERPROFILE%\.claude\.credentials.json`).
4. Copy the value of the `refreshToken` field. It's a ~108-character string starting with `sk-ant-oat01-`.

## Step 6 — Seed the Worker with the refresh token

Back on the blocked-network laptop:

```powershell
wrangler secret put CLAUDE_REFRESH_TOKEN
```

Paste the refresh token when prompted. Press Enter. (Optional: repeat with `--env test` if you want to test there first.)

## Step 7 — Flip the auth-injection flag on

Edit `wrangler.toml`:

```toml
[vars]
ENABLE_AUTH_INJECTION = "true"
```

Then `wrangler deploy` again. The Worker will now mint fresh access tokens on every incoming request.

Verify:

```powershell
curl -X POST https://<your-worker>.workers.dev/v1/messages `
  -H "content-type: application/json" `
  -H "anthropic-beta: oauth-2025-04-20" `
  -H "anthropic-version: 2023-06-01" `
  -H "authorization: Bearer any_bogus_value_will_do" `
  -d '{\"model\":\"claude-haiku-4-5\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"reply: SETUP_OK\"}]}'
```

You should get a real Claude response. The fact that a bogus `authorization` header worked is the proof — the Worker stripped it and injected a real one.

## Step 8 — Point Claude Code at the Worker

Edit `~/.claude/settings.json` (Windows: `%USERPROFILE%\.claude\settings.json`). Under the `env` block, add (or set):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<your-worker>.workers.dev",
    "NODE_TLS_REJECT_UNAUTHORIZED": "0",
    "DISABLE_TELEMETRY": "1"
  }
}
```

Why `DISABLE_TELEMETRY=1`: Claude Code's telemetry subsystem POSTs event batches to an Anthropic endpoint that doesn't accept the OAuth scopes our Worker uses. Without this flag you'll see `403 Forbidden` errors in the VSCode output panel — harmless (doesn't affect chat) but noisy. Setting the flag stops the telemetry attempts and silences the errors. (Alternative broader flag: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, which also quiets update checks and feature-flag polling.)

Save.

## Step 9 — Apply Shape B

Still on the blocked-network laptop. This lies to Claude Code about token expiry so it stops attempting local refresh (which would hit the DNS block).

Easiest: run the included script.

```powershell
powershell -ExecutionPolicy Bypass -File ~\claude-oauth-worker\scripts\shape-b-apply.ps1
```

Or manually: open `~/.claude/.credentials.json`, change the `expiresAt` field value from its current number to `9999999999000` (year 2286). Save.

## Step 10 — Reload VSCode

`Ctrl+Shift+P` → "Developer: Reload Window".

Ask Claude anything. If it responds, you're done. You should not need to touch `.credentials.json` again for weeks or months.

---

## Failure handling

### Worker returns `{"error":{"type":"oauth_refresh_error",...}}`

Means the Worker's stored refresh token is dead (revoked, rotated stuck, or hit an edge case). Fix:

1. On personal laptop: sign out of Claude Code + sign back in → fresh `refreshToken`.
2. On blocked laptop: run `scripts/re-seed-worker-tokens.ps1`, paste the fresh token. Script handles the rest (seeds both envs, flushes KV).
3. Reload VSCode.

### VSCode Claude shows "logged out"

Means Shape B was reverted somehow, or Claude Code's extension update is doing new auth validation. Fix:

1. Check `~/.claude/.credentials.json` — `claudeAiOauth.expiresAt` should be `9999999999000`. If not, re-run `scripts/shape-b-apply.ps1`.
2. If still logged out after Shape B is confirmed, run `scripts/panic-rollback.ps1` to revert everything, then paste fresh credentials from personal laptop (the pre-Worker workflow).

### Everything is broken, total panic

Run `scripts/panic-rollback.ps1`. This:
1. Restores `~/.claude/settings.json` to its pre-Worker state (removes `ANTHROPIC_BASE_URL`).
2. Restores `~/.claude/.credentials.json` to its pre-Shape-B state if a backup exists.
3. You're back to pre-Worker life — manually paste `.credentials.json` from personal laptop whenever it expires. Investigate the Worker issue at your leisure.

---

## Optional: test environment

`wrangler.toml` defines a second env `env.test` that deploys to `<name>-test.workers.dev` with `ENABLE_AUTH_INJECTION = "true"` by default. Useful for validating changes without touching the main Worker. Deploy with `wrangler deploy --env test`. Point your VSCode at `<name>-test.workers.dev` while testing.

## Optional: removing the `/addin/` route

If you're not planning to build a sideloaded Office add-in with this Worker, you can delete the `if (url.pathname.startsWith("/addin/"))` block from `src/index.js` and the `ADDIN_STUB_HTML` constant. Not required, just cleanup.
