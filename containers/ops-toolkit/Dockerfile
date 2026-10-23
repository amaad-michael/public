# syntax=docker/dockerfile:1
# Ops Toolkit — container form of scripts/ops-toolkit/.
#
# The image packages the toolkit's six job scripts byte-identically
# (scripts/ in this project is a verbatim copy of scripts/ops-toolkit/,
# verified with cmp in the build notes) and runs them on the same
# schedule as the systemd timers, translated to cron format in the
# shipped crontab. The container scheduler is cron, not systemd:
# there is no systemd inside a container, so the .timer semantics that
# have no cron equivalent (Persistent=true catch-up runs and
# RandomizedDelaySec jitter) do not carry over. README.md states
# plainly which jobs are host-bound and what this form can and cannot
# do — read it before treating the container as an install.
#
# Base pinned by digest (multi-arch index: linux/amd64 and
# linux/arm64 v8, so the same Dockerfile builds on the Pis) —
# re-verify the digest before bumping it.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

LABEL org.opencontainers.image.title="ops-toolkit" \
      org.opencontainers.image.description="Container packaging of scripts/ops-toolkit (six scheduled ops jobs under cron)" \
      org.opencontainers.image.base.name="debian:bookworm-slim"

# Runtime dependencies named by the toolkit README: procps gives
# vmstat/free/ps for sys-health.sh, openssl + coreutils timeout for
# cert-expiry-audit.sh, logrotate for log-clean.sh, and `service`
# (init-system-helpers) is service-uptime.sh's fallback when systemctl
# is absent. cron is the scheduler.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        coreutils \
        cron \
        findutils \
        gzip \
        init-system-helpers \
        logrotate \
        openssl \
        procps \
    && rm -rf /var/lib/apt/lists/*

# Jobs, shared library, config, and lists — same destinations as the
# bash install (/usr/local/sbin, /etc/ops).
COPY scripts/*.sh /usr/local/sbin/
COPY scripts/ops.conf /etc/ops/ops.conf
COPY scripts/lists/services.txt scripts/lists/ssl_endpoints.txt /etc/ops/
COPY crontab /etc/cron.d/ops-toolkit
COPY entrypoint.sh /usr/local/sbin/entrypoint.sh

RUN chmod 0755 /usr/local/sbin/*.sh \
    && chmod 0644 /etc/ops/ops.conf /etc/ops/services.txt /etc/ops/ssl_endpoints.txt \
    && chmod 0644 /etc/cron.d/ops-toolkit \
    && install -d -m 0755 /var/log/ops /var/lib/ops-toolkit

WORKDIR /var/log/ops

# The scheduler is the point of this form: cron in the foreground.
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
CMD ["cron", "-f"]
