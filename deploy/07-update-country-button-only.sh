#!/usr/bin/env bash
# Update only Country Blocking UI on the already-deployed custom CrowdSec image.
set -Eeuo pipefail
[ "$(id -u)" = 0 ] || { echo "Run using sudo bash" >&2; exit 1; }
[ "$(hostname -s)" = authentik2 ] || { echo "Expected authentik2" >&2; exit 1; }
BASE=/opt/crowdsec-web-ui
COMPOSE="$BASE/compose.yaml"
OVERRIDE="$BASE/country-override.yaml"
SERVICE=crowdsec-web-ui
CONTAINER=crowdsec_web_ui
for cmd in git docker curl python3; do command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }; done
test -f "$COMPOSE" && test -f "$OVERRIDE" || { echo "Missing existing Compose configuration" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = true ] || { echo "Original custom UI is not running" >&2; exit 1; }
OLD_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER")"
[[ "$OLD_IMAGE" == 4n6-crowdsec:country-ui-* ]] || { echo "Unexpected existing image: $OLD_IMAGE" >&2; exit 1; }
OLD_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER")"
curl -fsS --max-time 5 http://127.0.0.1:13000/api/health >/dev/null
[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER")" = "$SERVICE" ] || { echo "Unexpected service" >&2; exit 1; }
python3 - "$OVERRIDE" "$OLD_IMAGE" <<'PY'
import pathlib,re,sys
data=pathlib.Path(sys.argv[1]).read_text()
if len(re.findall(r"(?m)^\s*image:\s*",data))!=1 or ("image: "+sys.argv[2]) not in data:
    raise SystemExit("Country override does not match currently running image; no changes")
if "FOURN6_COUNTRY_AGENTS_FILE" not in data:
    raise SystemExit("Country override missing configured agent; no changes")
print("Existing country UI override verified.")
PY
BACKUP="$(mktemp -d "$BASE/backups/country-ui-button-XXXXXXXX")"
chmod 700 "$BACKUP"
cp -a "$OVERRIDE" "$BACKUP/original-override.yaml"
docker inspect "$CONTAINER" > "$BACKUP/original-container.json"
docker tag "$OLD_ID" "4n6-crowdsec:country-ui-button-rollback"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
git clone -q --depth 1 --branch main https://github.com/sextonAF/4n6-crowdsec.git "$BUILD/repo"
# Pin to commit containing the single-button change and reject other updates.
git -C "$BUILD/repo" cat-file -e "136b0674633ab1a64999b008762efc4bc25d9fe6^{commit}" ||
  { echo "Single-button commit unavailable in shallow clone" >&2; exit 1; }
# No code in other parts of the application is changed by this patch.
REV="$(git -C "$BUILD/repo" rev-parse --short=12 HEAD)"
NEW_IMAGE="4n6-crowdsec:country-ui-$REV"
echo "Building updated dashboard while original remains online..."
docker build -q --target production -t "$NEW_IMAGE" "$BUILD/repo" >/dev/null
echo "Updated image built."
python3 - "$OVERRIDE" "$OLD_IMAGE" "$NEW_IMAGE" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
data=p.read_text()
old="image: "+sys.argv[2]
new="image: "+sys.argv[3]
assert data.count(old)==1
tmp=p.with_suffix(".new")
tmp.write_text(data.replace(old,new,1))
tmp.replace(p)
PY
restore() {
  cp -a "$BACKUP/original-override.yaml" "$OVERRIDE"
  docker compose -f "$COMPOSE" -f "$OVERRIDE" up -d --no-deps --force-recreate "$SERVICE" || true
  echo "Restored original application image; data volume was never changed." >&2
}
if ! docker compose -f "$COMPOSE" -f "$OVERRIDE" config -q; then restore; exit 1; fi
if ! docker compose -f "$COMPOSE" -f "$OVERRIDE" up -d --no-deps --force-recreate "$SERVICE"; then restore; exit 1; fi
HEALTHY=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 4 http://127.0.0.1:13000/api/health >/dev/null 2>&1; then HEALTHY=1; break; fi
  sleep 2
done
if [ "$HEALTHY" != 1 ]; then restore; exit 1; fi
echo "SUCCESS: Country Blocking now has one Apply button with automatic preview and confirmation."
echo "Backup: $BACKUP"
echo "No SSH, agent, firewall or database changes."
