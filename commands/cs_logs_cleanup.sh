#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 0.1.4
#
# Cleanup logs
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

verbose=true

# Cleaning function
clean_directory() {
  local dir="$1"
  local files_to_keep="$2"

  # Check if the directory exists
  if [ ! -d "$dir" ]; then
    log_error "Directory $dir does not exist."
    return 1
  fi

  # Change to the directory
  cd "$dir" || return 1

  # List all files sorted by modification time (newest first), excluding directories
  local all_files
  all_files=$(ls -tp | grep -v '/$')

  # Count the total number of files
  local total_files
  total_files=$(echo "$all_files" | wc -l)

  # Calculate the number of files to delete
  local files_to_delete_count=$((total_files - files_to_keep))

  # Check if there are more files than the limit
  if [ "$files_to_delete_count" -le 0 ]; then
    log "INFO" "No files to delete in $dir. Total files ($total_files) are within the limit ($files_to_keep)."
    return 0
  fi

  # Get the list of files to delete (skip the newest files_to_keep files)
  local files_to_delete
  files_to_delete=$(echo "$all_files" | tail -n "$files_to_delete_count")

  # Delete the older files
  log "INFO" "Deleting the following files in $dir:"
  echo "$files_to_delete" | tee -a "$log_file"
  echo "$files_to_delete" | xargs rm --

  log "INFO" "Cleanup complete in $dir. Kept the newest $files_to_keep files."

  # Return to the original directory
  cd - > /dev/null
}

# Delete lock files to make sure that at least all 24h they get deleted
rm -f "${cs_path}/*.lock"
rm -f "${cs_logs}/*.lock"

# Call the cleaning function
clean_directory "${cs_logs}/logs/lighting" 10
clean_directory "${cs_logs}/logs/sensors" 200
clean_directory "${cs_logs}/logs/states" 20
clean_directory "${hass_path}/www/snapshots" 50
