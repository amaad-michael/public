#!/usr/bin/env bash
# Grant or revoke sudo for a user via a drop-in file in /etc/sudoers.d/.
# Idempotent; the snippet is validated with visudo before install and
# the full sudoers tree is validated again afterwards.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo-manage-local.sh USERNAME (--grant | --revoke) [--commands "cmd1, cmd2"] [--check]

  Grant sudo (drop-in /etc/sudoers.d/90-<user>) or revoke it by removing
  the drop-in. Idempotent.

Options:
  USERNAME               Login name (required).
  --grant                Create the sudoers drop-in.
  --revoke               Remove the sudoers drop-in.
  --commands "c1, c2"    Comma-separated command list (full paths) the user
                         may run via sudo. Default: ALL (unrestricted).
  --check                Dry-run: print what would be done, change nothing.
  --help                 Show this help.

Examples:
  sudo-manage-local.sh deploy --grant
  sudo-manage-local.sh deploy --grant --commands "/usr/bin/systemctl restart nginx, /usr/bin/apt-get update"
  sudo-manage-local.sh deploy --revoke --check
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

USERNAME=""
GRANT=0
REVOKE=0
COMMANDS="ALL"
CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --grant)    GRANT=1; shift ;;
    --revoke)   REVOKE=1; shift ;;
    --commands) COMMANDS="${2:?--commands requires a value}"; shift 2 ;;
    --check)    CHECK=1; shift ;;
    --help)     usage; exit 0 ;;
    --*)        warn "unknown option: $1"; usage; exit 2 ;;
    *)          if [[ -n "$USERNAME" ]]; then warn "unexpected argument: $1"; usage; exit 2; fi
                USERNAME="$1"; shift ;;
  esac
done

[[ -n "$USERNAME" ]] || { warn "USERNAME is required"; usage; exit 2; }
if [[ "$GRANT" -eq "$REVOKE" ]]; then
  warn "pass exactly one of --grant or --revoke"
  usage; exit 2
fi

DROPIN="/etc/sudoers.d/90-$USERNAME"

# Normalize the command list: "a, b" -> "a, b" (trim whitespace), reject
# anything that could break sudoers syntax.
normalize_commands() {
  local raw="$1" item out=""
  if [[ "$raw" == "ALL" ]]; then
    printf 'ALL\n'
    return 0
  fi
  IFS=',' read -ra parts <<<"$raw"
  for item in "${parts[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"   # ltrim
    item="${item%"${item##*[![:space:]]}"}"   # rtrim
    [[ -n "$item" ]] || continue
    # Absolute path, optional arguments allowed; sudoers-reserved characters
    # (comma already split, plus ':' '=' '!') are rejected.
    if ! [[ "$item" =~ ^/[^,:=!]+$ ]]; then
      warn "unsafe command in --commands: '$item' (absolute paths, optional args; no ',', ':', '=', '!')"
      exit 2
    fi
    out+="$item, "
  done
  out="${out%, }"                             # drop trailing comma
  [[ -n "$out" ]] || { warn "--commands produced an empty command list"; exit 2; }
  printf '%s\n' "$out"
}

render_grant() {
  local cmds
  cmds="$(normalize_commands "$COMMANDS")"
  printf '%s ALL=(ALL:ALL) %s\n' "$USERNAME" "$cmds"
}

if [[ "$GRANT" -eq 1 ]]; then
  if ! id "$USERNAME" &>/dev/null; then
    warn "user $USERNAME does not exist; refusing to grant sudo"
    exit 1
  fi
  tmp="$(mktemp)"
  render_grant >"$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn "generated sudoers snippet failed visudo -cf; refusing to install"
    exit 1
  fi
  if [[ -f "$DROPIN" ]] && cmp -s "$tmp" "$DROPIN"; then
    log "drop-in $DROPIN already correct; nothing to do"
    rm -f "$tmp"
    exit 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would install $DROPIN with:"
    cat "$tmp"
    rm -f "$tmp"
    exit 0
  fi
  install -m 0440 "$tmp" "$DROPIN"
  rm -f "$tmp"
  if ! visudo -c >/dev/null 2>&1; then
    warn "visudo -c reports errors after installing $DROPIN; removing it"
    rm -f "$DROPIN"
    exit 1
  fi
  log "sudo granted: $DROPIN"
else
  if [[ ! -f "$DROPIN" ]]; then
    log "no drop-in $DROPIN; nothing to revoke"
    exit 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would remove $DROPIN"
    exit 0
  fi
  rm -f "$DROPIN"
  if ! visudo -c >/dev/null 2>&1; then
    warn "visudo -c reports errors after removing $DROPIN (other files may be broken)"
    exit 1
  fi
  log "sudo revoked: $DROPIN removed"
fi
