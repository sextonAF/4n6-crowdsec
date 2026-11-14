# Country Firewall Agent — offline preview (development only)

This is a **read-only foundation**, not a deployed firewall agent. It performs no network calls, privileged operations, nftables calls, policy persistence, or firewall writes.

With **locally supplied trusted** IPv4/IPv6 CIDR files, use:

```bash
cd agent
python3 -m country_agent --country CN --ipv4 china-v4.txt --ipv6 china-v6.txt
python3 -m unittest discover -s tests -v
```

The preview returns the country, CIDR counts, SHA-256 of both inputs, `dry_run: true` and `applied: false`. `--include-ranges` explicitly lists the ranges.

Input checks reject unknown country codes, wrong-family CIDRs, non-global ranges, blanket /0 networks, empty or missing IPv6, noncanonical CIDRs, malformed lines and oversized files. Deduplicates CIDRs. A preview alone **does not verify the feed's provenance or country attribution**.

**Not implemented:** authoritative/fresh GeoIP feeds, agent authentication, permissions, secure transport, state storage, firewall enforcement, boot/restart persistence, audit logging, safe nftables chain placement, maintenance/rollback and live integration.

Do not install this on Gigahost for enforcement. Review the existing `opengov-guard`/CrowdSec/GlobaLeaks/Tor firewall interactions before adding any write capability.
