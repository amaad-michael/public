# LLM playbooks

Four Ansible deployments live in this folder. Two of them, the GPU box and the OptiPlex, have their own full guides and are only linked here. The other two, the NanoPi inference server and its load balancer, are documented in this README.

| Playbook | Target | Guide |
|---|---|---|
| `gpu-box-llm-setup-v1.9.yml` | Nobara GPU box, Ollama and Open WebUI | [gpu-box-llm-setup-v2.1.md](gpu-box-llm-setup-v2.1.md) |
| `optiplex-llm-setup-v2.1.yml` | Dell OptiPlex, llama.cpp | [optiplex-llm-v2.3.md](optiplex-llm-v2.3.md) |
| `llm-server-setup.yml` | NanoPi boards, llama.cpp inference | This README |
| `llm-lb-setup.yml` | NanoPi board, nginx load balancer | This README |

## llm-server-setup.yml

Configures a bare Debian or Ubuntu ARM64 NanoPi board as a llama.cpp inference server.

- Targets the inventory groups `llm_2gb` and `llm_4gb`. Those groups are not in the shipped `ansible/hosts` file; define them in your own inventory, as the playbook header shows (`-i inventory.ini`).
- Sets the hostname from the inventory name, runs a dist-upgrade, and installs the build toolchain plus `prometheus-node-exporter`. Bluetooth and Avahi are stopped and disabled where present.
- Clones llama.cpp into `~/llama.cpp` in the connection user's home and builds it natively (`LLAMA_NATIVE=ON`). The build is guarded by the resulting binary, so re-runs skip it.
- Downloads one GGUF model per group into `~/models`: the 4 GB group gets Qwen2.5-Coder-7B-Instruct Q4_K_M; the 2 GB group gets Qwen2.5-Coder-1.5B-Instruct Q4_K_M.
- Deploys the `llama-server` systemd unit from `llama-server.service.j2` and enables it. Defaults: port 8080, context size 2048, n-predict 512, threads equal to the board's CPU count.
- Firewall: UFW allows OpenSSH, allows port 8080 from the local /24 network only, and defaults to deny.

## llm-lb-setup.yml

Configures one small NanoPi board (0.5 GB class) as an nginx reverse proxy in front of the inference nodes.

- Targets the inventory group `llm_lb` (a single host), also defined in your own inventory.
- Installs nginx, curl, and `prometheus-node-exporter`; removes the default nginx site.
- Deploys `llm-lb.conf.j2` to `/etc/nginx/sites-available/llm-lb.conf`, links it into `sites-enabled`, validates with `nginx -t`, and enables nginx.
- The upstream pool uses `least_conn` so the lighter board is not handed heavy requests while it is busy. Proxy read and send timeouts are 300 seconds and response buffering is off, so tokens stream as they generate.
- `GET /lb-health` returns `llm-lb ok` from nginx itself without touching a backend.
- Backends come from the `llm_nodes` variable. The defaults are two example nodes (192.168.1.101 as `4gb-heavy`, 192.168.1.102 as `2gb-light`, both on port 8080); override `llm_nodes` in inventory group_vars for a real deployment.
- Firewall: UFW allows OpenSSH, allows the load balancer port (80) from the local /24 network only, and defaults to deny.

## Run order and templates

Run the server playbook on the inference nodes first, then the load balancer playbook:

```bash
ansible-playbook llm-server-setup.yml -i inventory.ini -K
ansible-playbook llm-lb-setup.yml -i inventory.ini -K
```

The two templates ship in this folder and are referenced by name from the playbooks: `llama-server.service.j2` (the systemd unit) and `llm-lb.conf.j2` (the nginx site).

The containerised form of this same topology (two llama.cpp backends behind an nginx load balancer) is `containers/llm/`.
