# AI Review — Codex shadow comparison tooling

Runs our Claude review on the **exact commit** OpenAI Codex reviewed upstream, so the two
can be compared apples-to-apples. Results collect in tracking issue **#28**.

## Pieces
- `.github/workflows/codex-shadow-review.yml` — reviews one upstream commit. Inputs:
  `upstream` (owner/repo), `base` (branch **or** commit SHA), `head_sha` (full 40-char), `pr`, `tracking_issue`.
  Checks out the upstream repo at `head_sha`, pulls the authoritative diff via `compare/base...head_sha`,
  asserts `compare_tip == head_sha`, runs `claude-code-action` (Sonnet 5, general "major issues" prompt),
  posts to the tracking issue with header `### Shadow: <upstream>#<pr> @ <sha>`.
- `.github/workflows/codex-watcher.yml` — cron (every 6h) + manual. Runs `codex-watch.sh`.
- `tools/ai-review/codex-watch.sh` — scans upstream repos for new `chatgpt-codex-connector[bot]`
  reviews, extracts the reviewed SHA, dedupes against the tracking issue, dispatches the shadow review.

## Gotchas (learned the hard way)
- `actions/checkout` needs the **full 40-char SHA** (short SHA is treated as a branch name → fails).
- Deleted stacked-PR base branch → compare against the PR's recorded `base.sha` (watcher does this).
- Some Codex comments omit `Reviewed commit:` → watcher falls back to PR head as of the comment time.
- Codex "usage limits reached / credits" notices are skipped (not reviews).
- `schedule` is disabled by default on **forks** — enable once in the Actions tab, or run manually.
- If `github.token` can't dispatch (anti-recursion), set a `WATCHER_PAT` secret (workflow scope).

## Manual run
`gh workflow run "Codex Watcher" -R vladb-ai/alpen -f dry_run=1`   # scan only
`bash tools/ai-review/codex-watch.sh`                              # local (needs gh auth)
