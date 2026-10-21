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
# A random base port: a fake left behind by a killed run would otherwise hold
# the port the next run wants, and the run would silently talk to the WRONG
# fake (its state, not this section's).
PORT=${HERMES_FAKE_PORT:-$((20000 + RANDOM % 20000))}
PASS=0
FAIL=0

# Each fake gets its own port: a leftover one from an earlier (killed) run
# would otherwise keep serving its own state to the next section, and the
# harness would report failures that belong to nobody.
# The port is bumped in the CALLER (not in a command substitution, which
# would run the function in a subshell and throw the new value away), so
# every fake really lands on a port of its own.
next_port() { PORT=$((PORT + 1)); }

cleanup() {
  # Every fake this run started, not just the last one: a section that ended
  # early (a killed run, a failed assertion) would otherwise leave a fake
  # behind, holding its port and answering the NEXT run with its own state.
  for pid in "${FAKE_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
FAKE_PIDS=()

# ── the fake gh ────────────────────────────────────────────────────────────
# It answers the three reads the workflow does and records the writes, and it
# FAILS on the shapes that are easy to get wrong: `gh api graphql` takes the
# repository's name, `gh api repos/<owner>/<repo>/...` takes the pair.
cat > "$TMP/gh" <<'GH'
#!/usr/bin/env bash
# The arguments are walked as an array, not as a flattened string: the --jq
# filter contains spaces and quotes, and word-splitting it would hand jq a
# truncated program.
args=("$@")
joined="${args[*]}"
log() { echo "$*" >> "$GH_LOG"; }
case "$joined" in
  *"/pulls/"*".head.sha"*)  log "head ${FAKE_HEAD:-head111}"; echo "${FAKE_HEAD:-head111}"; exit 0 ;;
  *"/pulls/"*"reviews"*)
    # A real review list, run through the workflow's own --jq filter, so the
    # filter is exercised here and not only in a consumer run.
    log "reviews"
    # Hermes' own review at FAKE_LAST_REVIEWED, plus (optionally) another bot's review
    # at FAKE_OTHER_BOT_REVIEWED, which must never count (s3ntin3l8/.github#99).
    reviews='[{"user":{"type":"Bot","login":"s3ntin3l8-hermes[bot]"},"state":"APPROVED","commit_id":"'"${FAKE_LAST_REVIEWED:-}"'"}'
    if [[ -n "${FAKE_OTHER_BOT_REVIEWED:-}" ]]; then
      reviews+=',{"user":{"type":"Bot","login":"claude[bot]"},"state":"COMMENTED","commit_id":"'"${FAKE_OTHER_BOT_REVIEWED}"'"}'
    fi
    reviews+=']'
    filter=""
    prev=""
    for a in "${args[@]}"; do
      if [[ "$prev" == "--jq" ]]; then filter="$a"; fi
      prev="$a"
    done
    if [[ -n "$filter" ]]; then
      printf '%s' "$reviews" | jq -r "$filter" 2>/dev/null || echo ""
    else
      printf '%s' "$reviews"
    fi
    exit 0 ;;
  *"graphql"*)
    # `gh api graphql` takes the repository's NAME, not "owner/repo".
    repo=""
    prev=""
    for a in "${args[@]}"; do
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
  *"--method POST"*"check-runs"*) log "check-run created ${args[*]}"; echo "${FAKE_CHECK_RUN_ID:-4242}"; exit 0 ;;
  *"--method PATCH"*"check-runs"*) log "check-run patched"; exit 0 ;;
  *"/check-runs"*)
    # The check runs already on a commit — the in-flight marker. The step
    # applies its own --jq filter to this, so the fake does too.
    # (This case must come AFTER the POST and PATCH cases: they match the
    # same path, and a marker listing would answer them with the wrong shape.)
    log "check-runs"
    runs='{"total_count":1,"check_runs":[{"name":"'"${LEDGER_NAME:-Hermes review}"'","external_id":"'"${FAKE_MARKER_RUN-run_dead}"'","output":{"summary":"'"${FAKE_MARKER_SESSION:+session: $FAKE_MARKER_SESSION}"'"}}]}'
    filter=""
    prev=""
    for a in "${args[@]}"; do
      if [[ "$prev" == "--jq" ]]; then filter="$a"; fi
      prev="$a"
    done
    if [[ -n "$filter" ]]; then
      printf '%s' "$runs" | jq -r "$filter" 2>/dev/null || echo ""
    else
      printf '%s' "$runs"
    fi
    exit 0 ;;
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
  next_port
  export API_URL="http://127.0.0.1:$PORT"
  python3 "$ROOT/scripts/fake-hermes.py" "$PORT" "$1" &
  FAKE_PID=$!
  FAKE_PIDS+=("$FAKE_PID")
  sleep 1
  if ! kill -0 "$FAKE_PID" 2>/dev/null; then
    echo "  FAIL  the fake Hermes on port $PORT did not start"
    FAIL=$((FAIL + 1))
    return 1
  fi
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
  if [[ "${HERMES_HARNESS_DEBUG:-}" == "1" ]]; then echo "--- $id log:"; sed 's/^/    /' "$TMP/log.$id" | head -12; fi
  [[ "$got" == "$want" ]] && check "$id -> skip=$want" yes || check "$id -> skip='$got' (want '$want')" no
}

marker() { printf '%s' "$1" > "$TMP/marker.json"; export FAKE_MARKER_FILE="$TMP/marker.json"; }

# The environment the steps read.
export API_URL="http://127.0.0.1:$PORT" API_KEY="test-key" GH_TOKEN="test-token"
# start_fake rewrites API_URL for the fake it starts; the steps read it from
# the environment, so it is re-exported here.
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
# Another bot's review on the head is not a Hermes review: no skip, no delta base.
export FAKE_OTHER_BOT_REVIEWED="head111"
run_step scope false
grep -q '^base=$' "$TMP/out.scope" && check "scope: another bot's review sets no delta base" yes || check "scope: another bot's review sets no delta base" no
# ...and it does not displace Hermes' own earlier review as the base.
export FAKE_LAST_REVIEWED="old999"
run_step scope false
grep -q '^base=old999$' "$TMP/out.scope" && check "scope: the base stays Hermes' own review" yes || check "scope: the base stays Hermes' own review" no
export FAKE_LAST_REVIEWED="" FAKE_OTHER_BOT_REVIEWED=""

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

echo "== a 409 whose run died is retried under a deeper key =="
export FAKE_MARKER_RUN="run_dead"
: > "$TMP/requests.log"
start_fake '{"run_statuses":{"run_dead":"failed"},"dispatch_codes":[409,202],"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.409" 2>&1
grep -q '"idempotency_key": "hermes-review:acme/widgets#42@..head111#run_dead"' "$TMP/requests.log" \
  && check "the retry goes under a deeper key, derived from the run that died" yes \
  || { check "the retry goes under a deeper key, derived from the run that died" no; \
       echo "        --- gh log:"; sed 's/^/        /' "$GH_LOG" | tail -8; \
       echo "        --- step log:"; sed 's/^/        /' "$TMP/log.409" | tail -8; \
       echo "        --- requests:"; sed 's/^/        /' "$TMP/requests.log" | cut -c1-120 | head -4; }
stop_fake

echo "== a stuck session is retried in a fresh one =="
export FAKE_MARKER_RUN="run_dead"
start_fake '{"run_statuses":{"run_dead":"failed"},"dispatch_codes":[409,202],"conflict_code":"admission_conflict","request_log":"'"$TMP"'/requests.log"}'
: > "$TMP/requests.log"
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.adm" 2>&1
grep -q '"session_id": "hermes-review-acme-widgets-42-2"' "$TMP/requests.log" \
  && check "a session that refused the turn is retried in a fresh one" yes \
  || { check "a session that refused the turn is retried in a fresh one" no; \
       echo "        --- step log:"; sed 's/^/        /' "$TMP/log.adm" | tail -8; \
       echo "        --- requests:"; sed 's/^/        /' "$TMP/requests.log" | cut -c1-140 | head -4; }
grep -q '"idempotency_key": "hermes-review:acme/widgets#42@..head111#session-2"' "$TMP/requests.log" \
  && check "the fresh session moves the idempotency key with it" yes \
  || check "the fresh session moves the idempotency key with it" no
stop_fake

echo "== a live run means no second dispatch =="
export FAKE_MARKER_RUN="run_live"
start_fake '{"run_statuses":{"run_live":"running"},"dispatch_codes":[409,202],"request_log":"'"$TMP"'/requests.log"}'
: > "$TMP/requests.log"
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.live" 2>&1
grep -q "already running" "$TMP/log.live" \
  && check "a live run is reported as already running" yes \
  || { check "a live run is reported as already running" no; \
       sed 's/^/        /' "$TMP/log.live" | tail -6; }
[[ $(grep -c '"method": "POST"' "$TMP/requests.log") -eq 1 ]] \
  && check "a live run is not dispatched a second time" yes \
  || check "a live run is not dispatched a second time" no
stop_fake
export FAKE_MARKER_RUN="run_dead"

echo "== every attempt refused is a failure, not a dispatch =="
start_fake '{"run_statuses":{"run_dead":"failed"},"dispatch_codes":[409,409,409],"conflict_code":"admission_conflict","request_log":"'"$TMP"'/requests.log"}'
: > "$TMP/requests.log"
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.exhausted" 2>&1; rc=$?
grep -q "NOT dispatched" "$TMP/log.exhausted" \
  && check "an exhausted dispatch loop says the review was NOT dispatched" yes \
  || { check "an exhausted dispatch loop says the review was NOT dispatched" no; \
       sed 's/^/        /' "$TMP/log.exhausted" | tail -6; }
[[ $rc -ne 0 ]] && check "an exhausted dispatch loop exits non-zero" yes \
  || check "an exhausted dispatch loop exits non-zero" no
stop_fake

echo "== the legacy path says a refusal is a refusal =="
export USE_RUNS="false"
start_fake '{"legacy_code":409,"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.legacy409" 2>&1; rc=$?
grep -q "NOT dispatched" "$TMP/log.legacy409" \
  && check "the legacy path says the review was NOT dispatched" yes \
  || { check "the legacy path says the review was NOT dispatched" no; \
       sed 's/^/        /' "$TMP/log.legacy409" | tail -6; }
[[ $rc -ne 0 ]] && check "the legacy path exits non-zero on HTTP 409" yes \
  || check "the legacy path exits non-zero on HTTP 409" no
stop_fake
export USE_RUNS="true"

echo "== follow-ups to the refusal handling =="
export BASE_SHA="old999" FAKE_MARKER_RUN="run_dead"

# (1) a fresh session must not be told that earlier rounds are in its history
: > "$TMP/requests.log"
start_fake '{"run_statuses":{"run_dead":"failed"},"dispatch_codes":[409,202],"conflict_code":"admission_conflict","run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.fresh" 2>&1
[[ $(grep -c "Earlier rounds are in the history of this session" "$TMP/requests.log") -eq 1 ]] \
  && check "the first attempt tells the reviewer earlier rounds are in its session" yes \
  || check "the first attempt tells the reviewer earlier rounds are in its session" no
[[ $(grep -c "This is a NEW session: earlier rounds are NOT in your history" "$TMP/requests.log") -eq 1 ]] \
  && check "the retry in a fresh session says it has no history" yes \
  || { check "the retry in a fresh session says it has no history" no; sed 's/^/        /' "$TMP/log.fresh" | tail -5; }
stop_fake

# (2) the session a round moved to is remembered by the next one
: > "$TMP/requests.log"; : > "$GH_LOG"
export FAKE_MARKER_SESSION="hermes-review-acme-widgets-42-2"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.remember" 2>&1
grep -q '"session_id": "hermes-review-acme-widgets-42-2"' "$TMP/requests.log" \
  && check "the next round starts in the session the previous round moved to" yes \
  || { check "the next round starts in the session the previous round moved to" no; sed 's/^/        /' "$TMP/requests.log" | cut -c1-200 | head -3; }
grep -q "output\[summary\]=session: hermes-review-acme-widgets-42-2" "$GH_LOG" \
  && check "the in-flight marker records the session it ran in" yes \
  || { check "the in-flight marker records the session it ran in" no; tail -3 "$GH_LOG"; }
stop_fake
export FAKE_MARKER_SESSION="evil/../x"
: > "$TMP/requests.log"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.remember" 2>&1
grep -q '"session_id": "hermes-review-acme-widgets-42"' "$TMP/requests.log" \
  && check "a remembered session id of the wrong shape is ignored" yes \
  || check "a remembered session id of the wrong shape is ignored" no
stop_fake
export FAKE_MARKER_SESSION="hermes-review-other-repo-9"
: > "$TMP/requests.log"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.remember" 2>&1
grep -q '"session_id": "hermes-review-acme-widgets-42"' "$TMP/requests.log" \
  && check "a remembered session of another pull request is ignored" yes \
  || check "a remembered session of another pull request is ignored" no
stop_fake
unset FAKE_MARKER_SESSION

# (3) a 409 nothing can explain is a failure, not a green "unknown"
export FAKE_MARKER_RUN=""
start_fake '{"dispatch_codes":[409],"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.nomarker" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q "NOT dispatched" "$TMP/log.nomarker" \
  && check "a 409 with no marker naming the run fails (not a green unknown)" yes \
  || check "a 409 with no marker naming the run fails (not a green unknown)" no
stop_fake
export FAKE_MARKER_RUN="unknown-run"
start_fake '{"dispatch_codes":[409],"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.nostatus" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q "NOT dispatched" "$TMP/log.nostatus" \
  && check "a 409 whose run status cannot be read fails" yes \
  || check "a 409 whose run status cannot be read fails" no
stop_fake

# (4) a completed run whose review already landed at this head is not redone
export FAKE_MARKER_RUN="run_done" FAKE_LAST_REVIEWED="head111"
: > "$TMP/requests.log"
start_fake '{"run_statuses":{"run_done":"completed"},"dispatch_codes":[409,202],"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.landed" 2>&1; rc=$?
[[ $rc -eq 0 && $(grep -c '"method": "POST"' "$TMP/requests.log") -eq 1 ]] && grep -q "already landed" "$TMP/log.landed" \
  && check "a completed run whose review landed at this head is not redispatched" yes \
  || { check "a completed run whose review landed at this head is not redispatched" no; sed 's/^/        /' "$TMP/log.landed" | tail -4; }
stop_fake
export FAKE_LAST_REVIEWED="old999"
: > "$TMP/requests.log"
start_fake '{"run_statuses":{"run_done":"completed"},"dispatch_codes":[409,202],"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.notlanded" 2>&1
[[ $(grep -c '"method": "POST"' "$TMP/requests.log") -eq 2 ]] \
  && check "a completed run with no review at this head is retried under a deeper key" yes \
  || check "a completed run with no review at this head is retried under a deeper key" no
stop_fake

# (5) response files do not outlive the step
export FAKE_LAST_REVIEWED="" FAKE_MARKER_RUN="run_dead"
mkdir -p "$TMP/rt"; export RUNNER_TEMP="$TMP/rt"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.tmpfiles" 2>&1
[[ -z "$(ls -A "$TMP/rt")" ]] && check "the step leaves no response files in RUNNER_TEMP" yes || { check "the step leaves no response files in RUNNER_TEMP" no; ls "$TMP/rt"; }
stop_fake
unset RUNNER_TEMP
export BASE_SHA=""

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
