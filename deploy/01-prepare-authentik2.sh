#!/usr/bin/env bash
# Read-only preflight: reuse the existing CrowdSec SSH tunnel, key and account.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run using sudo bash" >&2; exit 1; }
SERVICE=crowdsec-gigahost-tunnel.service
systemctl is-active --quiet "$SERVICE" || { echo "Existing $SERVICE is not active" >&2; exit 1; }
PID="$(systemctl show "$SERVICE" --value -p MainPID)"
[[ "$PID" =~ ^[1-9][0-9]*$ ]] || { echo "Existing service has no running main process" >&2; exit 1; }
[ "$(cat "/proc/$PID/comm")" = ssh ] || {
  echo "Main process is not ssh; cannot safely extend this tunnel without its exact command" >&2; exit 1;
}
python3 - "$PID" <<'PY'
import os, subprocess, sys
args = open(f"/proc/{sys.argv[1]}/cmdline","rb").read().split(b"\0")
args = [a.decode() for a in args if a]
if not args or os.path.basename(args[0]) != "ssh":
    raise SystemExit("Expected a direct ssh process")
identities = [args[i + 1] for i, a in enumerate(args[:-1]) if a == "-i"]
for i,a in enumerate(args[:-1]):
    if a.startswith("-i") and a != "-i":
        identities.append(a[2:])
if len(identities) != 1:
    raise SystemExit("Cannot identify exactly one existing tunnel SSH identity file")
identity = identities[0]
if not os.path.isfile(identity) or not os.path.isfile(identity + ".pub"):
    raise SystemExit("Existing tunnel identity/public key not found")
if not any("18082:" in a for a in args):
    raise SystemExit("Expected existing CrowdSec LAPI forward (18082) missing; refuse changes")
print("Existing SSH tunnel service is active")
print("Existing private key path (not printed):", identity)
print("Existing tunnel destination:", args[-1])
print("Existing authorized PUBLIC key for Gigahost stage:")
print(open(identity+".pub",encoding="ascii").read().strip())
print("No tunnel, key, account, or service was created or modified")
PY
