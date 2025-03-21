#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 0.1.3
#
# This script reads a CSV file containing lighting events and returns a list 
# of unique entities that have changed state within a specified time window.
# The script is intended to be used in a sensor.
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

# Check if the correct number of arguments is provided
if [ $# -ne 2 ]; then
  echo "Usage: $0 <delay> <state>"
  exit 1
fi

delay="$1"
target_state="$2"

# Check if delay is a number
if ! [[ "$delay" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Error: Delay must be a number."
  exit 1
fi

# Search for a file called ${cs_logs}/lighting/playlist.csv if it is not present or older than todays date 
# as date_to_analyze, list all csv files an pick randomly one of them, copy the selected to ${cs_logs}/lighting/playlist.csv
# and use it as the file to analyze.

playlist_file="${cs_logs}/lighting/playlist.csv"
date_to_analyze=$(date +%Y-%m-%d)

# Function to check if a file exists and is newer than today
is_file_recent() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1  # File does not exist
  fi
  local file_date=$(stat -c %y "$file" | cut -d' ' -f1)
  if [[ "$file_date" != "$date_to_analyze" ]]; then
    return 1  # File is not from today
  fi
  return 0  # File exists and is from today
}

# Check if playlist.csv exists and is recent
if ! is_file_recent "$playlist_file"; then
    # Find all CSV files in the directory excluding todays !
    csv_files=($(find "${cs_logs}/lighting/" -name "*.csv" ! -name "${date_to_analyze}.csv"))    
    # Check if any CSV files were found
    if [ ${#csv_files[@]} -eq 0 ]; then
      echo "Error: No CSV files found in ${cs_logs}/lighting/"
      exit 1
    fi
    # Pick a random CSV file
    random_index=$((RANDOM % ${#csv_files[@]}))
    selected_file="${csv_files[$random_index]}"
    # Copy the selected file to playlist.csv
    cp "$selected_file" "$playlist_file"
fi

# Check if the file exists
if [ ! -f "$playlist_file" ]; then
  echo "Error: File '$playlist_file' not found."
  exit 1
fi

# Check if the file is empty
if [ ! -s "$playlist_file" ]; then
  echo "Error: File '$playlist_file' is empty."
  exit 1
fi

# Initialize an empty array to store unique entities
declare -a unique_entities
unique_entities=()  # Initialize the array

# Function to convert time string to seconds since midnight
time_to_seconds() {
  local time_str="$1"
  local hours=$(echo "$time_str" | cut -d':' -f1)
  local minutes=$(echo "$time_str" | cut -d':' -f2)
  local seconds=$(echo "$time_str" | cut -d':' -f3)
  echo $(echo "scale=0; ($hours * 3600) + ($minutes * 60) + $seconds" | bc)
}

# Initialize time window
time_window_start=$(time_to_seconds "$(date +"%H:%M:%S")")
time_window_end=$(echo "$time_window_start + $delay + 3" | bc)

# Function to check if an array contains a value
contains() {
  local value="$1"
  for element in "${unique_entities[@]}"; do
    if [ "$element" == "$value" ]; then
      return 0  # Found
    fi
  done
  return 1  # Not found
}

# Read the file line by line
while IFS=';' read -r timestamp location entity state; do
    log_date=$(echo "$timestamp" | cut -d' ' -f1)
    if [ "$log_date" == "$date_to_analyze" ]; then
        if [ "$state" == "$target_state" ]; then
            log_time=$(echo "$timestamp" | cut -d' ' -f2)
            log_seconds=$(time_to_seconds "$log_time")
            if [ "$log_seconds" -ge "$time_window_start" ]; then
                if [ "$log_seconds" -lt "$time_window_end" ]; then
                    if ! contains "$entity"; then
                        unique_entities+=("$entity")
                    fi
                else
                    # We've passed the delay, so stop processing
                    break
                fi
            fi
        fi
    fi
done < "$playlist_file"

# Print the unique entities separated by semicolons
echo "${unique_entities[*]}" | tr ' ' ';'