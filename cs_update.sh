#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 0.2.8.4
#
# Launches local or remote update of casasmooth
#
#=================================== Update the repository to make sure that we run the last version

    cd "/config/casasmooth" >/dev/null 2>&1
    git fetch origin main && git reset --hard origin/main 2>&1
    chmod +x commands/*.sh >/dev/null 2>&1

#=================================== Include cs_library

    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi

#=================================== Concurrency management

    cs_update_lock_file="${cs_path}/cs_update.lock"

    # Function to remove the lock file
    remove_cs_update_lock_file() {
        if [ -f "$cs_update_lock_file" ]; then
            log "Removing lock file ${cs_update_lock_file}"
            rm -f "$cs_update_lock_file"
        fi
        # Optionally, close the file descriptor if it's still open (though it should be closed when the script exits)
        exec 9>&-
    }

    # Trap signals to ensure lock file removal on exit (including errors and signals like SIGINT, SIGTERM)
    trap remove_cs_update_lock_file EXIT SIGINT SIGTERM SIGQUIT ERR

    # Create a file descriptor for flock
    exec 9>"$cs_update_lock_file"
    # Attempt to acquire an exclusive lock using flock
    if ! flock -n 9; then # -n: non-blocking, returns immediately if lock cannot be acquired
        echo "Script is already running (lock is held on $cs_update_lock_file). Exiting."
        exit 1
    fi

#----- Check options
    usage() {
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --remoting       Enable remote processing"
        echo "  --nocloud        Disable remoting in the cloud, used to debug in a local container"
    }

    forward_args=() # Initialize an empty array to store arguments to forward

    verbose=true
    log=true

    production=true

    cloud=true
    remoting=false

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --log)
                log=true
                forward_args+=("$1") 
                shift
                ;;
            --verbose)
                verbose=true
                forward_args+=("$1") 
                shift
                ;;
            --debug)
                debug=true
                forward_args+=("$1") 
                shift
                ;;
            --remoting)
                remoting=true
                shift
                ;;
            --nocloud)
                cloud=false
                shift
                ;;
            *) # Positional argument or unknown option without leading '-'
                forward_args+=("$1") # Add positional/unknown argument to forward_args
                shift
                ;;
        esac
    done

    # Now "$@" contains only the positional arguments/files

#----- Check execution mode

    #----- Initial test to determine if we need a remote update or not. 

    remote_update=$remoting
    if [[ ! -f "${cs_lib}/cs_update_casasmooth.sh" ]]; then
        # No local cs_update_casasmooth found !!!
        remote_update=true
    fi

    ha_present=false
    if command -v ha >/dev/null 2>&1; then
        ha_present=true
    fi

#----- Update process

    if [[ "$remote_update" == "false" ]]; then

        #----- We are on a system running HASS, we do a local update

        if [[ "$(lib_update_required)" == "false" ]]; then
            log "casasmooth local update is not required."
            exit 0
        else
            log "Update casasmooth locally starting as a detached process..."
            timeout "30m" setsid bash "${cs_lib}/cs_update_casasmooth.sh" "${forward_args[@]}" --log --verbose > /dev/null 2>&1 &
        fi
    
    else

        #----- Setup the environment to be able to execute all remoting interactions with Azure

            LOCATION=$(extract_secret "LOCATION")
            ACR_SERVER=$(extract_secret "ACR_SERVER")
            ACR_USERNAME=$(extract_secret "ACR_USERNAME")
            ACR_PASSWORD=$(extract_secret "ACR_PASSWORD")
            IMAGE=$(extract_secret "IMAGE")
            MGMT_URL=$(extract_secret "MGMT_URL")
            AZURE_RESOURCE_GROUP=$(extract_secret "AZURE_RESOURCE_GROUP")
            AZURE_SUBSCRIPTION_ID=$(extract_secret "AZURE_SUBSCRIPTION_ID")
            BLOB_SERVICE=$(extract_secret "BLOB_SERVICE")
            CONTAINER_NAME=$(extract_secret "CONTAINER_NAME")
            STORAGE_SAS_TOKEN=$(extract_secret "STORAGE_SAS_TOKEN")
            CLIENT_ID=$(extract_secret "CLIENT_ID")
            CLIENT_SECRET=$(extract_secret "CLIENT_SECRET")
            TENANT_ID=$(extract_secret "TENANT_ID")
            OAUTH_ENDPOINT=$(extract_secret "OAUTH_ENDPOINT")
            RESOURCE=$(extract_secret "RESOURCE")   

        #----- Check to see if this system is running on HASS

        if [[ "$ha_present" == "true" ]]; then

            #----- We are on a system running HASS

                if [[ "$(lib_update_required)" == "false" ]]; then
                    log "casasmooth remote update is not required."
                    exit 0
                else
                    log "Update casasmooth remote starting as a detached process..."
                    timeout "30m" setsid bash "${cs_lib}/cs_update_client.sh" "${forward_args[@]}" --log --verbose > /dev/null 2>&1 &
                fi

        else

            #----- We are on a system without HASS, probably a VM, a container, or a terminal, this means that we dont have timeout problems induced by hass

                if [[ -z "${guid_to_process:-}" ]]; then
                    log "guid_to_process is required for remoting, exiting..."
                    exit 1
                fi

                guid="${guid_to_process}"

                data_file="dta_${guid}.tar.gz"
                result_file="res_${guid}.tar.gz"

                log "Starting the update process"
            
            #----- We are in an empty container, we need to process the data file that was uploaded for us but is it ready?

                log "Starting to poll for data..."

                found=false
                timeout_seconds=600
                poll_interval=5
                elapsed=0
                while [ "$elapsed" -lt "$timeout_seconds" ]; do
                    # Attempt to download the file and capture the HTTP status code
                    http_code=$(curl --silent --show-error --output "${cs_temp}/${data_file}" --write-out "%{http_code}" "${BLOB_SERVICE}/update/${data_file}?${STORAGE_SAS_TOKEN}")
                    if [ "$http_code" = "200" ]; then
                        found=true
                        log "We got the data file update/${data_file}, we can go on with the processing..."
                        break
                    elif [ "$http_code" = "404" ]; then
                        log_debug "File 'update/${data_file}' not yet available. Waiting for ${poll_interval} seconds..."
                    else
                        log_debug "Request for 'update/${data_file}' failed with HTTP code ${http_code}. Waiting for ${poll_interval} seconds..."
                    fi
                    sleep "$poll_interval"
                    elapsed=$((elapsed + poll_interval))
                done
                if [ "$elapsed" -ge "$timeout_seconds" ]; then
                    log "Polling timeout reached after $timeout_seconds seconds. We did not see the ${data_file}. Exiting the process."
                    exit 1
                fi
                if [[ "$found" != "true" ]]; then
                    log "Wait finished but file ${data_file} not present. Exiting the process."
                    exit 1
                fi

            #----- Extract the data tar file

                log "Extracting the data file..."
                tar -xzf "${cs_temp}/${data_file}" -C / > /dev/null 2>&1
                rm -f "${cs_temp}/${data_file}"

            #----- Do the update with the update data

                log "Update casasmooth process..."
                rm -f "${cs_logs}/cs_update_casasmooth.lock" 
                rm -f "${cs_logs}/cs_update_casasmooth.log" 
                bash "${cs_lib}/cs_update_casasmooth.sh" "${forward_args[@]}" --log --verbose # > /dev/null 2>&1 &
                if [ $? -ne 0 ]; then
                    log "**************** CRITICAL: cs_update_casasmooth.sh failed!"
                    exit 1
                fi

            #----- Collect the results

                tarlist="${cs_temp}/cs_tarlist.txt"
                > "$tarlist"

                add_to_tarlist() {
                    local file="$1"
                    if [ -e "$file" ]; then
                        echo "$file" >> "$tarlist"
                    else
                        log_debug "File not found, skipping: $file"
                    fi
                }

                add_to_tarlist "/config/configuration.yaml"
                add_to_tarlist "/config/themes/cs_themes.yaml"

                find /config/casasmooth/locals/prod -type f -print0 | while IFS= read -r -d $'\0' file; do
                    add_to_tarlist "$file"
                done

                find /config/casasmooth/dashboards -type f -name 'cs_dashboard.yaml' -print0 | while IFS= read -r -d $'\0' file; do
                    add_to_tarlist "$file"
                done

                add_to_tarlist "/config/casasmooth/lib/cs_library.sh"
                add_to_tarlist "/config/casasmooth/lib/.cs_secrets.yaml"

                find /config/casasmooth/commands -type f -print0 | while IFS= read -r -d $'\0' file; do
                    add_to_tarlist "$file"
                done

                add_to_tarlist "/config/casasmooth/logs/cs_inventory.csv"
                add_to_tarlist "/config/casasmooth/logs/cs_inventory.txt"
                add_to_tarlist "/config/casasmooth/logs/cs_update_casasmooth.log"

                add_to_tarlist "/config/www/cs_update_casasmooth.txt"

                tar -czf "${cs_temp}/${result_file}" -T "$tarlist" > /dev/null 2>&1

            #----- Send the result file to the storage account

                log "Uploading file ${result_file} to blob storage account, container ${CONTAINER_NAME}, folder update..."

                response=$(curl -s -w "\n%{http_code}" -X PUT -H "x-ms-blob-type: BlockBlob" --data-binary @"${cs_temp}/${result_file}" "${BLOB_SERVICE}/update/${result_file}?${STORAGE_SAS_TOKEN}")

                http_code=$(echo "$response" | tail -n1)
                response_body=$(echo "$response" | sed '$d')

                if [ "$http_code" -ne "201" ]; then
                    log "Failed to upload ${result_file}. HTTP status code: ${http_code}"
                    log_debug "Response: ${response_body}"
                    exit 1
                fi

                log_debug "Upload successful. HTTP status code: ${http_code}"

            #----- No need to cleanup the container as it is ephemeral
            log "Update completed."

        fi

    fi

    rm -f $cs_update_lock_file

    exit 0