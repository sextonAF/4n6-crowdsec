#!/usr/bin/env bash
# Stage 2 of deployment: run as root on Gigahost srv19210.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
[ "$(hostname -s)" = "srv19210" ] || { echo "Wrong host; expected srv19210" >&2; exit 1; }
for command in git nft python3 systemctl sshd openssl curl; do
  command -v "$command" >/dev/null || { echo "Missing: $command" >&2; exit 1; }
done
nft list table inet opengov_guard >/dev/null
systemctl is-active --quiet crowdsec.service
systemctl is-active --quiet opengov-guard.service
[ "$(systemctl is-enabled nftables.service 2>/dev/null || true)" = disabled ] || {
  echo "Expected disabled nftables.service: refusing to modify system" >&2; exit 1;
}
printf "Paste authentik2 country tunnel PUBLIC key (ssh-ed25519 ...): "
IFS= read -r PUBLIC_KEY
[[ "$PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] || {
  echo "Invalid SSH public key" >&2; exit 1;
}
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/root/4n6-country-backups/$STAMP"
install -d -m 700 "$BACKUP"
nft -a list ruleset > "$BACKUP/nft-ruleset.before.txt"
for file in /etc/systemd/system/4n6-country-agent.service /etc/systemd/system/4n6-country-refresh.service /etc/systemd/system/4n6-country-refresh.timer; do
  [ ! -e "$file" ] || cp -a "$file" "$BACKUP/"
done
if [ -d /opt/4n6-country-agent/app ]; then
  cp -a /opt/4n6-country-agent/app "$BACKUP/previous-app"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone -q --depth 1 --branch feature/country-blocking https://github.com/sextonAF/4n6-crowdsec.git "$TMP/repo"
(
  cd "$TMP/repo/agent"
  python3 -m unittest discover -s tests -v
)
install -d -m 755 /opt/4n6-country-agent
rm -rf /opt/4n6-country-agent/app.new
mkdir /opt/4n6-country-agent/app.new
cp -a "$TMP/repo/agent/." /opt/4n6-country-agent/app.new/
if [ -d /opt/4n6-country-agent/app ]; then
  mv /opt/4n6-country-agent/app /opt/4n6-country-agent/app.previous
fi
mv /opt/4n6-country-agent/app.new /opt/4n6-country-agent/app
install -d -m 700 /var/lib/4n6-country-agent /etc/4n6-country-agent
if [ ! -s /etc/4n6-country-agent/token ]; then
  openssl rand -hex 32 > /etc/4n6-country-agent/token
fi
chmod 600 /etc/4n6-country-agent/token
id crowdsec-country-tunnel >/dev/null 2>&1 || useradd -r -m -d /var/lib/crowdsec-country-tunnel -s /usr/sbin/nologin crowdsec-country-tunnel
HOME_DIR="$(getent passwd crowdsec-country-tunnel | cut -d: -f6)"
install -d -m 700 -o crowdsec-country-tunnel -g crowdsec-country-tunnel "$HOME_DIR/.ssh"
printf 'restrict,port-forwarding,permitopen="127.0.0.1:14110" %s\n' "$PUBLIC_KEY" > "$HOME_DIR/.ssh/authorized_keys"
chown crowdsec-country-tunnel:crowdsec-country-tunnel "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
cat > /etc/systemd/system/4n6-country-agent.service <<'UNIT'
[Unit]
Description=4N6 country blocking enforcement agent
Wants=network-online.target
After=network-online.target opengov-guard.service crowdsec-firewall-bouncer.service globaleaks.service
[Service]
Type=simple
User=root
WorkingDirectory=/opt/4n6-country-agent/app
ExecStartPre=/usr/bin/python3 -m country_agent restore --state-dir /var/lib/4n6-country-agent
ExecStart=/usr/bin/python3 -m country_agent serve --bind 127.0.0.1 --port 14110 --server-id gigahost-no --token-file /etc/4n6-country-agent/token --feeds /var/lib/4n6-country-agent --state-dir /var/lib/4n6-country-agent
Restart=on-failure
RestartSec=3s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelTunables=yes
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=/var/lib/4n6-country-agent /run
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/4n6-country-refresh.service <<'UNIT'
[Unit]
Description=4N6 country IP-range refresh
After=network-online.target 4n6-country-agent.service
Wants=network-online.target
[Service]
Type=oneshot
User=root
WorkingDirectory=/opt/4n6-country-agent/app
ExecStart=/usr/bin/python3 -m country_agent refresh --state-dir /var/lib/4n6-country-agent
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=/var/lib/4n6-country-agent /run
UNIT
cat > /etc/systemd/system/4n6-country-refresh.timer <<'UNIT'
[Unit]
Description=Daily refresh of user-selected country IP ranges
[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=1800
Persistent=true
Unit=4n6-country-refresh.service
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now 4n6-country-agent.service 4n6-country-refresh.timer
systemctl is-active --quiet 4n6-country-agent.service
echo "Gigahost agent installed; firewall remains unchanged until Apply."
echo "Backups: $BACKUP"
echo
echo "ONE-TIME AGENT TOKEN — copy into the authentik2 deployment prompt; do not post in chat:"
cat /etc/4n6-country-agent/token
echo
