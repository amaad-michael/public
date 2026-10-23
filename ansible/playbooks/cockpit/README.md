# Cockpit playbook

One playbook that gives a host its side of Cockpit: the web console package and the console port in the firewall.

```bash
cd ansible
ansible-playbook -i hosts playbooks/cockpit/cockpit_setup.yml -K
```

Target a group instead of all hosts with `-e target_group=webservers`; limit to one host with `-l host01`; dry-run with `--check`.

## cockpit_setup.yml

Installs and enables Cockpit on Debian and RHEL family hosts. The play:

- Fails cleanly on any other OS family.
- On RedHat family hosts below version 9 it installs `epel-release` first; version 9 and newer do not need it. Tagged `prerequisites`.
- Installs the `cockpit` package (the same name on both families; apt cache update on Debian family hosts). Tagged `install`.
- Validates the install by running `cockpit-ws --version`. The binary path differs by family: `/usr/lib/cockpit/cockpit-ws` on Debian, `/usr/libexec/cockpit-ws` on RedHat. Tagged `validation`.
- Enables and starts `cockpit.socket` and verifies the socket reports `active`. Cockpit is socket-activated: the web service itself starts on the first connection to port 9090. Tagged `service` and `status`.
- Opens 9090/tcp in firewalld or UFW, whichever the host runs; with neither present it prints the rule to add instead of guessing.
- On a host whose service manager is not systemd, the service steps print the manual commands instead of failing.

## 🔗 Related pieces

- `containers/cockpit/` runs the console itself as a single bastion container instead of installing it per host. The playbook stays the way hosts get their side of Cockpit: a host with no Cockpit packages can be reached from that console only in a limited form.
- Historical metrics are deliberately not a Cockpit job here (decision 2026-10-22): the fleet's Prometheus/Grafana stack owns metric history, so neither the playbook nor the script installs PCP (Performance Co-Pilot), and the console runs live-only. Hosts carry no `pmcd`/`pmlogger` archiving daemons writing to their SD cards.
- `scripts/linux-admin-toolkit/27-cockpit-install/cockpit-install-local.sh` is the bash form of the same setup for a single host run by hand: same package, same unit, same firewall step.
