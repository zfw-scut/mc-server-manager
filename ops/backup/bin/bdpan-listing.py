#!/usr/bin/env python3
"""Inspect `bdpan ls --json` output without reading bdpan credentials."""

from __future__ import annotations

import argparse
import json
import re
import sys


def load_document():
    return json.load(sys.stdin)


def load_files(document) -> dict[str, int]:
    if isinstance(document, dict):
        if document.get("code") not in (None, 0):
            raise ValueError(f"bdpan returned an error object: {document.get('error', document.get('code'))}")
        items = document.get("results", document.get("files", []))
    else:
        items = document
    if not isinstance(items, list):
        raise ValueError("listing is not an array")

    files: dict[str, int] = {}
    for item in items:
        if not isinstance(item, dict) or item.get("isdir") is True:
            continue
        name = item.get("server_filename") or item.get("name")
        size = item.get("size")
        if isinstance(name, str) and isinstance(size, int):
            files[name] = size
    return files


def expected_pairs(values: list[str]) -> dict[str, int]:
    if not values or len(values) % 2:
        raise ValueError("file checks must be NAME SIZE pairs")
    return {values[index]: int(values[index + 1]) for index in range(0, len(values), 2)}


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    count_parser = subparsers.add_parser("count")
    count_parser.add_argument("prefix")
    completed_parser = subparsers.add_parser("completed")
    completed_parser.add_argument("prefix")
    subparsers.add_parser("length")
    for command in ("contains", "verify"):
        check_parser = subparsers.add_parser(command)
        check_parser.add_argument("checks", nargs="+")
    probe_parser = subparsers.add_parser("probe")
    probe_parser.add_argument("name")
    probe_parser.add_argument("size", type=int)
    args = parser.parse_args()

    try:
        document = load_document()
        if args.command == "probe":
            if (
                isinstance(document, dict)
                and document.get("code") == 1
                and document.get("data") is None
                and "不存在" in str(document.get("error", ""))
            ):
                return 1
            files = load_files(document)
            if not files:
                return 1
            if set(files) != {args.name}:
                print("exact-path lookup returned an unexpected file set", file=sys.stderr)
                return 2
            if files[args.name] != args.size:
                print(
                    f"remote size conflict for {args.name}: expected {args.size}, got {files[args.name]}",
                    file=sys.stderr,
                )
                return 2
            return 0

        files = load_files(document)
        if args.command == "length":
            print(len(files))
            return 0
        if args.command == "count":
            archive_pattern = re.compile(
                rf"^({re.escape(args.prefix)}_.*\.tar\.(?:zst|gz))(?:\.parts\.sha256)?$"
            )
            backups = {
                match.group(1)
                for name in files
                if (match := archive_pattern.match(name))
            }
            print(len(backups))
            return 0
        if args.command == "completed":
            completion_pattern = re.compile(
                rf"^{re.escape(args.prefix)}_.*\.tar\.(?:zst|gz)\.parts\.sha256$"
            )
            for name in sorted(files):
                if completion_pattern.match(name):
                    print(f"{name}\t{files[name]}")
            return 0

        expected = expected_pairs(args.checks)
        mismatches = [
            f"{name}: expected {size}, got {files.get(name, 'missing')}"
            for name, size in expected.items()
            if files.get(name) != size
        ]
        if mismatches:
            if args.command == "verify":
                print("remote upload verification failed: " + "; ".join(mismatches), file=sys.stderr)
            return 1
        return 0
    except (argparse.ArgumentError, json.JSONDecodeError, TypeError, ValueError) as exc:
        print(f"invalid bdpan listing: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
