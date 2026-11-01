# scripts/provisioning

Bare-metal installers and tools; the scripts here run as root on the target host. The LAMP installers and the Gitea tighten scripts end with a verification pass; the Jenkins installer waits for Jenkins to answer on port 8080 before printing the initial admin password; the LUKS guardian has no verify mode (see below).

## 📦 Contents

- [🛠️ Gitea (bare metal)](#-gitea-bare-metal)
   - [Which variant](#which-variant)
   - [Required order](#required-order)
   - [What the tighten scripts do](#what-the-tighten-scripts-do)
- [🛠️ LAMP (bare metal)](#-lamp-bare-metal)
- [🔭 neo1 observability (native systemd)](#-neo1-observability-native-systemd)
- [🔒 LUKS Vault Guardian](#-luks-vault-guardian)
   - [Before running](#before-running)
   - [What one run does](#what-one-run-does)
   - [Verifying and restoring](#verifying-and-restoring)
- [🔗 Jenkins](#-jenkins)
- [🛠️ Proxmox VE](#-proxmox-ve)

## 🛠️ Gitea (bare metal)

A hardened Gitea 1.26.4 deployment under systemd, using Gitea's
built-in SSH server (web on port 3000, SSH on port 2222). Four scripts
form two matched pairs:

| Variant | Installer | Post-setup |
| --- | --- | --- |
| Standard | `install-gitea.sh` | `post-setup-tighten-gitea.sh` |
| SD endurance | `install-gitea-sd.sh` | `post-setup-tighten-gitea-sd.sh` |

Both installers support Debian-family and RHEL-family systems on
amd64, arm64, and arm-6. Both download the pinned binary and its
checksum from dl.gitea.com and verify the SHA-256 before installing to
`/usr/local/bin/gitea`. Both create a `git` system user with a nologin
shell, seed `/etc/gitea/app.ini`, and write the same hardened systemd
unit (sandboxing, `ProtectSystem=full`, empty capability bounding set,
seccomp filter). Neither makes firewall changes. The SD installer ends by printing the `firewall-cmd` commands for ports 3000 and 2222 for firewalld nodes; the standard installer prints no firewall commands, only a note that none were made.

### Which variant

Use the SD variant on any node whose root filesystem is on an SD or
MMC card. It detects that itself (it walks the root device's ancestor
chain, so LUKS or LVM stacked on SD is caught), and
`SD_OPTIMIZE=1` or `SD_OPTIMIZE=0` forces the behavior either way. On NVMe or SSD roots the flash measures below are skipped, but the SD installer still differs from the standard one there: it always seeds `app.ini` with SQLite WAL mode and the single console/Warn log sink, and always creates the `/var/lib/gitea/dump/` staging directory. Its flash
measures are:

- zram swap (1G, zstd when the kernel offers it) replacing disk swap,
  skipped gracefully if the kernel lacks the zram module.
- `noatime` on `/` and flash swap retired in `/etc/fstab`. Fstab edits
  are staged, verified with `findmnt --verify`, and only then swapped
  in; the original is kept at `/etc/fstab.bak.<epoch>`. Noatime takes
  effect at the next reboot.
- A bounded persistent journald (100M, one month) and a 512M tmpfs on
  `/tmp`.
- `app.ini` seeded with SQLite WAL journal mode and a single console
  log sink at Warn level, plus a `/var/lib/gitea/dump/` staging
  directory for backups.

### Required order

1. Run the installer for your variant, as root.
1. Complete the first-run web installer at `http://<host>:3000`. The
   seeded unit deliberately leaves `/etc/gitea` in `ReadWritePaths`
   and `app.ini` group-writable (660) because the web installer needs
   to write the config.
1. Create a canary repository in the Gitea UI (empty is fine) and
   upload the SSH public key of the user who will run the tighten
   script (normally root) to an account with write access to it.
1. Run the matching tighten script, once per node, as root, with the
   canary set:

   ```bash
   export TEST_REPO="michael/canary"
   export GITEA_HOST="127.0.0.1"
   ./post-setup-tighten-gitea.sh
   ```

   `TEST_REPO` is `<owner>/<repo>` with no `.git` suffix. `GITEA_HOST`
   is optional and defaults to 127.0.0.1; `SSH_PORT` and `HTTP_PORT`
   can also be overridden.

### What the tighten scripts do

Both variants tighten, then verify, in order:

1. `chmod 640 /etc/gitea/app.ini` and remove `/etc/gitea` from the
   unit's `ReadWritePaths`, then restart Gitea (daemon-reload alone
   does not rebuild the mount namespace).
1. Verify the lockdown: `ReadWritePaths` no longer lists `/etc/gitea`,
   the `git` user cannot write `app.ini`, and the service is active.
1. Canary under the final sandbox: HTTP answers on port 3000 (wget,
   with retries), an SSH clone of the canary repo succeeds, and a push
   succeeds. The push is the critical probe because it traverses the
   server-side hook chain, the child-exec path the seccomp filter
   could plausibly break. The clone uses
   `StrictHostKeyChecking=accept-new`; pin known_hosts afterward on
   long-lived nodes.
1. Sweep the journal since the restart for seccomp or namespace
   denials (`EPERM`, `SIGSYS`, `operation not permitted`,
   `read-only file system`). Any hit fails the run.
1. Print the `systemd-analyze security` summary where available
   (systemd 240+; on older systemd this degrades to a notice).

Exit code 0 means every gate passed and the node is clear for fleet
rollout; 1 names the failed gate. The scripts are idempotent and safe
to re-run.

The SD tighten script adds two steps:

- A WAL verification: it reads `PRAGMA journal_mode` from
  `/var/lib/gitea/data/gitea.db` and warns (does not fail) if the
  answer is not `wal`. It is skipped with a notice if the database is
  not SQLite at the default path.
- The backup cycle: a `gitea-dump.service` and `gitea-dump.timer`
  (nightly 03:00, `Persistent=true`, up to 5 minutes randomized delay)
  that dumps to `/var/lib/gitea/dump/` with 7-day local retention, and
  runs one dump immediately to prove the cycle works. The dumps live
  on the same SD card; they are staging only. Pull them off-node
  before calling the node backed up.

### The controller: gitea-control-v1.0.sh

One script owns the whole lifecycle, in the neo1 observability
controller's shape. Verbs: `install`, `tighten`, `up`, `down`,
`restart`, `status`, and `uninstall`, each taking
`--form native`, `--form sd`, or `--form container`. The native forms
run the installer and tighten scripts above as-is (nothing is
reimplemented); the container form wraps `docker compose` in
`containers/gitea`. `uninstall` prints a labeled plan before touching
anything, needs the typed confirmation `gitea`, preserves
`/var/lib/gitea` and the `git` account by default (the `gitea_data`
volume on the container form), and removes that data only with
`--purge`. On the SD form it also removes the dump timer units the SD
tighten script installed; the SD installer's host tuning (zram swap,
fstab edits, journald drop-in) is host configuration and is left in
place. `--dry-run` prints the plan and changes nothing. Every verb's
header output and exit codes are documented in the script's own
READ THIS block. The Ansible playbook
(`ansible/playbooks/gitea/install_gitea.yml`) stays a parallel
install path and is not wrapped.

## 🛠️ LAMP (bare metal)

Two distro-specific installers for the same stack: Apache, PHP-FPM,
and MariaDB, installed from distro packages and enabled under systemd.
Both must run as root, and both finish with the same verification
block (versions, service states, a throwaway PHP probe page fetched
through Apache and removed afterward, and a MariaDB socket-auth
`SELECT VERSION()`).

| | Debian | Rocky |
| --- | --- | --- |
| Script | `lamp-install-debian13.sh` | `lamp-install-rocky10.sh` |
| Target | pi2, Debian 13 (trixie), ARM64 | pi3, Rocky 10.x, ARM64, SELinux enforcing |
| Web server | apache2 2.4 | httpd 2.4 |
| PHP | 8.4 (distro default) | 8.3 (AppStream default) |
| MariaDB | 11.8 (distro default) | 10.11 (full-life stream, EOL 2035) |
| PHP wiring | Detects the installed PHP version, then `a2enmod proxy_fcgi setenvif` and `a2enconf php<version>-fpm` | AppStream module defaults |
| Firewall | UFW: allows 80 and 443 only if UFW is already active | firewalld: adds the http and https services if firewalld is active |

The Rocky MariaDB choice is deliberate. The unversioned
`mariadb-server` package on EL10 is the 10.11 full-life stream; the
newer 11.8 stream ships as `mariadb11.8-server` and is not what this
installer wants. The verification block enforces it: the run fails if
`mariadb --version` does not report a 10.11 version. The Rocky script
also runs `restorecon` on its probe page and prints `getenforce` as
part of verification.

For the Ansible form of the same stack, see
`ansible/playbooks/lamp/` (one playbook, distro-conditional tasks
reconciling both installers). For the container form, see
`containers/lamp/`.

## 🔭 neo1 observability (native systemd)

`neo1-observability-native/` is a kit, not a single installer: the
bare-metal form of the neo1 observability node (512 MB ARMv7, Armbian)
with its configs, hardened systemd units, and helper scripts in one
folder. Prometheus, Alertmanager, blackbox_exporter, node_exporter,
and ntfy run as checksum-pinned static binaries; Grafana is on-demand
only (never enabled, auto-stops after 6h); two timers pull nightly
Pi-hole and Unbound backups from pi4/pi0. `scripts/install.sh` in the
kit refuses to run with any pin blanked, installs promtool/amtool
beside their daemons, and ends by enabling the always-on set plus the two backup timers. The
kit's own README carries the deploy order and the memory budget.

The Docker form of the same design lives in
`containers/neo1-observability-docker/`; the cluster's multi-service
standby stack is `containers/monitoring/`.

## 🔒 LUKS Vault Guardian

`luks_vault_guardian.sh` backs up LUKS2 headers for the configured
drives, fingerprints them with SHA-256, and packs the result into a
single passphrase-encrypted 7z archive. It protects the header (the
master key material) rather than imaging the whole disk. It never
touches user data.

### Before running

- Run as root. The script reads raw LUKS block devices and refuses to
  run otherwise.
- Edit the configuration block at the top of the script first.
  `TARGET_DRIVES` defaults to `/dev/nvme0n1p3`. `STAGING_DIR` defaults
  to `/media/secure-backup/luks_headers` and must be a mounted external
  mount point; the script exits if it is not one. The staging directory
  is created mode 700 if missing. The log is `/var/log/luks_guardian.log`
  (created mode 600).
- 7z is the only dependency. If `7z` is missing, the script installs it
  (p7zip-full via apt, or p7zip via dnf after enabling EPEL, or p7zip
  via yum).

### What one run does

1. For each drive in `TARGET_DRIVES`: skip it with a log line if it is
   not a block device or not LUKS. Otherwise write three files into
   staging, each mode 600: a `cryptsetup luksDump` text layout, the
   binary header from `cryptsetup luksHeaderBackup`, and a
   `.sha256` verification file covering both. If extraction fails for
   a drive, the partial files are deleted and the script exits 1.
1. Archive everything in staging into
   `luks_headers_vault_<timestamp>.7z` in the staging directory
   (LZMA2, maximum compression, `-mhe=on` so archive filenames are
   encrypted too). 7z prompts interactively for the passphrase; it is
   never stored on the system.
1. Set the archive mode 600 and delete every other file in staging, so
   no unencrypted header material persists.

The passphrase is a second lock, separate from the disk passwords: per
the script header, it must differ from the actual drive passphrases.
Sync the resulting `.7z` off the machine with an unprivileged account
(the header's model is luckybackup or rclone run as the regular user),
keeping the privileged backup step and the unprivileged sync step
separate.

### Verifying and restoring

The script has no verify or restore mode. Bit-rot checking is manual:
extract the archive, then run `sha256sum -c` against the
`*_verification_*.sha256` file inside it and confirm both the layout
dump and the header image still match the fingerprints taken at backup
time. Restoring a header is also manual, with cryptsetup against the
extracted `.img` file:

```bash
cryptsetup luksHeaderRestore <device> --header-backup-file <device>_header_<timestamp>.img
```

Treat the archive as key material: a LUKS header backup plus a drive
passphrase is enough to unlock the disk.

## 🔗 Jenkins

`install-jenkins-rocky.sh` installs Jenkins LTS on Rocky Linux 8, 9,
or 10. Its guide is `jenkins-consolidated-v1.0.md` in this folder. Run
the installer with `--help` for its options (Java version selection,
the optional JNLP agent port, and a no-firewall mode).

`jenkins-control-v1.0.sh` is the lifecycle controller for the Jenkins
forms. Its `install` verb runs the bash installer as-is (installer
options pass through after a `--` separator), `up`, `down`, `restart`,
and `status` drive the service, and `uninstall` removes the package
footprint while preserving `/var/lib/jenkins` unless `--purge` is
given. With `--form container` the same verbs drive the compose
stack in `containers/jenkins`. The Ansible install and uninstall
playbooks stay parallel paths; the controller's native removal set
matches the uninstall playbook's footprint.

## 🛠️ Proxmox VE

`proxmox-setup.sh` is the bash form of the Proxmox VE deployment in
`ansible/playbooks/proxmox/`: one subcommand per playbook (`install`,
`configure`, `prep`, `templates-cloudinit`, `templates-turnkey`, or
`all` for the full sequence), run as root on the target host, with
the same values, checks, and defaults as the playbooks. Every
subcommand accepts `--dry-run`; the `api-check` subcommand validates
an API token against the Proxmox REST API. There is no Docker form —
Proxmox VE is a bare-metal hypervisor. The full mapping and run
order are in the Proxmox playbooks' README. Run `prep` or `all` on
a terminal with no setting flags and the script first opens a
pre-flight panel listing the prep settings (NFS storage, server
and export, the firewall toggle, the management CIDR, the notify
email, and a dry-run toggle) to confirm or adjust before anything
runs; any setting flag, or no terminal, runs directly as before.
