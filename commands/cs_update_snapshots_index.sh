#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.2.0
#
# Updates the snapshots index file for the camera AI dashboard
#

#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

# Configuration
SNAPSHOTS_DIR="${hass_path}/www/snapshots"
INDEX_FILE="${hass_path}/www/snapshots/snapshots_index.json"
MAX_FILES_PER_CAMERA=100

log_info "Starting snapshots index update..."

# Check if snapshots directory exists
if [ ! -d "$SNAPSHOTS_DIR" ]; then
    log_error "Snapshots directory does not exist: $SNAPSHOTS_DIR"
    exit 1
fi

log_debug "Scanning directory: $SNAPSHOTS_DIR"
log_debug "Looking for .jpg and .png files..."

# Create temporary file for building the index
temp_file=$(mktemp)

# Start JSON structure
echo "{" > "$temp_file"
echo '  "last_updated": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'",' >> "$temp_file"
echo '  "cameras": {' >> "$temp_file"

# Get all image files and group by camera
declare -A camera_files
declare -A camera_metadata

# Find all .jpg and .png files in the snapshots directory
files_found=0
# Use a simpler approach that works better on HassOS
for file in "$SNAPSHOTS_DIR"/*.jpg "$SNAPSHOTS_DIR"/*.png; do
    # Skip if no files match the pattern
    [ -f "$file" ] || continue
    
    filename=$(basename "$file")
    files_found=$((files_found + 1))
    
    # Extract camera name from filename 
    # Simple format: part1-part2-part3-part4.jpg
    # Remove extension first
    base_filename="${filename%.*}"
    
    # Split on dashes
    IFS='-' read -ra parts <<< "$base_filename"
    
    # Check if we have exactly 4 parts
    if [ ${#parts[@]} -ne 4 ]; then
        continue
    fi
    
    camera_short="${parts[0]}"
    camera_area_id="${parts[1]}"
    detection_type="${parts[2]}"
    timestamp_part="${parts[3]}"
    
    # Use camera_short as the key to match camera_js format
    # This ensures alignment with the camera.short field from cs_cameras.sh
    camera_key="${camera_short}"
    
    # Store camera metadata (camera_short, area_id) for later use
    # Format: camera_short:area_id
    if [[ -z "${camera_metadata[$camera_key]:-}" ]]; then
        camera_metadata["$camera_key"]="$camera_short:$camera_area_id"
    fi
    
    # Get file modification time for sorting
    if command -v stat >/dev/null 2>&1; then
        file_time=$(stat -c %Y "$file" 2>/dev/null || echo "0")
    else
        file_time=$(date -r "$file" +%s 2>/dev/null || echo "0")
    fi
    
    # Store file data: timestamp:filename:detection_type (use a unique separator)
    file_info="$file_time:$filename:$detection_type"
    
    # Append to a string with a unique separator (e.g., newline)
    if [[ -z "${camera_files[$camera_key]:-}" ]]; then
        camera_files["$camera_key"]="$file_info"
    else
        camera_files["$camera_key"]+=$'\n'"$file_info"
    fi
done

log_debug "Processed $files_found files, found ${#camera_files[@]} cameras"

# Process each camera
camera_count=0
total_cameras=${#camera_files[@]}

# Handle case when no cameras are found
if [ "$total_cameras" -eq 0 ]; then
    log_info "No camera files found in snapshots directory"
    # Close JSON structure with empty cameras object
    echo '  },' >> "$temp_file"
    echo "  \"total_cameras\": 0" >> "$temp_file"
    echo '}' >> "$temp_file"
    
    # Move the temporary file to the final location atomically
    if mv "$temp_file" "$INDEX_FILE"; then
        log_info "Empty snapshots index created: $INDEX_FILE"
    else
        log_error "Failed to create empty snapshots index file"
        rm -f "$temp_file"
        exit 1
    fi
    exit 0
fi

for camera_name in "${!camera_files[@]}"; do
    camera_count=$((camera_count + 1))
    
    log_debug "Processing camera: $camera_name"
    
    # Extract camera metadata
    IFS=':' read -r meta_camera_short meta_area_id <<< "${camera_metadata[$camera_name]}"
    
    # Add camera entry to JSON with complete metadata
    echo "    \"$camera_name\": {" >> "$temp_file"
    echo "      \"short\": \"$meta_camera_short\"," >> "$temp_file"
    echo "      \"area_id\": \"$meta_area_id\"," >> "$temp_file"
    echo '      "files": [' >> "$temp_file"
    
    # Convert newline-separated list to array and sort
    mapfile -t sorted_files < <(printf '%s\n' "${camera_files[$camera_name]}" | sort -t: -k1,1nr)
    
    # Take only the newest MAX_FILES_PER_CAMERA files
    file_count=0
    for file_entry in "${sorted_files[@]}"; do
        if [ $file_count -ge $MAX_FILES_PER_CAMERA ]; then
            break
        fi
        
        # Extract components from timestamp:filename:detection_type format
        IFS=':' read -r file_timestamp filename file_detection_type <<< "$file_entry"
        
        # Skip empty entries
        if [ -z "$file_timestamp" ] || [ -z "$filename" ] || [ -z "$file_detection_type" ]; then
            continue
        fi
        
        # Add comma if not the first file
        if [ $file_count -gt 0 ]; then
            echo "," >> "$temp_file"
        fi
        
        # Add file entry to JSON with clean data
        echo -n "        {" >> "$temp_file"
        echo -n "\"name\": \"$filename\", " >> "$temp_file"
        echo -n "\"timestamp\": $file_timestamp, " >> "$temp_file"
        echo -n "\"detection_type\": \"$file_detection_type\"" >> "$temp_file"
        echo -n "}" >> "$temp_file"
        
        file_count=$((file_count + 1))
    done
    
    # Close files array and camera object
    echo "" >> "$temp_file"
    echo '      ],' >> "$temp_file"
    echo "      \"count\": $file_count" >> "$temp_file"
    
    # Add comma if not the last camera
    if [ $camera_count -lt $total_cameras ]; then
        echo "    }," >> "$temp_file"
    else
        echo "    }" >> "$temp_file"
    fi
    
    unset sorted_files
done

# Close JSON structure
echo '  },' >> "$temp_file"
echo "  \"total_cameras\": $total_cameras" >> "$temp_file"
echo '}' >> "$temp_file"

# Move the temporary file to the final location atomically
if mv "$temp_file" "$INDEX_FILE"; then
    log_info "Snapshots index updated successfully: $INDEX_FILE"
    log_info "Indexed $total_cameras cameras with up to $MAX_FILES_PER_CAMERA files each"
else
    log_error "Failed to update snapshots index file"
    rm -f "$temp_file"
    exit 1
fi
