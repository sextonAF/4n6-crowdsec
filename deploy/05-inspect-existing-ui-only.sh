#!/usr/bin/env bash
# Read-only inspection of the existing CrowdSec Web UI for a minimal country-blocking UI update.
set -u
[ "$(id -u)" -eq 0 ] || { echo "Run using sudo bash" >&2; exit 1; }
echo "=== WEB UI CONTAINER (NO CHANGES) ==="
if ! docker inspect crowdsec_web_ui >/dev/null 2>&1; then
  echo "No container named crowdsec_web_ui"; exit 1
fi
docker inspect -f 'Container={{.Name}} State={{.State.Status}} Image={{.Config.Image}} ImageID={{.Image}}' crowdsec_web_ui
docker inspect -f 'ComposeService={{index .Config.Labels "com.docker.compose.service"}}' crowdsec_web_ui
docker inspect -f 'ComposeProject={{index .Config.Labels "com.docker.compose.project"}}' crowdsec_web_ui
docker inspect -f 'ComposeFiles={{index .Config.Labels "com.docker.compose.project.config_files"}}' crowdsec_web_ui
docker inspect -f 'ComposeWorkingDir={{index .Config.Labels "com.docker.compose.project.working_dir"}}' crowdsec_web_ui
docker inspect -f 'User={{.Config.User}} Entrypoint={{json .Config.Entrypoint}} Cmd={{json .Config.Cmd}}' crowdsec_web_ui
echo
echo "=== MOUNTS (PATHS ONLY; NO FILE CONTENTS) ==="
docker inspect -f '{{range .Mounts}}{{println .Type .Source "=>" .Destination "rw=" .RW}}{{end}}' crowdsec_web_ui
echo
echo "=== BINDINGS AND NETWORK (NO CREDENTIALS) ==="
docker inspect -f '{{json .HostConfig.PortBindings}}' crowdsec_web_ui
docker inspect -f '{{range $name,$network := .NetworkSettings.Networks}}{{println $name "gateway=" $network.Gateway "ip=" $network.IPAddress}}{{end}}' crowdsec_web_ui
echo
echo "=== EXISTING WEB UI HEALTH ==="
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 http://127.0.0.1:13000/api/health || true
echo
echo "=== EXISTING SSH FORWARDS ==="
ss -H -lnt '( sport = :18082 or sport = :18083 )' || true
echo
echo "=== COUNTRY FORWARD REACHABILITY (NO TOKEN) ==="
curl -sS -o /dev/null -w 'Agent HTTP %{http_code}\n' --max-time 5 http://172.21.0.1:18083/v1/status || true
echo
echo "=== EXISTING DASHBOARD FEATURE ==="
curl -sS -o /dev/null -w 'Country API HTTP %{http_code}\n' --max-time 5 http://127.0.0.1:13000/api/country-blocking/gigahost-no/status || true
echo
echo "Inspection complete. No files or services changed. No secrets printed."
