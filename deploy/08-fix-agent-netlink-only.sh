#!/usr/bin/env bash
# Fix ONLY missing AF_NETLINK permissions for existing Gigahost country agent.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
[ "$(hostname -s)" = srv19210 ] || { echo "Expected Gigahost srv19210" >&2; exit 1; }
for u in 4n6-country-agent.service 4n6-country-refresh.service; do
  FILE="/etc/systemd/system/$u"
  [ -f "$FILE" ] || { echo "Missing existing $FILE" >&2; exit 1; }
  grep -Fxq "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" "$FILE" ||
    { echo "Unexpected current restrictions in $FILE. No changes made." >&2; exit 1; }
done
AGENT=4n6-country-agent.service
systemctl is-active --quiet "$AGENT" || { echo "Existing agent inactive; no changes made" >&2; exit 1; }
BACKUP="$(mktemp -d /root/4n6-country-netlink-XXXXXXXX)"
chmod 700 "$BACKUP"
for u in 4n6-country-agent.service 4n6-country-refresh.service; do
  systemctl cat "$u" > "$BACKUP/$u.before.txt"
  DIR="/etc/systemd/system/$u.d"
  mkdir -p "$DIR"
  DROPIN="$DIR/90-allow-nft-netlink.conf"
  [ ! -e "$DROPIN" ] || { echo "Drop-in already exists at $DROPIN; inspect before changes" >&2; exit 1; }
done
rollback() {
  for u in 4n6-country-agent.service 4n6-country-refresh.service; do
    rm -f "/etc/systemd/system/$u.d/90-allow-nft-netlink.conf"
  done
  systemctl daemon-reload
  systemctl restart "$AGENT" || true
  echo "Original agent restrictions restored. Backup: $BACKUP" >&2
}
trap 'rollback' ERR
for u in 4n6-country-agent.service 4n6-country-refresh.service; do
  cat > "/etc/systemd/system/$u.d/90-allow-nft-netlink.conf" <<'UNIT'
[Service]
RestrictAddressFamilies=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
UNIT
done
systemctl daemon-reload
systemctl restart "$AGENT"
systemctl is-active --quiet "$AGENT"
# Authenticated status without outputting token.
TOKEN="$(cat /etc/4n6-country-agent/token)"
curl -fsS --max-time 8 \
  -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:14110/v1/status | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["server_id"]=="gigahost-no" and d["mode"]=="enforcement"
print("Agent status verified. Active countries:", ",".join(d["countries"]) or "none")
'
unset TOKEN
trap - ERR
echo "SUCCESS: nftables netlink permission added to existing agent and refresh service."
echo "No country rules were added or modified. Backup: $BACKUP"
