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
├── ansible/      # playbook groups: accounts, cleanup, cockpit, firewall,
│                 # healthchecks, LLM, monthly, motd, Pi-hole, Proxmox,
│                 # reboots, vuln, workstation
├── containers/   # ten Docker Compose stacks: monitoring, Pi-hole + Unbound,
│                 # Gitea, LAMP, Cockpit, LLM inference, scanner,
│                 # OptiPlex LLM, GPU LLM, neo1 observability (Docker)
├── scripts/      # Linux Admin Toolkit, ops toolkit, and backup, gaming,
│                 # git, LLM, monitoring, network, Pi-hole, provisioning,
│                 # security, and workstation scripts
├── templates/    # bash script templates and the secure-ci CI template
└── deprecated/   # retired files, kept for git history
```

## 🔀 How this repo is maintained

Changes here are built, tested, and packaged by an AI agent, then
reviewed, committed, and merged by me. The full routine, the record
keeping, and the standing rules are documented in
[git-repo-workflow.md](git-repo-workflow.md), with worked examples of
the commands themselves.

## ⚠️ Note

IP addresses and hostnames are examples from my lab. Replace them with
your own before running anything.

Maintained by A. Michael Tatum, Cloud Linux Engineer
