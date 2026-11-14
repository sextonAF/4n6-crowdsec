# 4N6 CrowdSec — Country Blocking

Status: Design specification; **not deployed**.

## Goal

Add a **Country Blocking** management page to the existing CrowdSec Web UI for per-server, inbound GeoIP blocking, initially China (CN) on Gigahost. The policy must cover all **direct inbound** server ports (not just web routes), both IPv4 and IPv6, and remain separate from CrowdSec's detection and existing nftables bouncer.

## GUI

- Navigation: **Country Blocking**.
- Server selector: only explicitly configured servers; no implicit combined/broadcast action.
- Per-server enabled/disabled state, selected ISO 3166-1 alpha-2 country codes, and effective status.
- Country list with search and add/remove, plus pending-change review.
- **Preview Changes** must show country codes, IPv4/IPv6 CIDR counts, source, refresh timestamp, and estimated impact, without changing the firewall.
- **Apply** requires explicit confirmation and a server acknowledgement; failure leaves the last known-good policy intact.
- Show enforcement status, last update, error details, and audit log; distinguish desired policy from verified applied policy.
- Provide a **Disable country blocking** action with confirmation and rollback; never conflate this with stopping CrowdSec.

## Remote firewall agent (separate, least-privilege service)

- The CrowdSec LAPI watcher credentials are **not** firewall administration credentials. Do not reuse them for this feature.
- Use a separately authenticated, encrypted management channel. Do not expose a management API directly on a public interface; prefer an outbound-only agent connection or an SSH-restricted private connection.
- Use allowlisted commands/actions, strict server identity, authorization, input validation and an audit trail.
- GeoIP range inputs must be independently validated as CIDRs; reject unsupported country codes, unexpected sizes, empty/stale feeds and source failures.
- Apply policies atomically with nftables set swaps and rollback to a previously verified set on failure.
- Preserve existing firewall tables/chains and CrowdSec bouncer sets. **Never issue `nft flush ruleset`**.
- A watchdog and a local recovery procedure must protect administrative access if the agent stops or network connectivity changes.
- No firewall writes are allowed from the Web UI process directly.

## Gigahost integration constraints (mandatory validation before implementation)

- Inspect `opengov-guard.service`, `table inet opengov_guard`, ordering, NAT redirect for GlobaLeaks 80→8080 and 443→8443, systemd service startup, SSH port 22, IPv4/IPv6 and CrowdSec bouncer sets.
- Preserve Tor onion functionality and GlobaLeaks availability. Blocking direct-source country IPs is not equivalent to identifying the originating country behind a Tor or reverse proxy connection.
- Inspect effective nftables hook priority, chain processing, existing established-connection behavior, remote maintenance/update paths, and recovery console access before selecting rule placement.
- Treat geolocation as an estimate: VPNs/proxies and imperfect registry data can bypass or misclassify blocks.
- Start in dry-run mode; never apply a live country block during a UI build or without explicit deployment approval.

## Acceptance tests

1. Authenticated administrator can preview CN for exactly one server; read-only users cannot apply changes.
2. Unauthenticated requests cannot read sensitive agent state or modify the firewall.
3. An unauthorized server selection is rejected server-side.
4. Simulated agent timeout or invalid GeoIP feed leaves last-good policy unchanged.
5. No duplicate rules/sets on repeat apply; removal is idempotent.
6. IPv4 and IPv6 packets in a controlled test set are dropped without disrupting an existing SSH admin session or GlobaLeaks.
7. Server boot and agent restarts restore only the last confirmed policy.
8. UI reports effective enforcement only after a real agent acknowledgement.
9. Existing CrowdSec decisions, login, alerts, and dashboard remain unchanged.
10. Deployment and rollback are independently tested before enabling on Gigahost.

## Development sequence

1. Inspect current frontend navigation, routing, authentication and backend APIs.
2. Implement UI and backend contracts with a mock/test agent (no privileged commands).
3. Add isolated agent with configuration validation, dry-run, rollback, telemetry, authentication and tests.
4. Test end-to-end on a disposable nftables test environment.
5. Perform read-only Gigahost firewall inspection, prepare a backed-up change, and deploy only when approved.
