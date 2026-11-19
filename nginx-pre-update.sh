```bash
#!/usr/bin/env bash
# ============================================================
# NGINX PRE-UPDATE
# Ubuntu 24.04+
# Backup configuration and update APT package lists
# Does NOT upgrade, restart or reload Nginx
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="nginx-pre-update"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/nginx-backups/${TIMESTAMP}"

# Check root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root."
    exit 1
fi

# Check required commands
for cmd in nginx apt-get dpkg-query systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Missing command: $cmd"
        exit 1
    }
done

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Logging
LOG_FILE="${BACKUP_DIR}/Log-${SCRIPT_NAME}.txt"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================"
echo " NGINX PRE-UPDATE"
echo " Started: $(date)"
echo " Backup: $BACKUP_DIR"
echo "================================================"

# 1. Check Nginx configuration
echo "[1/7] Testing Nginx configuration..."
nginx -t

# 2. Backup Nginx configuration
echo "[2/7] Backing up /etc/nginx..."
cp -a /etc/nginx "$BACKUP_DIR/"

# 3. Backup systemd override
echo "[3/7] Backing up systemd configuration..."

if [[ -d /etc/systemd/system/nginx.service.d ]]; then
    mkdir -p "$BACKUP_DIR/systemd"
    cp -a /etc/systemd/system/nginx.service.d \
        "$BACKUP_DIR/systemd/"
fi

# 4. Backup installed package information
echo "[4/7] Saving package information..."

dpkg-query -W -f='${binary:Package}\t${Version}\n' \
    'nginx*' > "$BACKUP_DIR/nginx-packages.txt" 2>&1 || true

apt-mark showmanual > "$BACKUP_DIR/manual-packages.txt"

nginx -V > "$BACKUP_DIR/nginx-build-info.txt" 2>&1
nginx -T > "$BACKUP_DIR/nginx-full-config.txt" 2>&1

# 5. Save system information
echo "[5/7] Saving system information..."

{
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "OS:"
    cat /etc/os-release
    echo
    echo "Nginx:"
    nginx -v 2>&1
    echo
    echo "Service:"
    systemctl status nginx --no-pager
} > "$BACKUP_DIR/system-info.txt" 2>&1

# 6. Update APT package lists
echo "[6/7] Running apt update..."
apt-get update

# 7. Display available Nginx version
echo "[7/7] Checking Nginx package candidate..."

apt-cache policy nginx

echo
echo "================================================"
echo " BACKUP COMPLETED"
echo " Finished: $(date)"
echo " Backup: $BACKUP_DIR"
echo " Log: $LOG_FILE"
echo "================================================"

echo "IMPORTANT:"
echo "- Nginx has NOT been upgraded."
echo "- Nginx has NOT been restarted."
echo "- Review APT candidate before upgrading."
```
