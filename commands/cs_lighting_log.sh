#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.0.4
#
# Log a lighting event in a daily log file
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

# Check that exactly 3 arguments are passed
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 area_id entity_id state"
    exit 1
fi

area_id="$1"
entity_id="$2"
state="$3"

# Set state to "off" if it is neither "on" nor "off"
if [[ "$state" != "on" && "$state" != "off" ]]; then
    state="off"
fi

# Get the current timestamp
timestamp=$(date '+%Y-%m-%d %H:%M:%S')

# Determine the log file name (e.g., logs/YYYY-MM-DD.log)
log_dir="${cs_path}/logs/lighting"
mkdir -p "$log_dir"
log_file="$log_dir/$(date '+%Y-%m-%d').csv"

# Write the log entry
echo "$timestamp;$area_id;$entity_id;$state" >> "$log_file"

exit 0
