# Jenkins playbooks

The Ansible install form for Jenkins, mirroring the bash installer
`scripts/provisioning/install-jenkins-rocky.sh` (its guide is
`scripts/provisioning/jenkins-consolidated-v1.0.md`). The Docker form
is `containers/jenkins/`. Removal is the companion playbook
`ansible/playbooks/cleanup/uninstall_jenkins.yml`, which removes
exactly what the installer creates.

## install_jenkins.yml

Installs Jenkins LTS 2.580.1 on Rocky Linux 8, 9, or 10:

- Fails on non-Rocky/RHEL systems unless `-e allow_other_os=true`.
- Installs Java with dnf: version 21 on Rocky 10 and later, 17 on
  Rocky 8 and 9 (Rocky 10 dropped `java-17-openjdk`), plus fontconfig
  and curl. Override with `-e java_ver=17` or `-e java_ver=21`.
- Adds the Jenkins stable repository file from pkg.jenkins.io (only
  when `/etc/yum.repos.d/jenkins.repo` is absent or empty, like the
  bash installer) and imports the Jenkins GPG key.
- Installs the `jenkins` package pinned to `jenkins_version`
  (2.580.1).
- Enables the systemd service and starts it, then waits for the
  initial admin password file at
  `/var/lib/jenkins/secrets/initialAdminPassword`.
- If firewalld is active, opens port 8080 permanently. Port 50000
  for JNLP agents is opened only with `-e with_agent_port=true`;
  `-e configure_firewall=false` skips firewall changes entirely.
- Prints the Jenkins URL and the initial admin password at the end,
  like the bash installer.

Run it scoped to the target host:

```bash
cd ansible
ansible-playbook -i hosts playbooks/jenkins/install_jenkins.yml -l pi3 -K
```

The playbook is idempotent: safe to re-run, and it never removes or
downgrades anything.

One variable exists for test harnesses: in a chroot or container
there is no running systemd, so a test run can pass
`-e jenkins_service_state=stopped`. The package, repository, key, and
service enablement still run for real; only the service start (and
the password wait, which depends on a first start) is skipped.
Production runs use the default, `started`.
