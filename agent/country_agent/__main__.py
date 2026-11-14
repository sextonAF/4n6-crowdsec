"""CLI for offline GeoIP previews or authenticated loopback-only read-only API."""
import argparse
import json
from pathlib import Path
from .http_api import run
from .policy import PolicyValidationError, preview_from_files


def main():
    parser = argparse.ArgumentParser(description="GeoIP previews; never changes firewall rules")
    commands = parser.add_subparsers(dest="command", required=True)
    preview_parser = commands.add_parser("preview", help="Preview locally supplied GeoIP files")
    preview_parser.add_argument("--country", required=True)
    preview_parser.add_argument("--ipv4", required=True, type=Path)
    preview_parser.add_argument("--ipv6", required=True, type=Path)
    preview_parser.add_argument("--include-ranges", action="store_true")
    serve_parser = commands.add_parser("serve", help="Start authenticated local preview API")
    serve_parser.add_argument("--bind", default="127.0.0.1", choices=["127.0.0.1"])
    serve_parser.add_argument("--port", type=int, default=14110)
    serve_parser.add_argument("--token-file", type=Path, required=True)
    serve_parser.add_argument("--feeds", type=Path, required=True)
    serve_parser.add_argument("--server-id", required=True)
    args = parser.parse_args()

    if args.command == "serve":
        try:
            run(args.bind, args.port, args.token_file, args.feeds, args.server_id)
        except (ValueError, OSError) as exc:
            parser.exit(2, f"Cannot start preview agent: {exc}\n")
        return 0

    try:
        result = preview_from_files(args.country, args.ipv4, args.ipv6, args.include_ranges)
    except (PolicyValidationError, OSError) as exc:
        parser.exit(2, f"Invalid preview: {exc}\n")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
