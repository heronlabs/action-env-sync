#!/usr/bin/env bash
# Offline test harness for core/sync-branches.sh.
#
# Builds throwaway git repos (a bare "origin" + a working clone), points a `gh` stub
# at PATH, runs the action script, and asserts on pushed refs / RESULT lines / gh calls.
# No network, no real GitHub.
#
# shellcheck disable=SC2015  # `cond && ok || bad` is intentional; ok() always returns 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../core/sync-branches.sh"
STUB_DIR="$HERE"   # contains the `gh` stub

pass=0
fail=0
note() { printf '  %s\n' "$*"; }
ok()   { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && note "$2"; }

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# Build an origin with: main (advanced), staging (diverges cleanly), development (conflicts).
# Echoes the temp root; caller uses "$root/origin.git" and "$root/work".
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

# Run the action script inside a working clone. Sets GH stub on PATH and capture files.
# Usage: run_action <work> <targets> [extra env assignments...]
# Echoes nothing; exports RUN_OUT/RUN_RC/RUN_GHLOG/RUN_GHOUT for the caller.
run_action() {
  local work="$1" targets="$2"; shift 2
  RUN_GHLOG="$(mktemp)"
  RUN_GHOUT="$(mktemp)"
  local sum; sum="$(mktemp)"
  : >"$RUN_GHLOG"
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
}

contains_source() { # <origin> <branch>  -> true if origin/branch contains main
  local origin="$1" br="$2" tmp; tmp="$(mktemp -d)"
  git clone -q "$origin" "$tmp" >/dev/null 2>&1
  local r=1
  if git -C "$tmp" merge-base --is-ancestor origin/main "origin/$br" 2>/dev/null; then r=0; fi
  rm -rf "$tmp"
  return $r
}

is_merge_commit() { # <origin> <branch> -> true if tip has 2 parents
  local origin="$1" br="$2" tmp; tmp="$(mktemp -d)"
  git clone -q "$origin" "$tmp" >/dev/null 2>&1
  local parents; parents="$(git -C "$tmp" rev-list --parents -n1 "origin/$br" 2>/dev/null | wc -w)"
  rm -rf "$tmp"
  [ "$parents" -eq 3 ]   # sha + 2 parents
}

# ---------------------------------------------------------------- tests

test_mixed_run() {
  local root; root="$(build_repo)"
  local origin="$root/origin.git" work="$root/work"
  run_action "$work" $'staging\ndevelopment\nmissing\nmain'

  [ "$RUN_RC" -eq 0 ] && ok "mixed: exit 0 (green)" || bad "mixed: exit 0 (green)" "rc=$RUN_RC out=$RUN_OUT"

  grep -q 'result: staging synced' <<<"$RUN_OUT" && ok "mixed: staging reported synced" || bad "mixed: staging reported synced" "$RUN_OUT"
  contains_source "$origin" staging && ok "mixed: origin/staging contains main" || bad "mixed: origin/staging contains main"
  is_merge_commit "$origin" staging && ok "mixed: staging tip is a merge commit" || bad "mixed: staging tip is a merge commit"

  grep -q 'result: development conflict' <<<"$RUN_OUT" && ok "mixed: development reported conflict" || bad "mixed: development reported conflict" "$RUN_OUT"
  ! contains_source "$origin" development && ok "mixed: origin/development NOT advanced" || bad "mixed: origin/development NOT advanced"
  grep -Eq 'gh pr create.*--base development.*--head main|gh pr create.*--head main.*--base development' "$RUN_GHLOG" && ok "mixed: pr create for development" || bad "mixed: pr create for development" "$(cat "$RUN_GHLOG")"

  grep -q 'result: missing skipped' <<<"$RUN_OUT" && ok "mixed: missing target skipped" || bad "mixed: missing target skipped" "$RUN_OUT"
  grep -q 'result: main ' <<<"$RUN_OUT" && bad "mixed: source==target should be silently skipped" "$RUN_OUT" || ok "mixed: source==target not processed"

  rm -rf "$root"
}

test_already_synced_noop() {
  local root; root="$(build_repo)"
  local origin="$root/origin.git" work="$root/work"
  # First sync staging cleanly.
  run_action "$work" 'staging'
  # Re-fetch into work then run again: staging now already contains main -> no-op.
  git_q "$work" fetch origin
  run_action "$work" 'staging'
  grep -q 'result: staging already' <<<"$RUN_OUT" && ok "already-synced: reported already" || bad "already-synced: reported already" "$RUN_OUT"
  grep -q 'gh pr create' "$RUN_GHLOG" && bad "already-synced: no PR created" "$(cat "$RUN_GHLOG")" || ok "already-synced: no PR created"
  [ "$RUN_RC" -eq 0 ] && ok "already-synced: green" || bad "already-synced: green" "rc=$RUN_RC"
  rm -rf "$root"
}

test_reuse_existing_pr() {
  local root; root="$(build_repo)"
  local work="$root/work"
  # development conflicts; simulate an already-open PR via stub.
  run_action "$work" 'development' GH_STUB_PRLIST_OUT='https://github.com/o/r/pull/42'
  grep -q 'gh pr create' "$RUN_GHLOG" && bad "reuse: must NOT create a duplicate PR" "$(cat "$RUN_GHLOG")" || ok "reuse: no duplicate pr create"
  grep -q 'result: development conflict' <<<"$RUN_OUT" && ok "reuse: development still conflict" || bad "reuse: development still conflict" "$RUN_OUT"
  grep -q 'pull/42' "$RUN_GHOUT" && ok "reuse: existing PR url in outputs" || bad "reuse: existing PR url in outputs" "$(cat "$RUN_GHOUT")"
  rm -rf "$root"
}

test_supersede_closes_pr() {
  local root; root="$(build_repo)"
  local work="$root/work"
  # staging merges cleanly; simulate a stale open PR (number) -> must be closed.
  run_action "$work" 'staging' GH_STUB_PRLIST_OUT='7'
  grep -q 'gh pr close 7' "$RUN_GHLOG" && ok "supersede: stale PR closed" || bad "supersede: stale PR closed" "$(cat "$RUN_GHLOG")"
  grep -q 'result: staging synced' <<<"$RUN_OUT" && ok "supersede: staging synced" || bad "supersede: staging synced" "$RUN_OUT"
  rm -rf "$root"
}

test_push_rejected_falls_back_to_pr() {
  local root; root="$(build_repo)"
  local origin="$root/origin.git" work="$root/work"
  # Reject any push to staging (simulates branch protection blocking the token).
  cat >"$origin/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
  [ "$ref" = "refs/heads/staging" ] && { echo "protected: staging" >&2; exit 1; }
done
exit 0
HOOK
  chmod +x "$origin/hooks/pre-receive"

  run_action "$work" 'staging'
  ! contains_source "$origin" staging && ok "push-reject: origin/staging NOT advanced" || bad "push-reject: origin/staging NOT advanced"
  grep -Eq 'gh pr create.*--base staging.*--head main|gh pr create.*--head main.*--base staging' "$RUN_GHLOG" && ok "push-reject: fell back to PR" || bad "push-reject: fell back to PR" "$(cat "$RUN_GHLOG")"
  grep -q 'result: staging conflict' <<<"$RUN_OUT" && ok "push-reject: reported as conflict (PR path)" || bad "push-reject: reported as conflict (PR path)" "$RUN_OUT"
  [ "$RUN_RC" -eq 0 ] && ok "push-reject: green" || bad "push-reject: green" "rc=$RUN_RC out=$RUN_OUT"
  rm -rf "$root"
}

test_missing_source_hard_error() {
  local root; root="$(build_repo)"
  local work="$root/work"
  run_action "$work" 'staging' SOURCE_BRANCH=nope
  [ "$RUN_RC" -ne 0 ] && ok "bad source: hard error (non-zero)" || bad "bad source: hard error (non-zero)" "rc=$RUN_RC out=$RUN_OUT"
  rm -rf "$root"
}

test_empty_targets_hard_error() {
  local root; root="$(build_repo)"
  local work="$root/work"
  run_action "$work" ''
  [ "$RUN_RC" -ne 0 ] && ok "empty targets: hard error (non-zero)" || bad "empty targets: hard error (non-zero)" "rc=$RUN_RC"
  rm -rf "$root"
}

# ---------------------------------------------------------------- run

test_mixed_run
test_already_synced_noop
test_reuse_existing_pr
test_supersede_closes_pr
test_push_rejected_falls_back_to_pr
test_missing_source_hard_error
test_empty_targets_hard_error

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
