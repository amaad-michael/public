# 🛠️ public

*Homelab automation: Ansible playbooks, container configs, and utility
scripts for my Raspberry Pi cluster and home network.*

![Shell][shell-badge]
![Ansible][ansible-badge]
![Docker][docker-badge]

[shell-badge]: https://img.shields.io/badge/shell-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white
[ansible-badge]: https://img.shields.io/badge/ansible-%231A1918.svg?style=flat&logo=ansible&logoColor=white
[docker-badge]: https://img.shields.io/badge/docker-%230db7ed.svg?style=flat&logo=docker&logoColor=white

## 📁 Layout

```
public/
├── ansible/      # playbook groups: accounts, audits, backups, cleanup,
│                 # cockpit, firewall, Gitea, healthchecks, Jenkins, LAMP,
│                 # LLM, monitoring, monthly, motd, neo1 observability,
│                 # ops toolkit, Pi-hole, Proxmox, reboots, security, vuln,
│                 # workstation
├── containers/   # seventeen Docker Compose stacks: monitoring,
│                 # Pi-hole + Unbound, Gitea, LAMP, Cockpit, LLM inference,
│                 # scanner, OptiPlex LLM, GPU LLM, neo1 observability
│                 # (Docker), Jenkins, backup integrity, cron audit,
│                 # firewall audit, health/SMART, Open Terminal, ops toolkit
├── scripts/      # Linux Admin Toolkit, ops toolkit, and backup, gaming,
│                 # git, LLM, monitoring, network, Pi-hole, provisioning,
│                 # security, and workstation scripts
├── templates/    # bash script templates, the blank-note template, and
│                 # the secure-ci CI template
└── deprecated/   # retired files, kept for git history
```

The repo root also carries `CODEOWNERS` and the shared config
dotfiles (`.gitignore`, `.gitattributes`, `.editorconfig`, `.mdlrc`,
`.yamllint`, `.pre-commit-config.yaml`), and `.github/` holds the
Dependabot config, the PR template, and the CI and security workflows.

## 🔀 How this repo is maintained

This repo runs human in the loop, deliberately. An AI agent builds,
tests, and packages each change, but the analysis is mine: I set the
direction, audit the findings, challenge the claims, and verify the
evidence before anything is accepted. Nothing lands on the agent's
say-so. The agent gets no connections into my systems: no accounts,
no server access, and no push rights. Changes arrive as tested
packages and reach this repo the old fashioned way, applied by hand.
Every change is reviewed, committed, and merged by me.

The full routine, the record keeping, and the standing rules are
documented in [git-repo-workflow.md](git-repo-workflow.md), with
worked examples of the commands themselves.

## ✅ Proof it runs

Claims are cheap, so here is the evidence: both of my local LLM
stacks, running in my home lab in their bare-metal form, built and
deployed by me.

![llama-ui serving Meta-Llama-3.1 8B Instruct](scripts/llm/llama-ui-screenshot-2026-05-29.png)

*The OptiPlex llama.cpp deployment, installed bare-metal by the
[scripts in scripts/llm](scripts/llm/): llama-ui serving
Meta-Llama-3.1 8B Instruct. May 2026.*

![Open WebUI fronting Ollama with deepseek-r1:14b](scripts/llm/open-webui-screenshot-2026-05-28.webp)

*The GPU box Ollama deployment, also installed bare-metal from
[scripts/llm](scripts/llm/): Open WebUI with deepseek-r1:14b
loaded. May 2026.*

Both stacks also exist as container stacks under containers/. The
screenshots show the bare-metal installs, not the containers.

## ⚠️ Note

IP addresses and hostnames are examples from my lab. Replace them with
your own before running anything.

Maintained by A. Michael Tatum, Cloud Linux Engineer
