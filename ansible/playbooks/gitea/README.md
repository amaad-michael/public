# Gitea playbooks

The Ansible install form for a primary-host Gitea, mirroring the
bash pair `scripts/provisioning/install-gitea.sh` and
`scripts/provisioning/post-setup-tighten-gitea.sh`.

This is not the `containers/gitea/` project. That container is a
pull-mirror instance with the web installer locked
(`INSTALL_LOCK = true` in its `app.ini`): it exists to mirror the
GitHub repos so the code survives a GitHub outage. The playbook below
installs the primary host — the place where repositories are created
and pushed to — with the same version pin (Gitea 1.26.4), the same
`git` system user, paths, seeded `app.ini`, and hardened systemd
unit as the bash installer. The SD-card bash variant
(`install-gitea-sd.sh` and its tighten script) has no Ansible form;
its flash-wear measures stay bash-only.

## install_gitea.yml

One playbook, two phases, matching the bash pair's required order.

Install phase (every run):

- Installs dependencies: git, wget, sqlite3, and ca-certificates on
  the Debian family; git, wget, sqlite, and ca-certificates on the
  RHEL family.
- Creates the `git` system user and group with a nologin shell and
  `/home/git` home (built-in SSH mode, like the installer).
- Creates `/var/lib/gitea/{custom,data,log}` owned `git:git`, mode
  0750, and `/etc/gitea` owned `root:git`, mode 0750.
- Seeds `/etc/gitea/app.ini` only if absent (mode 0660): the
  `[server]` block with the built-in SSH server, web on port 3000,
  SSH on port 2222. An existing `app.ini` is never overwritten, so
  the values the web installer writes later survive re-runs.
- Downloads the pinned Gitea 1.26.4 binary for the host architecture
  (amd64, arm64, or arm-6) and its `.sha256` from dl.gitea.com, and
  verifies the checksum before installing to `/usr/local/bin/gitea`.
- Writes the same hardened systemd unit as the bash installer
  (sandboxing, `ProtectSystem=full`, empty capability bounding set,
  seccomp filter, `ReadWritePaths=/var/lib/gitea /etc/gitea` until
  the tighten phase removes the config path), restores SELinux
  contexts when SELinux is enforcing, and enables the service.

Then, by hand: complete the first-run web installer at
`http://<host>:3000`, create a canary repository (empty is fine),
and upload the SSH public key of the account that will run the
tighten phase (normally root) to an account with write access to it.

Tighten phase (re-run with `-e gitea_tighten=true
-e gitea_canary_repo=<owner>/<repo>`):

- Fails closed if `gitea_canary_repo` is not set, like the bash
  script's `TEST_REPO` requirement.
- Sets `app.ini` to mode 0640 and removes `/etc/gitea` from the
  unit's `ReadWritePaths`, then restarts Gitea (daemon-reload alone
  does not rebuild the mount namespace).
- Verifies the lockdown: `ReadWritePaths` no longer lists
  `/etc/gitea`, the `git` user cannot write `app.ini`, and the
  service is active.
- Runs the canary under the final sandbox: HTTP answers on port
  3000, an SSH clone of the canary repo succeeds, and a commit push
  succeeds (the push traverses the server-side hook chain, the path
  the seccomp filter could plausibly break). The clone uses
  `StrictHostKeyChecking=accept-new`; pin known_hosts afterward on
  long-lived nodes.
- Sweeps the journal since the restart for seccomp or namespace
  denials and fails if any appear.

```bash
cd ansible
ansible-playbook -i hosts playbooks/gitea/install_gitea.yml -l pi1 -K
ansible-playbook -i hosts playbooks/gitea/install_gitea.yml -l pi1 -K -e gitea_tighten=true -e gitea_canary_repo=michael/canary
```

No firewall changes are made, matching the bash installer. One
variable exists for test harnesses: in a chroot or container there
is no running systemd, so a test run can pass
`-e gitea_service_state=stopped`; the install still runs for real,
and only the service start (and the tighten checks that query the
running service manager) is skipped. Production runs use the
default, `started`.
