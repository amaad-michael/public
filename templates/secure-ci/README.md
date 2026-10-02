# Secure CI template

A hardened, reusable `ci.yml` for any new repo. Two files, drop-in:

- `.github/workflows/ci.yml` — lint (pre-commit) + Trivy security scan
- `.github/dependabot.yml` — weekly bumps for the SHA-pinned actions
- `.yamllint` — repo-level yamllint config (line-length 120; the 40-char SHA
  pins can't fit in 80 columns, so the default would fail the lint job)
- `.mdlrc` — disables MD013 for the Ruby `mdl` hook (prose line-length is an
  editor concern, not a CI gate). Note: the pinned hook is Ruby `mdl`, not
  Node markdownlint, so `.markdownlint.json`/`.yaml` would be ignored.

## What makes it "very secure"

1. **SHA-pinned actions** — every `uses:` references a full commit SHA, not a mutable tag. Verified against the GitHub API on 2026-09-14:
   - `actions/checkout` v7.0.1
   - `pre-commit/action` v3.0.1
   - `step-security/harden-runner` v2.21.1
   - `aquasecurity/trivy-action` v0.36.0
1. **Least-privilege tokens** — top-level `permissions: {}` (deny all); each job grants only `contents: read`.
1. **Safe triggers** — `pull_request`, never `pull_request_target`.
1. **No script injection** — no `${{ }}` inside `run:` blocks; values pass via `env:` (see the commented test-job example in the file).
1. **Egress auditing** — harden-runner in `audit` mode on every job.
1. **`persist-credentials: false`** on checkout — no token lingering in git config.
1. **Concurrency** — stale runs cancelled on force-push.

## Use

1. Copy both files into the new repo (`ci.yml` → `.github/workflows/`, `dependabot.yml` → `.github/`).
1. Make sure the repo has a `.pre-commit-config.yaml` (the lint job runs it — your enterprise template already includes one).
1. Add the repo's real test job where the commented example sits, following the `env:`-not-interpolation pattern.
1. Dependabot will keep the SHA pins fresh via weekly PRs — review and merge those like any other.

## Notes

- Trivy fails the build on HIGH/CRITICAL findings (`exit-code: '1'`). Loosen `severity:` if that's too strict for a given repo.
- Harden-runner `audit` mode never breaks builds; switch to `block` per-repo once you know its network needs.
- `"on":` is quoted deliberately — unquoted `on` parses as boolean `true` under YAML 1.1.
