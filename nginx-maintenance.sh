#!/usr/bin/env bash
# ============================================================
# NGINX MAINTENANCE TOOLKIT (v8)
# Ubuntu 24.04+ / Debian-based systems / APT Nginx packages
#
# Commands:
#   backup       Backup Nginx config and related system settings
#   upgrade      Backup, refresh APT, simulate, confirm, upgrade
#   health       Check config, service, listeners and optional URLs
#   list         List available backups and their validation status
#   rollback     Restore configuration from a trusted backup
#   menu         Interactive menu
#
# v8 audit fixes:
# - Match TCP ports accurately across IPv4/IPv6/wildcard addresses in
#   check_listeners() regardless of whitespace alignment.
# - Log a clear warning when "nginx -T" writes non-empty stderr to
#   nginx-T-errors.txt during backup.
# - Surface non-zero return codes from rollback_apply() explicitly
#   in rollback() so callers/logs see exact failure/revert status.
#
# v7 changes:
# - Separate stdout and stderr of "nginx -T" so warnings/errors do
#   not pollute parsed config/SSL/include files.
# - Keep global TIMESTAMP immutable; use local timestamps in functions.
# - Add "list" command (and menu option) to inspect backups.
#
# IMPORTANT:
# - This is not a zero-downtime upgrade guarantee. APT package
#   maintainer scripts may reload/restart Nginx during installation.
# - Rollback restores configuration/system settings, NOT the old
#   Nginx binary/package version.
# - SSL files outside /etc/nginx (for example /etc/letsencrypt)
#   are NOT copied. Their referenced paths are recorded only.
#   Non-secret include files outside /etc/nginx are copied for
#   reference into external-includes/ but are NOT restored.
# - Backups may contain credentials/private configuration. Keep
#   /root/nginx-backups private and maintain an off-server snapshot.
# ============================================================

set -Eeuo pipefail
umask 077

TOOL_NAME="nginx-maintenance"
BACKUP_ROOT="/root/nginx-backups"
LOG_ROOT="/var/log/nginx-maintenance"
LOCK_FILE="/var/lock/${TOOL_NAME}.lock"
KEEP_BACKUPS=10
KEEP_INVALID_BACKUPS=3   # CONFIG_INVALID backups are counted separately
KEEP_LOGS=30

RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CURRENT_LOG=""
CURRENT_BACKUP=""
EXIT_CODE=0

# Optional: space-separated TCP ports that "health" must find owned by
# Nginx, e.g. HEALTH_PORTS="80 443" or HEALTH_PORTS="8080".
# If empty, health only requires some TCP listener owned by an nginx process.
HEALTH_PORTS="${HEALTH_PORTS:-}"

# Never fails: a dead log pipe (e.g. SSH dropped) must not abort the
# script, least of all in the middle of a rollback.
log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" || true
}

# die writes to stderr so the message is still visible when die is
# called inside a $(...) command substitution. stderr is also teed
# into the log file after init_log.
die() {
    log "ERROR: $*" >&2
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

# umask 077 only affects NEW directories; chmod covers pre-existing ones.
ensure_private_dir() {
    mkdir -p "$1" || die "Cannot create directory: $1"
    chmod 700 "$1" || die "Cannot set permissions on directory: $1"
}

acquire_lock() {
    require_commands flock
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another ${TOOL_NAME} instance is already running."
}

init_log() {
    ensure_private_dir "$LOG_ROOT"
    CURRENT_LOG="${LOG_ROOT}/Log-${TOOL_NAME}-${RUN_TIMESTAMP}.txt"
    if [[ -e "$CURRENT_LOG" ]]; then
        CURRENT_LOG="${LOG_ROOT}/Log-${TOOL_NAME}-${RUN_TIMESTAMP}-$$.txt"
    fi
    touch "$CURRENT_LOG"
    exec > >(tee -a "$CURRENT_LOG") 2>&1
    log "Log file: $CURRENT_LOG"
}

new_timestamp() {
    local value
    value="$(date +%Y%m%d-%H%M%S)"
    if [[ -e "${BACKUP_ROOT}/${value}" || -e "${BACKUP_ROOT}/before-rollback-${value}" ]]; then
        value="${value}-$$"
    fi
    printf '%s' "$value"
}

# Newest backup that has an nginx/ dir and is NOT marked CONFIG_INVALID.
latest_backup() {
    [[ -d "$BACKUP_ROOT" ]] || return 0
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -name '[0-9]*-[0-9]*' \
        -exec test -d '{}/nginx' \; \
        ! -exec test -e '{}/CONFIG_INVALID' \; \
        -print 2>/dev/null \
        | sort -r | sed -n '1p'
}

list_backups() {
    local item name status pkg_ver found=0
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        log "Backup directory does not exist yet: $BACKUP_ROOT"
        return 0
    fi

    log "Available backups in $BACKUP_ROOT:"
    printf '%-28s %-16s %s\n' "BACKUP_DIR" "STATUS" "NGINX_VERSION"
    printf '%-28s %-16s %s\n' "----------" "------" "-------------"

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        found=1
        name="$(basename "$item")"
        if [[ ! -d "$item/nginx" ]]; then
            status="INCOMPLETE"
        elif [[ -e "$item/CONFIG_INVALID" ]]; then
            status="CONFIG_INVALID"
        else
            status="VALID"
        fi
        pkg_ver="unknown"
        if [[ -f "$item/nginx-main-package.txt" ]]; then
            pkg_ver="$(awk '{print $2}' "$item/nginx-main-package.txt" | head -n1)"
            [[ -n "$pkg_ver" ]] || pkg_ver="unknown"
        fi
        printf '%-28s %-16s %s\n' "$item" "$status" "$pkg_ver"
    done < <(
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
            \( -name '[0-9]*-[0-9]*' -o -name 'before-rollback-*' \) 2>/dev/null \
            | sort -r
    )

    if [[ "$found" -eq 0 ]]; then
        log "No backups found."
    fi
}

prune_old() {
    local dir="$1" pattern="$2" type="$3" keep="$4" item
    [[ -d "$dir" ]] || return 0
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        log "Removing old retained item: $item"
        rm -rf -- "$item"
    done < <(
        find "$dir" -mindepth 1 -maxdepth 1 -type "$type" -name "$pattern" 2>/dev/null \
            | sort -r | tail -n +"$((keep + 1))"
    )
}

# Valid and CONFIG_INVALID backups have separate quotas, so a series of
# failed backups can never push good backups out of retention.
prune_backups() {
    local item valid=0 invalid=0
    [[ -d "$BACKUP_ROOT" ]] || return 0
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        if [[ -e "$item/CONFIG_INVALID" ]]; then
            invalid=$((invalid + 1))
            (( invalid > KEEP_INVALID_BACKUPS )) || continue
        else
            valid=$((valid + 1))
            (( valid > KEEP_BACKUPS )) || continue
        fi
        log "Removing old retained item: $item"
        rm -rf -- "$item"
    done < <(
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*' 2>/dev/null \
            | sort -r
    )
}

prune_all() {
    prune_backups
    prune_old "$BACKUP_ROOT" 'before-rollback-*' d "$KEEP_BACKUPS"
    prune_old "$LOG_ROOT" "Log-${TOOL_NAME}-*.txt" f "$KEEP_LOGS"
}

# Reload when running; start when stopped (a stopped Nginx is a common
# reason to roll back, and "reload" would fail on it).
reload_or_start_nginx() {
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        log "Nginx is not running; starting it instead of reloading."
        systemctl start nginx
    fi
}

# ---------- save helpers ----------

save_systemd_state() {
    local destination="$1"
    mkdir -p "$destination/systemd"
    if [[ -d /etc/systemd/system/nginx.service.d ]]; then
        cp -a /etc/systemd/system/nginx.service.d "$destination/systemd/"
    else
        touch "$destination/systemd/NO_NGINX_OVERRIDE_PRESENT"
    fi
    # Full unit override (or mask symlink) in /etc/systemd/system.
    if [[ -e /etc/systemd/system/nginx.service || -L /etc/systemd/system/nginx.service ]]; then
        cp -a /etc/systemd/system/nginx.service "$destination/systemd/nginx.service"
    else
        touch "$destination/systemd/NO_NGINX_UNIT_PRESENT"
    fi
}

save_logrotate_state() {
    local destination="$1"
    if [[ -f /etc/logrotate.d/nginx ]]; then
        cp -a /etc/logrotate.d/nginx "$destination/logrotate-nginx"
    else
        touch "$destination/NO_LOGROTATE_NGINX_PRESENT"
    fi
}

save_default_state() {
    local destination="$1"
    if [[ -f /etc/default/nginx ]]; then
        cp -a /etc/default/nginx "$destination/default-nginx"
    else
        touch "$destination/NO_DEFAULT_NGINX_PRESENT"
    fi
}

# ---------- restore helpers ----------
# The restore_* functions run inside "if !" / "||" contexts where set -e
# is ignored, so every step checks its own result and returns 1 instead
# of calling die (which would exit mid-rollback and skip the revert).

restore_systemd_from() {
    local source="$1"
    if [[ -f "$source/systemd/NO_NGINX_OVERRIDE_PRESENT" ]]; then
        rm -rf /etc/systemd/system/nginx.service.d || return 1
    elif [[ -d "$source/systemd/nginx.service.d" ]]; then
        rm -rf /etc/systemd/system/nginx.service.d || return 1
        cp -a "$source/systemd/nginx.service.d" /etc/systemd/system/ || return 1
    else
        log "ERROR: Backup is missing systemd state: $source"
        return 1
    fi

    # Unit file state exists only in v6+ backups; older ones are skipped.
    if [[ -f "$source/systemd/NO_NGINX_UNIT_PRESENT" ]]; then
        rm -f /etc/systemd/system/nginx.service || return 1
    elif [[ -e "$source/systemd/nginx.service" || -L "$source/systemd/nginx.service" ]]; then
        rm -f /etc/systemd/system/nginx.service || return 1
        cp -a "$source/systemd/nginx.service" /etc/systemd/system/nginx.service || return 1
    else
        log "NOTE: Backup has no nginx.service unit state (older backup); leaving it unchanged."
    fi
}

restore_logrotate_from() {
    local source="$1"
    if [[ -f "$source/NO_LOGROTATE_NGINX_PRESENT" ]]; then
        rm -f /etc/logrotate.d/nginx || return 1
    elif [[ -f "$source/logrotate-nginx" ]]; then
        install -D -o root -g root -m 0644 "$source/logrotate-nginx" /etc/logrotate.d/nginx || return 1
    else
        log "ERROR: Backup is missing logrotate state: $source"
        return 1
    fi
}

restore_default_from() {
    local source="$1"
    if [[ -f "$source/NO_DEFAULT_NGINX_PRESENT" ]]; then
        rm -f /etc/default/nginx || return 1
    elif [[ -f "$source/default-nginx" ]]; then
        install -D -o root -g root -m 0644 "$source/default-nginx" /etc/default/nginx || return 1
    else
        log "NOTE: Backup has no /etc/default/nginx state (older backup); leaving it unchanged."
    fi
}

save_current_state() {
    local destination="$1"
    mkdir -p "$destination"
    if [[ -d /etc/nginx ]]; then
        cp -a /etc/nginx "$destination/"
    else
        die "/etc/nginx does not exist; refusing to continue."
    fi
    save_systemd_state "$destination"
    save_logrotate_state "$destination"
    save_default_state "$destination"
}

restore_auxiliary_state() {
    local source="$1"
    restore_systemd_from "$source" || return 1
    restore_logrotate_from "$source" || return 1
    restore_default_from "$source" || return 1
    systemctl daemon-reload || return 1
}

# Records include files outside /etc/nginx (e.g. certbot's
# options-ssl-nginx.conf) and copies them for reference.
save_external_includes() {
    local destination="$1" file
    sed -nE 's/^# configuration file (.*):$/\1/p' "$destination/nginx-full-config.txt" 2>/dev/null \
        | grep -v '^/etc/nginx/' | sort -u > "$destination/external-includes.txt" || true

    [[ -s "$destination/external-includes.txt" ]] || return 0
    log "Copying external include files (reference only, not restored by rollback)..."
    while IFS= read -r file; do
        [[ -n "$file" && -f "$file" ]] || continue
        case "$file" in
            *.key|*/privkey*|*/private/*)
                log "Skipping private-looking file: $file"
                continue
                ;;
        esac
        mkdir -p "$destination/external-includes"
        cp -a --parents "$file" "$destination/external-includes" \
            || log "WARNING: could not copy external include: $file"
    done < "$destination/external-includes.txt"
}

backup() {
    require_commands nginx dpkg-query systemctl cp
    local ts work config_ok=1
    ensure_private_dir "$BACKUP_ROOT"

    # Staging dirs left by an interrupted run are stale (we hold the lock).
    # Backups are built in .tmp-<ts> and renamed only when complete, so a
    # half-written backup can never be picked for rollback.
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.tmp-*' \
        -exec rm -rf -- {} + 2>/dev/null || true

    ts="$(new_timestamp)"
    CURRENT_BACKUP="${BACKUP_ROOT}/${ts}"
    work="${BACKUP_ROOT}/.tmp-${ts}"
    mkdir -p "$work"

    log "Creating backup at: $CURRENT_BACKUP (staging: $work)"
    log "Copying /etc/nginx before validation so even an invalid current config is preserved..."
    cp -a /etc/nginx "$work/"

    save_systemd_state "$work"
    save_logrotate_state "$work"
    save_default_state "$work"

    log "Saving installed Nginx package versions..."
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 'nginx*' \
        > "$work/nginx-packages.txt" 2>&1 || true
    dpkg-query -W -f='${binary:Package}\t${Version}\n' nginx \
        > "$work/nginx-main-package.txt" 2>&1 || true

    log "Saving Nginx build information and expanded configuration..."
    nginx -V > "$work/nginx-build-info.txt" 2>&1 || true
    # Keep stdout clean for config parsing; save stderr separately.
    nginx -T > "$work/nginx-full-config.txt" 2> "$work/nginx-T-errors.txt" || true
    if [[ -s "$work/nginx-T-errors.txt" ]]; then
        log "WARNING: 'nginx -T' emitted messages to stderr; see $CURRENT_BACKUP/nginx-T-errors.txt"
    fi

    log "Recording SSL certificate/key paths referenced by Nginx config..."
    grep -hEo '^[[:space:]]*ssl_(certificate|certificate_key|trusted_certificate|dhparam)[[:space:]]+[^;]+' \
        "$work/nginx-full-config.txt" 2>/dev/null \
        | sed -E 's/^[[:space:]]+//' | sort -u \
        > "$work/ssl-paths.txt" || true

    log "Recording include files outside /etc/nginx..."
    save_external_includes "$work"

    log "Saving OS, service and package policy information..."
    {
        echo "Backup date: $(date -Is)"
        echo "Hostname: $(hostname)"
        echo
        cat /etc/os-release
        echo
        nginx -v 2>&1 || true
        echo
        systemctl status nginx --no-pager -l || true
        echo
        apt-cache policy nginx || true
    } > "$work/system-info.txt" 2>&1

    log "Validating current Nginx configuration..."
    nginx -t || config_ok=0
    if [[ "$config_ok" -eq 0 ]]; then
        touch "$work/CONFIG_INVALID"
    fi

    # Publish atomically: only complete backups ever get a final name.
    mv -T "$work" "$CURRENT_BACKUP" || die "Could not finalize backup (left at: $work)"

    if [[ "$config_ok" -eq 0 ]]; then
        log "WARNING: current nginx -t failed. The config has still been backed up,"
        log "but it is marked CONFIG_INVALID and will not be chosen for rollback."
        log "Fix the current configuration before attempting an upgrade."
        return 1
    fi

    prune_all
    log "Backup completed: $CURRENT_BACKUP"
    log "Keep this backup private; Nginx configuration may contain secrets."
}

# Return codes: 0 = upgrade installed, 10 = nothing to upgrade.
# NOTE: called as "check_upgrade_plan || plan_rc=$?", so set -e is
# ignored inside; every critical command must check its own result.
check_upgrade_plan() {
    local simulation answer

    log "Refreshing APT package lists..."
    apt-get update || die "apt-get update failed. No upgrade was performed."

    log "Current and candidate Nginx package versions:"
    apt-cache policy nginx || true
    if command -v apt-mark >/dev/null 2>&1 \
        && apt-mark showhold 2>/dev/null | grep -Eqx 'nginx(-common)?'; then
        log "WARNING: nginx or nginx-common is on APT hold; APT will not upgrade it."
        log "         Release it with: apt-mark unhold nginx nginx-common"
    fi

    log "Simulating Nginx upgrade (no package changes will be made)..."
    if ! simulation="$(apt-get -s install --only-upgrade nginx 2>&1)"; then
        printf '%s\n' "$simulation"
        die "APT simulation failed. No upgrade was performed."
    fi
    printf '%s\n' "$simulation"

    if grep -Eq '^(Remv |The following packages will be REMOVED:)' <<<"$simulation"; then
        die "APT proposes removing packages. Upgrade cancelled."
    fi

    if ! grep -Eq '^Inst nginx([[:space:]]|:)' <<<"$simulation"; then
        log "APT did not report an upgrade for the nginx package."
        return 10
    fi

    echo
    log "Review the APT simulation above, including dependencies and removals."
    read -r -p "Proceed with Nginx package upgrade? Type YES to continue: " answer \
        || die "No input received. Upgrade cancelled."
    [[ "${answer:-}" == "YES" ]] || die "Upgrade cancelled by user."

    log "Installing Nginx upgrade while retaining existing conffiles on conflict..."
    DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade \
        -o Dpkg::Options::="--force-confold" nginx \
        || die "APT installation failed. Inspect dpkg/apt state before retrying."
    return 0
}

upgrade() {
    require_commands nginx apt-get apt-cache dpkg-query systemctl
    local plan_rc=0 before after

    # Called plainly (no "||") so set -e stays active inside backup().
    # backup() logs its own reason and returns 1 on any failure.
    backup
    before="$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || echo unknown)"

    check_upgrade_plan || plan_rc=$?
    if [[ "$plan_rc" -eq 10 ]]; then
        log "Nginx is already current according to APT. Backup retained at: $CURRENT_BACKUP"
        return 0
    elif [[ "$plan_rc" -ne 0 ]]; then
        die "Upgrade plan did not complete successfully."
    fi

    after="$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || echo unknown)"
    log "Nginx package version: $before -> $after"

    log "Checking upgraded binary and configuration..."
    nginx -v
    nginx -V 2>&1
    if ! nginx -t; then
        log "ERROR: nginx -t failed after package upgrade."
        log "The script will not reload or restart Nginx."
        log "APT maintainer scripts may already have touched the running service."
        log "Inspect service immediately, then restore config if required:"
        log "  $0 rollback $CURRENT_BACKUP"
        return 2
    fi

    log "Applying the validated configuration (reload, or start if stopped)..."
    if ! reload_or_start_nginx; then
        log "ERROR: systemctl reload/start failed; no further automatic action will be taken."
        log "Check: systemctl status nginx --no-pager -l"
        return 3
    fi

    sleep 2
    if ! systemctl is-active --quiet nginx; then
        log "ERROR: Nginx is not active after reload/start."
        log "Inspect: journalctl -u nginx -n 100 --no-pager"
        return 4
    fi

    log "Upgrade workflow completed. Running local health check..."
    if ! health; then
        log "WARNING: health check reported problems."
        EXIT_CODE=1
    fi
    log "For website checks run: $0 health https://your-domain.example"
    log "Backup used for this upgrade: $CURRENT_BACKUP"
}

# Succeeds if Nginx owns a TCP listener (any port), or, when HEALTH_PORTS
# is set, if Nginx owns a listener on every listed port.
check_listeners() {
    local listeners nginx_listeners port matched missing=0

    if ! command -v ss >/dev/null 2>&1; then
        log "ss command unavailable; skipped listener check."
        return 0
    fi

    listeners="$(ss -H -lntp 2>/dev/null || true)"
    nginx_listeners="$(grep -F '"nginx"' <<<"$listeners" || true)"

    if [[ -n "$HEALTH_PORTS" ]]; then
        for port in $HEALTH_PORTS; do
            [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port in HEALTH_PORTS: $port"
            # Match ":<port>" at the end of a field/address token (e.g. 0.0.0.0:80, [::]:443, *:8080).
            matched="$(grep -E "(^|[[:space:]])(\[[0-9a-fA-F:.]+\]|[^[:space:]]*):${port}([[:space:]]|$)" <<<"$nginx_listeners" || true)"
            if [[ -z "$matched" ]]; then
                log "WARNING: no Nginx listener on TCP port ${port}."
                missing=1
            else
                printf '%s\n' "$matched"
            fi
        done
        return "$missing"
    fi

    if [[ -z "$nginx_listeners" ]]; then
        log "WARNING: no TCP listener owned by an nginx process was found."
        return 1
    fi
    printf '%s\n' "$nginx_listeners"
}

health() {
    require_commands nginx systemctl journalctl
    local rc=0 url http_code curl_rc

    log "Nginx version:"
    nginx -v 2>&1 || rc=1

    log "Configuration test:"
    if ! nginx -t; then
        log "WARNING: configuration test failed."
        rc=1
    fi

    log "Service status:"
    if systemctl is-active --quiet nginx; then
        log "Nginx service is active."
    else
        log "WARNING: Nginx service is NOT active."
        rc=1
    fi
    systemctl status nginx --no-pager -l || true

    log "Listening sockets:"
    check_listeners || rc=1

    if [[ "$#" -gt 0 ]]; then
        require_commands curl
        for url in "$@"; do
            log "HTTP check: $url"
            http_code="000"
            set +e
            http_code="$(curl --location --silent --show-error --output /dev/null \
                --connect-timeout 10 --max-time 30 \
                --write-out '%{http_code}' "$url")"
            curl_rc=$?
            set -e
            log "HTTP ${http_code}"
            if [[ "$curl_rc" -ne 0 ]] || [[ ! "$http_code" =~ ^[0-9]{3}$ ]] \
                || (( 10#$http_code < 200 || 10#$http_code >= 400 )); then
                log "WARNING: URL check failed (curl exit=${curl_rc}, HTTP=${http_code}): $url"
                rc=1
            fi
        done
    else
        log "No URL supplied. Example: $0 health https://example.com"
    fi

    log "Recent Nginx errors (if any):"
    journalctl -u nginx -p err -n 30 --no-pager || true
    return "$rc"
}

# Prints the canonical backup path on stdout. Errors go to stderr (via die)
# so they remain visible even though this runs inside $(...).
validate_backup_path() {
    local requested="$1" canonical_root canonical_backup
    [[ -d "$requested" ]] || die "Backup directory does not exist: $requested"
    canonical_root="$(realpath -e "$BACKUP_ROOT")" || die "Backup root does not exist."
    canonical_backup="$(realpath -e "$requested")" || die "Cannot resolve backup path."
    # Only direct children of the backup root are accepted.
    [[ "$(dirname "$canonical_backup")" == "$canonical_root" ]] \
        || die "Rollback is restricted to backups directly inside $canonical_root"
    [[ -d "$canonical_backup/nginx" ]] || die "Backup has no nginx/ directory."
    [[ ! -e "$canonical_backup/CONFIG_INVALID" ]] \
        || die "Backup is marked CONFIG_INVALID (its config failed nginx -t); refusing to restore it."
    [[ -d "$canonical_backup/systemd" ]] || die "Backup is missing systemd state."
    if [[ ! -f "$canonical_backup/logrotate-nginx" && ! -f "$canonical_backup/NO_LOGROTATE_NGINX_PRESENT" ]]; then
        die "Backup is missing logrotate state; refusing incomplete rollback."
    fi
    printf '%s' "$canonical_backup"
}

# The critical part of rollback. Called with INT/TERM/HUP ignored so
# that /etc/nginx cannot be left missing between the two mv commands.
# Return codes: 0 ok, 4 rolled back to previous state, 5 manual fix needed.
rollback_apply() {
    local backup_dir="$1"
    local ts safety_dir staged old failed_dir failed=0

    ts="$(new_timestamp)"
    safety_dir="${BACKUP_ROOT}/before-rollback-${ts}"
    staged="/etc/nginx.restore-${ts}"
    old="/etc/nginx.old-${ts}"
    failed_dir="/etc/nginx.failed-${ts}"

    log "Saving current state for automatic recovery..."
    save_current_state "$safety_dir"
    log "Safety copy: $safety_dir"

    log "Staging selected backup..."
    cp -a "$backup_dir/nginx" "$staged" || {
        rm -rf "$staged"
        die "Could not stage backup. Current /etc/nginx is untouched."
    }

    log "Swapping Nginx configuration..."
    if ! mv -T /etc/nginx "$old"; then
        rm -rf "$staged"
        die "Could not move the current /etc/nginx aside. Nothing was changed."
    fi
    if ! mv -T "$staged" /etc/nginx; then
        if mv -T "$old" /etc/nginx; then
            die "Could not install staged config. Previous config restored."
        fi
        log "CRITICAL: /etc/nginx is missing and could not be restored automatically."
        log "CRITICAL: previous config: $old"
        log "CRITICAL: safety copy:     $safety_dir/nginx"
        log "CRITICAL: selected backup: $backup_dir/nginx"
        log "CRITICAL: manual fix: mv $old /etc/nginx   (or: cp -a $safety_dir/nginx /etc/nginx)"
        return 5
    fi

    log "Restoring systemd, logrotate and /etc/default state..."
    if ! restore_auxiliary_state "$backup_dir"; then
        failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        log "Validating restored configuration..."
        nginx -t || failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        log "Applying restored configuration (reload, or start if stopped)..."
        reload_or_start_nginx || failed=1
        sleep 2
        systemctl is-active --quiet nginx || failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        log "ERROR: rollback validation/reload failed. Reverting to the pre-rollback state..."
        # Nothing is deleted here: the failed config is moved aside, not removed.
        if ! mv -T /etc/nginx "$failed_dir"; then
            log "CRITICAL: could not move the failed config out of /etc/nginx. No further changes were made."
            log "CRITICAL: /etc/nginx currently holds the config restored from: $backup_dir"
            log "CRITICAL: previous config is intact at: $old"
            log "CRITICAL: safety copy (config, systemd, logrotate): $safety_dir"
            log "CRITICAL: manual fix: mv /etc/nginx $failed_dir && mv $old /etc/nginx"
            log "CRITICAL: then restore systemd/logrotate state from $safety_dir and run: systemctl daemon-reload"
            return 5
        fi
        if ! mv -T "$old" /etc/nginx; then
            log "CRITICAL: could not move $old back to /etc/nginx; trying the safety copy..."
            if ! cp -aT "$safety_dir/nginx" /etc/nginx; then
                log "CRITICAL: /etc/nginx is MISSING. Nothing has been deleted. Restore manually from one of:"
                log "CRITICAL:   $old"
                log "CRITICAL:   $safety_dir/nginx"
                log "CRITICAL:   $failed_dir (the config from the failed rollback)"
                log "CRITICAL:   $backup_dir/nginx (the selected backup)"
                return 5
            fi
            log "Previous config recovered from the safety copy. Leftover directory: $old"
        fi
        restore_auxiliary_state "$safety_dir" || log "CRITICAL: failed restoring auxiliary state; inspect manually."
        if nginx -t; then
            if reload_or_start_nginx && systemctl is-active --quiet nginx; then
                log "Previous configuration restored and successfully applied."
            else
                log "CRITICAL: previous config is restored but service reload/start/active check failed."
                log "Inspect: systemctl status nginx --no-pager -l"
            fi
        else
            log "CRITICAL: previous configuration also fails nginx -t. Do not restart Nginx."
        fi
        log "Safety copy retained at: $safety_dir"
        log "Config from the failed rollback retained at: $failed_dir (delete it manually when no longer needed)"
        return 4
    fi

    rm -rf "$old"
    prune_all

    log "Configuration rollback completed successfully."
    log "IMPORTANT: Nginx binary/package version was NOT downgraded."
    if [[ -f "$backup_dir/nginx-main-package.txt" ]]; then
        log "Package version recorded in selected backup:"
        cat "$backup_dir/nginx-main-package.txt" || true
    fi
    log "Do not downgrade the binary blindly; verify package availability and dependencies first."
    log "Pre-rollback safety copy retained at: $safety_dir"
    return 0
}

rollback() {
    require_commands nginx systemctl realpath
    local requested="${1:-}" backup_dir answer rc=0

    if [[ -z "$requested" ]]; then
        requested="$(latest_backup)"
    fi
    [[ -n "$requested" ]] || die "No valid backup found. Usage: $0 rollback /root/nginx-backups/TIMESTAMP"
    backup_dir="$(validate_backup_path "$requested")"
    ensure_private_dir "$BACKUP_ROOT"

    echo "Selected backup: $backup_dir"
    echo "This replaces /etc/nginx and restores the backed-up systemd, logrotate and /etc/default state."
    read -r -p "Type RESTORE to continue: " answer || die "No input received. Rollback cancelled."
    [[ "${answer:-}" == "RESTORE" ]] || die "Rollback cancelled by user."

    # From here on, Ctrl-C / SIGTERM / SIGHUP (and SIGPIPE from a dead log
    # pipe) must not interrupt the swap. rollback_apply is deliberately
    # called plainly (no "||") so set -e stays active inside it, exactly as
    # in v5: a failed safety copy aborts BEFORE /etc/nginx is touched.
    # A non-zero return exits the script, so the traps need no cleanup there.
    trap '' INT TERM HUP PIPE
    rollback_apply "$backup_dir" || rc=$?
    trap - INT TERM HUP PIPE

    if [[ "$rc" -eq 4 ]]; then
        log "Rollback reverted to pre-rollback state (code 4)."
    elif [[ "$rc" -eq 5 ]]; then
        log "Rollback encountered a critical state requiring manual intervention (code 5)."
    fi
    return "$rc"
}

menu() {
    local choice url dir
    echo
    echo "======================================"
    echo " NGINX MAINTENANCE TOOLKIT (v8)"
    echo "======================================"
    echo "1) Backup configuration"
    echo "2) Upgrade Nginx (backup + simulation + confirmation)"
    echo "3) Health check"
    echo "4) List available backups"
    echo "5) Rollback configuration"
    echo "0) Exit"
    echo
    read -r -p "Select: " choice || die "No input received."

    case "$choice" in
        1) backup ;;
        2) upgrade ;;
        3)
            read -r -p "Optional URL to check (Enter to skip): " url || url=""
            # Show full output, but keep the real result for the final exit code.
            if [[ -n "$url" ]]; then
                health "$url" || EXIT_CODE=$?
            else
                health || EXIT_CODE=$?
            fi
            ;;
        4) list_backups ;;
        5)
            list_backups
            echo
            read -r -p "Backup directory (Enter = latest valid): " dir || dir=""
            if [[ -n "$dir" ]]; then
                rollback "$dir" || EXIT_CODE=$?
            else
                rollback || EXIT_CODE=$?
            fi
            ;;
        0) exit 0 ;;
        *) die "Invalid selection." ;;
    esac
}

usage() {
    cat <<EOF
NGINX MAINTENANCE TOOLKIT (v8)

Usage:
  sudo $0 backup
  sudo $0 upgrade
  sudo $0 health [https://domain.example ...]
  sudo $0 list
  sudo $0 rollback [backup-directory]
  sudo $0 menu

Backup root: $BACKUP_ROOT
Log root:    $LOG_ROOT

Environment:
  HEALTH_PORTS="80 443"   optional; ports Nginx must be listening on
                          (default: any TCP listener owned by nginx)
EOF
}

main() {
    local cmd="${1:-menu}"

    case "$cmd" in
        -h|--help|help) usage; exit 0 ;;
    esac

    require_root
    acquire_lock
    init_log
    # tee runs asynchronously; give it a moment to flush the last lines.
    # The exit status of the script is preserved.
    trap 'sleep 0.3' EXIT

    case "$cmd" in
        backup)   backup ;;
        upgrade)  upgrade ;;
        health)   shift; health "$@" || EXIT_CODE=$? ;;
        list)     list_backups ;;
        rollback) shift; rollback "${1:-}" || EXIT_CODE=$? ;;
        menu)     menu ;;
        *)        usage; die "Unknown command: $cmd" ;;
    esac

    log "Finished (exit code ${EXIT_CODE})."
    exit "$EXIT_CODE"
}

main "$@"
