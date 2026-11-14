#!/usr/bin/env bash
# Add the country-agent forward to the EXISTING SSH tunnel only.
set -Eeuo pipefail
SERVICE=crowdsec-gigahost-tunnel.service
DROPIN="/etc/systemd/system/$SERVICE.d/90-4n6-country-forward.conf"
BACKUP_DIR=/opt/crowdsec-web-ui/backups
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo bash" >&2; exit 1; }
[ "$(hostname -s)" = authentik2 ] || { echo "Wrong host" >&2; exit 1; }
for tool in python3 systemctl ss; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
systemctl is-active --quiet "$SERVICE" || { echo "Existing SSH tunnel inactive" >&2; exit 1; }
PID="$(systemctl show "$SERVICE" --value -p MainPID)"
[[ "$PID" =~ ^[1-9][0-9]*$ ]] || { echo "Unknown SSH tunnel PID" >&2; exit 1; }
[ "$(cat "/proc/$PID/comm")" = ssh ] || { echo "Existing tunnel is not direct ssh" >&2; exit 1; }
ss -H -lnt '( sport = :18082 )' | grep -q 18082 || { echo "Original 18082 monitoring forward not listening" >&2; exit 1; }
if ss -H -lnt '( sport = :18083 )' | grep -q 18083; then
  echo "Country agent port 18083 already listening; no changes made."
  exit 0
fi
[ ! -e "$DROPIN" ] || { echo "Country forward drop-in already exists: $DROPIN; refusing changes" >&2; exit 1; }
BASE="$(systemctl show "$SERVICE" --value -p FragmentPath)"
[ -r "$BASE" ] || { echo "Cannot inspect original service file" >&2; exit 1; }
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
python3 - "$PID" "$TMP" <<'PY'
import os, pathlib, sys
pid, dest = sys.argv[1:]
argv = [a.decode() for a in pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if a]
if not argv or os.path.basename(argv[0]) != "ssh":
    raise SystemExit("Current tunnel must be a direct SSH process")
if "-N" not in argv:
    raise SystemExit("Existing SSH process is not an explicit -N tunnel")
if not any("18082:" in a for a in argv):
    raise SystemExit("Existing SSH 18082 forwarding option missing")
if any("18083:" in a for a in argv):
    raise SystemExit("Country forwarding already present in current process")
if not argv[-1].startswith("crowdsec-tunnel@") or "193.243.189.205" not in argv[-1]:
    raise SystemExit("SSH destination differs from existing Gigahost account")
argv[-1:-1] = ["-L", "172.21.0.1:18083:127.0.0.1:14110"]
def quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$") + '"'
pathlib.Path(dest).write_text("[Service]\nExecStart=\nExecStart=" + " ".join(map(quote, argv)) + "\n")
print("Prepared original SSH command with one additional country-agent forward.")
PY
if [ "${1:-}" = "--check" ]; then
  echo "READ-ONLY CHECK PASSED. Existing SSH and UI unchanged."
  exit 0
fi
[ -d "$BACKUP_DIR" ] || { echo "Backup directory missing: $BACKUP_DIR; refusing changes" >&2; exit 1; }
BACKUP="$(mktemp -d "$BACKUP_DIR/tunnel-only-XXXXXXXX")"
chmod 700 "$BACKUP"
systemctl cat "$SERVICE" > "$BACKUP/original-service.txt"
cp -a "$BASE" "$BACKUP/original-unit"
mkdir -p "$(dirname "$DROPIN")"
install -m 644 "$TMP" "$DROPIN"
restore() {
  echo "Forward verification failed; restoring original SSH service." >&2
  rm -f "$DROPIN"
  systemctl daemon-reload
  systemctl restart "$SERVICE" || true
}
systemctl daemon-reload
if ! systemctl restart "$SERVICE"; then restore; exit 1; fi
OK=0
for _ in $(seq 1 12); do
  if ss -H -lnt '( sport = :18082 )' | grep -q 18082 &&
     ss -H -lnt '( sport = :18083 )' | grep -q 18083 &&
     systemctl is-active --quiet "$SERVICE"; then
    OK=1; break
  fi
  sleep 1
done
if [ "$OK" != 1 ]; then restore; exit 1; fi
echo "SUCCESS: existing 18082 and new 18083 SSH forwarding ports are listening."
echo "Web UI, CrowdSec, and Gigahost firewall were not modified."
echo "Backup: $BACKUP"
