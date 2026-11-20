#!/usr/bin/env bash
# ============================================================
# NGINX MAINTENANCE TOOLKIT (v15)
# Ubuntu 24.04+ / Debian-based systems / APT Nginx packages
#
# Commands:
#   backup       Backup Nginx config and related system settings
#   upgrade      Backup, refresh APT, simulate, confirm, upgrade
#   health       Check config, service, listeners and optional URLs
#   list         List backups and their status
#   rollback     Restore configuration from a trusted backup
#   menu         Interactive menu
#
# v9 = merge of two lines of work.
# From v8: immutable RUN_TIMESTAMP + local timestamps; "nginx -T" stdout
#   and stderr kept apart; "list" command; rollback return codes 4/5
#   logged and propagated to a final "Finished (exit code N)" line.
# Kept/fixed from v6-v7: atomic backups (.tmp-<ts> then rename),
#   CONFIG_INVALID marking, separate retention quotas, start-if-stopped,
#   signal protection during the /etc/nginx swap, mv -T hardening.
# Merge fixes: because rollback is now called with "|| EXIT_CODE=$?",
#   set -e is ignored inside it, so every critical step carries its own
#   explicit check (safety copy, backup path validation). The "nginx -T"
#   stderr warning ignores nginx's normal "syntax is ok / test is
#   successful" lines, which are printed on every successful run.
#
# v10 changes (on top of v9):
# - Old log files are pruned at every start (init_log), so read-only
#   commands such as "health" run from cron cannot fill LOG_ROOT.
# - Log flush on exit is deterministic: the EXIT trap closes stdout/stderr
#   and waits for the tee process instead of sleeping a fixed time. The
#   script's exit status is preserved.
# - APT hold check no longer pipes into "grep -q" under pipefail.
# - File is stored with LF line endings. Keep it that way (CRLF breaks bash).
#
# v11 changes (on top of v10):
# - finish_log can no longer hang: if a stray background child still holds
#   the log pipe open, a 5 s watchdog stops tee. The watchdog closes the
#   lock fd, so it can never keep the lock held after the script exits.
# - Read-only commands (health, list) write to their own log class
#   (Log-<tool>-readonly-*) with their own retention. A frequent cron
#   "health" can therefore never evict the logs of backup/upgrade/rollback.
#
# v12 changes (on top of v11):
# - "health" and "list" no longer take the exclusive lock. They change
#   nothing, so a cron "health" cannot be refused (false alarm) because a
#   backup/upgrade/rollback is running. If a maintenance run is in
#   progress, health says so in its log: results can be transient while
#   Nginx is being upgraded or its config is being swapped.
# - The interactive menu only collects the choice. The run is then locked
#   and logged exactly like the direct command, so menu "health" and
#   "list" go to the read-only log class too. The selection is logged.
# - Stale comment in main() corrected.
#
# v13 changes (on top of v12):
# - The "is a maintenance run active?" probe takes a SHARED lock (flock -s).
#   An exclusive probe made two concurrent health runs report each other as
#   "busy" and could collide with a starting backup.
# - acquire_lock waits up to LOCK_WAIT seconds (flock -w) instead of failing
#   at once. A cron backup that starts in the same second as a cron health
#   is no longer refused because of that health's few-millisecond probe; a
#   real concurrent maintenance run still holds the lock far longer and is
#   still refused.
#
# v14 changes (on top of v13):
# - "health URL" now checks TWO paths and tells them apart:
#     origin : curl --resolve HOST:PORT:<origin-ip>  (default 127.0.0.1),
#              no redirects followed, Cloudflare bypassed;
#     public : the URL as visitors/Cloudflare see it (redirects followed).
#   The verdict separates (1) an origin fault (Nginx/PHP-FPM/WordPress) from
#   (2) a Cloudflare challenge/WAF block of the probe (origin is fine) and
#   (3) Cloudflare 52x (origin fine locally, but Cloudflare cannot use it).
# - Exit status of "health": problems with the origin, or with the public
#   path for real visitors (52x, connection failure, other HTTP errors),
#   count as failures. A Cloudflare challenge/WAF block of the probe while
#   the origin is healthy is only a warning (status 0): it is not an outage.
# - New: --origin-ip, --no-origin, --insecure-origin, HEALTH_URLS (also used
#   by the check at the end of "upgrade"), HEALTH_ORIGIN_IP,
#   HEALTH_ORIGIN_INSECURE, HEALTH_ORIGIN_CACERT (Cloudflare Origin CA certs
#   are not publicly trusted: use one of the last two for them).
#
# v15 changes (on top of v14):
# - Normalize the distributed script to Unix LF line endings (CRLF breaks Bash).
# - A healthy origin plus a Cloudflare challenge/WAF block is reported as
#   "ORIGIN OK - PUBLIC ACCESS UNVERIFIED", not as a fully healthy public site.
#   The health command remains non-failing for a probe-only block, but the log
#   explicitly says that real visitor access has not been verified.
# - Remove the blanket suggestion to skip Cloudflare WAF for the server IP.
#   If a monitor exception is needed, scope it to a dedicated health endpoint,
#   the monitor's public egress IP, and only the necessary security rule.
# - Prefer HEALTH_ORIGIN_CACERT for Cloudflare Origin CA; reject combining it
#   with --insecure-origin / HEALTH_ORIGIN_INSECURE=1 (which disables validation).
# - Clarify that a successful public probe is only from this server's network
#   path, not proof of availability from every visitor/location.
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
LOCK_WAIT=3             # seconds a maintenance run waits for a momentary (shared) probe lock

RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CURRENT_LOG=""
CURRENT_BACKUP=""
TEE_PID=""
EXIT_CODE=0

# Optional: space-separated TCP ports that "health" must find owned by
# Nginx, e.g. HEALTH_PORTS="80 443" or HEALTH_PORTS="8080".
# If empty, health only requires some TCP listener owned by an nginx process.
HEALTH_PORTS="${HEALTH_PORTS:-}"

# HTTP health checks (see "health"):
#   HEALTH_URLS            space-separated URLs checked when none are given
#   HEALTH_ORIGIN_IP       address of the origin for the direct check
#   HEALTH_ORIGIN_INSECURE 1 = do not verify the origin TLS certificate
#   HEALTH_ORIGIN_CACERT   CA file used to verify the origin certificate
HEALTH_URLS="${HEALTH_URLS:-}"
HEALTH_ORIGIN_IP="${HEALTH_ORIGIN_IP:-127.0.0.1}"
HEALTH_ORIGIN_INSECURE="${HEALTH_ORIGIN_INSECURE:-0}"
HEALTH_ORIGIN_CACERT="${HEALTH_ORIGIN_CACERT:-}"

URL_SCHEME=""; URL_HOST=""; URL_PORT=""
PUB_CODE=""; PUB_RC=0; PUB_CLASS=""
ORIGIN_CODE=""; ORIGIN_RC=0

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
    flock -w "$LOCK_WAIT" 9 || die "Another ${TOOL_NAME} instance is already running."
}

# Read-only commands (health, list) do not take the exclusive lock. This only
# reports whether a maintenance run currently holds it (prints 1) or not
# (prints 0). The probe is a SHARED lock: probes never conflict with each
# other, and a starting maintenance run just waits it out (see acquire_lock).
maintenance_busy() {
    require_commands flock
    mkdir -p "$(dirname "$LOCK_FILE")"
    if ( exec 9>"$LOCK_FILE" && flock -n -s 9 ) 2>/dev/null; then
        echo 0
    else
        echo 1
    fi
}

# Read-only commands get their own log class so that frequent runs (a cron
# "health" every few minutes) never push audit-relevant logs of backup,
# upgrade or rollback runs out of retention.
log_prefix_for() {
    case "$1" in
        health|list) printf 'Log-%s-readonly-' "$TOOL_NAME" ;;
        *)           printf 'Log-%s-' "$TOOL_NAME" ;;
    esac
}

prune_logs() {
    prune_old "$LOG_ROOT" "Log-${TOOL_NAME}-[0-9]*.txt" f "$KEEP_LOGS"
    prune_old "$LOG_ROOT" "Log-${TOOL_NAME}-readonly-*.txt" f "$KEEP_LOGS"
}

init_log() {
    local prefix
    prefix="$(log_prefix_for "${1:-}")"
    ensure_private_dir "$LOG_ROOT"
    CURRENT_LOG="${LOG_ROOT}/${prefix}${RUN_TIMESTAMP}.txt"
    if [[ -e "$CURRENT_LOG" ]]; then
        CURRENT_LOG="${LOG_ROOT}/${prefix}${RUN_TIMESTAMP}-$$.txt"
    fi
    touch "$CURRENT_LOG"
    exec > >(tee -a "$CURRENT_LOG") 2>&1
    TEE_PID=$!
    log "Log file: $CURRENT_LOG"
    # Every command creates a log file, so retention must not depend on
    # backup/rollback succeeding. The current (newest) log is always kept.
    prune_logs
}

# EXIT trap: let tee write out everything, then exit with the original status.
finish_log() {
    local rc=$? watchdog=""
    trap - EXIT
    if [[ -n "$TEE_PID" ]]; then
        exec >&- 2>&- || true
        # tee ends once every writer has closed the pipe. A stray background
        # child that still holds it must not hang the script (and its lock),
        # so a watchdog stops tee after 5 s. It closes fd 9 (the lock).
        ( exec 9>&-; sleep 5; kill "$TEE_PID" 2>/dev/null ) >/dev/null 2>&1 &
        watchdog=$!
        wait "$TEE_PID" 2>/dev/null || true
        kill "$watchdog" 2>/dev/null || true
    fi
    exit "$rc"
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

    log "Backups in $BACKUP_ROOT (newest first; give rollback the name or full path):"
    printf '%-34s %-15s %s\n' "BACKUP" "STATUS" "NGINX_PACKAGE"
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        found=1
        name="${item##*/}"
        if [[ ! -d "$item/nginx" ]]; then
            status="INCOMPLETE"
        elif [[ -e "$item/CONFIG_INVALID" ]]; then
            status="CONFIG_INVALID"
        elif [[ "$name" == before-rollback-* ]]; then
            status="SAFETY_COPY"
        else
            status="VALID"
        fi
        pkg_ver="unknown"
        if [[ -f "$item/nginx-main-package.txt" ]]; then
            # File format is "<package><TAB><version>"; an error text has no TAB.
            pkg_ver="$(awk -F'\t' 'NF >= 2 { print $2; exit }' "$item/nginx-main-package.txt" 2>/dev/null || true)"
            [[ -n "$pkg_ver" ]] || pkg_ver="unknown"
        fi
        printf '%-34s %-15s %s\n' "$name" "$status" "$pkg_ver"
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
    prune_logs
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

# These return 1 on any failure instead of relying on set -e, because
# rollback calls them in a context where set -e is ignored.
save_systemd_state() {
    local destination="$1"
    mkdir -p "$destination/systemd" || return 1
    if [[ -d /etc/systemd/system/nginx.service.d ]]; then
        cp -a /etc/systemd/system/nginx.service.d "$destination/systemd/" || return 1
    else
        touch "$destination/systemd/NO_NGINX_OVERRIDE_PRESENT" || return 1
    fi
    # Full unit override (or mask symlink) in /etc/systemd/system.
    if [[ -e /etc/systemd/system/nginx.service || -L /etc/systemd/system/nginx.service ]]; then
        cp -a /etc/systemd/system/nginx.service "$destination/systemd/nginx.service" || return 1
    else
        touch "$destination/systemd/NO_NGINX_UNIT_PRESENT" || return 1
    fi
}

save_logrotate_state() {
    local destination="$1"
    if [[ -f /etc/logrotate.d/nginx ]]; then
        cp -a /etc/logrotate.d/nginx "$destination/logrotate-nginx" || return 1
    else
        touch "$destination/NO_LOGROTATE_NGINX_PRESENT" || return 1
    fi
}

save_default_state() {
    local destination="$1"
    if [[ -f /etc/default/nginx ]]; then
        cp -a /etc/default/nginx "$destination/default-nginx" || return 1
    else
        touch "$destination/NO_DEFAULT_NGINX_PRESENT" || return 1
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
    mkdir -p "$destination" || return 1
    if [[ -d /etc/nginx ]]; then
        cp -a /etc/nginx "$destination/" || return 1
    else
        die "/etc/nginx does not exist; refusing to continue."
    fi
    save_systemd_state "$destination" || return 1
    save_logrotate_state "$destination" || return 1
    save_default_state "$destination" || return 1
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
    # Keep stdout clean for config parsing; stderr goes to its own file.
    nginx -T > "$work/nginx-full-config.txt" 2> "$work/nginx-T-errors.txt" || true
    # On success nginx still prints "syntax is ok" / "test is successful"
    # to stderr, so only other lines are worth a warning.
    if grep -Ev '^nginx: (the configuration file .* syntax is ok|configuration file .* test is successful)$' \
        "$work/nginx-T-errors.txt" >/dev/null 2>&1; then
        log "WARNING: 'nginx -T' reported warnings/errors; see $CURRENT_BACKUP/nginx-T-errors.txt"
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
    local simulation answer held

    log "Refreshing APT package lists..."
    apt-get update || die "apt-get update failed. No upgrade was performed."

    log "Current and candidate Nginx package versions:"
    apt-cache policy nginx || true
    if command -v apt-mark >/dev/null 2>&1; then
        held="$(apt-mark showhold 2>/dev/null || true)"
        if grep -Eqx 'nginx(-common)?' <<<"$held"; then
            log "WARNING: nginx or nginx-common is on APT hold; APT will not upgrade it."
            log "         Release it with: apt-mark unhold nginx nginx-common"
        fi
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
    if [[ -z "$HEALTH_URLS" ]]; then
        log "No website was checked. Set HEALTH_URLS or run: $0 health https://your-domain.example"
        log "(checks the origin directly via --resolve and the public/Cloudflare path separately)"
    fi
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
            # Local-address token ending in ":<port>" (0.0.0.0:80, [::]:443, *:8080).
            matched="$(grep -E "(^|[[:space:]])[^[:space:]]*:${port}([[:space:]]|$)" <<<"$nginx_listeners" || true)"
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

# ---------- HTTP checks: origin (--resolve) + public (Cloudflare) ----------

# Splits an http(s) URL into URL_SCHEME / URL_HOST / URL_PORT.
# Fails for anything without a plain DNS host name (IPv6 literals, user:pass@).
parse_url() {
    local url="$1" rest hostport
    case "$url" in
        https://*) URL_SCHEME="https"; rest="${url#https://}"; URL_PORT=443 ;;
        http://*)  URL_SCHEME="http";  rest="${url#http://}";  URL_PORT=80 ;;
        *) return 1 ;;
    esac
    hostport="${rest%%[/?#]*}"
    [[ -n "$hostport" && "$hostport" != *@* ]] || return 1
    if [[ "$hostport" == *:* ]]; then
        URL_HOST="${hostport%%:*}"
        URL_PORT="${hostport##*:}"
        [[ "$URL_PORT" =~ ^[0-9]+$ ]] || return 1
    else
        URL_HOST="$hostport"
    fi
    [[ "$URL_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
}

# A direct origin check is pointless when the URL already names an address.
host_is_ip() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ || "$1" == "localhost" ]]
}

curl_rc_text() {
    case "$1" in
        6)  echo "DNS lookup failed" ;;
        7)  echo "connection refused" ;;
        28) echo "timed out" ;;
        35|52|56) echo "TLS handshake/connection error" ;;
        51|58|59|60|77|83|91) echo "TLS certificate not trusted" ;;
        *)  echo "curl exit code $1" ;;
    esac
}

# Why the origin check failed, in words (uses ORIGIN_RC / ORIGIN_CODE).
origin_failure_text() {
    if [[ "$ORIGIN_RC" -ne 0 ]]; then
        case "$ORIGIN_RC" in
            7)  echo "connection refused on ${HEALTH_ORIGIN_IP}: Nginx is not listening there (use --origin-ip if it listens on another address)" ;;
            28) echo "timed out: Nginx or the upstream does not answer" ;;
            51|58|59|60|77|83|91)
                echo "TLS certificate not trusted: for a Cloudflare Origin CA certificate use --insecure-origin or HEALTH_ORIGIN_CACERT" ;;
            *)  echo "$(curl_rc_text "$ORIGIN_RC")" ;;
        esac
        return 0
    fi
    case "$ORIGIN_CODE" in
        400|403) echo "HTTP ${ORIGIN_CODE}: can also be Authenticated Origin Pulls or an allow-list limited to Cloudflare IPs, not necessarily a fault" ;;
        500)     echo "HTTP 500: PHP/WordPress error" ;;
        502|503|504) echo "HTTP ${ORIGIN_CODE}: Nginx is up but the upstream (PHP-FPM) failed or is overloaded" ;;
        *)       echo "HTTP ${ORIGIN_CODE}" ;;
    esac
}

# Direct request to the origin: the real host name in the URL (so SNI, Host
# header and certificate checks are genuine), but resolved to the origin
# address. Redirects are NOT followed: a redirect is an origin answer, and
# following it would leave through public DNS (i.e. through Cloudflare).
# Sets ORIGIN_CODE / ORIGIN_RC.
origin_probe() {
    local url="$1" host="$2" port="$3" tmp="$4" addr="$HEALTH_ORIGIN_IP"
    local args=()
    if [[ "$addr" == *:* && "$addr" != \[* ]]; then
        addr="[${addr}]"
    fi
    args=(--silent --show-error --output /dev/null
          --connect-timeout 10 --max-time 30
          --resolve "${host}:${port}:${addr}" --write-out '%{http_code}')
    if [[ "$HEALTH_ORIGIN_INSECURE" == "1" ]]; then
        args+=(--insecure)
    fi
    if [[ -n "$HEALTH_ORIGIN_CACERT" ]]; then
        args+=(--cacert "$HEALTH_ORIGIN_CACERT")
    fi
    ORIGIN_RC=0
    ORIGIN_CODE="$(curl "${args[@]}" "$url" 2>"$tmp/origin.err")" || ORIGIN_RC=$?
    [[ "$ORIGIN_CODE" =~ ^[0-9]{3}$ ]] || ORIGIN_CODE="000"
}

# Request exactly as a visitor / Cloudflare-fronted client would make it.
# Sets PUB_CODE / PUB_RC and PUB_CLASS, one of:
#   OK               2xx/3xx
#   CF_CHALLENGE     Cloudflare challenge ("Just a moment", cf-mitigated)
#   CF_BLOCK         Cloudflare WAF block / rate limit (1020, 1015, 429)
#   CF_ORIGIN_ERROR  Cloudflare 520-527/530: Cloudflare cannot use the origin
#   CONN_FAIL        no HTTP answer at all (DNS, TCP, TLS, timeout)
#   HTTP_ERROR       any other 4xx/5xx
public_probe() {
    local url="$1" tmp="$2" hdr="$2/pub.hdr" body="$2/pub.body"
    local snippet="" cf=0 mitigated=0 chal_body=0 waf_body=0
    : > "$hdr"; : > "$body"
    PUB_RC=0
    PUB_CODE="$(curl --location --silent --show-error --output "$body" --dump-header "$hdr" \
        --connect-timeout 10 --max-time 30 --write-out '%{http_code}' "$url" 2>"$tmp/pub.err")" || PUB_RC=$?
    [[ "$PUB_CODE" =~ ^[0-9]{3}$ ]] || PUB_CODE="000"

    PUB_CLASS="HTTP_ERROR"
    if [[ "$PUB_RC" -ne 0 ]]; then
        PUB_CLASS="CONN_FAIL"
        return 0
    fi

    if grep -Eqi '^(server:[[:space:]]*cloudflare|cf-ray:)' "$hdr"; then cf=1; fi
    if grep -Eqi '^cf-mitigated:[[:space:]]*challenge' "$hdr"; then mitigated=1; fi
    snippet="$(head -c 8192 "$body" | tr -d '\000' || true)"
    if grep -Eqi 'Just a moment|cf-chl|challenge-platform|cf_chl_opt' <<<"$snippet"; then chal_body=1; fi
    if grep -Eqi 'error code: 10[0-9]{2}|Attention Required|Cloudflare Ray ID' <<<"$snippet"; then waf_body=1; fi

    if [[ "$mitigated" -eq 1 ]] || [[ "$PUB_CODE" =~ ^(403|503)$ && "$chal_body" -eq 1 ]]; then
        PUB_CLASS="CF_CHALLENGE"
    elif [[ "$cf" -eq 1 && ( "$PUB_CODE" == "429" || ( "$PUB_CODE" == "403" && "$waf_body" -eq 1 ) ) ]]; then
        PUB_CLASS="CF_BLOCK"
    elif [[ "$cf" -eq 1 && "$PUB_CODE" =~ ^5(2[0-7]|30)$ ]]; then
        PUB_CLASS="CF_ORIGIN_ERROR"
    elif [[ "$PUB_CODE" =~ ^[23][0-9]{2}$ ]]; then
        PUB_CLASS="OK"
    fi
}

# Checks one URL, logs the evidence and a verdict. Returns 0 = no problem
# (a probe blocked by Cloudflare while the origin is healthy is a warning
# only), 1 = problem. Must not rely on set -e (called with "||").
http_check_url() {
    local url="$1" tmp="$2" do_origin="$3"
    local host port origin_ok=0 have_origin=0 o_note="" p_note="" why=""

    if ! parse_url "$url"; then
        log "WARNING: not an http(s) URL with a plain host name: $url"
        return 1
    fi
    host="$URL_HOST"; port="$URL_PORT"
    log "HTTP check: $url"

    if [[ "$do_origin" -eq 1 ]]; then
        if host_is_ip "$host"; then
            log "  origin check skipped: the URL host is an address, not a name"
        else
            have_origin=1
            origin_probe "$url" "$host" "$port" "$tmp"
            if [[ "$ORIGIN_RC" -eq 0 && "$ORIGIN_CODE" =~ ^[23][0-9][0-9]$ ]]; then
                origin_ok=1
            fi
            if [[ "$ORIGIN_RC" -ne 0 ]]; then o_note=" - $(curl_rc_text "$ORIGIN_RC")"; fi
            log "  origin (--resolve ${host}:${port}:${HEALTH_ORIGIN_IP}): HTTP ${ORIGIN_CODE}${o_note}"
        fi
    fi

    public_probe "$url" "$tmp"
    if [[ "$PUB_RC" -ne 0 ]]; then p_note=" - $(curl_rc_text "$PUB_RC")"; fi
    log "  public (DNS/Cloudflare path)              : HTTP ${PUB_CODE} [${PUB_CLASS}]${p_note}"

    # ---- origin check not available: public result only ----
    if [[ "$have_origin" -eq 0 ]]; then
        case "$PUB_CLASS" in
            OK)
                log "  RESULT: OK (public URL only; the origin was not checked separately)."
                return 0 ;;
            CF_CHALLENGE|CF_BLOCK)
                log "  RESULT: PROBE BLOCKED by Cloudflare (HTTP ${PUB_CODE}, ${PUB_CLASS})."
                log "          Without the origin check this cannot be told apart from an outage."
                return 1 ;;
            CF_ORIGIN_ERROR)
                log "  RESULT: PROBLEM: Cloudflare returned ${PUB_CODE}; it cannot use the origin."
                return 1 ;;
            *)
                log "  RESULT: PROBLEM: public URL failed (HTTP ${PUB_CODE})."
                return 1 ;;
        esac
    fi

    # ---- origin healthy ----
    if [[ "$origin_ok" -eq 1 ]]; then
        case "$PUB_CLASS" in
            OK)
                log "  RESULT: ORIGIN OK + PUBLIC PROBE OK from this server's network path."
                log "          This confirms this probe path only; it is not a guarantee for every visitor/location."
                return 0 ;;
            CF_CHALLENGE)
                log "  RESULT: ORIGIN OK - PUBLIC ACCESS UNVERIFIED."
                log "          This probe received a Cloudflare challenge (HTTP ${PUB_CODE});"
                log "          the origin answered HTTP ${ORIGIN_CODE}, but this does NOT prove"
                log "          that ordinary visitors can access the public website."
                log "          Health status: warning only; investigate the challenge separately."
                return 0 ;;
            CF_BLOCK)
                log "  RESULT: ORIGIN OK - PUBLIC ACCESS UNVERIFIED."
                log "          Cloudflare blocked/rate-limited this probe (HTTP ${PUB_CODE});"
                log "          the origin answered HTTP ${ORIGIN_CODE}, but visitor access is unknown."
                log "          Health status: warning only; investigate the WAF/rate limit separately."
                log "          Do not bypass WAF globally. If needed, allow only a dedicated"
                log "          health endpoint from the monitor egress IP using a narrow rule."
                return 0 ;;
            CF_ORIGIN_ERROR)
                log "  RESULT: PROBLEM between Cloudflare and the origin: origin is fine locally (HTTP ${ORIGIN_CODE}),"
                log "          but Cloudflare returns ${PUB_CODE}. Check: firewall blocking Cloudflare IP ranges,"
                log "          SSL/TLS mode vs the origin certificate, origin port, DNS pointing to another server."
                return 1 ;;
            CONN_FAIL)
                log "  RESULT: PROBLEM: origin is fine (HTTP ${ORIGIN_CODE}) but the public URL is unreachable from this server"
                log "          (DNS, network or Cloudflare)."
                return 1 ;;
            *)
                log "  RESULT: PROBLEM: origin says HTTP ${ORIGIN_CODE} but the public URL says HTTP ${PUB_CODE};"
                log "          check Cloudflare rules, redirects, caching and page rules."
                return 1 ;;
        esac
    fi

    # ---- origin failed ----
    why="$(origin_failure_text)"
    case "$PUB_CLASS" in
        OK)
            log "  RESULT: ORIGIN CHECK FAILED (${why}) although the public URL answers."
            log "          Cloudflare may be serving a cached copy, or --origin-ip / port / TLS settings"
            log "          do not match this server. Do not trust the public result until this is clear."
            return 1 ;;
        CF_CHALLENGE|CF_BLOCK)
            log "  RESULT: ORIGIN CHECK FAILED (${why}); the public probe was also blocked by Cloudflare,"
            log "          so there is no public confirmation either."
            return 1 ;;
        *)
            log "  RESULT: ORIGIN DOWN (${why}); the public URL fails too (HTTP ${PUB_CODE})."
            log "          The fault is in Nginx / PHP-FPM / WordPress, not in Cloudflare."
            return 1 ;;
    esac
}

health() {
    require_commands nginx systemctl journalctl
    local rc=0 url tmp check_origin=1
    local urls=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --origin-ip)
                [[ $# -ge 2 ]] || die "--origin-ip needs an IP address."
                HEALTH_ORIGIN_IP="$2"; shift 2 ;;
            --no-origin)       check_origin=0; shift ;;
            --insecure-origin) HEALTH_ORIGIN_INSECURE=1; shift ;;
            --)                shift; urls+=("$@"); break ;;
            -*)                die "Unknown health option: $1" ;;
            *)                 urls+=("$1"); shift ;;
        esac
    done
    [[ "$HEALTH_ORIGIN_IP" =~ ^[0-9A-Fa-f:.]+$ ]] || die "Invalid origin IP: $HEALTH_ORIGIN_IP"
    [[ "$HEALTH_ORIGIN_INSECURE" =~ ^[01]$ ]] || die "HEALTH_ORIGIN_INSECURE must be 0 or 1."
    [[ -z "$HEALTH_ORIGIN_CACERT" || -r "$HEALTH_ORIGIN_CACERT" ]] \
        || die "Cannot read HEALTH_ORIGIN_CACERT: $HEALTH_ORIGIN_CACERT"
    [[ "$HEALTH_ORIGIN_INSECURE" != "1" || -z "$HEALTH_ORIGIN_CACERT" ]] \
        || die "Choose either HEALTH_ORIGIN_CACERT or --insecure-origin, not both. Prefer the CA certificate."
    if [[ "${#urls[@]}" -eq 0 && -n "$HEALTH_URLS" ]]; then
        read -r -a urls <<<"$HEALTH_URLS"
    fi

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

    if [[ "${#urls[@]}" -gt 0 ]]; then
        require_commands curl mktemp
        tmp="$(mktemp -d)" || die "Cannot create a temporary directory."
        for url in "${urls[@]}"; do
            http_check_url "$url" "$tmp" "$check_origin" || rc=1
        done
        rm -rf "$tmp"
    else
        log "No URL supplied. Example: $0 health https://example.com"
        log "(the origin is checked directly via --resolve ${HEALTH_ORIGIN_IP}; the public path via DNS/Cloudflare)"
    fi

    log "Recent Nginx errors (if any):"
    journalctl -u nginx -p err -n 30 --no-pager || true
    return "$rc"
}

# Prints the canonical backup path on stdout. Errors go to stderr (via die)
# so they remain visible even though this runs inside $(...).
validate_backup_path() {
    local requested="$1" canonical_root canonical_backup
    # A bare name (as shown by "list") is looked up inside the backup root.
    if [[ "$requested" != */* ]]; then
        requested="${BACKUP_ROOT}/${requested}"
    fi
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
    save_current_state "$safety_dir" \
        || die "Could not save the pre-rollback safety copy. /etc/nginx is untouched."
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

    # No step here may rely on set -e: main/menu call rollback with
    # "|| EXIT_CODE=$?", which disables it. Every failure is explicit.
    if [[ -z "$requested" ]]; then
        requested="$(latest_backup)" || requested=""
    fi
    [[ -n "$requested" ]] || die "No valid backup found. Usage: $0 rollback [name|path]  (see: $0 list)"
    backup_dir="$(validate_backup_path "$requested")" || exit 1
    ensure_private_dir "$BACKUP_ROOT"

    echo "Selected backup: $backup_dir"
    echo "This replaces /etc/nginx and restores the backed-up systemd, logrotate and /etc/default state."
    read -r -p "Type RESTORE to continue: " answer || die "No input received. Rollback cancelled."
    [[ "${answer:-}" == "RESTORE" ]] || die "Rollback cancelled by user."

    # From here on, Ctrl-C / SIGTERM / SIGHUP (and SIGPIPE from a dead log
    # pipe) must not interrupt the swap.
    trap '' INT TERM HUP PIPE
    rollback_apply "$backup_dir" || rc=$?
    trap - INT TERM HUP PIPE

    if [[ "$rc" -eq 4 ]]; then
        log "Rollback failed validation and was reverted to the pre-rollback state (code 4)."
    elif [[ "$rc" -eq 5 ]]; then
        log "Rollback hit a critical state that needs manual intervention (code 5)."
    fi
    return "$rc"
}

# Collects the interactive choice only. It runs BEFORE the lock and the log
# are set up, so that main() can treat the choice like a direct command
# (correct lock behaviour, correct log class).
MENU_CMD=""
MENU_ARGS=()

menu_choose() {
    local choice url dir
    echo
    echo "======================================"
    echo " NGINX MAINTENANCE TOOLKIT (v15)"
    echo "======================================"
    echo "1) Backup configuration"
    echo "2) Upgrade Nginx (backup + simulation + confirmation)"
    echo "3) Health check"
    echo "4) List backups"
    echo "5) Rollback configuration"
    echo "0) Exit"
    echo
    read -r -p "Select: " choice || die "No input received."

    case "$choice" in
        1) MENU_CMD="backup" ;;
        2) MENU_CMD="upgrade" ;;
        3)
            MENU_CMD="health"
            read -r -p "Optional URL to check (Enter to skip): " url || url=""
            [[ -z "$url" ]] || MENU_ARGS=("$url")
            ;;
        4) MENU_CMD="list" ;;
        5)
            MENU_CMD="rollback"
            list_backups
            echo
            read -r -p "Backup name or path (Enter = latest valid): " dir || dir=""
            [[ -z "$dir" ]] || MENU_ARGS=("$dir")
            ;;
        0) exit 0 ;;
        *) die "Invalid selection." ;;
    esac
}

usage() {
    cat <<EOF
NGINX MAINTENANCE TOOLKIT (v15)

Usage:
  sudo $0 backup
  sudo $0 upgrade
  sudo $0 health [options] [https://domain.example ...]
      --origin-ip IP      address of the origin for the direct check (default 127.0.0.1)
      --no-origin         skip the direct origin check
      --insecure-origin   do not verify the origin TLS certificate
  sudo $0 list
  sudo $0 rollback [backup-name-or-path]
  sudo $0 menu

Backup root: $BACKUP_ROOT
Log root:    $LOG_ROOT

Environment:
  HEALTH_PORTS="80 443"   optional; ports Nginx must be listening on
                          (default: any TCP listener owned by nginx)
  HEALTH_URLS="https://example.com/ ..."   URLs checked when none are given
                          (also used at the end of "upgrade")
  HEALTH_ORIGIN_IP, HEALTH_ORIGIN_INSECURE=1, HEALTH_ORIGIN_CACERT=/path/ca.pem
  Prefer HEALTH_ORIGIN_CACERT for Cloudflare Origin CA; do not combine it with
  HEALTH_ORIGIN_INSECURE=1 / --insecure-origin (certificate verification off).
EOF
}

main() {
    local cmd="${1:-menu}" busy=0

    case "$cmd" in
        -h|--help|help) usage; exit 0 ;;
    esac

    require_root

    # Menu: only collect the choice here; then continue as if the user had
    # typed the command (arguments included) on the command line.
    if [[ "$cmd" == "menu" ]]; then
        menu_choose
        cmd="$MENU_CMD"
        set -- "$cmd" ${MENU_ARGS[@]+"${MENU_ARGS[@]}"}
    fi

    case "$cmd" in
        health|list) busy="$(maintenance_busy)" ;;
        *)           acquire_lock ;;
    esac
    init_log "$cmd"
    # tee runs asynchronously; finish_log waits for it so the last lines
    # always reach the log file. The exit status is preserved.
    trap finish_log EXIT

    [[ -z "$MENU_CMD" ]] || log "Selected from menu: $cmd"
    if [[ "$busy" -eq 1 ]]; then
        log "NOTE: a maintenance run (backup/upgrade/rollback) is in progress."
        log "      Results below may be transient while Nginx or its config is being changed."
    fi

    case "$cmd" in
        backup)   backup ;;
        upgrade)  upgrade ;;
        health)   shift; health "$@" || EXIT_CODE=$? ;;
        list)     list_backups ;;
        rollback) shift; rollback "${1:-}" || EXIT_CODE=$? ;;
        *)        usage; die "Unknown command: $cmd" ;;
    esac

    log "Finished (exit code ${EXIT_CODE})."
    exit "$EXIT_CODE"
}

main "$@"
