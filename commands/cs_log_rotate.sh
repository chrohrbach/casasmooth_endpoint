#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 0.1.3
#
# Reduce the size of the log
# 
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

verbose=true

LOG_FILE="${hass_path}/home-assistant.log"
TEMP_DIR=$(mktemp -d)
TEMP_LOG_FILE="${TEMP_DIR}/home-assistant.tmp"

# Check if the log file exists
if [ ! -f "$LOG_FILE" ]; then
  log "WARNING: Log file '${LOG_FILE}' not found."
  exit 0
fi

# Keep only the last 1000 lines of the log
tail -n 1000 "$LOG_FILE" > "$TEMP_LOG_FILE"

# Replace the original log file with the cut version
mv "$TEMP_LOG_FILE" "$LOG_FILE"

log "INFO: '${LOG_FILE}' has been reduced to 1000 lines."

# Clean up the temporary directory
rm -rf "$TEMP_DIR"

# Check if the Home Assistant DB exceeds 25GB
DB_FILE="${hass_path}/home_assistant_v2.db"
MAX_SIZE=$((25 * 1024 * 1024 * 1024))
if [ -f "$DB_FILE" ]; then
    if command -v stat > /dev/null 2>&1; then
        DB_SIZE=$(stat -c%s "$DB_FILE")
    else
        DB_SIZE=$(du -b "$DB_FILE" | cut -f1)
    fi
    if [ "$DB_SIZE" -gt "$MAX_SIZE" ]; then
        log "WARNING: DB file '${DB_FILE}' size ${DB_SIZE} exceeds 25GB. Deleting and restarting Home Assistant."
        rm -f "$DB_FILE"
        log "Restarting Home Assistant core..."
        ha core restart
    fi
else
    log "INFO: DB file '${DB_FILE}' not found."
fi

exit 0