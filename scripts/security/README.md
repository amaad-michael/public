# scripts/security

Server hardening scripts, the SSH key toolkit, and the
pre-publication repo scanner.

## secure-server-init family

Six scripts, three variants in two versions each, that take a fresh
Debian-family or RHEL-family install to a hardened baseline. All six
are run as root on the target, right after a clean install.

### Pre-flight (read before running anything)

The standard and conservative variants disable SSH password
authentication. If key-based access is not already working, running
one of them locks you out of SSH, and recovery needs physical or
console access. Every standard and conservative script carries this
same pre-flight in its header:

1. On your local machine, confirm you have a key
   (`ls -la ~/.ssh/id_ed25519.pub`), or generate one:
   `ssh-keygen -t ed25519 -a 100 -C 'michael@hostname'`.
1. Copy the public key to the target before running the script:
   `ssh-copy-id -i ~/.ssh/id_ed25519.pub michael@<server-ip>`.
1. Test key-based login in a separate terminal:
   `ssh -i ~/.ssh/id_ed25519 michael@<server-ip>`.
1. Run the script only after that login works, and test again in a
   second terminal before closing the session you ran it from.

The legacy variant keeps password authentication, so it has no
lockout pre-flight; its compensating controls are listed below.

### What every variant does

- Detects the distro (debian or ubuntu map to the Debian path; rhel,
  rocky, almalinux, centos, and fedora to the RHEL path) and stops on
  anything else.
- Updates all packages, then disables automatic patching (removes
  unattended-upgrades or dnf-automatic and zeroes the periodic update
  settings).
- Creates the user `michael` if missing, with a NOPASSWD sudoers
  drop-in at `/etc/sudoers.d/michael`.
- Writes the SSH policy as a drop-in,
  `/etc/ssh/sshd_config.d/99-hardening.conf`, validates it with
  `sshd -t`, and restarts SSH. Login is restricted to `AllowUsers
  michael` in every variant.
- Configures the firewall as a whitelist with port 22 only: UFW
  (reset, default deny incoming) on Debian, firewalld (public zone,
  ssh service) on RHEL.
- Installs fail2ban with an sshd jail, auditd with watch rules on the
  passwd, shadow, and sudoers files, the sshd config, and root
  executions, and lynis for follow-up audits.
- Configures daily log rotation for the auth log, reports the
  AppArmor or SELinux status, and disables IPv6 by sysctl.
- Applies the Pi cluster personalization: appends the cluster hosts
  (pi0 to pi4 and neo1, 192.168.0.100 to 105) to `/etc/hosts` and
  installs a fastfetch MOTD with the same host list. The username and
  these hosts are baked into the scripts; adapt them before running
  anywhere else.

### Variant selection

All three variants use the same skeleton. They differ in the SSH
cryptography and authentication policy (the scripts call the modern
algorithm set the Bernstein stack: Ed25519, Curve25519,
ChaCha20-Poly1305, and the post-quantum hybrid
sntrup761x25519-sha512).

| | Standard | Conservative | Legacy |
| --- | --- | --- | --- |
| Files | `secure-server-init-v1.sh`, `secure-server-init-v1.1.sh` | `secure-server-init-conservative-v1.sh`, `secure-server-init-conservative-v1.1.sh` | `secure-server-init-legacy-v1.sh`, `secure-server-init-legacy-v1.1.sh` |
| Use when | Modern OpenSSH on both ends | Clients cannot do the post-quantum key exchange | Old OpenSSH that needs password auth and RSA |
| Password auth | No | No | Yes |
| Root login | No | Key only (`prohibit-password`) | No |
| Host key | Ed25519 only | Ed25519 only | RSA-4096 (generated if missing or undersized) |
| Key exchange | sntrup761x25519 hybrid, Curve25519 | Curve25519 only | DH group exchange and group14, SHA-256 |
| Ciphers | ChaCha20-Poly1305, AES-256-GCM | ChaCha20-Poly1305 only | AES-CTR (256, 192, 128) |
| MACs | HMAC-SHA2-512 and 256, ETM | HMAC-SHA2-256, ETM and plain | HMAC-SHA2-512 and 256, no ETM |
| MaxAuthTries | 3 | 4 | 5 |
| fail2ban sshd jail | 3 retries, 20 minute ban | 3 retries, 20 minute ban | 5 retries, 30 minute ban |

Conservative is the compatibility step down from standard: it drops
the post-quantum key exchange, the AES-GCM cipher, and the SHA-512
MAC, and it adds explicit forwarding restrictions (`X11Forwarding`,
`AllowAgentForwarding`, `AllowTcpForwarding` all no). Its own summary
states the trade: compatibility over post-quantum resistance.

Legacy is for systems whose OpenSSH is too old for the modern stack.
It accepts password or public-key authentication
(`AuthenticationMethods password publickey`) and adds the controls
that password auth needs: a pwquality policy (minimum length 14, all
four character classes required, enforcing) and pam_faillock account
lockout (5 failures locks the account for 900 seconds). Set the
`michael` password immediately after running it
(`sudo passwd michael`), and watch fail2ban with
`fail2ban-client status sshd`.

### v1 versus v1.1

Within each variant, v1.1 changes two things relative to v1:

- The auditd rules also watch the SSH host key files (the Ed25519 key
  pair, or the RSA pair in legacy).
- Log rotation tightens for SD-card systems: the auth log rotates at
  14 days instead of 30, with mode 600 on the rotated file, and a
  second logrotate entry covers `/var/log/audit/audit.log` the same
  way. Note that the v1.1 scripts' own end-of-run summary still prints
  the old 30-day line; the written config is 14 days.

Legacy v1.1 also sets sshd `LogLevel INFO` where v1 used `VERBOSE`.

After any variant, run `sudo lynis audit system` for the follow-up
audit, as the scripts themselves suggest.

## SSH access toolkit

The scripts that move keys between a workstation and the fleet. The
fleet in every script is pi0 to pi4 plus neo1 at 192.168.0.100 to 105,
and the login user is `michael`.

### New workstation, in order

1. Controller setup: `ssh-setup-new-box-v1.0.sh` (Rocky-family boxes;
   it uses dnf). It installs keychain (enabling EPEL if the package is
   not in the enabled repos), adds the keychain eval line to
   `~/.bashrc`, generates `~/.ssh/id_ed25519` if missing, loads the
   key into the persistent agent (passphrase asked once), and copies
   the public key to all six nodes with ssh-copy-id. Idempotent; safe
   to re-run.
1. If the workstation already has a key and agent setup, use
   `send_keys.sh` instead for step one's copy phase. It loops the six
   hosts with ssh-copy-id, prompting for the `michael` password on
   each host unless the key is already installed, and skips hosts that
   already carry the key. Note that it reads `~/.ssh/id_rsa.pub`
   specifically, while `ssh-setup-new-box-v1.0.sh` works with
   ed25519; point the file variable at the right public key before
   running.
1. Pre-trust the fleet: `add_known_hosts.sh` appends an ssh-keyscan of
   every host to `~/.ssh/known_hosts` (hashed), so first connections
   do not stop at the confirmation prompt. It appends blindly:
   re-running duplicates entries, and if a host was rebuilt, clean its
   old entries out of the file first.
1. One host outside the fleet (a new VPS, a rebuilt box):
   `./setup_key_access.sh <remote_ip>`. It logs in as `michael` over
   SSH and appends this machine's `~/.ssh/id_rsa.pub` to the remote
   `~/.ssh/authorized_keys`, creating the directory with mode 700 and
   the file with mode 600 if needed. Re-running appends a duplicate
   key line: harmless but untidy.

### export_ssh.sh: host identity backup

Run on a host, as root, when that host's SSH identity needs to survive
a rebuild. It collects, into a staging directory under `/tmp`:

- `host_keys/`: every `/etc/ssh/ssh_host_*` file (public and private
  keys) plus `sshd_config`.
- `user_keys/<user>/`: the `authorized_keys` of root and of every user
  under `/home`.
- `SOURCE_IDENTITY.txt`: hostname, export date, OS version, SSH
  version.
- `selinux_contexts.txt` on RHEL-family systems only: the SELinux
  contexts of the host keys.

It then writes `ssh-backup-<hostname>-<timestamp>.tar.gz` into the
current directory, mode 600, verifies the tarball lists cleanly, and
writes a `.tar.gz.sha256` checksum file beside it. The staging
directory is deleted.

Handle the tarball as private key material: it contains the host's
private keys, and it is not encrypted. No restore script ships in this
folder; the layout above is the restore map (checksum first, then
host keys back to `/etc/ssh`, authorized_keys back to each user's
`.ssh`, SELinux contexts reapplied on RHEL-family targets).

## ⚠️ ssh-reset-defaults.sh: destructive, last resort only

This is not part of the bootstrap flow above. `ssh-reset-defaults.sh`
is recovery for a host whose SSH configuration is mangled beyond
repair, and it wipes the current hardening to get a known-good distro
baseline back. Run it as root, from the local console or an
out-of-band method, never over the SSH session it is about to restart.

What it does, in order:

1. Backs up the current config files and host key pairs, plus
   `/etc/ssh/ssh_known_hosts` and `/root/.ssh/authorized_keys`, to
   `/root/ssh_backup`. Verify that backup exists before relying on
   the reset.
1. Overwrites `/etc/ssh/sshd_config`, `/etc/ssh/ssh_config`, and
   `/etc/ssh/moduli` from `/usr/share/openssh/sshd_config`.
1. Regenerates any missing host key pairs (RSA, ECDSA, Ed25519).
   Existing keys are kept.
1. Empties `/etc/ssh/ssh_known_hosts` and
   `/root/.ssh/authorized_keys`. Key-based root login is gone until
   keys are re-added, and clients will see host key warnings wherever
   keys changed.
1. Restarts sshd.

After a reset, re-harden with the secure-server-init variant that
fits the host, then rebuild key access with the toolkit above.

## repo-public-check.sh

A read-only heuristic scan to run before a repo goes public. It scans
tracked files and, unless told otherwise, the full git history,
because deleted content stays in history.

```bash
./repo-public-check.sh [--no-history] [path-to-repo]
```

With no path it scans the current directory. It must be a git repo,
and git must be installed; both failures are exit 1, as is an unknown
option. `-h` or `--help` prints the header comment and usage.

What it checks, in seven sections:

1. Sensitive filenames among tracked files: `.env` files, `.pem`,
   `.key`, `.p12`, `.pfx`, private key filenames (`id_rsa`, `id_dsa`,
   `id_ecdsa`, `id_ed25519`), `credentials.json`, `secret(s).yml` or
   `.yaml`, and vault password files. Names ending in `.example`,
   `.sample`, `.template`, or `.dist` are treated as intentional
   templates and skipped.
1. Secret patterns in current tracked files: AWS access keys and
   secret key assignments, GitHub, GitLab, Slack, and Stripe tokens,
   private key blocks, PuTTY key files, URLs with embedded
   credentials, and generic password and API key assignments.
1. The same secret patterns across all of git history, deduplicated so
   one leaked line prints once rather than once per commit. Findings
   here need `git filter-repo` or BFG to purge; deleting the file is
   not enough.
1. Internal hostnames and private IPs in current files: names under
   internal-style suffixes (`.internal`, `.corp`, `.intranet`, `.lan`,
   `.local`, `.home.arpa`, `.invalid`) and RFC1918 addresses. These
   are warnings, not blockers.
1. Oversized blobs across all history: warn at 50MB, fail at 100MB
   (the GitHub hard block).
1. `.gitignore` hygiene: warns if there is no root `.gitignore` or it
   does not cover `.env`, and warns about untracked sensitive-named
   files that a careless `git add -A` could sweep in.
1. Contributor emails: every author email in history, listed as info,
   because they become public with the repo.

Two safeguards on the output itself: placeholder-looking values
(`changeme`, `example`, `<...>` spans, template expressions, and
similar) are filtered out before reporting, and matched secrets are
masked to `<redacted>`, so the output is safe to share.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | No blocking findings. Warnings may exist; review them before publishing |
| 2 | Blocking findings. Do not make the repo public until they are resolved |
| 1 | Usage or environment error (not a git repo, git missing, bad option) |

The scan is heuristic, as its header states: a clean verdict means
nothing matched known patterns, not that the repo is provably safe.
Every finding needs human review. The nightly public-repo audit runs
this script as its security pass, and it is worth running by hand
before any repo changes visibility.
