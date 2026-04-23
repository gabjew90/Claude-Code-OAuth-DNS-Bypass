# claude-oauth-worker

**Use your Claude Max / Pro / Team / Enterprise account from a network that blocks Anthropic.**

If your corporate / school / restricted network DNS-filters `api.anthropic.com`, `claude.ai`, `pivot.claude.ai`, or similar — but you have a legitimate Claude subscription — this repo deploys small Cloudflare Workers that proxy the traffic through a domain your network doesn't block (`*.workers.dev`). You run Anthropic's own services through your own Cloudflare account.

**Two capabilities. Pick either, or both:**

1. **VSCode Claude Code stays logged in** — no more daily credential re-paste ritual.
2. **Claude for Excel / PowerPoint add-ins install and work** — Anthropic's official add-ins on your blocked machine.

No API key, no extra billing. Your traffic still counts against your existing Claude subscription quota — same as if you were using Claude normally. Just routed differently.

---

## Does this apply to me?

You want this if **all** of these are true:

- [ ] You have a paid Claude subscription (Pro / Max / Team / Enterprise — not an API-only account).
- [ ] You use Claude on a laptop/machine that blocks `*.anthropic.com` / `*.claude.ai` / `*.claude.com` at the DNS layer (typical for Cisco Umbrella, corporate zero-trust, restrictive school networks, etc.).
- [ ] You have another device — phone, personal laptop on home wifi — where Claude domains *do* resolve normally. (You'll use it once to get a refresh token, and once per device for Office-add-in sign-in.)
- [ ] You're comfortable running PowerShell and `wrangler` commands on the blocked machine.

If you want **only the Excel/PowerPoint add-ins** and don't care about VSCode Claude Code, see the standalone repo [claude-office-addin-proxy](https://github.com/<you>/claude-office-addin-proxy) — simpler to set up (only two Workers, no OAuth bootstrap).

---

## Architecture — how it fits together

The setup deploys **three Cloudflare Workers** under your account. Each has one job and stays in its lane:

```
Your blocked-network laptop                                  Cloudflare (not blocked)
┌──────────────────────────────────────┐
│                                      │
│  VSCode Claude Code                  │   auto-refreshes your OAuth token
│  env.ANTHROPIC_BASE_URL  ──────────▶ │   <name>-test.workers.dev
│                                      │   (ENABLE_AUTH_INJECTION = "true")
│                                      │   Worker strips stale Bearer token,
│                                      │   injects a fresh one minted via
│                                      │   server-side OAuth refresh.
│                                      │
│                                      │
│  Office add-ins (Excel / PowerPoint) │   pass-through for api.anthropic.com
│  (sideloaded manifest)               │   <name>.workers.dev
│       │                              │   (ENABLE_AUTH_INJECTION = "false")
│       │ bundle rewrites route its    │   Forwards requests unchanged. The
│       │ api.anthropic.com calls here │   add-in's OWN OAuth token stays
│       ▼                              │   intact — critical, because it's
│                                      │   scoped to a different client_id
│                                      │   than VSCode's token.
│                                      │
│       │                              │   proxies the add-in's UI (HTML/JS)
│       │ manifest SourceLocation      │   <name>-pivot.workers.dev
│       │ points here                  │   Does surgical JS-bundle rewrites
│       ▼                              │   so OAuth completes with a
│                                      │   registered redirect_uri and the
│                                      │   token-exchange POST goes through
│                                      │   us instead of DNS-blocked claude.ai.
└──────────────────────────────────────┘
                                               │
                                               ▼
                                    api.anthropic.com / claude.ai / pivot.claude.ai
                                    (billed against your Claude subscription)
```

### Why three Workers, not one

Each Worker has a different role and **different requirements**:

| Worker | Auth injection | Purpose |
|---|---|---|
| `<name>.workers.dev` (main) | **OFF — pass-through** | Office add-ins' API calls route here. They already have their own valid OAuth token (from sign-in); injecting Claude-Code's token on top would break them (token is tied to a different `client_id`). |
| `<name>-test.workers.dev` | **ON — auth injection** | VSCode Claude Code points here. Needed because Claude Code's local OAuth refresh endpoint is DNS-blocked; this Worker refreshes on its behalf. |
| `<name>-pivot.workers.dev` | n/a (not an API proxy) | Proxies Anthropic's add-in UI with bundle rewrites. Only needed if you use the Office add-ins. |

**Do not collapse these.** If you turn auth-injection on the main Worker, the Office add-ins break. If you turn it off the test Worker, VSCode stops getting refreshed tokens. The splits are deliberate.

---

## Setup

Pick your path. Full walkthrough: [SETUP.md](./SETUP.md).

**Just VSCode Claude Code** (about 10 min):  → [SETUP.md Part A](./SETUP.md#part-a--vscode-claude-code-auth-fix)

**Just Office add-ins** (about 15 min):  → [SETUP.md Part B](./SETUP.md#part-b--office-add-ins-excel--powerpoint--word)

**Both** (about 20 min): do Part A, then Part B. Part B reuses some of Part A's setup.

---

## What you get, once set up

**VSCode Claude Code on the blocked machine:**
- Works exactly like on an unblocked network
- Silent token refresh every few hours via your Worker
- You never see a "logged out" state again

**Office add-ins on the blocked machine:**
- Click **Insert → Get Add-ins → My Add-ins → Developer Add-ins → Claude (proxied, Excel)** → Add
- Task pane opens with Anthropic's real Claude UI
- Sign in once per device via phone (paste a URL, authorize, done)
- Tokens persist across Office restarts, machine reboots

---

## Included scripts

All scripts are in `scripts/`. Run from the repo root (`cd ~/claude-oauth-worker`).

| Script | When to run it |
|---|---|
| `install-office-addins.ps1 -PivotWorkerUrl <url>` | Once, after deploying your pivot Worker, to sideload Office manifests. Also after Anthropic bundle updates, to bump manifest version and force WebView2 reload. |
| `uninstall-office-addins.ps1` | To remove the Office sideloads from HKCU. |
| `re-seed-worker-tokens.ps1` | When the main Worker starts returning `oauth_refresh_error` (Anthropic revoked your stored refresh token). Requires fetching a fresh refresh token from your personal device first. |
| `shape-b-apply.ps1` | Once, during VSCode setup, to set `expiresAt` far-future in your local credentials so Claude Code doesn't attempt its own (DNS-blocked) refresh. |
| `panic-rollback.ps1` | When everything's on fire — reverts VSCode to pre-fix state so you can fall back to manual credential pasting. |
| `diagnose-pivot-rewrite.sh <pivot-url>` | When the Office add-in breaks after an Anthropic bundle update. First `[FAIL]` tells you what regex to update in `src/pivot-proxy.js`. |

---

## When it breaks

**VSCode stops working suddenly:**
- Most likely cause: Anthropic rotated / revoked your stored refresh token.
- Fix: [SETUP.md → "Recovery"](./SETUP.md#recovery-when-things-break)

**Office add-in stops working after an Anthropic update:**
- Most likely cause: Anthropic shipped a new bundle whose minified shape doesn't match one of our regex rewrites.
- Fix: [PIVOT-PROXY.md → troubleshooting](./PIVOT-PROXY.md)

**Everything's on fire:**
- Run `scripts/panic-rollback.ps1`. You're back to pre-setup state in 90 seconds.

---

## Known fragility

- **Pattern-based JS-bundle rewrites** (for the Office add-ins) depend on Anthropic's minified code staying structurally similar. Anthropic deploys frequently. A given regex set has a useful life of weeks to months. When it breaks, the diagnostic script tells you what to fix.
- **OAuth refresh tokens die** periodically (Anthropic security policy). You'll re-seed once every few weeks to months using the re-seed script.
- **Cloudflare Workers outage** = everything down. Historically ~99.99% uptime; not a real concern.
- **Anthropic's ToS** applies. This setup uses your own Claude account with your own OAuth tokens — same auth flow Anthropic's clients use. No scope escalation, no billing trickery. See [DISCLAIMER.md](./DISCLAIMER.md).

---

## FAQ

**Does this cost anything?**
No. Cloudflare Workers free tier is 100,000 requests/day. Your Claude usage still counts against your existing subscription quota — exactly the same as if you used Claude directly.

**Is this against Anthropic's terms?**
This uses Anthropic's own public OAuth flow with your own tokens. No scope escalation, no sharing across users, no bypassing billing. It's functionally identical to Anthropic's intended flow — just with an extra hop that you control. That said, this is unofficial and unsupported by Anthropic; read [DISCLAIMER.md](./DISCLAIMER.md) and use good judgment.

**Will my employer's DLP see my Claude prompts?**
Your traffic goes to Cloudflare's network (which their filter doesn't block) and then to Anthropic. SNI-level inspection might see that you're talking to Cloudflare Workers, but not what's in the traffic (it's TLS). If your prompts include sensitive work data, weigh the privacy implications of running it through Cloudflare infra vs. Anthropic direct.

**Does this work on Mac? Linux?**
The Workers run on Cloudflare — platform-agnostic. The PowerShell scripts are Windows-specific. On Mac/Linux, the equivalent commands are trivial (bash `sed`, `nix-env install wrangler`, etc.) but not pre-written. Contributions welcome.

**My refresh token rotates. How often will I need to re-seed?**
Empirically every few weeks to months, depending on how often Anthropic's policy triggers a revocation. You'll know because the Worker starts returning `oauth_refresh_error` — at which point you run the re-seed script with a fresh token from your personal device. ~90 seconds.

**Can I run multiple Claude accounts?**
One account per Worker. You can deploy multiple copies of this repo under different Worker names to handle multiple accounts.

**Why don't you just ask IT to allowlist Anthropic?**
You should. This repo exists for situations where IT either can't or won't. If your IT team will approve the allowlist, that's a better long-term solution than any of this.

---

## License

MIT — see [LICENSE](./LICENSE).

## Disclaimer

See [DISCLAIMER.md](./DISCLAIMER.md). Not affiliated with or endorsed by Anthropic or Microsoft.
