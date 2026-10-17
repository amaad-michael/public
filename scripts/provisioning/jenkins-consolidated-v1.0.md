# Jenkins Homelab Reference

Version: v1.0
Last Updated: October 16, 2026
Status: Consolidated reference for open item [1cbd07] (Setup home Jenkins server)

This file consolidates Michael's Jenkins build script and Jenkins notes
into one reference. It keeps the working build path and the useful
migration material, and leaves out the chat filler, duplicates, and
superseded drafts from the source notes.

## Sources consolidated

- `~/workspace/your_files/jenkins-install/install-jenkins-rocky.sh`
  (the build script, embedded in full below)
- `~/workspace/user/files/scripting/homelab/jenkins_exodus_notes-v1.0.md`
  (controlled content migration plan and validation checklists)
- `~/workspace/user/files/scripting/homelab/jenkins.txt`
  (migration method notes)
- `~/workspace/user/files/scripting/ansible/ansible_notes.md`
  (the CI/CD with Jenkins section only)
- `~/workspace/user/files/scripting/homelab/jenkins-install.txt`
  (legacy Ansible draft; not carried over as a procedure, see the note
  at the end)

Passing mentions in the Proxmox LXC manual, the containers notes, and
the Proxmox README (a TurnKey Jenkins template row and LXC ID ranges)
were not imported; they belong to those documents.

## 1. Build path: the Rocky installer script

The canonical way to stand up the home Jenkins server is the Bash
installer. It has not been run on a server yet; it is built, syntax
checked, and ShellCheck reviewed.

What the script does:

- Targets Rocky Linux 8, 9, and 10 (RHEL-like systems can override the
  OS check with `ALLOW_OTHER_OS=1`).
- Installs Java and prerequisites with dnf. The default Java version is
  21 on Rocky 10 and later, 17 on Rocky 8 and 9, because Rocky 10 no
  longer ships Java 17. `--java 17` or `--java 21` overrides it.
- Adds the official Jenkins stable repository and imports the Jenkins
  GPG key, then installs the `jenkins` package.
- Enables and starts the systemd service, then waits for Jenkins to
  answer on port 8080 and for the initial admin password file to exist.
- If firewalld is active, opens port 8080, plus port 50000 for JNLP
  agents only when `--with-agent-port` is passed. `--no-firewall`
  skips firewall changes.
- Prints the Jenkins URL and the initial admin password at the end.
- Is idempotent: safe to re-run, and it never removes or downgrades
  anything. It must run as root.

Usage:

```bash
sudo ./install-jenkins-rocky.sh
sudo ./install-jenkins-rocky.sh --java 21 --with-agent-port
sudo ./install-jenkins-rocky.sh --no-firewall
```

Guardrails worth keeping from the older notes:

- Check whether Jenkins is already installed before changing anything,
  and stop if it is, unless a reinstall is the explicit goal.
- If an existing Jenkins configuration is present, back it up before
  making changes.

### Full build script

Embedded from `install-jenkins-rocky.sh` at consolidation time.
SHA-256 of the source script: `fbaa192efa740061ac341941610a951bda2b25c9feff7e8240d805ec8ad587ad`

```bash
#!/usr/bin/env bash
#
# install-jenkins-rocky.sh
#
# Install Jenkins (stable/LTS) on Rocky Linux 8/9/10.
#
# Usage:
#   sudo ./install-jenkins-rocky.sh [OPTIONS]
#
# Options:
#   --java 17|21          Java major version to install (default: 21 on Rocky 10+, 17 on 8/9)
#   --with-agent-port     Also open TCP 50000 (JNLP agents) in firewalld
#   --no-firewall         Skip firewalld configuration
#   -h, --help            Show this help
#
# Idempotent: safe to re-run. It never removes or downgrades anything.
# Must be run as root.
#
set -euo pipefail

JENKINS_PORT=8080
AGENT_PORT=50000
# Default Java version is chosen per OS release below (21 on Rocky 10+, 17 on
# 8/9); override with --java or the JAVA_VER environment variable.
JAVA_VER="${JAVA_VER:-}"
WITH_AGENT_PORT=0
CONFIGURE_FIREWALL=1

usage() {
    sed -n '2,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while (($#)); do
    case "$1" in
        --java)
            (($# >= 2)) || die "--java requires a value (17 or 21)"
            JAVA_VER="$2"; shift ;;
        --with-agent-port) WITH_AGENT_PORT=1 ;;
        --no-firewall)    CONFIGURE_FIREWALL=0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "run as root, e.g.: sudo $0"

# --- OS sanity check -------------------------------------------------------
. /etc/os-release
if [[ "${ID:-}" != rocky && "${ID_LIKE:-}" != *rhel* ]]; then
    [[ "${ALLOW_OTHER_OS:-0}" == 1 ]] \
        || die "not Rocky/RHEL (ID=${ID:-unknown}). Set ALLOW_OTHER_OS=1 to override."
    info "warning: non-Rocky OS (${PRETTY_NAME:-unknown}), proceeding anyway"
else
    info "detected ${PRETTY_NAME:-Rocky Linux}"
fi

# Default Java: Rocky 10 dropped java-17-openjdk (verified against Rocky 10.2
# BaseOS/AppStream metadata — only java-21-openjdk exists), and Jenkins LTS
# supports both 17 and 21, so default to 21 on Rocky 10+.
if [[ -z "${JAVA_VER:-}" ]]; then
    if [[ "${VERSION_ID%%.*}" -ge 10 ]]; then JAVA_VER=21; else JAVA_VER=17; fi
fi
[[ $JAVA_VER == 17 || $JAVA_VER == 21 ]] || die "--java must be 17 or 21"

# --- Java + prerequisites ---------------------------------------------------
info "installing Java ${JAVA_VER} and prerequisites"
dnf install -y "java-${JAVA_VER}-openjdk" fontconfig curl

# --- Jenkins repository ------------------------------------------------------
REPO_FILE=/etc/yum.repos.d/jenkins.repo
if [[ -s $REPO_FILE ]]; then
    info "jenkins repo already present at $REPO_FILE"
else
    info "adding Jenkins stable repository"
    curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo -o "$REPO_FILE"
fi
info "importing Jenkins GPG key"
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

# --- Install Jenkins ----------------------------------------------------------
info "installing jenkins"
dnf install -y jenkins

# --- Service -------------------------------------------------------------------
info "enabling and starting jenkins"
systemctl daemon-reload
systemctl enable --now jenkins

info "waiting for Jenkins to come up on port ${JENKINS_PORT}"
UP=0
for _ in $(seq 1 24); do
    if (echo > "/dev/tcp/127.0.0.1/${JENKINS_PORT}") 2>/dev/null \
        && [[ -s /var/lib/jenkins/secrets/initialAdminPassword ]]; then
        UP=1
        break
    fi
    sleep 5
done
[[ $UP -eq 1 ]] || die "jenkins did not come up; check 'systemctl status jenkins' and 'journalctl -u jenkins'"

# --- Firewall -------------------------------------------------------------------
if [[ $CONFIGURE_FIREWALL -eq 1 ]]; then
    if systemctl is-active --quiet firewalld; then
        PORTS=("$JENKINS_PORT")
        [[ $WITH_AGENT_PORT -eq 1 ]] && PORTS+=("$AGENT_PORT")
        for p in "${PORTS[@]}"; do
            if firewall-cmd --permanent --query-port="${p}/tcp" >/dev/null; then
                info "firewalld: port ${p}/tcp already open"
            else
                info "firewalld: opening port ${p}/tcp"
                firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
            fi
        done
        firewall-cmd --reload >/dev/null
    else
        info "firewalld not active, skipping firewall configuration"
    fi
fi

# --- Done ------------------------------------------------------------------------
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
IP=${IP:-<server-ip>}
printf '\nJenkins is up.\n'
printf '  URL:              http://%s:%s\n' "$IP" "$JENKINS_PORT"
printf '  Initial password: '
cat /var/lib/jenkins/secrets/initialAdminPassword
printf '\n\nPaste the password into the "Unlock Jenkins" page to finish setup.\n'
```

## 2. Ansible reference (alternative sketches, not the build path)

These playbook sketches come from the Ansible notes. They are kept as
reference material for a possible future Ansible-managed deployment.
The installer script in section 1 remains the build path.

```yaml
---
- name: Deploy Jenkins CI
  hosts: jenkins_server
  remote_user: vagrant
  become: yes
  roles:
    - geerlingguy.repo-epel
    - geerlingguy.jenkins
    - geerlingguy.git
    - tecris.maven
    - geerlingguy.ansible

- name: Configure On-Premises CentOS
  hosts: app_server
  remote_user: vagrant
  become: yes
  roles:
    - jenkins-keys-config
```

## 3. Migration runbook

Use this when moving an existing Jenkins instance to a new host. The
goal is a controlled content migration, not a blind copy of the old
server.

### 3.1 Scope

Content that normally moves:

- Jobs (freestyle and pipeline), including folders
- Credentials
- Nodes and agents
- Global configuration
- Plugins, aligned by version rather than copied blindly

Decide up front whether these move or get archived instead:

- Build history and build logs (can be very large)
- Workspace data (usually skipped)
- Artifacts (move, or archive externally)

### 3.2 Ground rules

- Freeze the source first, back it up second, migrate third.
- Do not copy the entire Jenkins home directory into the new server.
- Align plugins on the target before importing jobs.
- Credentials only survive the move if the encryption material moves
  with them.
- Validate on the new instance before cutover, and keep the old
  instance intact for rollback.

In the steps below, `$JENKINS_HOME` means the actual Jenkins home on
each machine. The package installer's home is `/var/lib/jenkins`;
container installs often use `/var/jenkins_home`. The source notes mix
both, so always confirm the real path on the host in front of you.

### 3.3 Freeze and back up the source

Put the old Jenkins into quiet mode so no new builds start:

```text
http://old-jenkins/quietDown
```

Stop the service or otherwise prevent new builds, then take a full
backup of the source Jenkins home:

```bash
tar -czvf jenkins-full-backup.tar.gz $JENKINS_HOME
```

### 3.4 Copy selectively

Copy these from the source:

```text
jobs/
credentials.xml
secrets/
users/        (if local user accounts must move)
nodes/        (if agent definitions must move)
```

Do not copy these directly:

```text
plugins/      (version mismatch risk; reinstall on the target instead)
war/
cache/
workspace/    (usually skipped)
logs/
```

Treat the source `config.xml` as a reference, not a file to drop in
whole. The same applies to global configuration files such as:

```text
config.xml
jenkins.model.JenkinsLocationConfiguration.xml
hudson.tasks.Mailer.xml
```

Compare old and new, then reapply the settings that matter: Jenkins
URL, executors, tool installations, and environment variables.

### 3.5 Align plugins on the target

List the source plugins:

```bash
ls $JENKINS_HOME/plugins | sed 's/.jpi//g' > plugins.txt
```

Install plugins on the new instance from the plugin manager or the
CLI, preferring current compatible versions over exact old copies.
Validate the critical ones before importing jobs: Pipeline,
Credentials, and Folders.

### 3.6 Move the jobs

Option A, filesystem copy (fast, good for bulk moves):

```bash
rsync -avz old:/var/lib/jenkins/jobs/ new:/var/lib/jenkins/jobs/
systemctl restart jenkins
```

Option B, API and XML (better for selective moves of critical jobs):

```bash
curl http://old/job/my-job/config.xml -o config.xml
curl -X POST http://new/createItem?name=my-job      --data-binary @config.xml      -H "Content-Type: text/xml"
```

Option C, Jenkins CLI (one job at a time):

```bash
java -jar jenkins-cli.jar -s http://JENKINS_IP:JENKINS_PORT get-job JOB_NAME > JOB_NAME.xml
java -jar jenkins-cli.jar -s http://JENKINS_IP:JENKINS_PORT create-job JOB_NAME < JOB_NAME.xml
```

The Job Import plugin is a fourth option for job-only moves. Whichever
method is used, missing plugins, broken pipeline scripts, and
hardcoded node labels are the usual load failures.

### 3.7 Move credentials

Credentials are encrypted with the instance master key, so these move
together or not at all:

```bash
cp -r secrets/* /var/lib/jenkins/secrets/
cp credentials.xml /var/lib/jenkins/
systemctl restart jenkins
```

If credentials do not decrypt on the new instance, recreate them
manually. Treat that as the expected fallback, not a surprise.

### 3.8 Agents and nodes

Copy `nodes/` if agent definitions move, but expect rework when
hostnames, SSH keys, or labels changed. Validate that each agent
connects and that pipeline labels resolve to the intended agents.

### 3.9 Build history (optional)

If history must move:

```bash
cp -r jobs/*/builds/ new/jobs/*/builds/
```

Risks: very large size and slow startup on the new instance. Keeping
only the last few builds per job, or archiving history externally, is
usually the better call.

### 3.10 Validation checklist

Run this before cutover. Tier 1 jobs (production deploys, release
pipelines, security builds) get the full checklist. Tier 2 jobs (CI
and integration builds) get the standard checks. Tier 3 jobs (dev,
test, and legacy jobs) get basic validation.

Job loading and configuration:

- Job appears in the new Jenkins, in the correct folder
- Job configuration opens with no missing plugin warnings
- SCM URL and branch settings preserved
- Build triggers intact (webhooks and cron schedules)
- Parameters and environment variables correct
- Tool versions valid (JDK, Node, Maven, and similar)

Credentials and agents:

- Every credential ID resolves and secrets decrypt successfully
- External integrations authenticate (Git, artifact repository, cloud
  providers)
- Correct node label assigned, job runs on the expected agent
- Workspace path valid and required tools present on the agent

Build test (mandatory for critical jobs):

- At least one full build runs end to end
- All stages execute with no plugin or runtime errors
- Artifacts are produced and archived at valid paths
- Webhooks trigger builds, notifications arrive, downstream jobs fire
- Console log is readable with no recurring warnings or errors

Dependency sweep:

- No old Jenkins URLs left in job or pipeline configuration
- No stale paths from the old host (for example under
  `/var/lib/jenkins/`)
- No legacy agent names or hostnames
- Shared libraries resolve at the correct version
- Job can run repeatedly without leftover workspace conflicts

Tracking fields per job: job name, tier, migrated, builds tested,
credentials OK, agent OK, notes, status.

### 3.11 Final sync, cutover, and rollback

1. Freeze the old Jenkins again with quietDown.
1. Run a final delta sync of the jobs.
1. Restart the new Jenkins.
1. Switch DNS or the load balancer to the new instance.
1. Disable the old Jenkins and watch the new instance's log:

```bash
tail -f /var/log/jenkins/jenkins.log
```

Rollback is simple because the old instance stays intact: switch DNS
back.

Cutover criteria from the source notes: all Tier 1 jobs validated, at
least 90 percent of Tier 2 jobs validated, no credential failures, no
plugin errors, and agents stable under load.

### 3.12 Top failure points

- Credentials not decrypting: the secrets material did not move with
  `credentials.xml`. Recreate the credentials manually.
- Plugin mismatch: jobs fail to load or fail at runtime on missing
  dependency plugins. Install the missing plugins at compatible
  versions.
- Hardcoded paths and URLs: pipelines still reference the old
  workspace paths, the old Jenkins URL, or old hostnames. Update the
  pipelines.

## 4. Removal

The public repo carries the companion removal playbook at
`ansible/playbooks/cleanup/uninstall_jenkins.yml`. It is the pointer
for tearing a Jenkins install back out; its content stays canonical in
the repo and is not duplicated here.

## 5. What was not carried over

- Conversation filler from the source notes (assistant preambles,
  closing offers to generate more material, and emoji decoration).
- The repeated generic migration explainers in `jenkins.txt`, which
  said the same thing three times; they are compressed into section 3.
- The Exodus notes' auto-generated table of contents and duplicated
  checklists; the substance is in sections 3.1 to 3.12.
- The Ansible install draft in `jenkins-install.txt` as a procedure:
  it installs Java 11 and a `jenkins` package without configuring the
  Jenkins repository, and current Jenkins LTS runs on Java 17 or 21.
  Its two sound guardrails (pre-check for an existing install, back up
  existing configuration first) are folded into section 1.
