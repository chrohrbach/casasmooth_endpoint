#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 0.1.2
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

exit 0