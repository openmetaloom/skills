#!/bin/bash
# memory-reconcile.sh - Daily financial and action reconciliation
# Version: 0.1.0
# Usage: memory-reconcile.sh [options]

MEMORY_DIR="${MEMORY_BASE_DIR:-$HOME/clawd/memory}"
REPORT_FILE="$MEMORY_DIR/reports/reconciliation-$(date +%Y-%m-%d).md"
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "yesterday")

mkdir -p "$MEMORY_DIR/reports"
chmod 700 "$MEMORY_DIR/reports"

# Colors for terminal output (if supported)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}✓${NC} $1"
  echo "✓ $1" >> "$REPORT_FILE"
}

log_warn() {
  echo -e "${YELLOW}⚠${NC} $1" >&2
  echo "⚠ $1" >> "$REPORT_FILE"
}

log_error() {
  echo -e "${RED}✗${NC} $1" >&2
  echo "✗ $1" >> "$REPORT_FILE"
}

echo "# Daily Reconciliation Report" > "$REPORT_FILE"
echo "Date: $(date +%Y-%m-%d)" >> "$REPORT_FILE"
echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

echo "=== Memory Reconciliation Report ==="
echo "Date: $(date +%Y-%m-%d)"
echo ""

# 1. Count today's actions
echo "## Action Count" >> "$REPORT_FILE"
TODAY_STREAM="$MEMORY_DIR/action-stream-$(date +%Y-%m-%d).jsonl"
YESTERDAY_STREAM="$MEMORY_DIR/action-stream-$YESTERDAY.jsonl"

if [ -f "$TODAY_STREAM" ]; then
  TODAY_COUNT=$(wc -l < "$TODAY_STREAM")
  log_info "Today's actions: $TODAY_COUNT"
  
  # Count by severity
  CRITICAL_COUNT=$(grep '"severity":"critical"' "$TODAY_STREAM" 2>/dev/null | wc -l)
  HIGH_COUNT=$(grep '"severity":"high"' "$TODAY_STREAM" 2>/dev/null | wc -l)
  
  if [ "$CRITICAL_COUNT" -gt 0 ]; then
    log_info "  Critical actions: $CRITICAL_COUNT"
  fi
  if [ "$HIGH_COUNT" -gt 0 ]; then
    log_info "  High severity: $HIGH_COUNT"
  fi
else
  log_warn "No actions logged today"
fi

if [ -f "$YESTERDAY_STREAM" ]; then
  YESTERDAY_COUNT=$(wc -l < "$YESTERDAY_STREAM")
  log_info "Yesterday's actions: $YESTERDAY_COUNT"
else
  log_warn "Yesterday's stream not found"
fi

echo "" >> "$REPORT_FILE"

# 2. Financial summary
echo "## Financial Summary" >> "$REPORT_FILE"

if [ -f "$TODAY_STREAM" ]; then
  # Extract costs and sum them
  TOTAL_COST=$(grep -o '"cost":[0-9.]*' "$TODAY_STREAM" 2>/dev/null | cut -d: -f2 | awk '{sum+=$1} END {printf "%.2f", sum}')
  
  if [ -n "$TOTAL_COST" ] && [ "$TOTAL_COST" != "0.00" ]; then
    log_info "Total spending today: \$$TOTAL_COST USD"
  else
    log_info "No financial transactions today"
  fi
  
  # List individual costs > $1
  echo "" >> "$REPORT_FILE"
  echo "### Transactions > $1.00" >> "$REPORT_FILE"
  
  grep -E '"cost":([1-9][0-9]*|[0-9]+\.[0-9]+)' "$TODAY_STREAM" 2>/dev/null | while read -r line; do
    local desc=$(echo "$line" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
    local cost=$(echo "$line" | grep -o '"cost":[0-9.]*' | cut -d: -f2)
    if [ -n "$desc" ] && [ -n "$cost" ]; then
      echo "- $desc: \$$cost" >> "$REPORT_FILE"
    fi
  done
else
  log_warn "Cannot calculate financial summary - no action stream"
fi

echo "" >> "$REPORT_FILE"

# 3. Check for errors and warnings
echo "## Health Check" >> "$REPORT_FILE"

# Check emergency log
if [ -f "$MEMORY_DIR/EMERGENCY_RECOVERY.jsonl" ]; then
  EMERGENCY_COUNT=$(wc -l < "$MEMORY_DIR/EMERGENCY_RECOVERY.jsonl")
  if [ "$EMERGENCY_COUNT" -gt 0 ]; then
    log_error "EMERGENCY LOG HAS $EMERGENCY_COUNT ENTRIES!"
    echo "CRITICAL: Review $MEMORY_DIR/EMERGENCY_RECOVERY.jsonl immediately" >> "$REPORT_FILE"
  fi
fi

# Check alerts
if [ -f "$MEMORY_DIR/ALERTS.jsonl" ]; then
  ALERT_COUNT=$(wc -l < "$MEMORY_DIR/ALERTS.jsonl" 2>/dev/null || echo 0)
  if [ "$ALERT_COUNT" -gt 0 ]; then
    log_warn "$ALERT_COUNT alerts in alert log"
  fi
fi

# Check disk space
AVAILABLE=$(df -k "$MEMORY_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$AVAILABLE" ]; then
  AVAILABLE_MB=$((AVAILABLE / 1024))
  if [ "$AVAILABLE" -lt 10240 ]; then  # Less than 10MB
    log_error "Low disk space: ${AVAILABLE_MB}MB available"
  else
    log_info "Disk space: ${AVAILABLE_MB}MB available"
  fi
else
  log_warn "Could not check disk space"
fi

# Check active workflows
ACTIVE_WORKFLOWS=$(find "$MEMORY_DIR/workflows/active" -name "*.json" 2>/dev/null | wc -l)
if [ "$ACTIVE_WORKFLOWS" -gt 0 ]; then
  log_info "Active workflows: $ACTIVE_WORKFLOWS"
else
  log_info "No active workflows"
fi

echo "" >> "$REPORT_FILE"

# 4. Integrity check
echo "## Integrity Check" >> "$REPORT_FILE"

if [ -f "$TODAY_STREAM" ]; then
  INVALID_COUNT=0
  while IFS= read -r line; do
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then
      INVALID_COUNT=$((INVALID_COUNT + 1))
    fi
  done < "$TODAY_STREAM"
  
  if [ "$INVALID_COUNT" -eq 0 ]; then
    log_info "All entries valid JSON"
  else
    log_error "$INVALID_COUNT invalid JSON entries found!"
  fi
else
  log_warn "Cannot check integrity - no action stream"
fi

echo "" >> "$REPORT_FILE"
echo "---" >> "$REPORT_FILE"
echo "Next steps:" >> "$REPORT_FILE"
echo "1. Review any errors or warnings above" >> "$REPORT_FILE"
echo "2. Check emergency log if entries exist" >> "$REPORT_FILE"
echo "3. Archive this report after review" >> "$REPORT_FILE"

echo ""
echo "=== Report saved to: $REPORT_FILE ==="

# Return error code if there were critical issues
if [ -f "$MEMORY_DIR/EMERGENCY_RECOVERY.jsonl" ] && [ $(wc -l < "$MEMORY_DIR/EMERGENCY_RECOVERY.jsonl") -gt 0 ]; then
  exit 1
fi

if [ -n "$AVAILABLE" ] && [ "$AVAILABLE" -lt 10240 ]; then
  exit 1
fi

exit 0
