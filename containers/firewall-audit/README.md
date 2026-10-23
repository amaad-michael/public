# Fleet firewall audit (container)

A run-on-demand collector that produces the firewall audit report of
`scripts/network/firewall_audit.sh` (Ansible form:
`ansible/playbooks/firewall/firewall_audit.yml`) from a container:
SELinux state, firewalld state, active zones and services,
masquerading and forwarding, iptables and nftables rulesets, open
ports, the PID-to-command mapping, listening services, non-localhost
bindings, installed firewall packages, recent firewall-config
changes, and the last 7 days of firewalld logs — plus a Findings
section flagging a host with no active firewall and listing
non-localhost listeners for review.

## 🌐 Access model: what a container can and cannot audit

A firewall lives in the host's kernel and network namespace. The
shipped compose is built around that fact:

- **`network_mode: host`** — the collector shares the host's network
  namespace, so `ss`, `nft`, and `iptables` describe the host. Behind
  the default bridge the same commands would describe the container's
  own empty namespace, and the report would look clean because it is
  looking at nothing. If you run it bridged anyway, the Findings
  section flags `no-active-firewall` — believe the flag, not the
  empty tables.
- **`CAP_NET_ADMIN` (read-only use)** — listing the host's nftables
  ruleset and iptables chains requires it. Every command the
  collector runs is a query (`list`, `-L`, `--state`); it writes no
  rule. All other capabilities are dropped, the root filesystem is
  read-only, and the container runs once and exits.
- **firewalld needs the host's D-Bus** — `firewall-cmd` talks to the
  host's firewalld over the system bus. Without the socket, the
  firewalld sections fall back to the bash audit's own messages
  ("FirewallD not active or not installed"), which would be wrong on
  a firewalld host. On firewalld hosts, add the socket with an
  override file (`docker-compose.override.yml`, kept on the host):

```yaml
services:
  firewall-audit:
    volumes:
      - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
```

- **SELinux and the journal are the host's only by proxy** —
  `getenforce` reports the container's view (on a Debian-based image
  that is "not available", whatever the host runs), and `journalctl`
  reads the host's journal only if `/var/log/journal` or
  `/run/log/journal` is also mounted in. The bash and Ansible forms,
  which execute on the host, have no such blind spots; for SELinux
  or journal evidence, prefer them. The ruleset, socket, and
  listener sections — the bulk of the audit — are exact under the
  shipped compose.

## ✅ Build and verify

```bash
cd containers/firewall-audit
docker compose build
docker compose run --rm firewall-audit
```

A healthy run prints all thirteen sections for the host and a
Findings section; on a host with an active firewall there is no
`FLAG` line.

## 🔧 Usage

Report saved to a file (mode 0600, like the bash audit's logs):

```bash
docker compose run --rm firewall-audit --output /tmp/firewall-report.log
```

## Notes

- Nothing is scheduled and nothing is a daemon: like the bash audit,
  each run is one collection.
- The host's `/etc/firewalld` is mounted read-only so the
  recent-changes section can stat the same files the bash audit
  stats over SSH.
- The base image is `debian:bookworm-slim` pinned by digest in the
  Dockerfile (multi-arch: amd64 and arm64, so the Pis build the same
  image). Re-verify the digest before bumping it.
