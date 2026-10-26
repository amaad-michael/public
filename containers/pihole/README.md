# Pi-hole + Unbound

A two-container DNS pair: Pi-hole for filtering and the LAN-facing DNS
service, Unbound as the recursive resolver behind it. The same compose
file runs on both DNS hosts. Per the compose header, pi4 is the primary
and pi0 the secondary.

## 📦 Contents

- [📦 Files](#-files)
- [⚙️ The .env file (required)](#-the-env-file-required)
- [🌐 Networking and ports](#-networking-and-ports)
- [Volumes and persistence](#volumes-and-persistence)
- [DNSSEC](#dnssec)
- [First start and blocklists](#first-start-and-blocklists)
- [✅ Verify](#-verify)
- [🔄 Upgrade and rollback](#-upgrade-and-rollback)
- [🔒 Hardening posture](#-hardening-posture)

## 📦 Files

- `docker-compose.yml`: both services, the `pihole-backup` bridge
  network (172.20.0.0/16), and three named volumes.
- `pi-dns-env.example`: template for the host-side `.env` (image pins
  and the Pi-hole API password).
- `unbound.conf`: the Unbound configuration, bind-mounted read-only
  into the Unbound container at its compiled-in config path,
  `/usr/local/unbound/unbound.conf`.
- `legacy/docker-compose.yml` and `legacy/unbound.conf`: the pre-v2
  stack as deployed on pi0 and pi4 (`:latest` tags, Unbound published
  on host port 5053, the `/etc/unbound` config layout), kept as the
  as-built record only — not a deployable rollback. Two facts,
  verified 2026-10-25, govern its status. First, the image starts
  Unbound with its own built-in config (its entrypoint runs
  `unbound -c /usr/local/unbound/unbound.conf`); the config this
  compose mounts at `/etc/unbound/unbound.conf` is never read, so
  the running resolver uses the image's defaults and this file's
  settings are not in effect. Second, the file could not be loaded
  if it were read: every published madnuttah/unbound build from
  1.16.3 through 1.26.2 rejects it — five lines no current build
  accepts (two removed legacy keywords, and three lines that were
  never Unbound keywords), plus a trust-anchor path in the legacy
  `/opt/unbound` layout. The file is preserved exactly as deployed,
  not modernized. For a rollback, deploy the main stack above.

## ⚙️ The .env file (required)

Compose refuses to start until all three values are set in a `.env`
file beside the compose file. The image references carry fail-closed
guards (`${PIHOLE_TAG:?...}`), so there is no `:latest` fallback on the
DNS plane.

```bash
cp pi-dns-env.example .env
chmod 600 .env
```

Then fill in:

- `PIHOLE_TAG`: pinned tag for `pihole/pihole`. Check the current
  stable tag at <https://hub.docker.com/r/pihole/pihole/tags>.
- `UNBOUND_TAG`: pinned tag for `madnuttah/unbound`. Check
  <https://hub.docker.com/r/madnuttah/unbound/tags>.
- `PIHOLE_API_PASSWORD`: the Pi-hole web/API password. It reaches the
  container as `FTLCONF_webserver_api_password`. The previous inline
  password was exposed in plaintext and is burned; never put the value
  in the compose file.

The `.env` is covered by the repo `.gitignore`. Never commit it.

## 🌐 Networking and ports

| Service | Container address | Host ports | Notes |
| --- | --- | --- | --- |
| pihole | 172.20.0.2 | 53/tcp, 53/udp, 80, 443 | The only LAN-facing service |
| unbound | 172.20.0.3 | none | Reachable only on the `pihole-backup` network |

Pi-hole's only upstream is Unbound:
`FTLCONF_dns_upstreams=172.20.0.3#5335`.

Unbound has no `ports:` block at all. That is deliberate: the v2 compose
closed the old LAN exposure of the resolver. Unbound listens on 5335
inside the container, and `unbound.conf` access control allows only
127.0.0.0/8 and 172.20.0.0/16, denying everything else. Do not publish
Unbound on the host; a monitoring tripwire on neo1
(`UnboundExposedToLAN`) alerts if a host publish reappears.

## Volumes and persistence

- `pihole_etc` at `/etc/pihole`: Pi-hole configuration and the gravity
  database. Survives container replacement and image upgrades.
- `pihole_dnsmasq` at `/etc/dnsmasq.d`: dnsmasq configuration snippets.
- `unbound_custom` at `/usr/local/unbound/custom.conf.d`: an include
  directory. It is only read if `unbound.conf` gains an
  `include: "/usr/local/unbound/custom.conf.d/*.conf"` line; the
  shipped config has none.

If volume permission errors appear on first start, fix volume
ownership. Do not restore the removed `PIHOLE_UID/GID=0` root override;
it cancelled the `cap_drop` hardening.

## DNSSEC

Validation happens once, in Unbound, the recursive layer. The compose
sets `FTLCONF_dns_dnssec=false` on Pi-hole because double validation at
the dnsmasq layer causes spurious SERVFAILs. `unbound.conf` carries the
hardening side: trust anchor at
`/usr/local/unbound/var/root.key`, root key sentinel, and the
harden-dnssec options. End-to-end enforcement is verified independently
by neo1's dnssec-failed.org probe.

## First start and blocklists

Deploy order, from the compose header: pi0 (secondary) first, verify,
then pi4 (primary).

Blocklist seeding uses the companion script
`scripts/pihole/pihole-init-blocklists.sh`. Note that the shipped
compose file does not invoke it: the script's header claim that it
runs automatically at container startup does not match the compose as
shipped, so run it manually once after the first start, against the
running container's `/etc/pihole/gravity.db`. It waits for the
database to exist, inserts five lists with `INSERT OR IGNORE` (so it
is safe to re-run), then triggers a gravity update with `pihole -g`:

- Hagezi Pro Mini
- Hagezi TIF Mini
- Hagezi Multi Normal
- Hagezi TIF Medium
- OISD Big

## ✅ Verify

Both services carry healthchecks. Pi-hole runs
`dig @127.0.0.1 pi.hole`; Unbound runs `unbound-host` against
example.com. If `unbound-host` is ever absent from the image, the
compose comments give the fallback check, `unbound-checkconf` against
the shipped config, noting that it validates the config only, not
resolution.

For a full check, run the DNS test suite in `scripts/pihole/` on the
host: `dns-test-pihole-unbound-linted.sh` runs eight dig checks from
inside the containers (Pi-hole local resolution, Unbound direct,
Pi-hole to Unbound routing in both port syntaxes, DNSSEC pass and
fail cases, and an ad-block check on doubleclick.net), writes
failures to a timestamped log in `/tmp`, and exits 1 if any check
fails.

## 🔄 Upgrade and rollback

Upgrade by editing the two tag values in `.env` to the new stable
tags, then `docker compose pull` and `docker compose up -d`. Rollback
is the same operation in reverse: restore the previous tag values and
re-run `docker compose up -d`. Configuration and gravity data persist
in the named volumes either way.

## 🔒 Hardening posture

Both containers run with `cap_drop: ALL` and
`no-new-privileges: true`. Pi-hole adds back only the capabilities it
needs (`NET_BIND_SERVICE`, `CHOWN`, `SETUID`, `SETGID`, `SETFCAP`); if
its healthcheck flaps or the logs show capability errors, the compose
comments name `NET_RAW` as the first suspect to add. Resource limits
are 0.5 CPU and 256M for Pi-hole, 0.25 CPU and 128M for Unbound.
Unbound logging is query and reply logging off, with servfail and
local-action logging on.
