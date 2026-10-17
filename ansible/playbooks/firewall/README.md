# Firewall playbooks

Three playbooks that configure host firewalls. One is a firewalld-only baseline; the other two are OS-aware variants of the same playbook with different port lists.

| Playbook | Firewall | Port list |
|---|---|---|
| `default-firewalld.yml` | firewalld only | ssh, http, https services; 8080/tcp; 5000-5010/udp; cockpit removed |
| `firewall_local_new.yml` | UFW on Debian family, firewalld on RedHat family | TCP 53, 80, 443, 853, 9090; UDP 53 |
| `firewall_local_pi.yml` | UFW on Debian family, firewalld on RedHat family | TCP 53, 80, 443, 9090; UDP 53 |

All three target `hosts: all` with privilege escalation. Scope every run with `--limit`.

## default-firewalld.yml

A static baseline for a firewalld host:

- Installs firewalld and starts and enables the service.
- Sets the default zone to `public` with `firewall-cmd --set-default-zone=public`. This step uses the command module on purpose: the playbook was converted from a text export on 2026-10-17, and the conversion recorded two corrections. The firewalld module lives in the `ansible.posix` collection (the `community.general` name does not resolve), and the module has no `set_default_zone` parameter, so the default zone is set with `firewall-cmd` instead.
- Permanently enables the ssh, http, and https services in the public zone, opens 8080/tcp and the 5000-5010/udp range, and removes the cockpit service from the zone. The two port entries are marked as examples in the source; edit them before treating the result as a finished ruleset.

## firewall_local_new.yml and firewall_local_pi.yml

The same playbook body, aimed at different hosts. Both declare the `community.general` and `ansible.posix` collections and decide the firewall tool from the host's OS family:

- Debian family: UFW is installed, SSH (port 22) is allowed first, default policies are set (deny incoming, allow outgoing), then the port list is opened and UFW is enabled.
- RedHat family: firewalld is installed and running, and the port list is opened permanently and immediately in the configured zone. The zone defaults to `public` and can be overridden with `-e desired_zone=<zone>`.

The only difference between the two files is the TCP port list. `firewall_local_new.yml` opens 53, 80, 443, 853 (DNS over TLS), and 9090; its header notes the list is synchronised with a production set. `firewall_local_pi.yml` is the Pi variant and opens 53, 80, 443, and 9090, without 853. Both open UDP 53, and in both, port 22 is handled separately and first, specifically to prevent a lockout.

Both variants end with a lockout safety probe: after the firewall changes, the controller checks that port 22 on the target still answers (10 second timeout, `ssh_probe_timeout`). A failed probe prints a warning. It aborts the run only when `-e fail_on_probe_failure=true` is set, which is the setting to use for hosts where a lockout would be critical. Setting `-e debug_firewall_status=true` also dumps the resulting UFW or firewalld status at the end of the run.
