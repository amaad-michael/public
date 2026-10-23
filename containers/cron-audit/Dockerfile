# syntax=docker/dockerfile:1
# Fleet cron audit — container form of scripts/monitoring/
# local_cron_checker.sh + remote_cron_checker.sh (Ansible form:
# ansible/playbooks/audits/cron_audit.yml).
#
# The image is a collector, not a daemon: cron-audit.sh reads host
# cron state either from a mounted host filesystem (--root, the
# compose default) or over SSH (--ssh), and prints the bash checkers'
# report format to stdout. Which mode can see what is documented in
# README.md — mounted mode cannot see systemd timers, and neither
# mode invents data it cannot read.
#
# Base pinned by digest (multi-arch index: linux/amd64 and
# linux/arm64 v8, so the same Dockerfile builds on the Pis) —
# re-verify the digest before bumping it.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

LABEL org.opencontainers.image.title="cron-audit" \
      org.opencontainers.image.description="Container form of the fleet cron audit (mounted-root and SSH collection modes)" \
      org.opencontainers.image.base.name="debian:bookworm-slim"

# openssh-client is the only addition SSH mode needs; everything else
# (bash, awk, find, grep, ls, cat) is in the base image. The collection
# commands for SSH mode run on the target host, not in the image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY cron-audit.sh /usr/local/bin/cron-audit.sh
RUN chmod 0755 /usr/local/bin/cron-audit.sh

# Runs as root: host crontab spools are root-only (0700 directories,
# 0600 files), and the bash checkers require root for the same reads.
USER root
WORKDIR /var/log/cron_audit

ENTRYPOINT ["/usr/local/bin/cron-audit.sh"]
CMD ["--root", "/host"]
