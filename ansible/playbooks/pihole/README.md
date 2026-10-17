# Pi-hole and Unbound playbooks

Two playbooks that install Pi-hole with a local Unbound recursive resolver on a Debian-family host. They differ in one step only: how the Pi-hole installer itself runs.

Both playbooks share the same wiring:

- The Pi-hole installer is downloaded from `https://install.pi-hole.net` to `/tmp/install_pihole.sh`. The download is pinned by SHA-256 (pinned in September 2026). Upstream updates that file in place, so re-pin the checksum in the playbook before re-running.
- Dependencies (curl, sudo, unbound, unbound-anchor) are installed with apt, and a dist-upgrade runs first. The package tasks only run on the Debian OS family.
- The OISD blocklist (`https://big.oisd.nl`) is added with `pihole -a -i`, then Gravity is rebuilt with `pihole -g`.
- Pi-hole's upstream is set to Unbound by writing `PIHOLE_DNS_1=127.0.0.1#5335` into `/etc/pihole/setupVars.conf`.
- The shared `unbound.conf` from this folder is deployed to `/etc/unbound/unbound.conf`, root hints are initialised with `unbound-anchor`, and handlers restart `pihole restartdns` and the unbound service as needed.

The playbooks target `hosts: all`. In the shipped inventory the DNS hosts are the `pi_dns` group (pi0 and pi4), so limit the run:

```bash
cd ansible
ansible-playbook -i hosts playbooks/pihole/pihole_unbound_automated.yml -l pi_dns -K
```

## Which playbook to run

| Playbook | Installer mode | Use it when |
|---|---|---|
| `pihole_unbound_automated.yml` | Runs the installer with `--unattended` | Default choice. Hands-off installs and re-runs |
| `pihole_unbound_attended.yml` | Pauses and makes you run the installer interactively over SSH | You want to answer the installer's prompts yourself |

The automated playbook is idempotent for the install step: it checks for `/etc/pihole/setupVars.conf` first and skips the installer when Pi-hole is already present.

The attended playbook downloads the installer, prints instructions, and pauses. You SSH into the host, run `sudo bash /tmp/install_pihole.sh` yourself, and pick a public upstream DNS provider during the install (the playbook switches Pi-hole to Unbound afterwards). Press Enter at the pause when the install finishes; the playbook then verifies `setupVars.conf` exists and continues with the shared steps.

## ⚙️ The shared Unbound configuration

`unbound.conf` runs Unbound as a localhost-only recursive resolver:

- Listens on 127.0.0.1 port 5335 only, with access control allowing 127.0.0.1 only. Nothing off the host can query it directly.
- IPv4 only (IPv6 is disabled), UDP and TCP enabled.
- DNSSEC hardening: `harden-glue`, `harden-dnssec-stripped`, QNAME minimisation, `use-caps-for-id`, identity and version hidden.
- Prefetching on, cache TTLs from 0 to 86400 seconds, EDNS buffer size 1232 to avoid fragmentation.
- `private-address` entries block DNS-rebinding answers for private and documentation ranges.
- Query and reply logging are off; verbosity is 1 through syslog. One thread, tuned for a small Pi-class host.

Related material lives elsewhere in the repo: the containerised form of this pair is `containers/pihole/`, and the host-side maintenance and removal playbooks are `ansible/playbooks/monthly/monthly_maint_pihole.yml` and the Pi-hole entries in `ansible/playbooks/cleanup/`.
