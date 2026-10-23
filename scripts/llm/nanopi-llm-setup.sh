#!/usr/bin/env bash
# nanopi-llm-setup.sh — bash form of the NanoPi inference pool.
#
# Ansible form (the source this script is derived from, step for step):
#   ansible/playbooks/llm/llm-server-setup.yml  (inference nodes)
#   ansible/playbooks/llm/llm-lb-setup.yml      (nginx load balancer)
#   ansible/playbooks/llm/llama-server.service.j2
#   ansible/playbooks/llm/llm-lb.conf.j2
# Docker form: containers/llm/
#
# Inventory-group mapping (Ansible -> this script):
#   hosts in group llm_4gb  -> --role server --tier 4gb
#       Qwen2.5-Coder-7B-Instruct Q4_K_M model
#   hosts in group llm_2gb  -> --role server --tier 2gb
#       Qwen2.5-Coder-1.5B-Instruct Q4_K_M model
#   the host in group llm_lb -> --role lb
#       --nodes "<ip> [<ip> ...]" replaces the playbook's llm_nodes
#       variable; the defaults match llm-lb-setup.yml exactly:
#       192.168.1.101 (label 4gb-heavy) and 192.168.1.102 (2gb-light),
#       each on the server port.
#   ansible_user (connection user) -> --user (default: $SUDO_USER,
#       falling back to $USER, then root)
#   inventory_hostname             -> --hostname (optional)
#
# The playbooks target Debian/Ubuntu ARM64 NanoPi boards. This script
# checks the OS family the same way and warns (does not stop) on other
# CPU architectures, because llama.cpp is built natively either way.
#
# Run as root on the target board. Re-runs are idempotent like the
# playbooks: the build is skipped while the llama-server binary
# exists, the model is downloaded only when missing, and service
# restarts happen only when the rendered unit/config changes.
#
# Usage:
#   nanopi-llm-setup.sh --role server --tier 4gb [--user USER]
#   nanopi-llm-setup.sh --role lb [--nodes "192.168.1.101 192.168.1.102"]
#   nanopi-llm-setup.sh --role server --tier 2gb --dry-run
#   nanopi-llm-setup.sh --role lb --print-config
#
# A config file (--config FILE, or $NANOPI_LLM_CONFIG) may set any of
# ROLE, TIER, LLM_USER, SET_HOSTNAME, SERVER_PORT, LB_PORT, CTX_SIZE,
# N_PREDICT, THREADS, MODEL_FILENAME, MODEL_URL, MODEL_SHA256, LAN_CIDR and NODES
# (space-separated). Command-line flags override the file.

set -euo pipefail

ROLE=""
TIER=""
LLM_USER="${SUDO_USER:-${USER:-root}}"
SET_HOSTNAME=""
SERVER_PORT=8080
LB_PORT=80
CTX_SIZE=2048
N_PREDICT=512
THREADS=""
MODEL_FILENAME=""
MODEL_URL=""
MODEL_SHA256=""
LAN_CIDR=""
NODES="192.168.1.101 192.168.1.102"
NODE_LABELS="4gb-heavy 2gb-light"
DRY_RUN=0
PRINT_CONFIG=0
SKIP_UPGRADE=0
SKIP_FIREWALL=0
SKIP_MODEL=0
CONFIG_FILE="${NANOPI_LLM_CONFIG:-}"

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: nanopi-llm-setup.sh --role server|lb [options]

Server (llama.cpp inference node; Ansible llm-server-setup.yml):
  --tier 2gb|4gb        Model tier (required for --role server)
                        2gb = Qwen2.5-Coder-1.5B Q4_K_M
                        4gb = Qwen2.5-Coder-7B Q4_K_M
  --user USER           Owner of ~/llama.cpp and ~/models, and the
                        user the systemd unit runs as
                        (default: $SUDO_USER, else $USER, else root)
  --ctx-size N          Context size (default 2048)
  --n-predict N         Prediction limit (default 512)
  --threads N           Threads (default: nproc)
  --model-file NAME     Override the model filename
  --model-url URL       Override the model download URL
  --model-sha256 HEX    SHA-256 a custom model must match (the built-in
                        tier models are pinned and always verified)
  --skip-model          Do not download the model

Load balancer (nginx; Ansible llm-lb-setup.yml):
  --nodes "IP [IP ...]" Backend inference nodes
                        (default "192.168.1.101 192.168.1.102")
  --node-labels "L ..." Labels for --nodes, in order
                        (default "4gb-heavy 2gb-light")
  --lb-port N           Listen port (default 80)

Common:
  --hostname NAME       Set the host's hostname (playbooks use the
                        inventory hostname)
  --server-port N       llama-server port (default 8080)
  --lan-cidr CIDR       LAN allowed through UFW
                        (default: this host's /24 network)
  --config FILE         Bash config file read before flags
  --skip-upgrade        Skip the apt dist-upgrade step
  --skip-firewall       Skip all UFW changes
  --dry-run             Print every changing command, change nothing
  --print-config        Print the rendered systemd unit (server) or
                        nginx site (lb) to stdout and exit
  -h, --help            This text
EOF
}

# First pass: find --config so the file is read before the real parse.
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--config" ]]; then
    CONFIG_FILE="$arg"
  fi
  prev="$arg"
done
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
  # The config file is operator-supplied bash, same trust as this script.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:?--role needs a value}"; shift 2 ;;
    --tier) TIER="${2:?--tier needs a value}"; shift 2 ;;
    --user) LLM_USER="${2:?--user needs a value}"; shift 2 ;;
    --hostname) SET_HOSTNAME="${2:?--hostname needs a value}"; shift 2 ;;
    --server-port) SERVER_PORT="${2:?--server-port needs a value}"; shift 2 ;;
    --lb-port) LB_PORT="${2:?--lb-port needs a value}"; shift 2 ;;
    --ctx-size) CTX_SIZE="${2:?--ctx-size needs a value}"; shift 2 ;;
    --n-predict) N_PREDICT="${2:?--n-predict needs a value}"; shift 2 ;;
    --threads) THREADS="${2:?--threads needs a value}"; shift 2 ;;
    --model-file) MODEL_FILENAME="${2:?--model-file needs a value}"; shift 2 ;;
    --model-url) MODEL_URL="${2:?--model-url needs a value}"; shift 2 ;;
    --model-sha256) MODEL_SHA256="${2:?--model-sha256 needs a value}"; shift 2 ;;
    --nodes) NODES="${2:?--nodes needs a value}"; shift 2 ;;
    --node-labels) NODE_LABELS="${2:?--node-labels needs a value}"; shift 2 ;;
    --lan-cidr) LAN_CIDR="${2:?--lan-cidr needs a value}"; shift 2 ;;
    --config) shift 2 ;;
    --skip-upgrade) SKIP_UPGRADE=1; shift ;;
    --skip-model) SKIP_MODEL=1; shift ;;
    --skip-firewall) SKIP_FIREWALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --print-config) PRINT_CONFIG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

is_positive_int() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]; }
is_port() { is_positive_int "$1" && [[ "$1" -le 65535 ]]; }

validate() {
  [[ "$ROLE" == "server" || "$ROLE" == "lb" ]] \
    || die "--role must be 'server' or 'lb'"
  is_port "$SERVER_PORT" || die "--server-port must be 1-65535: $SERVER_PORT"
  is_port "$LB_PORT" || die "--lb-port must be 1-65535: $LB_PORT"
  is_positive_int "$CTX_SIZE" || die "--ctx-size must be a positive integer: $CTX_SIZE"
  is_positive_int "$N_PREDICT" || die "--n-predict must be a positive integer: $N_PREDICT"
  if [[ -n "$THREADS" ]] && ! is_positive_int "$THREADS"; then
    die "--threads must be a positive integer: $THREADS"
  fi
  if [[ -n "$LAN_CIDR" && "$LAN_CIDR" != */* ]]; then
    die "--lan-cidr must be a CIDR (address/prefix): $LAN_CIDR"
  fi
  if [[ "$ROLE" == "server" ]]; then
    [[ "$TIER" == "2gb" || "$TIER" == "4gb" ]] \
      || die "--role server needs --tier 2gb or --tier 4gb"
    if [[ -z "$MODEL_FILENAME" && -z "$MODEL_URL" ]]; then
      # The default models are pinned twice: the URL names the repo
      # commit (not the moving main branch) and MODEL_SHA256 is the
      # file's SHA-256 as published by Hugging Face (its LFS hash,
      # read from the HF API on 2026-10-23).
      if [[ "$TIER" == "4gb" ]]; then
        MODEL_FILENAME="qwen2.5-coder-7b-instruct-q4_k_m.gguf"
        MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/13fb94bfda8c8cf22497dc57b78f391a9acb426a/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
        MODEL_SHA256="509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c"
      else
        MODEL_FILENAME="qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"
        MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/f86cb2c1fa58255f8052cc32aeede1b7482d4361/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"
        MODEL_SHA256="cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046"
      fi
    elif [[ -z "$MODEL_FILENAME" || -z "$MODEL_URL" ]]; then
      die "--model-file and --model-url must be overridden together"
    fi
  fi
  if [[ "$ROLE" == "lb" ]]; then
    [[ -n "${NODES// /}" ]] || die "--role lb needs at least one --nodes address"
    local node
    for node in $NODES; do
      [[ "$node" =~ ^[0-9A-Za-z._:-]+$ ]] \
        || die "invalid node address: $node"
    done
  fi
  if [[ -z "$THREADS" ]]; then
    THREADS="$(nproc 2>/dev/null || echo 4)"
  fi
  if [[ "$PRINT_CONFIG" -eq 0 ]]; then
    id "$LLM_USER" >/dev/null 2>&1 || die "user does not exist: $LLM_USER"
  fi
}

llm_home() {
  if [[ "$LLM_USER" == "root" ]]; then
    printf '%s\n' "/root"
  else
    printf '%s\n' "/home/$LLM_USER"
  fi
}

detect_lan_cidr() {
  if [[ -n "$LAN_CIDR" ]]; then
    return 0
  fi
  local first base
  first="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | head -n 1 || true)"
  if [[ "$first" == */* ]]; then
    base="${first%.*}"
    LAN_CIDR="${base}.0/24"
  elif [[ "$DRY_RUN" -eq 1 || "$PRINT_CONFIG" -eq 1 ]]; then
    LAN_CIDR="192.168.0.0/24"
    warn "no global IPv4 address found; dry-run continues with $LAN_CIDR"
  else
    die "could not detect the LAN /24; pass --lan-cidr explicitly"
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

run_as_user() {
  local user="$1"
  shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: runuser -u %s -- %s\n' "$user" "$*"
  elif [[ "$(id -un)" == "$user" ]]; then
    "$@"
  else
    runuser -u "$user" -- "$@"
  fi
}

# install_if_changed SRC DEST MODE — installs SRC at DEST only when the
# content differs; sets CHANGED_FILE=1 when it did. Mirrors the Ansible
# template tasks, whose change status drives the service handlers.
CHANGED_FILE=0
install_if_changed() {
  local src="$1" dest="$2" mode="$3"
  CHANGED_FILE=0
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    log "unchanged: $dest"
    return 0
  fi
  CHANGED_FILE=1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: install -m %s %s %s\n' "$mode" "$src" "$dest"
  else
    install -m "$mode" "$src" "$dest"
    log "installed: $dest"
  fi
}

apt_update_upgrade() {
  export DEBIAN_FRONTEND=noninteractive
  run_cmd apt-get update
  if [[ "$SKIP_UPGRADE" -eq 0 ]]; then
    run_cmd apt-get -y dist-upgrade
  fi
}

disable_unneeded_services() {
  local svc
  for svc in bluetooth avahi-daemon; do
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'DRY-RUN: systemctl disable --now %s (if present)\n' "$svc"
    elif systemctl list-unit-files "$svc.service" >/dev/null 2>&1 \
      && systemctl list-unit-files "$svc.service" | grep -q "$svc"; then
      systemctl disable --now "$svc" || true
    fi
  done
}

setup_firewall() {
  local port="$1"
  if [[ "$SKIP_FIREWALL" -eq 1 ]]; then
    log "skipping firewall (--skip-firewall)"
    return 0
  fi
  run_cmd apt-get install -y ufw
  run_cmd ufw allow OpenSSH
  run_cmd ufw allow from "$LAN_CIDR" to any port "$port" proto tcp
  run_cmd ufw default deny incoming
  run_cmd ufw --force enable
}

render_server_unit() {
  local home="$1"
  cat <<EOF
[Unit]
Description=llama.cpp inference server
After=network.target

[Service]
Type=simple
User=$LLM_USER
WorkingDirectory=$home
ExecStart=$home/llama.cpp/build/bin/llama-server \\
  --model $home/models/$MODEL_FILENAME \\
  --host 0.0.0.0 \\
  --port $SERVER_PORT \\
  --threads $THREADS \\
  --ctx-size $CTX_SIZE \\
  --n-predict $N_PREDICT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

render_lb_config() {
  local node label
  local -a node_list label_list
  read -r -a node_list <<< "$NODES"
  read -r -a label_list <<< "$NODE_LABELS"
  cat <<'EOF'
# llm-lb.conf
# nginx reverse proxy / load balancer for llama.cpp inference nodes.
# Uses least_conn to avoid sending heavy requests to the lighter board.

upstream llm_pool {
    least_conn;

EOF
  local i
  for i in "${!node_list[@]}"; do
    label="${label_list[$i]:-node$((i + 1))}"
    printf '    server %s:%s;  # %s\n' "${node_list[$i]}" "$SERVER_PORT" "$label"
  done
  cat <<EOF
}

server {
    listen $LB_PORT;
    server_name _;

    # Health check endpoint — returns LB status without hitting a backend
    location /lb-health {
        access_log off;
        return 200 'llm-lb ok\n';
        add_header Content-Type text/plain;
    }

    # Proxy all inference traffic to the pool
    location / {
        proxy_pass http://llm_pool;

        # Inference takes time — do not let nginx time out mid-generation
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
        proxy_send_timeout 300s;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # Disable buffering — stream tokens as they generate
        proxy_buffering off;
        proxy_cache off;
    }
}
EOF
}

# download_model — fetch the GGUF to a .part file, verify its SHA-256
# when a pin is set, and only then move it into place. A mismatch
# deletes the download and aborts: a model that fails verification is
# never served. Reads do_server's locals (model_dir, MODEL_*) through
# bash's dynamic scoping; called only from do_server.
download_model() {
  local part="$model_dir/$MODEL_FILENAME.part"
  run_as_user "$LLM_USER" curl -fL --output "$part" "$MODEL_URL"
  if [[ -n "$MODEL_SHA256" ]]; then
    local actual_sha
    actual_sha="$(run_as_user "$LLM_USER" sha256sum "$part" | awk '{print $1}')"
    if [[ "$actual_sha" != "$MODEL_SHA256" ]]; then
      run_as_user "$LLM_USER" rm -f "$part"
      die "model SHA-256 mismatch for $MODEL_FILENAME: got $actual_sha, expected $MODEL_SHA256 — download deleted"
    fi
    log "model SHA-256 verified: $MODEL_FILENAME"
  else
    warn "no SHA-256 pin for $MODEL_FILENAME (custom --model-url without --model-sha256) — the model cannot be verified"
  fi
  run_as_user "$LLM_USER" mv "$part" "$model_dir/$MODEL_FILENAME"
}

do_server() {
  local home llama_dir model_dir bin tmpunit actual_model_sha
  home="$(llm_home)"
  llama_dir="$home/llama.cpp"
  model_dir="$home/models"
  bin="$llama_dir/build/bin/llama-server"

  if [[ "$PRINT_CONFIG" -eq 1 ]]; then
    render_server_unit "$home"
    return 0
  fi

  if [[ -n "$SET_HOSTNAME" ]]; then
    run_cmd hostnamectl set-hostname "$SET_HOSTNAME"
  fi

  apt_update_upgrade
  run_cmd apt-get install -y git cmake build-essential python3-pip \
    curl wget tmux htop prometheus-node-exporter
  disable_unneeded_services

  # llama.cpp — clone and native build, as the playbook's git + shell tasks
  if [[ -d "$llama_dir/.git" ]]; then
    run_as_user "$LLM_USER" git -C "$llama_dir" pull --ff-only
  else
    run_as_user "$LLM_USER" git clone --depth 1 \
      https://github.com/ggerganov/llama.cpp "$llama_dir"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: build llama.cpp in %s unless %s exists\n' "$llama_dir" "$bin"
  elif [[ ! -x "$bin" ]]; then
    run_as_user "$LLM_USER" bash -c \
      "cd '$llama_dir' && cmake -B build -DLLAMA_NATIVE=ON && cmake --build build --config Release -j$THREADS"
  else
    log "llama-server binary exists, skipping build: $bin"
  fi

  # Model — one GGUF per tier, downloaded only when missing
  run_cmd install -d -o "$LLM_USER" -m 0755 "$model_dir"
  if [[ "$SKIP_MODEL" -eq 1 ]]; then
    log "skipping model download (--skip-model)"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: download %s to %s/%s (if missing), verify its SHA-256 against the pin, then move it into place\n' \
      "$MODEL_URL" "$model_dir" "$MODEL_FILENAME"
  elif [[ -f "$model_dir/$MODEL_FILENAME" ]]; then
    if [[ -n "$MODEL_SHA256" ]]; then
      actual_model_sha="$(run_as_user "$LLM_USER" sha256sum "$model_dir/$MODEL_FILENAME" | awk '{print $1}')"
      if [[ "$actual_model_sha" == "$MODEL_SHA256" ]]; then
        log "model already present and SHA-256 verified: $model_dir/$MODEL_FILENAME"
      else
        warn "the present model fails SHA-256 verification (got $actual_model_sha) — re-downloading"
        download_model
      fi
    else
      log "model already present: $model_dir/$MODEL_FILENAME"
    fi
  else
    download_model
  fi

  # systemd unit — the llama-server.service.j2 template, rendered
  tmpunit="$(mktemp)"
  render_server_unit "$home" > "$tmpunit"
  install_if_changed "$tmpunit" /etc/systemd/system/llama-server.service 0644
  rm -f "$tmpunit"
  local unit_changed="$CHANGED_FILE"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: systemctl daemon-reload; systemctl enable --now llama-server%s\n' \
      "$([[ "$unit_changed" -eq 1 ]] && printf ' (restart: unit changed)')"
  else
    systemctl daemon-reload
    systemctl enable llama-server
    if [[ "$unit_changed" -eq 1 ]]; then
      systemctl restart llama-server
    else
      systemctl start llama-server
    fi
  fi

  setup_firewall "$SERVER_PORT"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    # Health gate: a single is-active probe cannot prove the daemon
    # stayed up. The unit sets Restart=on-failure / RestartSec=5, so a
    # daemon that exits at once (e.g. its model will not load) cycles
    # through activating (auto-restart), and is transiently "active"
    # at each restart attempt — a lone probe taken right after the
    # start can land in that instant and report success for a service
    # that has already failed. Instead, sample the unit's state over
    # 12 seconds (longer than one restart cycle, at an interval that
    # does not alias the 5-second RestartSec): every sample must be
    # active/running with a success result, and the restart count
    # must not move during the window.
    local gate_line gate_snapshot
    local gate_state gate_substate gate_result gate_restarts
    local gate_attempt=0
    local gate_restarts_first=""
    while [[ "$gate_attempt" -lt 6 ]]; do
      gate_attempt=$((gate_attempt + 1))
      sleep 2
      gate_state="unknown"
      gate_substate="unknown"
      gate_result="unknown"
      gate_restarts="unknown"
      gate_snapshot="$(systemctl show llama-server \
        -p ActiveState -p SubState -p Result -p NRestarts \
        2>/dev/null || true)"
      while IFS= read -r gate_line; do
        case "$gate_line" in
          ActiveState=*) gate_state="${gate_line#ActiveState=}" ;;
          SubState=*) gate_substate="${gate_line#SubState=}" ;;
          Result=*) gate_result="${gate_line#Result=}" ;;
          NRestarts=*) gate_restarts="${gate_line#NRestarts=}" ;;
        esac
      done <<< "$gate_snapshot"
      if [[ -z "$gate_restarts_first" ]]; then
        gate_restarts_first="$gate_restarts"
      fi
      if [[ "$gate_state" != "active" \
        || "$gate_substate" != "running" \
        || "$gate_result" != "success" \
        || "$gate_restarts" != "$gate_restarts_first" ]]; then
        die "llama-server is not active after setup (state: $gate_state/$gate_substate, result: $gate_result, restarts: $gate_restarts; check: journalctl -u llama-server)"
      fi
    done
    log "llama-server active on port $SERVER_PORT (model: $MODEL_FILENAME)"
  fi
  log "NanoPi inference server setup complete (tier: $TIER)"
}

do_lb() {
  local tmpconf
  if [[ "$PRINT_CONFIG" -eq 1 ]]; then
    render_lb_config
    return 0
  fi

  if [[ -n "$SET_HOSTNAME" ]]; then
    run_cmd hostnamectl set-hostname "$SET_HOSTNAME"
  fi

  apt_update_upgrade
  run_cmd apt-get install -y nginx curl prometheus-node-exporter
  disable_unneeded_services

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: rm -f /etc/nginx/sites-enabled/default\n'
  else
    rm -f /etc/nginx/sites-enabled/default
  fi

  tmpconf="$(mktemp)"
  render_lb_config > "$tmpconf"
  run_cmd install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  install_if_changed "$tmpconf" /etc/nginx/sites-available/llm-lb.conf 0644
  rm -f "$tmpconf"
  local conf_changed="$CHANGED_FILE"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: ln -sf /etc/nginx/sites-available/llm-lb.conf /etc/nginx/sites-enabled/llm-lb.conf\n'
  else
    ln -sf /etc/nginx/sites-available/llm-lb.conf /etc/nginx/sites-enabled/llm-lb.conf
  fi

  run_cmd nginx -t
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: systemctl daemon-reload; systemctl enable --now nginx%s\n' \
      "$([[ "$conf_changed" -eq 1 ]] && printf ' (reload: config changed)')"
  else
    systemctl enable nginx
    if [[ "$conf_changed" -eq 1 ]]; then
      systemctl reload nginx || systemctl restart nginx
    else
      systemctl start nginx
    fi
  fi

  setup_firewall "$LB_PORT"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    systemctl is-active --quiet nginx \
      || die "nginx is not active after setup (check: journalctl -u nginx)"
    curl -fsS "http://127.0.0.1:$LB_PORT/lb-health" | grep -q "llm-lb ok" \
      || die "LB health endpoint did not answer 'llm-lb ok'"
    log "llm-lb healthy on port $LB_PORT"
  fi
  log "NanoPi load balancer setup complete (nodes: $NODES)"
}

main() {
  validate
  detect_lan_cidr
  if [[ "$PRINT_CONFIG" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    [[ $EUID -eq 0 ]] || die "run as root (or use --dry-run / --print-config)"
    command -v apt-get >/dev/null 2>&1 \
      || die "apt-get not found: the playbooks target Debian/Ubuntu boards only"
  fi
  case "$(uname -m)" in
    aarch64|arm64) ;;
    *) warn "the playbooks target ARM64 NanoPi boards; this host is $(uname -m) (llama.cpp is built natively, so this still works)" ;;
  esac
  case "$ROLE" in
    server) do_server ;;
    lb) do_lb ;;
  esac
}

main "$@"
