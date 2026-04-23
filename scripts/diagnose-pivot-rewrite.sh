#!/usr/bin/env bash
# Verify the pivot-proxy Worker's bundle rewrites are still matching the
# current Anthropic-served add-in bundle. Run when the "Claude (proxied)"
# add-in stops working after an Anthropic deploy.
#
# Usage:
#   bash scripts/diagnose-pivot-rewrite.sh <your-pivot-worker-url>
# Example:
#   bash scripts/diagnose-pivot-rewrite.sh https://claude-oauth-worker-pivot.yourname.workers.dev

set -u

WORKER="${1:-}"
if [ -z "$WORKER" ]; then
  echo "Usage: $0 <pivot-worker-url>"
  exit 2
fi
WORKER="${WORKER%/}"

TMP=$(mktemp)
trap "rm -f $TMP $TMP.html" EXIT

echo ""
echo "=== 1. Fetch HTML from proxy ==="
curl -sf "$WORKER/?dx=$(date +%s)" -m 15 > "$TMP.html" || { echo "  ERROR: HTML fetch failed"; exit 1; }
BUNDLE_URL=$(grep -oE 'src="/m-addin/assets/index-[^"?]+\.js' "$TMP.html" | head -1 | sed 's|src="||')
if [ -z "$BUNDLE_URL" ]; then
  echo "  ERROR: could not find bundle URL in HTML response"
  head -c 500 "$TMP.html"
  exit 1
fi
echo "  Bundle: $BUNDLE_URL"

echo ""
echo "=== 2. Fetch bundle ==="
curl -sf "$WORKER$BUNDLE_URL?dx=$(date +%s)" -m 30 > "$TMP" || { echo "  ERROR: bundle fetch failed"; exit 1; }
SIZE=$(wc -c < "$TMP")
echo "  Size: $SIZE bytes"
if [ "$SIZE" -lt 1000000 ]; then
  echo "  WARN: bundle looks suspiciously small"
fi

echo ""
echo "=== 3. Check E0 (redirect_uri) rewrite ==="
CB=$(grep -oE "function [A-Za-z0-9_\$]{1,5}\(\)\{return\"[^\"]*auth/callback\"\}" "$TMP" | head -1)
if [ -n "$CB" ] && echo "$CB" | grep -q '"https://pivot.claude.ai/auth/callback"'; then
  echo "  [OK] $CB"
elif [ -n "$CB" ]; then
  echo "  [FAIL] callback fn returns wrong value: $CB"
else
  echo "  [FAIL] no function returning /auth/callback found"
fi

echo ""
echo "=== 4. Check template literal is replaced ==="
if grep -qE '\$\{[^}]*location\.origin[^}]*\}/auth/callback' "$TMP"; then
  echo "  [FAIL] template literal still present — E0 regex missed"
else
  echo "  [OK] no template literal remains"
fi

echo ""
echo "=== 5. Check tokenEndpoint rewrite ==="
TE=$(grep -oE "tokenEndpoint:[^,}]{1,120}" "$TMP" | head -3)
if echo "$TE" | grep -q "/v1/oauth/token"; then
  echo "  [OK] $TE"
elif echo "$TE" | grep -qE "tokenEndpoint:(\`|\")https?://claude\.ai"; then
  echo "  [FAIL] tokenEndpoint still hits claude.ai directly"
  echo "         $TE"
fi

echo ""
echo "=== 6. Check A1 (api.anthropic.com) rewrite ==="
A=$(grep -oE "function [A-Za-z0-9_\$]{1,5}\(\)\{return\"https://[^\"]+\"\}" "$TMP" | grep -E "(api\.anthropic|workers\.dev)" | head -3)
if echo "$A" | grep -qE 'workers\.dev"'; then
  echo "  [OK] $A"
elif echo "$A" | grep -q "https://api.anthropic.com"; then
  echo "  [FAIL] A1 still hits api.anthropic.com"
  echo "         $A"
else
  echo "  [INFO] no matching fn — minification shape may have changed"
fi

echo ""
echo "=== 7. Worker endpoints ==="
for path in "/_/inject" "/oauth/authorize"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$WORKER$path" -m 10)
  echo "  GET $path -> $code"
done

echo ""
echo "If any [FAIL]: update the regex in src/pivot-proxy.js, then:"
echo "  wrangler deploy --env pivot"
echo "  # then in Excel: quit, clear WebView2 cache, reopen, re-add the add-in"
