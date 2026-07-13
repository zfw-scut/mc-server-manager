#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

CONFIG_FILE="${MINECRAFT_BACKUP_CONFIG:-/etc/minecraft-backup.conf}"
[[ -r "$CONFIG_FILE" ]] || { echo "Cannot read $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${SERVER_DIR:?SERVER_DIR is required}"
: "${BACKUP_DIR:?BACKUP_DIR is required}"

MINECRAFT_SERVICE="${MINECRAFT_SERVICE:-hello-new-generation.service}"
BACKUP_PREFIX="${BACKUP_PREFIX:-hello-new-generation}"
MAX_LOCAL_BACKUPS="${MAX_LOCAL_BACKUPS:-3}"
MIN_FREE_GIB="${MIN_FREE_GIB:-5}"

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

for command in systemctl tar sha256sum find stat du df realpath sort; do
    command -v "$command" >/dev/null || die "missing command: $command"
done
[[ -d "$SERVER_DIR" ]] || die "server directory does not exist: $SERVER_DIR"
[[ "$MAX_LOCAL_BACKUPS" =~ ^[1-9][0-9]*$ ]] || die "MAX_LOCAL_BACKUPS must be a positive integer"
[[ "$MIN_FREE_GIB" =~ ^[0-9]+$ ]] || die "MIN_FREE_GIB must be an integer"
[[ "$BACKUP_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die "BACKUP_PREFIX contains unsafe characters"

# This script archives a stopped server only. The root upload orchestrator owns
# the shared lock and is responsible for stopping and restarting Minecraft.
if systemctl is-active --quiet "$MINECRAFT_SERVICE"; then
    die "$MINECRAFT_SERVICE is active; refusing to create a non-cold backup"
fi
main_pid="$(systemctl show "$MINECRAFT_SERVICE" -p MainPID --value)"
[[ "$main_pid" == "0" ]] || die "$MINECRAFT_SERVICE still has MainPID=$main_pid"

mkdir -p -- "$BACKUP_DIR"
server_real="$(realpath -- "$SERVER_DIR")"
backup_real="$(realpath -- "$BACKUP_DIR")"
[[ "$backup_real/" != "$server_real/"* ]] || die "BACKUP_DIR must not be inside SERVER_DIR"

prune_to_limit() {
    local limit="$1" entry path remove_count index
    local -a archives=()
    mapfile -d '' archives < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f \
            \( -name "${BACKUP_PREFIX}_*.tar.zst" -o -name "${BACKUP_PREFIX}_*.tar.gz" \) \
            -printf '%T@ %p\0' | sort -z -n
    )
    remove_count=$((${#archives[@]} - limit))
    (( remove_count > 0 )) || return 0
    for ((index = 0; index < remove_count; index++)); do
        entry="${archives[index]}"
        path="${entry#* }"
        log "Removing old local backup to enforce the ${MAX_LOCAL_BACKUPS}-backup limit: $path"
        rm -f -- "$path" "${path}.sha256" "${path}.ready" "${path}.uploaded" \
            "${path}.hot-unverified"
    done
}

level_name="$(sed -n 's/^level-name=//p' "$SERVER_DIR/server.properties" | tail -n 1)"
level_name="${level_name:-world}"
[[ -f "$SERVER_DIR/$level_name/level.dat" ]] || \
    die "world level.dat not found under $SERVER_DIR/$level_name"

server_bytes="$(du -sb -- "$SERVER_DIR" | awk '{print $1}')"
available_bytes="$(df --output=avail -B1 -- "$BACKUP_DIR" | tail -n 1 | tr -d ' ')"
reserve_bytes=$((MIN_FREE_GIB * 1024 * 1024 * 1024))
required_bytes=$((server_bytes + reserve_bytes))

current_archives=()
mapfile -d '' current_archives < <(
    find "$BACKUP_DIR" -maxdepth 1 -type f \
        \( -name "${BACKUP_PREFIX}_*.tar.zst" -o -name "${BACKUP_PREFIX}_*.tar.gz" \) \
        -printf '%T@ %p\0' | sort -z -n
)
remove_count=$((${#current_archives[@]} - (MAX_LOCAL_BACKUPS - 1)))
if (( available_bytes < required_bytes && remove_count > 0 )); then
    reclaimable_bytes=0
    for ((index = 0; index < remove_count; index++)); do
        old_path="${current_archives[index]#* }"
        reclaimable_bytes=$((reclaimable_bytes + $(stat -c %s -- "$old_path")))
        if [[ -f "${old_path}.sha256" ]]; then
            reclaimable_bytes=$((reclaimable_bytes + $(stat -c %s -- "${old_path}.sha256")))
        fi
    done
    (( available_bytes + reclaimable_bytes >= required_bytes )) || \
        die "insufficient space even after rotation; existing backups were preserved"
    prune_to_limit "$((MAX_LOCAL_BACKUPS - 1))"
    available_bytes="$(df --output=avail -B1 -- "$BACKUP_DIR" | tail -n 1 | tr -d ' ')"
fi
(( available_bytes >= required_bytes )) || \
    die "insufficient backup space: need source size plus ${MIN_FREE_GIB} GiB reserve"

if command -v zstd >/dev/null; then
    extension="tar.zst"
    compression=(--use-compress-program="zstd -T1 -1")
else
    command -v gzip >/dev/null || die "neither zstd nor gzip is installed"
    extension="tar.gz"
    compression=(--use-compress-program="gzip -1")
fi

timestamp="$(TZ=Asia/Hong_Kong date '+%Y-%m-%d_%H-%M-%S_%z')"
archive="$BACKUP_DIR/${BACKUP_PREFIX}_cold_${timestamp}.${extension}"
partial="$BACKUP_DIR/.${BACKUP_PREFIX}_cold_${timestamp}.${extension}.partial"
checksum="${archive}.sha256"
ready_marker="${archive}.ready"

cleanup() {
    rc=$?
    trap - EXIT INT TERM
    rm -f -- "$partial"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log "Starting cold backup while $MINECRAFT_SERVICE is stopped"
server_parent="$(dirname -- "$SERVER_DIR")"
server_name="$(basename -- "$SERVER_DIR")"
tar "${compression[@]}" \
    -C "$server_parent" \
    --exclude="$server_name/logs" \
    --exclude="$server_name/crash-reports" \
    --exclude="$server_name/.cache" \
    -cf "$partial" \
    "$server_name"

tar "${compression[@]}" -tf "$partial" >/dev/null
mv -- "$partial" "$archive"
(
    cd "$BACKUP_DIR"
    sha256sum "$(basename -- "$archive")" > "$(basename -- "$checksum")"
)
touch -- "$ready_marker"
prune_to_limit "$MAX_LOCAL_BACKUPS"
log "Cold backup completed and queued for upload: $archive"
trap - EXIT INT TERM
