# syntax=docker/dockerfile:1
# Vulnerability scanner node — container equivalent of
# ansible/playbooks/vuln/setup_scanner.yml. Same toolset as the
# playbook installs on a bare-metal scanner node:
#   nmap, python3, pip, git, plus the pip packages requests
#   and dnspython, with /opt/tatum_audit as the workspace.
# The playbook targets Debian- and RHEL-family nodes; the image
# uses the Debian variant's package set.
#
# The base is pinned by digest (multi-arch index: linux/amd64 and
# linux/arm64 v8, so the same Dockerfile builds on the Pis) —
# re-verify the digest before bumping it.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

LABEL org.opencontainers.image.title="scanner-node" \
      org.opencontainers.image.description="Container equivalent of ansible/playbooks/vuln/setup_scanner.yml (nmap + python3 + requests/dnspython)" \
      org.opencontainers.image.base.name="debian:bookworm-slim"

# Playbook steps 1-3: refresh the package cache, install nmap,
# python3, git, and pip. Debian bookworm marks the system python
# externally managed (PEP 668), so the pip packages go into a
# dedicated venv instead of the system environment — same
# packages the playbook's pip step installs, isolated.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        nmap \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/scanner-venv \
    && /opt/scanner-venv/bin/pip install --no-cache-dir \
        requests \
        dnspython \
    && chmod -R a+rX /opt/scanner-venv

# Playbook step 4: the audit workspace. On the node it is
# root:root 0750; in the image it belongs to the unprivileged
# scanner user so scans can write output there (see README).
RUN useradd --create-home --uid 1000 scanner \
    && mkdir -p /opt/tatum_audit \
    && chown scanner:scanner /opt/tatum_audit \
    && chmod 0750 /opt/tatum_audit

ENV PATH="/opt/scanner-venv/bin:$PATH"
WORKDIR /opt/tatum_audit
USER scanner

# Run-on-demand tool container, not a daemon: the default command
# is a shell; scans are one-shot `docker compose run` invocations.
CMD ["/bin/bash"]
