#!/usr/bin/env python3
"""Minimal Minecraft RCON client using only the Python standard library."""

from __future__ import annotations

import argparse
import socket
import struct
import sys
from pathlib import Path


MAX_PACKET_SIZE = 4 * 1024 * 1024


def receive_exact(sock: socket.socket, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("RCON connection closed unexpectedly")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def receive_packet(sock: socket.socket) -> tuple[int, int, bytes]:
    (length,) = struct.unpack("<i", receive_exact(sock, 4))
    if length < 10 or length > MAX_PACKET_SIZE:
        raise ValueError(f"invalid RCON packet length: {length}")
    packet = receive_exact(sock, length)
    request_id, packet_type = struct.unpack("<ii", packet[:8])
    if packet[-2:] != b"\x00\x00":
        raise ValueError("invalid RCON packet terminator")
    return request_id, packet_type, packet[8:-2]


def send_packet(sock: socket.socket, request_id: int, packet_type: int, payload: bytes) -> None:
    body = struct.pack("<ii", request_id, packet_type) + payload + b"\x00\x00"
    sock.sendall(struct.pack("<i", len(body)) + body)


def execute(host: str, port: int, password: str, command: str, timeout: float) -> str:
    auth_id = 0x4D43
    command_id = auth_id + 1

    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        send_packet(sock, auth_id, 3, password.encode("utf-8"))

        authenticated = False
        for _ in range(3):
            response_id, response_type, _ = receive_packet(sock)
            if response_id == -1:
                raise PermissionError("RCON authentication failed")
            if response_id == auth_id and response_type == 2:
                authenticated = True
                break
        if not authenticated:
            raise PermissionError("RCON authentication response was not received")

        send_packet(sock, command_id, 2, command.encode("utf-8"))
        response_id, _, payload = receive_packet(sock)
        if response_id != command_id:
            raise RuntimeError("RCON returned an unexpected request id")

        chunks = [payload]
        sock.settimeout(0.15)
        while True:
            try:
                response_id, _, payload = receive_packet(sock)
            except (socket.timeout, ConnectionError):
                break
            if response_id != command_id:
                break
            chunks.append(payload)

    return b"".join(chunks).decode("utf-8", errors="replace")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Execute one Minecraft RCON command")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=25575)
    parser.add_argument("--password-file", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("command")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        password = args.password_file.read_text(encoding="utf-8").strip()
        if not password:
            raise ValueError("RCON password file is empty")
        output = execute(args.host, args.port, password, args.command, args.timeout)
    except (OSError, ValueError, RuntimeError, PermissionError) as exc:
        print(f"minecraft-rcon: {exc}", file=sys.stderr)
        return 1
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
