#!/usr/bin/env bash
# Codex watcher: find new upstream Codex reviews and dispatch our Claude shadow review
# on the EXACT reviewed commit, deduped against the tracking issue. Idempotent.
# Env: DRY_RUN=1 to scan+report without dispatching.
set -uo pipefail
FORK="vladb-ai/alpen"           # where the shadow workflow + tracking issue live
TRACK="${TRACKING_ISSUE:-28}"
WF="codex-shadow-review.yml"
REPOS="${REPOS:-alpen strata-bridge asm zkaleido strata-common moho}"
DRY="${DRY_RUN:-0}"
LIMIT="${PR_LIMIT:-25}"

# SHAs already shadowed (from tracking-issue comment headers: "... @ <40-hex> ...")
mapfile -t DONE < <(gh api "repos/$FORK/issues/$TRACK/comments" --paginate \
  -q '.[]|select(.user.login=="github-actions[bot]")|.body' 2>/dev/null \
  | grep -oE '@ [0-9a-f]{40}' | awk '{print $2}' | sort -u)
is_done(){ local s; for s in "${DONE[@]:-}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

extract_sha(){  # Codex formats: "Reviewed commit: `sha`" (bold or not) or blob/<sha>/ (findings)
  jq -r '(.body|capture("[Rr]eviewed commit:?\\**\\s*`?(?<s>[0-9a-f]{7,40})").s) // (.body|capture("blob/(?<s>[0-9a-f]{40})/").s) // "?"' <<<"$1" 2>/dev/null
}

new=0; scanned=0
for r in $REPOS; do
  for pr in $(gh pr list -R "alpenlabs/$r" --state all --limit "$LIMIT" \
        --json number,updatedAt -q 'sort_by(.updatedAt)|reverse|.[].number' 2>/dev/null); do
    all=$(gh api "repos/alpenlabs/$r/issues/$pr/comments" \
          -q '[.[]|select(.user.login=="chatgpt-codex-connector[bot]")]' 2>/dev/null)
    [ "$(jq 'length' <<<"$all" 2>/dev/null)" = "0" ] && continue
    # keep only actual reviews (drop "usage limits reached / credits" notices)
    c=$(jq -c '[.[]|select((.body|test("usage limits|[Cc]redits must be used";"i"))|not)]' <<<"$all")
    [ "$(jq 'length' <<<"$c" 2>/dev/null)" = "0" ] && { echo "  ~ $r#$pr: Codex quota/credit notice only, skipped"; continue; }
    scanned=$((scanned+1))
    latest=$(jq -c 'sort_by(.created_at)|last' <<<"$c")
    sha=$(extract_sha "$latest")
    if [ "$sha" = "?" ]; then
      # no reviewed-commit in body (some clean reviews omit it): use PR head as of the comment time
      ts=$(jq -r '.created_at' <<<"$latest")
      sha=$(gh api "repos/alpenlabs/$r/pulls/$pr/commits" --paginate -q "[.[]|select(.commit.committer.date <= \"$ts\")]|last|.sha" 2>/dev/null)
      [ -z "$sha" ] || [ "$sha" = "null" ] && { echo "  ? $r#$pr: no reviewed sha and no head fallback, skipped"; continue; }
      echo "  (i) $r#$pr: sha via head-at-comment fallback"
    fi
    full=$(gh api "repos/alpenlabs/$r/commits/$sha" -q .sha 2>/dev/null); [ -z "$full" ] && continue
    is_done "$full" && continue
    base=$(gh pr view "$pr" -R "alpenlabs/$r" --json baseRefName -q .baseRefName 2>/dev/null)
    # deleted (e.g. merged stacked-PR) base branch -> compare against the recorded base commit
    gh api "repos/alpenlabs/$r/branches/$base" -q .name >/dev/null 2>&1 || \
      base=$(gh api "repos/alpenlabs/$r/pulls/$pr" -q .base.sha 2>/dev/null)
    echo "NEW  $r#$pr  base=$base  sha=${full:0:12}"
    new=$((new+1))
    [ "$DRY" = "1" ] && continue
    gh workflow run "$WF" -R "$FORK" -f upstream="alpenlabs/$r" -f base="$base" \
      -f head_sha="$full" -f pr="$pr" -f tracking_issue="$TRACK" >/dev/null 2>&1 \
      && echo "     dispatched" || echo "     dispatch FAIL"
  done
done
echo "codex-watch: ${#DONE[@]} already shadowed, $scanned codex-reviewed PRs scanned, $new new (dry=$DRY)"
