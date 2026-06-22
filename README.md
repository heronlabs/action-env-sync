# Environment Sync Action

A GitHub Action that **fans a source branch out into long-lived environment branches**. When a PR merges to `main`, it keeps every environment branch (e.g. `staging`, `development`) in sync — automatically.

For each target branch:

- **Clean merge** → a 2-parent merge commit is pushed straight to the target (zero clicks).
- **Conflict** (or the push is refused by branch protection) → a resolution **PR** is opened/updated for a human to resolve.
- **Already up to date** → no-op.

Targets are synced **independently** (fan-out): one target's conflict never blocks another. A conflict keeps the run **green** — the PR is the signal; only broken plumbing (bad inputs, auth failure) fails the run.

Branch names are arbitrary — `main`/`staging`/`development`, `master`/`stg`/`dev`, whatever your repo uses.

## Usage

```yaml
name: Sync environments
on:
  push:
    branches: [main]

permissions:
  contents: write
  pull-requests: write

jobs:
  sync:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0                      # full history is required
          token: ${{ secrets.SYNC_TOKEN }}    # same token used to push to targets

      - uses: heronlabs/action-env-sync@v1
        with:
          target-branches: |
            staging
            development
          github-token: ${{ secrets.SYNC_TOKEN }}
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `source-branch` | no | `${{ github.ref_name }}` | Branch to sync **from**. On a push to `main`, this is `main`. |
| `target-branches` | **yes** | — | Newline- or comma-separated list of branches to sync **to**. |
| `github-token` | **yes** | — | Token with `contents: write` (push to targets) and `pull-requests: write` (open PRs). |
| `merge-message` | no | `Merge {source} into {target}` | Merge-commit subject template. `{source}` / `{target}` are substituted. |

## Outputs

| Output | Description |
|---|---|
| `synced` | Newline list of targets cleanly merged and pushed. |
| `conflicts` | Newline list of targets that received a resolution PR. |
| `pr-urls` | Newline list of opened/updated PR URLs. |

## Requirements

### Full history

The action merges with git plumbing, so the consumer's `actions/checkout` **must** use `fetch-depth: 0`. A shallow checkout fails fast with a clear error.

### Token & branch protection

Clean syncs push directly to target branches, which are usually protected. The default `GITHUB_TOKEN`:

- is commonly **blocked by branch protection** (can't push to `staging`/`development`), and
- its pushes **don't trigger downstream workflows**.

So use a **Personal Access Token** or **GitHub App token** that is allowed to push to the protected targets (or is on their bypass list), and pass it to **both** `actions/checkout` (`token:`) and this action (`github-token:`). The checkout token is what authenticates the `git push`; the action token is what `gh` uses to open PRs.

If a push is refused for lack of permission, the action **degrades gracefully to opening a PR** rather than failing — so a misconfigured token surfaces as PRs, not red runs.

## Behavior reference

| Situation | Outcome |
|---|---|
| Target merges cleanly | Merge commit pushed to target; run green. |
| Target conflicts | Resolution PR opened (or reused if one is already open); run green. |
| Push to target refused | Retried once, then a resolution PR is opened; run green. |
| Target already contains source | No-op. |
| Target branch doesn't exist | Skipped, noted in the job summary; run green. |
| `source` listed among targets | Skipped. |
| Clean push after a prior conflict PR | The now-stale PR is closed automatically. |
| Missing/invalid `target-branches`, unresolvable source, auth failure | Run fails (red). |

## Development

```bash
shellcheck core/*.sh        # lint (matches CI)
bash test/run.sh            # offline harness — temp git repos + a gh stub, no network
```

The harness in [`test/run.sh`](test/run.sh) builds throwaway repos with diverging branches and asserts every behavior above.

## License

MIT © Heron Labs
