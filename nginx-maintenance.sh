#!/usr/bin/env bash
# ============================================================
# NGINX MAINTENANCE TOOLKIT
# Ubuntu 24.04+ / Nginx packages
#
# Commands:
#   backup       Backup config + systemd + package information
#   upgrade      Backup, refresh APT, simulate, confirm, upgrade
#   health       Check Nginx; optionally check supplied URLs
#   rollback     Restore Nginx config from a selected backup
#   menu         Interactive menu
#
# IMPORTANT:
# - This script does not promise zero downtime. Package maintainer
#   scripts may reload/restart services during an upgrade.
# - Rollback restores configuration, not the old Nginx binary.
#   Binary downgrade must be handled separately if the old package
#   version is still available.
# ============================================================

set -Eeuo pipefail
umask 077

TOOL_NAME="nginx-maintenance"
BACKUP_ROOT="/root/nginx-backups"
LOG_ROOT="/var/log/nginx-maintenance"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CURRENT_LOG=""
CURRENT_BACKUP=""

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo $0 <command>"
}

require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

init_log() {
    mkdir -p "$LOG_ROOT"
    CURRENT_LOG="${LOG_ROOT}/Log-${TOOL_NAME}-${TIMESTAMP}.txt"
    touch "$CURRENT_LOG"
    exec > >(tee -a "$CURRENT_LOG") 2>&1
    log "Log file: $CURRENT_LOG"
}

latest_backup() {
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-
}

backup() {
    require_commands nginx dpkg-query apt-mark systemctl
    mkdir -p "$BACKUP_ROOT"

    CURRENT_BACKUP="${BACKUP_ROOT}/${TIMESTAMP}"
    mkdir -p "$CURRENT_BACKUP"

    log "Testing current Nginx configuration..."
    nginx -t

    log "Backing up /etc/nginx..."
    cp -a /etc/nginx "$CURRENT_BACKUP/"

    log "Backing up systemd override..."
    if [[ -d /etc/systemd/system/nginx.service.d ]]; then
        mkdir -p "$CURRENT_BACKUP/systemd"
        cp -a /etc/systemd/system/nginx.service.d "$CURRENT_BACKUP/systemd/"
    else
        mkdir -p "$CURRENT_BACKUP/systemd"
        touch "$CURRENT_BACKUP/systemd/NO_NGINX_OVERRIDE_PRESENT"
    fi

    log "Saving installed Nginx package versions..."
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 'nginx*' \
        > "$CURRENT_BACKUP/nginx-packages.txt" 2>&1 || true

    dpkg-query -W -f='${binary:Package}\t${Version}\n' nginx \
        > "$CURRENT_BACKUP/nginx-main-package.txt" 2>&1 || true

    apt-mark showmanual > "$CURRENT_BACKUP/manual-packages.txt"

    log "Saving Nginx build information and expanded configuration..."
    nginx -V > "$CURRENT_BACKUP/nginx-build-info.txt" 2>&1
    nginx -T > "$CURRENT_BACKUP/nginx-full-config.txt" 2>&1

    log "Saving OS and service information..."
    {
        echo "Date: $(date -Is)"
        echo "Hostname: $(hostname)"
        echo
        cat /etc/os-release
        echo
        nginx -v 2>&1
        echo
        systemctl status nginx --no-pager -l || true
        echo
        apt-cache policy nginx || true
    } > "$CURRENT_BACKUP/system-info.txt" 2>&1

    log "Backup completed: $CURRENT_BACKUP"
    log "Remember: keep this backup private; Nginx configuration may contain secrets."
}

check_upgrade_plan() {
    local simulation_file
    simulation_file="$(mktemp)"
    trap 'rm -f "$simulation_file"' RETURN

    log "Refreshing APT package lists..."
    apt-get update

    log "Current and candidate Nginx package versions:"
    apt-cache policy nginx

    log "Simulating upgrade (no changes will be made)..."
    if ! apt-get -s install --only-upgrade nginx | tee "$simulation_file"; then
        die "APT simulation failed. No upgrade was performed."
    fi

    if grep -Eq '^(Remv |The following packages will be REMOVED:)' "$simulation_file"; then
        die "APT proposes removing packages. Upgrade cancelled."
    fi

    if ! grep -Eq '^(Inst nginx |Conf nginx )' "$simulation_file"; then
        log "APT did not report an nginx package upgrade. It may already be current."
    fi

    echo
    log "Review the simulation above."
    read -r -p "Proceed with Nginx package upgrade? Type YES to continue: " answer
    [[ "$answer" == "YES" ]] || die "Upgrade cancelled by user."

    log "Installing Nginx package upgrade..."
    apt-get install --only-upgrade nginx
}

upgrade() {
    require_commands nginx apt-get apt-cache dpkg-query apt-mark systemctl
    backup
    check_upgrade_plan

    log "Checking upgraded Nginx binary and configuration..."
    nginx -v
    nginx -V 2>&1
    if ! nginx -t; then
        log "ERROR: nginx -t failed after package upgrade."
        log "The script will NOT reload or restart Nginx."
        log "Inspect the error and restore configuration if necessary:"
        log "  $0 rollback $CURRENT_BACKUP"
        exit 2
    fi

    log "Reloading Nginx to apply the validated configuration..."
    if ! systemctl reload nginx; then
        log "ERROR: systemctl reload failed."
        log "No automatic restart will be attempted."
        log "Check: systemctl status nginx --no-pager -l"
        exit 3
    fi

    sleep 2
    if ! systemctl is-active --quiet nginx; then
        die "Nginx is not active after reload. Inspect service status and logs."
    fi

    log "Upgrade workflow completed. Run health checks:"
    log "  $0 health https://your-domain.example"
    log "Backup used for this upgrade: $CURRENT_BACKUP"
}

health() {
    require_commands nginx systemctl
    log "Nginx version:"
    nginx -v 2>&1

    log "Configuration test:"
    nginx -t

    log "Service status:"
    systemctl is-active nginx
    systemctl status nginx --no-pager -l || true

    log "Listening sockets:"
    if command -v ss >/dev/null 2>&1; then
        ss -lntp | grep -E ':(80|443)\b' || true
    fi

    if [[ "$#" -gt 0 ]]; then
        require_commands curl
        local url
        for url in "$@"; do
            log "HTTP check: $url"
            curl --location --silent --show-error --output /dev/null \
                --connect-timeout 10 --max-time 30 \
                --write-out 'HTTP %{http_code} | %{remote_ip} | %{time_total}s\n' \
                "$url" || log "WARNING: request failed for $url"
        done
    else
        log "No URL supplied. Example: $0 health https://example.com"
    fi

    log "Recent Nginx errors (if any):"
    journalctl -u nginx -p err -n 30 --no-pager || true
}

rollback() {
    require_commands nginx systemctl
    local backup_dir="${1:-}"

    if [[ -z "$backup_dir" ]]; then
        backup_dir="$(latest_backup)"
    fi

    [[ -n "$backup_dir" ]] || die "No backup found. Usage: $0 rollback /root/nginx-backups/TIMESTAMP"
    [[ -d "$backup_dir/nginx" ]] || die "Backup does not contain an nginx/ directory: $backup_dir"

    echo "Selected backup: $backup_dir"
    echo "This will replace /etc/nginx with the backed-up configuration."
    read -r -p "Type RESTORE to continue: " answer
    [[ "$answer" == "RESTORE" ]] || die "Rollback cancelled by user."

    local safety_dir="${BACKUP_ROOT}/before-rollback-${TIMESTAMP}"
    mkdir -p "$safety_dir"
    if [[ -d /etc/nginx ]]; then
        cp -a /etc/nginx "$safety_dir/"
    fi
    if [[ -d /etc/systemd/system/nginx.service.d ]]; then
        mkdir -p "$safety_dir/systemd"
        cp -a /etc/systemd/system/nginx.service.d "$safety_dir/systemd/"
    fi

    log "Current configuration saved to: $safety_dir"
    log "Restoring /etc/nginx..."
    rm -rf /etc/nginx
    cp -a "$backup_dir/nginx" /etc/nginx

    log "Restoring systemd override state..."
    if [[ -f "$backup_dir/systemd/NO_NGINX_OVERRIDE_PRESENT" ]]; then
        rm -rf /etc/systemd/system/nginx.service.d
    elif [[ -d "$backup_dir/systemd/nginx.service.d" ]]; then
        rm -rf /etc/systemd/system/nginx.service.d
        cp -a "$backup_dir/systemd/nginx.service.d" /etc/systemd/system/
    fi

    systemctl daemon-reload

    log "Testing restored configuration..."
    if ! nginx -t; then
        log "ERROR: restored configuration failed validation."
        log "The pre-rollback configuration is preserved at: $safety_dir"
        log "Nginx has NOT been reloaded or restarted."
        exit 4
    fi

    log "Reloading Nginx with restored configuration..."
    systemctl reload nginx
    systemctl is-active --quiet nginx || die "Nginx is not active after rollback reload."

    log "Configuration rollback completed."
    log "IMPORTANT: Nginx binary/package version was NOT downgraded."
    log "If binary downgrade is required, check whether the previous package version is still available:"
    if [[ -f "$backup_dir/nginx-main-package.txt" ]]; then
        cat "$backup_dir/nginx-main-package.txt"
    fi
    log "Do not downgrade blindly; verify package availability and dependencies first."
}

menu() {
    echo
    echo "======================================"
    echo " NGINX MAINTENANCE TOOLKIT"
    echo "======================================"
    echo "1) Backup configuration"
    echo "2) Upgrade Nginx (with backup + simulation)"
    echo "3) Health check"
    echo "4) Rollback configuration"
    echo "0) Exit"
    echo
    read -r -p "Select: " choice

    case "$choice" in
        1) backup ;;
        2) upgrade ;;
        3)
            read -r -p "Optional URL to check (Enter to skip): " url
            if [[ -n "$url" ]]; then health "$url"; else health; fi
            ;;
        4)
            read -r -p "Backup directory (Enter = latest): " dir
            if [[ -n "$dir" ]]; then rollback "$dir"; else rollback; fi
            ;;
        0) exit 0 ;;
        *) die "Invalid selection." ;;
    esac
}

main() {
    require_root
    init_log

    case "${1:-menu}" in
        backup) backup ;;
        upgrade) upgrade ;;
        health) shift; health "$@" ;;
        rollback) shift; rollback "${1:-}" ;;
        menu) menu ;;
        -h|--help|help)
            cat <<EOF
Usage:
  $0 backup
  $0 upgrade
  $0 health [https://domain.example ...]
  $0 rollback [backup-directory]
  $0 menu
EOF
            ;;
        *) die "Unknown command: $1. Use --help." ;;
    esac

    log "Finished."
}

main "$@"
