#!/usr/bin/env bash
# app-token.sh — mint a GitHub App *installation* token, attributed to <slug>[bot].
#
# Equivalent of actions/create-github-app-token, but runnable OUTSIDE Actions
# (e.g. from a Hermes session / cronjob / the hermes-01 API server). The agent on
# hermes-01 calls this to obtain a token before doing `gh`/REST work, so all GitHub
# actions are attributed to the App — not your personal account.
#
# Requirements (already provided by the review-bot profile .env):
#   HERMES_APP_ID            numeric App ID (e.g. 4303310)
#   HERMES_APP_PRIVATE_KEY   PEM private key (single logical line; \n escaped OK)
#   HERMES_INSTALLATION_ID   (optional) install id; auto-resolved if you have ONE install
#
# Usage:  export GITHUB_TOKEN="$(~/.hermes/scripts/app-token.sh)"
#
# Exit codes: 2 missing deps, 3 missing creds, 4 token exchange failed.

set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "::error::app-token.sh requires '$1'" >&2; exit 2; }; }
need openssl
need curl
need jq

: "${HERMES_APP_ID:?set HERMES_APP_ID (GitHub App numeric id)}"
: "${HERMES_APP_PRIVATE_KEY:?set HERMES_APP_PRIVATE_KEY (App PEM; \\n-escaped on one line is fine)}"

# Restore real newlines in the PEM if it was stored escaped.
PEM=$(printf '%s' "$HERMES_APP_PRIVATE_KEY" | sed 's/\\n/\n/g')

# Resolve installation id (auto if exactly one install on the account/org).
if [[ -z "${HERMES_INSTALLATION_ID:-}" ]]; then
  INSTALLATIONS=$(curl -sS -X GET \
    -H "Authorization: Bearer $(jwt)" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/app/installations 2>/dev/null) || INSTALLATIONS=""
  COUNT=$(printf '%s' "$INSTALLATIONS" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
  if [[ "$COUNT" == "1" ]]; then
    HERMES_INSTALLATION_ID=$(printf '%s' "$INSTALLATIONS" | jq -r '.[0].id')
  elif [[ "$COUNT" == "0" ]]; then
    echo "::error::app-token.sh: no installations found for this App" >&2; exit 4
  else
    echo "::error::app-token.sh: multiple installations (COUNT=$COUNT); set HERMES_INSTALLATION_ID explicitly" >&2; exit 4
  fi
fi

# Sign the App JWT.
jwt() {
  local now; now=$(date +%s)
  local iat=$(( now - 60 ))
  local exp=$(( now + 540 ))   # GitHub allows max 10 min; stay under
  local header b64hdr payload b64payload
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(jq -n --arg iat "$iat" --arg exp "$exp" --arg iss "$HERMES_APP_ID" \
    '{iat: ($iat|tonumber), exp: ($exp|tonumber), iss: ($iss|tonumber)}')
  b64() { openssl base64 -A | tr '+' '-' | tr '/' '_' | tr -d '='; }
  b64hdr=$(printf '%s' "$header"  | b64)
  b64payload=$(printf '%s' "$payload" | b64)
  printf '%s.%s' "$b64hdr" "$b64payload" \
    | openssl dgst -sha256 -sign <(printf '%s\n' "$PEM") -binary \
    | b64 \
    | sed "s|^|$(printf '%s.%s' "$b64hdr" "$b64payload").|"
}

JWT=$(jwt)

TOKEN_JSON=$(curl -sS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/$HERMES_INSTALLATION_ID/access_tokens")

TOKEN=$(printf '%s' "$TOKEN_JSON" | jq -r '.token // empty')
if [[ -z "$TOKEN" ]]; then
  echo "::error::app-token.sh: token exchange failed: $TOKEN_JSON" >&2
  exit 4
fi

printf '%s' "$TOKEN"
