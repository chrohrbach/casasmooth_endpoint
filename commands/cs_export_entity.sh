#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.0.0
#
# Exports a entity_id with his tsate
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

# Check that exactly 2 arguments are passed
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 entity_id state"
    exit 1
fi

entity_id="$1"
state="$2"


# Get the current timestamp
timestamp=$(date '+%Y-%m-%d %H:%M:%S')

# Determine the log file name (e.g., logs/YYYY-MM-DD.log)
log_dir="${cs_path}/logs/states"
mkdir -p "$log_dir"
log_file="$log_dir/$(date '+%Y-%m-%d').csv"

# Write the log entry
echo "$timestamp;$entity_id;$state" >> "$log_file"

exit 0
