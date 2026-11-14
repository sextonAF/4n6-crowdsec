#!/usr/bin/env bash
# Restore the original CrowdSec Web UI image and saved application database.
set -Eeuo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
BACKUP="${1:-}"
[ -n "$BACKUP" ] && [ -f "$BACKUP/container-before.json" ] && [ -d "$BACKUP/data" ] || {
  echo "Usage: sudo bash rollback-authentik2.sh /opt/crowdsec-web-ui/backups/country-TIMESTAMP" >&2
  exit 1
}
BASE=/opt/crowdsec-web-ui
COMPOSE="$BASE/compose.yaml"
STAMP="${BACKUP##*/country-}"
IMAGE="4n6-crowdsec:rollback-$STAMP"
docker image inspect "$IMAGE" >/dev/null || { echo "Rollback image not present: $IMAGE" >&2; exit 1; }
SERVICE="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' crowdsec_web_ui)"
test -n "$SERVICE"
cat > "$BACKUP/rollback-override.yaml" <<YAML
services:
  $SERVICE:
    image: $IMAGE
YAML
# Exclude the new country override. Restore previous override only if it existed.
if [ -f "$BACKUP/country-override.yaml" ]; then
  cp -a "$BACKUP/country-override.yaml" "$BASE/country-override.yaml"
else
  rm -f "$BASE/country-override.yaml"
fi
docker compose -f "$COMPOSE" -f "$BACKUP/rollback-override.yaml" up -d --no-deps --force-recreate "$SERVICE"
docker stop crowdsec_web_ui >/dev/null
docker cp "$BACKUP/data/." crowdsec_web_ui:/app/data/
docker start crowdsec_web_ui >/dev/null
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:13000/api/health >/dev/null 2>&1; then
    echo "Previous UI restored and healthy. Existing firewall selections on Gigahost are independent."
    exit 0
  fi
  sleep 2
done
echo "Rollback completed but health not confirmed; check docker logs crowdsec_web_ui" >&2
exit 1
