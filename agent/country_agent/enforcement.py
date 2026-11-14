"""Trusted source acquisition and atomic, persistent nftables updates.

This module deliberately controls only table inet four_n6_geo.
"""
from __future__ import annotations
import fcntl
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen
from .policy import PolicyValidationError, parse_feed, validate_country
from .nft_rules import TABLE, render_replace, render_disable, validate_policy

SOURCE = "https://raw.githubusercontent.com/ipverse/geo-ip-blocks/master/country"
MAX_COUNTRIES = 30
MAX_DOWNLOAD = 16 * 1024 * 1024
REFRESH_HOURS = 24

def normalize_countries(value):
    if not isinstance(value, list) or len(value) > MAX_COUNTRIES:
        raise PolicyValidationError("Expected an array of at most 30 countries")
    if any(not isinstance(x, str) for x in value):
        raise PolicyValidationError("Country code must be a string")
    result = [validate_country(x) for x in value]
    if len(result) != len(set(result)):
        raise PolicyValidationError("Repeated country")
    return sorted(result)

def fetch_ranges(code: str, timeout: int = 20):
    code = validate_country(code)
    result = []
    for version, label in ((4, "ipv4"), (6, "ipv6")):
        address = f"{SOURCE}/{code.lower()}/{code.lower()}-{label}.txt"
        req = Request(address, headers={"User-Agent":"4N6-country-policy/1", "Accept":"text/plain"})
        with urlopen(req, timeout=timeout) as response:
            if response.status != 200 or response.url != address:
                raise PolicyValidationError("Unexpected GeoIP source response")
            data = response.read(MAX_DOWNLOAD + 1)
        result.append(parse_feed(data, version))
    return tuple(result)

def load_policy(directory: Path):
    filename = directory / "policy.json"
    if not filename.is_file():
        return {"countries": [], "updated_at": None}
    obj = json.loads(filename.read_text("utf-8"))
    return {"countries": normalize_countries(obj["countries"]), "updated_at": obj.get("updated_at")}

def write_atomic(path: Path, content: bytes):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".4n6-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        df = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(df)
        finally:
            os.close(df)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def nft_exists():
    result = subprocess.run(["/usr/sbin/nft","list","table","inet",TABLE], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=10, check=False)
    return result.returncode == 0

def execute_batch(rules: str):
    """nft -f executes the whole batch transactionally, not line by line."""
    fd, name = tempfile.mkstemp(prefix="geo-policy-", suffix=".nft", dir="/run")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write(rules)
            stream.flush()
            os.fsync(stream.fileno())
        for opts in (("-c", "-f"), ("-f",)):
            result = subprocess.run(["/usr/sbin/nft", *opts, name], capture_output=True,
                                    text=True, timeout=40, check=False)
            if result.returncode:
                raise RuntimeError(f"nft validation/apply failed ({result.returncode}): {result.stderr[:500]}")
    finally:
        os.unlink(name)

def _apply(directory: Path, countries: list[str], *, download=True):
    if countries:
        if download:
            families = {code: fetch_ranges(code) for code in countries}
            new_rules = render_replace(families, nft_exists())
        else:
            rule_file = directory / "active.nft"
            if not rule_file.is_file():
                raise RuntimeError("Cannot restore policy: active.nft missing")
            # The stored rules are generated only by render_replace, with no raw user inputs.
            # For startup, nft is empty after reboot, so saved table definition is usable.
            saved = rule_file.read_text("ascii")
            if not saved.startswith("# Generated 4N6 country policy;") or f"table inet {TABLE}" not in saved:
                raise RuntimeError("Saved policy invalid")
            new_rules = (f"delete table inet {TABLE}\n" if nft_exists() else "") + saved
    else:
        new_rules = render_disable(nft_exists())
    execute_batch(new_rules)
    return new_rules

def apply(directory: Path, requested: list[str], *, refresh=False):
    countries = normalize_countries(requested)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / "lock").open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        old = load_policy(directory)
        if refresh and countries != old["countries"]:
            raise PolicyValidationError("Refresh requires the stored selection")
        if countries:
            families = {code: fetch_ranges(code) for code in countries}
            replacement = render_replace(families, nft_exists())
            saved = render_replace(families, False)
        else:
            replacement = render_disable(nft_exists())
            saved = ""
        # Do not change persistent policy until nft accepted the transaction.
        execute_batch(replacement)
        updated = datetime.now(timezone.utc).isoformat()
        # Store the last-known-good rules, then its selection. Never persist raw user text.
        write_atomic(directory / "active.nft", saved.encode("ascii"))
        write_atomic(directory / "policy.json", json.dumps({"countries":countries,"updated_at":updated},sort_keys=True).encode())
        counts = {"ipv4":0,"ipv6":0}
        if countries:
            four, six = validate_policy(families)
            counts = {"ipv4":len(four),"ipv6":len(six)}
        return {"countries":countries,"updated_at":updated,"applied":True,"counts":counts}

def restore(directory: Path):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / "lock").open("a+") as lock:
        fcntl.flock(lock.fileno(),fcntl.LOCK_EX)
        old = load_policy(directory)
        if not old["countries"]:
            return {"restored":False,"countries":[]}
        rules = (directory / "active.nft").read_text("ascii")
        if not rules.startswith("# Generated 4N6 country policy;") or f"table inet {TABLE}" not in rules:
            raise RuntimeError("Saved policy does not match generated rule format")
        execute_batch((f"delete table inet {TABLE}\n" if nft_exists() else "") + rules)
        return {"restored":True,"countries":old["countries"]}

def status(directory: Path):
    policy = load_policy(directory)
    present = nft_exists()
    return {"countries":policy["countries"],"updated_at":policy["updated_at"],
            "enforcement_enabled":bool(policy["countries"]) and present,
            "applied":not policy["countries"] or present,
            "mode":"enforcement", "table_present":present}
