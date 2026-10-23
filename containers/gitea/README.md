# gitea — self-hosted git mirror

A single-container Gitea whose job is to pull-mirror the GitHub repos,
so the code survives a GitHub outage, lockout, or deletion. It is the
container form of `scripts/provisioning/install-gitea.sh` — same
version pin (1.26.4), same in-container ports (3000 web, 2222 built-in
SSH), same SQLite posture, hardened the same way (cap_drop ALL,
read_only, no-new-privileges, resource limits).

## 🛠️ Setup

1. Copy `gitea-env.example` to `.env`, generate the two secrets with
   the commands in that file, set `GITEA_DOMAIN` / `GITEA_ROOT_URL` to
   the host's LAN name, and `chmod 600 .env`. Compose refuses to start
   until both secrets are set.
1. Start the stack: `docker compose up -d`. The web installer is
   disabled by design (INSTALL_LOCK), so nothing is exposed
   half-configured.
1. Create the first admin (no registration, no web sign-up):

   `docker compose exec gitea gitea admin user create --username
   michael --password '<generated-password>' --email
   '<your-email>' --admin`

   Generate the password in Proton Pass (32 characters) and store it
   there.
1. Verify before trusting it: open the web UI on port 3003, check
   `/api/healthz`, then run the canary in the Verification section.

Gitea's own settings ship as `app.ini` in this folder, bind-mounted
read-only into the container at `/data/gitea/conf/app.ini`.

## Mirrors

In the web UI: **+ → New Migration**, paste a GitHub repo URL, and
check **This repository will be a mirror**. Do this for each repo under
github.com/amaad-michael and github.com/harborsonar worth surviving
(public, michaeltatum.xyz, hs_web, and the private ones). For private
repos, authenticate with a GitHub personal access token scoped
read-only to those repos; keep the token in Proton Pass, not in any
file here. Set the mirror sync interval to 1 hour on the repos that
change often; the default is fine for the rest. Mirrors are read-only
copies — day-to-day work still happens on GitHub.

## ✅ Verification (canary)

Mirror the tighten scripts' canary discipline:

1. Create an empty repo in the UI.
1. Add your SSH key under your account settings.
1. Clone it over the built-in SSH server:
   `git clone ssh://git@<host>:2222/michael/<repo>.git`
1. Commit, push, and confirm the commit appears in the UI.

If all four steps pass under the hardened profile, the stack is ready
to hold mirrors.

## 💾 Backups

Everything lives in the `gitea_data` volume (repositories, SQLite
database, avatars). For a portable snapshot:
`docker compose exec gitea gitea dump` writes a self-contained archive
inside the container's data area; copy it out and keep it with the
other backups.
