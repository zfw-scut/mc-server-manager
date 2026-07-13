from __future__ import annotations

import importlib.util
import json
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_rcon_module():
    path = ROOT / "bin" / "minecraft-rcon.py"
    spec = importlib.util.spec_from_file_location("minecraft_rcon", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RCON = load_rcon_module()


def receive_packet(connection: socket.socket) -> tuple[int, int, bytes]:
    length = struct.unpack("<i", connection.recv(4))[0]
    packet = b""
    while len(packet) < length:
        packet += connection.recv(length - len(packet))
    request_id, packet_type = struct.unpack("<ii", packet[:8])
    return request_id, packet_type, packet[8:-2]


def send_packet(connection: socket.socket, request_id: int, packet_type: int, payload: bytes) -> None:
    body = struct.pack("<ii", request_id, packet_type) + payload + b"\0\0"
    connection.sendall(struct.pack("<i", len(body)) + body)


class MockRconServer:
    def __init__(self, password: bytes = b"secret") -> None:
        self.password = password
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.thread.join(timeout=2)
        self.listener.close()

    def _serve(self) -> None:
        connection, _ = self.listener.accept()
        with connection:
            request_id, packet_type, payload = receive_packet(connection)
            self.assert_packet_type(packet_type, 3)
            if payload != self.password:
                send_packet(connection, -1, 2, b"")
                return
            send_packet(connection, request_id, 2, b"")
            request_id, packet_type, payload = receive_packet(connection)
            self.assert_packet_type(packet_type, 2)
            send_packet(connection, request_id, 0, b"reply: " + payload)

    @staticmethod
    def assert_packet_type(actual: int, expected: int) -> None:
        if actual != expected:
            raise AssertionError(f"packet type {actual} != {expected}")


class RconTests(unittest.TestCase):
    def test_executes_command(self) -> None:
        with MockRconServer() as server:
            result = RCON.execute("127.0.0.1", server.port, "secret", "list", 2)
        self.assertEqual(result, "reply: list")

    def test_rejects_bad_password(self) -> None:
        with MockRconServer() as server:
            with self.assertRaises(PermissionError):
                RCON.execute("127.0.0.1", server.port, "wrong", "list", 2)


class HelperScriptTests(unittest.TestCase):
    def test_cold_backup_architecture_has_no_hourly_hot_timer(self) -> None:
        service = (ROOT / "systemd" / "minecraft-backup-upload.service").read_text(
            encoding="utf-8"
        )
        installer = (ROOT / "install.sh").read_text(encoding="utf-8")
        recovery = (ROOT / "bin" / "minecraft-backup-recover.sh").read_text(
            encoding="utf-8"
        )
        archive_script = (ROOT / "bin" / "minecraft-backup.sh").read_text(
            encoding="utf-8"
        )
        orchestrator = (ROOT / "bin" / "minecraft-backup-upload.sh").read_text(
            encoding="utf-8"
        )
        manual = (ROOT / "bin" / "minecraft-backup-now.sh").read_text(encoding="utf-8")
        self.assertFalse((ROOT / "systemd" / "minecraft-backup.timer").exists())
        self.assertFalse((ROOT / "systemd" / "minecraft-backup.service").exists())
        self.assertIn("User=root", service)
        self.assertIn("refusing to create a non-cold backup", archive_script)
        self.assertIn('systemctl stop "$MINECRAFT_SERVICE"', orchestrator)
        self.assertIn('restart_minecraft_if_needed', orchestrator)
        self.assertIn('run_as_minecraft "$LOCAL_BACKUP_SCRIPT"', orchestrator)
        self.assertIn('run_as_minecraft "$BDPAN_BIN" upload', orchestrator)
        self.assertIn('${BACKUP_PREFIX}_cold_*.ready', orchestrator)
        self.assertIn("PLAYER_CHECK_MAX_GAP_SECONDS", orchestrator)
        self.assertIn("UPLOAD_RETRY_DELAY_MINUTES", orchestrator)
        self.assertIn("UPLOAD_PART_SIZE_MIB", orchestrator)
        self.assertIn("REMOTE_QUERY_ATTEMPTS", orchestrator)
        self.assertIn("REMOTE_QUERY_RETRY_SECONDS", orchestrator)
        self.assertIn("remote_backup_count_once", orchestrator)
        self.assertIn("probe_remote_file_once", orchestrator)
        self.assertIn("Remote metadata query was unsafe", orchestrator)
        self.assertIn("Splitting $archive_name", orchestrator)
        self.assertIn("Upload the parts manifest last", orchestrator)
        self.assertIn("skipping another Minecraft shutdown", orchestrator)
        self.assertIn("Cloud upload retry is deferred", orchestrator)
        self.assertIn("player-seen-during-upload", orchestrator)
        self.assertIn("existing .ready cold backup", manual)
        self.assertIn("minecraft-stopped-by-backup", recovery)
        self.assertIn('systemctl start "$MINECRAFT_SERVICE"', recovery)
        self.assertIn("systemctl disable --now minecraft-backup.timer", installer)
        self.assertIn("systemctl enable --now minecraft-backup-upload.timer", installer)

    def test_upload_timer_schedules_after_being_started_late(self) -> None:
        timer = (ROOT / "systemd" / "minecraft-backup-upload.timer").read_text(
            encoding="utf-8"
        )
        self.assertIn("OnActiveSec=5min", timer)
        self.assertIn("OnUnitInactiveSec=5min", timer)
        self.assertNotIn("OnUnitActiveSec=", timer)
        self.assertNotIn("OnBootSec=", timer)

    def test_maintenance_entrypoints_are_safe(self) -> None:
        manual = (ROOT / "bin" / "minecraft-backup-now.sh").read_text(
            encoding="utf-8"
        )
        for action in (
            "status",
            "logs",
            "verify-local",
            "cloud",
            "upload",
            "check",
            "pause",
            "resume",
        ):
            self.assertIn(action, manual)
        self.assertIn('systemctl disable --now "$BACKUP_TIMER"', manual)
        self.assertNotIn('systemctl stop "$BACKUP_UNIT"', manual)
        self.assertIn('"$BACKUP_DIR/.offline-since"', manual)
        self.assertIn('"$BACKUP_DIR/.last-player-check"', manual)
        self.assertIn("the 30-minute observation starts fresh", manual)

    def test_remote_listing_verification(self) -> None:
        listing = [
            {"server_filename": "backup.tar.zst", "size": 123, "isdir": False},
            {"server_filename": "backup.tar.zst.sha256", "size": 80, "isdir": False},
        ]
        result = subprocess.run(
            [
                sys.executable,
                ROOT / "bin" / "bdpan-listing.py",
                "verify",
                "backup.tar.zst",
                "123",
                "backup.tar.zst.sha256",
                "80",
            ],
            input=json.dumps(listing),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_exact_remote_probe_distinguishes_present_missing_and_conflict(self) -> None:
        helper = [sys.executable, ROOT / "bin" / "bdpan-listing.py", "probe", "part-006", "256"]

        present = subprocess.run(
            helper,
            input=json.dumps([{"server_filename": "part-006", "size": 256, "isdir": False}]),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(present.returncode, 0, present.stderr)

        missing = subprocess.run(
            helper,
            input=json.dumps({"code": 1, "data": None, "error": "目录不存在"}),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(missing.returncode, 1, missing.stderr)

        conflict = subprocess.run(
            helper,
            input=json.dumps([{"server_filename": "part-006", "size": 128, "isdir": False}]),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(conflict.returncode, 2, conflict.stderr)

    def test_remote_listing_length_rejects_error_objects(self) -> None:
        result = subprocess.run(
            [sys.executable, ROOT / "bin" / "bdpan-listing.py", "length"],
            input=json.dumps({"code": 1, "data": None, "error": "目录不存在"}),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)

    def test_remote_backup_count_excludes_checksums(self) -> None:
        listing = [
            {"server_filename": "hello_1.tar.zst", "size": 123, "isdir": False},
            {"server_filename": "hello_1.tar.zst.sha256", "size": 80, "isdir": False},
            {"server_filename": "hello_2.tar.gz", "size": 456, "isdir": False},
            {
                "server_filename": "hello_2.tar.gz.parts.sha256",
                "size": 90,
                "isdir": False,
            },
            {
                "server_filename": "hello_3.tar.zst.parts.sha256",
                "size": 90,
                "isdir": False,
            },
            {"server_filename": "other_1.tar.zst", "size": 789, "isdir": False},
        ]
        result = subprocess.run(
            [sys.executable, ROOT / "bin" / "bdpan-listing.py", "count", "hello"],
            input=json.dumps(listing),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "3")

    def test_completed_remote_listing_only_outputs_completion_manifests(self) -> None:
        listing = [
            {"server_filename": "hello_cold_1.tar.zst.part-000", "size": 256, "isdir": False},
            {"server_filename": "hello_cold_1.tar.zst.sha256", "size": 120, "isdir": False},
            {
                "server_filename": "hello_cold_1.tar.zst.parts.sha256",
                "size": 1620,
                "isdir": False,
            },
            {
                "server_filename": "other_cold_1.tar.zst.parts.sha256",
                "size": 1620,
                "isdir": False,
            },
        ]
        result = subprocess.run(
            [sys.executable, ROOT / "bin" / "bdpan-listing.py", "completed", "hello"],
            input=json.dumps(listing),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "hello_cold_1.tar.zst.parts.sha256\t1620")

    def test_rcon_configuration_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            properties = root / "server.properties"
            password = root / "password"
            properties.write_text("motd=test\nenable-rcon=false\n", encoding="utf-8")
            password.write_text("secret-value\n", encoding="utf-8")
            command = [
                sys.executable,
                ROOT / "bin" / "configure-rcon.py",
                properties,
                password,
            ]
            subprocess.run(command, check=True, capture_output=True, text=True)
            subprocess.run(command, check=True, capture_output=True, text=True)
            updated = properties.read_text(encoding="utf-8")
            self.assertIn("motd=test", updated)
            self.assertIn("enable-rcon=true", updated)
            self.assertIn("rcon.password=secret-value", updated)
            self.assertEqual(len(list(root.glob("server.properties.before-backup-*"))), 1)


if __name__ == "__main__":
    unittest.main()
