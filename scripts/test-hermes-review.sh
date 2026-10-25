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
# Needs PyYAML in the `python3` first on PATH (it extracts the steps from the YAML); a
# venv python without it fails every section with `No module named 'yaml'`.
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
  *"/reactions"*)
    # The 👀 reaction. Records WHICH token made the call and where it went.
    log "reaction to=${args[*]} token=${GH_TOKEN:-}"
    [[ "${FAKE_REACTION_FAIL:-}" == "1" ]] && exit 1
    exit 0 ;;
  *"/pulls/"*".head.sha"*)  log "head ${FAKE_HEAD:-head111}"; echo "${FAKE_HEAD:-head111}"; exit 0 ;;
  *"/pulls/"*"reviews"*)
    # A real review list, run through the workflow's own --jq filter, so the
    # filter is exercised here and not only in a consumer run.
    log "reviews"
    if [[ -n "${FAKE_REVIEWS_FAIL:-}" ]]; then echo "gh: HTTP 403: Resource not accessible by integration" >&2; exit 1; fi
    # Hermes' own review at FAKE_LAST_REVIEWED, plus (optionally) another bot's review
    # at FAKE_OTHER_BOT_REVIEWED, which must never count (s3ntin3l8/.github#99).
    # FAKE_LAST_REVIEWED is the commit_id the review REPORTS now (GitHub re-points an
    # approval's at the head when the branch is rewritten, #129); FAKE_REVIEW_AT is when
    # it was submitted.
    reviews='[{"user":{"type":"Bot","login":"s3ntin3l8-hermes[bot]"},"state":"APPROVED","commit_id":"'"${FAKE_LAST_REVIEWED:-}"'","submitted_at":"'"${FAKE_REVIEW_AT:-2026-01-02T00:00:00Z}"'"}'
    # A second, later Hermes review (a run whose marker was never written, #133).
    if [[ -n "${FAKE_REVIEW2_AT:-}" ]]; then
      reviews+=',{"user":{"type":"Bot","login":"s3ntin3l8-hermes[bot]"},"state":"COMMENTED","commit_id":"","submitted_at":"'"${FAKE_REVIEW2_AT}"'"}'
    fi
    if [[ -n "${FAKE_OTHER_BOT_REVIEWED:-}" ]]; then
      reviews+=',{"user":{"type":"Bot","login":"claude[bot]"},"state":"COMMENTED","commit_id":"'"${FAKE_OTHER_BOT_REVIEWED}"'","submitted_at":"2026-01-02T00:00:00Z"}'
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
    # A raw GraphQL payload, like the real API: the step's own --jq does the
    # picking, so the selection logic is what the tests exercise.
    filter=""
    prev=""
    for a in "${args[@]}"; do
      if [[ "$prev" == "--jq" ]]; then filter="$a"; fi
      prev=$a
    done
    [[ -f "${FAKE_MARKER_FILE:-/nonexistent}" ]] || { echo ""; exit 0; }
    jq -r "$filter" < "$FAKE_MARKER_FILE" 2>/dev/null || echo ""
    exit 0 ;;
  *"--method POST"*"check-runs"*) log "check-run created ${args[*]}"; echo "${FAKE_CHECK_RUN_ID:-4242}"; exit 0 ;;
  *"--method PATCH"*"check-runs"*) log "check-run patched ${args[*]}"; exit 0 ;;
  *"/check-runs"*)
    # The check runs already on a commit — the in-flight marker. The step
    # applies its own --jq filter to this, so the fake does too.
    # (This case must come AFTER the POST and PATCH cases: they match the
    # same path, and a marker listing would answer them with the wrong shape.)
    log "check-runs"
    # A marker that only appears after FAKE_MARKER_AFTER listings: the other entry
    # point dispatched a moment ago and has not written it yet.
    if [[ -n "${FAKE_MARKER_AFTER:-}" ]]; then
      n=$(( $(cat "${FAKE_MARKER_COUNTER:-/nonexistent}" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "${FAKE_MARKER_COUNTER:-/dev/null}"
      if (( n <= FAKE_MARKER_AFTER )); then echo ""; exit 0; fi
    fi
    # A second marker on the same commit, so a test can check which one wins:
    # the endpoint answers newest first, so the NEWEST marker is the one the
    # next round has to continue in.
    second=''
    if [[ -n "${FAKE_MARKER2_SESSION:-}" ]]; then
      second=',{"id":'"${FAKE_MARKER2_ID:-800}"',"name":"'"${LEDGER_NAME:-Hermes review}"'","external_id":"'"${FAKE_MARKER2_RUN-run_old}"'","output":{"summary":"session: '"$FAKE_MARKER2_SESSION"'"}}'
    fi
    runs='{"total_count":2,"check_runs":[{"id":'"${FAKE_MARKER_ID:-900}"',"name":"'"${LEDGER_NAME:-Hermes review}"'","external_id":"'"${FAKE_MARKER_RUN-run_dead}"'","started_at":"'"${FAKE_MARKER_STARTED:-2026-01-01T00:00:00Z}"'","output":{"summary":"'"${FAKE_MARKER_SESSION:+session: $FAKE_MARKER_SESSION}"'"}}'"$second"']}'
    filter=""
    prev=""
    for a in "${args[@]}"; do
      if [[ "$prev" == "--jq" ]]; then filter="$a"; fi
      prev="$a"
    done
    payload="$runs"
    if [[ -n "$filter" ]]; then
      printf '%s' "$payload" | jq -r "$filter" 2>/dev/null || echo ""
    else
      printf '%s' "$payload"
    fi
    exit 0 ;;
  *"/commits/"*)
    # A commit: its tree and its committer date. FAKE_TREES / FAKE_COMMIT_DATES are
    # space-separated "sha=value" lists; anything unlisted gets "tree-<sha>" and a date
    # before the default review time. FAKE_COMMIT_MISSING makes the commit unreadable.
    sha=""
    for a in "${args[@]}"; do [[ "$a" == repos/*/commits/* ]] && sha=${a##*/}; done
    log "commit $sha"
    for m in ${FAKE_COMMIT_MISSING:-}; do [[ "$m" == "$sha" ]] && exit 1; done
    tree="tree-$sha"; date="2026-01-01T00:00:00Z"
    for kv in ${FAKE_TREES:-}; do [[ "${kv%%=*}" == "$sha" ]] && tree=${kv#*=}; done
    for kv in ${FAKE_COMMIT_DATES:-}; do [[ "${kv%%=*}" == "$sha" ]] && date=${kv#*=}; done
    commit='{"commit":{"tree":{"sha":"'"$tree"'"},"committer":{"date":"'"$date"'"}}}'
    filter=""; prev=""
    for a in "${args[@]}"; do [[ "$prev" == "--jq" ]] && filter="$a"; prev="$a"; done
    if [[ -n "$filter" ]]; then printf '%s' "$commit" | jq -r "$filter" 2>/dev/null || echo ""; else printf '%s' "$commit"; fi
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

# marker [commit ...]: the PR's commits OLDEST first, as GitHub answers them. A commit is
# "oid:run:id[:state][+run:id[:state]...]" (one marker per run:id), or a bare "oid" for none. No argument =
# no commit carries a marker.
marker() {
  local c oid rest m nodes=""
  for c in "$@"; do
    oid=${c%%:*}; rest=""; [[ "$c" == *:* ]] && rest=${c#*:}
    local runs=""
    if [[ -n "$rest" ]]; then
      IFS=+ read -ra ms <<< "$rest"
      for m in "${ms[@]}"; do
        # "run:id" or "run:id:state" (state = IN_PROGRESS|COMPLETED; default IN_PROGRESS),
        # optionally "state/CONCLUSION" (default SUCCESS once COMPLETED) and a trailing
        # "@<start>[><end>]" for when the run started (default 2026-01-01T00:00:00Z) and
        # was closed (default 2099: far enough that any review falls inside the window).
        local mrun=${m%%:*} mrest=${m#*:} mid mstate=IN_PROGRESS mconc=null mat=2026-01-01T00:00:00Z mend=2099-01-01T00:00:00Z
        if [[ "$mrest" == *@* ]]; then mat=${mrest#*@}; mrest=${mrest%%@*}; fi
        if [[ "$mat" == *">"* ]]; then mend=${mat#*>}; mat=${mat%%>*}; fi
        mid=${mrest%%:*}; [[ "$mrest" == *:* ]] && mstate=${mrest#*:}
        if [[ "$mstate" == */* ]]; then mconc='"'${mstate#*/}'"'; mstate=${mstate%%/*}
        elif [[ "$mstate" == COMPLETED ]]; then mconc='"SUCCESS"'; fi
        runs+="${runs:+,}"'{"databaseId":'"$mid"',"name":"Hermes review","externalId":"'"$mrun"'","status":"'"$mstate"'","conclusion":'"$mconc"',"startedAt":"'"$mat"'","completedAt":'"$([[ "$mconc" == null ]] && echo null || echo "\"$mend\"")"'}'
      done
    fi
    nodes+="${nodes:+,}"'{"commit":{"oid":"'"$oid"'","checkSuites":{"nodes":[{"checkRuns":{"nodes":['"$runs"']}}]}}}'
  done
  printf '%s' '{"data":{"repository":{"pullRequest":{"commits":{"nodes":['"$nodes"']}}}}}' > "$TMP/marker.json"
  export FAKE_MARKER_FILE="$TMP/marker.json"
}

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
export HERMES_MARKER_WAIT_INTERVAL=0   # the marker wait must not sleep in tests
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

echo "== the review scope: the reviewed commit comes from the ledger (#129) =="
# The #129 shape: the approval was submitted against old999, a merge commit has since been
# pushed, and GitHub re-pointed the review's commit_id at the new head. Only the ledger
# still knows what was reviewed.
export FAKE_HEAD="head111" FAKE_LAST_REVIEWED="head111" FAKE_REVIEW_AT="2026-01-02T00:00:00Z"
export FAKE_COMMIT_DATES="head111=2026-01-03T00:00:00Z"
marker "old999:run_a:10:COMPLETED@2026-01-01T12:00:00Z" "head111"
run_step scope false
grep -q '^base=old999$' "$TMP/out.scope" && check "scope: a re-pointed commit_id does not skip; the base is the ledger's commit" yes || check "scope: a re-pointed commit_id does not skip; the base is the ledger's commit" no
# Same content under a new SHA (a rebase or a recreated branch): nothing new to review.
export FAKE_TREES="old999=treeX head111=treeX"
run_step scope true
unset FAKE_TREES
# A marker whose run was stopped or failed reviewed nothing.
marker "old999:run_a:10:COMPLETED/CANCELLED@2026-01-01T12:00:00Z" "head111"
run_step scope false
grep -q '^base=$' "$TMP/out.scope" && check "scope: a cancelled marker is not a reviewed commit" yes || check "scope: a cancelled marker is not a reviewed commit" no
# A run that completed but posted no review (none submitted after it started) did not
# review anything either, so the older paired marker wins.
marker "old999:run_a:10:COMPLETED@2026-01-01T12:00:00Z" "mid555:run_b:20:COMPLETED@2026-01-05T00:00:00Z" "head111"
run_step scope false
grep -q '^base=old999$' "$TMP/out.scope" && check "scope: an unpaired success marker falls back to the older paired one" yes || check "scope: an unpaired success marker falls back to the older paired one" no
# A review that predates the marker was not that run's review (a dismissed one is gone from
# the landed list altogether), so the marker pairs with nothing and nothing is skipped.
marker "head111:run_a:10:COMPLETED@2026-01-01T12:00:00Z"
export FAKE_REVIEW_AT="2025-12-01T00:00:00Z" FAKE_LAST_REVIEWED=""
run_step scope false
grep -q '^base=$' "$TMP/out.scope" && check "scope: a review that predates the marker does not pair with it" yes || check "scope: a review that predates the marker does not pair with it" no
# No ledger at all and a commit_id newer than the review: it was re-pointed, so the whole
# diff is reviewed rather than trusting it.
rm -f "$TMP/marker.json"; unset FAKE_MARKER_FILE
export FAKE_LAST_REVIEWED="head111" FAKE_REVIEW_AT="2026-01-02T00:00:00Z" FAKE_COMMIT_DATES="head111=2026-01-03T00:00:00Z"
run_step scope false
grep -q '^base=$' "$TMP/out.scope" && check "scope: a commit_id newer than its review is not trusted without a ledger" yes || check "scope: a commit_id newer than its review is not trusted without a ledger" no
# ...and an unreadable commit is not trusted either.
export FAKE_COMMIT_DATES="" FAKE_COMMIT_MISSING="head111" FAKE_LAST_REVIEWED="old999"
run_step scope false
grep -q '^base=$' "$TMP/out.scope" && check "scope: an unreadable commit_id is not trusted without a ledger" yes || check "scope: an unreadable commit_id is not trusted without a ledger" no
unset FAKE_COMMIT_MISSING FAKE_REVIEW_AT FAKE_COMMIT_DATES
export FAKE_LAST_REVIEWED="" FAKE_OTHER_BOT_REVIEWED=""

echo "== the review scope: a marker is paired with its own run's review (#133) =="
# Run A (10:00-10:30) posted the review at 10:20. Run B (11:00-11:30) posted nothing.
# A later review at 13:00 comes from a run whose marker was never written. A lower bound
# alone paired that review with B, and the base became B: too new, code skipped.
export FAKE_HEAD="head111" FAKE_LAST_REVIEWED="" FAKE_REVIEW_AT="2026-01-01T10:20:00Z" FAKE_REVIEW2_AT="2026-01-01T13:00:00Z"
export FAKE_COMMIT_DATES="head111=2026-01-03T00:00:00Z"
marker "old999:run_a:10:COMPLETED@2026-01-01T10:00:00Z>2026-01-01T10:30:00Z" "mid555:run_b:20:COMPLETED@2026-01-01T11:00:00Z>2026-01-01T11:30:00Z" "head111"
run_step scope false
grep -q '^base=old999$' "$TMP/out.scope" && check "scope: a later review from another run does not pair an older silent marker" yes || check "scope: a later review from another run does not pair an older silent marker" no
# Clock skew: a review a few seconds after the marker was closed is still the run's.
unset FAKE_REVIEW2_AT
export FAKE_REVIEW_AT="2026-01-01T10:30:30Z"
run_step scope false
grep -q '^base=old999$' "$TMP/out.scope" && check "scope: 30 s of clock skew after the close still pairs" yes || check "scope: 30 s of clock skew after the close still pairs" no
# ...but not minutes after it: that is another run's review, and the (re-pointed) commit_id is not trusted.
marker "old999:run_a:10:COMPLETED@2026-01-01T10:00:00Z>2026-01-01T10:30:00Z" "head111"
export FAKE_REVIEW_AT="2026-01-01T10:35:00Z"
run_step scope false
grep -q '^base=$' "$TMP/out.scope" && check "scope: a review minutes after the close is not the run's" yes || check "scope: a review minutes after the close is not the run's" no
unset FAKE_REVIEW_AT FAKE_COMMIT_DATES
export FAKE_LAST_REVIEWED=""

echo "== the in-flight marker =="
start_fake '{"run_status":"running","request_log":"'"$TMP"'/requests.log"}'
marker head111                         # a commit, but no marker on it
run_step inflight false
marker "head111:run_live:10"
run_step inflight true                 # the same head is already being reviewed
marker "old999:run_live:10"
run_step inflight false                # the head moved -> stop the stale run
grep -q "^stale_run=run_live" "$TMP/out.inflight" && check "the stale run is stopped" yes || check "the stale run is stopped" no
grep -q "check-run patched.*check-runs/10 .*conclusion=cancelled" "$GH_LOG" && check "the stopped run's marker is closed cancelled" yes || check "the stopped run's marker is closed cancelled" no
# Commits come OLDEST first and each round leaves a marker: the NEWEST one decides, not the
# first commit that has one. The old round's run is finished; the head's own is live.
marker "old999:run_done:10" "head111:run_live:20"
run_step inflight true
# ...and the reverse: the live run is on the older head, a finished one on the newer.
marker "old999:run_live:10" "mid555:run_done:20"
run_step inflight false
grep -q "^stale_run=$" "$TMP/out.inflight" && check "inflight: the newest marker (finished) wins over an older live one" yes || check "inflight: the newest marker (finished) wins over an older live one" no
marker "old999:run_done:10" "mid555:run_live:20"
run_step inflight false
grep -q "^stale_run=run_live" "$TMP/out.inflight" && check "inflight: the newest marker (live, older head) is the one stopped" yes || check "inflight: the newest marker (live, older head) is the one stopped" no
# Several markers on ONE commit: the highest id, whatever the position.
marker "head111:run_done:30+run_live:40"
run_step inflight true
marker "head111:run_live:40+run_done:30"
run_step inflight true
marker "old999:run_done:10"
stop_fake
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
run_step inflight false                # a finished run -> the marker is stale

echo "== a marker the poll window left open =="
# The review finished after the window ended: the next round closes the marker with the
# run's real outcome (and only an OPEN marker is touched).
: > "$GH_LOG"
marker "head111:run_done:50:IN_PROGRESS"
run_step inflight false
grep -q "check-run patched.*check-runs/50 .*conclusion=success" "$GH_LOG" \
  && check "inflight: a left-open marker of a completed run is closed success" yes \
  || check "inflight: a left-open marker of a completed run is closed success" no
: > "$GH_LOG"
marker "head111:run_done:50:COMPLETED"
run_step inflight false
grep -q "check-run patched" "$GH_LOG" \
  && check "inflight: an already-completed marker is not patched again" no \
  || check "inflight: an already-completed marker is not patched again" yes
stop_fake
start_fake '{"run_status":"failed","request_log":"'"$TMP"'/requests.log"}'
: > "$GH_LOG"
marker "head111:run_dead:51:IN_PROGRESS"
run_step inflight false
grep -q "check-run patched.*check-runs/51 .*conclusion=failure" "$GH_LOG" \
  && check "inflight: a left-open marker of a failed run is closed failure" yes \
  || check "inflight: a left-open marker of a failed run is closed failure" no
stop_fake
start_fake '{"run_status":"unheard-of","request_log":"'"$TMP"'/requests.log"}'
: > "$GH_LOG"
marker "head111:run_odd:52:IN_PROGRESS"
run_step inflight false                # an unknown status is stale for dispatch...
grep -q "check-run patched" "$GH_LOG" \
  && check "inflight: an unknown status is not proof of an outcome - the marker stays open" no \
  || check "inflight: an unknown status is not proof of an outcome - the marker stays open" yes
stop_fake
# The dispatch section below runs against a fake whose runs have completed.
marker "old999:run_done:10"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'

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

echo "== a review still running when the poll window ends =="
start_fake '{"run_status":"running","request_log":"'"$TMP"'/requests.log"}'
: > "$GH_LOG"
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.expiry" 2>&1; rc=$?
[[ $rc -eq 0 ]] && check "expiry: the job does not claim the review failed (exit 0)" yes || check "expiry: the job does not claim the review failed (exit 0)" no
grep -q "NOT a verdict.*Hermes review" "$TMP/log.expiry" && check "expiry: the warning says the check is not a verdict" yes || check "expiry: the warning says the check is not a verdict" no
grep -q "check-run created" "$GH_LOG" && check "expiry: the marker was written" yes || check "expiry: the marker was written" no
grep -q "check-run patched" "$GH_LOG" \
  && check "expiry: the marker is NOT closed while the review still runs" no \
  || check "expiry: the marker is NOT closed while the review still runs" yes
stop_fake

echo "== a non-numeric poll window falls back to the default =="
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
HERMES_POLL_SECONDS=abc bash -c 'set -uo pipefail; . "$1"' _ "$TMP/run.sh" > "$TMP/log.nan" 2>&1; rc=$?
grep -q "not a number of seconds" "$TMP/log.nan" && [[ $rc -eq 0 ]] && check "a non-numeric HERMES_POLL_SECONDS falls back instead of crashing" yes || check "a non-numeric HERMES_POLL_SECONDS falls back instead of crashing" no
stop_fake

echo "== the poll window is clamped under the job timeout =="
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
HERMES_POLL_SECONDS=99999 bash -c 'set -uo pipefail; . "$1"' _ "$TMP/run.sh" > "$TMP/log.clamp" 2>&1
grep -q "clamped to 3000" "$TMP/log.clamp" && check "an oversized HERMES_POLL_SECONDS is clamped" yes || check "an oversized HERMES_POLL_SECONDS is clamped" no
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
# (2b) with two markers on the base commit, the NEWEST one wins
export FAKE_MARKER_SESSION="hermes-review-acme-widgets-42"
export FAKE_MARKER2_SESSION="hermes-review-acme-widgets-42-2"
# The ids decide, not the position: the OLDER marker comes first in the
# payload (the endpoint answers newest first, but the answer must not depend
# on that) and the NEWER one has the higher id.
export FAKE_MARKER_ID=800 FAKE_MARKER2_ID=950
: > "$TMP/requests.log"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.newest" 2>&1
grep -q '"session_id": "hermes-review-acme-widgets-42-2"' "$TMP/requests.log" \
  && check "the newest marker wins, not the oldest" yes \
  || { check "the newest marker wins, not the oldest" no; sed 's/^/        /' "$TMP/requests.log" | cut -c1-200 | head -3; }
stop_fake
unset FAKE_MARKER2_SESSION
export FAKE_MARKER_ID=900

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
# (3a) the other entry point's marker lands a moment AFTER the 409 (it is written after
# the dispatch): wait for it, then take the "already running" path instead of failing
export FAKE_MARKER_RUN="run_live" FAKE_MARKER_AFTER=2 FAKE_MARKER_COUNTER="$TMP/marker.count"; : > "$FAKE_MARKER_COUNTER"
: > "$TMP/requests.log"
start_fake '{"run_statuses":{"run_live":"running"},"dispatch_codes":[409],"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.latemarker" 2>&1; rc=$?
[[ $rc -eq 0 && $(grep -c '"method": "POST"' "$TMP/requests.log") -eq 1 ]] \
  && grep -qE "marker appeared after [0-9]+ check" "$TMP/log.latemarker" && grep -q "already running" "$TMP/log.latemarker" \
  && check "a 409 whose marker lands a moment later waits for it and exits green" yes \
  || { check "a 409 whose marker lands a moment later waits for it and exits green" no; sed 's/^/        /' "$TMP/log.latemarker" | tail -6; }
stop_fake
# the wait is for a key conflict only: an admission_conflict needs no marker and must not wait
: > "$FAKE_MARKER_COUNTER"; export FAKE_MARKER_AFTER=99
start_fake '{"run_statuses":{"run_dead":"failed"},"dispatch_codes":[409,202],"conflict_code":"admission_conflict","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.noadmwait" 2>&1
# one listing is the step's own lookup (the harness lists once before it); a wait would add up to 6 more
[[ $(cat "$FAKE_MARKER_COUNTER") -le 2 ]] \
  && check "an admission_conflict does not wait for a marker" yes \
  || check "an admission_conflict does not wait for a marker" no
stop_fake
unset FAKE_MARKER_AFTER FAKE_MARKER_COUNTER

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
# ...a review that predates the run is not that run's review (its commit_id is irrelevant:
# GitHub re-points an approval's at the head, #129)
export FAKE_LAST_REVIEWED="head111" FAKE_REVIEW_AT="2025-12-31T00:00:00Z"
: > "$TMP/requests.log"
start_fake '{"run_statuses":{"run_done":"completed"},"dispatch_codes":[409,202],"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.notlanded" 2>&1
[[ $(grep -c '"method": "POST"' "$TMP/requests.log") -eq 2 ]] \
  && check "a completed run whose review predates it is retried under a deeper key" yes \
  || check "a completed run whose review predates it is retried under a deeper key" no
stop_fake
unset FAKE_REVIEW_AT

# (4b) a completed run whose reviews cannot be read: unknown, so nothing is dispatched
# and the step does not report success (a failed read once counted as "a review landed")
export FAKE_LAST_REVIEWED="head111" FAKE_MARKER_RUN="run_done" FAKE_REVIEWS_FAIL=1
: > "$TMP/requests.log"
start_fake '{"run_statuses":{"run_done":"completed"},"dispatch_codes":[409,202],"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.reviewsfail" 2>&1; rc=$?
[[ $rc -ne 0 && $(grep -c '"method": "POST"' "$TMP/requests.log") -eq 1 ]] && grep -q "NOT dispatched" "$TMP/log.reviewsfail" && grep -q "HTTP 403" "$TMP/log.reviewsfail" && ! grep -q "already landed" "$TMP/log.reviewsfail" \
  && check "an unreadable reviews list is not read as a landed review, and the error says why" yes \
  || { check "an unreadable reviews list is not read as a landed review, and the error says why" no; sed 's/^/        /' "$TMP/log.reviewsfail" | tail -4; }
stop_fake
unset FAKE_REVIEWS_FAIL

# (5) response files do not outlive the step
export FAKE_LAST_REVIEWED="" FAKE_MARKER_RUN="run_dead"
mkdir -p "$TMP/rt"; export RUNNER_TEMP="$TMP/rt"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.tmpfiles" 2>&1
[[ -z "$(ls -A "$TMP/rt")" ]] && check "the step leaves no response files in RUNNER_TEMP" yes || { check "the step leaves no response files in RUNNER_TEMP" no; ls "$TMP/rt"; }
stop_fake
unset RUNNER_TEMP
export BASE_SHA=""
echo "== the 👀 reaction: only when a review was really dispatched =="
export EVENT_NAME="issue_comment" COMMENT_ID="777" ISSUE_NUMBER="42" REACTION_TOKEN="react-token"
reacted() { grep -c "^reaction" "$GH_LOG"; }

: > "$GH_LOG"; export FAKE_MARKER_RUN="run_dead"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1
grep -q "^reaction to=.*repos/acme/widgets/issues/comments/777/reactions.*content=eyes.* token=react-token" "$GH_LOG" \
  && check "a freshly dispatched review reacts 👀 to the comment, with the reaction token" yes \
  || { check "a freshly dispatched review reacts 👀 to the comment, with the reaction token" no; sed 's/^/        /' "$GH_LOG" | tail -4; }
stop_fake

: > "$GH_LOG"
start_fake '{"run_status":"completed","replayed":true,"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1
[[ $(reacted) -eq 0 ]] && check "a replay of an existing run does not react" yes || check "a replay of an existing run does not react" no
stop_fake

: > "$GH_LOG"; export FAKE_MARKER_RUN="run_live"
start_fake '{"run_statuses":{"run_live":"running"},"dispatch_codes":[409,202],"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1
[[ $(reacted) -eq 0 ]] && check "an already-running review (nothing dispatched) does not react" yes || check "an already-running review (nothing dispatched) does not react" no
stop_fake

: > "$GH_LOG"; export FAKE_MARKER_RUN="run_dead"
start_fake '{"dispatch_code":429,"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1
[[ $(reacted) -eq 0 ]] && check "a refused dispatch (429) does not react" yes || check "a refused dispatch (429) does not react" no
stop_fake

: > "$GH_LOG"
start_fake '{"run_statuses":{"run_dead":"failed"},"dispatch_codes":[409,409,409],"conflict_code":"admission_conflict","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1
[[ $(reacted) -eq 0 ]] && check "every attempt refused (409) does not react" yes || check "every attempt refused (409) does not react" no
stop_fake

: > "$GH_LOG"; unset REACTION_TOKEN
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1
[[ $(reacted) -eq 0 ]] && check "without a reaction token (opted out / not minted) nothing is posted" yes || check "without a reaction token (opted out / not minted) nothing is posted" no
stop_fake

: > "$GH_LOG"; export REACTION_TOKEN="react-token" FAKE_REACTION_FAIL=1
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1; rc=$?
[[ $rc -eq 0 ]] && check "a failing reaction never fails the review" yes || { check "a failing reaction never fails the review" no; sed 's/^/        /' "$TMP/log.eyes" | tail -4; }
grep -q "could not add the" "$TMP/log.eyes" && check "a failing reaction is reported as a warning" yes || check "a failing reaction is reported as a warning" no
stop_fake

: > "$GH_LOG"; export EVENT_NAME=pull_request PR_NUMBER=42 FAKE_MARKER_RUN="run_dead"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1
grep -q "^reaction to=.*repos/acme/widgets/issues/42/reactions.*content=eyes.* token=react-token" "$GH_LOG" \
  && check "an auto-review on PR open reacts 👀 to the PR body" yes \
  || { check "an auto-review on PR open reacts 👀 to the PR body" no; sed 's/^/        /' "$GH_LOG" | tail -4; }
stop_fake

: > "$GH_LOG"
start_fake '{"run_status":"completed","replayed":true,"request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.eyes" 2>&1
[[ $(reacted) -eq 0 ]] && check "a replayed auto-review does not react" yes || check "a replayed auto-review does not react" no
stop_fake
unset FAKE_REACTION_FAIL REACTION_TOKEN EVENT_NAME COMMENT_ID ISSUE_NUMBER PR_NUMBER

echo "== a follow-up round reviews the PR's own changes, not the base branch's (#130) =="
# The message the reviewer receives names the range AND says to leave out what is already
# on the base branch.
export FAKE_LAST_REVIEWED="" FAKE_MARKER_RUN="run_dead" BASE_SHA="old999"
: > "$TMP/requests.log"
start_fake '{"run_status":"completed","request_log":"'"$TMP"'/requests.log"}'
( set -uo pipefail; . "$TMP/run.sh" ) > "$TMP/log.followup" 2>&1
grep -q 'FOLLOW-UP round' "$TMP/requests.log" && grep -q 'EXCLUDING the commits already on the base branch' "$TMP/requests.log" \
  && check "the follow-up message tells the reviewer to leave out the base branch's commits" yes \
  || check "the follow-up message tells the reviewer to leave out the base branch's commits" no
stop_fake
export BASE_SHA=""
# The command the review prompt gives, run against a real history: a PR that took
# "Update branch" (main merged in) with three conflicts, finished the three ways a
# conflict is finished: typing new text, taking the PR's side (--ours) and taking main's
# (--theirs). A combined diff (--cc) only shows the first; the other two are exactly
# what silently drops the PR's change or reverts main's fix.
CMD=$(grep -m1 '^     git log -p' "$ROOT/hermes-review-prompt.md" | sed 's/^ *//')
G="$TMP/git-delta"; mkdir -p "$G"
(
  cd "$G" && git init -q -b main . && git config user.email t@t && git config user.name t
  for f in typed ours theirs; do printf 'l1\nl2\nl3\n' > "$f.txt"; done
  git add .; git commit -qm base
  git checkout -qb pr; echo pr1 > p1.txt; git add .; git commit -qm pr1
  git rev-parse HEAD > "$TMP/git-r"
  git checkout -q main; echo m1 > m1.txt; git add .; git commit -qm main1
  for f in typed ours theirs; do sed 's/l2/MAIN-l2/' "$f.txt" > "$f.tmp" && mv "$f.tmp" "$f.txt"; done; git commit -qam main2
  git checkout -q pr; for f in typed ours theirs; do sed 's/l2/PR-l2/' "$f.txt" > "$f.tmp" && mv "$f.tmp" "$f.txt"; done; git commit -qam pr2
  git merge main -m "Update branch" > /dev/null 2>&1
  git checkout --ours ours.txt > /dev/null 2>&1; git checkout --theirs theirs.txt > /dev/null 2>&1; printf 'l1\nhand-typed\nl3\n' > typed.txt
  git add .; git commit -qm "Update branch"
  echo pr3 > p3.txt; git add .; git commit -qm pr3
  git update-ref refs/remotes/origin/main main
  git rev-parse HEAD > "$TMP/git-head"
)
if [[ -n "$CMD" ]]; then
  # BASE_REF and HEAD_SHA are read by the eval'd command from the prompt.
  # shellcheck disable=SC2034
  OUT=$(cd "$G" && BASE_REF=main HEAD_SHA=$(cat "$TMP/git-head") && eval "${CMD//<base>/$(cat "$TMP/git-r")}" 2>&1)
else
  OUT=""
fi
MERGE=$(echo "$OUT" | sed -n '/^    Update branch/,/^    pr3/p')
echo "$OUT" | grep -q '^    pr2' && echo "$OUT" | grep -q '^    pr3' && [[ -n "$MERGE" ]] \
  && check "the prompt's follow-up command lists the PR's own commits since the last review" yes \
  || { check "the prompt's follow-up command lists the PR's own commits since the last review" no; echo "$OUT" | head -5 | sed 's/^/        /'; }
! echo "$OUT" | grep -qE '^    main[12]' \
  && check "the prompt's follow-up command leaves out the commits that came in from the base branch" yes \
  || check "the prompt's follow-up command leaves out the commits that came in from the base branch" no
for f in typed ours theirs; do
  echo "$MERGE" | grep -q "^+++ b/$f.txt" \
    && check "the prompt's follow-up command shows the merge's $f resolution" yes \
    || check "the prompt's follow-up command shows the merge's $f resolution" no
done
! echo "$MERGE" | grep -q 'm1.txt' \
  && check "the prompt's follow-up command does not show the files the merge brought in from the base branch" yes \
  || check "the prompt's follow-up command does not show the files the merge brought in from the base branch" no

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
