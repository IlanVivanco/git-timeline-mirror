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
DEST_REPO_URL="${DEST_REPO_URL:-}" # URL of the mirrored destination repository

# Allow $GIT_EMAILS to be a comma-separated list of emails and trim spaces
IFS=',' read -r -a GIT_EMAILS <<<"$(echo "$GIT_EMAILS" | tr -d ' ')"

# --------------------------------------------------
# 3 · Collect repo paths
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
# 4 · Prepare last_sync (only when not plain dry‑run)
# --------------------------------------------------
LAST_SYNC=0
if ! $DRY_RUN && ! $FORCE; then
  if [[ -f .last_sync ]]; then
    LAST_SYNC=$(cat .last_sync)
    # Add 1 second offset to avoid including the exact same timestamp
    LAST_SYNC=$((LAST_SYNC + 1))
  fi
fi

# --------------------------------------------------
# 5 · Harvest commits
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
      echo "🔍 Harvesting commits for $EMAIL in $R since $(date -d "@$LAST_SYNC" +"%F %T")"
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
    echo "🔍 Harvesting all commits for ${GIT_EMAILS[*]} in $R"
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
echo $(cat "$TMPFILE" | awk -F '\t' '{printf "  %s  %s\n", strftime("%F %T", $1), $2}')

if [[ "$TOTAL" -eq 0 ]]; then
  echo "✅ No new commits to import"
  rm "$TMPFILE"
  exit 0
fi
sort -n "$TMPFILE" -o "$TMPFILE"

# --------------------------------------------------
# 6 · Dry‑run summary
# --------------------------------------------------
if $DRY_RUN; then
  echo "ℹ️  Dry run: inspected ${REPOS[*]} repo would import $TOTAL commits into the mirrored repository"
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
# 7 · Replay commits directly in the destination repository
# --------------------------------------------------
# Clone or initialize the destination repository
if [[ -n "$DEST_REPO_URL" ]]; then
  if [[ ! -d "mirrored-timeline" ]]; then
    echo "ℹ️  Cloning destination repository"
    git clone "$DEST_REPO_URL" mirrored-timeline
  fi
  cd mirrored-timeline

  # Handle FORCE flag to override git history
  if $FORCE; then
    echo "⚠️  --force: rebuilding git history from scratch"
    git checkout --orphan temp-branch
    git rm -rf . >/dev/null 2>&1 || true
    git commit --allow-empty -m "Initialize fresh timeline" >/dev/null
    git branch -D main >/dev/null 2>&1 || true
    git branch -m main
    git push --force-with-lease origin main >/dev/null 2>&1 || true
  fi
else
  echo "❌ DEST_REPO_URL is not set in .env" >&2
  exit 1
fi

# Replay commits directly in the destination repository
while IFS=$'\t' read -r TS MSG; do
  GIT_AUTHOR_NAME="$ME_NAME" GIT_AUTHOR_EMAIL="$ME_EMAIL" GIT_AUTHOR_DATE="@$TS" \
    GIT_COMMITTER_NAME="$ME_NAME" GIT_COMMITTER_EMAIL="$ME_EMAIL" GIT_COMMITTER_DATE="@$TS" \
    git commit --allow-empty -m "$MSG" >/dev/null
  NEWEST_TS="$TS"
done <"$TMPFILE"

# Update .last_sync after replaying commits
if [[ "$TOTAL" -gt 0 ]]; then
  echo "$NEWEST_TS" >../.last_sync
  # Push commits to remote
  git push origin main >/dev/null 2>&1 || true
fi

# Return to the git-timeline-mirror repository
cd ..

rm "$TMPFILE"

echo "✅ Imported $TOTAL commits into the mirrored repository (latest $(date -d "@$NEWEST_TS" +"%F %T"))"
