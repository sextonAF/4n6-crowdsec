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
    # Remove only our forwarding drop-in, restoring the existing SSH tunnel.
    TUNNEL=crowdsec-gigahost-tunnel.service
    DROPIN="/etc/systemd/system/$TUNNEL.d/90-4n6-country-forward.conf"
    if [ -f "$BACKUP/tunnel-service.before.txt" ]; then
      if [ -f "$BACKUP/tunnel-dropin.before" ]; then
        cp -a "$BACKUP/tunnel-dropin.before" "$DROPIN"
      else
        rm -f "$DROPIN"
      fi
      systemctl daemon-reload
      if ! systemctl restart "$TUNNEL"; then
        echo "Original Web UI restored, but SSH tunnel restart failed; inspect $TUNNEL" >&2
        exit 1
      fi
    fi
    echo "Previous UI restored; existing SSH tunnel configuration restored; Gigahost firewall policy unchanged."
    exit 0
  fi
  sleep 2
done
echo "Rollback completed but health not confirmed; check docker logs crowdsec_web_ui" >&2
exit 1
