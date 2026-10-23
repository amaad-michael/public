# Security playbooks

Ansible forms of the `scripts/security/` family: the server
hardening baseline and the SSH access toolkit.

## 🔒 secure_server_init.yml

The Ansible form of the secure-server-init family
(`scripts/security/secure-server-init-v1.1.sh` and its conservative
and legacy v1.1 variants), applying the whole baseline as a unit, in
the bash scripts' own order:

1. System update, with automatic patching disabled (unattended-
   upgrades / dnf-automatic removed, periodic updates zeroed).
1. The admin user (`michael` by default) with a NOPASSWD sudoers
   drop-in at `/etc/sudoers.d/michael`, mode 0440.
1. The sshd hardening drop-in
   `/etc/ssh/sshd_config.d/99-hardening.conf`, validated with
   `sshd -t` where services are managed, then SSH restarted.
1. A whitelist firewall with port 22 only: UFW reset with default
   deny incoming on Debian family, firewalld public zone with the
   ssh service on RedHat family.
1. fail2ban with an sshd jail, auditd with watch rules on the
   passwd, shadow and sudoers files, the sshd config, the SSH host
   key, and root executions, and lynis.
1. Daily log rotation (14 days, mode 600) for the auth log and the
   audit log.
1. The AppArmor or SELinux status, reported only.
1. The Pi cluster personalization: pi0 to pi4 and neo1
   (192.168.0.100 to 105) in `/etc/hosts` and a fastfetch MOTD with
   the same host list.
1. IPv6 disabled by the sysctl drop-in
   `/etc/sysctl.d/99-disable-ipv6.conf`.

The variant is a variable, with the bash scripts' values as
defaults:

| Variable | Default | Meaning |
| --- | --- | --- |
| `secure_init_variant` | `standard` | `standard`, `conservative` or `legacy`, matching the three v1.1 bash variants (crypto and auth policy, fail2ban retries, legacy pwquality and pam_faillock) |
| `secure_init_user` | `michael` | The admin user the scripts bake in |
| `secure_init_ssh_port` | `22` | The one port the whitelist firewall opens |

```bash
ansible-playbook -i ansible/hosts playbooks/security/secure_server_init.yml --limit <host>
ansible-playbook -i ansible/hosts playbooks/security/secure_server_init.yml --limit <host> -e secure_init_variant=legacy
```

⚠️ Pre-flight, identical to the bash scripts: the standard and
conservative variants disable SSH password authentication. Confirm
key-based login works before running, or the target locks you out
of SSH and recovery needs physical or console access.

There is no Docker form for this baseline, and there will not be
one: it hardens the host itself (sshd, the host firewall, auditd,
sysctl), which a container cannot do to its host.

Four test switches (`secure_init_install_packages`,
`secure_init_manage_services`, `secure_init_manage_firewall`,
`secure_init_apply_sysctl`) exist for sandbox and chroot runs that
cannot provide one layer; leave them at their defaults (`true`) on
real hosts.

## 📝 Notes

- The playbook targets `hosts: all`; scope every run with `--limit`
  and an explicit inventory.
- No secrets live in the playbook. The admin key, if any, is added
  afterward with the SSH access toolkit.
