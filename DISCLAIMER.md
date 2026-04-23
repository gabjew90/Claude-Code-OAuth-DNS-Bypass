# Disclaimer

This Worker is for users with **legitimate Claude Max (or equivalent) subscriptions** who are blocked from reaching Anthropic's servers by environmental network restrictions — e.g., corporate DNS filters like Cisco Umbrella that block `api.anthropic.com`, `claude.ai`, `platform.claude.com`.

## What this does, and does not

**Does:**
- Route your own traffic through your own Cloudflare Worker so DNS filters on your network don't see the destination.
- Perform OAuth refresh on Cloudflare's network (using **your** refresh token, extracted from **your** `~/.claude/.credentials.json` after **you** logged into Claude Code on a network where `claude.ai` is reachable) using the same public OAuth flow Claude Code and the Claude Agent SDK use.
- Inject the minted access token into **your** outbound requests to `api.anthropic.com`.

**Does not:**
- Bypass Claude subscription billing. Every request counts against your Max sub's message bucket, exactly as if you'd made it directly from claude.ai. No API key is involved.
- Elevate scopes. The refresh scope is exactly what Claude Code itself requests — `user:file_upload user:inference user:mcp_servers user:profile user:sessions:claude_code`. No more.
- Share tokens between users. Each deployment is one person's Worker, one person's Cloudflare KV, one person's refresh token.
- Exploit any security vulnerability. The reverse-engineered client ID and token URL are visible in claude-code's publicly distributed VSCode extension; nothing extracted here is secret.
- Circumvent Anthropic's account terms. If Anthropic's TOS prohibits programmatic use of your Claude Max sub at your scale of usage, **that applies to you regardless of whether you use this Worker**. Check current TOS.

## Who this is for

Yourself. Your Cloudflare account. Your Max subscription. Do not expose the Worker URL as a public service — a refresh token that leaks lets anyone impersonate you against Anthropic.

## Who this is NOT for

- Reselling Claude access.
- Sharing a single refresh token across multiple people or bots.
- Circumventing geographic or age restrictions on Anthropic's products.
- Anything Anthropic would consider bad-faith use of a consumer subscription.

## Network / IT considerations

If you're using this on an employer-owned laptop (common case — corporate DNS is what prompted this kind of workaround), consider:

- **Is this against acceptable use policy?** Probably not, if you're already authorized to use Claude for work, but read your IT policy.
- **Does your employer monitor outbound traffic?** This doesn't hide the fact that you're talking to `<your-worker>.workers.dev`. It only hides the *final* Anthropic destination from DNS-layer filters. Deep packet inspection / SNI-based firewalls can still flag the Cloudflare traffic.
- **Data egress:** your Claude prompts and responses pass through Cloudflare infrastructure (their edge + workers runtime). Cloudflare doesn't read or store them, but this is one more third party in the loop vs. a direct Anthropic connection. If your prompts include confidential employer data, weigh this.

## No warranty

MIT license. Use at your own risk. If Anthropic rotates their OAuth mechanism and this breaks, or if your employer updates their filter to block Cloudflare Workers too, or if anything else goes sideways: that's on you to repair or roll back.
