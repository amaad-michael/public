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

## 🔑 ssh_toolkit.yml

The Ansible form of the SSH access toolkit in `scripts/security/`
(`ssh-setup-new-box-v1.0.sh`, `send_keys.sh`,
`setup_key_access.sh`, `add_known_hosts.sh`), in three plays:

1. Controller (connection: local): keychain installed with the
   script's EPEL fallback, the keychain eval line in `~/.bashrc`,
   `~/.ssh` at 0700, and an ed25519 keypair generated only if
   missing, with the script's `michael@homelab` comment.
1. Fleet (`hosts: all`): the controller's public key in each target
   user's `authorized_keys` — the declarative form of `send_keys.sh`
   and `setup_key_access.sh`. Where the bash tools append and can
   duplicate a key line on re-run, `authorized_key` is exact-state
   and converges; the key, user and fleet are the scripts' own.
1. Controller again: `ssh-keyscan -H` of every fleet address
   (192.168.0.100 to 105) recorded hashed in `~/.ssh/known_hosts`,
   the state `add_known_hosts.sh` aims at, without its blind-append
   duplicates.

What stays bash-only, stated in the playbook header as well:
loading the key into a persistent agent with its one passphrase
prompt is an operator-session action no playbook can perform; the
first-contact password prompts of `ssh-copy-id` are the same class;
and `export_ssh.sh` (archiving a host's private host keys, run as
root on that host) is deliberately not re-implemented — moving
private host key material through a playbook is the wrong shape
for it.

```bash
ansible-playbook -i ansible/hosts playbooks/security/ssh_toolkit.yml
ansible-playbook -i ansible/hosts playbooks/security/ssh_toolkit.yml --tags controller
```

There is no Docker form: the toolkit operates on the operator's
own `~/.ssh` and live sessions, which a container cannot reach.

## 📝 Notes

- Both playbooks target `hosts: all` or the controller; scope every
  run with `--limit` and an explicit inventory.
- No secrets live in either playbook. Key material is generated on
  the host it belongs to or read from the operator's own public key
  file at run time.
