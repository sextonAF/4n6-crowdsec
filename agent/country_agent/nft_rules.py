"""Render isolated nftables country-blocking rules; never executes them.

One table, two interval sets, and ingress filters for prerouting and input.
The kernel rule is intentionally before established-connection acceptance:
a blocked source is blocked from all inbound local services regardless of port.
"""
from __future__ import annotations

from collections.abc import Mapping
from ipaddress import ip_network
from .policy import FamilyPreview, PolicyValidationError, validate_country

TABLE = "four_n6_geo"
PRIORITY = -30
MAX_TOTAL_NETWORKS = 250_000

def validate_policy(families: Mapping[str, tuple[FamilyPreview, FamilyPreview]]) -> tuple[tuple[str, ...], tuple[str, ...]]:
    if not families:
        raise PolicyValidationError("At least one country must be selected")
    if len(families) > 249:
        raise PolicyValidationError("Too many countries")
    v4, v6 = set(), set()
    for code, (four, six) in families.items():
        validate_country(code)
        if four.version != 4 or six.version != 6 or (not four.cidrs and not six.cidrs):
            raise PolicyValidationError("Each country requires validated IPv4 and IPv6 ranges")
        for family, preview, target in ((4, four, v4), (6, six, v6)):
            for cidr in preview.cidrs:
                try:
                    network = ip_network(cidr, strict=True)
                except ValueError as exc:
                    raise PolicyValidationError("Invalid network in requested policy") from exc
                if network.version != family or network.prefixlen == 0 or not network.is_global:
                    raise PolicyValidationError("Unsafe range in requested policy")
                target.add(network)
        if len(v4) + len(v6) > MAX_TOTAL_NETWORKS:
            raise PolicyValidationError("Country policy exceeds network count limit")
    if not v4 and not v6:
        raise PolicyValidationError("Country policy contains no public IP ranges")
    return (
        tuple(str(n) for n in sorted(v4, key=lambda n: (int(n.network_address), n.prefixlen))),
        tuple(str(n) for n in sorted(v6, key=lambda n: (int(n.network_address), n.prefixlen))),
    )

def render_table(families: Mapping[str, tuple[FamilyPreview, FamilyPreview]]) -> str:
    """Render only a new standalone table; no flush or foreign table commands."""
    v4, v6 = validate_policy(families)
    def elements(cidrs: tuple[str, ...]) -> str:
        return ",\n            ".join(cidrs)
    return f"""# Generated 4N6 country policy; independent of OpenGov and CrowdSec.
table inet {TABLE} {{
    set blocked_v4 {{
        type ipv4_addr
        flags interval
        auto-merge
        elements = {{
            {elements(v4)}
        }}
    }}
    set blocked_v6 {{
        type ipv6_addr
        flags interval
        auto-merge
        elements = {{
            {elements(v6)}
        }}
    }}
    chain prerouting {{
        type filter hook prerouting priority -310; policy accept;
        ip saddr @blocked_v4 drop
        ip6 saddr @blocked_v6 drop
    }}
    chain input {{
        type filter hook input priority {PRIORITY}; policy accept;
        ip saddr @blocked_v4 drop
        ip6 saddr @blocked_v6 drop
    }}
}}
"""

def render_replace(families: Mapping[str, tuple[FamilyPreview, FamilyPreview]], existing: bool) -> str:
    """An nft -f batch is transactional; delete/recreate only OUR table if present."""
    table = render_table(families)
    return (f"delete table inet {TABLE}\n" if existing else "") + table

def render_disable(existing: bool) -> str:
    """Disable managed blocking without touching any other nftables table."""
    return f"delete table inet {TABLE}\n" if existing else "# 4N6 country blocking already disabled\n"
