# Secrets Management - Pre-Production Checklist

## Critical: There Are No Default Passwords

**The stack ships with no defaults. Set these in .env before first start:**

```
Grafana:       admin / the GRAFANA_ADMIN_PASSWORD value you set in .env
Traefik:       admin / the password whose bcrypt hash is TRAEFIK_AUTH_HASH in .env
Vaultwarden:   (no default - requires master account setup)
```

Compose fails closed without them: Grafana will not start until GRAFANA_ADMIN_PASSWORD is set, and Traefik fails to load its BasicAuth middleware until TRAEFIK_AUTH_HASH is set.

---

## 1. Generate Strong Secrets

```bash
# Generate 32-byte random secrets (base64 encoded)
GRAFANA_PASS=$(openssl rand -base64 32)
TRAEFIK_USER="admin"
TRAEFIK_PASS=$(openssl rand -base64 32)
VAULTWARDEN_DOMAIN_TOKEN=$(openssl rand -base64 32)

# For Traefik BasicAuth, hash password:
TRAEFIK_HASH=$(htpasswd -bcB -C 10 /dev/null "$TRAEFIK_USER" "$TRAEFIK_PASS" | cut -d: -f2)

echo "Grafana Admin Password: $GRAFANA_PASS"
echo "Traefik User: $TRAEFIK_USER"
echo "Traefik Password: $TRAEFIK_PASS"
echo "Traefik BasicAuth (TRAEFIK_AUTH_HASH): ${TRAEFIK_USER}:${TRAEFIK_HASH}"
```

**Store securely:**

- Password manager (Vaultwarden once deployed)
- Encrypted file (GPG)
- 1Password, Bitwarden, LastPass (external)
- **NEVER** commit to git or docker-compose.yml

---

## ⚙️ 2. Create .env from .env.example (NOT TRACKED BY GIT)

```bash
cp .env.example .env
# .env is git-ignored in the repo. DO NOT COMMIT IT.
# Set GRAFANA_ADMIN_PASSWORD in .env to the generated password (step 1),
# then append:
cat >> .env << 'EOF'

# Traefik BasicAuth (format: user:bcrypt-hash)
TRAEFIK_AUTH_HASH=admin:<htpasswd-hash>

# Optional: SMTP password, used only by the section 5 alertmanager.yml variant
ALERTMANAGER_SMTP_AUTH_PASSWORD=<app-password>
EOF

chmod 600 .env
```

The shipped alertmanager.yml routes alerts to the Ntfy webhook and
reads no environment values; the SMTP password above is only consumed
if you replace it with the SMTP variant in section 5.

---

## ⚙️ 3. How Compose Uses .env

**Before (legacy inline default):**

```yaml
environment:
  - GF_SECURITY_ADMIN_PASSWORD=<inline default>
```

**After (current, fail-closed):**

```yaml
environment:
  - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}
```

---

## 4. Traefik BasicAuth in traefik.yml

The shipped traefik.yml reads the hash from the environment with no fallback:

```yaml
middlewares:
  BasicAuth:
    basicAuth:
      users:
        - "admin:${TRAEFIK_AUTH_HASH}"
```

TRAEFIK_AUTH_HASH must be set (in .env) or Traefik fails to load. To rotate the dashboard password, generate a new hash and update .env:

```bash
# Generate hash locally:
htpasswd -bcB -C 10 /dev/null admin <new-password>
# Output: admin:$2y$10$...hash...

# Put the admin:<hash> value in TRAEFIK_AUTH_HASH in .env, then:
docker compose up -d traefik
```

---

## 5. Secure Alertmanager Email Integration (Optional)

Create `alertmanager.yml` with SMTP:

```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_auth_username: 'your-email@gmail.com'
  smtp_auth_password: '${ALERTMANAGER_SMTP_PASSWORD}'
  smtp_require_tls: true

route:
  receiver: 'default'

receivers:
  - name: 'default'
    email_configs:
      - to: 'admin@standby'
        from: 'alerts@standby'
        smarthost: 'smtp.gmail.com:587'
        auth_username: 'your-email@gmail.com'
        auth_password: '${ALERTMANAGER_SMTP_PASSWORD}'
```

**For Gmail, use an App Password:**

1. Enable 2FA on Gmail account
1. Generate App Password: <https://myaccount.google.com/apppasswords>
1. Use app password in `auth_password`

---

## 🚀 6. First-Time Setup (Post-Deployment)

### Vaultwarden Master Password

```bash
# 1. Navigate to http://localhost:8000
# 2. Create master account (this becomes ADMIN)
# 3. Enable 2FA immediately
# 4. Save recovery codes securely

# If using email invites, whitelist IPs:
docker compose exec vaultwarden /app/vaultwarden \
  --invitation-org-name "Standby" \
  --signups-allowed false
```

### Grafana Initial Setup

```bash
# 1. Navigate to http://localhost:3000
# 2. Log in: admin / the GRAFANA_ADMIN_PASSWORD value from .env
# 3. No forced change: you set this password in .env; it is not a default
# 4. Set organization
# 5. Add users (if needed)
# 6. Disable anonymous access (already done in compose)
```

### Traefik Dashboard Access

```bash
# Username: admin
# Password: ${TRAEFIK_PASS}
curl -u admin:${TRAEFIK_PASS} http://localhost:8080/api/version
```

---

## 💾 7. Backup Secrets

**Before scaling to production:**

```bash
# 1. Backup .env (encrypted)
gpg --symmetric .env  # Creates .env.gpg
rm .env               # Secure delete

# 2. Backup docker-compose.yml (config)
git add docker-compose.yml  # Safe to commit (no secrets)
git commit -m "security: hardened compose config"

# 3. Backup volume data (credentials stored here)
docker compose down
docker run --rm -v standby_vaultwarden_data:/data \
  -v $(pwd)/backups:/backup alpine \
  tar czf /backup/vaultwarden_data.tar.gz /data
docker compose up -d

# 4. Backup .env to encrypted external storage
# (USB drive, cloud storage with client-side encryption, etc.)
```

---

## 8. Rotation Schedule

### Every 90 days

```bash
# 1. Generate new passwords
NEW_GRAFANA_PASS=$(openssl rand -base64 32)

# 2. Update in Grafana UI (Settings > Users > Admin)
# OR via API:
curl -X PATCH http://admin:${GRAFANA_ADMIN_PASSWORD}@localhost:3000/api/admin/users/1/password \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"$NEW_GRAFANA_PASS\"}"

# 3. Update .env
sed -i "s/GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$NEW_GRAFANA_PASS/" .env

# 4. Restart Grafana
docker compose restart grafana
```

### On suspected compromise

1. Rotate ALL secrets immediately
1. Review audit logs (Traefik, Grafana)
1. Change Vaultwarden master account password
1. Notify all users to change local passwords
1. Full container/volume wipe if severe

---

## 9. Checklist Before Production

- [ ] .env created from .env.example with strong passwords
- [ ] .env confirmed git-ignored
- [ ] Compose fail-closed guards verified (stack will not start with .env values unset)
- [ ] TRAEFIK_AUTH_HASH set in .env (traefik.yml reads the hash from the environment; the file itself holds no hash)
- [ ] All default passwords removed from files
- [ ] alertmanager.yml configured (if using email)
- [ ] Vaultwarden master account set with 2FA
- [ ] Grafana admin password set in .env (no default)
- [ ] Traefik dashboard tested with credentials
- [ ] .env backed up to encrypted external storage
- [ ] No secrets in git history (check: git log -p \| grep password)
- [ ] Incident response plan documented
- [ ] Backup/restore tested (dry run)

---

## 💾 10. Disaster Recovery

**If secrets are leaked:**

```bash
# 1. Immediate containment
docker compose down

# 2. Assume all data is compromised
docker volume rm standby_grafana_data standby_vaultwarden_data

# 3. Generate new secrets
(regenerate all passwords)

# 4. Update .env
(new credentials)

# 5. Rebuild clean
docker compose up -d

# 6. Reconfigure (Vaultwarden master, Grafana users, etc.)

# 7. Audit trail
# - Check Traefik access logs for unauthorized IPs
# - Review Grafana login history
# - Inspect Alertmanager webhook calls
# - Check for unusual Prometheus scrapes
```

---

## Quick Commands

```bash
# View current environment
docker compose config | grep -A 5 environment

# Read the running Grafana password variable
docker compose exec grafana env | grep GF_SECURITY

# Test .env loading (compose reads .env automatically)
docker compose config | head -20

# Validate no secrets in docker-compose.yml
grep -i password docker-compose.yml | grep -v '\${' && echo "FOUND PLAINTEXT!" || echo "OK"

# Check git history for secrets
git log --all --full-history -p -- .env  # Should be empty (.env is git-ignored)
git log -p | grep -i "password\|secret\|token" | head -20  # Find any leaked secrets
```

---

## 🔗 References

- [OWASP: Secrets Management](https://owasp.org/www-community/Sensitive_Data_Exposure)
- [Docker: Manage Sensitive Data](https://docs.docker.com/compose/use-secrets/)
- [CWE-798: Use of Hard-Coded Credentials](https://cwe.mitre.org/data/definitions/798.html)

---

**REMEMBER:** Secrets are the keys to the kingdom. Treat them with the same care as your home security system. One leaked password = full system compromise.
