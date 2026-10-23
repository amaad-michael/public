# Password cycle kit

Playbooks for cycling the fleet's account passwords (pi_all: pi0-pi4 +
neo1) and verifying the result. Part of ansible/playbooks/accounts/.

The original single-account templates remain at the accounts/ top
level, renamed ../cycle_creds_old.yml (root) and
../cycle_creds_michael_old.yml. This kit is the parameterized version
used for full fleet cycles: all three accounts, values injected from
the vault at run time, and a pre-flight gate before anything changes.

- cycle_creds.yml: cycle the root, michael, and ansible account passwords
  on every host.
- verify_cycle_creds.yml: verify the fleet after a cycle (reachability,
  sudo become, set passwords, sshd hardening state).
- passwords.example.yml: the shape of the vars file the cycle playbook
  consumes. Placeholders only.

## How the cycle works

Passwords live in the vault (Proton Pass), never in this repo. Each host
gets a unique 32-character password per account, generated in the vault.

At run time, copy passwords.example.yml to ~/passwords.yml (outside the
repo) and fill every value from the vault, then inject it as extra vars.
Commands are written from the repo root:

```bash
ansible-playbook -i ansible/hosts ansible/playbooks/accounts/password-cycle/cycle_creds.yml -e "@$HOME/passwords.yml" -e ansible_user=root --limit neo1
```

The cycle runs as root, not as the inventory's usual michael user: the
playbook first reads each host's account database and creates any
missing account (the ansible service account may not exist yet, and a
rebuilt host may be missing michael), and an account cannot create
itself. Created accounts get a home directory and /bin/bash; michael and
ansible also get their passwordless sudo drop-ins in /etc/sudoers.d
(visudo-validated). Existing accounts are never modified by the creation
step. SSH keys are not this kit's job; they are handled by the SSH setup
scripts.

Pilot on one host first (neo1 is the canary). A pre-flight task asserts
every host in the run has a real 32-character value for every account
before any password task starts anywhere, so a bad vars file changes
nothing. The set task runs with no_log: values never appear in output.

sshd is deliberately not restarted by the cycle playbook: daemon restarts
belong to the hardening step (PermitRootLogin prohibit-password,
PasswordAuthentication no), done per host with a live session held open.

After the cycle and hardening, verify the fleet, then shred the vars file:

```bash
ansible-playbook -i ansible/hosts ansible/playbooks/accounts/password-cycle/verify_cycle_creds.yml
shred -u ~/passwords.yml
```

Keep the vars file until the whole fleet verifies. Re-running the cycle
with the same values is safe: the effective passwords do not change.

## Bash form

`scripts/security/cycle-fleet-passwords.sh` performs the same cycle
from the controller over SSH with the same safety semantics (runtime
injected values from the same vars-file shape, fleet-wide pre-flight,
create-if-missing accounts, visudo-validated sudo drop-ins, fail-fast,
and the same post-cycle verification). Use either form; do not mix
them mid-cycle. There is no Docker form: the cycle is a
controller-side operation driven by vault-held secrets.
