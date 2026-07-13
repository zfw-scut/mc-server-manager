#!/usr/bin/env python3
"""Idempotently enable RCON while preserving unrelated server.properties lines."""

from __future__ import annotations

import argparse
import datetime as dt
import shutil
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("properties", type=Path)
    parser.add_argument("password_file", type=Path)
    parser.add_argument("--port", default="25575")
    args = parser.parse_args()

    password = args.password_file.read_text(encoding="utf-8").strip()
    if not password or any(char in password for char in "\r\n"):
        raise SystemExit("RCON password is empty or invalid")

    original = args.properties.read_text(encoding="utf-8")
    desired = {
        "enable-rcon": "true",
        "rcon.port": args.port,
        "rcon.password": password,
        "broadcast-rcon-to-ops": "false",
    }
    seen: set[str] = set()
    output: list[str] = []
    for line in original.splitlines():
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key in desired:
            if key not in seen:
                output.append(f"{key}={desired[key]}")
                seen.add(key)
        else:
            output.append(line)
    for key, value in desired.items():
        if key not in seen:
            output.append(f"{key}={value}")

    updated = "\n".join(output) + "\n"
    if updated == original:
        print("RCON configuration is already current")
        return 0

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = args.properties.with_name(f"{args.properties.name}.before-backup-{timestamp}")
    shutil.copy2(args.properties, backup)
    args.properties.write_text(updated, encoding="utf-8")
    print(f"Updated {args.properties}; backup: {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
