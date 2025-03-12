#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 0.2.8.3.7
#
# Launches local or remote update of casasmooth
#
#=================================== Update the repository to make sure that we run the last version

    cd "/config/casasmooth" >/dev/null 2>&1
    git pull --ff-only origin main 2>&1
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

#===================================

#----- Check options
    usage() {
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --remoting       Enable remote processing"
        echo "  --nocloud        Disable remoting in the cloud, used to debug in a local container"
    }

    forward_args=() # Initialize an empty array to store arguments to forward

    cloud=true
    production=true
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
            log "casasmooth update is not required."
            exit 0
        else
            log "Update casasmooth starting as a detached process..."
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

            data_file="dta_${guid}.tar.gz"
            result_file="res_${guid}.tar.gz"

        #----- Check to see if this system is running on HASS

        if [[ "$ha_present" == "true" ]]; then

            #----- We are on a system running HASS

                if [[ "$(lib_update_required)" == "false" ]]; then
                    log "casasmooth update is not required."
                    exit 0
                fi

                guid=$(jq -r '.data.uuid' "${hass_path}/.storage/core.uuid" 2>/dev/null) || true
                if [[ -z "$guid" ]]; then
                    log "Failed to retrieve guid from ${hass_path}/.storage/core.uuid. Ensure the file exists and contains the correct JSON structure."
                fi

                if [[ -z "${guid:-}" ]]; then
                    log "guid is required for remoting, exiting..."
                    exit 1
                fi

                log "Starting the upload process for remote updating"

            #----- Collect required files

                # Create data file
                tar -czf "${cs_temp}/${data_file}" "/config/.storage" "/config/configuration.yaml" "/config/secrets.yaml" "/config/casasmooth/locals" "/config/casasmooth/cache" 
                if [ ! -f "${cs_temp}/${data_file}" ]; then
                    log "tar.gz file was not created at ${data_file}"
                    exit 1
                fi

            #----- Send the files to the storage account, they will be downloaded by the container
                
                log "Uploading configuration file to the cloud"
                log_debug "Uploading ${data_file} to ${BLOB_SERVICE}/update/${data_file}..."

                # Perform the REST call using curl.
                
                response=$(curl -s -w "\n%{http_code}" -X PUT -H "x-ms-blob-type: BlockBlob" --data-binary @"${cs_temp}/${data_file}" "${BLOB_SERVICE}/update/${data_file}?${STORAGE_SAS_TOKEN}")

                # Separate the HTTP status code from the response body.
                
                http_code=$(echo "$response" | tail -n1)
                response_body=$(echo "$response" | sed '$d')

                if [ "$http_code" -ne "201" ]; then
                    log "Failed to upload ${data_file}. HTTP status code: ${http_code}"
                    log_debug "Response: ${response_body}"
                    exit 1
                fi

                log_debug "Upload successful. HTTP status code: ${http_code}"

                # Remove the local file after successful upload:
                if [[ "$production" == "true" ]]; then
                    rm -f "${cs_temp}/${data_file}"
                    log_debug "Local file ${cs_temp}/${data_file} has been removed."
                fi

            #----- Create container group, the container will read the data file and process it

                if [[ "$cloud" == "true" ]]; then

                    # Request token via client_credentials
                    # 'grant_type=client_credentials' + 'resource=...' + 'client_id=...' + 'client_secret=...'
                    token_response=$(curl -s -X POST \
                    -d "grant_type=client_credentials" \
                    -d "resource=${RESOURCE}" \
                    -d "client_id=${CLIENT_ID}" \
                    -d "client_secret=${CLIENT_SECRET}" \
                    "${OAUTH_ENDPOINT}")

                    # Extract access_token using jq, sed, or grep
                    # (Here we assume 'jq' is installed. If not, see alternative below.)
                    ACCESS_TOKEN=$(echo "$token_response" | jq -r '.access_token')

                    if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
                        echo "Failed to obtain an access token. Response was:"
                        echo "$token_response"
                        exit 1
                    fi

                    log "Starting cloud processing"
                    log_debug "Creating container group '${guid}' in resource group '${AZURE_RESOURCE_GROUP}'..."

                    # Build the JSON payload as an inline string.

                    CREATE_PAYLOAD="{
                    \"location\": \"${LOCATION}\",
                    \"properties\": {
                        \"imageRegistryCredentials\": [
                        {
                            \"server\": \"${ACR_SERVER}\",
                            \"username\": \"${ACR_USERNAME}\",
                            \"password\": \"${ACR_PASSWORD}\"
                        }
                        ],
                        \"containers\": [
                        {
                            \"name\": \"${guid}\",
                            \"properties\": {
                            \"image\": \"${IMAGE}\",
                            \"resources\": {
                                \"requests\": {
                                \"memoryInGB\": 1.5,
                                \"cpu\": 2
                                }
                            },
                            \"environmentVariables\": [
                                {
                                \"name\": \"guid_to_process\",
                                \"value\": \"${guid}\"
                                }
                            ]
                            }
                        }
                        ],
                        \"osType\": \"Linux\",
                        \"sku\": \"Standard\"
                    }
                    }"

                    CREATE_URL="${MGMT_URL}/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.ContainerInstance/containerGroups/${guid}?api-version=2023-05-01"

                    # Send the PUT request and capture the HTTP code.
                    create_response=$(curl -s -w "\n%{http_code}" -X PUT -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json" -d "${CREATE_PAYLOAD}" "${CREATE_URL}")

                    # Separate the body and HTTP code.
                    create_body=$(echo "$create_response" | sed '$d')
                    create_http_code=$(echo "$create_response" | tail -n1)

                    if [[ "$create_http_code" =~ ^2 ]]; then
                        log_debug "Container group '${guid}' created successfully."
                    else
                        log "Error creating container group. HTTP code: ${create_http_code}"
                        log_debug "Response: ${create_body}"
                        exit 1
                    fi
                fi

            #----- While the process does his work, we wait for the results by looking for the result blob existence

                log "Waiting for processing results"
                log_debug "Polling for blob file 'update/${result_file}'..."

                found=false
                max_attempts=180
                secs=5
                attempt=0
                while [ $attempt -lt $max_attempts ]; do
                    attempt=$((attempt+1))
                    log_debug "Attempt ${attempt}/${max_attempts}: Polling..."

                    blob_url="${BLOB_SERVICE}/update/${result_file}?${STORAGE_SAS_TOKEN}"
                    log_debug "Checking URL: ${blob_url}" # Log the full URL

                    http_status=$(curl -s -o /dev/null -w "%{http_code}" -I "${blob_url}")
                    log_debug "Attempt ${attempt}/${max_attempts}: HTTP Status: ${http_status}" # Log HTTP status code

                    if [ "$http_status" -eq "200" ]; then
                        log_debug "Blob file found (HTTP 200)."
                        found=true
                        break
                    else
                        log_debug "Attempt ${attempt}/${max_attempts}: Blob not found (HTTP ${http_status}), waiting ${secs} seconds..."
                        sleep $secs
                    fi
                done

                if $found; then
                    log "Result blob '${result_file}' found after ${attempt} attempts."
                    # Proceed with further processing knowing the blob exists
                else
                    log "Result blob '${result_file}' not found after ${max_attempts} attempts. Timeout."
                    # Handle the case where the blob is not found (e.g., error, retry, etc.)
                fi

            #----- Delete the data file from blob storage

                if [[ "$production" == "true" ]]; then

                    log_debug "Deleting file ${data_file} from ${BLOB_SERVICE}/update/${data_file}..."

                    delete_response=$(curl -s -w "\n%{http_code}" -X DELETE "${BLOB_SERVICE}/update/${data_file}?${STORAGE_SAS_TOKEN}")
                    delete_http_code=$(echo "$delete_response" | tail -n1)
                    delete_response_body=$(echo "$delete_response" | sed '$d')

                    if [ "$delete_http_code" -ne "202" ]; then
                        log "Failed to delete ${data_file}. HTTP status code: ${delete_http_code}"
                        log_debug "Response: ${delete_response_body}"
                        exit 1
                    fi

                fi

            #----- Process has been terminated, delete the container group

                if [[ "$cloud" == "true" ]]; then

                    log_debug "Deleting container group '${guid}'..."

                    DELETE_URL="${MGMT_URL}/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.ContainerInstance/containerGroups/${guid}?api-version=2023-05-01"

                    delete_response=$(curl -s -w "\n%{http_code}" -X DELETE -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json" "${DELETE_URL}")
                    delete_http_code=$(echo "$delete_response" | tail -n1)
                    delete_response_body=$(echo "$delete_response" | sed '$d')

                    if [[ "$delete_http_code" =~ ^2 ]]; then
                        log "Processing finished"
                        log_debug "Container group '${guid}' deleted successfully."
                    else
                        log  "Error deleting container group. HTTP code: ${delete_http_code}"
                        log_debug "Response: ${delete_response_body}"
                        exit 1
                    fi
                fi
            #----- Check that we have found the result file

                if [[ "$found" != "true" ]]; then
                    log "Timeout reached: Blob file did not appear."
                    exit 1
                fi

            #----- Get the result file

                rm -f ${cs_temp}/${result_file}
                http_code=$(curl --silent --show-error --output "${cs_temp}/${result_file}" --write-out "%{http_code}" "${BLOB_SERVICE}/update/${result_file}?${STORAGE_SAS_TOKEN}")
                
                if [ "$http_code" = "200" ]; then
                    log "Results collected"
                    log_debug "We got the result file update/${result_file}, we can go on with the processing..."
                    sleep 3 # wait for the file to be ready
                else
                    log "File 'update/${result_file}' not available."
                    exit 1
                fi

            #----- Delete the result file from blob storage

                log_debug "Deleting file ${result_file} from ${BLOB_SERVICE}/update/${result_file}..."

                delete_response=$(curl -s -w "\n%{http_code}" -X DELETE "${BLOB_SERVICE}/update/${result_file}?${STORAGE_SAS_TOKEN}")
                delete_http_code=$(echo "$delete_response" | tail -n1)
                delete_response_body=$(echo "$delete_response" | sed '$d')

                if [ "$delete_http_code" -ne "202" ]; then
                    log "Failed to delete ${result_file}. HTTP status code: ${delete_http_code}"
                    log_debug "Response: ${delete_response_body}"
                    exit 1
                fi

            #----- Decompress the result file

                if [[ "$production" == "true" ]]; then
                    log "Installing results"
                    log_debug "Decompressing ${cs_temp}/${result_file}..."
                    tar -xzf "${cs_temp}/${result_file}" -C / 
                    rm -f "${cs_temp}/${result_file}"
                    log_debug "Local file ${cs_temp}/${result_file} has been removed."
                fi

            #----- Execute a guid update, this sends also some important information to the backend
            
                bash "${cs_commands}/cs_register_guid.sh"

            #----- Copy static resources

                # Create directories safely
                mkdir -p "${hass_path}/www"
                mkdir -p "${hass_path}/www/community"
                mkdir -p "${hass_path}/www/images"

                # Copy custom cards
                safe_copy "${cs_resources}" "${hass_path}/www/community"

                # Copy images
                mkdir -p "${cs_path}/images"
                safe_copy "${cs_path}/images" "${hass_path}/www"

                # Copy sounds
                safe_copy "${cs_medias}" "/media"

            #----- Restart

                if [[ "$production" == "true" ]]; then
                    if [ "$(lib_need_restart)" -eq 1 ]; then
                        log "Restarting core..."
                        ha core restart
                    fi
                fi

            log "Done"

        else

            #----- We are on a system without HASS, probably a VM, a container, or a terminal

                if [[ -z "${guid_to_process:-}" ]]; then
                    log "guid_to_process is required for remoting, exiting..."
                    exit 1
                fi

                guid="${guid_to_process}"

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
                        log "File 'update/${data_file}' not yet available. Waiting for ${poll_interval} seconds..."
                    else
                        log "Request for 'update/${data_file}' failed with HTTP code ${http_code}. Waiting for ${poll_interval} seconds..."
                    fi
                    sleep "$poll_interval"
                    elapsed=$((elapsed + poll_interval))
                done
                if [[ "$found" != "true" ]]; then
                    log "Wait finished but file ${data_file} not present. Exiting the process."
                    exit 1
                fi
                if [ "$elapsed" -ge "$timeout_seconds" ]; then
                    log "Polling timeout reached after $timeout_seconds seconds. We did not see the ${data_file}. Exiting the process."
                    exit 1
                fi

            #----- Extract the data tar file

                log "Extracting the data file..."
                tar -xzf "${cs_temp}/${data_file}" -C / 
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

                tar -czf "${cs_temp}/${result_file}" -T "$tarlist" 

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