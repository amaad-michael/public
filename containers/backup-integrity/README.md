# Backup integrity (container)

The container form of `scripts/backups/backup_integrity_tool_v1.sh`
(Ansible form: `ansible/playbooks/backups/backup_integrity.yml`): a
run-on-demand tool image that generates and verifies SHA-256
manifests (`manifest-YYYYMM.sha256`) for a directory tree, detecting
silent corruption, bit rot, or delta drift between a source and its
copy.

The tool inside the image **is** the bash script, byte-identical to
the primary implementation — copied, not re-written. Byte
compatibility follows from that: on the same tree, this image and
the bash tool produce byte-identical manifests, and each form
verifies the other's manifest. (A second bash implementation,
`scripts/monitoring/local_backups_checker.sh`, uses a different
interface and a single `backup.manifest` name; this image follows
the primary tool.)

## ✅ Build and verify

```bash
cd containers/backup-integrity
docker compose build
BACKUP_INTEGRITY_DIR=/path/to/tree docker compose run --rm backup-integrity generate /data
BACKUP_INTEGRITY_DIR=/path/to/tree docker compose run --rm backup-integrity verify /data
```

A healthy pair of runs: generate writes
`/path/to/tree/manifest-YYYYMM.sha256` and prints `SUCCESS: Manifest
written`; verify prints `SUCCESS: Cryptographic integrity check
passed.`

## 🔧 Usage

Generate a manifest on the source side, after syncing:

```bash
BACKUP_INTEGRITY_DIR=/mnt/offsite-drive docker compose run --rm backup-integrity generate /data
```

Verify on the destination side, after the copy lands:

```bash
BACKUP_INTEGRITY_DIR=/mnt/offsite-drive docker compose run --rm backup-integrity verify /data
```

Exit codes are the bash tool's: 0 means the manifest was generated
or every file matched; 1 means a fatal error or at least one file
missing/corrupt.

## 🌐 Access model

The tree reaches the tool as a bind mount at `/data`:

- **generate** needs the mount writable — the manifest is written
  into the tree's root, exactly where the bash tool writes it, so
  the manifest travels with the tree.
- **verify** only reads. For a verification-only run, mount the tree
  read-only in an override file and the tool cannot alter the
  evidence even by accident:

```yaml
services:
  backup-integrity:
    volumes:
      - ${BACKUP_INTEGRITY_DIR:-./data}:/data:ro
```

Nothing else is mounted and no ports are published; the container
runs once and exits.

## Notes

- The base image is `debian:bookworm-slim` pinned by digest in the
  Dockerfile (multi-arch: amd64 and arm64, so the Pis build the same
  image). Re-verify the digest before bumping it. The tool needs
  only `sha256sum` and `find`, both in the base image.
- Filenames with spaces or newlines are handled the same way as the
  bash tool: the manifest pipeline is `find -print0 | xargs -0
  sha256sum`.
