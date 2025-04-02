#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 1.1.4
#
# Get the subscribed services from the cloud using a REST endpoint
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#=================================== Script

verbose=true

# Get the GUID
if [ -z "$guid" ]; then
    guid=$(jq -r ".data.uuid" "${hass_path}/.storage/core.uuid")
    if [ -z "$guid" ]; then
        log "Failed to retrieve guid from ${hass_path}/.storage/core.uuid"
        exit 1
    fi
fi

# Get the endpoint URL from the YAML file
endpoint_url=$(extract_secret "getservices_endpoint")
if [ -z "$endpoint_url" ]; then
    log "Failed to retrieve endpoint URL"
    exit 1
fi

# Make the REST call with the GUID as the payload
json_payload=$(jq -n --arg guid "$guid" --arg option "$*" '{guid: $guid, option: $option}')
log "Getting services for $guid"
services=$(curl -s --header "Content-Type: application/json" --data "$json_payload" "$endpoint_url")
if [ $? -ne 0 ]; then
    log "Failed to retrieve content from $guid"
    exit 1
fi

# Check if the content is different before writing
if [ "$services" != "$(cat "${cs_path}/cache/cs_services.txt" 2>/dev/null)" ]; then
  # Write the content to the file
  echo "$services" > "${cs_path}/cache/cs_services.txt"
fi

exit 0