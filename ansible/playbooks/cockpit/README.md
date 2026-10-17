# Cockpit playbooks

Two playbooks that give a host its side of Cockpit: the web console packages, and the Performance Co-Pilot (PCP) data collection behind the Metrics page.

Run them in this order:

```bash
cd ansible
ansible-playbook -i hosts playbooks/cockpit/cockpit_setup.yml -K
ansible-playbook -i hosts playbooks/cockpit/cockpit_pcp.yml -K
```

## cockpit_setup.yml

Installs and enables Cockpit on Debian and RHEL family hosts. Targets `hosts: all`; scope with `--limit` as needed.

- On RedHat family hosts below version 9 it installs `epel-release` first; version 9 and newer do not need it. Tagged `prerequisites`.
- Installs the `cockpit` metapackage (with an apt cache update on Debian family hosts). Tagged `install`.
- Validates the install by running `cockpit-ws --version`. The binary path differs by family: `/usr/lib/cockpit/cockpit-ws` on Debian, `/usr/libexec/cockpit-ws` on RedHat. Tagged `validation`.
- Enables and starts `cockpit.socket` and then verifies the socket reports `active`. Cockpit is socket-activated: the web service itself starts on the first connection to port 9090. Tagged `service` and `status`.

## cockpit_pcp.yml

Adds performance data collection to a host that already runs Cockpit.

- Installs `pcp` and `cockpit-pcp`. The package list is the same for the RedHat and Debian families; the playbook picks the list by OS family.
- Enables and starts `pmlogger`, the PCP service that archives performance metrics to disk. That archive is what gives the Cockpit Metrics page its historical graphs; without it, the console only has live data.
- The play assumes a central Cockpit instance gathers data from the host once PCP is in place, which is the model described under Related pieces.

## 🔗 Related pieces

- `containers/cockpit/` runs the console itself as a single bastion container instead of installing it per host. The playbooks in this folder stay the way hosts get their side of Cockpit: a host with no Cockpit packages can be reached from that console only in a limited form, and its historical Metrics graphs appear only when it runs the PCP pieces from `cockpit_pcp.yml`.
- `scripts/linux-admin-toolkit/27-cockpit-install/` is the toolkit form of the setup step only: a local shell script and a fleet playbook that install Cockpit, enable `cockpit.socket`, and additionally open 9090/tcp in firewalld or UFW (printing the rule to add when neither tool exists). It has no PCP counterpart.
