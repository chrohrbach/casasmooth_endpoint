#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 0.5
#
# Log a sensor event in a daily JSON log file
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

#----- Usage check: exactly 9 arguments
if [ "$#" -ne 9 ]; then
  echo "Usage: $(basename "$0") area_id class_id entity_id state unit_of_measurement device_class entity_name secs_interval guid" >&2
  echo "$1-$2-$3-$4-$5-$6-$7-$8-$9" >> "${0}.log"
  exit 1
fi

#----- Assign arguments
area_id="$1"
class_id="$2"
entity_id="$3"
state="$4"
unit_of_measurement="$5"
device_class="$6"
entity_name="$7"
secs_interval="$8"
guid="$9"

#----- Prepare daily JSON log file
timestamp=$(date '+%Y-%m-%d %H:%M:%S')
log_dir="${cs_path}/logs/sensors"
mkdir -p "$log_dir"
#log_file="${log_dir}/$(date '+%Y%m%d%H0000').json"
csv_file="${log_dir}/$(date '+%Y%m%d%H0000').csv"

#----- Write one JSON object per line (NDJSON style)
#cat <<EOF >> "$log_file"
#{
#  "timestamp": "$timestamp",
#  "area_id": "$area_id",
#  "class_id": "$class_id",
#  "entity_id": "$entity_id",
#  "state": "$state",
#  "unit_of_measurement": "$unit_of_measurement",
#  "device_class": "$device_class",
#  "entity_name": "$entity_name",
#  "secs_interval": "$secs_interval",
#  "guid": "$guid"
#}
#EOF

#----- Write one CSV object per line
cat <<EOF >> "$csv_file"
$timestamp;$area_id;$class_id;$entity_id;$state;$unit_of_measurement;$device_class;$secs_interval
EOF

exit 0
