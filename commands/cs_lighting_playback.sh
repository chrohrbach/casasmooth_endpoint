#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 0.1.5
#
# LIGHTING PLAYBACK SCRIPT
# ========================
# This script analyzes historical lighting events and simulates playback by finding
# entities that should change state within a specific time window.
#
# PURPOSE:
# - Reads CSV files containing lighting event logs
# - Selects a random historical day's lighting pattern if no recent playlist exists
# - Analyzes the selected day's lighting events within a time window
# - Returns entities that changed to the target state during that window
#
# INPUT PARAMETERS:
# 1. delay (seconds): Time window duration to look ahead from current time
# 2. target_state: The state to filter for (e.g., "on", "off")
#
# OUTPUT:
# Semicolon-separated list of unique entity names that changed to target_state
# within the time window
#
# WORKFLOW:
# 1. Check if today's playlist.csv exists and is current
# 2. If not, randomly select a historical lighting log file
# 3. Copy selected file to playlist.csv for consistent processing
# 4. Parse the playlist and find entities changing state in time window
# 5. Return unique entities for automation processing
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
  echo "Usage: $0 <delay> <state>" >&2
  echo "  delay: Number of seconds to look ahead from current time" >&2
  echo "  state: Target state to filter for (e.g., 'on', 'off')" >&2
  exit 1
fi

delay="$1"
target_state="$2"

# Validate that delay is a positive number
if ! echo "$delay" | grep -q '^[0-9]\+\(\.[0-9]\+\)\?$'; then
  echo "Error: Delay must be a positive number (seconds)." >&2
  exit 1
fi

# PLAYLIST MANAGEMENT
# ===================
# The playlist.csv file contains the lighting events for playback simulation.
# Each day we select a different random historical day from the past 15 days.
# We also clean up old log files outside the 15-day window.
# The playlist is stored in the cs_locals directory for HassOS compatibility.

playlist_file="${cs_locals}/playlist.csv"
current_date=$(date +%Y-%m-%d)
playback_timeframe_days=15

# Send status messages to stderr so they don't interfere with entity output
echo "LIGHTING PLAYBACK ANALYSIS - $current_date" >&2
echo "Debug: cs_locals='$cs_locals', playlist_file='$playlist_file'" >&2

# Function to check if playlist file exists and was created today
is_playlist_current()
{
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1  # File does not exist
  fi
  
  # Simple check: if file exists and is less than 24 hours old, consider it current
  # This is a simplified version that should work cross-platform
  local file_age=$(find "$file" -mtime -1 2>/dev/null | wc -l)
  if [ "$file_age" -gt 0 ]; then
    return 0  # File is recent (less than 1 day old)
  else
    return 1  # File is old or check failed
  fi
}

# Function to get date from filename (expects YYYY-MM-DD.csv format)
get_date_from_filename()
{
  local filename="$1"
  basename "$filename" .csv
}

# Function to calculate days between two dates
days_between()
{
  local date1="$1"
  local date2="$2"
  # Try GNU date first, fallback to simpler method for BusyBox/HassOS
  if command -v date >/dev/null 2>&1; then
    local timestamp1=$(date -d "$date1" +%s 2>/dev/null)
    local timestamp2=$(date -d "$date2" +%s 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$timestamp1" ] && [ -n "$timestamp2" ]; then
      echo $(( (timestamp1 - timestamp2) / 86400 ))
      return
    fi
  fi
  # Fallback: simple string comparison (works for YYYY-MM-DD format)
  if [ "$date1" = "$date2" ]; then
    echo 0
  elif [ "$date1" \> "$date2" ]; then
    echo 1  # Positive difference
  else
    echo -1  # Negative difference
  fi
}

# Function to clean up old log files outside the timeframe
cleanup_old_logs()
{
  local cleaned_count=0
  
  # Very conservative cleanup: only remove files that are clearly from previous years
  # This avoids any month arithmetic that could cause octal interpretation issues
  
  for file in "${cs_logs}/lighting/"*.csv; do
    if [ -f "$file" ]; then
      local file_date=$(get_date_from_filename "$file")
      
      # Only process files with valid date format
      if echo "$file_date" | grep -q '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$'; then
        local file_year=$(echo "$file_date" | cut -d'-' -f1)
        
        # Only delete files from previous years (ultra-conservative)
        if [ "$file_year" -lt 2025 ]; then
          rm "$file" 2>/dev/null
          cleaned_count=$((cleaned_count + 1))
        fi
      fi
    fi
  done
  
  # Only report if significant cleanup occurred (more than 10 files)
  if [ $cleaned_count -gt 10 ]; then
    echo "Cleaned up $cleaned_count old log files." >&2
  fi
}

# HISTORICAL DATA SELECTION
# ==========================
# Check if we need to create/update the playlist from historical data
if ! is_playlist_current "$playlist_file"; then
    # First, clean up old log files outside our timeframe
    cleanup_old_logs
    
    # Find all historical CSV files within the past 15 days (exclude today's incomplete data)
    valid_csv_files=""
    # Try to calculate cutoff date, fallback to simple method for HassOS
    cutoff_date=$(date -d "$current_date - $playback_timeframe_days days" +%Y-%m-%d 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$cutoff_date" ]; then
      # HassOS fallback: use current month files (simplified approach)
      current_month=$(date +%Y-%m)
      for file in "${cs_logs}/lighting/"*.csv; do
        if [ -f "$file" ]; then
          file_date=$(get_date_from_filename "$file")
          # Check if filename has valid date format and is from current month
          if echo "$file_date" | grep -q '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$'; then
            file_month=$(echo "$file_date" | cut -c1-7)  # Extract YYYY-MM
            if [ "$file_month" = "$current_month" ] && [ "$file_date" \< "$current_date" ]; then
              valid_csv_files="$valid_csv_files $file"
            fi
          fi
        fi
      done
    else
      # Full date arithmetic when available
      for file in "${cs_logs}/lighting/"*.csv; do
        if [ -f "$file" ]; then
          file_date=$(get_date_from_filename "$file")
          # Check if filename has valid date format and is within our timeframe
          if echo "$file_date" | grep -q '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$'; then
            # Use string comparison for dates (works since dates are in YYYY-MM-DD format)
            if [ "$file_date" \> "$cutoff_date" ] && [ "$file_date" \< "$current_date" ]; then
              valid_csv_files="$valid_csv_files $file"
            elif [ "$file_date" = "$cutoff_date" ]; then
              valid_csv_files="$valid_csv_files $file"
            fi
          fi
        fi
      done
    fi
    
    # Verify we have historical data available
    if [ -z "$valid_csv_files" ]; then
      echo "Warning: No historical lighting CSV files found in ${cs_logs}/lighting/" >&2
      echo "Debug: Looking for files matching pattern: ${cs_logs}/lighting/*.csv" >&2
      # Create empty playlist as fallback
      touch "$playlist_file"
      selected_date="$current_date"
    else
      # Convert space-separated string to array for random selection
      set -- $valid_csv_files
      file_count=$#
      
      # Randomly select one historical day's lighting pattern
      random_index=$((RANDOM % file_count + 1))
      eval selected_file=\$$random_index
      selected_date=$(get_date_from_filename "$selected_file")
      
      echo "Using historical pattern from: $selected_date" >&2
      
      # Copy the selected historical pattern to playlist.csv
      echo "Debug: Copying '$selected_file' to '$playlist_file'" >&2
      if cp "$selected_file" "$playlist_file" 2>/dev/null; then
        echo "Debug: Copy successful" >&2
      else
        echo "Error: Failed to copy historical data to playlist file" >&2
        echo "Debug: Source: $selected_file" >&2
        echo "Debug: Target: $playlist_file" >&2
        echo "Debug: Target directory exists: $(test -d "$(dirname "$playlist_file")" && echo "yes" || echo "no")" >&2
        exit 1
      fi
    fi
else
    # Get the date from the existing playlist
    if [ -f "$playlist_file" ] && [ -s "$playlist_file" ]; then
        # Read first line to extract the date
        first_line=$(head -n 1 "$playlist_file")
        # Use grep to check for date pattern instead of bash regex
        if echo "$first_line" | grep -q '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}'; then
            selected_date=$(echo "$first_line" | cut -d' ' -f1)
            echo "Using existing playlist from: $selected_date" >&2
        else
            selected_date="unknown"
            echo "Using existing playlist (date unknown)" >&2
        fi
    fi
fi

# PLAYLIST VALIDATION
# ===================
# Ensure the playlist file is ready for processing
if [ ! -f "$playlist_file" ]; then
  echo "Error: Playlist file not found after setup." >&2
  exit 1
fi

# Handle empty playlist gracefully (no historical data available)
if [ ! -s "$playlist_file" ]; then
  echo "Warning: Playlist file is empty (no historical data)" >&2
  echo ""  # Return empty result
  exit 0
fi

# Use the selected date for analysis instead of current date
date_to_analyze="$selected_date"

# TIME PROCESSING FUNCTIONS
# ==========================
# Initialize string to store entities that should change state (space-separated)
unique_entities=""

# Convert time string (HH:MM:SS) to seconds since midnight for comparison
time_to_seconds()
{
  local time_str="$1"
  local hours=$(echo "$time_str" | cut -d':' -f1)
  local minutes=$(echo "$time_str" | cut -d':' -f2)
  local seconds=$(echo "$time_str" | cut -d':' -f3)
  
  # Remove leading zeros to avoid octal interpretation
  hours=$(echo "$hours" | sed 's/^0*//')
  minutes=$(echo "$minutes" | sed 's/^0*//')
  seconds=$(echo "$seconds" | sed 's/^0*//')
  
  # Handle empty values (when all digits were zeros)
  hours=${hours:-0}
  minutes=${minutes:-0}
  seconds=${seconds:-0}
  
  echo $(( hours * 3600 + minutes * 60 + seconds ))
}

# TIME WINDOW CALCULATION
# ========================
# Define the time window: from now to (now + delay + 3 second buffer)
current_time=$(date +"%H:%M:%S")
time_window_start=$(time_to_seconds "$current_time")
time_window_end=$(( time_window_start + delay + 3 ))

# UTILITY FUNCTIONS
# ==================
# Check if an entity is already in our results string (avoid duplicates)
contains()
{
  local value="$1"
  case " $unique_entities " in
    *" $value "*) return 0 ;;  # Found
    *) return 1 ;;             # Not found
  esac
}

# MAIN PROCESSING LOOP
# ====================
# Process each line in the playlist CSV file
processed_events=0

while IFS=';' read -r timestamp location entity state; do
    # Remove Windows line endings (carriage returns) from all fields
    timestamp=$(echo "$timestamp" | tr -d '\r')
    location=$(echo "$location" | tr -d '\r')
    entity=$(echo "$entity" | tr -d '\r')
    state=$(echo "$state" | tr -d '\r')
    
    # Extract date from timestamp and verify it matches our analysis date
    log_date=$(echo "$timestamp" | cut -d' ' -f1)
    
    if [ "$log_date" == "$date_to_analyze" ]; then
        # Only process events that match our target state
        if [ "$state" == "$target_state" ]; then
            # Extract time portion and convert to seconds
            log_time=$(echo "$timestamp" | cut -d' ' -f2)
            log_seconds=$(time_to_seconds "$log_time")
            
            # Check if this event falls within our time window
            if [ "$log_seconds" -ge "$time_window_start" ]; then
                if [ "$log_seconds" -lt "$time_window_end" ]; then
                    # Event is in our time window - add entity if not already present
                    if ! contains "$entity"; then
                        unique_entities="$unique_entities $entity"
                    fi
                    processed_events=$((processed_events + 1))
                else
                    # We've passed the time window, no need to continue
                    break
                fi
            fi
        fi
    fi
done < "$playlist_file"

# OUTPUT RESULTS
# ===============
# Return the list of entities that should change state
if [ -z "$unique_entities" ]; then
    echo ""  # Return empty string for Home Assistant
else
    # Remove leading/trailing spaces and convert to semicolon-separated format
    trimmed_entities=$(echo "$unique_entities" | sed 's/^ *//; s/ *$//')
    echo "$trimmed_entities" | tr ' ' ';'
fi