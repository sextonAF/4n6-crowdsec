"""Pure offline GeoIP CIDR policy validation. No firewall or network access."""
from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from ipaddress import ip_network
from pathlib import Path
import re

# Allowed ISO 3166-1 alpha-2 country codes, pinned for predictable validation.
COUNTRY_CODES = frozenset("""AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW""".split())
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_LINES = 250_000
MAX_NETWORKS = 150_000


class PolicyValidationError(ValueError):
    pass


@dataclass(frozen=True)
class FamilyPreview:
    version: int
    cidrs: tuple[str, ...]
    digest: str

    def as_dict(self, include_ranges=False):
        value = {"family": self.version, "cidr_count": len(self.cidrs),
                 "source_sha256": self.digest}
        if include_ranges:
            value["cidrs"] = list(self.cidrs)
        return value


def validate_country(code: str) -> str:
    if not isinstance(code, str) or not re.fullmatch(r"[A-Z]{2}", code) or code not in COUNTRY_CODES:
        raise PolicyValidationError("Invalid ISO 3166-1 alpha-2 country code")
    return code


def parse_feed(content: bytes, family: int, *, allow_empty: bool = False) -> FamilyPreview:
    if family not in (4, 6):
        raise PolicyValidationError("IP family must be 4 or 6")
    if not content or len(content) > MAX_FILE_BYTES:
        raise PolicyValidationError("Empty or oversized feed")
    try:
        lines = content.decode("ascii").splitlines()
    except UnicodeDecodeError as exc:
        raise PolicyValidationError("Non-ASCII feed") from exc
    if len(lines) > MAX_LINES:
        raise PolicyValidationError("Too many input lines")
    networks = set()
    for number, raw in enumerate(lines, 1):
        cidr = raw.strip()
        if not cidr or cidr.startswith("#"):
            continue
        if not re.fullmatch(r"[0-9a-fA-F:.]+/[0-9]{1,3}", cidr):
            raise PolicyValidationError(f"Invalid CIDR syntax at line {number}")
        try:
            network = ip_network(cidr, strict=True)
        except ValueError as exc:
            raise PolicyValidationError(f"Invalid CIDR at line {number}") from exc
        if network.version != family or network.prefixlen == 0 or not network.is_global:
            raise PolicyValidationError(f"Unsafe or wrong-family range at line {number}")
        networks.add(network)
        if len(networks) > MAX_NETWORKS:
            raise PolicyValidationError("Excessive number of ranges")
    if not networks and not allow_empty:
        raise PolicyValidationError("Feed has no valid ranges")
    ordered = tuple(str(n) for n in sorted(networks, key=lambda n: (int(n.network_address), n.prefixlen)))
    return FamilyPreview(family, ordered, sha256(content).hexdigest())


def preview(country: str, ipv4_source: bytes, ipv6_source: bytes, include_ranges=False):
    code = validate_country(country)
    v4 = parse_feed(ipv4_source, 4)
    v6 = parse_feed(ipv6_source, 6)
    return {"country": code, "dry_run": True, "applied": False,
            "ipv4": v4.as_dict(include_ranges), "ipv6": v6.as_dict(include_ranges)}


def preview_from_files(country: str, ipv4_path: Path, ipv6_path: Path, include_ranges=False):
    def read_bounded(path: Path):
        with path.open("rb") as source:
            contents = source.read(MAX_FILE_BYTES + 1)
        if len(contents) > MAX_FILE_BYTES:
            raise PolicyValidationError("Oversized feed")
        return contents
    return preview(country, read_bounded(ipv4_path), read_bounded(ipv6_path), include_ranges)
