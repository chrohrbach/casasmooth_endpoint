#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 2.2.4
#
# Efficient direct backup using BusyBox tar, no staging, backup from /config.
# The backup tarball is named <guid>_<timestamp>.tar.gz, but always sent to the cloud as <guid>.tar.gz.
# This script includes all of /config except excluded folders (see tar excludes).

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

if [[ -z "$cs_path" ]]; then
    log "cs_path is empty. Skipping local backup steps entirely."
    log "Backup terminated at $(date +"%d.%m.%Y %H:%M:%S")"
    exit 0
fi

endpoint_url="$(extract_secret "file_backup_endpoint")"
backup_folder="${cs_path}/backup"
mkdir -p "${backup_folder}"
current_date_time=$(date +"%Y%m%d_%H%M%S")
tar_filename="${guid}_${current_date_time}.tar.gz"
tar_filepath="${backup_folder}/${tar_filename}"
cloud_filename="${guid}.tar.gz"

#----- Cleanup old backups
log "Cleaning up old backups in ${backup_folder}..."
ls -tp "${backup_folder}"/*.tar.gz 2>/dev/null | grep -v '/$' | tail -n +4 | xargs -r rm --
find "${backup_folder}" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +

#----- Manage function (for uploading)
manage() {
    if [[ -z "$endpoint_url" || -z "$guid" ]]; then
        log "Skipping upload — endpoint or guid not set."
        return
    fi

    for file_path in "$@"; do
        if [[ ! -f "$file_path" ]]; then
            log "File not found: $file_path"
            continue
        fi

        # --- Skip large .log files ---
        if [[ "${file_path##*.}" == "log" ]]; then
            file_size=$(stat -c%s "$file_path" 2>/dev/null || echo 0)
            if [[ $file_size -gt $((20 * 1024 * 1024)) ]]; then
                log "Skipping large log file (over 20MB): $file_path"
                continue
            fi
        fi

        file_content=$(base64 "$file_path" | tr -d '\n') || {
            log "Failed to encode file: $file_path"
            continue
        }
        if [[ "$file_path" == "$tar_filepath" ]]; then
            file_name="$cloud_filename"
        else
            file_name=$(basename "$file_path")
        fi

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

#----- Backup isolated files to cloud
log "Backup inventory files"
manage "${cs_logs}/cs_inventory.csv"
manage "${cs_logs}/cs_inventory.txt"
manage "${cs_locals}/cs_registry_data.sh"
manage "${cs_locals}/cs_states.sh"
manage "${cs_cache}/cs_services.txt"
manage "${cs_logs}/cs_update_casasmooth.log"
manage "${cs_logs}/cs_update_client.log"
manage "${cs_path}/cs_update.log"

#----- Backup all files except excluded patterns
log "Creating tar archive ${tar_filepath}..."

cd /homeassistant

tar czf "${tar_filepath}" \
    --exclude='casasmooth/.git' \
    --exclude='casasmooth/.github' \
    --exclude='casasmooth/.gitattributes' \
    --exclude='casasmooth/.gitignore' \
    --exclude='casasmooth/.vscode' \
    --exclude='casasmooth/backup' \
    --exclude='casasmooth/docs' \
    --exclude='casasmooth/resources' \
    --exclude='casasmooth/custom_components' \
    --exclude='casasmooth/logs/sensors' \
    --exclude='casasmooth/logs/lighting' \
    --exclude='casasmooth/locals/back' \
    --exclude='casasmooth/locals/last' \
    --exclude='casasmooth/temp' \
    --exclude='casasmooth/images' \
    --exclude='casasmooth/notebooks/sensors' \
    --exclude='casasmooth/medias' \
    --exclude='home-assistant_v2.*' \
    --exclude='home-assistant.log.*' \
    --exclude='.Trash*' \
    --exclude='backup.db*' \
    --exclude='frigate.db*' \
    --exclude='blueprints' \
    --exclude='custom_components' \
    --exclude='deps' \
    --exclude='image' \
    --exclude='model_cache' \
    --exclude='notebooks' \
    --exclude='pyscript' \
    --exclude='python_scripts' \
    --exclude='themes' \
    --exclude='tts' \
    --exclude='www' \
    .

#----- Upload Tar Archive to Cloud (if enhanced)
z=$(< "${cs_cache}/cs_services.txt")
zz=$(echo -n "$z" | base64 -d)

if [[ "$zz" == *"enhanced_base"* ]]; then
    if [[ -f "${tar_filepath}" ]]; then
        manage "${tar_filepath}"
    else
        log "No tar file found at ${tar_filepath}, skipping final upload."
    fi
fi

log "Backup terminated at $(date +"%d.%m.%Y %H:%M:%S")"

exit 0