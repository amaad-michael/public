# open-terminal — hardened file I/O service for the LLM stack

A single-container deployment of Open Terminal: the file I/O
service LLM models in Open WebUI call to create, read, modify and
delete files in one sandboxed workspace, with no command execution
and no shell access. This project is the Docker Compose form of
the hardened `docker run` embedded in
`scripts/llm/setup_open_terminal-v1_2.sh` (v1.2); the Ansible form
is `ansible/playbooks/llm/open_terminal_setup.yml`. All three forms
deploy the same image with the same hardening.

## 🛠️ Setup

The bash script prepares the host before it starts the container;
compose does not do host preparation, so do that part once, by
hand or with the Ansible form:

1. Create the workspace and log directories at mode 0700, with the
   workspace owned by 1000:1000 (the script's values):

   ```bash
   sudo mkdir -p /tmp/open-terminal-workspace /var/log/open-terminal
   sudo chmod 700 /tmp/open-terminal-workspace /var/log/open-terminal
   sudo chown 1000:1000 /tmp/open-terminal-workspace
   ```

1. Copy `open-terminal-env.example` to `.env`, chmod 600, and set
   `OPEN_TERMINAL_API_KEY`. On a host where the bash form already
   ran, reuse the key it generated
   (`sudo cat /var/lib/open-terminal/api_key.txt`) so the Open
   WebUI registration keeps working.
1. Start the stack: `docker compose up -d`
1. Register the service in Open WebUI (Admin Settings,
   Integrations, Open Terminal) with the URL
   `http://127.0.0.1:9000` and the same API key, exactly as the
   bash script's closing instructions describe.

## 🔒 Hardening translation

Every flag of the script's `docker run`, and its compose key:

| `docker run` flag | Compose key |
| --- | --- |
| `-p 127.0.0.1:9000:8000` | `ports: ["127.0.0.1:9000:8000"]` |
| `--read-only` | `read_only: true` |
| `--ipc=none` | `ipc: none` |
| `--tmpfs /tmp:rw,noexec,nosuid,size=256m` (and `/run`, `/home`) | `tmpfs:` list, same option strings |
| `-v /tmp/open-terminal-workspace:/workspace:rw,Z` | `volumes:` with `${OPEN_TERMINAL_WORKSPACE}` for the host path |
| `--cap-drop ALL`, `--cap-add SETUID/SETGID/CHOWN` | `cap_drop: [ALL]`, `cap_add:` list |
| `--security-opt no-new-privileges:true` | `security_opt:` |
| `-e OPEN_TERMINAL_*` (four variables) | `environment:`; the API key value comes from `.env` |
| `--memory 256m`, `--cpus 1.0`, `--pids-limit 50` | `mem_limit:`, `cpus:`, `pids_limit:` |
| `--health-cmd/interval/timeout/retries/start-period` | `healthcheck:` (`curl -f http://localhost:8000/health`) |
| `--log-driver json-file`, `--log-opt max-size/max-file` | `logging:` |
| `--restart unless-stopped` | `restart: unless-stopped` |

No flag was dropped. The script sets no `--user`; the container
runs as the image's own user in every form, and the workspace is
prepared for it with the 1000:1000 ownership above.

One scope difference to know: the script's `--uninstall` removes
the workspace, the logs and the API key along with the container.
`docker compose down` removes only the container; delete those
host paths by hand for the full uninstall.

## ✅ Verification (canary)

1. `curl -s http://127.0.0.1:9000/health` responds.
1. A write without the key fails; with the key it succeeds:

   ```bash
   curl -X POST http://127.0.0.1:9000/api/file/write -H "Content-Type: application/json" -d '{"path":"test.txt","content":"should fail"}'
   curl -X POST http://127.0.0.1:9000/api/file/write -H "Content-Type: application/json" -H "Authorization: Bearer <api key>" -d '{"path":"test.txt","content":"hello world"}'
   ```

1. The file lands in the workspace directory and nowhere else.
