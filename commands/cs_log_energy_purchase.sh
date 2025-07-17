#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 0.1.1
#
# Log an energy purchase (consumption session) for billing, per user/month
#
# Usage: cs_log_energy_purchase.sh txid email entity_id entity_name ordered_kwh consumed_kwh start_time end_time duration_hours end_reason
#   txid: transaction identifier
#   email: user email address (used for log folder)
#   entity_id: device/entity identifier
#   entity_name: human-readable name
#   ordered_kwh: originally ordered energy (kWh)
#   consumed_kwh: actually consumed energy (kWh)
#   start_time: session start (ISO8601)
#   end_time: session end (ISO8601)
#   duration_hours: session duration in hours
#   end_reason: reason why session ended
#
#=================================== Include cs_library
include="/config/casasmooth/lib/cs_library.sh"
if ! source "${include}"; then
  echo "ERROR: Failed to source ${include}"
  exit 1
fi
#===================================

#----- Usage check: exactly 10 arguments
if [ "$#" -ne 10 ]; then
  echo "Usage: $(basename "$0") txid email entity_id entity_name ordered_kwh consumed_kwh start_time end_time duration_hours end_reason" >&2
  exit 1
fi

#----- Assign arguments
txid="$1"
email="$2"
entity_id="$3"
entity_name="$4"
ordered_kwh="$5"
consumed_kwh="$6"
start_time="$7"
end_time="$8"
duration_hours="$9"
end_reason="${10}"

#----- Prepare log directory and file (per user, per month)
log_dir="${cs_logs}/energy_purchases/${email}"
mkdir -p "$log_dir"
month=$(date -d "$start_time" '+%Y-%m')
log_file="${log_dir}/${month}.csv"

#----- Write CSV header if file does not exist
if [ ! -f "$log_file" ]; then
  echo "timestamp,txid,entity_id,entity_name,ordered_kwh,consumed_kwh,start_time,end_time,duration_hours,end_reason" > "$log_file"
fi

#----- Write log entry
now=$(date '+%Y-%m-%dT%H:%M:%S')
echo "$now,\"$txid\",\"$entity_id\",\"$entity_name\",$ordered_kwh,$consumed_kwh,\"$start_time\",\"$end_time\",$duration_hours,\"$end_reason\"" >> "$log_file"

exit 0
