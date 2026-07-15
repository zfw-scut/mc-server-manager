#!/usr/bin/env bash

set -Eeuo pipefail

configure_rcon=false
enable_timer=false
for argument in "$@"; do
    case "$argument" in
        --configure-rcon) configure_rcon=true ;;
        --enable-timer) enable_timer=true ;;
        *) echo "Usage: $0 [--configure-rcon] [--enable-timer]" >&2; exit 2 ;;
    esac
done

if [[ "$configure_rcon" == true && "$enable_timer" == true ]]; then
    echo "Run --configure-rcon, restart Minecraft, and test once before using --enable-timer." >&2
    exit 2
fi

(( EUID == 0 )) || { echo "Run this installer as root" >&2; exit 1; }
root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 0755 /usr/local/libexec/minecraft-backup
install -m 0755 "$root_dir/bin/minecraft-rcon.py" /usr/local/libexec/minecraft-backup/
install -m 0755 "$root_dir/bin/bdpan-listing.py" /usr/local/libexec/minecraft-backup/
install -m 0755 "$root_dir/bin/configure-rcon.py" /usr/local/libexec/minecraft-backup/
install -m 0755 "$root_dir/bin/minecraft-backup.sh" /usr/local/libexec/minecraft-backup/
install -m 0755 "$root_dir/bin/minecraft-backup-upload.sh" /usr/local/libexec/minecraft-backup/
install -m 0755 "$root_dir/bin/minecraft-backup-recover.sh" /usr/local/libexec/minecraft-backup/
install -m 0755 "$root_dir/bin/minecraft-backup-now.sh" /usr/local/sbin/minecraft-backup-now

if [[ ! -e /etc/minecraft-backup.conf ]]; then
    install -m 0644 "$root_dir/etc/minecraft-backup.conf" /etc/minecraft-backup.conf
else
    echo "Keeping existing /etc/minecraft-backup.conf"
fi

ensure_config_default() {
    local key="$1" value="$2"
    if ! grep -q "^${key}=" /etc/minecraft-backup.conf; then
        printf '%s=%s\n' "$key" "$value" >> /etc/minecraft-backup.conf
    fi
}
ensure_config_default MINECRAFT_SERVICE hello-new-generation.service
ensure_config_default MINECRAFT_USER minecraft
ensure_config_default MINECRAFT_HOME /data/minecraft
ensure_config_default MINECRAFT_START_TIMEOUT_SECONDS 300
ensure_config_default PLAYER_CHECK_MAX_GAP_SECONDS 600
ensure_config_default UPLOAD_RETRY_DELAY_MINUTES 60
ensure_config_default UPLOAD_PART_SIZE_MIB 256
ensure_config_default REMOTE_QUERY_ATTEMPTS 4
ensure_config_default REMOTE_QUERY_RETRY_SECONDS 10

install -m 0644 "$root_dir/systemd/minecraft-backup-upload.service" /etc/systemd/system/
install -m 0644 "$root_dir/systemd/minecraft-backup-upload.timer" /etc/systemd/system/
install -d -o minecraft -g minecraft -m 0750 /data/minecraft/backups/hello-new-generation
install -d -o minecraft -g minecraft -m 0700 /data/minecraft/.config/bdpan

# Remove the abandoned hourly hot-backup scheduler during upgrades.
systemctl disable --now minecraft-backup.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/minecraft-backup.timer \
    /etc/systemd/system/minecraft-backup.service

if [[ "$configure_rcon" == true ]]; then
    install -d -o root -g root -m 0700 /etc/minecraft-backup
    if [[ ! -e /etc/minecraft-backup/rcon-password ]]; then
        if command -v openssl >/dev/null; then
            openssl rand -base64 36 | tr -d '\n' > /etc/minecraft-backup/rcon-password
        else
            head -c 48 /dev/urandom | base64 | tr -d '\n' > /etc/minecraft-backup/rcon-password
        fi
        chmod 0600 /etc/minecraft-backup/rcon-password
    fi
    python3 /usr/local/libexec/minecraft-backup/configure-rcon.py \
        /data/minecraft/hello-new-generation/server.properties \
        /etc/minecraft-backup/rcon-password
    chown minecraft:minecraft /data/minecraft/hello-new-generation/server.properties
    chmod 0640 /data/minecraft/hello-new-generation/server.properties
    echo "RCON was configured. Restart hello-new-generation.service during an approved window."
fi

systemctl daemon-reload
if [[ "$enable_timer" == true ]]; then
    [[ -r /etc/minecraft-backup/rcon-password ]] || {
        echo "RCON credential is missing; refusing to enable timers." >&2
        exit 1
    }
    # shellcheck source=/dev/null
    source /etc/minecraft-backup.conf
    python3 /usr/local/libexec/minecraft-backup/minecraft-rcon.py \
        --host "${RCON_HOST:-127.0.0.1}" --port "${RCON_PORT:-25575}" \
        --password-file /etc/minecraft-backup/rcon-password --timeout 30 list >/dev/null || {
        echo "RCON preflight failed; restart/test Minecraft before enabling timers." >&2
        exit 1
    }
    BDPAN_BIN="${BDPAN_BIN:-/data/minecraft/.local/bin/bdpan}"
    [[ -x "$BDPAN_BIN" ]] || {
        echo "bdpan is missing; refusing to enable timers." >&2
        exit 1
    }
    runuser -u minecraft -- env HOME=/data/minecraft "$BDPAN_BIN" whoami | grep -q '已登录' || {
        echo "bdpan is not logged in for the minecraft user; refusing to enable timers." >&2
        exit 1
    }
    systemctl enable --now minecraft-backup-upload.timer
else
    echo "Cold-backup timer installed but not enabled. Use --enable-timer only after the manual cold-backup test passes."
fi
