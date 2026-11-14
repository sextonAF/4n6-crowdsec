"""CLI for offline GeoIP CIDR previews. Never applies firewall rules."""
import argparse
import json
from pathlib import Path
from .policy import PolicyValidationError, preview_from_files

def main():
    p = argparse.ArgumentParser(description="Validate country IP ranges without changing firewall")
    p.add_argument("--country", required=True)
    p.add_argument("--ipv4", required=True, type=Path)
    p.add_argument("--ipv6", required=True, type=Path)
    p.add_argument("--include-ranges", action="store_true")
    args = p.parse_args()
    try:
        result = preview_from_files(args.country, args.ipv4, args.ipv6, args.include_ranges)
    except (PolicyValidationError, OSError) as exc:
        p.exit(2, f"Invalid preview: {exc}\n")
    print(json.dumps(result, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
