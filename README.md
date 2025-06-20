
# Git Timeline Export

A lightweight scaffold that mirrors **only your own Git commit metadata** (dates, subjects, repo name) from any number of private repositories into this very repository—without exposing any proprietary code.

We keep **two branches** so metadata never pollutes real source history:

| Branch | Purpose |
|--------|---------|
| `main` | Stores the scaffolding itself—`sync_history.sh`, middleware, docs, etc. |
| `timeline` (default) | Holds the synthetic, empty commits that render as dots on your GitHub contribution graph. |

GitHub counts contributions from *all* branches, so separating them is safe and clean.

---

## Project layout (on `main`)

```
├── .env.sample          # user‑customisable settings (copy to .env)
├── repos.txt            # list of source‑repo paths, one per line
├── sync_history.sh      # main synchronisation / replay script
├── filter_message.sh    # pluggable message‑sanitiser (middleware)
├── test_dry_run.sh      # quick validation helper
└── README.md            # this file
```

---

## Quick start

```bash
# 1 · Clone the scaffold (default branch is main)
git clone https://github.com/your‑handle/commit-echo.git
cd commit-echo

# 2 · Personalise settings
cp .env.sample .env && $EDITOR .env

# 3 · List the repos you want to mine
$EDITOR repos.txt

# 4 · First dry‑run preview (scans just the first repo, no writes)
./sync_history.sh --dry-run

# 5 · Actual sync → updates the `timeline` branch and pushes it
./sync_history.sh         # incremental
# or
./sync_history.sh --force # rebuild from scratch
```

---

## Configuration (`.env`)

```env
### Identity (must match commits you push at work)
ME_NAME="Ilán Vivanco"
ME_EMAIL="ilan@example.com"

### Branch that stores synthetic commits
DEST_BRANCH="timeline"

### Optional tweaks
FILTER_SCRIPT="./filter_message.sh" # executable that receives msg on stdin
REPOS_FILE="repos.txt"              # path listing source repos
```

---

## CLI flags

| Flag                | Effect |
|---------------------|--------|
| `--dry-run`         | Preview using **only the first repo** (or a specific one via `--dry-run=<repo>`); prints sample output; **no branch changes, no push.** |
| `--dry-run=<repo>`  | Limit preview to the repo whose basename matches `<repo>`. |
| `--force`           | Delete the `timeline` branch, rebuild it from scratch, and push with `--force-with-lease`. |

Flags are mutually exclusive.

---

## Middleware examples (`filter_message.sh`)

The middleware receives the commit message on **stdin** and outputs the sanitised version.  Exit non‑zero to *skip* that commit.

```bash
# 1 · Strip JIRA tickets
sed -E 's/[A-Z]{2,}-[0-9]+//g'

# 2 · Redact project codenames
sed -E 's/(SecretProject|Intranet)/[REDACTED]/Ig'

# 3 · Block commits mentioning prod DB
read -r msg
if grep -qE '(prod-db|clientX)' <<< "$msg"; then
  exit 1   # skip
else
  echo "$msg"
fi
```

Make it executable (`chmod +x filter_message.sh`) and reference it via `.env`.

---

## FAQ

**Why a separate branch?**  Keeping synthetic empty commits apart prevents noise in your real history and keeps pull requests clean. GitHub still credits those commits to your profile.

**Can I rename `timeline`?**  Yes—set `DEST_BRANCH` in `.env` and optionally rename the remote branch.

**How do I test safely?**  Use `./sync_history.sh --dry-run` (optionally with a repo name) to scan a subset without touching branches or pushing.

Happy exporting!  Pull requests welcome.
