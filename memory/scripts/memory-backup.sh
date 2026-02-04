#!/bin/bash
# memory-backup.sh - Local backup system for agent memory
# Version: 0.1.0 - Hardened with safety checks
# Usage: memory-backup.sh [hourly|daily|manual "description"]

MEMORY_DIR="${MEMORY_BASE_DIR:-$HOME/clawd/memory}"
BACKUP_DIR="$MEMORY_DIR/backups"

# Safety limits
MIN_DISK_SPACE_KB=10240  # 10MB
MAX_HOURLY_BACKUPS=24
MAX_DAILY_BACKUPS=30

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Check disk space
check_disk_space() {
  local available=$(df -k "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$available" ] || [ "$available" -lt "$MIN_DISK_SPACE_KB" ]; then
    echo "CRITICAL: Insufficient disk space for backup ($available KB available)" >&2
    return 1
  fi
  return 0
}

# Safe deletion with dry-run protection
safe_delete_old() {
  local pattern="$1"
  local keep_count="$2"
  local backup_type="$3"
  
  # Count matching files
  local file_count=$(find "$BACKUP_DIR" -name "$pattern" -type f 2>/dev/null | wc -l)
  
  if [ "$file_count" -le "$keep_count" ]; then
    # Nothing to delete
    return 0
  fi
  
  # Get files to delete (oldest first, using mtime)
  local delete_count=$((file_count - keep_count))
  
  echo "Rotating $backup_type backups: keeping $keep_count, deleting $delete_count oldest"
  
  # Use -print0 and carefully handle filenames
  find "$BACKUP_DIR" -name "$pattern" -type f -printf '%T@ %p\0' 2>/dev/null | \
    sort -z -n | \
    head -z -n "$delete_count" | \
    while IFS=' ' read -r -d '' mtime filepath; do
      if [ -f "$filepath" ]; then
        echo "  Removing: $(basename "$filepath")"
        rm -f "$filepath"
      fi
    done
}

backup_hourly() {
  if ! check_disk_space; then
    return 1
  fi
  
  local timestamp=$(date +%Y%m%d-%H%M)
  local current_stream="$MEMORY_DIR/action-stream-$(date +%Y-%m-%d).jsonl"
  
  if [ ! -f "$current_stream" ]; then
    echo "No action stream to backup"
    return 0
  fi
  
  local backup_file="$BACKUP_DIR/action-stream-$(date +%Y-%m-%d)-$timestamp.jsonl"
  
  # Copy with verification
  if cp "$current_stream" "$backup_file"; then
    chmod 600 "$backup_file"
    
    # Verify copy succeeded
    if [ -s "$backup_file" ]; then
      echo "✓ Hourly backup created: $(basename "$backup_file")"
      
      # Rotate old backups
      safe_delete_old "action-stream-*-*.jsonl" "$MAX_HOURLY_BACKUPS" "hourly"
    else
      echo "✗ Backup file is empty, removing" >&2
      rm -f "$backup_file"
      return 1
    fi
  else
    echo "✗ Hourly backup failed" >&2
    return 1
  fi
}

backup_daily() {
  if ! check_disk_space; then
    return 1
  fi
  
  local yesterday=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
  local yesterday_stream="$MEMORY_DIR/action-stream-$yesterday.jsonl"
  
  if [ ! -f "$yesterday_stream" ]; then
    echo "No yesterday's stream to archive"
    return 0
  fi
  
  # Check if already archived
  local archive_file="$BACKUP_DIR/action-stream-$yesterday.jsonl.gz"
  if [ -f "$archive_file" ]; then
    echo "Already archived: $(basename "$archive_file")"
    return 0
  fi
  
  # Compress with verification
  if gzip -c "$yesterday_stream" > "$archive_file.tmp"; then
    if [ -s "$archive_file.tmp" ]; then
      mv "$archive_file.tmp" "$archive_file"
      chmod 600 "$archive_file"
      echo "✓ Daily archive created: $(basename "$archive_file")"
      
      # Rotate old archives
      safe_delete_old "action-stream-*.jsonl.gz" "$MAX_DAILY_BACKUPS" "daily"
    else
      echo "✗ Archive is empty, removing" >&2
      rm -f "$archive_file.tmp"
      return 1
    fi
  else
    echo "✗ Daily archive failed" >&2
    rm -f "$archive_file.tmp"
    return 1
  fi
}

backup_manual() {
  local description="${1:-manual}"
  
  # Sanitize description for filename
  description=$(echo "$description" | tr -cd '[:alnum:]-_' | cut -c1-50)
  
  if ! check_disk_space; then
    return 1
  fi
  
  local timestamp=$(date +%Y%m%d-%H%M%S)
  local current_stream="$MEMORY_DIR/action-stream-$(date +%Y-%m-%d).jsonl"
  
  if [ ! -f "$current_stream" ]; then
    echo "No action stream to backup"
    return 1
  fi
  
  local backup_file="$BACKUP_DIR/action-stream-manual-${description}-$timestamp.jsonl"
  
  if cp "$current_stream" "$backup_file"; then
    chmod 600 "$backup_file"
    echo "✓ Manual backup created: $(basename "$backup_file")"
  else
    echo "✗ Manual backup failed" >&2
    return 1
  fi
}

case "$1" in
  hourly)
    backup_hourly
    ;;
  daily)
    backup_daily
    ;;
  manual)
    backup_manual "$2"
    ;;
  *)
    echo "Usage: $0 [hourly|daily|manual \"description\"]"
    echo ""
    echo "Commands:"
    echo "  hourly          - Create timestamped backup, keep last $MAX_HOURLY_BACKUPS"
    echo "  daily           - Compress yesterday's stream, keep last $MAX_DAILY_BACKUPS"
    echo "  manual <desc>   - Create manual backup with description"
    echo ""
    echo "All backups are local-only. NEVER commit backup files to git."
    exit 1
    ;;
esac
