#!/bin/bash
## Michael Tatum; RHEL FIREWALL & PORT AUDIT SCRIPT

# Configurable log directory
LOG_DIR="/var/log/firewall_audit"
mkdir -p "$LOG_DIR"

# Output log file
LOG_FILE="$LOG_DIR/firewall_audit_$(date +%Y%m%d_%H%M%S).log"

# List of servers
SERVERS=("10.0.0.1" "10.0.0.2" "10.0.0.3")

# Start logging
echo "Starting firewall and port audit..." > "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

for SERVER in "${SERVERS[@]}"; do
    echo "Auditing $SERVER..." | tee -a "$LOG_FILE"

    if ! ssh -o ConnectTimeout=10 "$SERVER" "echo OK" &>/dev/null; then
        echo "ERROR: Unable to connect to $SERVER" | tee -a "$LOG_FILE"
        continue
    fi

    {
        echo "========== $SERVER =========="
        echo "Timestamp: $(date)"
        echo ""

        echo "--- SELinux Status ---"
        ssh "$SERVER" 'getenforce || echo "SELinux not available"'
        echo ""

        echo "--- FirewallD Status ---"
        ssh "$SERVER" 'systemctl is-active firewalld && firewall-cmd --state || echo "FirewallD not active or not installed"'
        echo ""

        echo "--- Active Zones & Services ---"
        ssh "$SERVER" 'firewall-cmd --get-active-zones && firewall-cmd --list-services || echo "No active zones/services"'
        echo ""

        echo "--- Masquerading & Port Forwarding ---"
        ssh "$SERVER" 'firewall-cmd --query-masquerade && firewall-cmd --list-forward-ports || echo "No masquerading or port forwarding"'
        echo ""

        echo "--- iptables Rules ---"
        ssh "$SERVER" 'sudo iptables -L -n -v || echo "iptables not available"'
        echo ""

        echo "--- nftables Rules ---"
        ssh "$SERVER" 'nft list ruleset || echo "nftables not in use"'
        echo ""

        echo "--- Open Ports (ss) ---"
        ssh "$SERVER" 'ss -tuln || netstat -tuln'
        echo ""

        echo "--- PID to Command Mapping for Open Ports ---"
        ssh "$SERVER" '
            ss -tulnp | awk "NR>1" | while read -r line; do
                pid=$(echo "$line" | grep -oP "pid=\K[0-9]+")
                if [ -n "$pid" ]; then
                    cmd=$(ps -p "$pid" -o cmd=)
                    echo "PID: $pid - Command: $cmd"
                fi
            done || echo "No PID to command mapping available"
        '
        echo ""

        echo "--- Listening Services (lsof) ---"
        ssh "$SERVER" 'lsof -i -P -n | grep LISTEN || echo "lsof not available or no services listening"'
        echo ""

        echo "--- Non-localhost Bound Ports ---"
        ssh "$SERVER" 'ss -tuln | grep -v "127.0.0.1" || echo "No external bindings found"'
        echo ""

        echo "--- Installed Firewall Packages ---"
        ssh "$SERVER" 'rpm -qa | grep -E "firewalld|iptables|nftables"'
        echo ""

        echo "--- Recent Firewall Changes ---"
        ssh "$SERVER" 'find /etc/firewalld /etc/sysconfig/iptables -type f -exec ls -l {} \; 2>/dev/null'
        echo ""

        echo "--- FirewallD Logs (last 7 days) ---"
        ssh "$SERVER" 'journalctl -u firewalld --since "7 days ago" || echo "No recent logs found"'
        echo ""

    } >> "$LOG_FILE"
done

echo "Firewall audit complete. Log saved to $LOG_FILE"
