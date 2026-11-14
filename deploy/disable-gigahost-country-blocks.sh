#!/usr/bin/env bash
# Emergency disable of all managed country restrictions on Gigahost.
# This does not touch opengov_guard, CrowdSec, or nftables.service.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
[ "$(hostname -s)" = srv19210 ] || { echo "Wrong host" >&2; exit 1; }
cd /opt/4n6-country-agent/app
python3 - <<'PY'
from pathlib import Path
from country_agent.enforcement import apply
print(apply(Path("/var/lib/4n6-country-agent"), []))
PY
echo "User-selected country blocks cleared; other firewall tables untouched."
