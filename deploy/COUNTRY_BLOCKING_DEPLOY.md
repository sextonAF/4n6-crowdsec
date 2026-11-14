# Country Blocking — installation and rollback

**Scope:** Dedicated nftables table that drops inbound source ranges matching administrator-selected countries. Covers IPv4 and IPv6, all host ports, packets before DNAT, and forwarded container connections. No application exemptions; blocks are controlled through **Country Blocking** in the Web UI. Other nftables tables remain unchanged.

Source for ranges: [ipverse/geo-ip-blocks](https://github.com/ipverse/geo-ip-blocks), CC0, updated daily. Network registration country is approximate, not guaranteed physical source location. VPN/Tor/proxies may mask the true originating country. CIDR lists are downloaded using HTTPS, validated, and reloaded automatically by a systemd timer.

## Three-stage deployment using the existing CrowdSec SSH tunnel

### 1. On authentik2

As a sudo-capable user, run:

```bash
TMP="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/sextonAF/4n6-crowdsec/main/deploy/01-prepare-authentik2.sh -o "$TMP"
bash -n "$TMP" && sudo bash "$TMP"
rm -f "$TMP"
```

This is **read-only**: it inspects the already-running `crowdsec-gigahost-tunnel.service`, identifies the SSH key already being used and displays only its **public key**. It does not generate a key, create an account or start a tunnel. Copy that existing public key for the next command. If the existing service differs from the expected setup, the inspection stops instead of guessing.

### 2. On Gigahost (root@srv19210)

```bash
TMP="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/sextonAF/4n6-crowdsec/feature/country-blocking/deploy/02-install-gigahost.sh -o "$TMP"
bash -n "$TMP" && bash "$TMP"
rm -f "$TMP"
```

Paste the **existing** public key when prompted. The script matches that key to its existing Gigahost SSH account, preserving the existing authorized-key entry and its existing `8081` forwarding permission. Where the existing key uses `permitopen`, the script adds permission to reach `127.0.0.1:14110` without replacing any earlier entries. It does **not** create a second SSH account. It installs the authenticated, loopback-bound agent, boot restore unit and daily source refresh timer. It backs up pre-install rules and service files locally. **It does not enable any country blocks.** At the end it prints an agent token—copy it privately for the next command; never post it publicly.

### 3. Back on authentik2

```bash
TMP="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/sextonAF/4n6-crowdsec/feature/country-blocking/deploy/03-deploy-authentik2.sh -o "$TMP"
bash -n "$TMP" && sudo bash "$TMP"
rm -f "$TMP"
```

The script prompts for the CrowdSec instance ID (normally `gigahost-no`) and for the agent token using hidden input. It builds the customized image, preserves the existing Compose file, creates an isolated override and backs up the running app's data while stopped. It adds a **second local port-forward to the existing SSH tunnel service**, briefly restarting that same connection while preserving the original CrowdSec forwarding configuration. It verifies both old (`18082`) and new (`18083`) forwarding ports, then deploys the Web UI and probes its health. If the existing SSH service is not a directly inspectable `ssh -N` tunnel, the script stops rather than creating an alternative connection. It does not edit the OpenGov or CrowdSec firewall tables.

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
- The agent listens only on `127.0.0.1:14110` on Gigahost. Remote access uses the **existing CrowdSec SSH connection** with an additional forward to `172.21.0.1:18083` on authentik2; the original `18082` CrowdSec LAPI forward remains in place. No public management port is opened.
- The authorization token is kept in private files on both servers. CrowdSec LAPI credentials are not reused for firewall operations.
- Blocks are applied at nftables `inet` `prerouting` priority `-310` and `input` priority `-30`. This intercepts direct inbound traffic ahead of OpenGov and CrowdSec, even if the destination is GlobaLeaks, SSH or a forwarded container.
- Country blocks can terminate your own remote SSH if the connecting address falls in the selected range. The recovery method is server-console access and the emergency unblock script.
- Check `systemctl status 4n6-country-agent.service` on Gigahost and `systemctl status crowdsec-gigahost-tunnel.service` on authentik2 if agent connection fails.
- Check effective `nft list table inet four_n6_geo` on Gigahost after a successful Apply.
- The feature is per-server. Every additional server needs its own independently configured agent and dedicated token. An existing authenticated tunnel can be reused for additional forwards where its configuration and permissions permit.
- Never treat unverified / stale source data as evidence of a successful new block. Failures must leave the previously saved policy in place, and the GUI displays errors.
