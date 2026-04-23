# claude-oauth-worker

Three Cloudflare Workers that give you **full Claude access from DNS-filtered environments** where direct connections to `api.anthropic.com`, `claude.ai`, `pivot.claude.ai`, etc. are blocked.

Typical use case: your corporate / school / restricted network filters Anthropic domains, but you have a paid Claude Max subscription and want to actually use it from your work laptop. Workers live on Cloudflare (usually not blocked), proxy your traffic, and handle OAuth token refresh server-side.

## What you get

1. **VSCode Claude Code** stays logged in indefinitely on the blocked network — no daily credential re-paste ritual.
2. **Anthropic's official Claude-for-Office add-ins** (Excel, PowerPoint, Word) install and authenticate cleanly, with all traffic routed through your own Cloudflare proxy.
3. One-command install/uninstall for Office sideloads, plus a diagnostic script for when Anthropic's bundle changes and a rewrite breaks.

You keep your Claude Max quota. No API key, no extra billing — everything runs on the real OAuth tokens your normal Claude account issues.

## Architecture at a glance

```
Your blocked-network laptop                Cloudflare (unblocked)
┌──────────────────────────┐  ┌──────────────────────────────────────────────────┐
│  VSCode Claude Code      │─▶│ <main>.workers.dev                               │
│  (ANTHROPIC_BASE_URL)    │  │   - proxies api.anthropic.com                    │
│                          │  │   - refreshes OAuth tokens using refresh token   │
│                          │  │     stored as Worker secret + KV rotation cache  │
│                          │  └──────────────────────────────────────────────────┘
│                          │  ┌──────────────────────────────────────────────────┐
│  Office add-ins          │─▶│ <pivot>.workers.dev                              │
│  (Excel / PowerPoint /   │  │   - proxies pivot.claude.ai (official add-in)    │
│    Word task panes,      │  │   - surgical JS-bundle rewrites so redirect_uri  │
│    sideloaded)           │  │     is a registered URI, token exchange hits     │
│                          │  │     /v1/oauth/token on this proxy, inference     │
│                          │  │     calls hit the main Worker above              │
└──────────────────────────┘  └──────────────────────────────────────────────────┘
                                            │
                                            ▼
                                  api.anthropic.com / claude.ai / pivot.claude.ai
                                  (billed against your Claude Max subscription)
```

## Who this is for

Yourself. One Claude account, one Cloudflare account, one laptop. Don't publish your Worker URLs — a leaked refresh token lets anyone impersonate you against Anthropic. See [DISCLAIMER.md](./DISCLAIMER.md).

## Quick setup

See [SETUP.md](./SETUP.md) for the full walkthrough. Summary:

```powershell
# One-time
git clone https://github.com/<you>/claude-oauth-worker.git ~\claude-oauth-worker
cd ~\claude-oauth-worker
npm install -g wrangler
wrangler login

# Create KV, edit wrangler.toml with the returned id + change 'name' values
wrangler kv namespace create CLAUDE_TOKEN_CACHE

# Deploy the three Workers
wrangler deploy                    # main
wrangler deploy --env test         # optional soak env
wrangler deploy --env pivot        # only needed for Office add-ins

# Fix VSCode Claude Code — see SETUP.md for the refresh-token bootstrap

# Install Office add-ins (Excel/PowerPoint/Word)
.\scripts\install-office-addins.ps1 -PivotWorkerUrl "https://<your-pivot>.workers.dev"
```

## Features

### VSCode Claude Code auth fix

- The main Worker accepts normal Anthropic API requests.
- When `ENABLE_AUTH_INJECTION=true`, it refreshes OAuth tokens server-side using a long-lived refresh token stored as a Worker secret, caches the resulting access token in Cloudflare KV, and rewrites `Authorization: Bearer` headers on outbound requests.
- Combined with "Shape B" (a one-field edit in your local `~/.claude/.credentials.json` setting `expiresAt` to the year 2286), Claude Code never attempts its own refresh, never runs into the DNS block, never logs you out.

See [SETUP.md](./SETUP.md) for the bootstrap.

### Office add-ins (Claude for Excel, PowerPoint, Word)

The pivot-proxy Worker proxies Anthropic's add-in backend at `pivot.claude.ai`. It rewrites the add-in's minified JS bundle in flight to:

- Force a registered `redirect_uri` so OAuth authorize doesn't 400.
- Route the OAuth token exchange through this Worker (so the DNS-blocked laptop can mint tokens).
- Route the add-in's inference calls through your main Worker (so chat with Claude from inside Excel actually reaches Anthropic).

See [PIVOT-PROXY.md](./PIVOT-PROXY.md) for the full spec, troubleshooting, and recovery steps when Anthropic ships a breaking bundle change.

## Included scripts

| Script | Purpose |
|---|---|
| `scripts/install-office-addins.ps1 -PivotWorkerUrl <url>` | Generate Excel/PowerPoint/Word manifests from templates, substituting your Worker URL, and register them in HKCU so Office picks them up. No admin needed. |
| `scripts/uninstall-office-addins.ps1` | Remove the Office add-in registry entries. |
| `scripts/re-seed-worker-tokens.ps1` | When Anthropic rotates your refresh token or revokes it, paste a fresh one and re-seed both the secret and KV. |
| `scripts/shape-b-apply.ps1` | Idempotently set `expiresAt` far-future in `~/.claude/.credentials.json` so Claude Code doesn't try to refresh locally. |
| `scripts/panic-rollback.ps1` | Revert `ANTHROPIC_BASE_URL` and restore credentials from the pre-Shape-B backup. |
| `scripts/diagnose-pivot-rewrite.sh <pivot-url>` | Fetch the current add-in bundle and check every critical rewrite with PASS/FAIL. Run first when the Office add-in breaks. |

## Failure handling

**Most-likely failure:** the refresh token stored in the main Worker dies (Anthropic rotated, you signed out, etc.) → Worker returns `oauth_refresh_error`. Recovery is a fresh Claude Code login on an unblocked network, re-seed Worker. See SETUP.md → "Failure handling".

**Second most likely:** Anthropic ships a new add-in bundle whose minified form doesn't match a regex in `pivot-proxy.js`. Run `bash scripts/diagnose-pivot-rewrite.sh <pivot-url>`. The first `[FAIL]` tells you what to fix.

See [PIVOT-PROXY.md](./PIVOT-PROXY.md) for the troubleshooting matrix.

## Disclaimer

See [DISCLAIMER.md](./DISCLAIMER.md). Not affiliated with or endorsed by Anthropic. Using the pivot-proxy to access Anthropic's official add-in is a workaround for broken network conditions; it uses your own Claude account's real OAuth tokens and the same public OAuth flow the add-in uses normally.

## License

MIT — see [LICENSE](./LICENSE).
