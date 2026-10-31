# scripts/network

Network audit, firewall setup, and scanning scripts for the homelab
fleet (pi0 to pi4 and neo1, 192.168.0.100 to 105) and the two
workstation hosts (the Nobara GPU box and the OptiPlex).

## firewall_audit.sh

Read-only firewall and port audit of all six fleet hosts over SSH. For
each host it collects:

- SELinux status and firewalld state
- Active zones, services, masquerading, and port forwarding rules
- iptables and nftables rulesets
- Listening sockets from `ss`, with a PID to command mapping and the
  `lsof` listener list
- Non-localhost bound ports
- Installed firewall packages and recent changes under `/etc/firewalld`
  and `/etc/sysconfig/iptables`
- The firewalld journal for the last 7 days

Run it from any host that can SSH to the fleet as the invoking user:

```bash
./firewall_audit.sh
```

Output goes to one timestamped file,
`/var/log/firewall_audit/firewall_audit_YYYYMMDD_HHMMSS.log`, so run
as root or as a user who can create that directory. A host that fails
the 10-second SSH check is logged as an error and skipped. Several checks are RHEL-family oriented (firewalld, `rpm`); on the Debian-family hosts most of those sections print their not-available fallbacks instead of failing the run — the `rpm` package list and the recent-changes find simply come back empty.

## 🛠️ Host firewall setup scripts

Both scripts run once on the host itself, as root. Both are
idempotent: re-running leaves the same rules in place.

| Script | Host | Firewall | LAN-only ports opened |
| --- | --- | --- | --- |
| `gpu-box-firewall-setup-v1.1.sh` | GPU box (Nobara) | firewalld, zone `home` | 22 (SSH), 11434 (Ollama), 3000 (Open WebUI), 9090 (Cockpit) |
| `optiplex-firewall-setup-v1.1.sh` | OptiPlex (apt-based) | UFW | 22 (SSH), 8080 (llama-server), 9090 (Cockpit) |

- `gpu-box-firewall-setup-v1.1.sh` installs firewalld if missing,
  enables it, binds the source subnet 192.168.0.0/24 to the `home`
  zone, adds the four ports as permanent rules, reloads, and prints
  the resulting zone state. Log:
  `/var/log/gpu-box-firewall-setup.log`.
- `optiplex-firewall-setup-v1.1.sh` installs UFW if missing, enables
  it, and adds one allow rule per port scoped to 192.168.0.0/24. Log:
  `/var/log/optiplex-firewall-setup.log`.

The port sets are fixed in each script; edit the `PORTS` or `RULES`
array before running if a host's services differ.

## fleet-firewall.sh

The bash form of the fleet firewall playbooks in
`ansible/playbooks/firewall/`. It runs on the host itself, as root,
and picks the tool by OS family exactly as the playbooks do: UFW on
the Debian family (pi0, pi2, pi4, neo1), firewalld on the RedHat
family (pi1, pi3). Three profiles mirror the three playbooks:

| Profile | Playbook | Rules |
| --- | --- | --- |
| `pi` (default) | `firewall_local_pi.yml` | TCP 53, 80, 443, 9090; UDP 53 |
| `new` | `firewall_local_new.yml` | The pi list plus TCP 853 |
| `baseline` | `default-firewalld.yml` | firewalld only: ssh, http, https services; 8080/tcp; 5000-5010/udp; cockpit removed; default zone public |

On the UFW path, SSH (22/tcp) is allowed first, before the default
policies (deny incoming, allow outgoing) are set, and UFW is
force-enabled only after the rules are in place. On the firewalld
path, rules are permanent and immediate in the zone (default
`public`, `--zone` overrides) with one reload at the end when
anything changed. Every rule is checked before it is added, so
re-running changes nothing. After applying, an SSH lockout probe
checks that port 22 is covered by the resulting ruleset; it warns
by default and aborts with `--fail-on-probe-failure`.

```bash
sudo ./fleet-firewall.sh                  # apply the pi profile
sudo ./fleet-firewall.sh --profile new    # apply the new profile
sudo ./fleet-firewall.sh --verify         # diff live rules vs profile
sudo ./fleet-firewall.sh --dry-run        # print changes, change nothing
```

Run in a terminal without `--profile` and a profile picker panel
opens instead: arrow keys or j/k move, Enter chooses, q cancels.
The chosen profile runs through the same code path as `--profile`;
off a terminal, or with `--profile` given, nothing changes and
the default stays `pi`.

Log: `/var/log/fleet-firewall.log`. There is no Docker form: this
configures the host's own firewall.

## 🔍 nmap scans

Three scripts scan the fixed subnet 192.168.0.0/24 at different
depths and cadences. All three require `nmap` and exit 1 if it is
missing.

| Script | Cadence | Scan | Output |
| --- | --- | --- | --- |
| `local_nmap.sh` | Ad hoc, by hand | Fast scan, top 100 ports (`-F -T4`) | Stdout only, no files |
| `local_nmap_hourly.sh` | Hourly (cron) | Fast scan, open ports only, reverse DNS | `/var/log/netwatch/` (below) |
| `local_nmap_monthly.sh` | Monthly (cron) | All 65,535 ports with version detection (`-p- -sV`) | One report per run in `/var/log/netwatch/` |

`local_nmap_hourly.sh` keeps five files in `/var/log/netwatch`:

- `scan_raw.txt`: the latest raw scan
- `scan_clean.txt`: the latest scan with latency and timing lines
  stripped, so diffs only show real changes
- `scan_previous.txt`: the previous clean scan, kept for comparison
- `history.log`: every raw scan, appended with a timestamp header
- `changes.log`: a zero-context diff appended each time the clean
  scan changes

The first hourly run has no previous scan, so it records history but
no diff. The monthly report is named
`deep_scan_YYYY-MM-DD_HH-MM.log`. Both netwatch scripts write under
`/var/log`, so schedule them as root.

## nmap-vuln-scan.sh

On-demand vulnerability scan of one host or a list of hosts:

```bash
./nmap-vuln-scan.sh 192.168.0.101
./nmap-vuln-scan.sh targets.txt
```

The argument is either a single IP or a file with one target per
line. Each target gets a service and version scan with the built-in
`vuln` NSE script category (`-sV --script vuln -T4`). Reports land in
a timestamped directory in the current directory,
`nmap_vuln_results_YYYYMMDD_HHMMSS/`, one `<target>_vuln_scan.txt`
file per target.
