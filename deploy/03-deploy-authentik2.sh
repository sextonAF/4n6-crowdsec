#!/usr/bin/env bash
# Stage 3: execute as root on authentik2 after Gigahost agent is installed.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo bash" >&2; exit 1; }
for command in git docker ssh systemctl curl python3; do
  command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 1; }
done
BASE=/opt/crowdsec-web-ui
SECRETS="$BASE/secrets"
COMPOSE="$BASE/compose.yaml"
test -f "$COMPOSE" || { echo "Existing CrowdSec Compose configuration missing" >&2; exit 1; }
test "$(hostname -s)" = authentik2 || { echo "Expected host authentik2" >&2; exit 1; }
test -n "$(docker ps -q -f name=^/crowdsec_web_ui$)" || { echo "Existing CrowdSec Web UI is not running" >&2; exit 1; }
CONTAINER=crowdsec_web_ui
SERVICE="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$CONTAINER")"
[[ "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Unable to determine Compose service" >&2; exit 1; }
ip -4 addr show | grep -q '172.21.0.1/' || { echo "Docker bridge gateway 172.21.0.1 not found" >&2; exit 1; }
ip link show br-0e6182ca2826 >/dev/null || { echo "Expected monitored Docker bridge not found" >&2; exit 1; }
# Existing encrypted SSH tunnel is mandatory; no new credentials or account.
TUNNEL_SERVICE=crowdsec-gigahost-tunnel.service
systemctl is-active --quiet "$TUNNEL_SERVICE" || {
  echo "Existing CrowdSec Gigahost SSH tunnel is not active" >&2; exit 1;
}
[ -n "$(ss -H -lnt '( sport = :18082 )')" ] || {
  echo "Existing CrowdSec local tunnel port 18082 not listening" >&2; exit 1;
}
read -rp 'Enter CrowdSec instance ID for Gigahost [gigahost-no]: ' INSTANCE_ID
INSTANCE_ID="${INSTANCE_ID:-gigahost-no}"
[[ "$INSTANCE_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid instance ID" >&2; exit 1; }
read -rsp 'Paste Gigahost country-agent token (input hidden): ' TOKEN
echo
[ "${#TOKEN}" -ge 32 ] || { echo "Agent token is too short" >&2; exit 1; }
umask 077
install -d -m 750 "$SECRETS"
printf '%s\n' "$TOKEN" > "$SECRETS/country_agent_token"
unset TOKEN
chown root:1000 "$SECRETS/country_agent_token"
chmod 640 "$SECRETS/country_agent_token"
printf '{"%s":{"url":"http://172.21.0.1:18083","token_file":"/run/secrets/country_agent_token"}}\n' "$INSTANCE_ID" > "$SECRETS/geo_agents.json"
chown root:1000 "$SECRETS/geo_agents.json"
chmod 640 "$SECRETS/geo_agents.json"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BASE/backups/country-$STAMP"
install -d -m 700 "$BACKUP"
cp -a "$COMPOSE" "$BACKUP/compose.yaml"
[ ! -e "$BASE/country-override.yaml" ] || cp -a "$BASE/country-override.yaml" "$BACKUP/country-override.yaml"
docker inspect "$CONTAINER" > "$BACKUP/container-before.json"
OLD_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER")"
docker tag "$OLD_IMAGE_ID" "4n6-crowdsec:rollback-$STAMP"
echo "Rollback image: 4n6-crowdsec:rollback-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone -q --depth 1 --branch main https://github.com/sextonAF/4n6-crowdsec.git "$TMP/repo"
REV="$(git -C "$TMP/repo" rev-parse --verify HEAD)"
echo "Building 4N6 CrowdSec commit: $REV"
docker build --pull -t "4n6-crowdsec:${REV:0:12}" \
  --build-arg "VITE_COMMIT_HASH=${REV:0:12}" \
  --build-arg "VITE_BRANCH=main" \
  --build-arg "VITE_REPO_URL=https://github.com/sextonAF/4n6-crowdsec" \
  "$TMP/repo"
# Extend the existing tunnel service, preserving all its current SSH arguments.
# One SSH connection will forward both the original 18082 and new 18083 ports.
TUNNEL_DROPIN="/etc/systemd/system/$TUNNEL_SERVICE.d/90-4n6-country-forward.conf"
install -d -m 755 "$(dirname "$TUNNEL_DROPIN")"
if [ -e "$TUNNEL_DROPIN" ]; then
  cp -a "$TUNNEL_DROPIN" "$BACKUP/tunnel-dropin.before"
fi
systemctl cat "$TUNNEL_SERVICE" > "$BACKUP/tunnel-service.before.txt"
TUNNEL_PID="$(systemctl show "$TUNNEL_SERVICE" --value -p MainPID)"
[[ "$TUNNEL_PID" =~ ^[1-9][0-9]*$ ]] || {
  echo "Missing active SSH process; no change made" >&2; exit 1;
}
[ "$(cat "/proc/$TUNNEL_PID/comm")" = ssh ] || {
  echo "Existing tunnel process is not ssh; no change made" >&2; exit 1;
}
python3 - "$TUNNEL_PID" "$TUNNEL_DROPIN" <<'PY'
import os, pathlib, sys
pid, output = sys.argv[1:]
argv = [x.decode() for x in pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if x]
if not argv or os.path.basename(argv[0]) != "ssh":
    raise SystemExit("Existing tunnel executable is not ssh")
if not any("18082:" in x for x in argv):
    raise SystemExit("Original 18082 CrowdSec port-forward is missing")
if any("18083:" in x for x in argv):
    raise SystemExit("New forwarding port already configured; refusing duplicate")
# SSH's -N connection has no remote command. Append a second -L to the
# original argv; preserve all existing keys, host checks, ports, and flags.
if "-N" not in argv and not any(x.startswith("-N") and len(x)>2 for x in argv):
    raise SystemExit("Existing SSH service is not a pure -N tunnel")
argv.extend(["-L","172.21.0.1:18083:127.0.0.1:14110"])
def quote(v):
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("%","%%").replace("$","$$") + '"'
content="[Service]\nExecStart=\nExecStart="+" ".join(map(quote,argv))+"\n"
pathlib.Path(output).write_text(content)
PY
# Changes may interrupt the existing tunnel briefly; automatically restore
# the exact previous drop-in and restart the original service if it fails.
restore_tunnel() {
  if [ -f "$BACKUP/tunnel-dropin.before" ]; then
    cp -a "$BACKUP/tunnel-dropin.before" "$TUNNEL_DROPIN"
  else
    rm -f "$TUNNEL_DROPIN"
  fi
  systemctl daemon-reload
  systemctl restart "$TUNNEL_SERVICE" || true
}
systemctl daemon-reload
if ! systemctl restart "$TUNNEL_SERVICE"; then
  restore_tunnel
  echo "Extended SSH tunnel failed; previous configuration restored" >&2
  exit 1
fi
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  ufw allow in on br-0e6182ca2826 from 172.21.0.0/16 to 172.21.0.1 port 18083 proto tcp comment '4n6 geo agent existing tunnel'
fi
if [ -z "$(ss -H -lnt '( sport = :18082 )')" ] || [ -z "$(ss -H -lnt '( sport = :18083 )')" ]; then
  restore_tunnel
  echo "One of the two SSH forwarding ports is missing; original tunnel restored" >&2
  exit 1
fi
for try in $(seq 1 15); do
  if curl -fsS --max-time 3 -H "Authorization: Bearer $(cat "$SECRETS/country_agent_token")" \
    http://172.21.0.1:18083/v1/status > "$BACKUP/agent-status.json"; then
    break
  fi
  sleep 2
done
python3 - "$BACKUP/agent-status.json" "$INSTANCE_ID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["server_id"]==sys.argv[2], "Agent identity mismatch"
assert d["mode"]=="enforcement", "Agent enforcement unavailable"
print("Remote agent verified:", d["server_id"])
PY
cat > "$BASE/country-override.yaml" <<YAML
services:
  $SERVICE:
    image: 4n6-crowdsec:${REV:0:12}
    environment:
      FOURN6_COUNTRY_AGENTS_FILE: /run/secrets/geo_agents.json
    volumes:
      - $SECRETS/geo_agents.json:/run/secrets/geo_agents.json:ro
      - $SECRETS/country_agent_token:/run/secrets/country_agent_token:ro
YAML
docker compose -f "$COMPOSE" -f "$BASE/country-override.yaml" config -q
echo "Stopping Web UI briefly to take a consistent application data backup..."
docker stop "$CONTAINER" >/dev/null
if ! docker cp "$CONTAINER:/app/data" "$BACKUP/data"; then
  docker start "$CONTAINER" >/dev/null || true
  echo "Data backup failed. Existing UI restarted; deployment aborted." >&2
  exit 1
fi
docker start "$CONTAINER" >/dev/null
# Apply the image override without altering the original Compose file.
echo "Deploying customized Web UI..."
if ! docker compose -f "$COMPOSE" -f "$BASE/country-override.yaml" up -d --no-deps --force-recreate "$SERVICE"; then
  echo "Deployment failed; restoring original image and database..." >&2
  bash "$TMP/repo/deploy/rollback-authentik2.sh" "$BACKUP" || true
  exit 1
fi
HEALTHY=0
for try in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:13000/api/health >/dev/null 2>&1; then HEALTHY=1; break; fi
  sleep 2
done
if [ "$HEALTHY" -ne 1 ]; then
  echo "New dashboard unhealthy; restoring original image and database..." >&2
  bash "$TMP/repo/deploy/rollback-authentik2.sh" "$BACKUP" || true
  exit 1
fi
echo "Web UI health OK; existing Gigahost SSH tunnel serves both monitoring and country blocking."
echo "Deployment commit: $REV"
echo "Backup path: $BACKUP"
echo "Open https://crowdsec.4n6.af and select Country Blocking."
