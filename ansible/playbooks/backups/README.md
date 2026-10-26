# Backup playbooks

The Ansible form of backup integrity checking. One playbook generates
and verifies the same SHA-256 manifests as the bash tool.

| Playbook | Targets | Output |
|---|---|---|
| `backup_integrity.yml` | `hosts: all` (scope with `--limit`) | `manifest-YYYYMM.sha256` in the target directory, or a pass/fail verification |

## 📦 backup_integrity.yml

The bash form it mirrors is the primary tool,
`scripts/backups/backup_integrity_tool_v1.sh` (guide:
`scripts/backups/backup_integrity_tool_guide-v1.md`):

- **generate** — recursively hash every regular file under the target
  into `manifest-YYYYMM.sha256` at the target's root, excluding the
  manifests themselves. The playbook runs the identical pipeline
  (`find . -type f ! -name "manifest-*.sha256" -print0 | xargs -0
  sha256sum`) in the identical working directory, so a manifest from
  either form verifies under the other with `sha256sum -c`, and on an
  unchanged tree the bytes are identical. One behavioural refinement:
  the playbook builds the manifest to a temp file and replaces the
  existing manifest only when the bytes differ, so re-running
  generate on an unchanged tree reports no change (the bash tool
  rewrites the file unconditionally).
- **verify** — locate the most recent `manifest-*.sha256` at the
  target's root and run `sha256sum --quiet -c` against it, with the
  bash tool's own SUCCESS/FATAL messages and exit semantics: the play
  fails on any host whose tree does not match its manifest.

A second bash implementation,
`scripts/monitoring/local_backups_checker.sh`, formerly existed with
a different interface (`--generate`/`--verify`, a single
`backup.manifest` name, a hand-rolled verification loop,
`verify_*.log` files); it was removed on 2026-10-22 because the two
tools wrote incompatible manifests. This playbook follows the
primary tool only.

The backup **run** itself (rsync into timestamped directories) is a
different function; its forms live in
`scripts/linux-admin-toolkit/18-backup-run/` and
`19-backup-verify/`.

## 🛠️ Usage

```bash
cd ansible
ansible-playbook -i hosts playbooks/backups/backup_integrity.yml -l pi1 -e backup_integrity_target=/mnt/backup/infrastructure
ansible-playbook -i hosts playbooks/backups/backup_integrity.yml -l pi1 -e backup_integrity_target=/mnt/backup/infrastructure -e backup_integrity_action=verify
```

Options, passed as extra vars:

| Option | Effect |
|---|---|
| `-e backup_integrity_target=/path` | Directory on the target host to manifest or verify. Required. |
| `-e backup_integrity_action=generate` | Write/refresh the manifest (default). |
| `-e backup_integrity_action=verify` | Verify the tree against its most recent manifest; fails the play on mismatch. |
