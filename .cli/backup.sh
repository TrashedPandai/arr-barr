#\!/usr/bin/env bash
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLI_DIR/common.sh"
require_env

DATA_ROOT="$(get_data_root)"
if [ -z "$DATA_ROOT" ]; then
    msg_error "DATA_ROOT not set in .env"
    exit 1
fi

CONFIG_DIR="$DATA_ROOT/config"
BACKUP_DIR="$DATA_ROOT/backups"

# ── List existing backups ─────────────────────────────────────────────────────

list_backups() {
    show_logo_static
    show_header "Arr Media Stack  —  Backups"

    if [ \! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" ]; then
        msg_dim "No backups found."
        echo ""
        exit 0
    fi

    section_header "EXISTING BACKUPS" "$C_SAPPHIRE"

    local count=0
    for f in $(ls -1t "$BACKUP_DIR"/arr-backup-*.tar.gz 2>/dev/null); do
        count=$((count + 1))
        local fname
        fname="$(basename "$f")"
        local fsize
        fsize="$(du -b "$f" 2>/dev/null | cut -f1 || stat -f%z "$f" 2>/dev/null || echo 0)"
        local fdate
        fdate="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
        local display_date
        display_date="$(date -d "@$fdate" +%Y-%m-%d %H:%M:%S 2>/dev/null || date -r "$fdate" +%Y-%m-%d %H:%M:%S 2>/dev/null || echo unknown)"
        local display_size
        display_size="$(human_size "$fsize")"

        printf "  ${C_TEXT}%-40s${S_RESET}  ${C_SUBTEXT0}%s${S_RESET}  ${C_OVERLAY0}%s${S_RESET}\n"             "$fname" "$display_date" "$display_size"
    done

    echo ""
    msg_dim "$count backup(s) in $BACKUP_DIR"
    echo ""
}

# ── Prune old backups ─────────────────────────────────────────────────────────

prune_backups() {
    local keep=$1
    show_logo_static
    show_header "Arr Media Stack  —  Prune Backups"

    if [ \! -d "$BACKUP_DIR" ]; then
        msg_dim "No backups directory found. Nothing to prune."
        echo ""
        exit 0
    fi

    local files
    files=($(ls -1t "$BACKUP_DIR"/arr-backup-*.tar.gz 2>/dev/null || true))
    local total=${#files[@]}

    if [ "$total" -le "$keep" ]; then
        msg_success "Only $total backup(s) exist. Nothing to prune (keeping $keep)."
        echo ""
        exit 0
    fi

    local remove_count=$((total - keep))
    msg_info "Found $total backup(s). Keeping $keep most recent, removing $remove_count."
    echo ""

    if \! confirm "Delete $remove_count old backup(s)?"; then
        msg_dim "Cancelled."
        echo ""
        exit 0
    fi

    echo ""
    local removed=0
    for (( i=keep; i<total; i++ )); do
        local f="${files[$i]}"
        rm -f "$f"
        msg_success "Removed $(basename "$f")"
        removed=$((removed + 1))
    done

    echo ""
    msg_success "Pruned $removed backup(s). $keep remaining."
    echo ""
}

# ── Create backup ─────────────────────────────────────────────────────────────

create_backup() {
    show_logo_static
    show_header "Arr Media Stack  —  Backup"

    if [ \! -d "$CONFIG_DIR" ]; then
        msg_error "Config directory not found: $CONFIG_DIR"
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local backup_file="$BACKUP_DIR/arr-backup-${timestamp}.tar.gz"

    msg_info "Backing up config directories..."
    msg_dim "Source: $CONFIG_DIR"
    msg_dim "Target: $backup_file"
    echo ""

    # Run tar in background and show spinner
    tar -czf "$backup_file" -C "$DATA_ROOT" config &
    local tar_pid=$\!

    spin_while "$tar_pid" "Creating backup archive..."
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        msg_error "Backup failed with exit code $exit_code"
        rm -f "$backup_file"
        exit 1
    fi

    local backup_size
    backup_size="$(du -b "$backup_file" 2>/dev/null | cut -f1 || stat -f%z "$backup_file" 2>/dev/null || echo 0)"
    local display_size
    display_size="$(human_size "$backup_size")"

    msg_success "Backup complete\!"
    echo ""
    kv_line "File:" "$(basename "$backup_file")"
    kv_line "Size:" "$display_size"
    kv_line "Path:" "$backup_file"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

case "${1:-}" in
    --list|-l)
        list_backups
        ;;
    --prune|-p)
        if [ -z "${2:-}" ] || \! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
            msg_error "Usage: arr backup --prune N  (keep N most recent backups)"
            exit 1
        fi
        prune_backups "$2"
        ;;
    --help|-h)
        echo ""
        echo "Usage: arr backup [OPTIONS]"
        echo ""
        echo "  (no args)    Create a new timestamped backup"
        echo "  --list, -l   List existing backups"
        echo "  --prune N    Keep only the N most recent backups"
        echo "  --help, -h   Show this help"
        echo ""
        ;;
    "")
        create_backup
        ;;
    *)
        msg_error "Unknown option: $1"
        echo "  Run arr backup --help for usage."
        exit 1
        ;;
esac
