# Bash Template (Verbose)

The verbose variant of the bash template: banner header, `set -euo pipefail`, a `usage()` function with `getopts` argument parsing, start/finish timestamps with elapsed time, and a `main` entry point. Copy the script block into a new `.sh` file.

```bash
#!/bin/bash
########################################
##  ▄▀▄     █▄ ▄█ █ ▄▀▀ █▄█ ▄▀▄ ██▀ █     ▀█▀ ▄▀▄ ▀█▀ █ █ █▄ ▄█
##  █▀█ ▄   █ ▀ █ █ ▀▄▄ █ █ █▀█ █▄▄ █▄▄    █  █▀█  █  ▀▄█ █ ▀ █
########################################

# Script: simple_script.sh
# Purpose: Your script's purpose here.

set -euo pipefail  # Safe scripting: exit on error, unset variables, or pipeline failure

date
uptime

# Usage function
usage() {
    echo "Usage: $0 [-h]"
    exit 1
}

# Argument parsing
while getopts ":h" opt; do
    case "${opt}" in
        h) usage ;;
        *) usage ;;
    esac
done

# Main function
main() {
    echo "Script running..."
    # Add your logic here
    echo "Done."
}

main  # Run the script

date
uptime

echo "It took $SECONDS seconds for this script to execute."
```
