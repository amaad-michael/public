# scripts/pihole

Scripts for the containerized Pi-hole + Unbound pair in
`containers/pihole` (containers `pihole-backup` and `unbound-backup`
on the `pihole-backup` network, Unbound at 172.20.0.3 port 5335),
plus one bash installer and one log cleanup script for a bare-metal
Pi-hole host and one controller that owns the pair's whole lifecycle
in both forms.

## install-pihole-unbound.sh

The bash deployment form for the container pair (the Ansible
playbooks in `ansible/playbooks/pihole/` install the bare-metal form
instead). Run it as root on the Docker host:

```bash
sudo ./install-pihole-unbound.sh
sudo ./install-pihole-unbound.sh --dry-run
sudo ./install-pihole-unbound.sh --with-blocklists
```

What it does, in order:

- Checks the prerequisites: root, the docker CLI, and a compose
  backend (`docker compose` plugin, or the standalone
  `docker-compose` binary).
- Validates `containers/pihole/.env` and fails closed: the file must
  exist, it is tightened to mode 600 if needed, and `PIHOLE_TAG`,
  `UNBOUND_TAG`, and `PIHOLE_API_PASSWORD` must all be set. The
  `latest` tag is rejected for both images.
- Renders the compose config and refuses to deploy if the rendered
  `unbound` service publishes any host port. That is the v2 posture:
  Unbound stays reachable only on the `pihole-backup` bridge network.
- Runs `compose pull` and `compose up -d`.
- Verifies the deployment: both containers report healthy, Unbound
  publishes no host ports, `pi.hole` resolves to 172.20.0.2 through
  Pi-hole, and an external name resolves through the Pi-hole to
  Unbound path.

`--dry-run` stops after the render and guard checks and prints the
deploy commands instead of running them. `--compose-dir DIR` points
at a different checkout of the compose project. `--with-blocklists`
additionally runs `pihole-init-blocklists.sh` inside the Pi-hole
container after a healthy start; without it the script prints the
reminder to seed the blocklists manually. Deploy order is the compose
header's: pi0 (secondary) first, verify, then pi4 (primary).

## DNS test suite

One DNS test suite. It runs `dig` inside the containers through `sudo docker exec`, so run it on the Docker host (or a host with equivalent Docker access). The checks are:

- `pi.hole` local resolution
- Unbound direct resolution of google.com
- Pi-hole to Unbound forwarding at 172.20.0.3, on port 53 and on port
  5335 (both the `#port` fragment form and the `-p` flag form)
- DNSSEC: dnssec-failed.org must fail validation, google.com must
  validate
- Ad blocking: doubleclick.net must be blocked

Pass/fail is dig's exit code only: the suite does not parse the answer, so the DNSSEC and ad-blocking entries above are the labelled expectations for each dig (dnssec-failed.org SERVFAIL, google.com AD flag, doubleclick.net blocked), not assertions the script checks in the output.

The suite is `dns-test-pihole-unbound-linted.sh`, the single variant
kept since the 2026-10-22 consolidation (the full and minimal
variants were removed; the full variant's fragment-syntax port test
was folded in). It runs 8 tests in sections; pre-flight aborts if
either container is stopped or missing; failures are appended to
`/tmp/dns-test-failures-<epoch>.log` (deleted on a clean run); it
warns if sudo would prompt, which would hang a CI run; and it exits
1 on any failure, so scripted callers can trust the exit code.

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

## install-pihole-unbound-native-v1.0.sh

The bash form of the bare-metal install: a step-for-step mirror of
the two Ansible playbooks (`pihole_unbound_automated.yml` and
`pihole_unbound_attended.yml`, which remain the parallel route to the
same end state). Run it as root on the target host:

```bash
sudo ./install-pihole-unbound-native-v1.0.sh              # unattended (default)
sudo ./install-pihole-unbound-native-v1.0.sh --attended   # pause for a manual vendor install
sudo ./install-pihole-unbound-native-v1.0.sh --dry-run    # print the plan and commands, change nothing
```

What it does, in order: dist-upgrades and installs the playbooks'
package set (plus `sqlite3`, which the blocklist initializer needs);
downloads Pi-hole's installer and verifies it against the SHA-256
the playbooks pin (upstream updates that file in place, so a mismatch
stops the run before anything executes; re-pin deliberately with
`--installer-sha256`); runs the vendor installer unattended, or in
`--attended` mode pauses while you run it interactively choosing a
public upstream, exactly as the attended playbook does; sets
`PIHOLE_DNS_1=127.0.0.1#5335` in `setupVars.conf`; delegates
blocklist initialization to `pihole-init-blocklists.sh` (the OISD
list the playbooks add, plus the Hagezi lists, then gravity); deploys
`ansible/playbooks/pihole/unbound.conf` to `/etc/unbound/unbound.conf`
(override the source with `--unbound-conf`); fetches the DNSSEC root
anchor when absent; and applies the playbooks' closing restarts
(Pi-hole DNS, then Unbound) only for what changed. Idempotent: the
vendor installer, the config deploy, and the anchor are all gated on
existing state, as in the playbooks. Deploy order is pi0 (secondary)
first, verify, then pi4 (primary).

## pihole-control-v1.0.sh

One controller for the Pi-hole + Unbound lifecycle, in the pattern of
the neo1 observability stack's control script. It covers both forms:
the container pair above (`--form container`, the default when no
bare-metal footprint is present) and the bare-metal install the
Ansible playbooks perform (`--form native`).

```bash
sudo ./pihole-control-v1.0.sh status
sudo ./pihole-control-v1.0.sh install --with-blocklists
sudo ./pihole-control-v1.0.sh restart --form native
sudo ./pihole-control-v1.0.sh logs-clean --form native --dry-run
sudo ./pihole-control-v1.0.sh uninstall --dry-run
sudo ./pihole-control-v1.0.sh uninstall --purge
```

Verbs: `install`, `up`, `down`, `restart`, `status`, `logs-clean`,
`uninstall`. Container `install` delegates to
`install-pihole-unbound.sh` so its .env validation, Unbound exposure
guard, and health checks stay single-sourced; native `install`
delegates to `install-pihole-unbound-native-v1.0.sh`, the bash mirror
of the playbooks (`--attended` passes through for its manual-install
pause; the playbooks themselves stay available as the parallel
route). The legacy
stack under `containers/pihole/legacy` is an as-built record: the
controller refuses to install it but will take it down and uninstall
it (point `--compose-dir` at the legacy directory).

This is production DNS. `down`, `restart`, `logs-clean`, and
`uninstall` print a plain warning that the host stops answering DNS
while they run; work the secondary (pi0) before the primary (pi4).
`uninstall` prints a labeled plan (REMOVE / PRESERVED / PURGE) and
requires a typed confirmation. By default it preserves the data: the
container volumes, or natively `/etc/pihole`, `/etc/unbound`, and
`/var/lib/unbound`. `--purge` removes them, and the native purge
matches the footprint of
`ansible/playbooks/cleanup/uninstall_pihole2.yml` (package purge,
`pihole` user and group removal, `/etc/resolv.conf` restored to
Cloudflare when the pihole binary was present). Unit handling
resolves whatever suffix a unit file carries (`.service`, `.timer`,
`.socket`, and so on); it never assumes `.service`.
