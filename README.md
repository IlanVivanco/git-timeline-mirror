# Git Timeline Mirror

A lightweight tool that syncs **your Git commit metadata** (dates, subjects, repo names) from any number of private repositories into a dedicated public mirror repository without exposing any proprietary code.

While GitHub can count private repository contributions (if you enable the setting), this tool is perfect for showcasing your coding activity publicly without revealing sensitive project details. It creates empty commits in a separate repository that accurately reflects your development timeline.

**Why use this?** Private contributions are invisible by default on GitHub profiles, and even when enabled, viewers can't see the actual activity patterns or project diversity. This tool gives you a public timeline that demonstrates your consistent coding habits across all projects. **Bonus**: Since the mirrored timeline is just a regular Git repository, you can push it to any Git platform (GitLab, Bitbucket, etc.) to showcase your activity there too—perfect for when you need to demonstrate your coding consistency across different platforms.

The architecture is beautifully simple: this repo holds the tooling, while your mirrored commits live in their own dedicated repository, keeping everything clean and isolated.

  > [!NOTE]
  You can enable private contributions in your GitHub profile settings, but this only shows activity to you. Other viewers still see gaps in your contribution graph and can't appreciate your consistent coding habits across private projects. This tool bridges that gap by creating a public showcase of your development timeline.

---

## Project layout

```
├── .env.sample          # user‑customisable settings (copy to .env)
├── sync_history.sh      # main synchronisation / replay script
├── filter_message.sh    # pluggable message‑sanitiser (middleware)
├── mirrored-timeline/   # cloned destination repo (auto-created)
├── .last_sync           # incremental sync timestamp (auto-created)
└── README.md            # this file
```

---

## Quick start

1. Clone this tooling repository
    ```bash
    git clone https://github.com/IlanVivanco/git-timeline-mirror.git
    cd git-timeline-mirror
    ```

2. Create a separate GitHub repo for your mirrored commits, this is where your cloned timeline will live.

3. Personalise settings
    ```bash
    cp .env.sample .env && $EDITOR .env
    ```

4. First dry‑run preview (scans repos, shows what would happen)
    ```bass
    ./sync_history.sh --dry-run
    ```

6. Actual sync: clones destination repo and populates it with commits
    ```bash
    ./sync_history.sh         # incremental (only new commits since last run)
    # or
    ./sync_history.sh --force # nuclear option: rebuild entire timeline from scratch
    ```

    > [!TIP]
    Run with `--verbose` to see which of your emails are actually contributors in each repo. Spoiler alert: you might be surprised by repos where you're mysteriously absent. 🤔

---

## Configuration (`.env`)

```env
# Identity (must match commits you push at work)
ME_NAME="Your Name"            # Used for commit authorship
ME_EMAIL="you@example.com"     # Used for commit authorship

# All emails to scan for in repos
# Multi-email support (newline-separated)
GIT_EMAILS="
you@example.com
work@company.com
old-email@example.com
"

# Source repos to harvest from
# Repository list (newline-separated)
REPOS="
~/code/project1/
~/code/project2/
/absolute/path/to/project3
"

# Destination repository URL
DEST_REPO_URL="https://github.com/your-username/your-timeline-repo.git"

# Optional tweaks to sanitize messages
FILTER_SCRIPT="./filter_message.sh"
```

  > [!WARNING]
  Make sure `DEST_REPO_URL` points to a repository you control. The script will clone it locally as `mirrored-timeline/` and push empty commits there.

---

## CLI flags

| Flag               | Effect                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `--dry-run`        | Preview using **all configured repos** (shows what commits would be imported); **no cloning, no commits, no push.** |
| `--dry-run=<repo>` | Limit preview to repos whose basename contains `<repo>` (fuzzy match). Perfect for testing specific projects.       |
| `--force`          | Nuclear option: rebuild the entire destination repository from scratch using `--force-with-lease`.                  |
| `--verbose`, `-v`  | Show detailed output, including which emails are contributors in each repo. Great for debugging missing commits.    |

  > [!WARNING]
  `--dry-run` and `--force` are mutually exclusive, because apparently we need to protect you from yourself.

---

## How it works

### Incremental Sync Magic ✨

The script is smart about not re-importing everything every time:

1. **First run**: Harvests all commits from your configured emails across all repos
2. **Subsequent runs**: Only processes commits newer than the last sync (stored in `.last_sync`)
3. **Deduplication**: Automatically removes duplicate commits (same timestamp + message)
4. **Chronological order**: Commits are sorted by timestamp regardless of which repo they came from

### Technical Details

- **Commit format**: `[repo-name] original commit message`
- **Empty commits**: No actual file changes, just metadata (dates, messages, authorship)
- **Timestamp preservation**: Original commit dates are maintained using `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE`
- **Local cloning**: Destination repo is cloned to `mirrored-timeline/` for manipulation
- **Automatic cleanup**: Temporary files are cleaned up even if the script crashes

The result? A clean timeline that accurately reflects your coding activity without exposing any proprietary code. GitHub's contribution graph gets populated, your manager sees green squares, everyone wins.

---

## Middleware examples (`filter_message.sh`)

The middleware receives the commit message on **stdin** and outputs the sanitised version. Exit non‑zero to *skip* that commit entirely.

```bash
# Example 1: Strip JIRA tickets and clean up
sed -E 's/[A-Z]{2,}-[0-9]+:?\s*//g' | sed 's/^[[:space:]]*//g'

# Example 2: Redact internal project names (case-insensitive)
sed -E 's/(SecretProject|ProjectX|InternalTool)/[REDACTED]/Ig'

# Example 3: Skip commits containing sensitive keywords
read -r msg
if grep -qiE '(password|secret|prod-db|staging|deploy)' <<< "$msg"; then
  exit 1   # skip this commit entirely
else
  echo "$msg"
fi

# Example 4: Normalize commit messages to sentence case
read -r msg
echo "$msg" | sed 's/^./\U&/'  # Capitalize first letter

# Example 5: Add emoji based on keywords (because why not?)
read -r msg
case "$msg" in
  *fix*|*bug*) echo "🐛 $msg" ;;
  *feat*|*add*) echo "✨ $msg" ;;
  *refactor*) echo "♻️ $msg" ;;
  *test*) echo "🧪 $msg" ;;
  *) echo "$msg" ;;
esac
```

Make it executable (`chmod +x filter_message.sh`) and get creative! The script processes each commit message through your filter, so you can clean, redact, skip, or enhance messages however you want.

---

## FAQ

**Why a separate repository instead of branches?** Because mixing synthetic commits with real source code is like putting chocolate on pizza, technically possible, but why would you? The separate repo keeps everything clean, and GitHub still counts those contributions toward your green squares.

**Can't I just enable private contributions on GitHub?** Yes, you can! Go to GitHub → Settings → Profile → "Private contributions" and check "Include private contributions on my profile." However, this only shows green squares to *you*—visitors to your profile still can't see your private repo activity, commit frequency, or project diversity. This tool creates a public timeline that showcases your coding patterns to everyone while keeping your code private. And on top of it, you can add activity from external sources like Gitlab or BitBucket.

**What if I have multiple work emails?** Perfect! List them all in `GIT_EMAILS` with newlines. The script will scan for commits from any of these emails across all your repos. Finally, a tool that understands your identity crisis.

**How do I test safely before committing?** Use `./sync_history.sh --dry-run` to see exactly what would happen without touching anything. Add `--verbose` if you want to see which emails are actually contributors in each repo.

**What happens if I run `--force`?** The script goes all-in: creates a fresh git history from scratch and force-pushes it. Only use this if you want to rebuild your entire timeline or if you've changed the `.env` config.

**Can I filter out embarrassing commit messages?** Absolutely! That's what `filter_message.sh` is for. Strip out JIRA tickets, redact project names, or skip commits entirely. The examples in the script should get you started.


## Troubleshooting

**"None of your configured emails found as contributors"**: Run with `--verbose` to see all contributor emails in each repo. You might be using different emails than you think, or the repo might not have any commits from you yet.

**"REPOS not configured"**: Make sure your `.env` file has the `REPOS` variable with newline-separated paths. Copy from `.env.sample` if you're starting fresh.

**"Filter script is not executable"**: Run `chmod +x filter_message.sh` to make the middleware executable.

**Commits not showing up in destination repo**: Check that `DEST_REPO_URL` is correct and you have push access. The script clones to `mirrored-timeline/` locally—peek in there if you're curious.

**"No new commits to import"**: Either you haven't made any commits since the last sync, or your email configuration doesn't match the commit authors. Use `--verbose` to debug.

**Performance with large repos**: The script scans entire git history on first run. Subsequent runs are much faster thanks to incremental sync. For truly massive repos, consider using `--dry-run=<specific-repo>` to test individual repos first.

**GitHub profile not showing private contributions**: If you want GitHub to show your private repo contributions on your profile (visible only to you), go to [GitHub Settings → Profile](https://github.com/settings/profile) and check "Include private contributions on my profile." Note that this doesn't make the contributions visible to others—that's where this tool shines.

---

Happy timeline building! Pull requests welcome (the irony is not lost on us).
