#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# sync_history.sh – mirror your own commit metadata into a dedicated repository
# -----------------------------------------------------------------------------
#   • Incremental sync by default (stores last epoch in .last_sync)
#   • Flags:
#        --dry-run[=<repo>] : preview using the first repo or one matching <repo>
#        --force            : rebuild git history from scratch
#        --verbose, -v      : show detailed output
#   • Filters commit messages via configurable middleware
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# --------------------------------------------------
# Helper functions
# --------------------------------------------------
parse_newline_separated() {
  local input="$1"
  local -n output_array=$2

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    output_array+=("$line")
  done <<<"$input"
}

format_timestamp() {
  date -d "@$1" +'%F %T'
}

harvest_commits_for_repo() {
  local repo="$1"
  local basename="$2"
  local tmpfile="$3"
  local since_option="$4"

  echo "🔍 Harvesting commits in $repo${since_option:+ since $(format_timestamp ${since_option#--since=@})}"

  # Process each email separately (git doesn't support OR with multiple --author flags)
  for email in "${GIT_EMAILS_ARRAY[@]}"; do
    local git_output
    git_output=$(git -C "$repo" log --reverse --pretty='%at%x09%s' --author="$email" $since_option)

    while IFS=$'\t' read -r ts msg; do
      [[ -z "$ts" ]] && continue
      local full="[$basename] $msg"
      if filtered="$(echo "$full" | "$FILTER_SCRIPT")"; then
        [[ -n "$filtered" ]] && printf '%s\t%s\n' "$ts" "$filtered" >>"$tmpfile"
      fi
    done <<<"$git_output"
  done
}

show_commit_summary() {
  local tmpfile="$1"
  local total="$2"
  local limit="${3:-6}"

  if [[ "$total" -gt "$limit" ]]; then
    head -n 3 "$tmpfile" | awk -F '\t' '{printf "  %s  %s\n", strftime("%F %T", $1), $2}'
    echo "  ..."
    tail -n 3 "$tmpfile" | awk -F '\t' '{printf "  %s  %s\n", strftime("%F %T", $1), $2}'
  else
    awk -F '\t' '{printf "  %s  %s\n", strftime("%F %T", $1), $2}' "$tmpfile"
  fi
}

# --------------------------------------------------
# 1 · Parse CLI flags
# --------------------------------------------------
DRY_RUN=false
DRY_TARGET=""
FORCE=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run | -d) DRY_RUN=true ;;
  --dry-run=*)
    DRY_RUN=true
    DRY_TARGET="${1#*=}"
    ;;
  --force | -f) FORCE=true ;;
  --verbose | -v) VERBOSE=true ;;
  *)
    echo "❌ Unknown flag: $1" >&2
    echo "Usage: $0 [--dry-run[=<repo>]] [--force] [--verbose|-v]" >&2
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
# 2 · Load configuration
# --------------------------------------------------
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
[[ -f .env ]] && source .env

# Set defaults with fallbacks
ME_NAME="${ME_NAME:-$(git config user.name 2>/dev/null || echo "Your Name")}"
ME_EMAIL="${ME_EMAIL:-$(git config user.email 2>/dev/null || echo "you@example.com")}"
GIT_EMAILS="${GIT_EMAILS:-$(git config user.email 2>/dev/null || echo "you@example.com")}"
FILTER_SCRIPT="${FILTER_SCRIPT:-./filter_message.sh}"
DEST_REPO_URL="${DEST_REPO_URL:-}"

# Validate required configuration
if [[ -z "$REPOS" ]]; then
  echo "❌ REPOS not configured in .env. Please set REPOS with newline-separated repo paths." >&2
  exit 1
fi

if [[ ! -x "$FILTER_SCRIPT" ]]; then
  echo "❌ Filter script '$FILTER_SCRIPT' is not executable" >&2
  exit 1
fi

# --------------------------------------------------
# 3 · Parse configuration arrays
# --------------------------------------------------
REPOS_ARRAY=()
parse_newline_separated "$REPOS" REPOS_ARRAY

GIT_EMAILS_ARRAY=()
parse_newline_separated "$GIT_EMAILS" GIT_EMAILS_ARRAY

if [[ ${#REPOS_ARRAY[@]} -eq 0 ]]; then
  echo "❌ No repositories found in REPOS configuration" >&2
  exit 1
fi

if [[ ${#GIT_EMAILS_ARRAY[@]} -eq 0 ]]; then
  echo "❌ No email addresses found in GIT_EMAILS configuration" >&2
  exit 1
fi

# Filter repositories for dry run
if $DRY_RUN && [[ -n "$DRY_TARGET" ]]; then
  FILTERED_REPOS=()
  for repo in "${REPOS_ARRAY[@]}"; do
    if [[ "$(basename "$repo")" == *"$DRY_TARGET"* ]]; then
      FILTERED_REPOS=("$repo")
      break
    fi
  done

  if [[ ${#FILTERED_REPOS[@]} -eq 0 ]]; then
    echo "⚠️  No repo matches '$DRY_TARGET', using all repos." >&2
    REPOS_TO_PROCESS=("${REPOS_ARRAY[@]}")
  else
    REPOS_TO_PROCESS=("${FILTERED_REPOS[@]}")
  fi
else
  REPOS_TO_PROCESS=("${REPOS_ARRAY[@]}")
fi

# --------------------------------------------------
# 4 · Determine sync point
# --------------------------------------------------
LAST_SYNC=0
SINCE_OPTION=""

if ! $DRY_RUN && ! $FORCE && [[ -f .last_sync ]]; then
  LAST_SYNC=$(cat .last_sync)
  # Add 1 second offset to avoid including the exact same timestamp
  LAST_SYNC=$((LAST_SYNC + 1))
  SINCE_OPTION="--since=@$LAST_SYNC"
fi

# --------------------------------------------------
# 5 · Harvest commits
# --------------------------------------------------
TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

for repo in "${REPOS_TO_PROCESS[@]}"; do
  # Expand tilde to home directory
  repo="${repo/#\~/$HOME}"

  if [[ ! -d "$repo/.git" ]]; then
    echo "⚠️  Skipping $repo (not a Git repository)"
    continue
  fi

  basename="$(basename "$repo")"

  # Check if any of our emails are contributors (only if verbose)
  if $VERBOSE; then
    contributors=$(git -C "$repo" log --format='%aE' | sort -u)
    email_found=false
    for email in "${GIT_EMAILS_ARRAY[@]}"; do
      if grep -qFx "$email" <<<"$contributors"; then
        email_found=true
        break
      fi
    done

    if ! $email_found; then
      echo "⚠️  None of your configured emails found as contributors in $repo"
      echo "   Configured: ${GIT_EMAILS_ARRAY[*]}"
      echo "   Found contributors: $(echo "$contributors" | tr '\n' ' ')"
    fi
  fi

  harvest_commits_for_repo "$repo" "$basename" "$TMPFILE" "$SINCE_OPTION"
done

TOTAL=$(wc -l <"$TMPFILE")

# Early exit if no commits found
if [[ "$TOTAL" -eq 0 ]]; then
  echo "✅ No new commits to import"
  exit 0
fi

# Sort commits by timestamp and remove duplicates
sort -n "$TMPFILE" -o "$TMPFILE"
# Remove duplicate commits (same timestamp and message)
awk -F'\t' '!seen[$1$2]++' "$TMPFILE" >"${TMPFILE}.dedup"
mv "${TMPFILE}.dedup" "$TMPFILE"

# --------------------------------------------------
# 6 · Show results
# --------------------------------------------------
if $VERBOSE || ($DRY_RUN && ! $VERBOSE); then
  echo "📋 Found $TOTAL commits to import:"
  show_commit_summary "$TMPFILE" "$TOTAL"
fi

# Exit early for dry run
if $DRY_RUN; then
  echo "ℹ️  Dry run complete - no changes made"
  exit 0
fi

# --------------------------------------------------
# 7 · Apply commits to destination repository
# --------------------------------------------------
if [[ -z "$DEST_REPO_URL" ]]; then
  echo "❌ DEST_REPO_URL is not set in .env" >&2
  exit 1
fi

# Clone or update destination repository
if [[ ! -d "mirrored-timeline" ]]; then
  echo "ℹ️  Cloning destination repository"
  git clone "$DEST_REPO_URL" mirrored-timeline
fi

cd mirrored-timeline

# Handle force rebuild
if $FORCE; then
  echo "⚠️  Rebuilding git history from scratch..."
  git checkout --orphan temp-branch
  git rm -rf . >/dev/null 2>&1 || true
  git commit --allow-empty -m "Initialize fresh timeline" >/dev/null
  git branch -D main >/dev/null 2>&1 || true
  git branch -m main
  git push --force-with-lease origin main >/dev/null 2>&1 || true
fi

# Apply commits
NEWEST_TS=""
while IFS=$'\t' read -r ts msg; do
  GIT_AUTHOR_NAME="$ME_NAME" GIT_AUTHOR_EMAIL="$ME_EMAIL" GIT_AUTHOR_DATE="@$ts" \
    GIT_COMMITTER_NAME="$ME_NAME" GIT_COMMITTER_EMAIL="$ME_EMAIL" GIT_COMMITTER_DATE="@$ts" \
    git commit --allow-empty -m "$msg" >/dev/null
  NEWEST_TS="$ts"
done <"$TMPFILE"

# Update sync tracking and push
if [[ -n "$NEWEST_TS" ]]; then
  echo "$NEWEST_TS" >../.last_sync
  git push origin main >/dev/null 2>&1 || true
  cd ..
  echo "✅ Imported $TOTAL commits into mirrored repository (latest: $(format_timestamp "$NEWEST_TS"))"
else
  cd ..
  echo "✅ No commits to import"
fi
