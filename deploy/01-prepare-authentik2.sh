#!/usr/bin/env bash
# Stage 1 of country-blocking deployment: run as root on authentik2.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run using sudo bash" >&2; exit 1; }
D=/opt/crowdsec-web-ui/secrets
test -d /opt/crowdsec-web-ui || { echo "Existing Web UI directory missing" >&2; exit 1; }
install -d -m 750 "$D"
if [ ! -f "$D/country_tunnel" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$D/country_tunnel" -C '4n6-country-agent'
  chmod 600 "$D/country_tunnel"
fi
echo
echo "Copy this one public key into the Gigahost installation prompt:"
cat "$D/country_tunnel.pub"
echo
echo "Private key stays on authentik2; do not copy it or post it in chat."
