#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 0.1.2.5
#
# This script is the client part of the remote update process. 
# This has been separated from the main cs_update due to 60s timeout that 
# the shell_command applies to script launched from hass.
#
#=================================== Update the repository to make sure that we run the last version (even in a sub/detached process)

    cd "/config/casasmooth" >/dev/null 2>&1
    temp_log="/config/casasmooth/logs/$(basename ${0%.*}).log"
    : > "${temp_log}"
    trace() { 
        printf "%s %s: $1\n" "$0" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${temp_log}"
    }
    trace "Update sources"
    git fetch origin main && git reset --hard origin/main >/dev/null 2>&1
    chmod +x commands/*.sh >/dev/null 2>&1

#=================================== Include cs_library

    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        trace "ERROR: Failed to source ${include}"
        exit 1
    fi

#=================================== Concurrency management

    trace "Set lock"
    cs_update_casasmooth_lock_file="${cs_path}/cs_update_casasmooth.lock"

    # Function to remove the lock file
    remove_cs_update_casasmooth_lock_file() {
        if [ -f "$cs_update_casasmooth_lock_file" ]; then
            trace "Remove lock"
            rm -f "$cs_update_casasmooth_lock_file"
        fi
        # Optionally, close the file descriptor if it's still open (though it should be closed when the script exits)
        exec 9>&-
    }

    # Trap signals to ensure lock file removal on exit (including errors and signals like SIGINT, SIGTERM)
    trap remove_cs_update_casasmooth_lock_file EXIT SIGINT SIGTERM SIGQUIT ERR

    # Create a file descriptor for flock
    exec 9>"$cs_update_casasmooth_lock_file"
    # Attempt to acquire an exclusive lock using flock
    if ! flock -n 9; then # -n: non-blocking, returns immediately if lock cannot be acquired
        trace "Script is already running"
        exit 1
    fi

#----- Check options
    usage() {
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --nocloud        Disable remoting in the cloud, used to debug in a local container"
    }

    forward_args=() # Initialize an empty array to store arguments to forward

    production=true

    cloud=true

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --log)
                logger=true
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

#----- guid is required

    guid=$(jq -r '.data.uuid' "${hass_path}/.storage/core.uuid" 2>/dev/null) || true
    if [[ -z "$guid" ]]; then
        trace "Failed to retrieve guid from ${hass_path}/.storage/core.uuid. Ensure the file exists and contains the correct JSON structure."
    fi

    if [[ -z "${guid:-}" ]]; then
        trace "guid is required for remoting, exiting..."
        exit 1
    fi

    data_file="dta_${guid}.tar.gz"
    result_file="res_${guid}.tar.gz"

    trace "Starting the upload process for remote updating"

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
    UPDATE_SAS_TOKEN=$(extract_secret "UPDATE_SAS_TOKEN")
    CLIENT_ID=$(extract_secret "CLIENT_ID")
    CLIENT_SECRET=$(extract_secret "CLIENT_SECRET")
    OAUTH_ENDPOINT=$(extract_secret "OAUTH_ENDPOINT")
    RESOURCE=$(extract_secret "RESOURCE")   

#----- Collect required files

    # Create data file
    tar -czf "${cs_temp}/${data_file}" "/config/.storage" "/config/configuration.yaml" "/config/secrets.yaml" "/config/casasmooth/locals" "/config/casasmooth/cache" > /dev/null 2>&1
    if [ ! -f "${cs_temp}/${data_file}" ]; then
        trace "tar.gz file was not created at ${data_file}"
        exit 1
    fi

#----- Cleanup the possible existing blobs from blob storage

    if [[ "$production" == "true" ]]; then

        trace "Deleting file ${data_file} from ${BLOB_SERVICE}/update/${data_file}..."
        delete_response=$(curl -s -w "\n%{http_code}" -X DELETE "${BLOB_SERVICE}/update/${data_file}?${UPDATE_SAS_TOKEN}")

        trace "Deleting file ${result_file} from ${BLOB_SERVICE}/update/${result_file}..."
        delete_response=$(curl -s -w "\n%{http_code}" -X DELETE "${BLOB_SERVICE}/update/${result_file}?${UPDATE_SAS_TOKEN}")

    fi

#----- Send the files to the storage account, they will be downloaded by the container
    
    trace "Uploading ${data_file} to ${BLOB_SERVICE}/update/${data_file}..."

    # Perform the REST call using curl.
    
    response=$(curl -s -w "\n%{http_code}" -X PUT -H "x-ms-blob-type: BlockBlob" --data-binary @"${cs_temp}/${data_file}" "${BLOB_SERVICE}/update/${data_file}?${UPDATE_SAS_TOKEN}")

    # Separate the HTTP status code from the response body.
    
    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ne "201" ]; then
        trace "Failed to upload ${data_file}. HTTP status code: ${http_code}"
        trace "Response: ${response_body}"
        exit 1
    fi

    trace "Upload successful. HTTP status code: ${http_code}"

    # Remove the local file after successful upload:
    if [[ "$production" == "true" ]]; then
        rm -f "${cs_temp}/${data_file}"
        trace "Local file ${cs_temp}/${data_file} has been removed."
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
            trace "Failed to obtain an access token. Response was:"
            trace "$token_response"
            exit 1
        fi

        trace "Starting cloud processing"
        trace "Creating container group '${guid}' in resource group '${AZURE_RESOURCE_GROUP}'..."

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
            trace "Container group '${guid}' created successfully."
        else
            trace "Error creating container group. HTTP code: ${create_http_code}"
            trace "Response: ${create_body}"
            exit 1
        fi
    fi

#----- While the process does his work, we wait for the results by looking for the result blob existence

    trace "Polling for blob file 'update/${result_file}'..."

    found=false
    max_attempts=180
    secs=5
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt+1))
        trace "Attempt ${attempt}/${max_attempts}: Polling..."

        blob_url="${BLOB_SERVICE}/update/${result_file}?${UPDATE_SAS_TOKEN}"
        trace "Checking URL: ${blob_url}" # trace the full URL

        http_status=$(curl -s -o /dev/null -w "%{http_code}" -I "${blob_url}")
        trace "Attempt ${attempt}/${max_attempts}: HTTP Status: ${http_status}" # trace HTTP status code

        if [ "$http_status" -eq "200" ]; then
            trace "Blob file found (HTTP 200)."
            found=true
            break
        else
            trace "Attempt ${attempt}/${max_attempts}: Blob not found (HTTP ${http_status}), waiting ${secs} seconds..."
            sleep $secs
        fi
    done

    if $found; then
        trace "Result blob '${result_file}' found after ${attempt} attempts."
        # Proceed with further processing knowing the blob exists
    else
        trace "Result blob '${result_file}' not found after ${max_attempts} attempts. Timeout."
        # Handle the case where the blob is not found (e.g., error, retry, etc.)
    fi

#----- Delete the data file from blob storage

    if [[ "$production" == "true" ]]; then

        trace "Deleting file ${data_file} from ${BLOB_SERVICE}/update/${data_file}..."

        delete_response=$(curl -s -w "\n%{http_code}" -X DELETE "${BLOB_SERVICE}/update/${data_file}?${UPDATE_SAS_TOKEN}")
        delete_http_code=$(echo "$delete_response" | tail -n1)
        delete_response_body=$(echo "$delete_response" | sed '$d')

        if [ "$delete_http_code" -ne "202" ]; then
            trace "Failed to delete ${data_file}. HTTP status code: ${delete_http_code}"
            trace "Response: ${delete_response_body}"
            exit 1
        fi

    fi

#----- Process has been terminated, delete the container group

    if [[ "$cloud" == "true" ]]; then

        trace "Deleting container group '${guid}'..."

        DELETE_URL="${MGMT_URL}/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.ContainerInstance/containerGroups/${guid}?api-version=2023-05-01"

        delete_response=$(curl -s -w "\n%{http_code}" -X DELETE -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json" "${DELETE_URL}")
        delete_http_code=$(echo "$delete_response" | tail -n1)
        delete_response_body=$(echo "$delete_response" | sed '$d')

        if [[ "$delete_http_code" =~ ^2 ]]; then
            trace "Processing finished"
            trace "Container group '${guid}' deleted successfully."
        else
            trace "Error deleting container group. HTTP code: ${delete_http_code}"
            trace "Response: ${delete_response_body}"
            exit 1
        fi
    fi
#----- Check that we have found the result file

    if [[ "$found" != "true" ]]; then
        trace "Timeout reached: Blob file did not appear."
        exit 1
    fi

#----- Get the result file

    rm -f ${cs_temp}/${result_file}
    http_code=$(curl --silent --show-error --output "${cs_temp}/${result_file}" --write-out "%{http_code}" "${BLOB_SERVICE}/update/${result_file}?${UPDATE_SAS_TOKEN}")
    
    if [ "$http_code" = "200" ]; then
        trace "We got the result file update/${result_file}, we can go on with the processing..."
        sleep 3 # wait for the file to be ready
    else
        trace "File 'update/${result_file}' not available."
        exit 1
    fi

#----- Delete the result file from blob storage

    trace "Deleting file ${result_file} from ${BLOB_SERVICE}/update/${result_file}..."

    delete_response=$(curl -s -w "\n%{http_code}" -X DELETE "${BLOB_SERVICE}/update/${result_file}?${UPDATE_SAS_TOKEN}")
    delete_http_code=$(echo "$delete_response" | tail -n1)
    delete_response_body=$(echo "$delete_response" | sed '$d')

    if [ "$delete_http_code" -ne "202" ]; then
        trace "Failed to delete ${result_file}. HTTP status code: ${delete_http_code}"
        trace "Response: ${delete_response_body}"
        exit 1
    fi

#----- Decompress the result file

    if [[ "$production" == "true" ]]; then
        trace "Installing results"
        trace "Decompressing ${cs_temp}/${result_file}..."
        tar -xzf "${cs_temp}/${result_file}" -C / > /dev/null 2>&1
        rm -f "${cs_temp}/${result_file}"
        trace "Local file ${cs_temp}/${result_file} has been removed."
    fi

#----- Execute a guid update, this sends also some important information to the backend

    bash "${cs_commands}/cs_register_guid.sh"

#----- Copy static resources

    # Create directories safely
    mkdir -p "${hass_path}/www"
    mkdir -p "${hass_path}/www/community"
    mkdir -p "${hass_path}/www/images"
    mkdir -p "${hass_path}/www/tts"

    # Copy custom cards
    safe_copy "${cs_resources}" "${hass_path}/www/community"

    # Copy custom components
    safe_copy "${cs_custom_components}" "${hass_path}/custom_components"

    # Copy images
    mkdir -p "${cs_images}"
    safe_copy "${cs_images}" "${hass_path}/www/images"

    # Copy sounds
    safe_copy "${cs_medias}" "/media"

#----- Restart

    if [[ "$production" == "true" ]]; then
        if [[ "$(lib_need_restart)" == "true" ]]; then
            trace "Restarting core..."
            ha core restart
        fi
    fi

trace "Done"