#!/usr/bin/env bash
# Exercises hermes-review.yml's review protocol against a fake Hermes API and
# a fake gh.
#
# This repo has no CI — a reusable workflow cannot run standalone — so the
# only real test is a consumer (see CLAUDE.md). This script is the cheaper
# first gate: it runs the workflow's own steps, extracted from the YAML, with
# the network edges faked. It caught the class of bug where `gh api graphql`
# was handed "owner/repo" instead of the repository's NAME (gh then looked for
# "owner/owner/repo"), which no YAML or shellcheck pass would have caught.
#
# Usage: scripts/test-hermes-review.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/hermes-review.yml"
TMP=$(mktemp -d)
PORT=${HERMES_FAKE_PORT:-8791}
PASS=0
FAIL=0

cleanup() {
  [[ -n "${FAKE_PID:-}" ]] && kill "$FAKE_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── the fake gh ────────────────────────────────────────────────────────────
# It answers the three reads the workflow does and records the writes, and it
# FAILS on the shapes that are easy to get wrong: `gh api graphql` takes the
# repository's name, `gh api repos/<owner>/<repo>/...` takes the pair.
cat > "$TMP/gh" <<'GH'
#!/usr/bin/env bash
args="$*"
log() { echo "$*" >> "$GH_LOG"; }
case "$args" in
  *"/pulls/"*".head.sha"*)  log "head ${FAKE_HEAD:-head111}"; echo "${FAKE_HEAD:-head111}"; exit 0 ;;
  *"/pulls/"*"reviews"*)    log "reviews ${FAKE_LAST_REVIEWED:-}"; echo "${FAKE_LAST_REVIEWED:-}"; exit 0 ;;
  *"graphql"*)
    # `gh api graphql` takes the repository's NAME, not "owner/repo".
    repo=""
    prev=""
    for a in $args; do
      if [[ "$prev" == "-F" && "$a" == repo=* ]]; then repo=${a#repo=}; fi
      prev=$a
    done
    if [[ "$repo" == */* ]]; then
      echo "gh: Could not resolve to a Repository with the name 's3ntin3l8/$repo'." >&2
      exit 1
    fi
    log "graphql repo=$repo"
    cat "${FAKE_MARKER_FILE:-/nonexistent}" 2>/dev/null || echo ""
    exit 0 ;;
  *"--method POST"*"check-runs"*) log "check-run created"; echo "${FAKE_CHECK_RUN_ID:-4242}"; exit 0 ;;
  *"--method PATCH"*"check-runs"*) log "check-run patched"; exit 0 ;;
esac
exit 0
GH
chmod +x "$TMP/gh"
export PATH="$TMP:$PATH"
export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"

# ── extract the steps under test from the workflow ─────────────────────────
python3 - "$WORKFLOW" "$TMP" <<'PY'
import sys, yaml
workflow, tmp = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(workflow))
for step in doc["jobs"]["hermes-review"]["steps"]:
    if step.get("id") in ("scope", "inflight", "run"):
        with open(f"{tmp}/{step['id']}.sh", "w") as fh:
            fh.write(step["run"])
PY

# ── the fake Hermes ────────────────────────────────────────────────────────
start_fake() {
  python3 "$ROOT/scripts/fake-hermes.py" "$PORT" "$1" &
  FAKE_PID=$!
  sleep 1
}
stop_fake() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }

check() { # $1 = label, $2 = yes/no
  if [[ "$2" == "yes" ]]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

run_step() { # $1 = step id, $2 = expected skip value
  local id=$1 want=$2 got
  export GITHUB_OUTPUT="$TMP/out.$id"; : > "$GITHUB_OUTPUT"
  ( set -uo pipefail; . "$TMP/$id.sh" ) > "$TMP/log.$id" 2>&1
  got=$(grep -oP '(?<=^skip=).*' "$GITHUB_OUTPUT" 2>/dev/null | tail -1)
  [[ "$got" == "$want" ]] && check "$id -> skip=$want" yes || check "$id -> skip='$got' (want '$want')" no
}

marker() { printf '%s' "$1" > "$TMP/marker.json"; export FAKE_MARKER_FILE="$TMP/marker.json"; }

# The environment the steps read.
export API_URL="http://127.0.0.1:$PORT" API_KEY="test-key" GH_TOKEN="test-token"
export REPO="acme/widgets" OWNER="acme" NUMBER="42" KIND="pr"
export BOT_LOGIN="s3ntin3l8-hermes[bot]" SCOPE_MODE="delta"
export LEDGER="check-run" LEDGER_NAME="Hermes review" USE_RUNS="true"
export HEAD_SHA="head111" BASE_SHA=""
export API_MODEL="hermes-agent" TARGET_KIND=pr TARGET_NUMBER=42 MODEL="" MAX_TURNS=30
export PROMPT_FILE="$TMP/prompt.md"; echo "REVIEW PROMPT" > "$PROMPT_FILE"
export GITHUB_STEP_SUMMARY="$TMP/summary.md"; : > "$GITHUB_STEP_SUMMARY"
export HERMES_POLL_SECONDS=2
export FAKE_REQUEST_LOG="$TMP/requests.log"; : > "$FAKE_REQUEST_LOG"

echo "== the review scope =="
export FAKE_HEAD="head111" FAKE_LAST_REVIEWED=""
run_step scope false
export FAKE_LAST_REVIEWED="head111"
run_step scope true          # already reviewed at this head -> skip
export FAKE_LAST_REVIEWED="old999"
run_step scope false         # a previous round exists -> delta, not a skip
export FAKE_LAST_REVIEWED=""

echo "== the in-flight marker =="
start_fake '{"run_status":"running","request_log":"'"$TMP"'/requests.log"}'
marker ""                              # no marker at all
run_step inflight false
marker '{"oid":"head111","run":"run_live"}'
run_step inflight true                 # the same head is already being reviewed
marker '{"oid":"old999","run":"run_live"}'
run_step inflight false                # the head moved -> stop the stale run
grep -q "^stale_run=run_live" "$TMP/out.inflight" && check "the stale run is stopped" yes || check "the stale run is stopped" no
marker '{"oid":"old999","run":"run_done"}'
stop_fake
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
run_step inflight false                # a finished run -> the marker is stale

echo "== the dispatch =="
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.run" 2>&1
grep -q '"idempotency_key": "hermes-review:acme/widgets#42@..head111"' "$TMP/requests.log" \
  && check "the idempotency key names the review range" yes \
  || check "the idempotency key names the review range" no
grep -q '"session_id": "hermes-review-acme-widgets-42"' "$TMP/requests.log" \
  && check "the run happens in one session per pull request" yes \
  || check "the run happens in one session per pull request" no
grep -q "check-run created" "$GH_LOG" && check "the in-flight marker is written" yes || check "the in-flight marker is written" no
grep -q "check-run patched" "$GH_LOG" && check "the in-flight marker is closed" yes || check "the in-flight marker is closed" no
stop_fake

echo "== the dispatch refuses what it must =="
start_fake '{"dispatch_code":429,"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.429" 2>&1; rc=$?
grep -q "concurrent-run cap" "$TMP/log.429" && check "HTTP 429 fails the step" yes || check "HTTP 429 fails the step" no
[[ $rc -ne 0 ]] && check "HTTP 429 exits non-zero" yes || check "HTTP 429 exits non-zero" no
stop_fake

start_fake '{"dispatch_code":401,"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.401" 2>&1; rc=$?
[[ $rc -ne 0 ]] && check "HTTP 401 exits non-zero" yes || check "HTTP 401 exits non-zero" no
stop_fake

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
