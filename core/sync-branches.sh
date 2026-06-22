#!/usr/bin/env bash
#
# action-env-sync — fan a source branch out into target branches.
#
# For each target: if the merge of source is clean, push a 2-parent merge commit
# straight to the target; if it conflicts (or the push is rejected), open/update a
# resolution PR instead. Already-synced targets are a no-op. Conflicts keep the run
# green — the PR is the signal; only broken plumbing exits non-zero.
#
# Inputs (env, set by action.yml):
#   SOURCE_BRANCH    branch to sync FROM (required)
#   TARGET_BRANCHES  newline/comma list to sync TO (required, >=1 non-empty)
#   MERGE_MESSAGE    merge-commit subject template, {source}/{target} substituted
#                    (default: "Merge {source} into {target}")
#   GH_TOKEN         consumed by `gh` for PR operations
#   COMMITTER_NAME / COMMITTER_EMAIL   identity for the merge commit (optional)
#
# Conventions: writes `result: <target> <status>` lines to stdout (synced|conflict|
# skipped|already), GitHub outputs to $GITHUB_OUTPUT, and a table to $GITHUB_STEP_SUMMARY.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

# Identity for commit-tree (config may be unset on CI runners).
export GIT_AUTHOR_NAME="${COMMITTER_NAME:-github-actions[bot]}"
export GIT_AUTHOR_EMAIL="${COMMITTER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

source_branch="${SOURCE_BRANCH:-}"
[ -n "$source_branch" ] || die "SOURCE_BRANCH is required"
merge_tmpl="${MERGE_MESSAGE:-Merge {source} into {target}}"

# --- parse target list: split on newline/comma, trim, drop empties, dedupe ----
parse_targets() {
  local raw="${1//,/$'\n'}" item x seen
  local out=()
  while IFS= read -r item; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ -n "$item" ] || continue
    seen=0
    if [ "${#out[@]}" -gt 0 ]; then
      for x in "${out[@]}"; do [ "$x" = "$item" ] && { seen=1; break; }; done
    fi
    [ "$seen" -eq 0 ] && out+=("$item")
  done <<<"$raw"
  [ "${#out[@]}" -gt 0 ] && printf '%s\n' "${out[@]}"
}

targets=()
while IFS= read -r line; do
  [ -n "$line" ] && targets+=("$line")
done < <(parse_targets "${TARGET_BRANCHES:-}")
[ "${#targets[@]}" -gt 0 ] || die "TARGET_BRANCHES must list at least one branch"

git fetch --no-tags --quiet origin || die "git fetch failed (auth/network)"
git rev-parse --verify --quiet "origin/${source_branch}^{commit}" >/dev/null \
  || die "source branch 'origin/${source_branch}' not found — set fetch-depth: 0 in checkout"

synced=(); conflicts=(); skipped=(); pr_urls=(); errored=()

ref_oid() { git rev-parse --verify --quiet "origin/$1^{commit}" 2>/dev/null; }

# Open or reuse a resolution PR for source->target. Echoes the PR url.
open_or_reuse_pr() {
  local target="$1" url
  url="$(gh pr list --base "$target" --head "$source_branch" --state open \
          --json url --jq '.[0].url // empty' 2>/dev/null || true)"
  if [ -z "$url" ]; then
    local body
    # shellcheck disable=SC2016  # backticks/%s are printf format literals, intentional
    body=$(printf 'Automated environment sync.\n\nMerging `%s` into `%s` conflicts and needs manual resolution. Resolve the conflicts in this PR and merge.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' \
            "$source_branch" "$target")
    url="$(gh pr create --base "$target" --head "$source_branch" \
            --title "Sync ${source_branch} → ${target}" --body "$body" 2>/dev/null || true)"
  fi
  printf '%s' "$url"
}

for target in "${targets[@]}"; do
  [ "$target" = "$source_branch" ] && continue

  if [ -z "$(ref_oid "$target")" ]; then
    echo "result: $target skipped"; skipped+=("$target"); continue
  fi

  # Already contains source? no-op.
  if git merge-base --is-ancestor "origin/${source_branch}" "origin/${target}" 2>/dev/null; then
    echo "result: $target already"; continue
  fi

  # Side-effect-free merge probe.
  tree="$(git merge-tree --write-tree "origin/${target}" "origin/${source_branch}" 2>/dev/null)" \
    && mt_rc=0 || mt_rc=$?

  if [ "$mt_rc" -ne 0 ]; then
    # Conflict -> PR path.
    url="$(open_or_reuse_pr "$target")"
    echo "result: $target conflict"; conflicts+=("$target")
    [ -n "$url" ] && pr_urls+=("$url")
    continue
  fi

  # Clean -> build merge commit and push.
  tree_oid="$(printf '%s\n' "$tree" | head -n1)"
  msg="${merge_tmpl//\{source\}/$source_branch}"; msg="${msg//\{target\}/$target}"
  commit="$(git commit-tree "$tree_oid" -p "origin/${target}" -p "origin/${source_branch}" -m "$msg")"

  push_ok=0
  if git push --quiet origin "${commit}:refs/heads/${target}" 2>/dev/null; then
    push_ok=1
  else
    # Race or transient: re-fetch and retry once.
    git fetch --no-tags --quiet origin || true
    if git merge-base --is-ancestor "origin/${source_branch}" "origin/${target}" 2>/dev/null; then
      echo "result: $target already"; continue
    fi
    git push --quiet origin "${commit}:refs/heads/${target}" 2>/dev/null && push_ok=1 || push_ok=0
  fi

  if [ "$push_ok" -eq 1 ]; then
    echo "result: $target synced"; synced+=("$target")
    # Close any stale resolution PR now superseded by the direct sync.
    num="$(gh pr list --base "$target" --head "$source_branch" --state open \
            --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    [ -n "$num" ] && gh pr close "$num" \
      --comment "Superseded by direct sync of ${source_branch} into ${target}." >/dev/null 2>&1 || true
  else
    # Push refused (e.g. branch protection) -> degrade to PR.
    url="$(open_or_reuse_pr "$target")"
    echo "result: $target conflict"; conflicts+=("$target")
    [ -n "$url" ] && pr_urls+=("$url")
  fi
done

# --- outputs -----------------------------------------------------------------
emit() { # <name> <items...>
  local name="$1" a; shift
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  { printf '%s<<__GHEOF__\n' "$name"
    for a in "$@"; do [ -n "$a" ] && printf '%s\n' "$a"; done
    printf '__GHEOF__\n'
  } >>"$GITHUB_OUTPUT"
}
emit synced "${synced[@]:-}"
emit conflicts "${conflicts[@]:-}"
emit pr-urls "${pr_urls[@]:-}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Environment sync from \`${source_branch}\`"
    echo
    echo "| Target | Result |"
    echo "|---|---|"
    for t in "${synced[@]:-}";    do [ -n "$t" ] && echo "| \`$t\` | ✅ synced |"; done
    for t in "${conflicts[@]:-}"; do [ -n "$t" ] && echo "| \`$t\` | ⚠️ conflict → PR |"; done
    for t in "${skipped[@]:-}";   do [ -n "$t" ] && echo "| \`$t\` | ⏭️ skipped (no such branch) |"; done
  } >>"$GITHUB_STEP_SUMMARY"
fi

# Conflicts are green; only real plumbing failures are red.
[ "${#errored[@]}" -eq 0 ] || die "errors syncing: ${errored[*]}"
exit 0
