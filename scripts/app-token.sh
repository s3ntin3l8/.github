#!/usr/bin/env bash
# app-token.sh — mint a GitHub App *installation* token (acts as <slug>[bot]).
#
# This is the OUT-OF-ACTIONS equivalent of `actions/create-github-app-token`: it signs
# a JWT with the App's private key and exchanges it for a short-lived installation
# token, so a local Hermes session (the `review-bot` profile, a gateway, or a cronjob)
# can drive `gh` / the REST API AS THE APP — not as your personal account.
#
# WHERE THIS LIVES
#   - Versioned here (scripts/app-token.sh) in s3ntin3l8/.github, the shared home.
#   - On the runner, copy it to ~/.hermes/scripts/app-token.sh so the review-bot
#     profile can call it. The agent then does:
#         export GITHUB_TOKEN="$(~/.hermes/scripts/app-token.sh)"
#     and every subsequent `gh` / curl call is attributed to <slug>[bot].
#
# SECRETS (provide via the review-bot profile's ~/.hermes/profiles/review-bot/.env,
#          NOT a repo secret — this runs locally on your self-hosted runner)
#   HERMES_APP_ID            GitHub App numeric ID
#   HERMES_APP_PRIVATE_KEY   PEM private key (single-line with \n, or literal newlines)
#   HERMES_INSTALLATION_ID   installation ID (optional; auto-resolved to the first one)
#   HERMES_APP_TOKEN_TTL     token lifetime seconds (max 3600; default 3600)
#
# REQUIRES: openssl, curl, jq.
set -euo pipefail

APP_ID="${HERMES_APP_ID:?HERMES_APP_ID required}"
PRIVATE_KEY="${HERMES_APP_PRIVATE_KEY:?HERMES_APP_PRIVATE_KEY required}"
TTL="${HERMES_APP_TOKEN_TTL:-3600}"

# Accept the PEM either as literal newlines or as \n-escaped (common in .env files).
if [[ "$PRIVATE_KEY" == *\\n* ]]; then
  PRIVATE_KEY="$(printf '%b' "$PRIVATE_KEY")"
fi

NOW="$(date +%s)"
IAT=$((NOW - 60))   # issue-at, 60s skew tolerance
EXP=$((NOW + 600))  # JWT valid 10 minutes

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
HEADER="$(printf '{"alg":"RS256","typ":"JWT"}' | b64)"
PAYLOAD="$(printf '{"iat":%d,"exp":%d,"iss":%s}' "$IAT" "$EXP" "$APP_ID" | b64)"
SIGNING_INPUT="${HEADER}.${PAYLOAD}"
SIG="$(printf '%s' "$SIGNING_INPUT" | openssl dgst -sha256 -sign <(printf '%s\n' "$PRIVATE_KEY") | b64)"
JWT="${SIGNING_INPUT}.${SIG}"

# Resolve installation id if not provided.
if [[ -z "${HERMES_INSTALLATION_ID:-}" ]]; then
  HERMES_INSTALLATION_ID="$(curl -sS -X GET \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations" | jq -r '.[0].id')"
fi

# Exchange the JWT for an installation token.
curl -sS -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${HERMES_INSTALLATION_ID}/access_tokens?expires_in=${TTL}" \
  | jq -r '.token'
