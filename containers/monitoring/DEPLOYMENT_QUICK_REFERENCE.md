# Deployment Quick Reference

## 🚀 Pre-Deployment

```bash
# 1. Verify all files present
ls -lah docker-compose.yml prometheus.yml alertmanager.yml ntfy.conf headscale.conf \
  policy.hujson alert_rules.yml traefik.yml .env

# 2. Create .env from .env.example with secrets (DO NOT COMMIT .env)
cp .env.example .env
sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 32)|" .env
echo "TRAEFIK_AUTH_HASH=admin:$(htpasswd -bcB -C 10 /dev/null admin $(openssl rand -base64 32) | cut -d: -f2)" >> .env
chmod 600 .env

# 3. Validate compose syntax
docker compose config > /dev/null && echo "✓ Syntax OK"

# 4. Check port conflicts
sudo netstat -tlnp | grep -E ":80|:443|:9090|:3000|:8080|:8081|:9000|:8082|:8000|:3001"
```

## 🚀 Deployment

```bash
# Start stack
docker compose up -d

# Verify all 9 containers running
docker compose ps

# Expected: 9/9 containers "Up"
```

## 🚀 Post-Deployment (First Run)

```bash
# 1. Wait for services to initialize (30-60 seconds)
sleep 60

# 2. Check health
docker compose ps | grep -E "healthy|unhealthy"

# 3. Set Vaultwarden master password
# Navigate to http://localhost:8000
# Create master account + enable 2FA

# 4. Grafana admin password
# Set before first start: it is the GRAFANA_ADMIN_PASSWORD value in .env
# (there is no default). To rotate: update .env, then run:
# docker compose up -d grafana

# 5. Verify the Grafana datasource
# The Prometheus datasource and the Homelab Nodes dashboard are
# provisioned automatically from grafana/provisioning and
# grafana/dashboards; the datasource is read-only in the UI.
# Navigate to http://localhost:3000 and confirm it tests OK.

# 6. Test Traefik dashboard (password whose hash is TRAEFIK_AUTH_HASH in .env)
curl -u admin:<password> http://localhost:8080/api/version
```

## ✅ Health Check (All Services)

```bash
docker compose exec prometheus wget --quiet --tries=1 --spider http://localhost:9090/-/healthy && echo "✓ Prometheus"
docker compose exec grafana wget --quiet --tries=1 --spider http://localhost:3000/api/health && echo "✓ Grafana"
docker compose exec alertmanager wget --quiet --tries=1 --spider http://localhost:9093/-/healthy && echo "✓ Alertmanager"
docker compose exec traefik traefik healthcheck --ping && echo "✓ Traefik"
docker compose exec ntfy wget --quiet --tries=1 --spider http://localhost:80/v1/health && echo "✓ Ntfy"
docker compose exec step-ca curl -f -k https://localhost:9000/health 2>/dev/null && echo "✓ step-ca"
docker compose exec headscale curl -f http://localhost:8080/health && echo "✓ Headscale"
docker compose exec vaultwarden curl -f http://localhost:80/alive && echo "✓ Vaultwarden"
docker compose exec uptime-kuma curl -f http://localhost:3001/ 2>/dev/null && echo "✓ Uptime Kuma"
```

## Access Points

| Service | URL | Credentials |
|---------|-----|-------------|
| Prometheus | http://localhost:9090 | None |
| Grafana | http://localhost:3000 | admin / (from .env: GRAFANA_ADMIN_PASSWORD) |
| Alertmanager | http://localhost:9093 | None |
| Traefik Dashboard | http://localhost:8080 | admin / (from .env) |
| Ntfy | http://localhost:8081 | None (deny-all auth) |
| step-ca | http://localhost:9000 | (self-signed) |
| Headscale | http://localhost:8082 | Configure after init |
| Vaultwarden | http://localhost:8000 | Create master account |
| Uptime Kuma | http://localhost:3001 | Configure after init |

## ✅ Verify Isolation from LLM Stack

```bash
# Check networks
docker network ls | grep -E "llm|standby"

# Verify no cross-network containers
docker network inspect $(docker network ls | grep standby | awk '{print $1}') | grep Containers

# Confirm port isolation
sudo netstat -tlnp | grep -E "11434|8501" # LLM ports (should NOT be in standby network)
sudo netstat -tlnp | grep -E "9090|3000|8080" # Standby ports
```

## 📊 Monitoring

```bash
# Watch logs in real-time
docker compose logs -f

# Specific service
docker compose logs -f prometheus

# Last 100 lines
docker compose logs --tail 100 traefik

# Structured logs (JSON)
docker compose logs --no-log-prefix prometheus | jq '.' 2>/dev/null || echo "Not JSON"
```

## Maintenance

### Backup

```bash
# Backup all volumes
docker compose down
for vol in $(docker volume ls | grep standby | awk '{print $2}'); do
  docker run --rm -v $vol:/data -v $(pwd)/backups:/backup \
    alpine tar czf /backup/${vol}.tar.gz /data
done
docker compose up -d
```

### Restore

```bash
docker compose down
for vol in $(docker volume ls | grep standby | awk '{print $2}'); do
  docker run --rm -v $vol:/data -v $(pwd)/backups:/backup \
    alpine tar xzf /backup/${vol}.tar.gz -C /
done
docker compose up -d
```

### Restart Service

```bash
docker compose restart prometheus
```

### Rebuild Service

```bash
docker compose down prometheus
docker volume rm standby_prometheus_data
docker compose up -d prometheus
```

### View Resource Usage

```bash
docker stats --no-stream

# Specific service
docker stats --no-stream standby-prometheus
```

## 🔍 Troubleshooting

### Service not starting

```bash
docker compose logs prometheus | tail -50
```

### Permission denied (volumes)

```bash
# Fix volume permissions
sudo chown -R 65534:65534 /var/lib/docker/volumes/standby_prometheus_data/_data
```

### Port already in use

```bash
# Find what's using port 9090
sudo lsof -i :9090
# Kill it or change compose port mapping
```

### Network timeout (inter-service)

```bash
# Test DNS resolution
docker compose exec prometheus nslookup standby-grafana

# Test connectivity
docker compose exec prometheus ping -c 3 standby-grafana
```

### High CPU/Memory

```bash
# Check limits
docker inspect standby-prometheus | grep -A 10 Resources

# Adjust in docker-compose.yml and restart
docker compose restart prometheus
```

## 🔒 Security Verification

```bash
# Verify no containers running as root
for container in $(docker compose ps -q); do
  docker exec $container id | grep -q "uid=0" && echo "WARNING: Running as root: $container"
done

# Verify read-only filesystems
docker inspect standby-prometheus | grep ReadonlyRootfs

# Verify capabilities dropped
docker inspect standby-prometheus | grep CapDrop

# Verify resource limits applied
docker inspect standby-prometheus | grep -A 5 '"Memory"'

# Verify no default passwords in configs
grep -r "changeme\|admin/admin" . --exclude-dir=.git --exclude=.env
```

## Emergency Procedures

### Full Wipe & Rebuild

```bash
docker compose down -v
rm -rf volumes/*
docker compose up -d
# Reconfigure all services from scratch
```

### Emergency Stop

```bash
docker compose down
```

### Emergency Start

```bash
docker compose up -d
```

### Check System Health

```bash
docker system df  # Disk usage
docker system events --since 10m  # Recent events
```

## Success Criteria

✓ All 9 containers "Up" and "healthy"
✓ No port conflicts with LLM stack
✓ All health checks passing
✓ Prometheus scraping metrics
✓ Grafana datasource connected
✓ Traefik dashboard accessible with auth
✓ Ntfy deny-all auth enforced
✓ Vaultwarden master account configured
✓ No errors in logs (30-second window)
✓ Resource limits applied
✓ Capabilities dropped
✓ Read-only filesystems enforced
✓ No default passwords in running config

---

## 📦 Key Files

| File | Purpose | Location |
|------|---------|----------|
| docker-compose.yml | Service definitions | ./ |
| .env | Secrets (NOT tracked) | ./ |
| prometheus.yml | Prometheus config | ./ |
| alertmanager.yml | Alertmanager config | ./ |
| ntfy.conf | Ntfy config (host-local, git-ignored) | ./ |
| headscale.conf | Headscale config (host-local, git-ignored) | ./ |
| traefik.yml | Traefik security config | ./ |
| policy.hujson | Headscale ACLs (host-local, git-ignored) | ./ |
| alert_rules.yml | Prometheus alert rules | ./ |
| SECURITY_HARDENING-v1.0.md | Defense-in-depth details | ./ |
| SECRETS_MANAGEMENT.md | Secret rotation guide | ./ |

---

## Support

For detailed security info, see: SECURITY_HARDENING-v1.0.md
For secret management, see: SECRETS_MANAGEMENT.md
For initial setup, see: STANDBY_SETUP.md
