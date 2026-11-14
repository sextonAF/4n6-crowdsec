# 4N6 Country Agent — read-only preview API (development only)

**No firewall modification capability exists in this package.** No network download, subprocess, nftables writes, or disk writes are performed. Do not install it on a production server until its authentication, isolation, feed lifecycle, and integration have been reviewed.

## Offline CLI

```bash
cd agent
python3 -m country_agent preview --country CN --ipv4 china-v4.txt --ipv6 china-v6.txt
python3 -m unittest discover -s tests -v
```

Input validation requires canonical global IPv4 and IPv6 CIDRs and rejects malformed, oversized, empty, wrong-family, or non-global feeds, and unknown country codes. A supplied feed is **not** independently authenticated or proven fresh.

## Development-only HTTP API

```bash
cd agent
install -d -m 700 ./local-secrets
python3 -c 'import secrets; from pathlib import Path; p=Path("local-secrets/token"); p.write_text(secrets.token_hex(32)); p.chmod(0o600)'
python3 -m country_agent serve --bind 127.0.0.1 --port 14110 --token-file ./local-secrets/token --feeds ./sample-feeds --server-id gigahost-no
```

The `sample-feeds` directory must exist and contain `CN.ipv4.txt` and `CN.ipv6.txt` (and corresponding files for any other country to preview). No feed fetcher is included. Do not commit those files if their distribution terms prohibit it.

Requests must use `Authorization: Bearer <token>`; responses contain no token. Endpoints:

- `GET /v1/status` -> `{server_id,mode:"preview-only",enforcement_enabled:false,applied:false,agent_version:1}`
- `POST /v1/preview` with `{"country":"CN"}` -> dry-run feed metadata for both IP families.
- All write methods return 405. There is no apply endpoint.

**Security limitations:** bearer authentication over plaintext HTTP is safe only over trusted loopback; do not expose, proxy to the public internet, or publish the token. Avoid deploying the agent with a privileged account. This basic API is NOT yet hardened or connected to Web UI, and should remain unused on Gigahost.

## Work remaining

- Design a separate mutually authenticated, encrypted connection between Web UI and the agent.
- Bind frontend status/preview to appropriately authorized backend endpoints.
- Add verified, licensed, refreshed country feed ingestion (both IP families; update/expiry checks).
- Inspect the real Gigahost nftables/opengov_guard/GlobaLeaks/Tor topology.
- Build tightly constrained, atomic nftables enforcement with restore/rollback and boot safety.
- Add end-to-end security tests and approve a separate production deployment.
