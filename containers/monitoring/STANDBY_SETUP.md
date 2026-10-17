# Standby Monitoring Stack - Setup & Verification

## Port Allocation (isolated from LLM stack)

| Service | Port | Purpose |
|---------|------|---------|
| Prometheus | 9090 | Metrics API |
| Grafana | 3000 | Dashboards |
| Alertmanager | 9093 | Alert routing |
| Traefik | 8080 | Dashboard/API |
| Traefik (HTTP) | 80 | Ingress |
| Traefik (HTTPS) | 443 | Ingress |
| Ntfy | 8081 | Notifications |
| step-ca | 9000 | Certificate Authority |
| Headscale | 8082 | VPN control plane |
| Headscale Metrics | 9091 | Prometheus metrics |
| Headscale UDP | 3478 | DERP relay |
| Vaultwarden | 8000 | Password manager |
| Uptime Kuma | 3001 | Status monitoring |

**LLM stack ports (unchanged):**

- ollama: 11434
- open-webui: 8501

**Verification:** No conflicts if your LLM stack uses 11434 & 8501 only.

---

## 📋 Pre-Deployment Checklist

**⚠️ SECURITY CRITICAL:**

- Grafana has no default password: GRAFANA_ADMIN_PASSWORD must be set in .env before first start (compose refuses to start Grafana without it)
- Headscale requires initialization and policy.hujson creation (see step-ca initialization section)
- step-ca will auto-generate PKI on first run; credentials will be in logs

1. **Docker & Docker Compose installed:**

   ```bash
   docker --version
   docker compose version
   ```

1. **Work in the stack folder (containers/monitoring/ in your repo clone); the shipped configs plus your host-local ntfy.conf and headscale.conf are present:**

   ```bash
   ls -la docker-compose.yml prometheus.yml alertmanager.yml ntfy.conf headscale.conf
   ```

1. **Network isolation confirmed:**

   ```bash
   docker network ls | grep llm
   ```

   (Your LLM stack should be on a separate network)

---

## 🚀 Deployment

```bash
# Start all services
docker compose up -d

# Verify all containers are running
docker compose ps

# Expected output: 9 containers in "Up" state
```

---

## ✅ Health Checks

```bash
# Check individual service health
docker compose exec prometheus wget --quiet --tries=1 --spider http://standby-prometheus:9090/-/healthy && echo "✓ Prometheus healthy"
docker compose exec grafana wget --quiet --tries=1 --spider http://standby-grafana:3000/api/health && echo "✓ Grafana healthy"
docker compose exec alertmanager wget --quiet --tries=1 --spider http://standby-alertmanager:9093/-/healthy && echo "✓ Alertmanager healthy"
docker compose exec traefik traefik healthcheck --ping && echo "✓ Traefik healthy"
docker compose exec headscale curl -f http://standby-headscale:8080/health && echo "✓ Headscale healthy"
docker compose exec uptime-kuma curl -f http://standby-uptime-kuma:3001/ && echo "✓ Uptime Kuma healthy"
docker compose exec -it step-ca curl -f -k https://standby-step-ca:9000/health && echo "✓ step-ca healthy"

# View logs for troubleshooting
docker compose logs -f prometheus
docker compose logs -f grafana
docker compose logs -f traefik
docker compose logs -f step-ca
docker compose logs -f headscale
```

---

## Access Points

| Service | URL | Default Credentials |
|---------|-----|-------------------|
| Prometheus | http://localhost:9090 | N/A |
| Grafana | http://localhost:3000 | admin / password set in .env (GRAFANA_ADMIN_PASSWORD) |
| Alertmanager | http://localhost:9093 | N/A |
| Traefik Dashboard | http://localhost:8080 | N/A |
| Ntfy | http://localhost:8081 | N/A |
| step-ca | http://localhost:9000 | Generated on first run |
| Headscale | http://localhost:8082 | Configure after startup |
| Vaultwarden | http://localhost:8000 | Set on first access |
| Uptime Kuma | http://localhost:3001 | Set on first access |

---

## 🚀 Critical Post-Deployment Steps

1. **Grafana admin password:**
   The admin password is the GRAFANA_ADMIN_PASSWORD value in .env, set
   before first start; there is no default to change. To rotate it,
   update .env and recreate the container:

   ```bash
   docker compose up -d grafana
   ```

1. **Verify the Grafana datasource:**
   - The Prometheus datasource is provisioned automatically from
     grafana/provisioning (URL: `http://standby-prometheus:9090`),
     along with the Homelab Nodes dashboard from grafana/dashboards.
   - Log in to Grafana (<http://localhost:3000>), open Configuration >
     Data Sources, and confirm the Prometheus datasource tests OK. It
     is provisioned read-only, so it cannot be edited in the UI.

1. **Vaultwarden first-time setup:**
   - Navigate to <http://localhost:8000>
   - Create master account
   - Enable 2FA

1. **Uptime Kuma monitors:**
   - Log in to <http://localhost:3001>
   - Add monitors for critical services (Prometheus, Grafana, etc.)
   - Configure notification integrations (Ntfy)

1. **step-ca initialization:**
   - Container will generate PKI on first run
   - Extract credentials from logs:

   ```bash
   docker compose logs step-ca | grep -i "admin\|token"
   ```

1. **Headscale initialization:**
   - Create policy.hujson for ACLs:

   ```bash
   cat > policy.hujson << 'EOF'
   {
     "Groups": {
       "group:admin": ["*"],
       "group:users": ["*"]
     },
     "Hosts": {},
     "TagOwners": {
       "tag:admin": ["group:admin"]
     },
     "ACLs": [
       {
         "Action": "accept",
         "Sources": ["*"],
         "Destinations": ["*:*"]
       }
     ],
     "SSH": []
   }
   EOF
   docker cp policy.hujson standby-headscale:/etc/headscale/policy.hujson
   docker compose restart headscale
   ```

   - Create first headscale user:

   ```bash
   docker compose exec headscale headscale users create admin
   ```

---

## Coexistence with LLM Stack

**Verify isolation:**

```bash
# List all networks
docker network ls

# Inspect standby network (should not include LLM containers)
docker network inspect $(docker network ls | grep standby-net | awk '{print $1}')

# Verify no port conflicts
sudo netstat -tlnp | grep -E ':(80|443|9090|3000|8080|8081|8000|3001)'
```

---

## 💾 Backup Strategy (cold standby)

Volumes persist data if container is removed:

```bash
# List volumes
docker volume ls | grep standby

# Backup a volume
docker run --rm -v standby_prometheus_data:/data -v $(pwd):/backup alpine tar czf /backup/prometheus_data.tar.gz /data

# Restore a volume
docker run --rm -v standby_prometheus_data:/data -v $(pwd):/backup alpine tar xzf /backup/prometheus_data.tar.gz -C /
```

---

## Stopping / Removing

```bash
# Stop all services (preserves volumes)
docker compose down

# Remove everything including volumes (careful!)
docker compose down -v
```

---

## Success Criteria

✓ All 9 containers running
✓ No port conflicts with LLM stack
✓ Prometheus scraping metrics
✓ Grafana connecting to Prometheus
✓ Traefik dashboard accessible
✓ Logs show no errors/warnings for 2 minutes
