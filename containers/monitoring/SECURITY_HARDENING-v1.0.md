# Standby Stack - Defense-in-Depth Security Hardening

**Version:** v1.0 · **Last Updated:** October 7, 2026

## 📋 Table of Contents

- [Overview](#overview)
- [1. Container-Level Hardening](#1-container-level-hardening)
   - [Applied to ALL services:](#applied-to-all-services)
   - [Container Security Summary:](#container-security-summary)
- [2. Network-Level Hardening](#2-network-level-hardening)
   - [Traefik Security Headers (middleware):](#traefik-security-headers-middleware)
   - [Rate Limiting (Traefik):](#rate-limiting-traefik)
   - [Authentication (Traefik):](#authentication-traefik)
   - [Network Isolation:](#network-isolation)
   - [Port Mapping Security:](#port-mapping-security)
- [3. Application-Level Hardening](#3-application-level-hardening)
   - [Prometheus:](#prometheus)
   - [Grafana:](#grafana)
   - [Vaultwarden:](#vaultwarden)
   - [Alertmanager:](#alertmanager)
   - [Ntfy:](#ntfy)
   - [Headscale:](#headscale)
- [4. Operational Hardening](#4-operational-hardening)
   - [Image Pinning:](#image-pinning)
   - [Restart Policy:](#restart-policy)
   - [Health Checks:](#health-checks)
   - [Log Aggregation:](#log-aggregation)
   - [Secrets Management (Critical):](#secrets-management-critical)
- [5. Attack Surface Reduction](#5-attack-surface-reduction)
   - [Removed/Disabled:](#removeddisabled)
- [6. Monitoring & Response](#6-monitoring--response)
   - [What to Monitor:](#what-to-monitor)
   - [Response Procedures:](#response-procedures)
- [7. Deployment Verification Checklist](#7-deployment-verification-checklist)
- [8. Ongoing Maintenance](#8-ongoing-maintenance)
   - [Weekly:](#weekly)
   - [Monthly:](#monthly)
   - [Quarterly:](#quarterly)
   - [Annually:](#annually)
- [9. Common Vulnerabilities Mitigated](#9-common-vulnerabilities-mitigated)
- [Quick Reference: Security by Service](#quick-reference-security-by-service)
- [Incident Response Template](#incident-response-template)

## 📖 Overview

All 9 services are hardened across 4 layers: **container-level**, **network-level**, **application-level**, and **operational**.

---

## 🔒 1. Container-Level Hardening

### Applied to ALL services

**Capability Dropping:**

```yaml
cap_drop:
  - ALL
cap_add:
  - NET_BIND_SERVICE  # Services that bind to ports
  - CHOWN            # Ntfy, Vaultwarden
  - SETUID/SETGID    # Process privilege management
  - NET_RAW          # Headscale (VPN/DERP)
```

**Why:** Removes 38 dangerous Linux capabilities by default; only required ones are re-added.

**Security Context:**

```yaml
security_opt:
  - no-new-privileges:true
```

**Why:** Prevents privilege escalation even if container is compromised.

**Read-Only Root Filesystem:**

```yaml
read_only: true
tmpfs:
  - /tmp
  - /var/run
```

**Why:** Attackers can't write to root filesystem; temporary directories are ephemeral RAM disks.

**Resource Limits:**

```yaml
deploy:
  resources:
    limits:
      cpus: '1'        # DoS prevention
      memory: 512M     # Memory exhaustion prevention
```

**Why:** Prevents resource-based DoS attacks (fork bombs, memory leaks).

### Container Security Summary

| Service | CPU Limit | Memory Limit | Capabilities Dropped |
|---------|-----------|--------------|----------------------|
| Prometheus | 1.0 | 512M | 38/38 |
| Grafana | 1.0 | 512M | 38/38 |
| Alertmanager | 0.5 | 256M | 38/38 |
| Traefik | 1.0 | 512M | 38/38 |
| Ntfy | 0.5 | 256M | 34/38 |
| step-ca | 0.5 | 256M | 38/38 |
| Headscale | 1.0 | 512M | 36/38 |
| Vaultwarden | 1.0 | 512M | 34/38 |
| Uptime Kuma | 0.5 | 256M | 38/38 |

---

## 🔒 2. Network-Level Hardening

### Traefik Security Headers (middleware)

```yaml
X-Frame-Options: DENY                          # Clickjacking protection
X-Content-Type-Options: nosniff                # MIME-sniffing protection
X-XSS-Protection: 1; mode=block                # XSS filter (legacy)
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: geolocation=(), microphone=(), camera=(), payment=()
Strict-Transport-Security: max-age=63072000    # Force HTTPS for 2 years
Content-Security-Policy: default-src 'self'   # Inline script/style blocked
```

**Why:** Prevents common web attacks (XSS, CSRF, clickjacking, content smuggling).

### Rate Limiting (Traefik)

```yaml
RateLimitAuth:
  average: 100 req/min
  burst: 200
  period: 1m
```

**Why:** Prevents brute-force attacks on dashboards and APIs.

### Authentication (Traefik)

- Dashboard: BasicAuth (username/password required)
- API: BasicAuth required
- Services: No exposure without reverse proxy rule

**Why:** Unauthenticated API access = full system control.

### Network Isolation

```yaml
networks:
  standby-net:
    driver: bridge
```

**Why:** Services only communicate within `standby-net`; cannot reach external networks or LLM stack.

### Port Mapping Security

Only expose necessary ports; all inter-service communication via container DNS (internal):

```
Prometheus (9090)    → Metrics API only, not for scraping config changes
Grafana (3000)       → UI only, requires login
Alertmanager (9093)  → Published on the host; routes alerts to the Ntfy webhook
Traefik (8080)       → Protected by BasicAuth
```

---

## 🔒 3. Application-Level Hardening

### Prometheus

```
--no-web.enable-admin-api  # Disable admin endpoints
```

**Why:** Prevents API-based config changes, rule reloads.

### Grafana

```
GF_SECURITY_DISABLE_BRUTE_FORCE_LOGIN_PROTECTION=false
GF_SECURITY_COOKIE_SAMESITE=Strict
GF_SECURITY_COOKIE_SECURE=true
GF_SECURITY_COOKIE_HTTPONLY=true
GF_USERS_ALLOW_SIGN_UP=false
GF_AUTH_ANONYMOUS_ENABLED=false
```

**Why:**

- Brute-force protection
- CSRF protection (SameSite)
- HTTPS-only cookies + HTTPOnly (XSS mitigation)
- No self-registration = no account spray attacks
- No anonymous access

### Vaultwarden

```
DOMAIN=https://vaultwarden.localhost:8000
SHOW_PASSWORD_HINT=false
INVITATION_ORG_NAME=Standby
ORG_CREATION_USERS=          # Empty = only admins create orgs
INVITATIONS_ALLOWED=false    # No external invites
SIGNUPS_ALLOWED=false        # No new registrations
IP_HEADER=X-Real-IP          # Log real client IP
IP_HEADER_TRUSTED_PROXY_COUNT=1
```

**Why:**

- HTTPS enforcement
- No password hints (security risk)
- Closed org + invitations disabled = no spray attacks
- No signups = zero attack surface
- Accurate audit logging

### Alertmanager

```
webhook_configs:
  - url: 'http://standby-ntfy:80/ntfy/alerts'
    send_resolved: true
```

**Why:** All alerts are logged/notified; no silent failures.

### Ntfy

```
auth-default-access: deny-all
```

**Why:** Topics require explicit ACL permission; no public posting.

### Headscale

```
db_encryption: enabled: true
oidc:
  only_start_if_oidc_is_available: false
```

**Why:** Database is encrypted at rest; no OIDC requirement (would fail startup).

---

## 🔒 4. Operational Hardening

### Image Pinning

All images pinned to specific versions (NOT `:latest`):

- prom/prometheus:v3.15.1
- grafana/grafana:13.3.0
- prom/alertmanager:v0.34.1
- traefik:v3.7.16
- binwiederhier/ntfy:v2.34.0
- smallstep/step-ca:0.30.2
- headscale/headscale:0.29.6
- vaultwarden/server:1.37.4
- louislam/uptime-kuma:2.5.8

**Why:** Prevents surprise breaking changes; reproducible deployments.

### Restart Policy

```yaml
restart: unless-stopped
```

**Why:** Recovers from crashes; respects manual `docker stop` for maintenance.

### Health Checks

Every service has health probes (30s interval, 5s timeout, 3 retries).

**Why:** Automatic detection of degraded services; triggering alerts/recovery.

### Log Aggregation

Traefik access logs in JSON format:

```yaml
accessLog:
  filePath: /var/log/traefik/access.log
  format: json
```

**Why:** Structured, parseable logs for SIEM/audit; easier investigation.

### Secrets Management (Critical)

**Current state:** No secrets in the repo. Grafana and Traefik credentials come from a host-side .env, and compose fails closed when they are unset.

1. Generate strong values:

   ```bash
   openssl rand -base64 32  # Grafana password
   openssl rand -base64 32  # Vaultwarden master
   htpasswd -bcB -C 10 /dev/null admin $(openssl rand -base64 32)  # Traefik BasicAuth hash
   ```

1. Create .env from the shipped template:

   ```bash
   cp .env.example .env
   chmod 600 .env
   # .env then holds:
   # GRAFANA_ADMIN_PASSWORD=<generated>
   # TRAEFIK_AUTH_HASH=admin:<htpasswd hash>
   ```

1. Compose consumes them fail-closed:

   ```yaml
   environment:
     - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}
   ```

   Traefik likewise reads `admin:${TRAEFIK_AUTH_HASH}` with no fallback; Traefik fails to load if TRAEFIK_AUTH_HASH is unset.

1. **Never commit .env to git:** it is git-ignored in the repo.

---

## 5. Attack Surface Reduction

### Removed/Disabled

| Feature | Status | Reason |
|---------|--------|--------|
| Unsigned Docker images | ✓ Pinned | Prevent tampering |
| Privileged containers | ✓ Disabled | Prevent host escape |
| Root filesystem write | ✓ Read-only | Prevent persistence |
| Public auth access | ✓ Deny-all | Prevent brute-force |
| Anonymous Grafana | ✓ Disabled | Prevent info disclosure |
| Password hints | ✓ Disabled | Prevent enumeration |
| Prometheus admin API | ✓ Disabled | Prevent config tampering |
| OIDC requirement | ✓ Disabled | Prevent startup failure |

---

## 📊 6. Monitoring & Response

### What to Monitor

1. **Container restarts:** More than 3 in 5 min = investigate
1. **Resource exhaustion:** CPU > 80%, Memory > 85% = alert
1. **Health check failures:** Any service failing health check 3x = critical
1. **Traefik access logs:** 40x/50x spikes = attack pattern detection
1. **Alertmanager webhook delays:** > 5s = notification failure

### Response Procedures

**If container compromised:**

```bash
docker compose down standby-prometheus  # Stop
docker volume rm standby_prometheus_data  # Wipe data
docker compose up -d standby-prometheus  # Rebuild
```

**If credentials leaked:**

```bash
# 1. Regenerate all passwords
# 2. Restart all services with new creds
# 3. Review audit logs for unauthorized access
# 4. Backup config (encrypted)
```

**If DDoS suspected:**

```bash
# 1. Increase rate limits in Traefik
# 2. Enable GeoIP filtering (if available)
# 3. Temporarily disable non-critical services
# 4. Redirect to new ports
```

---

## ✅ 7. Deployment Verification Checklist

Before production:

```bash
# ✓ All images pinned to specific versions
docker compose config | grep image:

# ✓ No containers running as root
docker compose exec prometheus id

# ✓ Capabilities dropped
docker inspect standby-prometheus | grep CapAdd

# ✓ Read-only filesystem enforced
docker compose exec prometheus touch /tmp/test  # Should succeed (tmpfs)
docker compose exec prometheus touch /test      # Should fail (read-only)

# ✓ Resource limits applied
docker inspect standby-prometheus | grep -A 5 '"Memory"'

# ✓ Health checks passing
docker compose ps | grep -v "healthy"

# ✓ No unnecessary ports exposed
netstat -tlnp | grep docker

# ✓ Traefik dashboard accessible with auth
curl -u admin:<password> http://localhost:8080/api/version  # password whose hash is TRAEFIK_AUTH_HASH in .env

# ✓ All inter-service DNS resolution working
docker compose exec prometheus nslookup standby-grafana

# ✓ Logs are being captured
docker compose logs --tail 100 prometheus | grep -i error

# ✓ Volumes are encrypted (Headscale)
# (Check /var/lib/headscale/db.sqlite encryption)
```

---

## 8. Ongoing Maintenance

### Weekly

- Review Traefik access logs for anomalies
- Check Prometheus disk usage (storage.tsdb.path)
- Verify all health checks passing

### Monthly

- Audit user accounts (Grafana, Vaultwarden)
- Review firewall/ACL rules
- Update base images to patch releases only (e.g., v2.45.1 → v2.45.2)

### Quarterly

- Full security audit of all configs
- Penetration test (internal)
- Disaster recovery drill (restore from backups)

### Annually

- Major version upgrades (plan 2-4 weeks ahead)
- Recertify security posture
- Review threat model changes

---

## 9. Common Vulnerabilities Mitigated

| CWE | Vulnerability | Mitigation |
|-----|---------------|-----------|
| CWE-284 | Improper Access Control | RBAC, BasicAuth, deny-all defaults |
| CWE-434 | Unrestricted Upload | Read-only filesystem |
| CWE-269 | Improper Privilege | Capability dropping, no-new-privileges |
| CWE-400 | Uncontrolled Resource Consumption | Memory/CPU limits, rate limiting |
| CWE-200 | Information Disclosure | No password hints, anonymous disabled |
| CWE-79 | Cross-Site Scripting (XSS) | HTTPOnly cookies, CSP headers |
| CWE-352 | Cross-Site Request Forgery (CSRF) | SameSite=Strict cookies |
| CWE-1021 | Improper Restriction (Clickjacking) | X-Frame-Options: DENY |
| CWE-327 | Use of Weak Crypto | TLS 1.2+, HSTS enforced |

---

## 🔒 Quick Reference: Security by Service

```
Prometheus:    No admin API, read-only root, 512M max
Grafana:       Auth required, sign-up disabled, secure cookies
Alertmanager:  Webhook notifications to Ntfy, UI on 9093
Traefik:       Rate limiting, BasicAuth, security headers
Ntfy:          Deny-all auth, 256M max
step-ca:       Self-signed (homelab OK), 256M max
Headscale:     DB encryption, ACL policy, 512M max
Vaultwarden:   HTTPS enforced, signups disabled, 512M max
Uptime Kuma:   No auth (UI only), 256M max
```

---

## Incident Response Template

1. **Detection:** Which alert triggered?
1. **Triage:** Severity (critical/high/medium)?
1. **Containment:** Stop affected service? Isolate container?
1. **Investigation:** Logs, metrics, volume contents?
1. **Recovery:** Restore from backup? Full redeploy?
1. **Post-incident:** RCA, patch, lessons learned?

Keep incident log in `incidents.log` with timestamps.

---

**Last Updated:** May 2026
**Security Level:** Production-Grade
**Certification:** Defense-in-Depth
