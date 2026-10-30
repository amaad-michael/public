# scripts/git

Two git helpers. Both change state, one on the machine and one in
the working tree, so this guide states exactly what each one does
before you run it.

## git-setup-new-box-v1.1.sh

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
- Efficient-work settings: `branch.sort` by most recent commit,
  `tag.sort` in version order, `column.ui` auto, the histogram
  diff algorithm with moved code shown as moves
  (`diff.colorMoved`), `merge.conflictstyle` zdiff3 so conflict
  blocks include the base version, `rerere` enabled so recorded
  conflict resolutions are reused, and `core.autocrlf` input so
  CRLF line endings never enter a commit from a Linux box

The global ignore file is created only if it is missing; an existing
one is kept untouched. The created file covers OS and editor noise,
`node_modules/` and `__pycache__/`, and `*.log`. The script also
reports whether the GitHub CLI (`gh`) is installed, without
installing or signing in to it: the laptop role-prep setup script
installs it, and `gh auth login` is a once-per-box manual step.
At the end the script prints the full global config so you can
verify what landed.

The script is idempotent and safe to re-run. Two optional blocks at
the bottom are commented out: a credential helper (cache or store;
with gh authenticated, `gh auth setup-git` is the other route)
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
