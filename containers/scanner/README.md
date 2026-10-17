# Scanner node (container)

A run-on-demand vulnerability scanner: the container equivalent of
`ansible/playbooks/vuln/setup_scanner.yml`. The playbook builds a
persistent scanner node on a Debian- or RHEL-family host; this stack
ships the same toolset as a portable image you run for a scan and
throw away.

## Toolset (mirrors the playbook exactly)

- `nmap` — the scanner itself, with the NSE script library
- `python3` with `pip` — the playbook's scripting runtime
- The playbook's two pip packages: `requests` and `dnspython`
- `git` — for pulling scan scripts and reporting code
- `/opt/tatum_audit` — the playbook's workspace directory, used as
  the working directory and persisted in the `scanner_workspace`
  volume so scan output survives the one-shot container

One packaging difference: Debian bookworm marks the system python
externally managed (PEP 668), so the pip packages live in a venv at
`/opt/scanner-venv`, first on `PATH`. The packages are the same; on
the node they sit in the system environment instead.

## Build and verify

```bash
cd containers/scanner
docker compose build
docker compose run --rm scanner nmap --version
docker compose run --rm scanner python3 -c "import requests, dns; print(requests.__version__, dns.__version__)"
```

## Usage

Version and service scan of a single host:

```bash
docker compose run --rm scanner nmap -sV 192.168.0.105
```

Scan of the local host's common ports, output saved into the
workspace volume:

```bash
docker compose run --rm scanner nmap -sT -sV -oN scan-local.txt 127.0.0.1
```

LAN discovery sweep (needs host networking, the shipped default —
see below):

```bash
docker compose run --rm scanner nmap -sn 192.168.0.0/24
```

## Network mode: host, and the tradeoff

The compose file sets `network_mode: host`. That is a deliberate
choice for a LAN scanner, not a shortcut:

- Behind the default bridge NAT, the container sees the docker
  bridge, not the LAN. ARP ping sweeps (`-sn` with ARP) and
  broadcast discovery do not cross it, target replies come back to
  the bridge address, and the scan source is rewritten — discovery
  results are incomplete or misleading.
- Host mode puts the scanner directly on the host's interfaces, so
  discovery and scanning behave exactly as they do from the
  bare-metal node the playbook builds.
- The cost: the container shares the host's network namespace.
  There is no port-publishing isolation to configure or get wrong —
  but anything the scanner binds, it binds on the host. For a
  run-on-demand tool an operator starts by hand and exits, that is
  the right trade. It would not be the right default for a daemon.

For single-target connect scans, bridged mode works fine: delete
the `network_mode` line and the scan reaches its target through the
bridge like any outbound connection.

## Capabilities: what NET_RAW is for

The stack drops all capabilities and adds back only `NET_RAW`, and
runs as the unprivileged `scanner` user.

- Connect scans (`-sT`), version detection (`-sV`), and NSE scripts
  need no raw sockets and work as shipped.
- SYN scans (`-sS`), UDP scans (`-sU`), and OS detection (`-O`)
  build raw packets and need `NET_RAW`. As shipped, the capability
  plus the non-root user covers them when nmap can open raw sockets
  unprivileged; if a scan type still reports permission errors on
  your host, run that one scan as root
  (`docker compose run --rm --user root scanner nmap -sS ...`)
  rather than loosening the stack's defaults for every run.

## Canary (after any rebuild)

```bash
docker compose run --rm scanner nmap -sT -sV 127.0.0.1
docker compose run --rm scanner python3 -c "import dns.resolver, requests; print('py ok')"
docker compose run --rm scanner git --version
```

A healthy canary: nmap completes the localhost scan and reports the
host's listening services, the python check prints `py ok`, and git
reports its version.

## Notes

- The base image is `debian:bookworm-slim` pinned by digest in the
  Dockerfile (multi-arch: amd64 and arm64, so the Pis build the same
  image). Re-verify the digest before bumping it.
- The playbook also refreshes the node's package cache; inside an
  image build that is the `apt-get update` layer, nothing more is
  needed.
- This mirrors the playbook's toolset in portable form. The node
  remains the always-there scanner; the container is the same kit
  you can run from any Docker host.
