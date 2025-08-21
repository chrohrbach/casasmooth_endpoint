#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.2.1
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

# Cleaning function (recursive) - keeps files_to_keep per folder, not total
clean_directory_recursive() {
  local dir="$1"
  local files_to_keep="$2"

  # Check if the directory exists
  if [ ! -d "$dir" ]; then
    log_error "Directory $dir does not exist."
    return 1
  fi

  log_info "Starting recursive cleanup of directory: $dir (keeping $files_to_keep newest files PER FOLDER)"

  # Process the base directory itself first
  clean_single_directory "$dir" "$files_to_keep"

  # Find all subdirectories and process each one recursively
  local subdirs
  subdirs=$(find "$dir" -type d -not -path "$dir" 2>/dev/null)
  
  if [ -n "$subdirs" ]; then
    local subdir_count
    subdir_count=$(echo "$subdirs" | wc -l)
    log_info "Found $subdir_count subdirectories to process recursively in $dir"
    
    local current_subdir=0
    while IFS= read -r subdir; do
      if [ -n "$subdir" ]; then
        current_subdir=$((current_subdir + 1))
        log_info "Processing subdirectory $current_subdir/$subdir_count: $subdir"
        clean_single_directory "$subdir" "$files_to_keep"
      fi
    done <<< "$subdirs"
  else
    log_info "No subdirectories found in $dir"
  fi
}

# Cleaning function (per folder)
clean_directory_per_folder() {
  local base_dir="$1"
  local files_to_keep="$2"

  # Check if the directory exists
  if [ ! -d "$base_dir" ]; then
    log_error "Directory $base_dir does not exist."
    return 1
  fi

  log_info "Starting per-folder cleanup of directory: $base_dir (keeping $files_to_keep newest files per folder)"

  # Process the base directory itself first
  clean_single_directory "$base_dir" "$files_to_keep"

  # Find all subdirectories and process each one
  local subdirs
  subdirs=$(find "$base_dir" -type d -not -path "$base_dir" 2>/dev/null)
  
  if [ -n "$subdirs" ]; then
    local subdir_count
    subdir_count=$(echo "$subdirs" | wc -l)
    log_info "Found $subdir_count subdirectories to process in $base_dir"
    
    local current_subdir=0
    while IFS= read -r subdir; do
      if [ -n "$subdir" ]; then
        current_subdir=$((current_subdir + 1))
        log_info "Processing subdirectory $current_subdir/$subdir_count: $subdir"
        clean_single_directory "$subdir" "$files_to_keep"
      fi
    done <<< "$subdirs"
  else
    log_info "No subdirectories found in $base_dir"
  fi
}

# Helper function to clean a single directory (non-recursive)
clean_single_directory() {
  local dir="$1"
  local files_to_keep="$2"

  # Find files only in this specific directory (not subdirectories)
  local all_files
  if command -v stat >/dev/null 2>&1; then
    # Use stat if available (more portable)
    all_files=$(find "$dir" -maxdepth 1 -type f -exec stat -c '%Y %n' {} \; 2>/dev/null | sort -nr | cut -d' ' -f2-)
  else
    # Fallback to ls -t (less reliable for large datasets but more portable)
    all_files=$(find "$dir" -maxdepth 1 -type f -exec ls -t {} + 2>/dev/null)
  fi

  # Count the total number of files (handle empty directory case)
  local total_files
  if [ -z "$all_files" ]; then
    total_files=0
  else
    total_files=$(echo "$all_files" | wc -l)
  fi

  log_info "📁 Found $total_files files in $dir (single directory scan)"

  # Calculate the number of files to delete
  local files_to_delete_count=$((total_files - files_to_keep))

  # Check if there are more files than the limit
  if [ "$files_to_delete_count" -le 0 ]; then
    log_info "✓ No cleanup needed in $dir - total files ($total_files) within limit ($files_to_keep)"
    return 0
  fi

  log_info "Will delete $files_to_delete_count files from $dir (keeping $files_to_keep newest)"

  # Get the list of files to delete (skip the newest files_to_keep files)
  local files_to_delete
  files_to_delete=$(echo "$all_files" | tail -n "$files_to_delete_count")

  # Delete the older files with progress tracking
  log_info "🗑️  Starting deletion of $files_to_delete_count files in $dir..."
  
  # Always use the most reliable method to ensure exact file count compliance
  if [ "$files_to_delete_count" -gt 25 ]; then
    # For larger deletions, use chunked approach but maintain exact count
    local temp_file="/tmp/cleanup_single_batch_$$"
    echo "$files_to_delete" > "$temp_file"
    
    # Split into chunks for progress reporting
    local chunk_size=25
    local total_chunks=$(( (files_to_delete_count + chunk_size - 1) / chunk_size ))
    local current_chunk=0
    
    while [ $((current_chunk * chunk_size)) -lt "$files_to_delete_count" ]; do
      current_chunk=$((current_chunk + 1))
      local start_line=$(( (current_chunk - 1) * chunk_size + 1 ))
      local end_line=$((current_chunk * chunk_size))
      
      # Extract chunk and delete files
      if sed -n "${start_line},${end_line}p" "$temp_file" | xargs -r rm -f 2>/dev/null; then
        local files_deleted_so_far=$((current_chunk * chunk_size))
        if [ "$files_deleted_so_far" -gt "$files_to_delete_count" ]; then
          files_deleted_so_far="$files_to_delete_count"
        fi
        log_info "📊 Progress: $files_deleted_so_far/$files_to_delete_count files deleted"
      else
        log_error "❌ Failed to delete chunk $current_chunk"
        rm -f "$temp_file" 2>/dev/null
        return 1
      fi
    done
    
    rm -f "$temp_file" 2>/dev/null
    log_info "✅ Cleanup complete in $dir (per folder) - deleted exactly $files_to_delete_count files, kept exactly $files_to_keep newest"
  else
    # For smaller deletions, use direct batch method for speed and accuracy
    if echo "$files_to_delete" | xargs -r rm -f 2>/dev/null; then
      log_info "✅ Cleanup complete in $dir (per folder) - deleted exactly $files_to_delete_count files, kept exactly $files_to_keep newest"
    else
      log_error "❌ Failed to delete some files in $dir (per folder)"
      return 1
    fi
  fi
}

# Delete lock files to make sure that at least all 24h they get deleted
find "${cs_path}" -name "*.lock" -type f -delete 2>/dev/null || true
find "${cs_logs}" -name "*.lock" -type f -delete 2>/dev/null || true

# Log cleanup start
log_info "Starting log cleanup process..."

# Call the cleaning functions - they will handle directory validation internally
clean_directory_recursive "${cs_logs}/lighting" 20
clean_directory_recursive "${cs_logs}/sensors" 50  
clean_directory_recursive "${cs_logs}/states" 20
clean_directory_per_folder "${hass_path}/www/snapshots" 250

log_info "Log cleanup process completed."
