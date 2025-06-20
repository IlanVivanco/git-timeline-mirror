#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# sync_history.sh – mirror your own commit metadata into a dedicated branch
# -----------------------------------------------------------------------------
#   • Two‑branch model: scripts live on main; synthetic commits live on $DEST_BRANCH
#   • Incremental sync by default (stores last epoch in .last_sync on $DEST_BRANCH)
#   • Flags:
#        --dry-run[=<repo>] : preview using the first repo or one matching <repo>;
#                             no writes, no push.
#        --force            : delete $DEST_BRANCH and rebuild + push --force-with-lease
#   • Filters commit messages via configurable middleware
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# --------------------------------------------------
# 1 · Parse CLI flags
# --------------------------------------------------
DRY_RUN=false
DRY_TARGET=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run) DRY_RUN=true ;;
  --dry-run=*)
    DRY_RUN=true
    DRY_TARGET="${1#*=}"
    ;;
  --force) FORCE=true ;;
  *)
    echo "❌ Unknown flag: $1" >&2
    exit 1
    ;;
  esac
  shift
done

if $DRY_RUN && $FORCE; then
  echo "❌ --dry-run and --force cannot be combined" >&2
  exit 1
fi

# --------------------------------------------------
# 2 · Load .env if present
# --------------------------------------------------
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
[[ -f .env ]] && source .env

ME_NAME="${ME_NAME:-$(git config user.name || echo "Your Name")}"
ME_EMAIL="${ME_EMAIL:-$(git config user.email || echo "you@example.com")}"
GIT_EMAILS="${GIT_EMAILS:-$(git config user.email || echo "you@example.com")}"
REPOS_FILE="${REPOS_FILE:-repos.txt}"
FILTER_SCRIPT="${FILTER_SCRIPT:-./filter_message.sh}"
DEST_BRANCH="${DEST_BRANCH:-timeline}"

# Allow $GIT_EMAILS to be a comma-separated list of emails and trim spaces
IFS=',' read -r -a GIT_EMAILS <<<"$(echo "$GIT_EMAILS" | tr -d ' ')"

# --------------------------------------------------
# 3 · Verify clean working tree (skip for plain dry‑run)
# --------------------------------------------------
if ! $DRY_RUN && { ! git diff --quiet || ! git diff --cached --quiet; }; then
  echo "❌ Uncommitted changes detected. Commit or stash before running." >&2
  exit 1
fi
CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD || echo main)"

# --------------------------------------------------
# 4 · Ensure destination branch exists (skip for plain dry‑run)
# --------------------------------------------------
if ! $DRY_RUN; then
  if git show-ref --quiet "refs/heads/$DEST_BRANCH"; then
    : # exists
  else
    echo "ℹ️  Creating orphan $DEST_BRANCH branch"
    git switch --orphan "$DEST_BRANCH"
    git rm -rf . >/dev/null 2>&1 || true
    GIT_AUTHOR_NAME="$ME_NAME" GIT_AUTHOR_EMAIL="$ME_EMAIL" git commit -m "Init timeline branch" >/dev/null
    git switch "$CURRENT_BRANCH"
  fi
fi

# --------------------------------------------------
# 5 · Collect repo paths
# --------------------------------------------------
[[ -f "$REPOS_FILE" ]] || {
  echo "❌ $REPOS_FILE not found" >&2
  exit 1
}
REPOS=()
while read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  REPOS+=("$line")
done <"$REPOS_FILE"
[[ ${#REPOS[@]} -eq 0 ]] && {
  echo "❌ No repos listed in $REPOS_FILE" >&2
  exit 1
}

# Optimize dry run: limit to one repo (first or matching)
if $DRY_RUN; then
  if [[ -n "$DRY_TARGET" ]]; then
    MATCHED=()
    for R in "${REPOS[@]}"; do
      [[ "$(basename "$R")" == *"$DRY_TARGET"* ]] && MATCHED+=("$R") && break
    done
    if [[ ${#MATCHED[@]} -eq 0 ]]; then
      echo "⚠️  No repo matches '$DRY_TARGET', using first." >&2
      MATCHED=("${REPOS[0]}")
    fi
    REPOS=("${MATCHED[0]}")
  else
    REPOS=("${REPOS[0]}")
  fi
fi

# --------------------------------------------------
# 6 · Prepare last_sync (only when not plain dry‑run)
# --------------------------------------------------
LAST_SYNC=0
if ! $DRY_RUN; then
  git switch --quiet "$DEST_BRANCH"
  [[ -f .last_sync ]] && LAST_SYNC=$(cat .last_sync)
  git switch --quiet "$CURRENT_BRANCH"
fi

# --------------------------------------------------
# 7 · Harvest commits
# --------------------------------------------------
TMPFILE="$(mktemp)"

for R in "${REPOS[@]}"; do
  echo "🔍 Inspecting $R"
  # Expand tilde to home directory
  R="${R/#\~/$HOME}"
  [[ -d "$R/.git" ]] || {
    echo "⚠️ Skipping $R not a Git repo" >&2
    continue
  }
  BASENAME="$(basename "$R")"

  # Check if GIT_EMAILS are present in the repository's contributors
  CONTRIBUTORS=$(git -C "$R" log --format='%aE' | sort -u)
  EMAIL_FOUND=false
  for EMAIL in "${GIT_EMAILS[@]}"; do
    if grep -qFx "$EMAIL" <<<"$CONTRIBUTORS"; then
      EMAIL_FOUND=true
      break
    fi
  done

  if ! $EMAIL_FOUND; then
    echo "❌ None of your emails (${GIT_EMAILS[*]}) are listed as contributors in any of the repositories."
    # List the contributors of the repository
    echo "Found contributors:"
    echo "$(echo "$CONTRIBUTORS")"
    rm "$TMPFILE"
    exit 1
  fi

  # Update the git log command to filter by multiple emails
  if [[ "$LAST_SYNC" -gt 0 ]]; then
    for EMAIL in "${GIT_EMAILS[@]}"; do
      git -C "$R" log --reverse --pretty='%at%x09%s' --author="$EMAIL" --since="@$LAST_SYNC" |
        while IFS=$'\t' read -r TS MSG; do
          [[ -z "$TS" ]] && continue
          FULL="[$BASENAME] $MSG"
          if FILTERED="$(echo "$FULL" | $FILTER_SCRIPT)"; then
            [[ -z "$FILTERED" ]] && continue
            printf '%s\t%s\n' "$TS" "$FILTERED" >>"$TMPFILE"
          fi
        done
    done
  else
    for EMAIL in "${GIT_EMAILS[@]}"; do
      git -C "$R" log --reverse --pretty='%at%x09%s' --author="$EMAIL" |
        while IFS=$'\t' read -r TS MSG; do
          [[ -z "$TS" ]] && continue
          FULL="[$BASENAME] $MSG"
          if FILTERED="$(echo "$FULL" | $FILTER_SCRIPT)"; then
            [[ -z "$FILTERED" ]] && continue
            printf '%s\t%s\n' "$TS" "$FILTERED" >>"$TMPFILE"
          fi
        done
    done
  fi
done

TOTAL=$(wc -l <"$TMPFILE")

if [[ "$TOTAL" -eq 0 ]]; then
  echo "✅ No new commits to import"
  rm "$TMPFILE"
  exit 0
fi
sort -n "$TMPFILE" -o "$TMPFILE"

# --------------------------------------------------
# 8 · Dry‑run summary
# --------------------------------------------------
if $DRY_RUN; then
  echo "ℹ️  Dry run: inspected ${REPOS[*]} repo would import $TOTAL commits into $DEST_BRANCH"
  if [[ "$TOTAL" -gt 6 ]]; then
    head -n 3 "$TMPFILE" | awk -F '\t' '{printf "  %s  %s\n", strftime("%F %T", $1), $2}'
    echo "  ..."
    tail -n 3 "$TMPFILE" | awk -F '\t' '{printf "  %s  %s\n", strftime("%F %T", $1), $2}'
  else
    cat "$TMPFILE" | awk -F '\t' '{printf "  %s  %s\n", strftime("%F %T", $1), $2}'
  fi
  rm "$TMPFILE"
  exit 0
fi

# --------------------------------------------------
# 9 · Optionally rebuild branch
# --------------------------------------------------
# Ensure the timeline branch is isolated
if $FORCE || ! git show-ref --quiet "refs/heads/$DEST_BRANCH"; then
  echo "⚠️  Recreating $DEST_BRANCH branch"
  git branch -D "$DEST_BRANCH" 2>/dev/null || true
  git switch --orphan "$DEST_BRANCH"
  git rm -rf . >/dev/null 2>&1 || true
  echo "*" >.gitignore
  echo "!README_TIMELINE.md" >>.gitignore
  git add .gitignore
  GIT_AUTHOR_NAME="$ME_NAME" GIT_AUTHOR_EMAIL="$ME_EMAIL" git commit -m "Init timeline branch with isolation" >/dev/null
else
  git switch --quiet "$DEST_BRANCH"
fi

# Clear workspace when switching to timeline branch
git rm -rf . >/dev/null 2>&1 || true

# --------------------------------------------------
# 10 · Replay commits
# --------------------------------------------------
while IFS=$'\t' read -r TS MSG; do
  GIT_AUTHOR_NAME="$ME_NAME" GIT_AUTHOR_EMAIL="$ME_EMAIL" GIT_AUTHOR_DATE="@$TS" \
    GIT_COMMITTER_NAME="$ME_NAME" GIT_COMMITTER_EMAIL="$ME_EMAIL" GIT_COMMITTER_DATE="@$TS" \
    git commit --allow-empty -m "$MSG" >/dev/null
  NEWEST_TS="$TS"
done <"$TMPFILE"

# Handle empty commit replay
if [[ "$TOTAL" -eq 0 ]]; then
  echo "✅ No new commits to import, ensuring branch has a valid commit"
  GIT_AUTHOR_NAME="$ME_NAME" GIT_AUTHOR_EMAIL="$ME_EMAIL" git commit --allow-empty -m "No new commits" >/dev/null
fi

echo "$NEWEST_TS" >.last_sync
git add .last_sync && git commit --amend --no-edit >/dev/null

# Push timeline branch
if git remote get-url origin >/dev/null 2>&1; then
  if $FORCE; then
    echo git push --force-with-lease origin "$DEST_BRANCH"
  else
    echo git push origin "$DEST_BRANCH"
  fi
else
  echo "ℹ️  No origin remote; skipping push"
fi

# Return to original branch
git switch --quiet "$CURRENT_BRANCH"
rm "$TMPFILE"

echo "✅ Imported $TOTAL commits into $DEST_BRANCH (latest $(date -d "@$NEWEST_TS" +"%F %T"))"
