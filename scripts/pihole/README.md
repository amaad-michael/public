# scripts/pihole

Scripts for the containerized Pi-hole + Unbound pair in
`containers/pihole` (containers `pihole-backup` and `unbound-backup`
on the `pihole-backup` network, Unbound at 172.20.0.3 port 5335),
plus one log cleanup script for a bare-metal Pi-hole host.

## DNS test suite

Three variants of the same DNS checks. All run `dig` inside the
containers through `sudo docker exec`, so run them on the Docker host
(or a host with equivalent Docker access). The checks are:

- `pi.hole` local resolution
- Unbound direct resolution of google.com
- Pi-hole to Unbound forwarding at 172.20.0.3, on port 53 and on port
  5335 (both the `#port` fragment form and the `-p` flag form)
- DNSSEC: dnssec-failed.org must fail validation, google.com must
  validate
- Ad blocking: doubleclick.net must be blocked

| Variant | Behavior |
| --- | --- |
| `dns-test-pihole-unbound-full.sh` | 8 tests, prints the dig HEADER status line per test, counts passes and failures, exit 1 if any test fails |
| `dns-test-pihole-unbound-linted.sh` | Pre-flight aborts if either container is stopped or missing; 7 tests in sections; failures are appended to `/tmp/dns-test-failures-<epoch>.log` (deleted on a clean run); warns if sudo would prompt, which would hang a CI run; exit 1 on any failure |
| `dns-test-pihole-unbound-minimal.sh` | The same checks as a bare list with raw dig output; no pass/fail counting and no failure exit code |

Which to use: the linted variant for routine or scripted
verification, the full variant for a compact summary, the minimal
variant for manual debugging where you want the raw output. One real
difference: the minimal variant runs the `pi.hole` test inside the
`unbound-backup` container; the other two run it in `pihole-backup`.

## pihole-init-blocklists.sh

Seeds the `adlist` table of `/etc/pihole/gravity.db` with five
blocklists, then runs `pihole -g` and prints the adlist and domain
counts:

- Hagezi Pro Mini
- Hagezi TIF Mini
- Hagezi Multi Normal
- Hagezi TIF Medium
- OISD Big

The script waits up to 60 seconds for `gravity.db` to appear, then
inserts with `INSERT OR IGNORE`, so it is idempotent and safe to
re-run. It works on paths inside the Pi-hole container (`/etc/pihole`,
`/usr/local/bin/pihole`), so run it inside the container, for example
with `docker exec`, once the container exists. Note: the shipped
`containers/pihole/docker-compose.yml` does not invoke this script;
wiring it into a deployment is a separate step.

## cleanup_logs_pihole2.sh

**Destructive. No backups are made and the operation is
irreversible.** This script targets a bare-metal Pi-hole host managed
by systemd, not the containers above. It must run as root.

What it does:

- Stops the `pihole-FTL`, `rsyslog`, `systemd-journald`, and
  `unbound` services (each only if present)
- Rotates the systemd journal, vacuums it to 1 second of retention,
  and deletes the persistent journal files under `/var/log/journal`
- Shreds (3 passes) `/var/log/pihole/pihole.log`,
  `/var/log/pihole/FTL.log`, and `/var/log/unbound.log`
- Truncates `/var/log/auth.log`, `/var/log/syslog`, and
  `/var/log/ufw.log`
- Recreates the two Pi-hole logs, owned `pihole:pihole`, mode 0644
- Clears `/root/.bash_history`
- Restarts the services and verifies their state and the journal
  disk usage

```bash
sudo ./cleanup_logs_pihole2.sh --dry-run  # print every action, change nothing
sudo ./cleanup_logs_pihole2.sh            # asks for confirmation first
sudo ./cleanup_logs_pihole2.sh --yes      # skip the confirmation prompt
```

Without `--yes` the script asks before doing anything. Unknown
arguments, `-h`, and `--help` print the usage text and exit 2.
