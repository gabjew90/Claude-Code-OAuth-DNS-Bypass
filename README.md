# claude-oauth-worker

A Cloudflare Worker that handles Claude Max OAuth refresh server-side, so **VSCode Claude Code (and similar clients) can stay logged in indefinitely in environments that DNS-block `api.anthropic.com` / `platform.claude.com` / `claude.ai`.**

Typical use case: your corporate / school / restrictive network filters Anthropic domains, but you have a legitimate Claude Max subscription and want to use Claude Code for work. This Worker becomes a reverse-proxy between your client and Anthropic — plus a silent token-refresh agent — on Cloudflare's network, which those filters don't block.

---

## What it does

1. **Proxies `/v1/messages`** (and anything that falls through to the default route) to `api.anthropic.com`.
2. **On each request**, checks whether a cached access token in Cloudflare KV is still valid.
3. **If expired**, calls `platform.claude.com/v1/oauth/token` with your stored refresh token, mints a fresh access token, persists it in KV (handles refresh-token rotation too).
4. **Overwrites the request's `Authorization` header** with the fresh access token before forwarding to Anthropic.
5. Serves a stub at `/addin/*` intended for a sideloaded Office add-in (optional; delete if you don't need it).

Combined with **Shape B** (a one-field edit in your local `~/.claude/.credentials.json`), your Claude Code client stops attempting its own refresh — the Worker is the only thing touching OAuth. Net result: **no more daily logouts on networks that block Anthropic.**

---

## Why this works (short version)

Claude Code's OAuth access tokens expire every ~24 hours. When they do, Claude Code tries to refresh via `platform.claude.com/v1/oauth/token`. If that domain is DNS-blocked, refresh fails and you're logged out until you bring fresh credentials in from an unblocked environment (usually a manual file paste).

This Worker moves the refresh call off your laptop and onto Cloudflare, which isn't blocked. Claude Code is told (via a fake `expiresAt` field in its local state) that its access token is valid forever, so it stops trying to refresh. Every request Claude Code sends passes through the Worker, which strips the stale access token, mints a real fresh one, and forwards it.

**Nothing about this bypasses Anthropic's subscription billing, scopes, or security** — it uses Anthropic's own public OAuth refresh flow, exactly the same flow Claude Code itself would use if the network weren't broken. See [DISCLAIMER.md](./DISCLAIMER.md).

---

## Architecture

```
Your laptop                               Cloudflare (not blocked)
┌─────────────────────────┐    ┌──────────────────────────────────────┐
│ VSCode Claude Code      │    │  <your-worker>.workers.dev           │
│   ANTHROPIC_BASE_URL  ──┼───▶│                                      │
│     points at the Worker│    │  on each request:                    │
│                         │    │   - check KV for valid access token  │
│   ~/.claude/            │    │   - if expired: refresh via          │
│    .credentials.json    │    │     platform.claude.com with stored  │
│    expiresAt=year 2286  │    │     refresh token                    │
│     (Shape B)           │    │   - replace Authorization: Bearer    │
│                         │    │     with the fresh token             │
│                         │    │   - forward to api.anthropic.com     │
└─────────────────────────┘    │                                      │
                               │  KV: access_token, refresh_token     │
                               │  Secret: CLAUDE_REFRESH_TOKEN (seed)  │
                               └──────────────────────────────────────┘
                                                  │
                                                  ▼
                                     api.anthropic.com
                                     (billed against your Claude Max sub)
```

---

## Setup

See [SETUP.md](./SETUP.md) for a ~10-minute walkthrough from clone to working Claude Code on a DNS-blocked network.

Quick summary:

1. `git clone https://github.com/<you>/claude-oauth-worker.git ~/claude-oauth-worker && cd ~/claude-oauth-worker`
2. `npm install -g wrangler; wrangler login`
3. Edit `wrangler.toml` — change `name` to something unique under your Cloudflare account.
4. `wrangler kv namespace create CLAUDE_TOKEN_CACHE` — paste the returned id into `wrangler.toml`.
5. `wrangler deploy`
6. On a network where `claude.ai` IS reachable (e.g. personal laptop), sign in to Claude Code. Copy the `refreshToken` out of `~/.claude/.credentials.json`.
7. On your blocked-network laptop: `wrangler secret put CLAUDE_REFRESH_TOKEN` — paste the refresh token.
8. Set `ENABLE_AUTH_INJECTION = "true"` in `wrangler.toml`, redeploy (or flip via Cloudflare dashboard).
9. In `~/.claude/settings.json`, add `"ANTHROPIC_BASE_URL": "https://<your-worker>.workers.dev"` to the `env` block.
10. Apply Shape B: edit `~/.claude/.credentials.json`, set `claudeAiOauth.expiresAt` to `9999999999000`. Or run `scripts/shape-b-apply.ps1`.
11. Reload VSCode. You should now be able to use Claude Code without hitting the logout loop.

---

## Scripts included

- [`scripts/shape-b-apply.ps1`](./scripts/shape-b-apply.ps1) — rewrites `~/.claude/.credentials.json` to fake a far-future `expiresAt`. Idempotent.
- [`scripts/re-seed-worker-tokens.ps1`](./scripts/re-seed-worker-tokens.ps1) — prompts for a fresh refresh token and seeds it into the Worker + flushes KV. Use when the Worker returns `oauth_refresh_error` (stored refresh token has died).
- [`scripts/panic-rollback.ps1`](./scripts/panic-rollback.ps1) — reverts `ANTHROPIC_BASE_URL` and restores credentials from the pre-Shape-B backup. Use if something's on fire.

All three are PowerShell (Windows). Trivial to port to bash/zsh if you're on macOS/Linux.

---

## Failure handling

Most real-world failures are "the Worker's stored refresh token died" — which happens when Anthropic revokes it (e.g., you clicked "sign out everywhere") or it rotates into a dead state. Recovery is `scripts/re-seed-worker-tokens.ps1` after a fresh Claude Code login on an unblocked network.

See [SETUP.md → Failure handling](./SETUP.md#failure-handling) for the full decision tree.

---

## Disclaimer

See [DISCLAIMER.md](./DISCLAIMER.md).

## License

MIT — see [LICENSE](./LICENSE).
