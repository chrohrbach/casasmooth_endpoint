#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 0.1.0
#
# Log an energy purchase (consumption session) for billing, per user/month
#
# Usage: cs_log_energy_purchase.sh email guid entity_id entity_name kwh cost start_time end_time
#   email: user email address (used for log folder)
#   guid: unique session identifier
#   entity_id: device/entity identifier
#   entity_name: human-readable name
#   kwh: energy consumed (kWh)
#   cost: cost for the session (CHF)
#   start_time: session start (ISO8601)
#   end_time: session end (ISO8601)
#
#=================================== Include cs_library
include="/config/casasmooth/lib/cs_library.sh"
if ! source "${include}"; then
  echo "ERROR: Failed to source ${include}"
  exit 1
fi
#===================================

#----- Usage check: exactly 8 arguments
if [ "$#" -ne 8 ]; then
  echo "Usage: $(basename "$0") email guid entity_id entity_name kwh cost start_time end_time" >&2
  exit 1
fi

#----- Assign arguments
email="$1"
guid="$2"
entity_id="$3"
entity_name="$4"
kwh="$5"
cost="$6"
start_time="$7"
end_time="$8"

#----- Prepare log directory and file (per user, per month)
log_dir="${cs_logs}/energy_purchases/${email}"
mkdir -p "$log_dir"
month=$(date -d "$start_time" '+%Y-%m')
log_file="${log_dir}/${month}.csv"

#----- Write CSV header if file does not exist
if [ ! -f "$log_file" ]; then
  echo "timestamp,guid,entity_id,entity_name,kwh,cost,start_time,end_time" > "$log_file"
fi

#----- Write log entry
now=$(date '+%Y-%m-%dT%H:%M:%S')
echo "$now,$guid,$entity_id,\"$entity_name\",$kwh,$cost,$start_time,$end_time" >> "$log_file"

exit 0
