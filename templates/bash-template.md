# Bash Template

A minimal starter for new Bash scripts: banner header, `set -euo pipefail`, start/finish timestamps with elapsed time, and a `main "$@"` entry point. Copy the script block into a new `.sh` file.

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

main() {
  # Your main script logic here.
  :
}

# Execute main function
main "$@"

date
uptime

echo "It took $SECONDS seconds for this script to execute."
```
