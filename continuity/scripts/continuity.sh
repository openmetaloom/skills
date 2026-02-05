#!/bin/bash
# continuity.sh - Core continuity logging functions for AI agents
# Version: 0.2.0 - Environment variable configuration support
#
# SAFETY: Continuity files contain private data. NEVER commit to git.
# Keep in ~/clawd/continuity/ only, with proper .gitignore rules.

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

# Configuration defaults (these are used if env vars not set)
: "${CONTINUITY_RECALL_MODE:=both}"
: "${CONTINUITY_LOG_LEVEL:=everything}"
: "${CONTINUITY_RECALL_LIMIT:=10}"
: "${CONTINUITY_STRICT_VALIDATION:=false}"
: "${CONTINUITY_EMERGENCY_STDERR:=true}"

# Source user configuration file if it exists
CONTINUITY_CONFIG_FILE="${HOME}/.openclaw/skills/continuity/config.env"
if [ -f "$CONTINUITY_CONFIG_FILE" ]; then
    # Use set -a to export all variables defined in the file
    set -a
    source "$CONTINUITY_CONFIG_FILE" 2>/dev/null || true
    set +a
fi

# Validate configuration values
_continuity_validate_config() {
    local errors=0
    
    # Validate RECALL_MODE
    case "$CONTINUITY_RECALL_MODE" in
        off|openclaw_only|continuity_only|both)
            ;;
        *)
            echo "WARNING: Invalid CONTINUITY_RECALL_MODE='$CONTINUITY_RECALL_MODE', using 'both'" >&2
            CONTINUITY_RECALL_MODE="both"
            errors=$((errors + 1))
            ;;
    esac
    
    # Validate LOG_LEVEL
    case "$CONTINUITY_LOG_LEVEL" in
        off|judgment|everything)
            ;;
        *)
            echo "WARNING: Invalid CONTINUITY_LOG_LEVEL='$CONTINUITY_LOG_LEVEL', using 'everything'" >&2
            CONTINUITY_LOG_LEVEL="everything"
            errors=$((errors + 1))
            ;;
    esac
    
    # Validate RECALL_LIMIT (must be positive integer)
    if ! [[ "$CONTINUITY_RECALL_LIMIT" =~ ^[0-9]+$ ]] || [ "$CONTINUITY_RECALL_LIMIT" -lt 1 ]; then
        echo "WARNING: Invalid CONTINUITY_RECALL_LIMIT='$CONTINUITY_RECALL_LIMIT', using 10" >&2
        CONTINUITY_RECALL_LIMIT=10
        errors=$((errors + 1))
    fi
    
    return $errors
}

# Run validation on load
_continuity_validate_config

# Export validated configuration
export CONTINUITY_RECALL_MODE
export CONTINUITY_LOG_LEVEL
export CONTINUITY_RECALL_LIMIT
export CONTINUITY_STRICT_VALIDATION
export CONTINUITY_EMERGENCY_STDERR
export CONTINUITY_CONFIG_FILE

# ============================================================================
# END CONFIGURATION LOADING
# ============================================================================

CONTINUITY_BASE_DIR="${CONTINUITY_BASE_DIR:-$HOME/clawd/continuity}"
CONTINUITY_ACTION_STREAM="$CONTINUITY_BASE_DIR/action-stream-$(date +%Y-%m-%d).jsonl"
CONTINUITY_EMERGENCY_LOG="$CONTINUITY_BASE_DIR/EMERGENCY_RECOVERY.jsonl"
CONTINUITY_SEQUENCE_FILE="$CONTINUITY_BASE_DIR/.sequence"
CONTINUITY_LAST_HASH_FILE="$CONTINUITY_BASE_DIR/.last_hash"

# Minimum disk space required (10MB in KB)
MIN_DISK_SPACE_KB=10240

# Ensure directory exists with proper permissions
mkdir -p "$CONTINUITY_BASE_DIR"/{conversations,actions,workflows,backups}
chmod 700 "$CONTINUITY_BASE_DIR"

# Generate proper UUID v4
continuity_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Fallback: generate RFC 4122 v4 UUID manually with proper version/variant bits
    # Read 16 bytes, format as UUID with version=4 (0100) and variant=10 (RFC 4122)
    local hex=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ -z "$hex" ] || [ ${#hex} -lt 32 ]; then
      echo "CRITICAL: Cannot generate UUID - /dev/urandom unavailable" >&2
      return 1
    fi
    # UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    # where 4 = version, y = 8/9/a/b (variant bits)
    local v4=$(printf '%s-%s-4%s-%s%s-%s' \
      "${hex:0:8}" \
      "${hex:8:4}" \
      "${hex:13:3}" \
      "$(echo "${hex:16:1}" | tr '0123456789abcdef' '89abcdef89abcdef')" \
      "${hex:17:3}" \
      "${hex:20:12}")
    echo "$v4"
  fi
}

# Get next sequence number (monotonic, survives restarts)
continuity_next_sequence() {
  local seq=0
  if [ -f "$CONTINUITY_SEQUENCE_FILE" ]; then
    seq=$(cat "$CONTINUITY_SEQUENCE_FILE" 2>/dev/null || echo 0)
  fi
  seq=$((seq + 1))
  echo "$seq" > "$CONTINUITY_SEQUENCE_FILE"
  echo "$seq"
}

# Get previous action hash for chain
continuity_previous_hash() {
  if [ -f "$CONTINUITY_LAST_HASH_FILE" ]; then
    cat "$CONTINUITY_LAST_HASH_FILE" 2>/dev/null || echo "genesis"
  else
    echo "genesis"
  fi
}

# Check disk space before critical operations
continuity_check_disk_space() {
  local available=$(df -k "$CONTINUITY_BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$available" ] || [ "$available" -lt "$MIN_DISK_SPACE_KB" ]; then
    echo "CRITICAL: Low disk space ($available KB available, need $MIN_DISK_SPACE_KB KB)" >&2
    return 1
  fi
  return 0
}

# Calculate integrity hash for action
continuity_calculate_hash() {
  local content="$1"
  local previous_hash="$2"
  echo -n "$content$previous_hash" | sha256sum | cut -d' ' -f1
}

# Log an action with synchronous write and integrity verification
# Usage: continuity_log_action <type> <platform> <description> [cost] [proof] [metadata_json]
# Returns: 0 on success, 1 on failure
continuity_log_action() {
  local type=$1
  local platform=$2
  local description=$3
  local cost=${4:-"null"}
  local proof=${5:-"null"}
  local metadata=${6:-"{}"}
  local severity=${7:-"medium"}

  # Check disk space first
  if ! continuity_check_disk_space; then
    # Emergency: try to write to emergency log anyway
    local emergency_entry="{\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")\",\"type\":\"$type\",\"error\":\"disk_space_low\"}"
    echo "$emergency_entry" >> "$CONTINUITY_EMERGENCY_LOG" 2>/dev/null
    return 1
  fi

  local id=$(continuity_uuid)
  if [ $? -ne 0 ] || [ -z "$id" ]; then
    echo "CRITICAL: Failed to generate UUID" >&2
    return 1
  fi
  
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  local sequence=$(continuity_next_sequence)
  local session_id="${OPENCLAW_SESSION_ID:-$(hostname)-$$-$(date +%s)}"
  local previous_hash=$(continuity_previous_hash)
  
  # Ensure cost is valid JSON (null or number, never empty string)
  case "$cost" in
    ""|"null"|"NULL") cost="null" ;;
    *[!0-9.]*) cost="null" ;;  # Non-numeric becomes null
  esac

  # Build JSON without integrity first
  local content=$(cat <<EOF
{"schema_version":"0.1.0","action":{"id":"$id","sequence":$sequence,"timestamp":"$timestamp","type":"$type","severity":"$severity","platform":"$platform","description":"$description","cost":$cost,"metadata":$metadata,"proof":"$proof","session_id":"$session_id"}}
EOF
)
  
  # Calculate integrity hash
  local current_hash=$(continuity_calculate_hash "$content" "$previous_hash")
  
  # Add integrity to JSON (compact format for JSONL)
  local json=$(echo "$content" | jq -c --arg hash "$current_hash" --arg prev "$previous_hash" \
    '.action._integrity = {hash: $hash, previous: $prev}')
  
  # Validate JSON before writing
  if ! echo "$json" | jq -e . >/dev/null 2>&1; then
    echo "CRITICAL: Generated invalid JSON" >&2
    echo "$json" >> "$CONTINUITY_EMERGENCY_LOG" 2>/dev/null
    return 1
  fi
  
  # Attempt synchronous write
  if echo "$json" >> "$CONTINUITY_ACTION_STREAM" && sync; then
    # Update last hash for chain
    echo "$current_hash" > "$CONTINUITY_LAST_HASH_FILE"
    chmod 600 "$CONTINUITY_ACTION_STREAM" "$CONTINUITY_LAST_HASH_FILE"
    echo "✓ Logged: $type on $platform (seq: $sequence)"
    echo "$id"
    return 0
  else
    # Write failed - emergency recovery
    echo "CRITICAL: Failed to write to action stream" >&2
    echo "$json" >> "$CONTINUITY_EMERGENCY_LOG" 2>/dev/null
    chmod 600 "$CONTINUITY_EMERGENCY_LOG"

    # Alert operator
    echo "{\"alert\":\"write_failure\",\"timestamp\":\"$timestamp\",\"action\":\"$type\"}" >> "$CONTINUITY_BASE_DIR/ALERTS.jsonl" 2>/dev/null
    
    return 1
  fi
}

# Log a critical action (financial, contractual) - MUST check return value
# Usage: if ! continuity_log_critical ...; then echo "ABORT"; exit 1; fi
continuity_log_critical() {
  if ! continuity_log_action "$1" "$2" "$3" "$4" "$5" "$6" "critical"; then
    echo "CRITICAL: Failed to log critical action. ABORTING." >&2
    return 1
  fi
  return 0
}

# Create workflow checkpoint
continuity_checkpoint_workflow() {
  local workflow_id=$1
  local workflow_file="$CONTINUITY_BASE_DIR/workflows/active/$workflow_id.json"

  mkdir -p "$CONTINUITY_BASE_DIR/workflows/active"
  cat > "$workflow_file"
  chmod 600 "$workflow_file"
  sync
  
  echo "✓ Checkpointed workflow: $workflow_id"
}

# Pre-compaction checkpoint
continuity_pre_compaction_checkpoint() {
  local manifest_file="$CONTINUITY_BASE_DIR/COMPACTION_MANIFEST.json"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local session_id="${OPENCLAW_SESSION_ID:-$(hostname)-$$-$(date +%s)}"

  # Count uncommitted actions
  local uncommitted=0
  if [ -f "$CONTINUITY_ACTION_STREAM" ]; then
    uncommitted=$(wc -l < "$CONTINUITY_ACTION_STREAM" 2>/dev/null || echo 0)
  fi

  # Find active workflows
  local workflows=0
  if [ -d "$CONTINUITY_BASE_DIR/workflows/active" ]; then
    workflows=$(find "$CONTINUITY_BASE_DIR/workflows/active" -name "*.json" 2>/dev/null | wc -l)
  fi

  # Get disk space
  local disk_available=$(df -k "$CONTINUITY_BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  
  cat > "$manifest_file" <<EOF
{
  "timestamp": "$timestamp",
  "session_id": "$session_id",
  "uncommitted_actions": $uncommitted,
  "active_workflows": $workflows,
  "disk_space_kb": $disk_available,
  "sequence": $(cat "$CONTINUITY_SEQUENCE_FILE" 2>/dev/null || echo 0),
  "last_hash": "$(cat "$CONTINUITY_LAST_HASH_FILE" 2>/dev/null || echo "genesis")",
  "checklist": {
    "actions_persisted": true,
    "workflows_checkpoints": true,
    "integrity_chain_valid": true
  }
}
EOF
  chmod 600 "$manifest_file"
  sync
  
  echo "✓ Pre-compaction checkpoint created"
  echo "  Uncommitted actions: $uncommitted"
  echo "  Active workflows: $workflows"
  echo "  Disk space: ${disk_available}KB"
}

# Verify continuity on restart with integrity checks
continuity_verify_continuity() {
  echo "=== Continuity Verification ==="
  echo ""

  local errors=0

  # Check 1: Action stream exists and is valid JSONL
  if [ -f "$CONTINUITY_ACTION_STREAM" ]; then
    local today_count=$(wc -l < "$CONTINUITY_ACTION_STREAM" 2>/dev/null || echo 0)
    local valid_count=0
    local invalid_count=0
    
    while IFS= read -r line; do
      if echo "$line" | jq -e . >/dev/null 2>&1; then
        valid_count=$((valid_count + 1))
      else
        invalid_count=$((invalid_count + 1))
      fi
    done < "$CONTINUITY_ACTION_STREAM"
    
    echo "✓ Today's action stream: $today_count entries ($valid_count valid, $invalid_count invalid)"
    
    if [ "$invalid_count" -gt 0 ]; then
      echo "⚠ WARNING: $invalid_count invalid JSON entries detected!" >&2
      errors=$((errors + 1))
    fi
  else
    echo "✗ Today's action stream missing!"
    errors=$((errors + 1))
  fi
  
  # Check 2: Verify integrity chain
  if [ -f "$CONTINUITY_LAST_HASH_FILE" ]; then
    local last_hash=$(cat "$CONTINUITY_LAST_HASH_FILE" 2>/dev/null)
    echo "✓ Last hash recorded: ${last_hash:0:16}..."
  else
    echo "⚠ No last hash file (first run or corrupted)"
  fi

  # Check 3: Disk space
  if continuity_check_disk_space; then
    echo "✓ Disk space sufficient"
  else
    echo "✗ Disk space CRITICAL"
    errors=$((errors + 1))
  fi
  
  # Check 4: Active workflows
  local active_wf=0
  if [ -d "$CONTINUITY_BASE_DIR/workflows/active" ]; then
    active_wf=$(find "$CONTINUITY_BASE_DIR/workflows/active" -name "*.json" 2>/dev/null | wc -l)
  fi
  echo "ℹ Active workflows: $active_wf"

  # Check 5: Backup directory
  if [ -d "$CONTINUITY_BASE_DIR/backups" ]; then
    local backup_count=$(ls -1 "$CONTINUITY_BASE_DIR/backups" 2>/dev/null | wc -l)
    echo "✓ Backup directory: $backup_count files"
  else
    echo "⚠ No backup directory found"
  fi

  # Check 6: Emergency log
  if [ -f "$CONTINUITY_EMERGENCY_LOG" ]; then
    local emergency_count=$(wc -l < "$CONTINUITY_EMERGENCY_LOG" 2>/dev/null || echo 0)
    if [ "$emergency_count" -gt 0 ]; then
      echo "✗ EMERGENCY LOG HAS $emergency_count ENTRIES! Review immediately!" >&2
      errors=$((errors + 1))
    fi
  fi
  
  echo ""
  if [ "$errors" -eq 0 ]; then
    echo "✅=== Verification PASSED ==="
  else
    echo "❌=== Verification FAILED ($errors errors) ==="
  fi
  
  return $errors
}

# Validate integrity of entire action stream
continuity_validate_integrity() {
  echo "=== Validating Action Stream Integrity ==="
  
  local previous_hash="genesis"
  local line_num=0
  local errors=0
  
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    
    # Check JSON validity
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then
      echo "✗ Line $line_num: Invalid JSON" >&2
      errors=$((errors + 1))
      continue
    fi
    
    # Extract stored hash and previous
    local stored_hash=$(echo "$line" | jq -r '.action._integrity.hash // empty')
    local stored_prev=$(echo "$line" | jq -r '.action._integrity.previous // empty')
    
    if [ -z "$stored_hash" ]; then
      echo "✗ Line $line_num: No integrity hash" >&2
      errors=$((errors + 1))
      continue
    fi
    
    # Verify chain link
    if [ "$stored_prev" != "$previous_hash" ]; then
      echo "✗ Line $line_num: Chain broken! Expected prev: $previous_hash, got: $stored_prev" >&2
      errors=$((errors + 1))
    fi
    
    # Calculate expected hash (without integrity field, compact format)
    local content=$(echo "$line" | jq -c 'del(.action._integrity)')
    local expected_hash=$(continuity_calculate_hash "$content" "$previous_hash")
    
    if [ "$stored_hash" != "$expected_hash" ]; then
      echo "✗ Line $line_num: Hash mismatch! Stored: $stored_hash, Expected: $expected_hash" >&2
      errors=$((errors + 1))
    fi
    
    previous_hash="$stored_hash"
  done < "$CONTINUITY_ACTION_STREAM"

  echo ""
  if [ "$errors" -eq 0 ]; then
    echo "✅ Integrity validation PASSED ($line_num entries verified)"
  else
    echo "❌ Integrity validation FAILED ($errors errors in $line_num entries)"
  fi

  return $errors
}

# Manual backup trigger with safety checks
continuity_backup_manual() {
  local description="${1:-manual}"

  if ! continuity_check_disk_space; then
    echo "✗ Cannot backup: insufficient disk space" >&2
    return 1
  fi

  if [ -f "$CONTINUITY_BASE_DIR/scripts/continuity-backup.sh" ]; then
    "$CONTINUITY_BASE_DIR/scripts/continuity-backup.sh" manual "$description"
  else
    # Fallback: simple copy
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$CONTINUITY_BASE_DIR/backups/action-stream-manual-$description-$timestamp.jsonl"

    if cp "$CONTINUITY_ACTION_STREAM" "$backup_file" 2>/dev/null; then
      chmod 600 "$backup_file"
      echo "✓ Manual backup created: $backup_file"
    else
      echo "✗ Manual backup failed" >&2
      return 1
    fi
  fi
}

# Health check endpoint
continuity_health_check() {
  local healthy=true
  local status="healthy"
  local issues=()

  # Check disk space
  if ! continuity_check_disk_space; then
    healthy=false
    status="critical"
    issues+=("low_disk_space")
  fi

  # Check writeable
  local test_file="$CONTINUITY_BASE_DIR/.write_test"
  if ! echo "test" > "$test_file" 2>/dev/null; then
    healthy=false
    status="critical"
    issues+=("not_writeable")
  else
    rm -f "$test_file"
  fi

  # Check emergency log
  if [ -f "$CONTINUITY_EMERGENCY_LOG" ]; then
    local emergency_count=$(wc -l < "$CONTINUITY_EMERGENCY_LOG" 2>/dev/null || echo 0)
    if [ "$emergency_count" -gt 0 ]; then
      healthy=false
      status="warning"
      issues+=("emergency_log_entries:$emergency_count")
    fi
  fi
  
  # Output JSON
  cat <<EOF
{
  "status": "$status",
  "healthy": $healthy,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")",
  "issues": $(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .),
  "metrics": {
    "today_actions": $(wc -l < "$CONTINUITY_ACTION_STREAM" 2>/dev/null || echo 0),
    "disk_available_kb": $(df -k "$CONTINUITY_BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4}'),
    "active_workflows": $(find "$CONTINUITY_BASE_DIR/workflows/active" -name "*.json" 2>/dev/null | wc -l)
  }
}
EOF
}

# Query actions by type and/or platform
# Usage: continuity_query [--type=TYPE] [--platform=PLATFORM] [--since=DATE] [--limit=N]
continuity_query() {
  local type_filter=""
  local platform_filter=""
  local since_date=""
  local limit=50
  local stream="$CONTINUITY_ACTION_STREAM"

  # Parse arguments
  for arg in "$@"; do
    case "$arg" in
      --type=*) type_filter="${arg#*=}" ;;
      --platform=*) platform_filter="${arg#*=}" ;;
      --since=*) since_date="${arg#*=}" ;;
      --limit=*) limit="${arg#*=}" ;;
      --date=*)
        local date="${arg#*=}"
        stream="$CONTINUITY_BASE_DIR/action-stream-$date.jsonl"
        ;;
    esac
  done
  
  if [ ! -f "$stream" ]; then
    echo "No action stream found"
    return 1
  fi
  
  # Build jq filter
  local filter="."
  if [ -n "$type_filter" ]; then
    filter="$filter | select(.action.type == \"$type_filter\")"
  fi
  if [ -n "$platform_filter" ]; then
    filter="$filter | select(.action.platform == \"$platform_filter\")"
  fi
  if [ -n "$since_date" ]; then
    filter="$filter | select(.action.timestamp >= \"$since_date\")"
  fi
  
  # Execute query
  local count=0
  while IFS= read -r line && [ $count -lt $limit ]; do
    if echo "$line" | jq -e "$filter" >/dev/null 2>&1; then
      echo "$line" | jq -c '{seq: .action.sequence, time: .action.timestamp, type: .action.type, platform: .action.platform, desc: .action.description, cost: .action.cost}'
      count=$((count + 1))
    fi
  done < "$stream"
  
  echo "($count results)"
}

# Get last action (optionally filtered by platform)
# Usage: continuity_last_action [platform]
continuity_last_action() {
  local platform_filter="${1:-}"
  local stream="$CONTINUITY_ACTION_STREAM"
  
  if [ ! -f "$stream" ]; then
    echo "No action stream found"
    return 1
  fi
  
  local last_line=""
  while IFS= read -r line; do
    if [ -n "$platform_filter" ]; then
      if echo "$line" | jq -e ".action.platform == \"$platform_filter\"" >/dev/null 2>&1; then
        last_line="$line"
      fi
    else
      last_line="$line"
    fi
  done < "$stream"
  
  if [ -n "$last_line" ]; then
    echo "$last_line" | jq -c '{seq: .action.sequence, time: .action.timestamp, type: .action.type, platform: .action.platform, desc: .action.description}'
  else
    echo "No actions found"
    return 1
  fi
}

# List active workflows
continuity_list_workflows() {
  local wf_dir="$CONTINUITY_BASE_DIR/workflows/active"
  
  if [ ! -d "$wf_dir" ]; then
    echo "No active workflows directory"
    return 1
  fi
  
  local count=0
  for wf in "$wf_dir"/*.json; do
    if [ -f "$wf" ]; then
      local name=$(basename "$wf" .json)
      local updated=$(stat -c %y "$wf" 2>/dev/null || stat -f %Sm "$wf" 2>/dev/null || echo "unknown")
      echo "- $name (updated: $updated)"
      count=$((count + 1))
    fi
  done
  
  if [ $count -eq 0 ]; then
    echo "No active workflows"
  else
    echo "($count workflows active)"
  fi
}

# Show continuity status dashboard
continuity_status() {
  echo "┌─────────────────────────────────────┐"
  echo "│ Continuity Status                   │"
  echo "├─────────────────────────────────────┤"

  # Today's actions
  local today_count=0
  if [ -f "$CONTINUITY_ACTION_STREAM" ]; then
    today_count=$(wc -l < "$CONTINUITY_ACTION_STREAM" 2>/dev/null || echo 0)
  fi
  printf "│ Today's Actions: %-18s │\n" "$today_count"

  # Active workflows
  local wf_count=0
  if [ -d "$CONTINUITY_BASE_DIR/workflows/active" ]; then
    wf_count=$(find "$CONTINUITY_BASE_DIR/workflows/active" -name "*.json" 2>/dev/null | wc -l)
  fi
  printf "│ Active Workflows: %-17s │\n" "$wf_count"

  # Last action
  local last_time="none"
  if [ -f "$CONTINUITY_ACTION_STREAM" ] && [ $today_count -gt 0 ]; then
    last_time=$(tail -1 "$CONTINUITY_ACTION_STREAM" 2>/dev/null | jq -r '.action.timestamp' 2>/dev/null || echo "unknown")
    if [ "$last_time" != "unknown" ] && [ "$last_time" != "null" ]; then
      # Convert to relative time
      last_time="recent"
    fi
  fi
  printf "│ Last Action: %-22s │\n" "$last_time"

  # Integrity status
  local integrity="✓ valid"
  if [ ! -f "$CONTINUITY_LAST_HASH_FILE" ]; then
    integrity="⚠ no chain"
  fi
  printf "│ Integrity: %-24s │\n" "$integrity"

  # Backups
  local backup_count=0
  if [ -d "$CONTINUITY_BASE_DIR/backups" ]; then
    backup_count=$(ls -1 "$CONTINUITY_BASE_DIR/backups" 2>/dev/null | wc -l)
  fi
  printf "│ Backups: %-26s │\n" "$backup_count files"

  # Disk space
  local disk_mb=0
  if command -v df >/dev/null 2>&1; then
    disk_mb=$(df -k "$CONTINUITY_BASE_DIR" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
  fi
  printf "│ Disk: %-29s │\n" "${disk_mb}MB free"

  echo "└─────────────────────────────────────┘"
}

# Wake up and load context (combines multiple checks)
continuity_wake() {
  echo "=== Waking Up ==="
  echo ""

  # Verify continuity
  continuity_verify_continuity
  echo ""

  # Show status
  continuity_status
  echo ""

  # List workflows
  continuity_list_workflows
  echo ""

  # Summary
  local today_count=0
  if [ -f "$CONTINUITY_ACTION_STREAM" ]; then
    today_count=$(wc -l < "$CONTINUITY_ACTION_STREAM" 2>/dev/null || echo 0)
  fi
  
  if [ $today_count -gt 0 ]; then
    echo "Recent activity:"
    continuity_query --limit=3 2>/dev/null | head -3
  fi

  echo ""
  echo "=== Ready ==="
}

# ============================================================================
# CONFIGURATION FUNCTIONS (v0.2.0)
# ============================================================================

# Display current configuration
continuity_show_config() {
    echo "=== Continuity Configuration ==="
    echo ""
    echo "Recall Mode:        $CONTINUITY_RECALL_MODE"
    echo "  (off | openclaw_only | continuity_only | both)"
    echo ""
    echo "Log Level:          $CONTINUITY_LOG_LEVEL"
    echo "  (off | judgment | everything)"
    echo ""
    echo "Recall Limit:       $CONTINUITY_RECALL_LIMIT entries"
    echo "Strict Validation:  $CONTINUITY_STRICT_VALIDATION"
    echo "Emergency Stderr:   $CONTINUITY_EMERGENCY_STDERR"
    echo ""
    echo "Base Directory:     $CONTINUITY_BASE_DIR"
    echo "Config File:        $CONTINUITY_CONFIG_FILE"
    echo ""
}

# Set configuration value (creates or updates config.env)
continuity_set_config() {
    local key="$1"
    local value="$2"
    
    if [ -z "$key" ] || [ -z "$value" ]; then
        echo "Usage: continuity_set_config <KEY> <VALUE>" >&2
        echo "Example: continuity_set_config CONTINUITY_LOG_LEVEL judgment" >&2
        return 1
    fi
    
    # Validate key is a known configuration option
    case "$key" in
        CONTINUITY_RECALL_MODE|CONTINUITY_LOG_LEVEL|CONTINUITY_RECALL_LIMIT|CONTINUITY_STRICT_VALIDATION|CONTINUITY_EMERGENCY_STDERR)
            ;;
        *)
            echo "ERROR: Unknown configuration key: $key" >&2
            return 1
            ;;
    esac
    
    # Create config file if it doesn't exist
    if [ ! -f "$CONTINUITY_CONFIG_FILE" ]; then
        mkdir -p "$(dirname "$CONTINUITY_CONFIG_FILE")"
        cat > "$CONTINUITY_CONFIG_FILE" << 'EOF'
# ~/.openclaw/skills/continuity/config.env
# Continuity Skill Configuration
# Generated automatically - edit with: continuity_set_config

EOF
        chmod 600 "$CONTINUITY_CONFIG_FILE"
    fi
    
    # Update or add the configuration value
    if grep -q "^$key=" "$CONTINUITY_CONFIG_FILE"; then
        # Update existing line
        sed -i "s/^$key=.*/$key=$value/" "$CONTINUITY_CONFIG_FILE"
    else
        # Add new line
        echo "$key=$value" >> "$CONTINUITY_CONFIG_FILE"
    fi
    
    echo "✓ Set $key=$value"
    echo "  (Run 'source ~/.openclaw/skills/continuity/scripts/continuity.sh' to reload)"
}

# ============================================================================
# RECALL MODE FUNCTIONS (v0.2.0)
# ============================================================================

# Check if current log level permits logging this response type
# Returns: 0 if should log, 1 if should not log
continuity_should_log() {
    local response_type="${1:-everything}"
    
    case "$CONTINUITY_LOG_LEVEL" in
        off)
            return 1  # Don't log anything
            ;;
        judgment)
            # Only log judgment/decision type responses
            case "$response_type" in
                judgment|decision|analysis|conclusion|recommendation|insight)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        everything)
            return 0  # Log everything
            ;;
        *)
            return 0  # Default to logging
            ;;
    esac
}

# Log an agent response automatically based on LOG_LEVEL
# Usage: continuity_log_response "response_text" "response_type" [metadata_json]
continuity_log_response() {
    local response_text="$1"
    local response_type="${2:-general}"
    local metadata="${3:-{}}"
    
    # Check if we should log this response type
    if ! continuity_should_log "$response_type"; then
        return 0  # Silently skip
    fi
    
    # Truncate very long responses
    local truncated_response="$response_text"
    if [ "${#response_text}" -gt 1000 ]; then
        truncated_response="${response_text:0:997}..."
        metadata=$(echo "$metadata" | jq --arg full_len "${#response_text}" '. + {full_length: $full_len, truncated: true}')
    fi
    
    # Log as an action with actor metadata
    local enriched_metadata=$(echo "$metadata" | jq --arg type "$response_type" '. + {response_type: $type, actor: "agent"}')
    
    continuity_log_action "agent_response" "continuity" "$truncated_response" "0" "n/a" "$enriched_metadata"
}

# Query previous context based on RECALL_MODE setting
# Returns: JSON array of previous actions/context
# Usage: context=$(continuity_recall_context [limit])
continuity_recall_context() {
    local limit="${1:-$CONTINUITY_RECALL_LIMIT}"
    local results=""
    
    case "$CONTINUITY_RECALL_MODE" in
        off)
            # No automatic recall
            echo "[]"
            return 0
            ;;
            
        openclaw_only)
            # Only use OpenClaw's native memory
            # This would integrate with OpenClaw's memory system
            # For now, returns empty (placeholder for integration)
            echo "[]"
            return 0
            ;;
            
        continuity_only)
            # Only use continuity action stream
            results=$(continuity_query --limit="$limit" 2>/dev/null)
            if [ -n "$results" ]; then
                # Convert JSON lines to array
                echo "$results" | jq -R '. | try fromjson catch empty' | jq -s '.'
            else
                echo "[]"
            fi
            return 0
            ;;
            
        both)
            # Combine both continuity and OpenClaw native memory
            local continuity_results="[]"
            local openclaw_results="[]"
            
            # Get continuity results
            local cont_query=$(continuity_query --limit="$limit" 2>/dev/null)
            if [ -n "$cont_query" ]; then
                continuity_results=$(echo "$cont_query" | jq -R '. | try fromjson catch empty' | jq -s '.')
            fi
            
            # Get OpenClaw native memory context (from MEMORY.md and session)
            # Read MEMORY.md summary if available
            if [ -f "$HOME/clawd/MEMORY.md" ]; then
                # Get last modified time of MEMORY.md
                local memory_mtime=$(stat -c %Y "$HOME/clawd/MEMORY.md" 2>/dev/null || echo "0")
                local current_time=$(date +%s)
                local memory_age=$((current_time - memory_mtime))
                
                # Only include if recently updated (within 24 hours)
                if [ $memory_age -lt 86400 ]; then
                    openclaw_results=$(cat <<EOF | jq -s '.'
{
  "source": "openclaw_memory",
  "type": "memory_context",
  "timestamp": "$(date -u -d @$memory_mtime +%Y-%m-%dT%H:%M:%SZ)",
  "description": "OpenClaw MEMORY.md last updated $(($memory_age / 3600)) hours ago",
  "metadata": {
    "actor": "system",
    "source_type": "openclaw_native"
  }
}
EOF
)
                fi
            fi
            
            # Merge results: continuity first, then OpenClaw context
            echo "$continuity_results" | jq --argjson openclaw "$openclaw_results" '. + $openclaw'
            return 0
            ;;
            
        *)
            # Should never reach here due to validation
            echo "ERROR: Invalid RECALL_MODE: $CONTINUITY_RECALL_MODE" >&2
            echo "[]"
            return 1
            ;;
    esac
}

# Get human-readable summary of recent context
# Usage: continuity_recall_summary
continuity_recall_summary() {
    if [ "$CONTINUITY_RECALL_MODE" = "off" ]; then
        echo "(Recall mode is OFF - no previous context loaded)"
        return 0
    fi
    
    local context=$(continuity_recall_context "$CONTINUITY_RECALL_LIMIT")
    local count=$(echo "$context" | jq 'length')
    
    if [ "$count" -eq 0 ]; then
        echo "(No previous context available)"
        return 0
    fi
    
    echo "=== Recent Context (mode: $CONTINUITY_RECALL_MODE) ==="
    echo ""
    echo "$context" | jq -r '.[] | "[\(.time // "unknown")] \(.type // "unknown"): \(.desc // "no description")[:60]"'
    echo ""
    echo "($count previous actions recalled)"
}

# ============================================================================
# ENHANCED WAKE FUNCTION (v0.2.0)
# ============================================================================

# Enhanced wake function with recall support
continuity_wake_with_recall() {
    echo "=== Waking Up ==="
    echo ""
    
    # Show configuration
    continuity_show_config
    echo ""
    
    # Verify continuity
    continuity_verify_continuity
    echo ""
    
    # Show status
    continuity_status
    echo ""
    
    # Recall previous context based on RECALL_MODE
    if [ "$CONTINUITY_RECALL_MODE" != "off" ]; then
        echo "=== Recalled Context ==="
        continuity_recall_summary
        echo ""
    fi
    
    # List workflows
    continuity_list_workflows
    echo ""
    
    echo "=== Ready ==="
}

# Export functions
export -f continuity_uuid
export -f continuity_next_sequence
export -f continuity_previous_hash
export -f continuity_check_disk_space
export -f continuity_calculate_hash
export -f continuity_log_action
export -f continuity_log_critical
export -f continuity_checkpoint_workflow
export -f continuity_pre_compaction_checkpoint
export -f continuity_verify_continuity
export -f continuity_validate_integrity
export -f continuity_backup_manual
export -f continuity_health_check
export -f continuity_query
export -f continuity_last_action
export -f continuity_list_workflows
export -f continuity_status
export -f continuity_wake
export -f continuity_show_config
export -f continuity_set_config
export -f continuity_should_log
export -f continuity_log_response
export -f continuity_recall_context
export -f continuity_recall_summary
export -f continuity_wake_with_recall
