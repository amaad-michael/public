# Reboot playbooks

Two ways to reboot Debian and RedHat family hosts with Ansible's `reboot` module. Both target `hosts: all` (scope with `--limit`), and both wait up to 600 seconds (`reboot_timeout`) for a host to come back. Neither sets a reboot message or pre- or post-reboot delays, so the module defaults apply there.

| Playbook | Pre-check | Post-reboot confirmation |
|---|---|---|
| `reboot_simple.yml` | None | Handler prints that the host has been rebooted |
| `reboot_complex.yml` | Fails the host if an `uptime` command errors before the reboot | The reboot module runs `whoami` as its test command; a handler reports the host rebooted and accessible |

## reboot_simple.yml

The plain reboot. One task reboots the host when its OS family is Debian or RedHat, and a handler posts a short notification afterwards. Nothing is checked before or after beyond the reboot module's own wait for the host to return.

This is the playbook the monthly maintenance wrapper (`scripts/run_monthly_maintenance.sh`) uses for its reboot step, against pi0, pi2, pi3, and pi4.

## reboot_complex.yml

The guarded reboot. Before rebooting, a pre-task runs `uptime` on the host: if the command returns a non-zero exit code, the play fails for that host and no reboot is attempted. The uptime output is printed so the run log shows the pre-reboot state. The reboot itself passes `test_command: whoami`, so the module confirms the host is genuinely back and accepting commands, and a handler logs that the host rebooted successfully and is accessible.

Pick `reboot_complex.yml` when a host might already be unhealthy and you want the run to stop instead of rebooting a sick machine blind. Pick `reboot_simple.yml` for routine, scheduled reboots of hosts you have just patched and verified.

## Bash form

`scripts/fleet-reboot.sh` mirrors both playbooks over SSH: hosts are
rebooted one at a time in inventory order, each verified back before
the next is touched. The default mode is the complex one (the
`uptime` pre-check gates the reboot; `whoami` plus a changed boot ID
confirm the return, within the same 600 second timeout);
`--simple` drops the pre-check. The bash equivalent of the monthly wrapper's reboot step is
`./scripts/fleet-reboot.sh --simple --limit pi0,pi2,pi3,pi4`. There
is no Docker form: rebooting a host is an operation on the host
itself.

Run without `--limit` on a terminal, the bash form opens a
host-selection panel over the `[pi_all]` hosts (checkboxes, all
starting checked) to build the host set, then requires a typed
confirmation (the word `reboot`) before the first host is
touched; the panel only selects, and declining the confirmation
reboots nothing. Off a terminal the bare form keeps its
long-standing meaning: all of `pi_all`, no panel, no
confirmation.
