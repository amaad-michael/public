# syntax=docker/dockerfile:1
# Fleet firewall audit — container form of
# scripts/network/firewall_audit.sh (Ansible form:
# ansible/playbooks/firewall/firewall_audit.yml).
#
# A run-on-demand collector, not a daemon. It runs the bash audit's
# thirteen sections against the network namespace it shares with the
# host (the compose file sets network_mode: host) and holds
# CAP_NET_ADMIN so the ruleset reads (nft list ruleset, iptables -L)
# succeed against the host's tables. Every command it runs is a
# read/query; it changes no firewall state. README.md documents the
# access model, including the one section (firewalld queries) that
# additionally needs the host's system D-Bus socket.
#
# Base pinned by digest (multi-arch index: linux/amd64 and
# linux/arm64 v8, so the same Dockerfile builds on the Pis) —
# re-verify the digest before bumping it.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

LABEL org.opencontainers.image.title="firewall-audit" \
      org.opencontainers.image.description="Container form of the fleet firewall audit (host-netns collector)" \
      org.opencontainers.image.base.name="debian:bookworm-slim"

# The audit's toolset: iptables + nftables for the rulesets, iproute2
# for ss, lsof and procps for the listener/process sections,
# selinux-utils for getenforce, firewalld for firewall-cmd (queries
# only — no daemon is started in the image), systemd for journalctl,
# and net-tools as the bash audit's ss fallback.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        firewalld \
        iproute2 \
        iptables \
        lsof \
        net-tools \
        nftables \
        procps \
        selinux-utils \
        systemd \
    && rm -rf /var/lib/apt/lists/*

COPY firewall-audit.sh /usr/local/bin/firewall-audit.sh
RUN chmod 0755 /usr/local/bin/firewall-audit.sh \
    && install -d -m 0755 /var/log/firewall_audit

# Runs as root: reading rulesets and other processes' socket owners
# requires it, exactly like the bash audit's sudo'd commands.
USER root
WORKDIR /var/log/firewall_audit

ENTRYPOINT ["/usr/local/bin/firewall-audit.sh"]
CMD []
