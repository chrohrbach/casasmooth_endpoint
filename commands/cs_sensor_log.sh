#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 0.7.1
#
# Log a sensor event in a daily JSON log file, CSV and Parquet with unit conversion
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

#----- Prepare timestamp and log directories
timestamp=$(date '+%Y-%m-%d %H:%M:%S')
log_dir="${cs_logs}/sensors/${device_class}"
mkdir -p "$log_dir"
file_base="${log_dir}/$(date '+%Y%m%d%H0000')"
csv_file="${file_base}.csv"

#----- Unit conversion function
convert_unit() {
  local value="$1"
  local unit="$2"
  local new_value="$value"
  local new_unit="$unit"
  case "$unit" in
    W)
      # Convert W to kW
      new_value=$(awk "BEGIN {printf \"%.3f\", $value/1000}")
      new_unit="kW"
      ;;
    Wh)
      # Convert Wh to kWh
      new_value=$(awk "BEGIN {printf \"%.3f\", $value/1000}")
      new_unit="kWh"
      ;;
    kW)
      # Already kW
      ;;
    kWh)
      # Already kWh
      ;;
    m3)
      # Convert m3 to L
      new_value=$(awk "BEGIN {printf \"%.1f\", $value*1000}")
      new_unit="L"
      ;;
    L)
      # Already L
      ;;
    C)
      # Celsius to Fahrenheit
      new_value=$(awk "BEGIN {printf \"%.1f\", $value*9/5+32}")
      new_unit="F"
      ;;
    F)
      # Fahrenheit to Celsius
      new_value=$(awk "BEGIN {printf \"%.1f\", ($value-32)*5/9}")
      new_unit="C"
      ;;
    Pa)
      # Pascal to hPa
      new_value=$(awk "BEGIN {printf \"%.2f\", $value/100}")
      new_unit="hPa"
      ;;
    hPa)
      # Already hPa
      ;;
    m)
      # Meters to Miles
      new_value=$(awk "BEGIN {printf \"%.6f\", $value/1609.344}")
      new_unit="miles"
      ;;
    miles)
      # Miles to Meters
      new_value=$(awk "BEGIN {printf \"%.2f\", $value*1609.344}")
      new_unit="m"
      ;;
    lbs)
      # Pounds to Kilograms
      new_value=$(awk "BEGIN {printf \"%.2f\", $value/2.20462}")
      new_unit="kg"
      ;;
    *)
      # No conversion
      ;;
  esac
  echo "$new_value;$new_unit"
}

#----- Convert state and unit_of_measurement
conversion_result=$(convert_unit "$state" "$unit_of_measurement")
converted_state=$(echo "$conversion_result" | cut -d';' -f1)
converted_unit=$(echo "$conversion_result" | cut -d';' -f2)

#----- Write one CSV object per line (converted)
cat <<EOF >> "$csv_file"
$timestamp;$area_id;$class_id;$entity_id;$converted_state;$converted_unit;$device_class;$secs_interval
EOF

exit 0
