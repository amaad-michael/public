# Git code repo workflow

How code changes move through Michael's repos, and how the work is
recorded. The short version: Charlie builds, tests, and packages
every change; Michael reviews, applies, commits, and merges. The
machine does the labor and the proving. The human keeps authorship,
judgment, and the final say. Nothing reaches a repo without him.

## Contents

1. [The split of roles](#the-split-of-roles)
1. [The routine](#the-routine)
1. [Worked examples: the commands we actually run](#worked-examples-the-commands-we-actually-run)
1. [Record keeping](#record-keeping)
1. [Standing rules](#standing-rules)
1. [Git housekeeping and best practices](#git-housekeeping-and-best-practices)
1. [Why it is built this way](#why-it-is-built-this-way)

## The split of roles

- Charlie's box has no GitHub credential and `gh` is not
  authenticated there. Pushes, branch pushes, and PR creation cannot
  be done from Charlie's side, by design.
- Charlie works in scratch clones on his own machine: reading code,
  making changes, running every check, and packaging the result.
- Michael lands everything: his clone, his branch, his commit, his
  name on the commit, his push, his PR, his merge.
- Charlie never puts his own name on Michael's commits. Provenance
  notes (who tested what) live in handoff docs and PR descriptions,
  not in commit authorship.

## The routine

1. Work starts from one of three places: Michael asks for a change,
   a nightly audit reports a finding, or an open board item calls
   for it.
1. Charlie clones fresh, or pulls the target repo to the current
   main, in a scratch tree. Changes are never built on a stale
   clone: a pull between building and applying would silently
   revert newer work when the stale copy lands.
1. Charlie makes the change in the scratch tree and reads every
   file he touches in full before deciding anything about it.
1. Charlie pre-checks the change the way CI will, before it ever
   reaches Michael: the repo's own linters (ShellCheck, yamllint,
   mdl, actionlint, gitleaks where they apply), syntax checks, and
   real functional runs. Config-level work runs in distro chroots;
   anything whose behavior runs through systemd runs against a
   real systemd PID 1 in a container rootfs, never a stub. Every
   branch of a deliverable gets a real run. A finding a subagent
   reports is re-verified by Charlie firsthand before it is
   treated as fact.
1. Defects found in testing are fixed in the scratch tree and the
   tests run again. Only a green, verified change gets packaged.
1. Packaging: the change is exported as a patch file, verified with
   `git apply --check` against a pristine clone of the exact base
   commit, with the applied tree compared against the tested tree.
   A HANDOFF.md goes with it: what the patch does, the exact
   apply/branch/commit/push steps, and a ready-to-paste PR
   description. Standing rule: every repo PR workflow includes that
   PR description, proactively.
1. Michael reviews the handoff and, when he is ready, copies the
   patch to `~/git/` on pi1 and runs the workflow: branch, apply,
   commit, push, then opens the PR from the URL the push prints
   (`gh` is not installed on pi1).
1. When Michael reports the PR and the merge, Charlie records both
   (PR number, merge commit) on the board item and closes it.
1. The nightly audits then keep watch: each repo goal pulls the
   latest code every night, re-runs its full check suite, diffs
   against the previous run, and reports only new or changed
   findings, so a landed change that regresses something is caught
   within a day.

## Worked examples: the commands we actually run

The routine above, as literal commands. These are the real command
lines from the Cockpit consolidation landing (October 2026),
generalized only where a name is repo-specific. Command blocks
carry no inline comments, per the standing rule; the prose around
each block says what it proves.

### Starting from a clean base

Preliminary step, always: know exactly what the change sits on.
Record the base commit before touching anything; the patch is
later proven against this exact commit.

```bash
cd ~/workspace/scratch
git clone https://github.com/amaad-michael/public repo-work
cd repo-work
git rev-parse HEAD
git status
```

When a scratch clone already exists, refresh it instead, and
confirm it is clean before building on it. A dirty scratch clone
is discarded and re-cloned, never tidied into trust.

```bash
cd ~/workspace/scratch/repo-work
git checkout main
git pull
git status --porcelain
```

### Checking the change before packaging

The change is reviewed as a diff, and with whitespace ignored, so
what ships is exactly the intended edit and nothing else.

```bash
git status --porcelain
git diff --stat
git diff
git diff -w
```

Every file the patch adds ends with exactly one trailing newline;
extra blank lines at end of file fail the repo's hooks just like a
missing newline does.

```bash
tail -c2 changed-file.md | od -An -c
```

The linters run at their real paths (none of them are on PATH),
the same way CI will run them.

```bash
~/workspace/tools/bin/shellcheck scripts/example.sh
~/workspace/tools/lintvenv/bin/yamllint -c .yamllint changed-file.yml
~/workspace/tools/bin/actionlint -shellcheck ~/workspace/tools/bin/shellcheck .github/workflows/ci.yml
~/workspace/tools/bin/gitleaks dir . --no-banner
```

### Packaging and proving the patch

The patch is exported from the tested tree, checksummed, and then
proven against a pristine clone of the recorded base: it must
apply cleanly, and the tree it produces must be byte-identical to
the tree that was tested.

```bash
git add -A
git diff --cached > ~/workspace/your_files/example-change.patch
sha256sum ~/workspace/your_files/example-change.patch
```

```bash
cd ~/workspace/scratch
git clone https://github.com/amaad-michael/public verify-clone
cd verify-clone
git checkout 72dccb6
git apply --check ~/workspace/your_files/example-change.patch
git apply ~/workspace/your_files/example-change.patch
diff -r --exclude=.git . ~/workspace/scratch/repo-work
```

When a handoff file goes through revisions under the same name,
the checksum goes to Michael with it, so he can confirm the copy
he holds is the copy that was tested. Browsers and file transfers
serve stale cached copies silently.

### Landing it (Michael's steps, on pi1)

The patch rides to the server as a file in `~/git/`, never the
home directory root. The PR opens from the URL the push prints,
because `gh` is not installed on pi1.

```bash
cd ~/git/public
git checkout main
git pull
git checkout -b cockpit-consolidation
git apply ~/git/cockpit-consolidation.patch
git add -A
git commit -m "Consolidate Cockpit setup into one playbook and one script"
git push -u origin cockpit-consolidation
```

### After the merge

Michael reports the PR number and the merge; Charlie records both
on the board item and closes it. The landed state is confirmed
from the repo itself, not from memory.

```bash
cd ~/git/public
git checkout main
git pull
git log --oneline -5
git branch -d cockpit-consolidation
git push origin --delete cockpit-consolidation
```

### Cleanup steps

Scratch trees and test rigs are disposable and are removed when
the work lands, so the next job starts from a known state.

```bash
rm -rf ~/workspace/scratch/repo-work ~/workspace/scratch/verify-clone
git fetch --prune
git remote prune origin
git stash list
git gc
```

Any superseded handoff file is trashed, not deleted outright, and
keeps its expiry date. A branch that was never merged is removed
only with the force form, and only after confirming nothing on it
is still wanted.

```bash
git branch -D unmerged-branch-name
```

### When something goes wrong

An uncommitted edit that should not have happened is reverted in
place. A commit that has not been pushed yet can be redone
freely. A commit that already landed is reverted with a new
commit, never rewritten.

```bash
git restore changed-file.md
git reset --soft HEAD~1
git revert <merge-or-commit-sha>
```

Authorship is Michael's, always. If a commit ever lands carrying
the wrong author name, the fix is an amend that resets authorship
to his own git config.

```bash
git commit --amend --reset-author
```

## Record keeping

- The action-items board is the work queue: one dated file per
  day, Open and Done sections. Every item carries a permanent
  6-character hex ID; the display number is ordering only and can
  change, the ID never does. A new item takes the next number
  after the highest open item. Closures freeze the item's number
  in the Done section as history.
- The board ID registry lists every ID ever minted and its state,
  so any citation of an item resolves forever.
- MEMORY.md holds the durable facts and decisions, dated, in
  Michael's own words where he stated them. A verbatim pin
  (memory-gate) guards it: if a background process rewrites or
  drops a standing bullet, the next check fails until a working
  turn reviews the diff and re-pins deliberately.
- The consistency baseline pins the numbers everyone else copies:
  board open/done counts, the cron roster, file hashes. Any turn
  that changes a guarded fact updates the pins in the same turn
  and re-runs verify-state (18 checks) before calling the work
  done.
- Goal records carry status pulses: the current state, a wait, or
  a blocker. Never version manifests; versions live in filenames.
- Documents are versioned in their filenames. A material update
  bumps the version and the superseded copy is trashed, so there
  is always exactly one current copy to point at.
- The daily log is the day's narrative: what was decided, what was
  verified, what failed and how it was fixed.

## Standing rules

- Nothing is committed, pushed, or opened as a PR without
  Michael's explicit approval. A patch in a handoff folder is a
  proposal, not a landing.
- Every repo change is pre-checked the way CI will run it, every
  time. A patch that applies cleanly but fails CI is a failed
  handoff.
- No guessing: a fact about a repo, a tool, or a config is stated
  only from a primary source (the pinned revision's own files,
  the tool's own docs or source, a reproduced test), or it is
  stated as unknown and then looked up.
- A change that touches a sitemap-covered page or asset carries
  that URL's `lastmod` bump in the same patch.
- Handoff files land in `~/git/` on the target server, never the
  home directory root.
- Command blocks handed to Michael start from an explicit `cd`,
  carry no inline comments, and spell out `chmod +x` where a
  script needs it.

## Git housekeeping and best practices

- One change per patch, one patch per PR. A bundle that mixes
  unrelated changes cannot be reviewed, reverted, or bisected
  cleanly.
- Never build on a stale clone. The base commit is recorded at
  the start of the job and named in the handoff, so the proof
  run and the landing talk about the same tree.
- `git apply --check` proves a patch applies. It does not prove
  the patch is right. The applied tree is diffed against the
  tested tree, and the repo's own hooks and linters run before
  packaging, not after.
- Content fixes to repo files are made in place against the
  target's own working tree, never by overwriting it with a copy
  built from an older clone.
- Branch names say what the change is (`cockpit-consolidation`,
  `gumroad-guides-card`). Merged branches are deleted on both
  sides; the merge commit on main is the permanent record.
- Stashes are a parking spot, not storage. Anything in
  `git stash list` older than the job that put it there gets
  reviewed and dropped.
- A secret scan (`gitleaks`) runs over any tree before it is
  packaged or published. Git history keeps whatever a file hides,
  so scrubbing after the fact is not a plan.
- The checksum of a patch is part of the handoff. If the file
  changed after testing, it is re-tested and re-checksummed;
  there is no "same patch, new bytes."
- Windows line endings and stray whitespace are defects, caught
  at packaging time by the repo's own hooks, not discovered by
  CI on Michael's time.

## Why it is built this way

It is human-in-the-loop by construction, not by slogan. The agent
half contributes speed, stamina, and exhaustive checking: full
audits every night, every branch of a change actually run, every
claim tied to evidence. The human half contributes the things that
should not be delegated: taste, priorities, authorship, and the
decision of what lands. The records are the contract between the
two halves. Because every step leaves a dated, checkable trace,
either side can audit the other at any time, and a mistake, once
caught, becomes a written rule that prevents the repeat instead of
a lesson that fades.
