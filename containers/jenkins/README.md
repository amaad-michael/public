# jenkins — CI server

A single-container Jenkins at the same LTS version as the other two
forms of this deployment: `scripts/provisioning/install-jenkins-rocky.sh`
(bash, bare metal under systemd) and
`ansible/playbooks/jenkins/install_jenkins.yml` (Ansible). All three
pin Jenkins LTS 2.580.1 and serve the web UI on port 8080.

The image tag is `jenkins/jenkins:2.580.1-lts`, the official LTS tag
for the pinned version (Docker Hub also publishes the plain
`2.580.1` tag; the `-lts` tag is the one that names the release
line). No `.env` file is required: this stack holds no secrets of
its own. The first-run setup wizard generates the initial admin
password inside the container, exactly like the package install.

## 🛠️ Setup

1. Start the stack: `docker compose up -d`.
1. Read the initial admin password from the container:

   `docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword`

1. Open `http://<host>:8080`, paste the password into the Unlock
   Jenkins page, and finish the setup wizard.

## 📦 Contents

- `docker-compose.yml`: the single `jenkins` service, the
  `jenkins-net` bridge network, and the `jenkins_home` named volume
  at `/var/jenkins_home` (the container form's Jenkins home; the
  package forms use `/var/lib/jenkins`).
- This README. There is no env example file, because the stack needs
  no host-side secrets or pins beyond the image tag in the compose
  file itself.

## 🔌 Ports

| Service | Host port | Notes |
| --- | --- | --- |
| jenkins | 8080 | Web UI and API |

The JNLP agent port 50000 is deliberately not published, matching
the bash installer, which opens it in firewalld only when
`--with-agent-port` is passed. If inbound agents are needed, add a
`docker-compose.override.yml` beside the compose file:

```yaml
services:
  jenkins:
    ports:
      - "50000:50000"
```

## ✅ Verify

The compose healthcheck polls `http://localhost:8080/login` with
curl from inside the container; `docker compose ps` should report
the service healthy after the first start (the healthcheck allows a
60-second start period). A freshly started container is at the
setup wizard, so `/login` answering is the ready signal; completing
the wizard is a manual step, as with the other forms.

## 💾 Backups

Everything lives in the `jenkins_home` volume (jobs, configuration,
credentials, build history). Back it up while the container is
stopped, or with `docker compose exec` and Jenkins' own backup
approach; restoring it into a fresh volume returns the instance to
the backed-up state. Removal of the package forms is covered by
`ansible/playbooks/cleanup/uninstall_jenkins.yml`; removing this
container form is `docker compose down -v` on the host (the `-v`
deletes the home volume — back up first).

## 🔒 Hardening posture

The container runs with `cap_drop: ALL` and
`no-new-privileges: true`, adding back only `CHOWN`, `SETUID`, and
`SETGID`, which the image entrypoint needs to hand the home volume
to the `jenkins` user before dropping privileges. Resource limits
are 1.0 CPU and 2G of memory.
