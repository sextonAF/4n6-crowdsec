#!/usr/bin/env bash
# Stage 2 of deployment: run as root on Gigahost srv19210.
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR: Installer stopped at line $LINENO (exit $rc), command: $BASH_COMMAND" >&2' ERR
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
[ "$(hostname -s)" = "srv19210" ] || { echo "Wrong host; expected srv19210" >&2; exit 1; }
# The public key was verified from the already-running authentik2 tunnel.
# This is public material only; never embed the private key or agent token.
PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICECou52olpG6dDHHhOhjcZexQqIeMjRIQ1tdbXHbe0E crowdsec-web-ui-gigahost'
echo "========== PRE-INSTALL CHECKS (NO CHANGES) =========="
MISSING=0
for command in git nft python3 systemctl openssl curl; do
  if command -v "$command" >/dev/null; then
    echo "OK: $command"
  else
    echo "MISSING: $command"
    MISSING=1
  fi
done
if nft list table inet opengov_guard >/dev/null 2>&1; then
  echo "OK: existing OpenGov firewall table present"
else
  echo "FAILED: existing OpenGov firewall table not found"
  MISSING=1
fi
for service in crowdsec.service opengov-guard.service; do
  if systemctl is-active --quiet "$service"; then
    echo "OK: $service active"
  else
    echo "FAILED: $service inactive"
    MISSING=1
  fi
done
NFT_SERVICE_STATE="$(systemctl is-enabled nftables.service 2>/dev/null || true)"
if [ "$NFT_SERVICE_STATE" = disabled ]; then
  echo "OK: nftables.service disabled"
else
  echo "FAILED: nftables.service state is $NFT_SERVICE_STATE (expected disabled)"
  MISSING=1
fi
if getent passwd crowdsec-tunnel >/dev/null; then
  echo "OK: existing crowdsec-tunnel account present"
else
  echo "FAILED: existing SSH tunnel account not found"
  MISSING=1
fi
if [ "$MISSING" -ne 0 ]; then
  echo "Preflight failed. No files, firewall rules, or services changed." >&2
  exit 1
fi
echo "All preflight checks passed."
if [ "${1:-}" = "--preflight" ]; then
  echo "READ-ONLY PREFLIGHT COMPLETE. No changes made."
  exit 0
fi
echo "Installing to existing account only."

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
git clone -q --depth 1 --branch main https://github.com/sextonAF/4n6-crowdsec.git "$TMP/repo"
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
# Extend ONLY the matching existing public key's forwarding permission.
# Keep the existing SSH account and key, preserving prior permitopen entries.
python3 - "$PUBLIC_KEY" "$BACKUP" <<'PY'
import os, pathlib, pwd, re, shutil, sys, tempfile
key_data = sys.argv[1].split()[1]
backup = pathlib.Path(sys.argv[2])
matches = []
for account in pwd.getpwall():
    home = pathlib.Path(account.pw_dir)
    if not home.is_absolute() or not home.is_dir():
        continue
    file = home / ".ssh" / "authorized_keys"
    if not file.is_file() or file.is_symlink():
        continue
    lines = file.read_text().splitlines(keepends=True)
    for index, line in enumerate(lines):
        if re.search(r"(^|\s)ssh-ed25519\s+"+re.escape(key_data)+r"(\s|$)",line):
            matches.append((file,index,lines))
if len(matches) != 1:
    raise SystemExit("Expected exactly one existing authorized SSH key on Gigahost; found "+str(len(matches)))
file,index,lines=matches[0]
line=lines[index]
prefix, marker, suffix = line.partition("ssh-ed25519 ")
if not marker:
    raise SystemExit("Authorized key format not recognized")
options=prefix.strip()
if options and "permitopen=" in options:
    if 'permitopen="127.0.0.1:14110"' not in options:
        prefix=options+',permitopen="127.0.0.1:14110" '
        lines[index]=prefix+marker+suffix
        shutil.copy2(file,backup/"authorized_keys.before")
        st=file.stat()
        fd,tmp=tempfile.mkstemp(prefix=".authorized_keys-",dir=file.parent)
        try:
            with os.fdopen(fd,"w") as out:
                out.writelines(lines)
                out.flush()
                os.fsync(out.fileno())
            os.chmod(tmp,st.st_mode & 0o777)
            os.chown(tmp,st.st_uid,st.st_gid)
            os.replace(tmp,file)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
elif options and ("restrict" in options or "no-port-forwarding" in options):
    raise SystemExit("SSH key has restrictions not safely handled automatically; no changes made")
print("Reusing existing SSH account/key from",file)
print("Existing CrowdSec port-forward authorization preserved")
PY
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
