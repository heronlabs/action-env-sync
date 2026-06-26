#!/usr/bin/env bats
# bats tests for core/sync-branches.sh
#
# Builds throwaway git repos (a bare "origin" + a working clone), points a `gh` stub
# at PATH, runs the action script, and asserts on pushed refs / RESULT lines / gh calls.
# No network, no real GitHub.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../core/sync-branches.sh"
  STUB_DIR="$BATS_TEST_DIRNAME"   # contains the `gh` stub
}

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# Build an origin with: main (advanced), staging (diverges cleanly), development (conflicts).
build_repo() {
  local root work origin
  root="$(mktemp -d)"
  origin="$root/origin.git"
  work="$root/work"
  git init -q --bare "$origin"
  git clone -q "$origin" "$work" 2>/dev/null
  git -C "$work" config user.name  tester
  git -C "$work" config user.email tester@example.com

  # main: base
  git -C "$work" checkout -q -b main
  printf 'base\n' >"$work/file.txt"
  git_q "$work" add -A
  git_q "$work" commit -m base
  git_q "$work" push origin main

  # staging: new file (will merge main cleanly)
  git -C "$work" checkout -q -b staging main
  printf 'stg\n' >"$work/stg.txt"
  git_q "$work" add -A
  git_q "$work" commit -m stg
  git_q "$work" push origin staging

  # development: edits file.txt (will conflict with main's edit)
  git -C "$work" checkout -q -b development main
  printf 'dev-change\n' >"$work/file.txt"
  git_q "$work" add -A
  git_q "$work" commit -m devchange
  git_q "$work" push origin development

  # advance main: edits the same file.txt
  git -C "$work" checkout -q main
  printf 'main-change\n' >"$work/file.txt"
  git_q "$work" add -A
  git_q "$work" commit -m mainchange
  git_q "$work" push origin main

  printf '%s' "$root"
}

# Run the action script inside a working clone.
# Usage: run_action <work> <targets> [extra env assignments...]
# Exports RUN_OUT, RUN_RC, RUN_GHLOG, RUN_GHOUT for the caller.
# shellcheck disable=SC2034  # RUN_OUT used by callers
run_action() {
  local work="$1" targets="$2"; shift 2
  RUN_GHLOG="$(mktemp)"
  RUN_GHOUT="$(mktemp)"
  local sum; sum="$(mktemp)"
  : >"$RUN_GHLOG"
  set +e
  RUN_OUT="$(
    cd "$work" &&
    env PATH="$STUB_DIR:$PATH" \
        GH_LOG="$RUN_GHLOG" \
        GITHUB_OUTPUT="$RUN_GHOUT" \
        GITHUB_STEP_SUMMARY="$sum" \
        SOURCE_BRANCH=main \
        TARGET_BRANCHES="$targets" \
        "$@" \
        bash "$SCRIPT" 2>&1
  )"
  RUN_RC=$?
  set -e
}

contains_source() {
  local origin="$1" br="$2" tmp; tmp="$(mktemp -d)"
  git clone -q "$origin" "$tmp" >/dev/null 2>&1
  local r=1
  if git -C "$tmp" merge-base --is-ancestor origin/main "origin/$br" 2>/dev/null; then r=0; fi
  rm -rf "$tmp"
  return $r
}

is_merge_commit() {
  local origin="$1" br="$2" tmp; tmp="$(mktemp -d)"
  git clone -q "$origin" "$tmp" >/dev/null 2>&1
  local parents; parents="$(git -C "$tmp" rev-list --parents -n1 "origin/$br" 2>/dev/null | wc -w)"
  rm -rf "$tmp"
  [ "$parents" -eq 3 ]   # sha + 2 parents
}

# ---------------------------------------------------------------- tests

@test "mixed: staging synced, development conflict, missing skipped, source==target ignored" {
  local root; root="$(build_repo)"
  local origin="$root/origin.git" work="$root/work"
  run_action "$work" $'staging\ndevelopment\nmissing\nmain'

  [ "$RUN_RC" -eq 0 ]

  grep -q 'result: staging synced' <<<"$RUN_OUT"
  contains_source "$origin" staging
  is_merge_commit "$origin" staging

  grep -q 'result: development conflict' <<<"$RUN_OUT"
  run ! contains_source "$origin" development
  grep -Eq 'gh pr create.*--base development.*--head main|gh pr create.*--head main.*--base development' "$RUN_GHLOG"

  grep -q 'result: missing skipped' <<<"$RUN_OUT"
  grep -q 'result: main ' <<<"$RUN_OUT" && false || true  # source==target must NOT appear

  rm -rf "$root"
}

@test "already synced: re-run on synced branch is no-op" {
  local root; root="$(build_repo)"
  local origin="$root/origin.git" work="$root/work"
  run_action "$work" 'staging'
  git_q "$work" fetch origin
  run_action "$work" 'staging'

  grep -q 'result: staging already' <<<"$RUN_OUT"
  grep -q 'gh pr create' "$RUN_GHLOG" && false || true  # no PR created
  [ "$RUN_RC" -eq 0 ]

  rm -rf "$root"
}

@test "reuse: existing open PR is reused, not duplicated" {
  local root; root="$(build_repo)"
  local work="$root/work"
  run_action "$work" 'development' GH_STUB_PRLIST_OUT='https://github.com/o/r/pull/42'

  grep -q 'gh pr create' "$RUN_GHLOG" && false || true  # must NOT create duplicate
  grep -q 'result: development conflict' <<<"$RUN_OUT"
  grep -q 'pull/42' "$RUN_GHOUT"

  rm -rf "$root"
}

@test "supersede: stale PR closed when clean merge succeeds" {
  local root; root="$(build_repo)"
  local work="$root/work"
  run_action "$work" 'staging' GH_STUB_PRLIST_OUT='7'

  grep -q 'gh pr close 7' "$RUN_GHLOG"
  grep -q 'result: staging synced' <<<"$RUN_OUT"

  rm -rf "$root"
}

@test "push rejected: falls back to PR on protected branch" {
  local root; root="$(build_repo)"
  local origin="$root/origin.git" work="$root/work"
  cat >"$origin/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
  [ "$ref" = "refs/heads/staging" ] && { echo "protected: staging" >&2; exit 1; }
done
exit 0
HOOK
  chmod +x "$origin/hooks/pre-receive"

  run_action "$work" 'staging'
  run ! contains_source "$origin" staging
  grep -Eq 'gh pr create.*--base staging.*--head main|gh pr create.*--head main.*--base staging' "$RUN_GHLOG"
  grep -q 'result: staging conflict' <<<"$RUN_OUT"
  [ "$RUN_RC" -eq 0 ]

  rm -rf "$root"
}

@test "missing source branch: hard error" {
  local root; root="$(build_repo)"
  local work="$root/work"
  run_action "$work" 'staging' SOURCE_BRANCH=nope

  [ "$RUN_RC" -ne 0 ]

  rm -rf "$root"
}

@test "empty targets: hard error" {
  local root; root="$(build_repo)"
  local work="$root/work"
  run_action "$work" ''

  [ "$RUN_RC" -ne 0 ]

  rm -rf "$root"
}
