#!/usr/bin/env bash
#
# repo-public-check.sh — Heuristic safety scan before making a git repo public.
#
# Scans tracked files AND full git history for secrets, private keys,
# internal hostnames/IPs, oversized blobs, and other things you don't want
# on the public internet.
#
# Usage: repo-public-check.sh [--no-history] [path-to-repo]
#
# Exit codes:
#   0  no blocking findings (warnings may exist)
#   2  blocking findings — do NOT make public until resolved
#   1  usage / environment error (not a git repo, git missing, ...)
#
# NOTE: This is heuristic, not a guarantee. Every finding needs human review.
# A clean result means "nothing matched known patterns", not "provably safe".

set -u

# ---------------------------------------------------------------- args ------
SCAN_HISTORY=1
TARGET="."

for arg in "$@"; do
    case "$arg" in
        --no-history) SCAN_HISTORY=0 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            echo "Usage: $(basename "$0") [--no-history] [path-to-repo]"
            exit 0 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *)  TARGET="$arg" ;;
    esac
done

# --------------------------------------------------------------- colors -----
if [ -t 1 ]; then
    RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'
    BLU=$'\033[1;34m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
    RED=""; YEL=""; GRN=""; BLU=""; DIM=""; RST=""
fi

# ---------------------------------------------------------------- env -------
command -v git >/dev/null 2>&1 || { echo "git not found in PATH" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "Not a directory: $TARGET" >&2; exit 1; }
cd "$TARGET" || exit 1
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Not a git repository: $TARGET" >&2; exit 1; }

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

FAIL=0   # blocking findings
WARN=0   # warnings / review items

say_fail() { FAIL=$((FAIL+1)); printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$1"; }
say_warn() { WARN=$((WARN+1)); printf '%s[WARN]%s %s\n' "$YEL" "$RST" "$1"; }
say_info() { printf '%s[INFO]%s %s\n' "$BLU" "$RST" "$1"; }
say_ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$1"; }
section()  { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RST"; }

# Placeholder-looking values are almost certainly not real secrets.
# Also covers template expressions (Jinja {{ }}, ${ }) — a reference to a
# variable/vault lookup is not a hardcoded secret.
PLACEHOLDER_RE='changeme|example|sample|placeholder|todo|fixme|your[_-]|\b(always|on_create|yes|no|true|false|null)\b|x{3,}|\*{3,}|<[^>]*>|\$\{|\{\{|\{%'
filter_placeholders() { grep -viE "$PLACEHOLDER_RE" || true; }

# Mask the matched secret so scan output is safe to share/paste.
# $1 = the ERE that produced the match.
mask_secret() { sed -E "s#${1}#<redacted>#gI" || true; }

# Collapse duplicate history findings (same file/line/content across many
# commits) keeping the first occurrence, so one leaked line doesn't print
# once per commit. Input: <rev>:<path>:<line>:<content>.
dedupe_history() { awk '{rest=$0; sub(/^[^:]*:/,"",rest); if(!seen[rest]++) print $0}'; }

# Run git-grep for one pattern across every commit in history, batching
# revisions so large repos don't blow past ARG_MAX. Prints rev:path:line:match.
# NOTE: revs must come BEFORE `--`; xargs appends at the end, hence sh -c.
grep_history() {  # $1 = ERE pattern
    git rev-list --all 2>/dev/null \
        | xargs -r -n 500 sh -c 'pat=$1; shift; git grep -n -I -i -E -e "$pat" "$@" -- 2>/dev/null' _ "$1"
}

echo "Scanning repo: $REPO_NAME  ($(git rev-parse --show-toplevel))"
echo "History scan: $([ "$SCAN_HISTORY" = 1 ] && echo on || echo off)"

# --------------------------------------- 1. sensitive filenames (tracked) ---
section "1. Sensitive filenames (tracked files)"
# .env.example / .env.sample are templates and intentionally public — excluded.
SENSITIVE_NAME_RE='(^|/)\.env(\.|$)|(^|/)\.env\.local$|\.pem$|\.key$|\.p12$|\.pfx$|(^|/)id_rsa$|(^|/)id_dsa$|(^|/)id_ecdsa$|(^|/)id_ed25519$|credentials\.json$|secrets?\.ya?ml$|vault-password'

found=0
while IFS= read -r f; do
    case "$f" in
        *.example|*.sample|*.template|*.dist) continue ;;
    esac
    say_fail "tracked sensitive file: $f"
    found=1
done < <(git ls-files | grep -Ei "$SENSITIVE_NAME_RE" || true)
[ "$found" = 0 ] && say_ok "no sensitive filenames tracked"

# --------------------------------------- 2. secret patterns (worktree) -------
section "2. Secret patterns in tracked files (current)"

# Format: "Label|extended-regex" — grep runs with -i.
PATTERNS_FAIL=(
    "AWS access key|AKIA[0-9A-Z]{16}"
    "AWS secret key assignment|aws_secret_access_key[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9/+=]{20,}"
    "GitHub token|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{20,}"
    "GitLab token|glpat-[A-Za-z0-9_-]{20,}"
    "Slack token|xox[baprs]-[A-Za-z0-9-]{10,}"
    "Stripe key|sk_(live|test)_[A-Za-z0-9]{10,}"
    "Private key material|-----[ ]BEGIN[ ]((RSA|DSA|EC|OPENSSH)[ ])?PRIVATE[ ]KEY-----"
    "PuTTY key file|PuTTY-User-Key""-File"
    "URL with embedded credentials|[a-zA-Z][a-zA-Z0-9+.-]*://[^/[:space:]:]+:[^/[:space:]@]+@"
    "Password assignment|password[\"']?[[:space:]]*[:=][[:space:]]*(\"[^\"]{4,}\"|'[^']{4,}'|[^\"'[:space:],;}]{4,})"
    "API key assignment|api[_-]?key[\"']?[[:space:]]*[:=][[:space:]]*(\"[^\"]{8,}\"|'[^']{8,}'|[^\"'[:space:],;}]{8,})"
)

found=0
for entry in "${PATTERNS_FAIL[@]}"; do
    label="${entry%%|*}"; re="${entry#*|}"
    while IFS= read -r line; do
        say_fail "$label -> ${line:0:160}"
        found=1
    done < <(git grep -n -I -i -E -e "$re" -- . 2>/dev/null | filter_placeholders | mask_secret "$re")
done
[ "$found" = 0 ] && say_ok "no secret patterns in current files"

# --------------------------------------- 3. secret patterns (history) --------
if [ "$SCAN_HISTORY" = 1 ]; then
    section "3. Secret patterns in git history (deleted != gone)"
    if [ -z "$(git rev-list --all 2>/dev/null | head -1)" ]; then
        say_info "no commits yet — skipping"
    else
        found=0
        for entry in "${PATTERNS_FAIL[@]}"; do
            label="${entry%%|*}"; re="${entry#*|}"
            # Output: <abbrev-sha>:<path>:<line>:<match> ; -I skips binaries
            while IFS= read -r line; do
                say_fail "history: $label -> ${line:0:160}"
                found=1
            done < <(grep_history "$re" | dedupe_history | filter_placeholders | mask_secret "$re")
        done
        if [ "$found" = 0 ]; then
            say_ok "no secret patterns in history"
        else
            say_info "history findings need 'git filter-repo' / BFG to truly purge"
        fi
    fi
fi

# --------------------------------------- 4. internal hosts / IPs (warn) -----
section "4. Internal hostnames and private IPs (review)"
PATTERNS_WARN=(
    "Internal hostname|[A-Za-z0-9.-]+\.(internal|corp|intranet|lan|local|home\.arpa|invalid)\b"
    "Private IPv4|\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})\b"
)
found=0
for entry in "${PATTERNS_WARN[@]}"; do
    label="${entry%%|*}"; re="${entry#*|}"
    while IFS= read -r line; do
        say_warn "$label -> ${line:0:160}"
        found=1
    done < <(git grep -n -I -i -E -e "$re" -- . 2>/dev/null | filter_placeholders)
done
[ "$found" = 0 ] && say_ok "no internal hosts/IPs in current files"

# --------------------------------------- 5. oversized blobs ------------------
section "5. Oversized blobs (GitHub hard-blocks >100MB)"
# 50MB warn / 100MB fail, measured on blob size across all history.
found=0
while IFS= read -r line; do
    # line: "<sha> blob <size> <path...>" — path may be empty for unreachable blobs
    size=$(echo "$line" | awk '{print $3}')
    path=$(echo "$line" | cut -d' ' -f4-)
    [ -z "$path" ] && path="(unreachable blob)"
    if [ "$size" -ge 104857600 ]; then
        say_fail "blob >100MB: $path ($((size/1048576))MB)"
        found=1
    elif [ "$size" -ge 52428800 ]; then
        say_warn "blob >50MB: $path ($((size/1048576))MB)"
        found=1
    fi
done < <(git rev-list --objects --all 2>/dev/null \
         | git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(rest)' 2>/dev/null \
         | awk '$2=="blob" && $3+0 >= 52428800')
[ "$found" = 0 ] && say_ok "no blobs over 50MB"

# --------------------------------------- 6. .gitignore hygiene --------------
section "6. .gitignore hygiene"
if [ ! -f .gitignore ]; then
    say_warn "no .gitignore at repo root"
else
    if git check-ignore -q .env 2>/dev/null; then
        say_ok ".env is git-ignored"
    else
        say_warn ".env is NOT covered by .gitignore"
    fi
fi

# Untracked files with sensitive names won't be published — but flag them so
# a careless `git add -A` doesn't sweep them in.
untracked_sensitive=$(git status --porcelain 2>/dev/null \
    | awk '$1=="??"{$1=""; print substr($0,2)}' \
    | grep -Ei "$SENSITIVE_NAME_RE" || true)
if [ -n "$untracked_sensitive" ]; then
    while IFS= read -r f; do
        case "$f" in *.example|*.sample|*.template|*.dist) continue ;; esac
        say_warn "untracked sensitive file (not published, but unprotected): $f"
    done <<< "$untracked_sensitive"
fi

# --------------------------------------- 7. contributor emails (info) --------
section "7. Contributor emails (will be public)"
emails=$(git log --all --format='%ae' 2>/dev/null | sort -u)
if [ -n "$emails" ]; then
    while IFS= read -r e; do say_info "author email: $e"; done <<< "$emails"
else
    say_info "no commits yet"
fi

# ---------------------------------------------------------------- verdict ----
echo
echo "------------------------------------------------------------"
echo "Findings: ${RED}$FAIL blocking${RST}, ${YEL}$WARN warnings${RST}"
if [ "$FAIL" -gt 0 ]; then
    echo "${RED}VERDICT: NOT SAFE to make public — resolve [FAIL] items first.${RST}"
    exit 2
elif [ "$WARN" -gt 0 ]; then
    echo "${YEL}VERDICT: No blockers found, but review [WARN] items before publishing.${RST}"
    exit 0
else
    echo "${GRN}VERDICT: No issues matched. Still review by hand — this is heuristic.${RST}"
    exit 0
fi
