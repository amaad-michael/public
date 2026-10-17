# Vulnerability scanning playbooks

One playbook builds a persistent scanner node; the other runs a scan from hosts that already have Nmap.

## setup_scanner.yml

Configures a dedicated vulnerability scanner node on a Debian or RedHat family host.

- Targets the inventory group `scanners`, which is not in the shipped `ansible/hosts` file; define it in your inventory.
- Refreshes the package cache (apt or dnf by OS family), then installs nmap, python3, git, and python3-pip.
- Creates the audit workspace `/opt/tatum_audit` (root-owned, mode 0750).
- Installs the two Python libraries the scanning scripts use: `requests` and `dnspython`.

## nmap-scan.yml

Runs an Nmap scan with NSE scripts against every targeted host and collects the output on the controller.

- Targets `hosts: all`, with no privilege escalation and no fact gathering. Limit the run to the hosts you mean to scan.
- Nmap must already be installed on the targets; the playbook checks with `which nmap` and fails the host if it is missing. `setup_scanner.yml` is the way to prepare a node.
- Each host is scanned by its inventory name. The scan writes `/tmp/nmap_scan_<host>.txt` on the target, fetches it into the results directory on the controller, and deletes the remote copy.

Behaviour is set by three variables:

| Variable | Default | Meaning |
|---|---|---|
| `scan_ports` | `80,443,22` | Ports scanned on each host |
| `builtin_scripts` | `http-title,vuln` | NSE scripts to run; can be set empty |
| `results_dir` | `./nmap_results` | Controller directory that receives the per-host output files |

Only built-in NSE scripts are available. The original version of this playbook referenced a custom script, `files/nmap-scripts/my-custom-script.nse`, which was never published; the tasks that copied and cleaned up that script were removed when the playbook was converted for the repo on 2026-10-17.

The default script set includes the `vuln` category, which actively probes for known vulnerabilities. Run it against hosts you own or are explicitly authorised to test.

## 🔗 Related piece

`containers/scanner/` is the same toolset as a run-on-demand container image: nmap, python3, git, the same `requests` and `dnspython` packages, and the same `/opt/tatum_audit` workspace. The playbook builds the always-there node; the container is the portable form of the same kit.
