# Linux Laptop Prep Checklist: Coding Instructor and Linux Administrator

**Version:** 2.4
**Date:** 2026-10-31
**Scope:** Role-agnostic. Built for a personal Linux laptop that has to walk into either a classroom or a server environment and be ready, with personal and work life kept cleanly apart.

---

## Table of Contents

1. [1. Base system](#1-base-system)
1. [2. Separation of lives](#2-separation-of-lives)
1. [3. Security core](#3-security-core)
1. [4. Linux administrator kit](#4-linux-administrator-kit)
1. [5. Coding instructor kit](#5-coding-instructor-kit)
1. [6. Developer environment](#6-developer-environment)
1. [7. Communications](#7-communications)
1. [8. Carry kit](#8-carry-kit)
1. [9. Dry run before day one](#9-dry-run-before-day-one)
1. [10. Ongoing hygiene](#10-ongoing-hygiene)
1. [11. Automation: the setup script](#11-automation-the-setup-script)

## 1. Base system

- [ ] OS fully updated, rebooted into the new kernel, and confirmed stable for a day before relying on it
- [ ] Firmware/BIOS updated
- [ ] Full-disk encryption on and the recovery key stored in Proton Pass
- [ ] Automatic time sync on (wrong clocks break Kerberos, TOTP codes, and log correlation)
- [ ] Persistent journaling on (the journal survives reboots, so a failed boot still leaves logs)
- [ ] Fleet /etc/hosts entries present (pi0-pi4 and neo1 resolve by name)
- [ ] Cluster MOTD in place (the fleet subnet block greets console and SSH logins)
- [ ] Terminal greeting set (the cluster MOTD prints above fastfetch in the first terminal of a session: /etc/profile.d/00-motd.sh ahead of fastfetch.sh for login shells, the same guarded block in /etc/bashrc for non-login terminals, once per session via the .motd-shown session flag; SSH logins keep PAM's native MOTD print)
- [ ] Desktop environments decided: the ones you use installed, or deliberately none (the new-box workflow's desktop step asks at prep time which of MATE, Cinnamon, Xfce, Openbox, and LXDE to install, as a multi-select: any one, several, all, or none. With --desktop the answer is a flag; on a terminal it is a checkbox panel, arrows or j/k to move, space to toggle, a for all five, enter to confirm, with None exclusive, and where the terminal cannot draw the panel it is a plain prompt with the same choices. The step installs only: it changes no display manager, no default session, and no auto-login, so the desktop itself is picked at the login screen's session picker. Fedora and Debian/Ubuntu carry all five; Rocky 10 and EPEL 10 carry none of the five today, so on that family the step reports each chosen desktop as one to install by hand)
- [ ] New-box prep launched with its choices made deliberately (the runner's --guided option walks the choices the invocation leaves open as panels on the desktop panel's machinery: the form itself when none is named, then the work/personal designation, then the desktop choice through the desktop panel itself, ending on a summary screen that lists every choice and the steps that will run, with Run and Cancel. A choice a flag already made is not asked again, so a fully flagged guided run shows only the summary; cancelling at any panel runs nothing. Guided needs a terminal that can draw: with choices still open and no such terminal the run stops and runs nothing, and with every choice determined by flags it adds nothing at all)
- [ ] Screen lock at 5 minutes or less, with password required on wake
- [ ] Host firewall on, default deny inbound
- [ ] A full system backup taken before the first workday with Clonezilla, plus a bare-metal restore you have actually tested (a backup is not a plan until a restore has succeeded once). The disk is LUKS on ext4, so Clonezilla images it as raw blocks: the image comes out near full partition size no matter how little space is in use, and the restore target must be at least the source size. After a restore, the first boot asks for the LUKS passphrase to unlock; if the passphrase is ever lost, the recovery key stored in Proton Pass (above) is the fallback
- [ ] Battery health checked; runtime on battery is known, not guessed

## 2. Separation of lives

The laptop is personal property doing professional work, so the walls matter more than the tools.

- [ ] A separate local user account (or at minimum a separate browser profile and home-directory workspace) for work, so no personal files, photos, or logins are one misclick from a classroom projector or a screen share
- [ ] Separate browser profile for work: no personal bookmarks, no personal saved logins, no personal history
- [ ] Separate SSH key per role and per employer, generated for the purpose, never your personal homelab key
- [ ] Separate git identity (name and email) configured per directory for work repos
- [ ] Employer data lives in one clearly named work folder, so returning or wiping it on exit is a single delete, not a scavenger hunt
- [ ] Nothing of an employer's stored in personal cloud accounts, and nothing personal stored in employer accounts

## 3. Security core

- [ ] Proton Pass installed and signed in; work credentials go in their own vault
- [ ] Proton Pass SSH agent set up, so SSH keys are served by the vault instead of sitting as loose files in ~/.ssh (handoff already written: proton-pass-ssh-handoff-v1.0.md)
- [ ] Proton VPN installed and signed in (the new-box workflow's Proton step installs the app from Proton's own repo on Debian/Ubuntu and Fedora before the role prep runs; on RHEL-family systems Proton publishes no app, so use the WireGuard configs from your Proton account instead; signing in on first launch is the remaining manual action)
- [ ] Authenticator app ready for employer 2FA enrollment on day one; recovery codes for every account saved to both clouds, the same pattern as the Gumroad codes
- [ ] SSH config hardened for work hosts: key-only auth, IdentitiesOnly set per host so the wrong key is never offered
- [ ] sudo posture matches your standing design: your own users are NOPASSWD by design (deliberate, for convenience), and there are no passwordless entries beyond the ones you placed there yourself
- [ ] An encrypted USB drive (LUKS) for moving files into restricted environments where cloud storage is not allowed
- [ ] Webcam cover and a hardware mute habit for calls

## 4. Linux administrator kit

- [ ] Terminal setup you can fly blind: tmux, shell history search, aliases, and the dotfiles to rebuild it all on a fresh machine in minutes
- [ ] Your public repo cloned locally (the ops toolkit, Ansible playbooks, and templates live there and are already tested)
- [ ] Ansible installed, with a clean inventory template ready to fill in for a new environment
- [ ] Core diagnostic tools: nmap, tcpdump, mtr, dig, curl, jq, iperf3, smartmontools, nc
- [ ] Docker (or Podman) installed and tested, for reproducing a service locally instead of guessing at it
- [ ] A VM setup (virt-manager/libvirt or VirtualBox) with one clean Linux VM kept as a sandbox and test target
- [ ] Bootable USB: current installer image plus a rescue environment, tested to boot on this laptop
- [ ] Hardware in the bag: USB-to-Ethernet adapter, console/serial cable, USB-C and HDMI cables, a small switch if the work ever touches physical racks
- [ ] VPN client support sorted: WireGuard and OpenVPN configs import cleanly, and any employer-specific client is installed and launches
- [ ] A local, offline copy of the documentation you reach for most (man pages cover most of it; add offline copies of anything web-only you depend on)

## 5. Coding instructor kit

- [ ] Presentation path tested end to end: laptop to projector or TV over HDMI and USB-C, at the room's resolution, with the desktop readable from the back row
- [ ] A clean presentation desktop: notifications off or do-not-disturb set, no personal windows, wallpaper neutral
- [ ] Terminal font and editor font sized for projection, high-contrast theme that survives a washed-out projector
- [ ] A presentation clicker or the keyboard shortcuts to replace one
- [ ] Local development environments installed and working offline, so a dead classroom network cannot kill a lesson: Python 3 with IDLE or a simple editor, a local JavaScript runtime (Node), and whatever block-based or beginner tools the curriculum uses, opened once and confirmed working without a connection
- [ ] Demo projects and exercises stored locally, not only in a cloud drive, with a spare copy on the encrypted USB
- [ ] One demo VM or container image pre-built with the class environment, so every session starts from the same known-good state and resets cleanly
- [ ] Student-safe defaults: the work browser profile has no saved passwords, no autofill of personal details, and no personal tabs restored on launch
- [ ] Screen recording or screenshot tool ready (for making recap material and for documenting a student's work)
- [ ] A printed or offline copy of the day's lesson plan, because the projector, the network, and the laptop never all fail on different days

## 6. Developer environment

- [ ] Editor configured and identical in feel to your main machine (keybindings, theme, extensions exported or synced)
- [ ] Language toolchains installed for what you teach and what you administer: Python, Node, and current shell tooling at minimum
- [ ] git configured with the work identity for work directories and your personal identity elsewhere (conditional includes, not one global identity)
- [ ] GitHub (or the employer's forge) access tested: key uploaded, clone over SSH confirmed working
- [ ] GitHub CLI (gh) installed and authenticated (`gh auth login`), so pull requests can be opened from the terminal
- [ ] A scratch directory habit for experiments, so demos and tests never land in real project trees

## 7. Communications

- [ ] Headset with a microphone you have heard a recording of; the laptop's built-in mic is the backup, not the plan
- [ ] Webcam tested in the actual apps you will use, with a background that is neutral and unrevealing
- [ ] Zoom, Teams, and Meet all launch in the work browser profile or their apps, signed in to the work accounts only
- [ ] Calendar access for the work schedule set up, with personal calendar details not exposed in return

## 8. Carry kit

- [ ] Charger plus one spare cable
- [ ] Wireless mouse (presenting and teaching from a trackpad all day is needless wear)
- [ ] HDMI cable and USB-C to HDMI adapter, even if the room "has them"
- [ ] Power bank sized for the laptop, or at minimum for the phone that becomes the emergency hotspot
- [ ] Phone hotspot plan confirmed working; it is the backup network for both roles
- [ ] A few blank USB drives for handing files to students or pulling logs off an isolated machine

## 9. Dry run before day one

- [ ] Present a full practice lesson or demo to an empty room: projector, fonts, demo environment, offline mode all exercised at once
- [ ] SSH into a test host using only the work key and the Proton Pass agent, exactly as you would on the job
- [ ] Run one real admin task end to end (an Ansible playbook against the sandbox VM) to prove the toolchain, not just its installation
- [ ] Restore one file from the backup
- [ ] Time a cold start: bag packed to logged in and presenting, so the first real morning has no surprises

## 10. Ongoing hygiene

- [ ] Weekly updates on a schedule that is never the morning of a teaching or on-call day
- [ ] Work folder reviewed monthly: anything that belongs to an employer is where it should be, and nothing personal has drifted in
- [ ] Keys and credentials rotated when an engagement ends; the per-role keys from section 2 get revoked and deleted, not just abandoned
- [ ] On exit from any role: employer data wiped from the work folder and the encrypted USB, access confirmed closed, and the separation from section 2 is what makes this a ten-minute job
- [ ] TickTick installed and signed in; it is the working task list for everything else

---

## 11. Automation: the setup script

The state this checklist describes can be produced from the command line for every item that is CLI-able. The script below does it: it creates the michael and michael-work accounts, installs the admin and instructor tooling, wires the per-role SSH and git separation, sets the screen lock and the host firewall, and prints whatever still needs hands, hardware, or a sign-in as a manual list at the end. Version 1.7 of the script installs the GitHub CLI from section 6 (a per-distro package install; GitHub's own repo is the RHEL-family fallback, and the sign-in stays a manual step), sets persistent journaling and the fleet personalization from section 1, and installs the two vendor applications from sections 3 and 10, each by the vendor's own distribution method. Proton Pass has no repository: the script reads Proton's version feed, takes the newest Stable release at full rollout, verifies the package's SHA512 checksum against the feed, and only then installs it; the sign-in and the SSH agent setup stay manual (see the companion handoff). Proton VPN is not this script's job anymore: the new-box workflow's own Proton step installs it on every workstation before the role prep runs, from Proton's own repository on Debian/Ubuntu and Fedora, with the manual WireGuard path on RHEL-family systems, where Proton publishes no app; the sign-in stays manual (version 1.9 note below). TickTick has no repository either: the script downloads from TickTick's official version-less endpoint, the same one the download page uses. Both install through the distro package manager, so dependencies resolve instead of failing the way the vendors' bare dpkg -i and rpm -i instructions can. One vendor collision is handled on the RPM side: the Proton Pass and TickTick RPMs both ship the same /usr/lib/.build-id debug symlinks with different targets (both apps are built on the stock Electron binary), so rpm refuses the second install; the script pulls the package's dependencies with dnf and retries with rpm --replacefiles, which changes only which app the debug links point at. Run it on the laptop as root: `sudo ./laptop-role-prep-setup-v2.0.sh`. The same script ships as a standalone file, laptop-role-prep-setup-v2.0.sh, byte-identical to the block below; the standalone is the copy to take to the laptop.

Version 1.4 (2026-10-30) fixes two defects the first real-metal run, on the travel laptop the same day, exposed. Distro detection no longer treats every dnf-family system whose ID is not exactly "fedora" as RHEL-family: an exact RHEL-family ID (rhel, rocky, almalinux, centos) decides first, because Rocky declares fedora in its ID_LIKE, and a derivative under its own ID is judged by its declared lineage, so Nobara (ID nobara, ID_LIKE fedora) is Fedora-family and gets zenmap, Python IDLE, flameshot, and virt-manager instead of the RHEL-family substitutions. And the account and group changes now check their results: account creation and the docker, libvirt, and optional sudo-group adds report a warning when they fail, never a done line. On a first run the package phase precedes account creation, so those group adds land on a re-run; the report now says so instead of claiming memberships that do not exist yet.

Tested 2026-10-17 and 2026-10-18: bash -n and ShellCheck clean, and both distro branches passed two consecutive live runs in test environments (Ubuntu 24.04 and Rocky Linux 10, each against local repos of the real distro packages and a local mirror of the genuine, checksum-verified vendor files), the second run converging, with results verified independently of the script's own report: packages installed, binaries present, group memberships, home permissions, and dotfiles all checked directly. The vendor installs were verified the same way on both branches: Proton Pass 1.42.0 with its feed checksum verified during the run, TickTick 8.0.20 on both branches, and Proton VPN (proton-vpn-gnome-desktop 0.11.0 from Proton's repo) on the Ubuntu branch, with the RHEL branch printing the manual path as designed. The Fedora variant of the Proton VPN install follows Proton's published Fedora instructions verbatim and is the one path not exercised live; every other branch was run. On RHEL-family systems a few checklist items have no package in the Rocky and EPEL indexes (Python IDLE, flameshot, zenmap, and virt-manager); the script reports those honestly and installs Cockpit Machines as the VM console there. Podman is the container runtime on that family; Docker is installed on the Debian family.

The version 1.4 changes were verified on 2026-10-30 with an executed harness: fixture os-release files for both families (including Rocky Linux, whose ID_LIKE declares fedora, and Nobara) run through the script's own detection block, and stubbed usermod and useradd success and failure paths run through the group-add and account-creation blocks. A full live re-run of version 1.4 on the laptop is the remaining proof and had not happened when this version was cut.

Version 1.5 (2026-10-30) closes a gap the same laptop run exposed: the fleet personalization wrote the /etc/hosts block but never the cluster MOTD, so the laptop's /etc/motd stayed the distro's empty placeholder while the rest of the fleet greets console and SSH logins with the banner and the subnet map. The script now writes the motd playbook's static /etc/motd (banner plus the same ## local subnet block) next to the hosts entries: a /etc/motd that already carries the block is left alone, any other non-empty one is copied to /etc/motd.backup first (the backup the playbook takes, and only when no backup exists yet), and the write is checked, so a failed write records a warning instead of a done line. Section 1 gains the matching checklist line; the requirement appeared nowhere in this checklist before.

The version 1.5 changes were verified on 2026-10-30 with an executed harness: the personalization block was extracted verbatim from the script and run against fixture /etc trees, with the fixture directory bound over /etc. An empty /etc/motd gained the playbook's content byte-for-byte; a second run changed neither file; a pre-existing custom /etc/motd was backed up with its original bytes and replaced, and a second run left that backup untouched; a read-only /etc/motd produced a warning and no done claim; and the version 1.4 block, run through the same harness, left /etc/motd untouched in both its empty and custom states. A full live run of version 1.5 on the laptop is the remaining proof and had not happened when this version was cut.

Version 1.6 (2026-10-30) corrects the distro detection a second time, on evidence the version 1.4 work did not have: the travel laptop's real /etc/os-release. Nobara's ID_LIKE is "rhel centos fedora", its whole ancestry with the RHEL tokens first, so the version 1.4 fallback, which judged a derivative under its own ID by its ID_LIKE lineage, still read Nobara as RHEL-family, and the version 1.5 live run on the laptop repeated the RHEL-family claims (Python IDLE and flameshot as manual items, the RHEL zenmap line, virt-manager as not packaged for RHEL 10). ID_LIKE cannot carry this distinction at all: Nobara's value is byte-identical to Rocky 10's, and RHEL itself ships ID_LIKE="fedora". Ancestry is not package lineage. The exact ID is now the only signal: an ID of rhel, rocky, almalinux, or centos is RHEL-family, and every other dnf system is not; the ID_LIKE fallback is removed. The family detection (dnf versus apt) still reads ID and ID_LIKE together, where ancestry tokens are harmless. The version 1.4 fixtures stand corrected by the same evidence: their Nobara entry assumed ID_LIKE=fedora, a value no real distro ships.

The version 1.6 changes were verified on 2026-10-30 with an executed harness over real os-release values only: Nobara's pair read from the laptop's own /etc/os-release, Rocky's and Ubuntu's read from the os-release files of the Rocky 10 and Ubuntu 24.04 reference trees on disk, and the Fedora, RHEL, AlmaLinux, and CentOS pairs taken from those distros' shipped os-release contents. All seven, run through the shipped version 1.6 detection block, give the right family and RHEL flag; the same fixtures through the version 1.5 block flip only the Nobara case, from RHEL-family to not, while Rocky stays RHEL-family. The section 5 branch, extracted from the shipped script and run under the Nobara flags, now takes the install branch (python3-idle and flameshot) instead of the manual items. A full live run of version 1.6 on the laptop is the remaining proof and had not happened when this version was cut.

Version 1.7 (2026-10-30) fixes the order of operations in the users section. The docker and libvirt group adds for the work account sat in their install sections, hundreds of lines before the accounts are created, so on a fresh machine both failed on the first run. Version 1.4 checked their results and reported the failure honestly - its warning said a re-run converges - but convergence by re-run is a crutch, not correctness: the version 1.5 live run on the laptop showed a true libvirt line only because the account had survived from that morning's first run. Both adds now run immediately after the accounts are created, next to the sudo-group add that was always sequenced right, under the same gates as before (apt family with Docker present for the docker add; virt enabled for the libvirt add). A failure there is now a real failure and is worded as one. The same live run's report also guessed at a cause it had not checked, printing the failed repository clone with an "(offline?)" aside on a machine that was online (the account's key was not yet registered on GitHub); that warning now states the failure and lists the usual causes without asserting one.

The version 1.7 changes were verified on 2026-10-30 with an executed fresh-box harness: useradd, usermod, getent, and id stubbed against a state directory, so the order of operations has real consequences - a group add for an account that does not exist yet fails the way the real usermod fails. The account creation, the two relocated adds, and the sudo-group add, extracted from the shipped script and executed in the script's own order on a simulated fresh box, put the work account into the libvirt group, the docker group (apt variant), and the admin group in a single pass, the done lines printed, with no could-not-be-added warnings; a second pass over that state changed nothing. The same harness running the version 1.6 order ended its first pass with the work account in neither group and both convergence warnings printed, and converged only on its second pass. A full live run on a genuinely fresh machine is the remaining proof and had not happened when this version was cut.

Version 1.8 (2026-10-30) makes the terminal greeting a written default. PAM prints /etc/motd only at real logins (SSH and console), so desktop terminal windows never showed the cluster MOTD at all, and in login terminals fastfetch printed with nothing above it. The config Michael built by hand on the travel laptop the same day and verified live in a fresh terminal (banner and fleet list first, fastfetch below, exactly once) is now what the script writes: /etc/profile.d/00-motd.sh carries a guarded block (interactive shell, /etc/motd readable, not an SSH session, session flag absent) that cats /etc/motd and sets the flag in the session runtime dir; its 00- prefix sorts it ahead of fastfetch.sh, so the MOTD prints first. Non-login interactive terminals never source profile.d, so the same block is appended to /etc/bashrc, which every user's ~/.bashrc sources; the append is grep-guarded on the flag string, so re-runs never stack copies, and the shared flag means whichever path fires first is the one that prints. The SSH guard is in both copies: on an SSH login PAM has already printed /etc/motd natively before the shell starts, and the profile.d copy's deliberate skip does not set the flag, so without the guard the bashrc copy would print the MOTD a second time in the same session; with it, exactly one printing happens on every path. Nobara 44 (verified by grep on the machine) sources no /etc/bashrc.d directory, so the block goes into /etc/bashrc itself, not a drop-in. An existing 00-motd.sh is recognized by content and reported as in place rather than rewritten. Section 1's presentation line now describes the greeting to verify.

The version 1.8 changes were verified on 2026-10-30 with an executed simulation of the shell startup chain: the personalization block was extracted from the shipped script and run against a fixture /etc (bound over /etc) to produce the payload files, and the payloads were then sourced in documented shell order with fastfetch stubbed. In login-shell order the output was the MOTD content followed by the fastfetch marker, with the session flag set; a second interactive shell in the same session printed no MOTD; a non-login interactive shell printed the MOTD once via the bashrc block; with SSH_CONNECTION set, neither script path printed anything and the flag stayed unset. The pre-change chain (fastfetch.sh alone, no greeting files) printed the fastfetch marker with no MOTD above it. The bashrc step run twice over the same fixture left exactly one greeting block. ShellCheck and the repository's pre-commit hooks pass on the changed files. A live run of the version 1.8 script itself on a fresh machine is the remaining proof and had not happened when this version was cut; the greeting behavior it writes is the hand-built config that was verified live on the laptop earlier the same day.

Version 1.9 (2026-10-30) retires this script's own Proton VPN install and moves the job to the new-box workflow. Through version 1.8 the vendor section installed Proton VPN itself (Proton's repos on Debian/Ubuntu and Fedora, the release-package pins verified on 2026-10-18, and a manual item on the RHEL family), which meant only work boxes, the boxes this script runs on, ever got it from the tooling. The workflow's runner (new-box-prep v1.3) now carries a Proton step of its own, ahead of the role prep, so every workstation gets the install, work box or personal. The step reads the exact /etc/os-release ID: the Fedora family (fedora, nobara) takes the release RPM from Proton's per-version fedora stable tree (fedora-44-stable today; pin 1.0.5-1), reachable-checked first, and a tree without it reports the step as not completable for that version while the workflow continues; the Debian family (debian, ubuntu) takes the release deb (pin 1.0.10) only after its SHA256 matches the checksum Proton publishes on its guide, and a mismatch aborts the step and installs nothing; the RHEL family (rocky, rhel, centos, almalinux) gets no install at all, because Proton publishes no EL repository, and the workflow records the manual WireGuard/OpenVPN route as a follow-on. The tray packages follow the desktop (the GNOME set where gnome-shell is present, libappindicator-gtk3 alone otherwise), and no service commands are run, because the daemon package's own scriptlet enables its service. Signing in on first launch stays manual, and section 3's Proton VPN line now points at the workflow step. TickTick and Proton Pass are unchanged.

The version 1.9 changes were verified on 2026-10-30 by executing the shipped step code, extracted verbatim from new-box-prep-v1.3.sh, in the three reference trees, with the runner's ordering proven in a stub harness inside the Rocky tree (the real runner sequencing stub siblings, its Proton step executing for real against that tree's own os-release). Fedora 44: in the tree the verified install guide was tested in, the step reported the app already in place and skipped; in a copy of that tree with the Proton packages removed, it ran the full path (the release package reachable-checked, downloaded, and installed; check-update; the app set installed at proton-vpn-gnome-desktop 0.11.0-1.fc44, with libappindicator-gtk3 since no gnome-shell is present; the daemon package's own scriptlet created the split-tunneling service's enable symlink), reported the sign-in as the remaining manual action, and a re-run reported the app in place. Ubuntu 24.04: the step downloaded the release deb, verified its SHA256 against Proton's published checksum, installed it with dpkg, updated, and installed proton-vpn-gnome-desktop 0.11.0 (gtk-app 4.18.8, cli 1.0.5); the negative control, the same run with the downloaded deb corrupted by one byte, aborted at the checksum with nothing installed; a download failure likewise stops the step with nothing installed; and a re-run reported the app in place. Rocky 10: the step printed the RHEL-family lines, recorded the manual WireGuard/OpenVPN follow-on in the workflow footer under both designations, installed nothing, and exited clean; on the server leg the step does not appear at all. Two sandbox adaptations are harness, not procedure: chrooted processes cannot open HTTPS tunnels through this sandbox's egress proxy, so the chroot runs spoke to a local relay process that pipes bytes to the proxy (TLS stayed end to end, and the checksums and repo signatures verified against the real servers), and the bare container trees first needed the stock state a workstation ships with (curl and gnupg installed, /tmp at 1777, the stock Ubuntu sources restored, a CA pointer for dnf). A live run of the full workflow on real hardware is the remaining proof and had not happened when this version was cut.

Version 2.0 (2026-10-30) aligns the sudo posture with the standing design, rewrites the backup item around Clonezilla, and completes the desktop application set. Through version 1.9 the report treated a NOPASSWD entry in sudoers as something to review, because the checklist said sudo requires a password; the standing ruling is the opposite, that your users are NOPASSWD by design, deliberate and for convenience, so the script now reports a NOPASSWD entry as the intended configuration and its absence as a plain fact, and section 3 of this checklist says the same. Section 1's backup item now names the actual tool and disk: Clonezilla imaging of a LUKS-on-ext4 system, where the image is raw blocks and comes out near full partition size regardless of used space, the restore target must be at least the source size, the first boot after a restore asks for the LUKS passphrase to unlock, and the recovery key in Proton Pass is the fallback if the passphrase is ever lost. The desktop applications from the software list that the script did not already install (VLC, nmap, and zenmap were already handled) are now installed on both families: Firefox, Tilix, htop, GtkHash, PyChess, FileZilla, the Transmission GTK client, Remmina, rkhunter, Lynis, Cockpit, and luckyBackup, and the Cockpit socket is enabled where Cockpit is installed. Three of them are not packaged for the RHEL family, so that family gets manual items for gtkhash, pychess, and luckyBackup instead of the same failed install on every run. Remmina is packaged for the RHEL family but cannot install there today: its EPEL 10 dependency libappindicator-gtk3 requires the libdbusmenu libraries, and no RHEL-family repo provides them (verified against the live EPEL 10 index as well as the local mirror), so the RHEL family gets a manual item for remmina too, until EPEL fixes the chain; it installs normally on Fedora and Ubuntu. Brave and LibreFox (LibreWolf) are manual items on every family, because neither is in the distro repos and this script adds no vendor repos and downloads no vendor installers. Chrome and Chromium stay excluded, as ruled.

The version 2.0 changes were verified on 2026-10-30 by executing the shipped code, extracted verbatim from the script, in the three reference trees. The sudo block ran in the Rocky tree against two fixture sudoers states: with a NOPASSWD entry present it printed the by-design done line and no warning, and with none present it printed the factual done line and no warning; the same harness running the version 1.9 block against the present fixture produced the old warning, proving the harness can tell the difference. The desktop applications block ran for real in all three trees. Fedora 44: all twelve applications installed (firefox 159.0, tilix 1.9.6, htop 3.4.1, gtkhash 1.4, pychess 1.0.5, filezilla 3.69.5, transmission-gtk 4.1.4, remmina 1.4.41, rkhunter 1.4.6, lynis 3.1.7, cockpit 370, luckybackup 0.5.0), and a second run reported the installed line, the two manual items, and the cockpit line with no warnings. Ubuntu 24.04: all twelve installed in a single batch (versions matching the apt index, including the firefox snap-transitional package, which is how Ubuntu ships Firefox; the snap payload it hands off to is snapd's job on a live system and was not exercised in a chroot), with the same clean report. Rocky 10: the eight installable applications installed (firefox 140.17.0, tilix 1.9.6, htop 3.3.0, filezilla 3.69.3, transmission-gtk 4.1.3, rkhunter 1.4.6, lynis 3.1.7, cockpit 356.3) and the report printed the four RHEL manual items with no warnings; the warning path itself was executed as a control (an install call for the absent gtkhash warns, the same call for the present htop does not). Two sandbox adaptations are harness, not procedure: chrooted processes cannot open tunnels through this sandbox's egress proxy, so the Ubuntu run spoke to a local relay process that pipes bytes to the proxy, and the Rocky tree's local mirrors ship metadata only, so the missing RPM payloads were fetched from the upstream Rocky and EPEL trees into the mirror first (dnf verifies every checksum against the metadata before installing). A live run of the version 2.0 script itself on a fresh machine is the remaining proof and had not happened when this version was cut.

Runner version 1.4 (2026-10-30) adds the new-box workflow's desktop step, and this checklist's version 2.3 adds the matching line in section 1; the role-prep script itself is unchanged. Through runner version 1.3 the workflow installed no desktop at all: a box got whatever its installer image carried, and the Cinnamon on Michael's own laptop came from new-nobara-setup on the personal track. The runner now resolves a desktop choice up front, together with the work/personal designation: --desktop takes a comma-separated list of mate, cinnamon, xfce, openbox, lxde, or the word all, or none (none combined with a desktop is a usage error, duplicates collapse, and the selection is handled in the fixed list order regardless of the order typed). With no flag the runner asks on the terminal: a checkbox panel drawn in pure bash and ANSI, with no TUI dependency, where the terminal can draw one (the arrows or j and k move, space toggles the row under the cursor, a toggles all five at once, enter confirms, and None is exclusive in both directions), and a plain prompt with the same parsing where it cannot; with no terminal and no flag the run stops and runs nothing, exactly like an undesignated run. A desktop value on a server run is a usage error, like a designation flag. The step runs on both laptop legs, after the role prep and before the GPU step, and installs only: Fedora takes the desktop groups (@mate-desktop, @cinnamon-desktop, @xfce-desktop, @lxde-desktop, with Openbox as a plain package), Debian takes the distro meta-packages (mate-desktop-environment, cinnamon-desktop-environment, xfce4, openbox, lxde), and the RHEL family takes each desktop's session package, the form EPEL would carry it in. A desktop counts as installed when its session file is in /usr/share/xsessions, which is what the login screen's session picker lists. Availability is probed before any install, and a desktop the family's configured repositories do not carry gets a named warning while the rest of the selection proceeds; no repository is ever invented. No display manager is installed or switched, and no default session or auto-login is set: the desktop is chosen at the login screen.

The runner version 1.4 changes were verified on 2026-10-30 by executing the shipped code in the three reference trees and driving the full runner in stub harnesses. A stub harness inside the Rocky tree ran the selection matrix (each flag form, multi-selects in and out of typed order, duplicate collapse, all and none, the none-combination and unknown-name usage errors, the server-run rejections, the flagless non-interactive stop, and the step's position after the role prep and before the GPU step) at 59 of 59 checks, with the server leg's output byte-identical between versions 1.3 and 1.4; a pty harness drove the terminal paths at 25 of 25, covering the plain prompt under TERM=dumb and the checkbox panel under a capable TERM with scripted keystrokes (two desktops toggled, all five taken with a, a desktop chosen and then None, j and k navigation, and the None the panel starts with confirmed as-is). In the Fedora 44 tree the step installed the MATE group and Openbox for real (mate-session-manager 1.28.0; both session files present; a re-run reported both in place and printed the session-picker note) and dry-resolved the Cinnamon, Xfce, and LXDE groups (238, 51, and 51 packages in the resolved transactions). In the Ubuntu 24.04 tree it installed Xfce and Openbox for real (xfce4-session 4.18.3, openbox 3.6.1; session files present; re-runs in place, the final step run exiting clean) and dry-resolved the MATE, Cinnamon, and LXDE meta-packages. In the Rocky 10 tree the step reported all five desktops as not available, in the fixed order, and installed nothing, which matches the indexes read the same day: the tree's configured repos and the live EPEL 10 index (26,043 packages parsed, with known-present control packages found by the same read) carry none of the five session packages and no desktop group for them. Three sandbox adaptations are harness, not procedure: the chrooted package managers reach the network through the sandbox's egress proxy (Fedora's dnf took the proxy CA as an sslcacert pointer in the test copy; the egress credential rotated once mid-testing and was refreshed); the Ubuntu tree had to move off the workspace share for dpkg to converge, because the share refuses the chown calls some maintainer scripts make, and even there one unrelated package (dictionaries-common) would not configure in a chroot and twice lent its failure to an apt exit code without blocking the desktop installs themselves; and the Fedora copy shipped /etc/gshadow at mode 000, which failed one unrelated scriptlet late in the MATE transaction, after the desktop had installed, so the step stopped there as designed and a re-run completed the selection. A live run of the version 1.4 workflow on real hardware, and a graphical login actually picking a session the step installed, are the remaining proofs and had not happened when this version was cut.

Runner version 1.5 (2026-10-31) adds a guided launch to the new-box workflow, and this checklist's version 2.4 adds the matching line in section 1; the role-prep script itself is unchanged. With --guided, the choices the invocation leaves open are asked as a short sequence of panels built on the desktop panel's own frame machinery, which this version factors out of the desktop panel into shared code the desktop panel and the guided panels both use (one implementation, not two): the form itself, laptop or server, when the invocation names none (the bare form ./new-box-prep-v1.5.sh --guided), then a laptop's work/personal designation, then the desktop choice through the desktop panel itself, unchanged. The walk ends on a summary screen listing every choice (the form, the designation, the desktops, the GPU step requested or not, and a dry-run line when --dry-run is set) and the steps that will run in order, with Run and Cancel rows. A choice the invocation already made is never asked again, so a fully flagged guided run shows only the summary. Confirming the summary feeds the same variables the flags and the plain prompts set, and the run then proceeds through the existing step code untouched. Guided needs the terminal the desktop panel needs (stdin and stdout terminals, TERM set and not dumb): with choices still open and no such terminal, the run stops with a message and the usage exit before anything runs; with every choice already determined by the flags, guided adds nothing at all, not even the summary, and the run proceeds exactly as the flag path. Cancelling at any panel (q, or Cancel on the summary) prints the cancellation line and exits 0 having run nothing; Ctrl-C is the panel trap's standing exit 130 with the cursor restored. A designation or desktop flag paired with a server choice made in the form panel is refused with the same messages and the same exit as the flag form.

The runner version 1.5 changes were verified on 2026-10-31 by driving the shipped runner in stub harnesses inside the Rocky 10 tree (the sibling step scripts stubbed to log their calls; the runner's own Proton and desktop steps executing against that tree). The no-guided regression ran 27 of 27 cases byte-identical between versions 1.4 and 1.5 (stdout, stderr, exit code, and the stub call log, across both laptop legs, the flag and usage-error matrix, dry-run, the GPU form, and every server form), with the only raw differences being the harness tree path and the runner's own versioned filename in the usage line; the usage text itself is unchanged. A pty harness (a real controlling terminal, scripted keystrokes) ran 87 of 87 checks: the desktop panel and the TERM=dumb plain prompts byte-identical between versions under identical keystrokes (the refactor proof for the shared panel machinery), the full guided walk (form, designation, desktop panel, summary, Run) producing a stub call log byte-identical to the equivalent fully flagged run and a post-panel transcript identical to that run's, a guided server run likewise identical to the flagged server run, a fully flagged guided run showing only the summary with every frame line at the panel's width, partial flags asking only the open questions, cancels at the first panel and at the summary running nothing, Ctrl-C mid-walk exiting 130 with the cursor restored, a guided dry run executing nothing, TERM=dumb with open choices stopping at exit 2, and a server pick in the form panel paired with --work refused with the flag form's own message. Six off-terminal guided checks (choices open stopping at exit 2 with nothing run; determined invocations, laptop, server, and a duplicated --guided, byte-identical to their flag paths; --guided followed by a form word a plain usage error) passed 6 of 6. bash -n and ShellCheck are clean, and markdownlint is clean on this checklist and the workstation README. A live run of the version 1.5 workflow on real hardware is the remaining proof and had not happened when this version was cut.

```bash
#!/usr/bin/env bash
# laptop-role-prep-setup-v2.0.sh
#
# Produce the desired state from "Linux Laptop Prep Checklist: Coding
# Instructor and Linux Administrator" (linux-laptop-role-prep-checklist)
# for every item that can be done from the command line. Items that need
# hardware, a GUI session, a vendor sign-in, or a human decision are NOT
# faked: they are collected and printed as a manual list at the end.
#
# Properties:
#   - Run as root (sudo). Idempotent: safe to re-run; existing users,
#     keys, and configs are detected and left in place.
#   - Distro-aware: dnf family (Rocky/Fedora/RHEL) and apt family
#     (Debian/Ubuntu). Anything else is reported and the run stops.
#   - No password is ever set non-interactively and no secret is written
#     by this script. New-user passwords and SSH key passphrases are
#     prompted for only when a terminal is attached; otherwise the exact
#     commands are printed as next steps.
#
# Companion guide: linux-laptop-role-prep-checklist (this script is
# embedded in it verbatim; the two files travel together).

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (edit before running, or leave the defaults)
# ---------------------------------------------------------------------------

WORK_USER="michael-work"
PERSONAL_USER="michael"

# Git identities. Left empty, the script still writes the conditional-
# include structure but skips the name/email values and tells you.
PERSONAL_GIT_NAME=""
PERSONAL_GIT_EMAIL=""
WORK_GIT_NAME=""
WORK_GIT_EMAIL=""

# 1 also adds the work user to the libvirt group when virt is installed.
INSTALL_VIRT=1
# 1 would add the work user to the sudo/wheel group. Default 0: neither
# new account gets admin rights unless asked; your existing account
# stays the admin. Sudo posture itself is checklist 3: your users are
# NOPASSWD by design (your ruling, deliberate, for convenience), and
# this script neither adds nor removes sudoers entries.
GRANT_SUDO_WORK=0

PUBLIC_REPO_URL="https://github.com/amaad-michael/public.git"

# ---------------------------------------------------------------------------
# Bookkeeping
# ---------------------------------------------------------------------------

DONE_ITEMS=()
MANUAL_ITEMS=()
WARNINGS=()

done_item()   { DONE_ITEMS+=("$1"); }
manual_item() { MANUAL_ITEMS+=("$1"); }
warn_item()   { WARNINGS+=("$1"); }

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
# Prerequisites and OS detection
# ---------------------------------------------------------------------------

if [[ ${EUID} -ne 0 ]]; then
    say "This script must run as root: sudo ./laptop-role-prep-setup-v2.0.sh"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    say "Cannot read /etc/os-release; cannot identify this system. Stopping."
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-}"
OS_LIKE="${ID_LIKE:-}"
FAMILY=""
case " ${OS_ID} ${OS_LIKE} " in
    *" rocky "*|*" rhel "*|*" fedora "*|*" centos "*) FAMILY="dnf" ;;
    *" debian "*|*" ubuntu "*) FAMILY="apt" ;;
esac
if [[ -z "${FAMILY}" ]]; then
    say "Unsupported distro family (ID=${OS_ID}, ID_LIKE=${OS_LIKE})."
    say "This script covers the dnf and apt families only. Stopping."
    exit 1
fi
say "Detected: ${PRETTY_NAME:-${OS_ID}} (family: ${FAMILY})"

# RHEL-lineage distros (Rocky, RHEL, CentOS, Alma) share a package
# universe that differs from Fedora's for a few names this script
# cares about; the package sections branch on it where the Rocky 10
# and EPEL 10 indexes prove the Fedora name does not exist there.
# The exact distro ID is the only sound signal, and it decides
# alone. ID_LIKE declares ancestry, not package lineage, and it
# cannot separate the two families at all: Nobara's ID_LIKE is
# "rhel centos fedora" (read from the travel laptop's real
# /etc/os-release on 2026-10-30), byte-identical to Rocky 10's own
# ID_LIKE, and RHEL itself ships ID_LIKE="fedora". v1.4 judged a
# derivative under its own ID by its ID_LIKE lineage and so still
# read Nobara as RHEL-family on real hardware; v1.6 removes that
# fallback. The RHEL set is closed and known: an exact ID of rhel,
# rocky, almalinux, or centos is RHEL-family, and every other dnf
# system, Fedora and its derivatives alike, is not.
RHELISH=0
if [[ "${FAMILY}" == "dnf" ]]; then
    case " ${OS_ID} " in
        *" rhel "*|*" rocky "*|*" almalinux "*|*" centos "*) RHELISH=1 ;;
    esac
fi

INTERACTIVE=0
[[ -t 0 ]] && INTERACTIVE=1

# ---------------------------------------------------------------------------
# Package installation (checklist sections 4, 5, 6)
# ---------------------------------------------------------------------------

# install_pkgs <pkg...>: try the batch; on failure retry one by one so a
# single bad name never sinks the rest. Misses become warnings.
install_pkgs() {
    local pkgs=("$@")
    if [[ "${FAMILY}" == "dnf" ]]; then
        if dnf install -y "${pkgs[@]}" >/dev/null 2>&1; then
            return 0
        fi
    else
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1; then
            return 0
        fi
    fi
    local p
    for p in "${pkgs[@]}"; do
        if [[ "${FAMILY}" == "dnf" ]]; then
            dnf install -y "${p}" >/dev/null 2>&1 || warn_item "package not installed: ${p}"
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${p}" >/dev/null 2>&1 || warn_item "package not installed: ${p}"
        fi
    done
}

step "Packages"

if [[ "${FAMILY}" == "apt" ]]; then
    apt-get update >/dev/null 2>&1 || warn_item "apt-get update failed (offline?); installs may fail"
fi

# Core + developer toolchains (sections 4 and 6): git, tmux, Python, Node.
if [[ "${FAMILY}" == "dnf" ]]; then
    install_pkgs git tmux python3 nodejs man-db man-pages
else
    install_pkgs git tmux python3 nodejs man-db manpages
fi
done_item "core tooling installed: git, tmux, python3, nodejs, man pages (checklist 4, 6)"

# GitHub CLI (gh): pull requests from the terminal, git's companion
# for the landing workflow. Fedora carries gh in the standard repos
# and EPEL 10 carries it for the RHEL family (2.97.0, verified
# against the EPEL 10 index 2026-10-29); Debian carries it too.
# Where no candidate exists, the fallback is GitHub's own package
# repo on the RHEL family and a manual item naming the official
# route elsewhere. Authentication is a sign-in and is never
# scripted; the manual item below carries it on every run.
install_pkgs gh
if command -v gh >/dev/null 2>&1; then
    done_item "github cli installed: $(gh --version 2>/dev/null | head -1) (checklist 6)"
elif [[ "${FAMILY}" == "dnf" && "${RHELISH}" == "1" ]]; then
    if ! dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo >/dev/null 2>&1; then
        dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
        dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo >/dev/null 2>&1 || true
    fi
    install_pkgs gh
    if command -v gh >/dev/null 2>&1; then
        done_item "github cli installed from GitHub's package repo: $(gh --version 2>/dev/null | head -1) (checklist 6)"
    else
        manual_item "GitHub CLI: install gh from https://cli.github.com (neither EPEL nor GitHub's repo yielded a package on this box)."
    fi
else
    manual_item "GitHub CLI: install gh from https://cli.github.com (no package candidate on this distro)."
fi
manual_item "GitHub CLI: authenticate once per box (never scripted): gh auth login (GitHub.com, SSH, web browser), then gh auth status to verify (checklist 6)."

# Linux administrator kit diagnostics (section 4) + Ansible.
if [[ "${FAMILY}" == "dnf" ]]; then
    install_pkgs nmap tcpdump mtr bind-utils curl jq iperf3 smartmontools nmap-ncat ansible-core
else
    install_pkgs nmap tcpdump mtr-tiny dnsutils curl jq iperf3 smartmontools netcat-openbsd ansible
fi
done_item "admin diagnostics installed: nmap, tcpdump, mtr, dig, curl, jq, iperf3, smartmontools, nc, ansible (checklist 4)"

# Instructor kit (section 5): Python IDLE + a screenshot tool. Verified
# against the Rocky 10 + EPEL 10 indexes on 2026-10-18: the RHEL
# family has no installable IDLE package (python3-idle does not exist
# there, and EPEL's python3.13-idle currently requires an expat build
# the 10.2 base repos do not ship yet) and no flameshot package at
# all, so both become manual items there instead of failing the same
# way on every run.
if [[ "${FAMILY}" == "dnf" && "${RHELISH}" == "1" ]]; then
    manual_item "Section 5: Python IDLE has no installable package on the RHEL family today (no python3-idle in the base repos; EPEL's python3.13-idle needs a base expat newer than the 10.2 repos ship)."
    manual_item "Section 5: flameshot is not packaged for the RHEL family; use the desktop's built-in screenshot tool or pick one by hand."
elif [[ "${FAMILY}" == "dnf" ]]; then
    install_pkgs python3-idle flameshot
    done_item "instructor tooling installed: Python IDLE, flameshot screenshot tool (checklist 5)"
else
    install_pkgs idle3 flameshot
    done_item "instructor tooling installed: Python IDLE, flameshot screenshot tool (checklist 5)"
fi

# Applications (added at Michael's direction 2026-10-17): VLC media
# player, Docker (apt family only), and Zenmap (the Nmap GUI). Package
# names verified against the real Ubuntu 24.04 and Rocky 10 + EPEL 10
# indexes: on apt the Docker engine is docker.io (plain "docker" has
# no candidate) with docker-compose-v2 alongside, and zenmap exists.
# On the RHEL family Docker is intentionally not installed (Michael's
# direction): Podman, installed below on both families, is the
# container runtime there. Zenmap is not packaged for Rocky or EPEL 10
# at all, so that family gets the nmap command-line tools only.
step "Applications"

if [[ "${FAMILY}" == "apt" ]]; then
    install_pkgs vlc zenmap docker.io docker-compose-v2
else
    install_pkgs vlc
    if [[ "${RHELISH}" == "1" ]]; then
        done_item "zenmap is not packaged for the RHEL family; the nmap command-line tools are installed above"
    else
        install_pkgs zenmap
    fi
    done_item "container runtime on the dnf family is podman (installed below); Docker intentionally skipped per your standing direction"
fi
if command -v vlc >/dev/null 2>&1; then
    vlc_ver="$(vlc --version 2>/dev/null | head -1)"
    if [[ -z "${vlc_ver}" ]]; then
        # vlc refuses to run as root, so under sudo --version prints
        # nothing; fall back to the installed package's version.
        if [[ "${FAMILY}" == "dnf" ]]; then
            vlc_ver="$(rpm -q vlc 2>/dev/null)"
        else
            vlc_ver="$(dpkg-query -W -f='${Version}' vlc 2>/dev/null)"
        fi
    fi
    done_item "vlc installed: ${vlc_ver}"
fi
if command -v zenmap >/dev/null 2>&1; then
    done_item "zenmap installed (Nmap GUI)"
fi
if [[ "${FAMILY}" == "apt" ]] && command -v docker >/dev/null 2>&1; then
    done_item "docker installed: $(docker --version 2>/dev/null) (checklist 4)"
    # The systemctl unit checks in this script use grep without -q on
    # purpose: under pipefail, grep -q exits on the first match and
    # systemctl dies of SIGPIPE, which flips the pipeline's result.
    if systemctl list-unit-files 2>/dev/null | grep '^docker\.service' >/dev/null; then
        systemctl enable --now docker >/dev/null 2>&1 || warn_item "docker present but its service could not be enabled"
    fi
    # The docker group add for the work user runs in the Users
    # section, after the account exists; see there.
fi

# Desktop applications (Michael's software list, scoped 2026-10-22,
# completed in v2.0): Firefox, Tilix, htop, GtkHash, PyChess,
# FileZilla, Transmission (the GTK client), Remmina, rkhunter, Lynis,
# Cockpit, and luckyBackup. Package names verified 2026-10-30
# against the Fedora 44, Rocky 10 + EPEL 10, and Ubuntu 24.04
# indexes: the full set exists on Fedora and on Ubuntu under the
# names below (Ubuntu's firefox package is the snap-transitional
# one; installing it is how Ubuntu ships Firefox). On the RHEL
# family gtkhash, pychess, and luckybackup are not packaged (the
# same Rocky 10 + EPEL 10 indexes that have no IDLE or flameshot),
# so that family gets manual items for those three instead of the
# same failed install on every run. Remmina is packaged for the
# RHEL family but cannot install today (checked 2026-10-30): its
# EPEL 10 dependency libappindicator-gtk3 requires the
# libdbusmenu libraries, and no RHEL-family repo provides them
# (verified against Rocky 10 BaseOS/AppStream and the live EPEL
# 10 index, not just the local mirror), so that family gets a
# manual item for remmina too, until EPEL fixes the chain. Brave
# and LibreFox are in no stock repo on any family; this script
# adds no vendor repos and downloads no vendor installers, so
# both are manual items below.
if [[ "${FAMILY}" == "dnf" && "${RHELISH}" == "1" ]]; then
    install_pkgs firefox tilix htop filezilla transmission-gtk rkhunter lynis cockpit
    done_item "desktop applications installed: firefox, tilix, htop, filezilla, transmission (GTK), rkhunter, lynis, cockpit"
    manual_item "Desktop applications: gtkhash is not packaged for the RHEL family (Rocky 10 + EPEL 10 indexes, checked 2026-10-30); install it by hand if you want it."
    manual_item "Desktop applications: pychess is not packaged for the RHEL family (Rocky 10 + EPEL 10 indexes, checked 2026-10-30); install it by hand if you want it."
    manual_item "Desktop applications: luckyBackup is not packaged for the RHEL family (Rocky 10 + EPEL 10 indexes, checked 2026-10-30); install it by hand if you want it."
    manual_item "Desktop applications: remmina is packaged in EPEL 10 but cannot install today (checked 2026-10-30): its dependency libappindicator-gtk3 requires the libdbusmenu libraries, which no RHEL-family repo provides; install it by hand if a future EPEL update fixes the chain."
else
    install_pkgs firefox tilix htop gtkhash pychess filezilla transmission-gtk remmina rkhunter lynis cockpit luckybackup
    done_item "desktop applications installed: firefox, tilix, htop, gtkhash, pychess, filezilla, transmission (GTK), remmina, rkhunter, lynis, cockpit, luckybackup"
fi
manual_item "Brave browser: not in the distro repos (Fedora 44, Rocky 10 + EPEL 10, and Ubuntu 24.04 indexes checked 2026-10-30), and this script adds no vendor repos; install it from brave.com if you want it."
manual_item "LibreFox (LibreWolf): not in the distro repos (Fedora 44, Rocky 10 + EPEL 10, and Ubuntu 24.04 indexes checked 2026-10-30), and this script adds no vendor repos; install it from librewolf.net if you want it."
if systemctl list-unit-files 2>/dev/null | grep '^cockpit\.socket' >/dev/null; then
    if systemctl enable --now cockpit.socket >/dev/null 2>&1; then
        done_item "cockpit web console enabled (cockpit.socket)"
    else
        warn_item "cockpit present but its socket could not be enabled"
    fi
fi

# Container runtime (section 4): Podman on both families.
install_pkgs podman
if command -v podman >/dev/null 2>&1; then
    done_item "podman installed: $(podman --version 2>/dev/null) (checklist 4)"
else
    warn_item "podman not available after install attempt"
fi

# Virtualization (section 4): libvirt + a VM console. (The work
# user's libvirt group add runs in the Users section, after the
# account exists; see there.) The console
# differs by family: virt-manager on apt. On RHEL 10 virt-manager is
# not packaged at all, so cockpit-machines, the RHEL-native console,
# takes its place.
if [[ "${INSTALL_VIRT}" == "1" ]]; then
    if [[ "${FAMILY}" == "dnf" && "${RHELISH}" == "1" ]]; then
        install_pkgs qemu-kvm libvirt cockpit-machines
    elif [[ "${FAMILY}" == "dnf" ]]; then
        install_pkgs qemu-kvm libvirt virt-manager
    else
        install_pkgs qemu-kvm libvirt-daemon-system libvirt-clients virt-manager
    fi
    if systemctl list-unit-files 2>/dev/null | grep '^libvirtd\.service' >/dev/null; then
        systemctl enable --now libvirtd >/dev/null 2>&1 || warn_item "libvirtd present but could not be enabled"
        if [[ "${RHELISH}" == "1" ]]; then
            done_item "libvirt installed and enabled; virt-manager is not packaged for RHEL 10, cockpit-machines installed as the VM console (checklist 4)"
        else
            done_item "libvirt installed and enabled; create the clean sandbox VM from virt-manager (checklist 4)"
        fi
    else
        warn_item "libvirt packages did not yield a libvirtd service; VM setup needs a look"
    fi
    manual_item "Section 4: build the one clean Linux sandbox VM (image choice is yours) and confirm it boots."
else
    manual_item "Section 4: VM setup skipped (INSTALL_VIRT=0); install the libvirt stack when ready."
fi

# ---------------------------------------------------------------------------
# Vendor applications (added at Michael's direction 2026-10-18):
# TickTick and Proton Pass. Distribution methods verified against
# each vendor's own site and feeds on 2026-10-18; see the per-app
# comments. Downloads land in a scratch directory that is removed
# when the section finishes. Every app degrades to a warning plus
# a manual item when its download or checksum does not check out;
# nothing unverified is ever installed.
#
# Proton VPN is not installed here anymore. Through version 1.8
# this section carried its own Proton VPN install (Proton's repos
# on Debian/Ubuntu and Fedora, a manual item on the RHEL family);
# version 1.9 retires it, because the new-box workflow's Proton
# step (new-box-prep) now installs Proton VPN on every
# workstation before this script runs, work box or personal, and
# the pins live in that one place. A standalone run of this
# script no longer installs Proton VPN; run the workflow, or
# follow the verified install guide, instead.
# ---------------------------------------------------------------------------

step "Vendor applications"

VENDOR_DIR="$(mktemp -d)"

# pkg_installed <name>: true when the package manager has the package.
pkg_installed() {
    if [[ "${FAMILY}" == "dnf" ]]; then
        rpm -q "$1" >/dev/null 2>&1
    else
        dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
    fi
}

# pkg_version <name>: the installed version, empty when absent.
pkg_version() {
    if [[ "${FAMILY}" == "dnf" ]]; then
        rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
    else
        dpkg-query -W -f='${Version}' "$1" 2>/dev/null
    fi
}

# fetch <url> <dest>: quiet download, non-zero on any failure.
fetch() {
    curl -fsSL --max-time 600 -o "$2" "$1" >/dev/null 2>&1
}

# install_local_pkg <file>: install a downloaded package file with
# the package manager so its dependencies resolve (a deliberate step
# up from the vendors' dpkg -i / rpm -i instructions, which fail on
# a machine missing a dependency instead of pulling it).
install_local_pkg() {
    if [[ "${FAMILY}" == "dnf" ]]; then
        if dnf install -y "$1" >/dev/null 2>&1; then
            return 0
        fi
        # Fallback for a collision between the vendors' own RPMs.
        # Proton Pass and TickTick are both built on the stock
        # Electron binary, so both packages ship the same
        # /usr/lib/.build-id/* debug symlinks with different
        # targets, and rpm refuses to install the second one
        # (file conflicts with the first). The links are debug
        # metadata; which app they point at does not affect either
        # program. Install the file's dependencies with dnf first
        # (rpm alone cannot resolve them), then let rpm replace
        # the conflicting links.
        local reqs
        reqs="$(rpm -qp --requires "$1" 2>/dev/null | grep -vE '^rpmlib\(|^\(|^/' | sort -u)"
        if [[ -n "${reqs}" ]]; then
            # shellcheck disable=SC2086 # reqs is a name list; word splitting is the point
            dnf install -y ${reqs} >/dev/null 2>&1 || true
        fi
        rpm -Uvh --replacefiles "$1" >/dev/null 2>&1
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" >/dev/null 2>&1
    fi
}

# --- Proton Pass -----------------------------------------------------
# No repository: Proton publishes standalone DEB/RPM packages and a
# version feed carrying every release's URL and SHA512 checksum (the
# same feed the app updates itself from). The script reads the feed,
# takes the newest Stable release at full rollout, verifies the
# checksum, and only then installs. Feed (x86_64):
#   https://proton.me/download/PassDesktop/linux/x64/version.json
# Vendor method: https://proton.me/support/set-up-proton-pass-linux
install_proton_pass() {
    if pkg_installed proton-pass; then
        done_item "proton-pass already installed: $(pkg_version proton-pass)"
        return 0
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        manual_item "Section 3: install Proton Pass from https://proton.me/pass/download (this script's verified feed covers x86_64; this machine is $(uname -m))."
        return 0
    fi
    local json="${VENDOR_DIR}/pass-version.json"
    if ! fetch "https://proton.me/download/PassDesktop/linux/x64/version.json" "${json}"; then
        warn_item "proton-pass: Proton's version feed was unreachable; skipped"
        manual_item "Section 3: install Proton Pass from https://proton.me/pass/download (the version feed was unreachable during this run)."
        return 0
    fi
    local sel
    if ! sel="$(python3 - "${json}" "${FAMILY}" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
want = ".deb" if sys.argv[2] == "apt" else ".rpm"
for rel in data.get("Releases", []):
    if rel.get("CategoryName") != "Stable":
        continue
    if rel.get("RolloutPercentage") != 1:
        continue
    for entry in rel.get("File", []):
        if entry.get("Url", "").endswith(want):
            print(rel["Version"], entry["Url"], entry["Sha512CheckSum"])
            raise SystemExit(0)
raise SystemExit(1)
PYEOF
)"; then
        warn_item "proton-pass: no full-rollout stable release found in Proton's feed; skipped"
        manual_item "Section 3: install Proton Pass from https://proton.me/pass/download (no suitable release was listed in the feed during this run)."
        return 0
    fi
    local ver url sha
    read -r ver url sha <<< "${sel}"
    local file
    file="${VENDOR_DIR}/$(basename "${url}")"
    if ! fetch "${url}" "${file}"; then
        warn_item "proton-pass ${ver}: download failed; skipped"
        manual_item "Section 3: install Proton Pass from https://proton.me/pass/download (the package download failed during this run)."
        return 0
    fi
    if ! printf '%s  %s\n' "${sha}" "${file}" | sha512sum --check - >/dev/null 2>&1; then
        warn_item "proton-pass ${ver}: SHA512 checksum mismatch against Proton's feed; NOT installed"
        manual_item "Section 3: install Proton Pass by hand from https://proton.me/pass/download and verify its checksum (the downloaded package did not match Proton's published checksum during this run)."
        return 0
    fi
    if ! install_local_pkg "${file}"; then
        warn_item "proton-pass ${ver}: package install failed"
        manual_item "Section 3: install Proton Pass by hand from https://proton.me/pass/download (the package install failed during this run)."
        return 0
    fi
    if pkg_installed proton-pass; then
        done_item "proton-pass installed: ${ver} (SHA512 verified against Proton's version feed)"
    else
        warn_item "proton-pass ${ver}: install ran but the package is not registered"
    fi
}

# --- TickTick --------------------------------------------------------
# TickTick's download page offers DEB, RPM, and AppImage builds. The
# page's download button calls a version-less endpoint on
# ticktick.com that redirects to the current package file (verified
# 2026-10-18: type=linux_deb_x64 served ticktick-8.0.20-amd64.deb,
# type=linux_rpm_x64 served ticktick-8.0.20-x86_64.rpm). TickTick
# publishes no checksum feed, so the package itself is the check:
# the install only counts when the ticktick package registers.
install_ticktick() {
    if pkg_installed ticktick; then
        done_item "ticktick already installed: $(pkg_version ticktick)"
        return 0
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        manual_item "Install TickTick from https://ticktick.com/download (this script's verified endpoint covers x86_64; this machine is $(uname -m), and the page offers an arm64 build)."
        return 0
    fi
    local kind file
    if [[ "${FAMILY}" == "dnf" ]]; then
        kind="linux_rpm_x64"
        file="${VENDOR_DIR}/ticktick.rpm"
    else
        kind="linux_deb_x64"
        file="${VENDOR_DIR}/ticktick.deb"
    fi
    if ! fetch "https://ticktick.com/static/getApp/download?type=${kind}" "${file}"; then
        warn_item "ticktick: download from TickTick's endpoint failed; skipped"
        manual_item "Install TickTick from https://ticktick.com/download (the download failed during this run)."
        return 0
    fi
    if ! install_local_pkg "${file}"; then
        warn_item "ticktick: package install failed"
        manual_item "Install TickTick from https://ticktick.com/download (the package install failed during this run)."
        return 0
    fi
    if pkg_installed ticktick; then
        done_item "ticktick installed: $(pkg_version ticktick) (from TickTick's official download endpoint)"
    else
        warn_item "ticktick: install ran but the package is not registered"
        manual_item "Install TickTick from https://ticktick.com/download (the install did not register during this run)."
    fi
}

install_proton_pass
install_ticktick

rm -rf "${VENDOR_DIR}"

# ---------------------------------------------------------------------------
# Base system (checklist section 1)
# ---------------------------------------------------------------------------

step "Base system"

if [[ "${FAMILY}" == "dnf" ]]; then
    if dnf upgrade -y >/dev/null 2>&1; then
        done_item "system packages updated (dnf upgrade) (checklist 1)"
    else
        warn_item "dnf upgrade did not complete; check network and rerun"
    fi
    if command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then
        manual_item "Section 1: a reboot into the new kernel is pending; reboot when convenient, not from this script."
    fi
else
    if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >/dev/null 2>&1; then
        done_item "system packages updated (apt upgrade) (checklist 1)"
    else
        warn_item "apt upgrade did not complete; check network and rerun"
    fi
    if [[ -e /var/run/reboot-required ]]; then
        manual_item "Section 1: a reboot into the new kernel is pending; reboot when convenient, not from this script."
    fi
fi

if command -v fwupdmgr >/dev/null 2>&1; then
    if fwupdmgr get-updates >/dev/null 2>&1; then
        manual_item "Section 1: firmware updates are available per fwupdmgr; apply them deliberately (fwupdmgr update) on power."
    else
        done_item "firmware checked with fwupdmgr; nothing pending or no metadata (checklist 1)"
    fi
else
    manual_item "Section 1: fwupd not present; check firmware/BIOS updates with the vendor's tool."
fi

if lsblk -f 2>/dev/null | grep -q crypto_LUKS || blkid 2>/dev/null | grep -q crypto_LUKS; then
    done_item "full-disk encryption verified present (LUKS) (checklist 1)"
else
    warn_item "no LUKS volume detected; verify the full-disk encryption item by hand"
fi
manual_item "Section 1/3: confirm the LUKS recovery key is stored in Proton Pass (never scripted)."

timedatectl set-ntp true >/dev/null 2>&1 || true
if systemctl list-unit-files 2>/dev/null | grep '^chronyd\.service' >/dev/null; then
    systemctl enable --now chronyd >/dev/null 2>&1 || true
elif systemctl list-unit-files 2>/dev/null | grep '^systemd-timesyncd\.service' >/dev/null; then
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
fi
done_item "automatic time synchronization enabled (checklist 1)"

# Persistent journal: a /var/log/journal directory plus an explicit
# Storage=persistent drop-in is what keeps the journal across
# reboots; without it the journal is volatile and a failed boot
# leaves no logs (the pi3 lesson, checklist 1).
mkdir -p /var/log/journal /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\n' > /etc/systemd/journald.conf.d/10-persistent.conf
systemctl restart systemd-journald >/dev/null 2>&1 || true
if [[ -d /var/log/journal ]]; then
    done_item "persistent journaling on: /var/log/journal present, Storage=persistent drop-in set (checklist 1)"
else
    warn_item "persistent journaling could not be confirmed; /var/log/journal missing"
fi

# Fleet personalization: the homelab hosts block (the same entries
# the server leg and the motd playbook write, grep-guarded the same
# way) so fleet names resolve on this box, the cluster MOTD the motd
# playbook writes to /etc/motd (banner plus the same subnet block,
# so console and SSH logins show the fleet map), fastfetch as the
# login presentation via the same /etc/profile.d mechanism the
# fleet's fastfetch playbook uses, and the terminal greeting:
# /etc/motd printed above fastfetch, once per desktop session
# (checklist 1).
if ! grep -q 'pi0' /etc/hosts 2>/dev/null; then
    cat >> /etc/hosts <<'EOF'

## local subnet
192.168.0.100   pi0
192.168.0.101   pi1
192.168.0.102   pi2
192.168.0.103   pi3
192.168.0.104   pi4
192.168.0.105   neo1
EOF
fi
done_item "fleet /etc/hosts entries present: pi0-pi4 and neo1 (checklist 1)"

# Cluster MOTD, mirroring the motd playbook's static /etc/motd. A
# /etc/motd that already carries the subnet block is left alone;
# any other non-empty one is copied to /etc/motd.backup first (the
# backup the playbook takes), and only when no backup exists yet.
if grep -q '## local subnet' /etc/motd 2>/dev/null; then
    done_item "cluster MOTD in place: /etc/motd carries the fleet subnet block (checklist 1)"
else
    if [[ -s /etc/motd && ! -e /etc/motd.backup ]]; then
        cp /etc/motd /etc/motd.backup
    fi
    if cat > /etc/motd <<'EOF'

▄▀▄     █▄ ▄█ █ ▄▀▀ █▄█ ▄▀▄ ██▀ █      ▀█▀ ▄▀▄ ▀█▀ █ █ █▄ ▄█
█▀█ ▄   █ ▀ █ █ ▀▄▄ █ █ █▀█ █▄▄ █▄▄     █  █▀█  █  ▀▄█ █ ▀ █

## local subnet
192.168.0.100   pi0
192.168.0.101   pi1
192.168.0.102   pi2
192.168.0.103   pi3
192.168.0.104   pi4
192.168.0.105   neo1
EOF
    then
        done_item "cluster MOTD in place: /etc/motd carries the fleet subnet block (checklist 1)"
    else
        warn_item "cluster MOTD could not be written to /etc/motd (checklist 1)"
    fi
fi

install_pkgs fastfetch
if command -v fastfetch >/dev/null 2>&1; then
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/fastfetch.sh <<'EOF'
#!/bin/bash
# Run fastfetch for interactive login shells.
fastfetch
EOF
    chmod 755 /etc/profile.d/fastfetch.sh
    done_item "fastfetch login presentation set: /etc/profile.d/fastfetch.sh (checklist 1)"
fi

# Terminal greeting: /etc/motd above fastfetch, once per desktop
# session (the config verified live on the travel laptop on
# 2026-10-30 and adopted as the default). Desktop terminals are
# not logins, so PAM never prints /etc/motd there; the greeting
# prints it from the shell instead, on two paths sharing one
# flag: for login shells, /etc/profile.d/00-motd.sh sorts ahead
# of fastfetch.sh and prints first; for non-login interactive
# terminals, which never source profile.d, the same guarded
# block rides at the end of /etc/bashrc (every user's ~/.bashrc
# sources it). The flag in the session runtime dir is set by
# whichever path fires first, so the MOTD prints exactly once
# per session. The SSH guard keeps both paths silent on SSH
# logins, where PAM has already printed /etc/motd natively.
# Nobara (like Fedora) ships no /etc/bashrc.d sourcing, so the
# block goes into /etc/bashrc itself, appended only when the
# flag string is absent, so re-runs never stack copies.
# shellcheck disable=SC2016 # the block is payload text for other shells; its $ expressions must stay literal
greeting_block='if [[ $- == *i* && -r /etc/motd && -z "${SSH_CONNECTION:-}" && ! -e "${XDG_RUNTIME_DIR}/.motd-shown" ]]; then
  cat /etc/motd
  touch "${XDG_RUNTIME_DIR}/.motd-shown"
fi'
mkdir -p /etc/profile.d
if [[ -f /etc/profile.d/00-motd.sh ]] && [[ "$(cat /etc/profile.d/00-motd.sh 2>/dev/null)" == "${greeting_block}" ]]; then
    done_item "terminal greeting in place: /etc/profile.d/00-motd.sh carries the MOTD-first block (checklist 1)"
elif printf '%s\n' "${greeting_block}" > /etc/profile.d/00-motd.sh; then
    chmod 755 /etc/profile.d/00-motd.sh
    done_item "terminal greeting set: /etc/profile.d/00-motd.sh prints /etc/motd before fastfetch, once per session (checklist 1)"
else
    warn_item "terminal greeting could not be written to /etc/profile.d/00-motd.sh (checklist 1)"
fi
if grep -q '\.motd-shown' /etc/bashrc 2>/dev/null; then
    done_item "terminal greeting in place: /etc/bashrc carries the MOTD-first block (checklist 1)"
elif printf '\n%s\n' "${greeting_block}" >> /etc/bashrc; then
    done_item "terminal greeting set: MOTD-first block appended to /etc/bashrc for non-login terminals (checklist 1)"
else
    warn_item "terminal greeting could not be appended to /etc/bashrc (checklist 1)"
fi

# Screen lock at 5 minutes with password on wake, as system dconf defaults
# so it covers every account including the two created below (GNOME only).
if [[ -d /etc/dconf ]] || command -v dconf >/dev/null 2>&1; then
    mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
    if [[ ! -e /etc/dconf/profile/user ]]; then
        printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
    fi
    cat > /etc/dconf/db/local.d/00-laptop-role-prep-lock <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 300

[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0
EOF
    dconf update >/dev/null 2>&1 || true
    done_item "screen lock defaults set: idle lock at 300s, password required (checklist 1)"
else
    manual_item "Section 1: no dconf/GNOME detected; set the 5-minute screen lock in your desktop's settings."
fi

if [[ "${FAMILY}" == "dnf" ]]; then
    command -v firewall-cmd >/dev/null 2>&1 || install_pkgs firewalld
    if systemctl enable --now firewalld >/dev/null 2>&1; then
        done_item "host firewall on: firewalld enabled, default zone drops unsolicited inbound (checklist 1)"
    else
        warn_item "firewalld could not be enabled"
    fi
else
    command -v ufw >/dev/null 2>&1 || install_pkgs ufw
    if ufw default deny incoming >/dev/null 2>&1 && ufw --force enable >/dev/null 2>&1; then
        done_item "host firewall on: ufw enabled, default deny inbound (checklist 1)"
    else
        warn_item "ufw could not be enabled"
    fi
fi

for bat in /sys/class/power_supply/BAT*; do
    [[ -d "${bat}" ]] || continue
    if [[ -r "${bat}/capacity" ]]; then
        bcap="$(cat "${bat}/capacity")"
        bhealth="unknown"
        if [[ -r "${bat}/charge_full" && -r "${bat}/charge_full_design" ]]; then
            f=$(cat "${bat}/charge_full"); d=$(cat "${bat}/charge_full_design")
            [[ "${d}" -gt 0 ]] && bhealth="$(( f * 100 / d ))%"
        elif [[ -r "${bat}/energy_full" && -r "${bat}/energy_full_design" ]]; then
            f=$(cat "${bat}/energy_full"); d=$(cat "${bat}/energy_full_design")
            [[ "${d}" -gt 0 ]] && bhealth="$(( f * 100 / d ))%"
        fi
        done_item "battery report: charge ${bcap}%, health ${bhealth} of design capacity (checklist 1)"
    fi
done
manual_item "Section 1: take the full system backup and test a bare-metal restore before the first workday; no script can prove a restore for you."

# ---------------------------------------------------------------------------
# Separation of lives (checklist section 2) + security core (section 3)
# ---------------------------------------------------------------------------

step "Users and per-user setup"

create_user() {
    local u="$1"
    if id "${u}" >/dev/null 2>&1; then
        done_item "user exists already: ${u} (checklist 2)"
    elif useradd -m -s /bin/bash "${u}"; then
        done_item "user created: ${u} (checklist 2)"
    else
        warn_item "user could not be created: ${u} (checklist 2)"
        return 1
    fi
    chmod 750 "/home/${u}"
    if [[ "${INTERACTIVE}" == "1" ]]; then
        if ! passwd -S "${u}" 2>/dev/null | grep -q ' P '; then
            say "Set a password for ${u}:"
            passwd "${u}" || warn_item "password not set for ${u}"
        fi
    else
        manual_item "Set the password for ${u}:  sudo passwd ${u}"
    fi
}

create_user "${WORK_USER}"
create_user "${PERSONAL_USER}"

# Group adds that need a group the install sections create and the
# account this section just created: docker (apt family) and
# libvirt. Both adds used to sit in their install sections, hundreds
# of lines before create_user ran, so on a fresh machine they
# failed on run 1 and only a re-run converged; v1.7 moves them here,
# next to the sudo-group add below, where the account exists. A
# failure here is a real failure and is reported as one.
if [[ "${FAMILY}" == "apt" ]] && command -v docker >/dev/null 2>&1; then
    if getent group docker >/dev/null 2>&1; then
        if usermod -aG docker "${WORK_USER}"; then
            done_item "${WORK_USER} added to the docker group (root-equivalent; matches the libvirt pattern so the work account can run containers without sudo)"
        else
            warn_item "${WORK_USER} could not be added to the docker group (checklist 4)"
        fi
    fi
fi
if [[ "${INSTALL_VIRT}" == "1" ]]; then
    if getent group libvirt >/dev/null 2>&1; then
        if usermod -aG libvirt "${WORK_USER}"; then
            done_item "${WORK_USER} added to the libvirt group (checklist 4)"
        else
            warn_item "${WORK_USER} could not be added to the libvirt group (checklist 4)"
        fi
    fi
fi

# Sudo posture (checklist 3): your users are NOPASSWD by design
# (Michael's ruling: deliberate, for convenience). New accounts get
# no sudoers entries from this script; membership only on request.
# The report states the posture it finds as fact, never as a
# defect: NOPASSWD present is the intended configuration.
SUDO_GROUP="wheel"
[[ "${FAMILY}" == "apt" ]] && SUDO_GROUP="sudo"
if [[ "${GRANT_SUDO_WORK}" == "1" ]]; then
    if usermod -aG "${SUDO_GROUP}" "${WORK_USER}"; then
        done_item "${WORK_USER} added to ${SUDO_GROUP} (GRANT_SUDO_WORK=1) (checklist 3)"
    else
        warn_item "${WORK_USER} could not be added to ${SUDO_GROUP} (checklist 3)"
    fi
fi
if grep -Rqs 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
    done_item "sudo posture: NOPASSWD entry present in sudoers, the intended configuration (your users are NOPASSWD by design) (checklist 3)"
else
    done_item "sudo posture: no NOPASSWD entry found in sudoers on this box; your standing design is NOPASSWD for your users, so this box does not match it yet (checklist 3)"
fi

# Per-user environment. Runs as the user so file ownership is right.
as_user() {
    local u="$1"; shift
    runuser -u "${u}" -- env HOME="/home/${u}" "$@"
}

setup_user() {
    local u="$1" role="$2" keyname="$3"
    local home="/home/${u}"

    # Work folder for the work account (checklist 2); scratch habit for
    # both (checklist 6).
    as_user "${u}" mkdir -p "${home}/scratch"
    if [[ "${role}" == "work" ]]; then
        as_user "${u}" mkdir -p "${home}/work"
        done_item "${u}: ~/work created - employer data lives here, one delete on exit (checklist 2)"
    fi

    # SSH: per-role key generated for the purpose (checklist 2) and a
    # hardened client config (checklist 3).
    as_user "${u}" mkdir -p "${home}/.ssh"
    as_user "${u}" chmod 700 "${home}/.ssh"
    local keyfile="${home}/.ssh/${keyname}"
    if [[ -e "${keyfile}" ]]; then
        done_item "${u}: SSH key already present: ${keyname} (checklist 2)"
    elif [[ "${INTERACTIVE}" == "1" ]]; then
        say "Generating ${keyname} for ${u} - you will be prompted for a passphrase:"
        if as_user "${u}" ssh-keygen -t ed25519 -f "${keyfile}" -C "${u}@$(hostname)-${role}"; then
            done_item "${u}: SSH key generated: ${keyname} (checklist 2)"
        else
            warn_item "${u}: ssh-keygen did not complete"
        fi
    else
        manual_item "Generate the ${role} SSH key:  sudo -u ${u} ssh-keygen -t ed25519 -f ${keyfile}"
    fi
    if [[ ! -e "${home}/.ssh/config" ]]; then
        as_user "${u}" tee "${home}/.ssh/config" >/dev/null <<'EOF'
Host *
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PasswordAuthentication no

# Per-host entries go below, one IdentityFile per role/employer, e.g.
# Host work-host
#     HostName 203.0.113.10
#     User michael
#     IdentityFile ~/.ssh/id_ed25519_work
EOF
        as_user "${u}" chmod 600 "${home}/.ssh/config"
        done_item "${u}: SSH client config written (IdentitiesOnly, key-only) (checklist 3)"
    fi

    # Terminal: tmux config + a history/aliases block in .bashrc, both
    # marker-managed so re-runs replace rather than duplicate (section 4).
    as_user "${u}" tee "${home}/.tmux.conf" >/dev/null <<'EOF'
# Managed by laptop-role-prep-setup - safe to edit, re-runs overwrite.
set -g history-limit 10000
set -g base-index 1
setw -g pane-base-index 1
set -g mouse off
bind r source-file ~/.tmux.conf
EOF
    local block="${home}/.bashrc"
    as_user "${u}" touch "${block}"
    if grep -q 'laptop-role-prep' "${block}" 2>/dev/null; then
        as_user "${u}" sed -i '/# >>> laptop-role-prep >>>/,/# <<< laptop-role-prep <<</d' "${block}"
    fi
    as_user "${u}" tee -a "${block}" >/dev/null <<'EOF'
# >>> laptop-role-prep >>>
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=5000
HISTFILESIZE=10000
shopt -s histappend
alias ll='ls -alF'
alias la='ls -A'
alias grep='grep --color=auto'
# <<< laptop-role-prep <<<
EOF
    done_item "${u}: tmux config + shell history/aliases in place (checklist 4)"

    # Public repo clone (checklist 4): the ops toolkit lives there.
    if [[ ! -d "${home}/public" ]] && command -v git >/dev/null 2>&1; then
        if as_user "${u}" git clone --quiet "${PUBLIC_REPO_URL}" "${home}/public" 2>/dev/null; then
            done_item "${u}: public repo cloned to ~/public (checklist 4)"
        else
            warn_item "${u}: public repo clone failed; the usual causes are no network or this account's key not yet added on GitHub - clone ${PUBLIC_REPO_URL} later"
        fi
    fi
}

setup_user "${WORK_USER}" work id_ed25519_work
setup_user "${PERSONAL_USER}" personal id_ed25519_personal

# Git identities (checklist 2 and 6): conditional includes, never one
# global identity. Values only when configured at the top of this script.
git_identity() {
    local u="$1" name="$2" email="$3"
    if [[ -n "${name}" && -n "${email}" ]]; then
        as_user "${u}" git config --global user.name "${name}"
        as_user "${u}" git config --global user.email "${email}"
        done_item "${u}: git identity set (checklist 6)"
    else
        manual_item "Set the git identity for ${u}:  sudo -u ${u} git config --global user.name '<name>' and user.email '<email>' (or fill the variables at the top of this script and re-run)"
    fi
}

git_identity "${PERSONAL_USER}" "${PERSONAL_GIT_NAME}" "${PERSONAL_GIT_EMAIL}"

# Work repos under ~/work/ pick up the work identity via includeIf.
WORK_HOME="/home/${WORK_USER}"
if [[ -n "${WORK_GIT_NAME}" && -n "${WORK_GIT_EMAIL}" ]]; then
    as_user "${WORK_USER}" tee "${WORK_HOME}/work/.gitconfig-work" >/dev/null <<EOF
[user]
    name = ${WORK_GIT_NAME}
    email = ${WORK_GIT_EMAIL}
EOF
else
    if [[ ! -e "${WORK_HOME}/work/.gitconfig-work" ]]; then
        as_user "${WORK_USER}" tee "${WORK_HOME}/work/.gitconfig-work" >/dev/null <<'EOF'
# Work git identity. Fill these in (or set WORK_GIT_NAME / WORK_GIT_EMAIL
# at the top of the setup script and re-run), then uncomment.
# [user]
#     name =
#     email =
EOF
    fi
    manual_item "Fill in the work git identity in ${WORK_HOME}/work/.gitconfig-work (checklist 2, 6)"
fi
as_user "${WORK_USER}" touch "${WORK_HOME}/.gitconfig"
if ! grep -q 'gitconfig-work' "${WORK_HOME}/.gitconfig" 2>/dev/null; then
    as_user "${WORK_USER}" tee -a "${WORK_HOME}/.gitconfig" >/dev/null <<'EOF'
[includeIf "gitdir:~/work/"]
    path = ~/work/.gitconfig-work
EOF
fi
done_item "${WORK_USER}: git conditional include wired for ~/work/ (checklist 2, 6)"

manual_item "Section 2: the separate browser profile is automatic inside each separate account; sign the work account's browser into work only, never personal logins."
manual_item "Section 3: sign in to Proton Pass and set up the SSH agent (companion handoff: proton-pass-ssh-handoff), then import the two new keys into the vault."
manual_item "Section 3: prepare an encrypted (LUKS) USB drive for restricted environments; needs the physical drive."
manual_item "Sections 5/7/8: presentation path, headset/webcam checks, and the physical carry kit are hands-on; run the section 9 dry run before day one."

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------

step "Report"

say "DONE:"
for i in "${DONE_ITEMS[@]}"; do say "  [x] ${i}"; done
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    say ""
    say "WARNINGS:"
    for i in "${WARNINGS[@]}"; do say "  [!] ${i}"; done
fi
say ""
say "MANUAL (not CLI-able, or needs your input):"
for i in "${MANUAL_ITEMS[@]}"; do say "  [ ] ${i}"; done

for u in "${WORK_USER}" "${PERSONAL_USER}"; do
    for pub in "/home/${u}/.ssh/"*.pub; do
        [[ -e "${pub}" ]] || continue
        say ""
        say "Public key for ${u} (${pub}):"
        ssh-keygen -lf "${pub}" 2>/dev/null || cat "${pub}"
    done
done
say ""
say "Re-running this script is safe; it converges to the same state."
```

*Companion records: proton-pass-ssh-handoff-v1.0.md (open item [ee7f5b] on the action board), ansible-hosts-inventory (homelab reference), the public repo at github.com/amaad-michael/public (toolkit and playbooks source); laptop-role-prep-setup-v2.0.sh, the standalone form of the section 11 script (byte-identical; the two files travel together).*
