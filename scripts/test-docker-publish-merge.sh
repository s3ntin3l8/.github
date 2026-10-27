#!/usr/bin/env bash
# Exercises docker-publish.yml's merge job (tag creation, audit gate, signing, promotion)
# against a fake docker and a fake cosign.
#
# Like test-hermes-review.sh, it runs the workflow's own `run:` blocks, extracted from the
# YAML, with the network edges faked, because a reusable workflow cannot run standalone and
# publishing a real image to test the ORDER of steps is not a gate. What it pins down:
#   - no `audit-command`: tags are created first, then the digest is signed once;
#   - with it: the candidate is audited first, the audited digest is signed BEFORE any
#     release tag exists, and a failing audit publishes and signs nothing;
#   - the audit command gets the candidate reference as its last argument;
#   - signing retries only the transient OIDC token fault;
#   - promotion fails unless every tag resolves to the audited digest.
#
# Usage: scripts/test-docker-publish-merge.sh
# Needs PyYAML in the `python3` first on PATH (see test-hermes-review.sh) and jq.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/docker-publish.yml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# ── extract the merge job's run blocks, by step name ───────────────────────
mkdir -p "$TMP/steps" "$TMP/bin"
python3 - "$WORKFLOW" "$TMP/steps" <<'PY' || { echo "cannot extract the steps (is PyYAML on python3's path?)"; exit 1; }
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for i, step in enumerate(doc["jobs"]["merge"]["steps"]):
    if "run" in step:
        open(f"{sys.argv[2]}/{step['name']}.sh", "w").write(step["run"])
PY

# ── the fakes ──────────────────────────────────────────────────────────────
cat > "$TMP/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >> "$CALL_LOG"
case "$*" in
  "buildx imagetools create"*) exit 0 ;;
  "buildx imagetools inspect"*)
    ref=$4
    case "$ref" in
      *:audit-*) echo '"sha256:aaaa"' ;;
      *) echo "\"${FAKE_TAG_DIGEST:-sha256:aaaa}\"" ;;
    esac ;;
esac
DOCKER
cat > "$TMP/bin/cosign" <<'COSIGN'
#!/usr/bin/env bash
echo "cosign $*" >> "$CALL_LOG"
n=$(grep -c '^cosign ' "$CALL_LOG")
case "${FAKE_COSIGN:-ok}" in
  ok) exit 0 ;;
  transient-twice)
    if [ "$n" -le 2 ]; then
      echo "Error: signing [x]: retrieving ID token: reading ID token: fetching ambient OIDC credentials: invalid character 'u' looking for beginning of value" >&2
      exit 1
    fi
    exit 0 ;;
  transient-always)
    echo "Error: fetching ambient OIDC credentials: unexpected status code 503" >&2; exit 1 ;;
  permanent)
    echo "Error: signing [x]: getting signer: no ambient OIDC credentials: ACTIONS_ID_TOKEN_REQUEST_TOKEN missing" >&2; exit 1 ;;
esac
COSIGN
# Retries would otherwise sleep 10+20+30 s per case.
printf '#!/usr/bin/env bash\necho "sleep $*" >> "$CALL_LOG"\n' > "$TMP/bin/sleep"
# The audit command: records its arguments and fails on request.
cat > "$TMP/bin/fake-audit" <<'AUDIT'
#!/usr/bin/env bash
echo "audit argc=$# last=${!#} args=$*" >> "$CALL_LOG"
mkdir -p image-audit && echo ok > image-audit/report.json
[ "${FAKE_AUDIT_FAIL:-}" = "1" ] && exit 3
exit 0
AUDIT
chmod +x "$TMP"/bin/*

# ── helpers ────────────────────────────────────────────────────────────────
# run_flow <steps...>: run the named steps in order, stopping at the first failure like
# Actions does. Returns that step's exit code (0 when all passed).
run_flow() {
  local step rc=0
  for step in "$@"; do
    ( cd "$WORK" && bash -e "$TMP/steps/$step.sh" ) >> "$WORK/out.log" 2>&1
    rc=$?
    [ $rc -ne 0 ] && { echo "step failed: $step (exit $rc)" >> "$WORK/out.log"; return $rc; }
    # Mirror the step outputs the later steps read.
    if [ "$step" = "Assemble the candidate image" ]; then
      export CANDIDATE_DIGEST=$(sed -n 's/^digest=//p' "$GITHUB_OUTPUT")
      export IMAGE_REF=$(sed -n 's/^ref=//p' "$GITHUB_OUTPUT")
      export AUDITED_DIGEST=$CANDIDATE_DIGEST
    fi
  done
  return 0
}

new_case() {
  WORK=$(mktemp -d "$TMP/case.XXXXXX")
  export CALL_LOG="$WORK/calls.log" GITHUB_OUTPUT="$WORK/gh_output"
  : > "$CALL_LOG"; : > "$GITHUB_OUTPUT"; : > "$WORK/out.log"
  export PATH="$TMP/bin:$PATH"
  export REGISTRY=ghcr.io IMAGE_NAME=o/img IMAGE_SLUG=o-img VERSION=1.2.3
  export GITHUB_RUN_ID=77 GITHUB_RUN_ATTEMPT=2
  export DOCKER_METADATA_OUTPUT_JSON='{"tags":["ghcr.io/o/img:1.2.3","ghcr.io/o/img:latest"]}'
  mkdir -p "/tmp/digests/$IMAGE_SLUG"
  : > "/tmp/digests/$IMAGE_SLUG/1111"; : > "/tmp/digests/$IMAGE_SLUG/2222"
  unset FAKE_COSIGN FAKE_AUDIT_FAIL FAKE_TAG_DIGEST AUDIT_COMMAND
  # A skipped step's outputs expand to the empty string in Actions, not to "unset".
  export CANDIDATE_DIGEST= IMAGE_REF= AUDITED_DIGEST=
}
end_case() { rm -rf "/tmp/digests/$IMAGE_SLUG"; }

check() { # check <description> <condition-exit-code>
  if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1"; echo "       --- calls:"; sed 's/^/       /' "$CALL_LOG"; echo "       --- out:"; sed 's/^/       /' "$WORK/out.log"; fi
}
line_of() { grep -n -m1 -- "$1" "$CALL_LOG" | cut -d: -f1; }
count() { grep -c -- "$1" "$CALL_LOG" || true; }

PLAIN=("Create and push manifest list" "Sign the image digest")
AUDITED=("Assemble the candidate image" "Audit the candidate image" "Sign the image digest" "Promote exactly the audited image")

echo "a) no audit-command: tags first, then one signature on the digest"
new_case
run_flow "${PLAIN[@]}"; check "flow succeeds" $?
create=$(line_of 'imagetools create'); sign=$(line_of '^cosign sign')
[ -n "$create" ] && [ -n "$sign" ] && [ "$create" -lt "$sign" ]; check "tags are created before signing" $?
[ "$(count '^cosign sign')" = 1 ]; check "signed exactly once" $?
grep -q 'cosign sign --yes ghcr.io/o/img@sha256:aaaa' "$CALL_LOG"; check "signed the digest reference" $?
! grep -q 'audit-' "$CALL_LOG"; check "no candidate tag is created" $?
end_case

echo "b) audit-command: candidate audited, digest signed BEFORE the release tags exist"
new_case
export AUDIT_COMMAND="fake-audit --output image-audit 'two words'"
run_flow "${AUDITED[@]}"; check "flow succeeds" $?
cand=$(line_of 'create -t ghcr.io/o/img:audit-77-2'); aud=$(line_of '^audit '); sign=$(line_of '^cosign sign'); rel=$(line_of 'create -t ghcr.io/o/img:1.2.3')
[ -n "$cand" ] && [ -n "$aud" ] && [ -n "$sign" ] && [ -n "$rel" ] && [ "$cand" -lt "$aud" ] && [ "$aud" -lt "$sign" ] && [ "$sign" -lt "$rel" ]
check "order: candidate < audit < sign < release tags" $?
grep -q '^audit argc=4 last=ghcr.io/o/img@sha256:aaaa args=--output image-audit two words ghcr.io/o/img@sha256:aaaa$' "$CALL_LOG"
check "audit got its own quoted args, then the candidate reference last" $?
grep -q 'create -t ghcr.io/o/img:1.2.3 -t ghcr.io/o/img:latest ghcr.io/o/img@sha256:aaaa' "$CALL_LOG"
check "release tags are created from the audited digest" $?
[ "$(count '^cosign sign')" = 1 ]; check "signed exactly once" $?
end_case

echo "c) a failing audit publishes and signs nothing"
new_case
export AUDIT_COMMAND="fake-audit" FAKE_AUDIT_FAIL=1
run_flow "${AUDITED[@]}"; rc=$?
[ $rc -ne 0 ]; check "the flow fails" $?
[ "$(count '^cosign ')" = 0 ]; check "nothing is signed" $?
! grep -q 'create -t ghcr.io/o/img:1.2.3' "$CALL_LOG"; check "no release tag is created" $?
end_case

echo "d) a transient OIDC token fault is retried"
new_case
export FAKE_COSIGN=transient-twice
run_flow "Sign the image digest"; check "signing eventually succeeds" $?
[ "$(count '^cosign sign')" = 3 ]; check "three attempts" $?
[ "$(count '^sleep ')" = 2 ]; check "backed off between attempts" $?
end_case

echo "e) a permanent signing error fails at once"
new_case
export FAKE_COSIGN=permanent
run_flow "Sign the image digest"; rc=$?
[ $rc -ne 0 ]; check "signing fails" $?
[ "$(count '^cosign sign')" = 1 ]; check "one attempt, no retry" $?
end_case

echo "f) a persistent transient fault gives up after four attempts"
new_case
export FAKE_COSIGN=transient-always
run_flow "Sign the image digest"; rc=$?
[ $rc -ne 0 ]; check "signing fails" $?
[ "$(count '^cosign sign')" = 4 ]; check "four attempts" $?
end_case

echo "g) promotion fails when a tag does not resolve to the audited digest"
new_case
export AUDIT_COMMAND="fake-audit" FAKE_TAG_DIGEST=sha256:bbbb
run_flow "${AUDITED[@]}"; rc=$?
[ $rc -ne 0 ]; check "the flow fails" $?
grep -q 'resolves to sha256:bbbb, not the audited digest sha256:aaaa' "$WORK/out.log"; check "the error names both digests" $?
end_case

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
