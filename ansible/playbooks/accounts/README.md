# Account playbooks

Credential cycling for the fleet is done by the password cycle kit in `password-cycle/`. The three playbooks at this level are the kit's superseded templates and one fresh-install cleanup.

## The canonical kit: password-cycle/

Use [`password-cycle/`](password-cycle/README.md) for any real password cycle. It has its own README with the full runbook.

The kit cycles the root, michael, and ansible account passwords across `pi_all` (pi0-pi4 and neo1). Password values are kept outside the repo and injected at run time from the filled vars file at `~/passwords.yml`. A pre-flight gate asserts every host has a real 32 character value for every account before anything changes, and the run creates any missing account first, so a rebuilt host is covered. `verify_cycle_creds.yml` then checks reachability, sudo, the set passwords, and the sshd hardening state.

## Superseded: cycle_creds_old.yml and cycle_creds_michael_old.yml

These are the original single-account templates the kit grew out of. Both are kept for reference and are not the tool for a real cycle.

- `cycle_creds_old.yml` sets the root password on Ubuntu servers.
- `cycle_creds_michael_old.yml` sets the michael account password on Ubuntu servers. It shares the same handler shape; its own comments note an SSH restart is not normally needed for a user password change.
- Both carry their password maps in the YAML itself, with placeholder values and an in-file warning that the values are hardcoded for demonstration and should be in Ansible Vault for production use. The maps are keyed by inventory hostname, and `update_password: always` forces a change on every run.

## remove_user_rocky.yml

> **Warning: destructive.** This playbook deletes an account and its home directory. Nothing is backed up.

On a fresh Rocky Linux install, the installer leaves a default `rocky` user. This playbook removes it: the `rocky` account is set absent, and a handler then deletes `/home/rocky`.

It targets `hosts: all`, so scope the run to the Rocky hosts (the `pi_rhel` group, pi1 and pi3, in the shipped inventory). It touches no other account. Before running it, make sure another working admin path to the host exists, such as the michael account or root over SSH keys, since the point of the playbook is that the default login goes away.
