#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# filter_message.sh – commit‑message middleware for git‑timeline
# Receives the raw message on STDIN and must echo the sanitised version on STDOUT.
# Exit non‑zero to skip that commit entirely.
# -----------------------------------------------------------------------------
# Default behaviour: passthrough (uncomment below)
# cat && exit 0
# -----------------------------------------------------------------------------

# Block entire commit if message matches blacklist words
# read -r msg
# if grep -qiE '(merge)' <<<"$msg"; then
#   exit 1
# else
#   echo "$msg"
#   exit 0
# fi

# --- Example 1 · Strip JIRA / ticket IDs like ABC‑123 or PROJ‑456
# sed -E 's/[A-Z]{2,}-[0-9]+//g' && exit 0

# --- Example 2 · Redact internal project names (case‑insensitive)
# sed -E 's/(SecretProject|Intranet)/[REDACTED]/Ig' && exit 0

# --- Example 3 · Remove lines containing privileged words
# grep -viE 'password|credential|secret' && exit 0

# If you reach here, no filter chosen ⇒ passthrough
cat
