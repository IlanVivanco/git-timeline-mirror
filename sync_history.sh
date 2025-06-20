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
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run) DRY_RUN=true ;;
  --dry-run=*)
    DRY_RUN=true
    DRY_TARGET="${1#*=}"
    ;;
  --force) FORCE=true ;;
  --verbose | -v) VERBOSE=true ;;
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
REPOS="${REPOS:-}" # Newline-separated list of repo paths
FILTER_SCRIPT="${FILTER_SCRIPT:-./filter_message.sh}"
DEST_REPO_URL="${DEST_REPO_URL:-}" # URL of the mirrored destination repository

# --------------------------------------------------
# 3 · Collect config data
# --------------------------------------------------
REPOS_ARRAY=()
if [[ -n "$REPOS" ]]; then
  # Use repos from .env (newline-separated)
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    REPOS_ARRAY+=("$line")
  done <<<"$REPOS"
else
  echo "❌ REPOS not configured in .env. Please set REPOS with newline-separated repo paths." >&2
  exit 1
fi

[[ ${#REPOS_ARRAY[@]} -eq 0 ]] && {
  echo "❌ No repos found in REPOS configuration" >&2
  exit 1
}

GIT_EMAILS_ARRAY=()
if [[ -n "$REPOS" ]]; then
  # Use repos from .env (newline-separated)
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    GIT_EMAILS_ARRAY+=("$line")
  done <<<"$GIT_EMAILS"
else
  echo "❌ REPOS not configured in .env. Please set REPOS with newline-separated repo paths." >&2
  exit 1
fi

[[ ${#GIT_EMAILS_ARRAY[@]} -eq 0 ]] && {
  echo "❌ No repos found in REPOS configuration" >&2
  exit 1
}

# Optimize dry run
if $DRY_RUN && [[ -n "$DRY_TARGET" ]]; then
  MATCHED=()
  for R in "${REPOS_ARRAY[@]}"; do
    [[ "$(basename "$R")" == *"$DRY_TARGET"* ]] && MATCHED+=("$R") && break
  done
  if [[ ${#MATCHED[@]} -eq 0 ]]; then
    echo "⚠️  No repo matches '$DRY_TARGET', using all repos." >&2
    REPOS=("${REPOS_ARRAY[@]}")
  else
    REPOS=("${MATCHED[0]}")
  fi
else
  REPOS=("${REPOS_ARRAY[@]}")
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
  # Expand tilde to home directory
  R="${R/#\~/$HOME}"
  [[ -d "$R/.git" ]] || {
    echo "⚠️ Skipping $R not a Git repo"
    continue
  }
  BASENAME="$(basename "$R")"

  # Check if GIT_EMAILS_ARRAY are present in the repository's contributors
  CONTRIBUTORS=$(git -C "$R" log --format='%aE' | sort -u)
  EMAIL_FOUND=false
  for EMAIL in "${GIT_EMAILS_ARRAY[@]}"; do
    if grep -qFx "$EMAIL" <<<"$CONTRIBUTORS"; then
      EMAIL_FOUND=true
      break
    fi
  done

  if ! $EMAIL_FOUND; then
    echo "❌ None of your emails are listed as contributors in $R."
    echo "Found contributors:"
    echo "$(echo "$CONTRIBUTORS")"
  fi

  # Update the git log command to filter by multiple emails
  if [[ "$LAST_SYNC" -gt 0 ]]; then
    for EMAIL in "${GIT_EMAILS_ARRAY[@]}"; do
      echo "🔍 Harvesting commits in $R since $(date -d "@$LAST_SYNC" +"%F %T")"
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
    echo "🔍 Harvesting all commits in $R"
    for EMAIL in "${GIT_EMAILS_ARRAY[@]}"; do
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

# Show verbose output if requested
if $VERBOSE; then
  echo "--------------------------"
  echo "📋 Harvested commits:"
  cat "$TMPFILE" | awk -F '\t' '{printf "  %s  %s\n", strftime("%F %T", $1), $2}'
fi

if [[ "$TOTAL" -eq 0 ]]; then
  echo "✅ No new commits to import"
  rm "$TMPFILE"
  exit 0
fi
sort -n "$TMPFILE" -o "$TMPFILE"

# --------------------------------------------------
# 6 · Dry‑run summary
# --------------------------------------------------
if $DRY_RUN && ! $VERBOSE; then
  echo "ℹ️  Dry run: The inspected repos would import $TOTAL commits into the mirrored repository"
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
# Skip destination repository operations during dry run
if ! $DRY_RUN; then
  # Clone or initialize the destination repository
  if [[ -n "$DEST_REPO_URL" ]]; then
    if [[ ! -d "mirrored-timeline" ]]; then
      echo "ℹ️  Cloning destination repository"
      git clone "$DEST_REPO_URL" mirrored-timeline
    fi
    cd mirrored-timeline

    # Handle FORCE flag to override git history
    if $FORCE; then
      echo "⚠️  Rebuilding git history from scratch..."
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

  echo "✅ Imported $TOTAL commits into the mirrored repository (latest $(date -d "@$NEWEST_TS" +"%F %T"))"
fi

rm "$TMPFILE"
