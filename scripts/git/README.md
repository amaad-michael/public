# scripts/git

Two git helpers. Both change state, one on the machine and one in
the working tree, so this guide states exactly what each one does
before you run it.

## git-setup-new-box-v1.0.sh

Run once on a new Linux box, as your own user (not root). It writes
the standard global git configuration:

- `user.name` and `user.email`, set to the identity at the top of
  the script
- `core.editor` set to nano
- `init.defaultBranch` set to main
- `pull.rebase` set to false (merge on pull)
- `push.autoSetupRemote` set to true
- `fetch.prune` set to true
- `color.ui` set to auto
- `core.excludesfile` pointing at `~/git/.gitignore_global`

The global ignore file is created only if it is missing; an existing
one is kept untouched. The created file covers OS and editor noise,
`node_modules/` and `__pycache__/`, and `*.log`. At the end the
script prints the full global config so you can verify what landed.

The script is idempotent and safe to re-run. Two optional blocks at
the bottom are commented out: a credential helper (cache or store)
and SSH commit signing. Uncomment at most one credential helper.

## git_commit_and_push.sh

An interactive commit and push helper, run inside a working tree:

1. It detects the currently checked-out branch and aborts on a
   detached HEAD.
1. It prompts for a commit message.
1. It stages everything (`git add .`) and commits with that message.
1. It shows the push target, `origin/<branch>`, and asks for confirmation. Anything other than `y` or `Y` cancels the push and keeps the commit locally.
1. On confirmation it pushes the current branch.

The push always goes to the currently checked-out branch; it never hardcodes main. Any failing step aborts the script: the git steps report their own error, and anything else trips an error trap that reports the line number. Because step 3 stages every
change in the tree, check `git status` first if the tree holds work
you do not want in the same commit.
