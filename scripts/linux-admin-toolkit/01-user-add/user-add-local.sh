#!/usr/bin/env bash
# Create (or remove) a local user, optionally installing an SSH public key
# and granting sudo. Idempotent.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: user-add-local.sh USERNAME [--ssh-key KEY|KEYFILE] [--sudo] [--remove] [--remove-home] [--check]

  Create a user, optionally with an SSH public key and sudo access.
  Idempotent: if the user exists, missing pieces are added instead of failing.

Options:
  USERNAME            Login name to create/remove (required).
  --ssh-key KEY       SSH public key text, or path to a .pub file, to install
                      in ~/.ssh/authorized_keys for the new user.
  --sudo              Grant full sudo via /etc/sudoers.d/90-<user>
                      (validated with visudo before install).
  --remove            Delete the user instead of creating them.
  --remove-home       With --remove, also remove the home directory and mail spool.
  --check             Dry-run: print what would be done, change nothing.
  --help              Show this help.

Examples:
  user-add-local.sh deploy --ssh-key ~/.ssh/id_ed25519.pub --sudo
  user-add-local.sh olduser --remove --remove-home --check
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

USERNAME=""
SSH_KEY=""
SUDO=0
REMOVE=0
REMOVE_HOME=0
CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key)     SSH_KEY="${2:?--ssh-key requires a value}"; shift 2 ;;
    --sudo)        SUDO=1; shift ;;
    --remove)      REMOVE=1; shift ;;
    --remove-home) REMOVE_HOME=1; shift ;;
    --check)       CHECK=1; shift ;;
    --help)        usage; exit 0 ;;
    --*)           warn "unknown option: $1"; usage; exit 2 ;;
    *)             if [[ -n "$USERNAME" ]]; then warn "unexpected argument: $1"; usage; exit 2; fi
                   USERNAME="$1"; shift ;;
  esac
done

[[ -n "$USERNAME" ]] || { warn "USERNAME is required"; usage; exit 2; }

# Validate username against login.defs rules (portable subset).
if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "$USERNAME" =~ ^[.-] ]] || [[ "$USERNAME" =~ [.-]$ ]]; then
  warn "invalid username: $USERNAME"
  exit 2
fi

# Resolve key text: accept literal key text or a path to a key file.
resolve_key() {
  local in="$1"
  if [[ -f "$in" ]]; then
    cat "$in"
  else
    printf '%s\n' "$in"
  fi
}

KEY_TEXT=""
if [[ -n "$SSH_KEY" ]]; then
  KEY_TEXT="$(resolve_key "$SSH_KEY")"
  if ! grep -Eq '^(ssh-(rsa|ed25519|dss|ecdsa)|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519|sk-ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/=]+' <<<"$KEY_TEXT"; then
    warn "the value given to --ssh-key does not look like a valid SSH public key"
    exit 2
  fi
fi

user_exists() { id "$USERNAME" &>/dev/null; }

install_key() {
  local home sshdir authkeys
  home="$(getent passwd "$USERNAME" | cut -d: -f6 || true)"
  if [[ -z "$home" ]]; then
    if [[ "$CHECK" -eq 1 ]]; then
      home="/home/$USERNAME"   # useradd -m default for the new user
    else
      warn "cannot determine home directory for $USERNAME"
      exit 1
    fi
  fi
  sshdir="$home/.ssh"
  authkeys="$sshdir/authorized_keys"

  if [[ -f "$authkeys" ]] && grep -qxF "$KEY_TEXT" "$authkeys" 2>/dev/null; then
    log "key already present in $authkeys"
    return 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would append SSH key to $authkeys"
    return 0
  fi
  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$sshdir"
  printf '%s\n' "$KEY_TEXT" >>"$authkeys"
  chmod 600 "$authkeys"
  chown "$USERNAME:$USERNAME" "$authkeys"
  log "SSH key installed in $authkeys"
}

install_sudo() {
  local dropin="/etc/sudoers.d/90-$USERNAME"
  local tmp
  tmp="$(mktemp)"
  printf '%s ALL=(ALL:ALL) ALL\n' "$USERNAME" >"$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    warn "generated sudoers snippet failed visudo -cf; refusing to install"
    exit 1
  fi
  if [[ -f "$dropin" ]] && cmp -s "$tmp" "$dropin"; then
    log "sudoers drop-in $dropin already correct"
    rm -f "$tmp"
    return 0
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would install sudoers drop-in $dropin (validated by visudo)"
    rm -f "$tmp"
    return 0
  fi
  install -m 0440 "$tmp" "$dropin"
  rm -f "$tmp"
  if ! visudo -c >/dev/null 2>&1; then
    warn "visudo -c reports errors after installing $dropin; removing it"
    rm -f "$dropin"
    exit 1
  fi
  log "sudo granted via $dropin"
}

if [[ "$REMOVE" -eq 1 ]]; then
  if ! user_exists; then
    log "user $USERNAME does not exist; nothing to remove"
    exit 0
  fi
  if [[ "$SUDO" -eq 1 ]]; then
    warn "--sudo is ignored with --remove"
  fi
  if [[ "$REMOVE_HOME" -eq 1 ]]; then
    if [[ "$CHECK" -eq 1 ]]; then
      log "[check] would run: userdel -r $USERNAME"
    else
      userdel -r "$USERNAME"
      log "user $USERNAME removed with home directory"
    fi
  else
    if [[ "$CHECK" -eq 1 ]]; then
      log "[check] would run: userdel $USERNAME (home left in place)"
    else
      userdel "$USERNAME"
      log "user $USERNAME removed (home directory left in place)"
    fi
  fi
  # Clean up the toolkit's own sudo drop-in if present.
  if [[ -f "/etc/sudoers.d/90-$USERNAME" ]]; then
    if [[ "$CHECK" -eq 1 ]]; then
      log "[check] would remove /etc/sudoers.d/90-$USERNAME"
    else
      rm -f "/etc/sudoers.d/90-$USERNAME"
      log "removed /etc/sudoers.d/90-$USERNAME"
    fi
  fi
  exit 0
fi

# --- Create path ---
if user_exists; then
  log "user $USERNAME already exists; ensuring requested state"
else
  if [[ "$CHECK" -eq 1 ]]; then
    log "[check] would run: useradd -m -s /bin/bash $USERNAME"
  else
    useradd -m -s /bin/bash "$USERNAME"
    log "user $USERNAME created"
  fi
fi

if [[ -n "$KEY_TEXT" ]]; then
  install_key
fi

if [[ "$SUDO" -eq 1 ]]; then
  install_sudo
fi

log "done"
