#!/usr/bin/env bash
# Deploy ONLY the already-implemented country-blocking dashboard feature.
# No SSH tunnel, Gigahost firewall, CrowdSec, or original Compose file changes.
set -Eeuo pipefail
[ "$(id -u)" = 0 ] || { echo "Run using sudo" >&2; exit 1; }
[ "$(hostname -s)" = authentik2 ] || { echo "Wrong host" >&2; exit 1; }
BASE=/opt/crowdsec-web-ui
COMPOSE="$BASE/compose.yaml"
OVERRIDE="$BASE/country-override.yaml"
SECRETS="$BASE/secrets"
CONTAINER=crowdsec_web_ui
SERVICE=crowdsec-web-ui
AGENT=http://172.21.0.1:18083
TOKEN="$FOURN6_AGENT_TOKEN"
[ -n "$TOKEN" ] && [ "$(printf %s "$TOKEN" | wc -c)" -ge 32 ] || { echo "Missing country agent token" >&2; exit 1; }
test -f "$COMPOSE" || { echo "Original Compose file missing" >&2; exit 1; }
for command in git docker curl python3; do command -v "$command" >/dev/null || { echo "Missing $command" >&2; exit 1; }; done
[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = true ] || { echo "Original UI not running" >&2; exit 1; }
[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER")" = "$SERVICE" ] || { echo "Unexpected Compose service" >&2; exit 1; }
[ "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")" = ghcr.io/theduffman85/crowdsec-web-ui:latest ] || { echo "Original image has changed; refusing automatic deployment" >&2; exit 1; }
[ "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Type}}{{end}}{{end}}' "$CONTAINER")" = volume ] || { echo "Expected existing /app/data Docker volume" >&2; exit 1; }
[ ! -e "$OVERRIDE" ] || { echo "Existing country override needs inspection; refusing overwrite" >&2; exit 1; }
systemctl is-active --quiet crowdsec-gigahost-tunnel.service
ss -H -lnt '( sport = :18082 )' | grep -q 18082
ss -H -lnt '( sport = :18083 )' | grep -q 18083
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $TOKEN" "$AGENT/v1/status")"
[ "$HTTP" = 200 ] || { echo "Country agent authorization failed (HTTP $HTTP); dashboard unchanged" >&2; exit 1; }
curl -fsS --max-time 5 http://127.0.0.1:13000/api/health >/dev/null
echo "Existing UI and both SSH forwards verified. Country agent authorized."
BACKUP="$BASE/backups/country-ui-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
docker inspect "$CONTAINER" > "$BACKUP/container-before.json"
cp -a "$COMPOSE" "$BACKUP/compose-before.yaml"
OLD_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER")"
docker tag "$OLD_ID" "4n6-crowdsec:country-ui-rollback"
echo "Existing image preserved as 4n6-crowdsec:country-ui-rollback"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
git clone -q --depth 1 --branch main https://github.com/sextonAF/4n6-crowdsec.git "$BUILD/repo"
SHA="$(git -C "$BUILD/repo" rev-parse --short=12 HEAD)"
echo "Building country UI image (existing running UI stays online throughout build)..."
docker build --target production -t "4n6-crowdsec:country-ui-$SHA" \
  --build-arg "VITE_COMMIT_HASH=$SHA" \
  --build-arg "VITE_BRANCH=main" \
  "$BUILD/repo"
echo "Build complete. Preparing original data backup."
# Existing UID 1000 is the node user inside the app.
mkdir -p "$SECRETS"
chmod 750 "$SECRETS"
umask 077
printf '%s\n' "$TOKEN" > "$SECRETS/country_agent_token"
printf '%s\n' '{"gigahost-no":{"url":"http://172.21.0.1:18083","token_file":"/run/secrets/country_agent_token"}}' > "$SECRETS/geo_agents.json"
chown root:1000 "$SECRETS/country_agent_token" "$SECRETS/geo_agents.json"
chmod 640 "$SECRETS/country_agent_token" "$SECRETS/geo_agents.json"
cat > "$OVERRIDE" <<YAML
services:
  $SERVICE:
    image: 4n6-crowdsec:country-ui-$SHA
    environment:
      FOURN6_COUNTRY_AGENTS_FILE: /run/secrets/geo_agents.json
    volumes:
      - $SECRETS/geo_agents.json:/run/secrets/geo_agents.json:ro
      - $SECRETS/country_agent_token:/run/secrets/country_agent_token:ro
YAML
if ! docker compose -f "$COMPOSE" -f "$OVERRIDE" config -q; then
  rm -f "$OVERRIDE"
  echo "Compose validation failed; original UI unchanged." >&2
  exit 1
fi
restore() {
  echo "Deployment failed: returning to the previously running image and Compose service." >&2
  rm -f "$OVERRIDE"
  docker compose -f "$COMPOSE" up -d --no-deps --force-recreate "$SERVICE" || true
  echo "Backup retained at $BACKUP" >&2
}
echo "Briefly stopping the dashboard to back up the exact data volume."
docker stop "$CONTAINER" >/dev/null
if ! docker cp "$CONTAINER:/app/data" "$BACKUP/data"; then
  docker start "$CONTAINER" >/dev/null || true
  rm -f "$OVERRIDE"
  echo "Backup failed; original UI restarted. No new image deployed." >&2
  exit 1
fi
docker start "$CONTAINER" >/dev/null
echo "Switching only the CrowdSec Web UI service to the updated image."
if ! docker compose -f "$COMPOSE" -f "$OVERRIDE" up -d --no-deps --force-recreate "$SERVICE"; then
  restore
  exit 1
fi
HEALTHY=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:13000/api/health >/dev/null 2>&1; then
    HEALTHY=1; break
  fi
  sleep 2
done
if [ "$HEALTHY" != 1 ]; then
  restore
  exit 1
fi
echo "SUCCESS: Country-blocking dashboard deployed. Existing data volume preserved."
echo "Backup: $BACKUP"
echo "Existing monitoring SSH connection and Gigahost firewall unchanged."
