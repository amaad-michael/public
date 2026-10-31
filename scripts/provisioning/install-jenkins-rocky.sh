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
JENKINS_REPO_URL="${JENKINS_REPO_URL:-https://pkg.jenkins.io/redhat-stable/jenkins.repo}"
JENKINS_KEY_URL="${JENKINS_KEY_URL:-https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key}"
# SHA-256 pins for the two Jenkins downloads, captured from
# pkg.jenkins.io on 2026-10-28 (the key's fingerprint is
# 6366 7EE7 4BBA 1F0A 08A6 9872 5BA3 1D57 EF59 75CA, Jenkins
# Project). A mismatch aborts before either file is used. If
# Jenkins rotates either file, refresh the pins deliberately.
JENKINS_REPO_SHA256="e0c5dfddcb06856e319b2e4c78a6997a2edf7a8bf87554075105e35bc49e6859"
JENKINS_KEY_SHA256="f1c175f9e68915d8d861e2884b40b77a9b763a32735bc996cd6a29639b2563e5"
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
# shellcheck disable=SC1091 # /etc/os-release is a system file, absent at lint time
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

# --- Jenkins repository (hash-verified before any dnf transaction) ---------
REPO_FILE=/etc/yum.repos.d/jenkins.repo
TMPKEY=""
TMPREPO=""
cleanup() { [[ -n "$TMPKEY" ]] && rm -f "$TMPKEY"; [[ -n "$TMPREPO" ]] && rm -f "$TMPREPO"; }
trap cleanup EXIT
if [[ -s $REPO_FILE ]]; then
    info "jenkins repo already present at $REPO_FILE; verifying its pinned hash"
    printf '%s  %s\n' "$JENKINS_REPO_SHA256" "$REPO_FILE" | sha256sum -c - >/dev/null \
        || die "existing $REPO_FILE does not match the pinned SHA-256; refusing to use an unverified repo file"
else
    info "adding Jenkins stable repository (hash-verified)"
    TMPREPO=$(mktemp)
    curl -fsSL "$JENKINS_REPO_URL" -o "$TMPREPO"
    printf '%s  %s\n' "$JENKINS_REPO_SHA256" "$TMPREPO" | sha256sum -c - >/dev/null \
        || die "downloaded jenkins.repo does not match the pinned SHA-256; aborting before install"
    install -m 0644 "$TMPREPO" "$REPO_FILE"
fi
info "importing Jenkins GPG key (hash-verified)"
TMPKEY=$(mktemp)
curl -fsSL "$JENKINS_KEY_URL" -o "$TMPKEY"
printf '%s  %s\n' "$JENKINS_KEY_SHA256" "$TMPKEY" | sha256sum -c - >/dev/null \
    || die "downloaded Jenkins key does not match the pinned SHA-256; aborting before import"
rpm --import "$TMPKEY"

# --- Java + prerequisites ---------------------------------------------------
info "installing Java ${JAVA_VER} and prerequisites"
dnf install -y "java-${JAVA_VER}-openjdk" fontconfig curl

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
