#!/usr/bin/env bash
# Expand country selection ceiling in existing agent only. Does not change firewall policy.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
[ "$(hostname -s)" = srv19210 ] || { echo "Expected srv19210" >&2; exit 1; }
FILE=/opt/4n6-country-agent/app/country_agent/enforcement.py
SERVICE=4n6-country-agent.service
[ -f "$FILE" ] || { echo "Existing agent file missing; no changes" >&2; exit 1; }
systemctl is-active --quiet "$SERVICE" || { echo "Existing agent inactive; no changes" >&2; exit 1; }
BACKUP="$(mktemp -d /root/4n6-country-cap-XXXXXXXX)"
chmod 700 "$BACKUP"
cp -a "$FILE" "$BACKUP/enforcement.py"
rollback() {
  trap - ERR
  cp -a "$BACKUP/enforcement.py" "$FILE"
  systemctl restart "$SERVICE" || true
  echo "Restored existing agent source from $BACKUP" >&2
}
trap rollback ERR
python3 - "$FILE" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
source=path.read_text()
old="MAX_COUNTRIES = 30"
if source.count(old)!=1:
    raise SystemExit("Unexpected existing country limit; no changes")
source=source.replace(old,"MAX_COUNTRIES = 249",1)
source=source.replace("Expected an array of at most 30 countries","Expected an array of at most 249 countries")
path.write_text(source)
PY
python3 -m py_compile "$FILE"
systemctl restart "$SERVICE"
TOKEN="$(cat /etc/4n6-country-agent/token)"
READY=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 -H "Authorization: Bearer $TOKEN"     http://127.0.0.1:14110/v1/status 2>/dev/null | python3 -c '
import json,sys
try:
 d=json.load(sys.stdin)
 assert d["server_id"]=="gigahost-no" and d["mode"]=="enforcement"
except (ValueError,AssertionError,KeyError):sys.exit(1)
' 2>/dev/null; then READY=1; break; fi
  sleep 1
done
unset TOKEN
[ "$READY" = 1 ] || { echo "Agent did not become ready; rollback"; false; }
trap - ERR
echo "SUCCESS: Existing country agent accepts up to 249 countries."
echo "Existing firewall rules unchanged. Backup: $BACKUP"
