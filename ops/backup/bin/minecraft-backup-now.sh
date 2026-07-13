#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

CONFIG_FILE="${MINECRAFT_BACKUP_CONFIG:-/etc/minecraft-backup.conf}"
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

MINECRAFT_SERVICE="${MINECRAFT_SERVICE:-hello-new-generation.service}"
BACKUP_UNIT="${BACKUP_UNIT:-minecraft-backup-upload.service}"
BACKUP_TIMER="${BACKUP_TIMER:-minecraft-backup-upload.timer}"
BACKUP_DIR="${BACKUP_DIR:-/data/minecraft/backups/hello-new-generation}"
BACKUP_PREFIX="${BACKUP_PREFIX:-hello-new-generation}"
REMOTE_ROOT="${REMOTE_ROOT:-mc-backups/hello-new-generation}"
MINECRAFT_USER="${MINECRAFT_USER:-minecraft}"
MINECRAFT_HOME="${MINECRAFT_HOME:-/data/minecraft}"
RCON_HOST="${RCON_HOST:-127.0.0.1}"
RCON_PORT="${RCON_PORT:-25575}"
RCON_TIMEOUT="${RCON_TIMEOUT:-120}"
RCON_CLIENT="${RCON_CLIENT:-/usr/local/libexec/minecraft-backup/minecraft-rcon.py}"
RCON_PASSWORD_FILE="${RCON_PASSWORD_FILE:-/etc/minecraft-backup/rcon-password}"
BDPAN_BIN="${BDPAN_BIN:-/data/minecraft/.local/bin/bdpan}"
BDPAN_LISTING="${BDPAN_LISTING:-/usr/local/libexec/minecraft-backup/bdpan-listing.py}"

usage() {
    cat <<'EOF'
Usage:
  minecraft-backup-now status        Show health, scheduler, players, state files, and local storage
  minecraft-backup-now logs [LINES]  Show recent backup logs (default: 200, maximum: 5000)
  minecraft-backup-now verify-local  Verify every local cold archive against its SHA-256 file
  minecraft-backup-now cloud         List the cloud backup directory (read-only)
  minecraft-backup-now upload        Run one normal eligibility check; never bypass the 30-minute rule
  minecraft-backup-now check         Alias for upload
  minecraft-backup-now pause         Disable future automatic checks; do not interrupt a running task
  minecraft-backup-now resume        Preflight dependencies, reset observation time, and enable the timer
EOF
}

(( EUID == 0 )) || {
    echo "Run this command as root (or with sudo)." >&2
    exit 1
}

rcon_list() {
    python3 "$RCON_CLIENT" \
        --host "$RCON_HOST" \
        --port "$RCON_PORT" \
        --password-file "$RCON_PASSWORD_FILE" \
        --timeout "$RCON_TIMEOUT" \
        list
}

run_as_minecraft() {
    runuser -u "$MINECRAFT_USER" -- env \
        HOME="$MINECRAFT_HOME" \
        PATH="$MINECRAFT_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

show_result() {
    local unit="$1" since="$2"
    systemctl show "$unit" \
        -p Result -p ExecMainStatus -p ActiveState -p SubState \
        --no-pager
    journalctl -u "$unit" --since "$since" --no-pager
}

show_epoch_state() {
    local label="$1" path="$2" value=""
    if [[ -f "$path" ]]; then
        read -r value < "$path" || true
    fi
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s: %s\n' "$label" "$(date --date="@$value" --iso-8601=seconds)"
    else
        printf '%s: none\n' "$label"
    fi
}

run_upload_check() {
    local started_at output rc
    systemctl is-active --quiet "$MINECRAFT_SERVICE" || {
        echo "Minecraft is not active; refusing to begin a cold-backup check." >&2
        exit 1
    }
    systemctl cat "$BACKUP_UNIT" >/dev/null 2>&1 || {
        echo "Unit is not installed: $BACKUP_UNIT" >&2
        exit 1
    }

    started_at="$(date --iso-8601=seconds)"
    echo "Starting $BACKUP_UNIT at $started_at"
    if systemctl start "$BACKUP_UNIT"; then
        rc=0
    else
        rc=$?
    fi
    output="$(journalctl -u "$BACKUP_UNIT" --since "$started_at" --no-pager)"
    show_result "$BACKUP_UNIT" "$started_at"

    (( rc == 0 )) || {
        echo "$BACKUP_UNIT failed; the timer was not changed." >&2
        exit "$rc"
    }
    if grep -q 'A backup or upload task is already running; skipping' <<<"$output"; then
        echo "No new task ran because another cold-backup/upload task owns the shared lock." >&2
        exit 3
    fi
}

show_status() {
    echo '=== Services ==='
    printf 'Minecraft: '
    systemctl is-active "$MINECRAFT_SERVICE" || true
    printf 'Automatic timer enabled: '
    systemctl is-enabled "$BACKUP_TIMER" || true
    printf 'Automatic timer active: '
    systemctl is-active "$BACKUP_TIMER" || true
    printf 'Backup task: '
    systemctl is-active "$BACKUP_UNIT" || true

    echo '=== Players ==='
    rcon_list || echo 'WARNING: RCON player query failed' >&2

    echo '=== Schedule ==='
    systemctl list-timers "$BACKUP_TIMER" --no-pager || true

    echo '=== Latest result ==='
    systemctl show "$BACKUP_UNIT" \
        -p Result -p ExecMainStatus -p ActiveState -p SubState \
        --no-pager || true

    echo '=== Observation and retry state ==='
    show_epoch_state 'Offline since' "$BACKUP_DIR/.offline-since"
    show_epoch_state 'Last player check' "$BACKUP_DIR/.last-player-check"
    show_epoch_state 'Upload retry after' "$BACKUP_DIR/.upload-retry-after"

    echo '=== Local backup markers ==='
    find "$BACKUP_DIR" -maxdepth 1 -type f \
        \( -name "${BACKUP_PREFIX}_cold_*.ready" \
           -o -name "${BACKUP_PREFIX}_cold_*.uploaded" \
           -o -name "${BACKUP_PREFIX}_cold_*.partial" \) \
        -printf '%TY-%Tm-%TdT%TH:%TM:%TS %f %s bytes\n' 2>/dev/null | sort || true

    echo '=== Storage ==='
    df -hT "$BACKUP_DIR" || true
    du -sh "$BACKUP_DIR" 2>/dev/null || true
}

show_logs() {
    local lines="${1:-200}"
    [[ "$lines" =~ ^[1-9][0-9]*$ ]] && (( lines <= 5000 )) || {
        echo "LINES must be an integer from 1 through 5000." >&2
        exit 2
    }
    journalctl -u "$BACKUP_UNIT" -n "$lines" --no-pager
}

verify_local() {
    local checksum archive manifest failures=0
    local checksums=()
    mapfile -d '' checksums < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f \
            -name "${BACKUP_PREFIX}_cold_*.tar.zst.sha256" -print0 | sort -z
    )
    ((${#checksums[@]} > 0)) || {
        echo "No local cold-backup checksum files were found in $BACKUP_DIR" >&2
        exit 1
    }

    for checksum in "${checksums[@]}"; do
        archive="${checksum%.sha256}"
        if [[ ! -s "$archive" ]]; then
            echo "MISSING: $archive" >&2
            failures=$((failures + 1))
            continue
        fi
        if ! (cd "$BACKUP_DIR" && sha256sum -c "$(basename -- "$checksum")"); then
            failures=$((failures + 1))
        fi
        manifest="${archive}.parts.sha256"
        if [[ -f "$manifest" ]] && \
           ! (cd "$BACKUP_DIR" && sha256sum -c "$(basename -- "$manifest")"); then
            failures=$((failures + 1))
        fi
    done

    (( failures == 0 )) || {
        echo "$failures local verification check(s) failed." >&2
        exit 1
    }
    echo "All local cold-backup SHA-256 checks passed."
}

show_cloud() {
    local start=0 page page_items page_count total=0
    [[ -x "$BDPAN_BIN" ]] || {
        echo "bdpan is missing: $BDPAN_BIN" >&2
        exit 1
    }
    [[ -x "$BDPAN_LISTING" ]] || {
        echo "bdpan listing helper is missing: $BDPAN_LISTING" >&2
        exit 1
    }
    echo "Cloud directory: /apps/bdpan/$REMOTE_ROOT"
    echo 'Verified completion manifests:'
    while true; do
        page="$(run_as_minecraft "$BDPAN_BIN" ls "$REMOTE_ROOT" \
            --json --order name --start "$start" --limit 1000)"
        page_items="$(printf '%s' "$page" | python3 "$BDPAN_LISTING" length)"
        page_count="$(printf '%s' "$page" | python3 "$BDPAN_LISTING" count "$BACKUP_PREFIX")"
        printf '%s' "$page" | python3 "$BDPAN_LISTING" completed "$BACKUP_PREFIX"
        [[ "$page_items" =~ ^[0-9]+$ && "$page_count" =~ ^[0-9]+$ ]] || {
            echo 'Cannot safely parse the cloud listing.' >&2
            exit 1
        }
        total=$((total + page_count))
        (( page_items < 1000 )) && break
        start=$((start + page_items))
    done
    echo "Completed cloud backups: $total"
}

pause_automatic() {
    systemctl disable --now "$BACKUP_TIMER"
    echo "Future automatic checks are disabled. Existing backups were not deleted."
    if systemctl is-active --quiet "$BACKUP_UNIT"; then
        echo "A backup/upload task is already running and was left alone so its recovery path can finish."
    else
        echo "No backup/upload task is currently running."
    fi
    printf 'Minecraft: '
    systemctl is-active "$MINECRAFT_SERVICE" || true
}

resume_automatic() {
    systemctl is-active --quiet "$MINECRAFT_SERVICE" || {
        echo "Minecraft is not active; refusing to enable automatic backups." >&2
        exit 1
    }
    [[ -x "$RCON_CLIENT" && -r "$RCON_PASSWORD_FILE" ]] || {
        echo "RCON client or credential is unavailable." >&2
        exit 1
    }
    rcon_list >/dev/null || {
        echo "RCON preflight failed; refusing to enable automatic backups." >&2
        exit 1
    }
    [[ -x "$BDPAN_BIN" ]] || {
        echo "bdpan is missing: $BDPAN_BIN" >&2
        exit 1
    }
    run_as_minecraft "$BDPAN_BIN" whoami | grep -q '已登录' || {
        echo "bdpan is not logged in for the minecraft user." >&2
        exit 1
    }

    # Any scheduler pause is an observation gap. Start a fresh quiet period so
    # unobserved time can never count toward the 30-minute shutdown condition.
    rm -f -- \
        "$BACKUP_DIR/.offline-since" \
        "$BACKUP_DIR/.last-player-check" \
        "$BACKUP_DIR/.cold-snapshot-for"
    systemctl enable --now "$BACKUP_TIMER"
    echo "Automatic checks are enabled; the 30-minute observation starts fresh."
    systemctl list-timers "$BACKUP_TIMER" --no-pager
}

action="${1:-}"
if [[ $# -gt 0 ]]; then
    shift
fi

case "$action" in
    upload|check)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        echo "This never bypasses player checks or the continuous 30-minute offline requirement."
        echo "An existing .ready cold backup is uploaded without stopping Minecraft."
        echo "Only when no queued cold backup exists will an eligible cycle stop Minecraft first."
        run_upload_check
        ;;
    status)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        show_status
        ;;
    logs)
        [[ $# -le 1 ]] || { usage >&2; exit 2; }
        show_logs "${1:-200}"
        ;;
    verify-local)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        verify_local
        ;;
    cloud)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        show_cloud
        ;;
    pause)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        pause_automatic
        ;;
    resume)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        resume_automatic
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
