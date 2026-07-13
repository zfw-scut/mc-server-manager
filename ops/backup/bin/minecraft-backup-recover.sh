#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE="${MINECRAFT_BACKUP_CONFIG:-/etc/minecraft-backup.conf}"
[[ -r "$CONFIG_FILE" ]] || exit 0
# shellcheck source=/dev/null
source "$CONFIG_FILE"

MINECRAFT_SERVICE="${MINECRAFT_SERVICE:-hello-new-generation.service}"
RECOVERY_MARKER="${RECOVERY_MARKER:-/run/minecraft-backup/minecraft-stopped-by-backup}"

[[ -e "$RECOVERY_MARKER" ]] || exit 0
printf '[%s] Recovery marker found; starting %s\n' \
    "$(date --iso-8601=seconds)" "$MINECRAFT_SERVICE"

if systemctl start "$MINECRAFT_SERVICE" && systemctl is-active --quiet "$MINECRAFT_SERVICE"; then
    rm -f -- "$RECOVERY_MARKER"
    printf '[%s] Recovery start request succeeded\n' "$(date --iso-8601=seconds)"
    exit 0
fi

printf '[%s] ERROR: recovery start failed; operator action is required\n' \
    "$(date --iso-8601=seconds)" >&2
exit 1
