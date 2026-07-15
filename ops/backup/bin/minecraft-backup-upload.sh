#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

CONFIG_FILE="${MINECRAFT_BACKUP_CONFIG:-/etc/minecraft-backup.conf}"
[[ -r "$CONFIG_FILE" ]] || { echo "Cannot read $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${BACKUP_DIR:?BACKUP_DIR is required}"
: "${REMOTE_ROOT:?REMOTE_ROOT is required}"

MINECRAFT_SERVICE="${MINECRAFT_SERVICE:-hello-new-generation.service}"
MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_HOME="${MINECRAFT_HOME:-/data/minecraft}"
MINECRAFT_START_TIMEOUT_SECONDS="${MINECRAFT_START_TIMEOUT_SECONDS:-300}"
PLAYER_CHECK_MAX_GAP_SECONDS="${PLAYER_CHECK_MAX_GAP_SECONDS:-600}"
UPLOAD_RETRY_DELAY_MINUTES="${UPLOAD_RETRY_DELAY_MINUTES:-60}"
UPLOAD_PART_SIZE_MIB="${UPLOAD_PART_SIZE_MIB:-256}"
REMOTE_QUERY_ATTEMPTS="${REMOTE_QUERY_ATTEMPTS:-4}"
REMOTE_QUERY_RETRY_SECONDS="${REMOTE_QUERY_RETRY_SECONDS:-10}"
BACKUP_PREFIX="${BACKUP_PREFIX:-hello-new-generation}"
OFFLINE_DELAY_MINUTES="${OFFLINE_DELAY_MINUTES:-30}"
REMOTE_MAX_BACKUPS="${REMOTE_MAX_BACKUPS:-100}"
RCON_HOST="${RCON_HOST:-127.0.0.1}"
RCON_PORT="${RCON_PORT:-25575}"
RCON_TIMEOUT="${RCON_TIMEOUT:-120}"
RCON_CLIENT="${RCON_CLIENT:-/usr/local/libexec/minecraft-backup/minecraft-rcon.py}"
BDPAN_BIN="${BDPAN_BIN:-/data/minecraft/.local/bin/bdpan}"
BDPAN_LISTING="${BDPAN_LISTING:-/usr/local/libexec/minecraft-backup/bdpan-listing.py}"
LOCAL_BACKUP_SCRIPT="${LOCAL_BACKUP_SCRIPT:-/usr/local/libexec/minecraft-backup/minecraft-backup.sh}"
RCON_PASSWORD_FILE="${RCON_PASSWORD_FILE:-${CREDENTIALS_DIRECTORY:-/etc/minecraft-backup}/rcon_password}"
RECOVERY_MARKER="${RECOVERY_MARKER:-/run/minecraft-backup/minecraft-stopped-by-backup}"

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

(( EUID == 0 )) || die "cold-backup orchestrator must run as root"
for command in python3 flock find stat sort date systemctl runuser sleep install sync env \
    split sha256sum df basename rm mv chown; do
    command -v "$command" >/dev/null || die "missing command: $command"
done
[[ -x "$RCON_CLIENT" ]] || die "RCON client is not executable: $RCON_CLIENT"
[[ -x "$BDPAN_LISTING" ]] || die "bdpan listing helper is not executable: $BDPAN_LISTING"
[[ -x "$LOCAL_BACKUP_SCRIPT" ]] || die "local backup script is not executable: $LOCAL_BACKUP_SCRIPT"
[[ -x "$BDPAN_BIN" ]] || die "bdpan is not executable: $BDPAN_BIN"
[[ -r "$RCON_PASSWORD_FILE" ]] || die "RCON credential is not readable"
[[ "$OFFLINE_DELAY_MINUTES" =~ ^[1-9][0-9]*$ ]] || die "OFFLINE_DELAY_MINUTES must be a positive integer"
[[ "$REMOTE_MAX_BACKUPS" =~ ^[1-9][0-9]*$ ]] || die "REMOTE_MAX_BACKUPS must be a positive integer"
[[ "$MINECRAFT_START_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
    die "MINECRAFT_START_TIMEOUT_SECONDS must be a positive integer"
[[ "$PLAYER_CHECK_MAX_GAP_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
    die "PLAYER_CHECK_MAX_GAP_SECONDS must be a positive integer"
[[ "$UPLOAD_RETRY_DELAY_MINUTES" =~ ^[1-9][0-9]*$ ]] || \
    die "UPLOAD_RETRY_DELAY_MINUTES must be a positive integer"
[[ "$UPLOAD_PART_SIZE_MIB" =~ ^[1-9][0-9]*$ ]] || \
    die "UPLOAD_PART_SIZE_MIB must be a positive integer"
[[ "$REMOTE_QUERY_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || \
    die "REMOTE_QUERY_ATTEMPTS must be a positive integer"
[[ "$REMOTE_QUERY_RETRY_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
    die "REMOTE_QUERY_RETRY_SECONDS must be a positive integer"
[[ "$BACKUP_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die "BACKUP_PREFIX contains unsafe characters"
[[ "$REMOTE_ROOT" != /* && "$REMOTE_ROOT" != *..* ]] || die "REMOTE_ROOT must be a safe relative path"

mkdir -p -- "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.backup.lock"
if ! flock -n 9; then
    log "A backup or upload task is already running; skipping"
    exit 0
fi

rcon() {
    python3 "$RCON_CLIENT" \
        --host "$RCON_HOST" \
        --port "$RCON_PORT" \
        --password-file "$RCON_PASSWORD_FILE" \
        --timeout "$RCON_TIMEOUT" \
        "$1"
}

run_as_minecraft() {
    runuser -u "$MINECRAFT_USER" -- env \
        HOME="$MINECRAFT_HOME" \
        PATH="$MINECRAFT_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

wait_for_minecraft() {
    local deadline=$((SECONDS + MINECRAFT_START_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        if systemctl is-active --quiet "$MINECRAFT_SERVICE" && rcon list >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

restart_minecraft_if_needed() {
    [[ -e "$RECOVERY_MARKER" ]] || return 0
    log "Starting $MINECRAFT_SERVICE after cold backup"
    systemctl start "$MINECRAFT_SERVICE" || return 1
    wait_for_minecraft || return 1
    rm -f -- "$RECOVERY_MARKER"
    log "$MINECRAFT_SERVICE is active and RCON is ready"
}

player_monitor_pid=""
stop_player_monitor() {
    [[ -n "$player_monitor_pid" ]] || return 0
    kill "$player_monitor_pid" >/dev/null 2>&1 || true
    wait "$player_monitor_pid" >/dev/null 2>&1 || true
    player_monitor_pid=""
}

cleanup() {
    rc=$?
    trap - EXIT INT TERM
    stop_player_monitor
    if [[ -e "$RECOVERY_MARKER" ]]; then
        log "Recovery marker is present; attempting to restart Minecraft"
        if ! restart_minecraft_if_needed; then
            log "ERROR: automatic Minecraft recovery failed; operator action is required"
            rc=1
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

systemctl is-active --quiet "$MINECRAFT_SERVICE" || \
    die "$MINECRAFT_SERVICE is not active; refusing to begin a cold backup cycle"

list_output="$(rcon list)" || die "cannot query the Minecraft server through RCON"
player_count_pattern='[Tt]here[[:space:]]+are[[:space:]]+([0-9]+)'
[[ "$list_output" =~ $player_count_pattern ]] || die "cannot safely parse the online player count: $list_output"
online_players="${BASH_REMATCH[1]}"
offline_state="$BACKUP_DIR/.offline-since"
cold_snapshot_state="$BACKUP_DIR/.cold-snapshot-for"
last_check_state="$BACKUP_DIR/.last-player-check"
player_seen_state="/run/minecraft-backup/player-seen-during-upload"
upload_retry_state="$BACKUP_DIR/.upload-retry-after"
now="$(date +%s)"

last_check=""
if [[ -f "$last_check_state" ]]; then
    read -r last_check < "$last_check_state" || true
fi
if [[ ! "$last_check" =~ ^[0-9]+$ ]] || (( last_check > now )) || \
   (( now - last_check > PLAYER_CHECK_MAX_GAP_SECONDS )); then
    rm -f -- "$offline_state"
    log "Player-check continuity was lost; the quiet period has been reset"
fi
printf '%s\n' "$now" > "${last_check_state}.tmp"
mv -- "${last_check_state}.tmp" "$last_check_state"

if (( online_players > 0 )); then
    rm -f -- "$offline_state"
    log "$online_players player(s) online; no cold backup or cloud upload will run"
    exit 0
fi

if [[ ! -f "$offline_state" ]]; then
    printf '%s\n' "$now" > "${offline_state}.tmp"
    mv -- "${offline_state}.tmp" "$offline_state"
    log "All players are offline; starting the ${OFFLINE_DELAY_MINUTES}-minute quiet period"
    exit 0
fi

offline_since=""
read -r offline_since < "$offline_state" || true
if [[ ! "$offline_since" =~ ^[0-9]+$ ]] || (( offline_since > now )); then
    printf '%s\n' "$now" > "${offline_state}.tmp"
    mv -- "${offline_state}.tmp" "$offline_state"
    log "Offline state was invalid and has been reset"
    exit 0
fi

elapsed=$((now - offline_since))
required=$((OFFLINE_DELAY_MINUTES * 60))
if (( elapsed < required )); then
    log "All players remain offline; $((required - elapsed)) second(s) left before cold backup"
    exit 0
fi

snapshot_for=""
if [[ -f "$cold_snapshot_state" ]]; then
    read -r snapshot_for < "$cold_snapshot_state" || true
fi

load_ready_markers() {
    ready_markers=()
    mapfile -d '' ready_markers < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f -name "${BACKUP_PREFIX}_cold_*.ready" \
            -printf '%T@ %p\0' | sort -z -n
    )
}

load_ready_markers
queued_backup_from_older_episode=false
if ((${#ready_markers[@]} > 0)); then
    log "A local cold backup is already queued; skipping another Minecraft shutdown"
    [[ "$snapshot_for" == "$offline_since" ]] || queued_backup_from_older_episode=true

    retry_after=""
    if [[ -f "$upload_retry_state" ]]; then
        read -r retry_after < "$upload_retry_state" || true
    fi
    if [[ "$retry_after" =~ ^[0-9]+$ ]] && (( retry_after > now )); then
        log "Cloud upload retry is deferred for $((retry_after - now)) more second(s)"
        exit 0
    fi
else
    rm -f -- "$upload_retry_state"
fi

if ((${#ready_markers[@]} == 0)) && [[ "$snapshot_for" != "$offline_since" ]]; then
    # Close the login race as far as RCON polling allows before stopping the server.
    list_output="$(rcon list)" || die "cannot recheck players immediately before cold backup"
    [[ "$list_output" =~ $player_count_pattern ]] || die "cannot safely parse the final player count: $list_output"
    if (( BASH_REMATCH[1] > 0 )); then
        rm -f -- "$offline_state" "$cold_snapshot_state"
        log "A player joined before shutdown; the cold backup has been cancelled"
        exit 0
    fi

    log "The quiet period is complete; stopping $MINECRAFT_SERVICE for a consistent cold backup"
    install -m 0600 /dev/null "$RECOVERY_MARKER"
    systemctl stop "$MINECRAFT_SERVICE"
    systemctl is-active --quiet "$MINECRAFT_SERVICE" && \
        die "$MINECRAFT_SERVICE remained active after the stop request"
    [[ "$(systemctl show "$MINECRAFT_SERVICE" -p MainPID --value)" == "0" ]] || \
        die "$MINECRAFT_SERVICE still has a main process after stopping"
    sync -f "$SERVER_DIR"

    run_as_minecraft "$LOCAL_BACKUP_SCRIPT"
    restart_minecraft_if_needed || die "Minecraft did not recover after the cold backup"

    printf '%s\n' "$offline_since" > "${cold_snapshot_state}.tmp"
    mv -- "${cold_snapshot_state}.tmp" "$cold_snapshot_state"
    load_ready_markers
fi

# A player may join as soon as Minecraft returns. Keep the completed cold backup
# locally and postpone cloud traffic until a later quiet period if that happens.
list_output="$(rcon list)" || die "cannot recheck players before cloud upload"
[[ "$list_output" =~ $player_count_pattern ]] || die "cannot safely parse the player count before upload: $list_output"
if (( BASH_REMATCH[1] > 0 )); then
    rm -f -- "$offline_state"
    log "A player joined after restart; the cold backup remains local and cloud upload is postponed"
    exit 0
fi

((${#ready_markers[@]} > 0)) || { log "No cold backups are waiting for upload"; exit 0; }

# Upload can take much longer than the five-minute timer interval. Keep polling
# RCON while bdpan runs so a player session during the upload resets the next
# offline cycle even if the player leaves before this service finishes.
rm -f -- "$player_seen_state"
(
    while sleep 60; do
        monitor_output="$(rcon list 2>/dev/null)" || continue
        [[ "$monitor_output" =~ $player_count_pattern ]] || continue
        monitor_now="$(date +%s)"
        printf '%s\n' "$monitor_now" > "${last_check_state}.monitor.tmp"
        mv -- "${last_check_state}.monitor.tmp" "$last_check_state"
        if (( BASH_REMATCH[1] > 0 )); then
            touch "$player_seen_state"
        fi
    done
) &
player_monitor_pid=$!

run_as_minecraft "$BDPAN_BIN" mkdir "$REMOTE_ROOT" >/dev/null 2>&1 || true
schedule_upload_retry() {
    local retry_after
    retry_after=$(($(date +%s) + UPLOAD_RETRY_DELAY_MINUTES * 60))
    printf '%s\n' "$retry_after" > "${upload_retry_state}.tmp"
    mv -- "${upload_retry_state}.tmp" "$upload_retry_state"
    log "Cloud upload failed; another attempt is deferred for ${UPLOAD_RETRY_DELAY_MINUTES} minute(s)"
}

remote_backup_count_once() {
    local start=0 page page_items page_backups total=0
    while true; do
        if ! page="$(run_as_minecraft "$BDPAN_BIN" ls "$REMOTE_ROOT" \
            --json --order name --start "$start" --limit 1000)"; then
            return 1
        fi
        if ! page_items="$(printf '%s' "$page" | python3 "$BDPAN_LISTING" length)"; then
            return 1
        fi
        if ! page_backups="$(printf '%s' "$page" | python3 "$BDPAN_LISTING" count "$BACKUP_PREFIX")"; then
            return 1
        fi
        [[ "$page_items" =~ ^[0-9]+$ && "$page_backups" =~ ^[0-9]+$ ]] || return 1
        total=$((total + page_backups))
        (( page_items < 1000 )) && break
        start=$((start + page_items))
    done
    printf '%s\n' "$total"
}

remote_backup_count() {
    local attempt count
    for ((attempt = 1; attempt <= REMOTE_QUERY_ATTEMPTS; attempt++)); do
        if count="$(remote_backup_count_once)"; then
            printf '%s\n' "$count"
            return 0
        fi
        if (( attempt < REMOTE_QUERY_ATTEMPTS )); then
            log "Remote backup listing failed (attempt ${attempt}/${REMOTE_QUERY_ATTEMPTS}); retrying in ${REMOTE_QUERY_RETRY_SECONDS} second(s)" >&2
            sleep "$REMOTE_QUERY_RETRY_SECONDS"
        fi
    done
    return 1
}

if ! remote_count="$(remote_backup_count)"; then
    schedule_upload_retry
    die "cannot safely count completed remote backups"
fi

# Return 0 only for an exact name+size match, 1 only for an explicit missing
# response, and 2 for transport errors, conflicts, or malformed responses.
probe_remote_file_once() {
    local remote_name="$1" size="$2" output rc=0
    if ! output="$(run_as_minecraft "$BDPAN_BIN" ls "$REMOTE_ROOT/$remote_name" \
        --json --limit 1)"; then
        return 2
    fi
    printf '%s' "$output" | python3 "$BDPAN_LISTING" probe "$remote_name" "$size" || rc=$?
    return "$rc"
}

probe_remote_file() {
    local remote_name="$1" size="$2" attempt status
    for ((attempt = 1; attempt <= REMOTE_QUERY_ATTEMPTS; attempt++)); do
        if probe_remote_file_once "$remote_name" "$size"; then
            return 0
        else
            status=$?
        fi
        # An explicit missing result is meaningful and is confirmed separately
        # by upload_and_verify_file. Only unsafe/error results are retried here.
        (( status == 2 )) || return "$status"
        if (( attempt < REMOTE_QUERY_ATTEMPTS )); then
            log "Remote metadata query was unsafe for $remote_name (attempt ${attempt}/${REMOTE_QUERY_ATTEMPTS}); retrying in ${REMOTE_QUERY_RETRY_SECONDS} second(s)" >&2
            sleep "$REMOTE_QUERY_RETRY_SECONDS"
        fi
    done
    return 2
}

upload_and_verify_file() {
    local local_path="$1" remote_name="$2" size status attempt
    size="$(stat -c %s -- "$local_path")"

    if probe_remote_file "$remote_name" "$size"; then
        log "Remote file already verified; skipping upload: $remote_name"
        return 0
    else
        status=$?
    fi
    if (( status != 1 )); then
        schedule_upload_retry
        die "cannot safely determine remote state for $remote_name"
    fi

    # Confirm a missing result twice so one stale/error response cannot cause a
    # duplicate upload of an already completed part.
    sleep 2
    if probe_remote_file "$remote_name" "$size"; then
        log "Remote file already verified on the second probe; skipping upload: $remote_name"
        return 0
    else
        status=$?
    fi
    if (( status != 1 )); then
        schedule_upload_retry
        die "second remote probe was unsafe for $remote_name"
    fi

    if ! run_as_minecraft "$BDPAN_BIN" upload "$local_path" "$REMOTE_ROOT/$remote_name"; then
        schedule_upload_retry
        die "cloud upload failed for $remote_name; local retry files were preserved"
    fi

    for attempt in 1 2 3 4 5 6; do
        if probe_remote_file "$remote_name" "$size"; then
            return 0
        else
            status=$?
        fi
        (( status == 1 )) || break
        sleep 5
    done
    schedule_upload_retry
    die "cloud upload returned success but exact-path verification failed for $remote_name"
}

for entry in "${ready_markers[@]}"; do
    marker="${entry#* }"
    archive="${marker%.ready}"
    checksum="${archive}.sha256"
    [[ -f "$archive" && -f "$checksum" ]] || { log "WARNING: incomplete local backup set: $archive"; continue; }
    archive_name="$(basename -- "$archive")"
    checksum_name="$(basename -- "$checksum")"
    archive_size="$(stat -c %s -- "$archive")"
    parts_manifest="${archive}.parts.sha256"
    parts_manifest_name="$(basename -- "$parts_manifest")"

    parts_valid=false
    if [[ -f "$parts_manifest" ]]; then
        if (cd "$BACKUP_DIR" && sha256sum -c "$(basename -- "$parts_manifest")" >/dev/null 2>&1); then
            parts_valid=true
        fi
    fi
    if [[ "$parts_valid" == false ]]; then
        find "$BACKUP_DIR" -maxdepth 1 -type f -name "${archive_name}.part-*" -delete
        rm -f -- "$parts_manifest"
        available_bytes="$(df --output=avail -B1 -- "$BACKUP_DIR" | tail -n 1 | tr -d ' ')"
        (( available_bytes >= archive_size + 1073741824 )) || \
            die "insufficient temporary space to split $archive_name for reliable cloud upload"
        log "Splitting $archive_name into ${UPLOAD_PART_SIZE_MIB} MiB cloud-upload parts"
        run_as_minecraft split -b "${UPLOAD_PART_SIZE_MIB}M" -d -a 3 \
            "$archive" "${archive}.part-"
        (
            cd "$BACKUP_DIR"
            sha256sum "${archive_name}.part-"* > "$(basename -- "$parts_manifest")"
        )
        chown "$MINECRAFT_USER" "$parts_manifest"
    fi

    parts_manifest_size="$(stat -c %s -- "$parts_manifest")"
    manifest_is_remote=false
    if probe_remote_file "$parts_manifest_name" "$parts_manifest_size"; then
        manifest_is_remote=true
    else
        probe_status=$?
        if (( probe_status != 1 )); then
            schedule_upload_retry
            die "cannot safely determine remote completion state for $parts_manifest_name"
        fi
    fi
    if (( remote_count >= REMOTE_MAX_BACKUPS )) && [[ "$manifest_is_remote" == false ]]; then
        log "WARNING: remote limit of ${REMOTE_MAX_BACKUPS} backups reached; upload is paused until old cloud backups are manually removed"
        break
    fi

    upload_parts=()
    mapfile -d '' upload_parts < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f -name "${archive_name}.part-*" -print0 | sort -z
    )
    ((${#upload_parts[@]} > 0)) || die "no upload parts were generated for $archive_name"

    for part in "${upload_parts[@]}"; do
        upload_and_verify_file "$part" "$(basename -- "$part")"
    done
    upload_and_verify_file "$checksum" "$checksum_name"
    # Upload the parts manifest last. Its presence is the remote completion marker.
    upload_and_verify_file "$parts_manifest" "$parts_manifest_name"

    mv -- "$marker" "${archive}.uploaded"
    rm -f -- "${upload_parts[@]}" "$parts_manifest"
    if ! remote_count="$(remote_backup_count)"; then
        schedule_upload_retry
        die "multipart upload completed but the remote backup count could not be verified"
    fi
    log "Cloud multipart upload verified ($remote_count/$REMOTE_MAX_BACKUPS): /apps/bdpan/$REMOTE_ROOT/$parts_manifest_name"
done

rm -f -- "$upload_retry_state"

stop_player_monitor
if [[ -e "$player_seen_state" ]]; then
    rm -f -- "$offline_state" "$player_seen_state"
    log "A player was seen during cloud upload; the next offline cycle will start from zero"
elif [[ "$queued_backup_from_older_episode" == true ]]; then
    rm -f -- "$offline_state"
    log "The queued backup came from an older player session; a fresh quiet period will start before the next cold backup"
else
    final_check="$(date +%s)"
    printf '%s\n' "$final_check" > "${last_check_state}.tmp"
    mv -- "${last_check_state}.tmp" "$last_check_state"
fi

trap - EXIT INT TERM
