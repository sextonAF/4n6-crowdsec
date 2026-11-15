#!/usr/bin/env bash
# Deploy only compiled client files, layered over existing dashboard image.
set -Eeuo pipefail
[ "$(id -u)" = 0 ] && [ "$(hostname -s)" = authentik2 ] || { echo "Run as root on authentik2"; exit 1; }
BASE=/opt/crowdsec-web-ui
COMPOSE="$BASE/compose.yaml"
OVERRIDE="$BASE/country-override.yaml"
SERVICE=crowdsec-web-ui
CONTAINER=crowdsec_web_ui
RELEASE=ac3288cfb6ad214422aa800f53ccb738a7270a1d
for cmd in git docker curl python3 sha256sum; do command -v "$cmd" >/dev/null || exit 1; done
test -f "$COMPOSE" && test -f "$OVERRIDE"
[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = true ]
OLD_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")"
case "$OLD_IMAGE" in 4n6-crowdsec:country-ui-*) ;; *) echo "Unexpected original image"; exit 1;; esac
OLD_REV="$(printf '%s' "$OLD_IMAGE" | sed 's/.*-//')"
curl -fsS --max-time 5 http://127.0.0.1:13000/api/health >/dev/null
BACKUP="$(mktemp -d "$BASE/backups/ip-ban-frontend-XXXXXXXX")"
chmod 700 "$BACKUP"
cp -a "$OVERRIDE" "$BACKUP/original-override.yaml"
docker inspect "$CONTAINER" > "$BACKUP/original-container.json"
BUILD="$(mktemp -d)"
STAGING="crowdsec-ipban-build-$$"
SWITCHED=0
cleanup() { docker rm -f "$STAGING" >/dev/null 2>&1 || true; rm -rf "$BUILD"; }
rollback() {
  trap - ERR
  if [ "$SWITCHED" = 1 ]; then
    cp -a "$BACKUP/original-override.yaml" "$OVERRIDE"
    docker compose -f "$COMPOSE" -f "$OVERRIDE" up -d --no-deps --force-recreate "$SERVICE" || true
    echo "Dashboard original restored." >&2
  fi
}
trap rollback ERR
trap cleanup EXIT
echo "Checking PR #19 top-row-only layout change..."
git clone -q --depth 30 https://github.com/sextonAF/4n6-crowdsec.git "$BUILD/repo"
cd "$BUILD/repo"
git cat-file -e "$RELEASE^{commit}" || { echo "Requested frontend release missing"; exit 1; }
git checkout -q --detach "$RELEASE"
git cat-file -e "$OLD_REV^{commit}" || { echo "Installed revision not found in source history"; exit 1; }
git diff --quiet "$OLD_REV" "$RELEASE" -- server shared package.json pnpm-lock.yaml pnpm-workspace.yaml scripts tsup.config.ts || { echo "Backend or dependency changes detected. Stopping"; exit 1; }
test -f client/src/pages/BannedIPs.tsx
python3 - "$OVERRIDE" "$OLD_IMAGE" <<'PY'
from pathlib import Path
import sys
data=Path(sys.argv[1]).read_text()
assert data.count("image: "+sys.argv[2])==1
assert "FOURN6_COUNTRY_AGENTS_FILE" in data
PY
echo "Compiling only frontend assets; existing site remains online..."
docker run --rm -v "$BUILD/repo:/work" -w /work node:24.22.2-trixie-slim sh -ec 'npm install -g --silent pnpm@12.16.1 && pnpm install --frozen-lockfile --silent && pnpm exec vite build'
test -s dist/client/index.html
test -d dist/client/assets
NEW_IMAGE="4n6-crowdsec:country-ui-$(printf '%s' "$RELEASE" | cut -c 1-12)"
docker create --name "$STAGING" "$OLD_IMAGE" >/dev/null
docker cp "$BUILD/repo/dist/client/." "$STAGING:/app/dist/client/"
docker commit "$STAGING" "$NEW_IMAGE" >/dev/null
docker rm "$STAGING" >/dev/null
python3 - "$OVERRIDE" "$OLD_IMAGE" "$NEW_IMAGE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
d=p.read_text()
old="image: "+sys.argv[2]
assert d.count(old)==1
tmp=p.with_suffix(".frontend-new")
tmp.write_text(d.replace(old,"image: "+sys.argv[3],1))
tmp.replace(p)
PY
SWITCHED=1
docker compose -f "$COMPOSE" -f "$OVERRIDE" config -q
docker compose -f "$COMPOSE" -f "$OVERRIDE" up -d --no-deps --force-recreate "$SERVICE"
HEALTHY=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 4 http://127.0.0.1:13000/api/health >/dev/null 2>&1; then HEALTHY=1; break; fi
  sleep 2
done
[ "$HEALTHY" = 1 ] || { echo "Health failed"; false; }
DEPLOYED="$(docker exec "$CONTAINER" sha256sum /app/dist/client/index.html | awk '{print $1}')"
BUILT="$(sha256sum dist/client/index.html | awk '{print $1}')"
[ "$DEPLOYED" = "$BUILT" ] || { echo "Asset checksum mismatch"; false; }
SWITCHED=0
echo "SUCCESS: PR #19 top-row layout deployed without a full image rebuild."
echo "Backend, firewall and database unchanged. Backup: $BACKUP"
