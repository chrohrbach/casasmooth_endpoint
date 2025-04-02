#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 1.2.7
#
# Optimized Backup using Find & CP instead of Rsync, with Cloud Upload
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

verbose=true
logger=true

log "IMPORTANT: Backup will only work if a correct plan is enabled for this GUID. Backend will reject the file otherwise."

# If cs_path is not available, skip local backup logic
if [[ -z "$cs_path" ]]; then
    log "cs_path is empty. Skipping local backup steps entirely."
    log "Backup terminated at $(date +"%d.%m.%Y %H:%M:%S")"
    exit 0
fi

endpoint_url="$(extract_secret "file_backup_endpoint")"
current_date_time=$(date +"%Y%m%d_%H%M%S")
backup_folder="${cs_path}/backup"
backup_dir="${backup_folder}/${current_date_time}"

#----- Cleanup old backups (keep last 3)
log "Cleaning up old backups in ${backup_folder}..."
find "${backup_folder}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -nr | awk 'NR>3 {print $1}' | xargs -I {} rm -rf {} 2>/dev/null || true

# Create backup directories
mkdir -p "${backup_dir}" || log "Cannot create backup dir: ${backup_dir}"
mkdir -p "${backup_dir}/config" || log "Cannot create backup dir: ${backup_dir}/config"
mkdir -p "${backup_dir}/config/casasmooth" || log "Cannot create backup dir: ${backup_dir}/config/casasmooth"
mkdir -p "${backup_dir}/config/.storage" || log "Cannot create backup dir: ${backup_dir}/config/.storage"

log "Backup dir set to ${backup_dir}"

#----- Manage function (for uploading)
manage() {
    # If no endpoint or no guid, skip upload
    if [[ -z "$endpoint_url" || -z "$guid" ]]; then
        log "Skipping upload — endpoint or guid not set."
        return
    fi

    for file_path in "$@"; do
        if [[ ! -f "$file_path" ]]; then
            log "File not found: $file_path"
            continue
        fi

        # --- NEW CHECK FOR LARGE .log FILES ---
        if [[ "${file_path##*.}" == "log" ]]; then
            # If file bigger than 20MB, skip
            file_size=$(stat -c%s "$file_path" 2>/dev/null || echo 0)
            if [[ $file_size -gt $((20 * 1024 * 1024)) ]]; then
                log "Skipping large log file (over 20MB): $file_path"
                continue
            fi
        fi
        # ---------------------------------------

        file_content=$(base64 "$file_path" | tr -d '\n') || {
            log "Failed to encode file: $file_path"
            continue
        }
        file_name=$(basename "$file_path")

        json_payload=$(printf '{
            "guid": "%s",
            "file_name": "%s",
            "file_content": "%s"
        }' "$guid" "$file_name" "$file_content")

        log "Sending $file_name to account $guid"

        temp_file=$(mktemp) || {
            log "Failed to create temporary file"
            continue
        }

        echo "$json_payload" > "$temp_file"

        # Attempt upload
        response=$(curl --silent --write-out "%{http_code}" \
            --header "Content-Type: application/json" \
            --data @"$temp_file" \
            "$endpoint_url")

        http_code=$(echo "$response" | tail -n1)

        if [[ "$http_code" -ne 202 ]]; then
            log "Failed to upload $file_name. HTTP status code: $http_code"
        fi

        rm -f "$temp_file"
    done
}

# Copy all files **excluding** backup, temp, and logs folders
log "Copying all casasmooth relevant files"
find "${cs_path}/" -type d \( \
    -name ".*" -o \
    -path "${cs_path}/.git" -o \
    -path "${cs_path}/.gitattributes" -o \
    -path "${cs_path}/.gitignore" -o \
    -path "${cs_path}/.vscode" -o \
    -path "${cs_path}/backup" -o \
    -path "${cs_path}/resources" -o \
    -path "${cs_path}/temp" -o \
    -path "${cs_path}/logs" -o \
    -path "${cs_path}/images" -o \
    -path "${cs_path}/medias" \
    \) -prune -o -type f \
    -exec cp --parents {} "${backup_dir}" \; \
    || log "Failed to copy files from ${cs_path} to ${backup_dir}"
    
#----- Copy YAML files from `$hass_path`
log "Copying hass relevant files"
find "${hass_path}/" -maxdepth 1 -type f \( -name "*.yaml" \) \
    -exec cp --parents {} "${backup_dir}" \; \
    || log "Failed to copy HASS YAML files"

#----- Copy Zigbee db from "$hass_path' separately
log "Copying zigbee db"
find "${hass_path}/" -maxdepth 1 -type f \( -name "zigbee.db*" \) \
    -exec cp --parents {} "${backup_dir}" \; \
    || log "Failed to copy Zigbee registry files"

#----- Copy Log files from `$hass_path`
log "Copying hass relevant files"
find "${hass_path}/" -maxdepth 1 -type f \( -name "*.log" \) \
    -exec cp --parents {} "${backup_dir}" \; \
    || log "Failed to copy HASS log files"

#----- Copy Home Assistant `.storage` files
log "Copying hass registries"
#find "${hass_path}/.storage/" -type f \( -name "core.*" -o -name "person" -o -name "auth" -o -name "frontend*" -o -name "lovelace*"  -o -name "energy*" \) \
find "${hass_path}/.storage/" -type f -name "*" \
    -exec cp --parents {} "${backup_dir}" \; \
    || log "Failed to copy HASS .storage files"

#----- Backup isolated files
log "Backup inventory files"
manage "${cs_logs}/cs_inventory.csv"
manage "${cs_logs}/cs_inventory.txt"
manage "${cs_locals}/cs_registry_data.sh"
manage "${cs_locals}/cs_states.sh"
manage "${cs_cache}/cs_services.txt"
manage "${cs_logs}/cs_update_casasmooth.log"
manage "${cs_logs}/cs_update_client.log"
manage "${cs_path}/cs_update.log"

#----- Create Tar Archive of Synced Files
tar_filename="${guid}.tar.gz"
log "Creating tar archive ${backup_dir}/${tar_filename}..."
tar -czf "${backup_dir}/${tar_filename}" -C "${backup_dir}/config/" . || log "Failed to create tar file"

z=$(< "${cs_cache}/cs_services.txt")
zz=$(echo -n "$z" | base64 -d)

#----- Upload Tar Archive to Cloud
if [[ "$zz" == *"enhanced_base"* ]]; then
    if [[ -f "${backup_dir}/${tar_filename}" ]]; then
        log "Backup completed: ${tar_filename}, send to cloud"
        manage "${backup_dir}/${tar_filename}"
    else
        log "No tar file found at ${backup_dir}/${tar_filename}, skipping final upload."
    fi
fi

#----- Check the regular backup ($$$$ /backup is not accessible from a sub process this does not work $$$$)

if [[ "$zz" == *"enhanced_base"* ]]; then

    backup_dir="/backup"

    # Check if the directory exists
    if [ ! -d "$backup_dir" ]; then

        log "Directory '$backup_dir' does not exist."

    else

        recent_files_array=()
        #mapfile -t recent_files_array < <(ls -t "$backup_dir/${guid}"* | head -n 1)
        mapfile -t recent_files_array < <(ls -t "$backup_dir/????????.tar" | head -n 1)
        
        # Check for empty array (no files found)
        if [ ${#recent_files_array[@]} -eq 0 ]; then
            log "No matching files found in '$backup_dir'."
            exit 0
        fi

        # Loop through the array and echo each file name
        for file in "${recent_files_array[@]}"; do
            filename=$(basename "$file")
            log "Upload ${file} as ${guid}-${filename}"
            BLOB_SERVICE=$(extract_secret "BLOB_SERVICE")
            BACKUP_SAS_TOKEN=$(extract_secret "BACKUP_SAS_TOKEN")
            response=$(curl -s -w "\n%{http_code}" -X PUT -H "x-ms-blob-type: BlockBlob" --data-binary @"${file}" "${BLOB_SERVICE}/backup/${guid}-${filename}?${BACKUP_SAS_TOKEN}")
            http_code=$(echo "$response" | tail -n1)
            response_body=$(echo "$response" | sed '$d')
            if [ "$http_code" -ne "201" ]; then
                log_error "Failed to upload ${file}. HTTP status code: ${http_code}"
                log_error "Response: ${response_body}"
            fi
        done

    fi
    
else

    log "Service not subscribed"

fi

log "Backup terminated at $(date +"%d.%m.%Y %H:%M:%S")"

exit 0
