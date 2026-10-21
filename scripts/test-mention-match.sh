#!/usr/bin/env bash
# Tests the "is the bot ADDRESSED, not just mentioned" matcher used by hermes-review.yml
# and claude-code.yml (s3ntin3l8/.github#41, #42). The function is extracted from the
# workflows themselves, so this exercises the shipped code, and the two copies must be
# byte-identical.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

extract() { # $1 = workflow file -> function text
  sed -n '/^ *# --- addressed()/,/^ *# --- end addressed() ---/p' "$1" | sed 's/^ *//'
}
extract "$ROOT/.github/workflows/hermes-review.yml" > "$TMP/hermes.fn"
extract "$ROOT/.github/workflows/claude-code.yml"   > "$TMP/claude.fn"
[[ -s "$TMP/hermes.fn" ]] || { echo "FAIL  no addressed() in hermes-review.yml"; exit 1; }
if diff -q "$TMP/hermes.fn" "$TMP/claude.fn" > /dev/null; then
  echo "  PASS  both workflows carry the same addressed()"; PASS=$((PASS+1))
else
  echo "  FAIL  addressed() differs between hermes-review.yml and claude-code.yml"; FAIL=$((FAIL+1))
fi
# shellcheck disable=SC1090
source "$TMP/hermes.fn"

t() { # $1 = want (yes|no), $2 = handle, $3 = label, $4 = text
  local got=no
  addressed "$4" "$2" && got=yes
  if [[ "$got" == "$1" ]]; then echo "  PASS  $3"; PASS=$((PASS+1));
  else echo "  FAIL  $3 (want $1, got $got)"; FAIL=$((FAIL+1)); fi
}

echo "== addressed =="
t yes claude "command at the start"                  "@claude Review the adjustments"
t yes claude "after a blank line"                    $'Thanks!\n\n@claude please re-review'
t yes claude "indented"                              "   @claude review"
t yes claude "followed by a comma"                   "@claude, take another look"
t yes claude "alone on its line"                     $'@claude\n'
t yes claude "case-insensitive"                      "@Claude review"
t yes claude "CRLF line endings"                     $'fyi\r\n@claude review\r\n'
t yes claude "list marker"                           "- @claude review"
t yes claude "star list marker"                      "* @claude review"
t yes claude "numbered list"                         "1. @claude review"
t yes claude "bold"                                  "**@claude** review"
t yes s3ntin3l8-hermes "hermes slug"                 "@s3ntin3l8-hermes Review"
t yes s3ntin3l8-hermes "hermes bot suffix"           "@s3ntin3l8-hermes[bot] review"
echo "== merely mentioned =="
t no  claude "the pocket-portfolio-tracker#567 status report" \
  "Addressed the review from @claude in a008c4a8: fixed the null check, fixed the retry."
t no  s3ntin3l8-hermes "the same report naming hermes"  "Addressed the review from @s3ntin3l8-hermes in abc123"
t no  claude "list item that only mentions it"       "- thanks @claude for the review"
t no  claude "no space after the list marker"        "-@claude review"
t no  claude "mid-sentence"                          "ping @claude when it is done"
t no  claude "quoted line"                           $'> @claude review\nthanks'
t no  claude "fenced code block"                     $'```\n@claude review\n```'
t no  claude "tilde fence"                           $'~~~\n@claude review\n~~~'
t no  claude "longer handle"                         "@claudex review"
t no  claude "hyphenated handle"                     "@claude-bot review"
t no  claude "email address"                         "mail me@claude.com"
t no  claude "no mention at all"                     "looks good"
t no  claude "empty"                                 ""
echo "== recovers after a closed fence =="
t yes claude "mention after a code block"            $'```\ncode\n```\n@claude review'

echo; echo "passed: $PASS   failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
