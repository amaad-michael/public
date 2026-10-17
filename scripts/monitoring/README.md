# scripts/monitoring

Three standalone checkers. Two collect cron configuration (one host at
a time, or the whole fleet over SSH); the third verifies backup
integrity with SHA-256 manifests. None of them change anything on the
hosts they inspect.

## local_cron_checker.sh

Run on the host it audits. It collects, in one file:

- User crontabs for every account with UID 1000 or higher and a bash
  or sh login shell (`crontab -u <user> -l`)
- `/etc/crontab`
- Every file in `/etc/cron.d/`
- Listings of `/etc/cron.hourly`, `/etc/cron.daily`,
  `/etc/cron.weekly`, and `/etc/cron.monthly`

Output: `/var/log/cron_audit/local_cronjobs_YYYYMMDD_HHMMSS.log`,
created with mode 600. Reading other users' crontabs and writing
under `/var/log` require root.

## remote_cron_checker.sh

Run from one host; it SSHes to the six fleet addresses
(192.168.0.100 to 105, pi0 to pi4 and neo1) and collects the same
material from each into a single file,
`/var/log/cron_audit/cronjobs_full_YYYYMMDD_HHMMSS.log`, with one
section per host. A host that fails the 10-second SSH check is logged
as an error and skipped. One difference from the local checker: the
remote version collects crontabs for all users with UID 1000 or
higher, without the login-shell filter.

Both checkers suit an on-demand or scheduled audit. Every run writes
a new timestamped file; nothing is overwritten, so the directory
becomes the audit history.

## local_backups_checker.sh

Creates and verifies SHA-256 manifests for a directory tree. It works
on the current directory, so run it from the root of the tree you want
to protect:

```bash
cd /path/to/tree
./local_backups_checker.sh --generate            # on the source side
./local_backups_checker.sh --verify              # on the destination side
./local_backups_checker.sh --generate-and-verify # both, as a sanity check
```

- `-o <file>` sets the manifest name for generation and `-m <file>`
  for verification. Both default to `backup.manifest`.
- The manifest stores relative paths, so verification works wherever
  the tree was copied to.
- The manifest itself and the `verify_*.log` files are excluded from
  the manifest; both change as the script runs and would guarantee a
  false corruption result.
- Each run writes a timestamped log, `verify_YYYYMMDD_HHMMSS.log`, in
  the current directory.
- Exit codes: 0 means everything matched (or a manifest was
  generated), 1 means one or more files are missing or corrupted, 2
  means a usage error or a missing manifest for verification.
- `-h` or `--help` prints the usage header.

Typical flow: generate the manifest on the source before copying,
then verify on the destination after the copy lands.
