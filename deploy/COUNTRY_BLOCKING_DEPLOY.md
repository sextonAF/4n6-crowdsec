# Country Blocking — installation and rollback

**Scope:** Dedicated nftables table that drops inbound source ranges matching administrator-selected countries. Covers IPv4 and IPv6, all host ports, packets before DNAT, and forwarded container connections. No application exemptions; blocks are controlled through **Country Blocking** in the Web UI. Other nftables tables remain unchanged.

Source for ranges: [ipverse/geo-ip-blocks](https://github.com/ipverse/geo-ip-blocks), CC0, updated daily. Network registration country is approximate, not guaranteed physical source location. VPN/Tor/proxies may mask the true originating country. CIDR lists are downloaded using HTTPS, validated, and reloaded automatically by a systemd timer.

## Three-stage deployment (two different servers)

### 1. On authentik2

As a sudo-capable user, run:

```bash
TMP="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/sextonAF/4n6-crowdsec/feature/country-blocking/deploy/01-prepare-authentik2.sh -o "$TMP"
bash -n "$TMP" && sudo bash "$TMP"
rm -f "$TMP"
```

This creates a dedicated SSH key and prints **only its public key**. Copy that public key for the next command. Do not disclose the private key.

### 2. On Gigahost (root@srv19210)

```bash
TMP="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/sextonAF/4n6-crowdsec/feature/country-blocking/deploy/02-install-gigahost.sh -o "$TMP"
bash -n "$TMP" && bash "$TMP"
rm -f "$TMP"
```

Paste the public key when prompted. The script installs an authenticated, loopback-bound agent, dedicated restricted SSH forwarding account, boot restore unit and daily source refresh timer. It backs up pre-install rules and service files locally. **It does not enable any country blocks.** At the end it prints an agent token—copy it privately for the next command; never post it publicly.

### 3. Back on authentik2

```bash
TMP="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/sextonAF/4n6-crowdsec/feature/country-blocking/deploy/03-deploy-authentik2.sh -o "$TMP"
bash -n "$TMP" && sudo bash "$TMP"
rm -f "$TMP"
```

The script prompts for the CrowdSec instance ID (normally `gigahost-no`) and for the agent token using hidden input. It builds the customized image, preserves the existing Compose file, creates an isolated override, backs up the running app's data while stopped, establishes a dedicated encrypted SSH tunnel, then deploys and probes its health. It does not edit the OpenGov or CrowdSec firewall tables.

After successful deployment, sign in to https://crowdsec.4n6.af, open **Country Blocking**, choose Gigahost and the country (e.g. China), then **Preview changes** and **Apply to server**. The page makes a fresh read-after-write verification request to the agent. Removing all countries disables this managed firewall table.

## Rollback

Web UI restore on authentik2 (replace with path printed during deployment):

```bash
bash deploy/rollback-authentik2.sh /opt/crowdsec-web-ui/backups/country-YYYYMMDDTHHMMSSZ
```

Emergency remove of **all managed country restrictions** on Gigahost:

```bash
bash deploy/disable-gigahost-country-blocks.sh
```

If using the raw GitHub-hosted scripts, download each script to a temporary file and syntax-check it, as in the installation commands. The Web UI rollback and firewall emergency disable are independent. Reverting the Web UI does **not** implicitly remove firewall restrictions; this prevents accidental surprise unblock during a dashboard restore.

## Operational notes

- Never enable `nftables.service` on Gigahost; the existing `/etc/nftables.conf` can flush the live firewall.
- The agent listens only on `127.0.0.1:14110` on Gigahost. Remote access is through a dedicated encrypted, key-authenticated SSH forward to `172.21.0.1:18083` on authentik2. No public management port is opened.
- The authorization token is kept in private files on both servers. CrowdSec LAPI credentials are not reused for firewall operations.
- Blocks are applied at nftables `inet` `prerouting` priority `-310` and `input` priority `-30`. This intercepts direct inbound traffic ahead of OpenGov and CrowdSec, even if the destination is GlobaLeaks, SSH or a forwarded container.
- Country blocks can terminate your own remote SSH if the connecting address falls in the selected range. The recovery method is server-console access and the emergency unblock script.
- Check `systemctl status 4n6-country-agent.service` and `systemctl status 4n6-country-tunnel.service` if agent connection fails.
- Check effective `nft list table inet four_n6_geo` on Gigahost after a successful Apply.
- The feature is per-server. Every additional server needs its own independently configured agent and dedicated token/tunnel.
- Never treat unverified / stale source data as evidence of a successful new block. Failures must leave the previously saved policy in place, and the GUI displays errors.
