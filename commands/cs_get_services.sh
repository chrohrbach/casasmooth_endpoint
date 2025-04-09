#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 1.2.0
#
# Get the subscribed services from the cloud using a REST endpoint.
# - Revised for robustness
# - Added rate limiting: Only calls API if cache file is older than 15 mins.
# - Added API call validation: Checks curl exit status, HTTP status code, and non-empty response.
# - Prevents writing to cache file on API error.
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#=================================== Script

verbose=true
cache_file="${cs_path}/cache/cs_services.txt"
min_interval_seconds=$((15 * 60)) # 15 minutes in seconds

# --- Check Rate Limit ---
# Default to proceeding if file doesn't exist or check fails
proceed=true
if [ -f "$cache_file" ]; then
    current_time=$(date +%s)
    # Use stat for potentially better portability/reliability getting timestamp
    file_mod_time=$(stat -c %Y "$cache_file" 2>/dev/null || date -r "$cache_file" +%s 2>/dev/null)

    if [[ -n "$file_mod_time" && "$current_time" -lt $((file_mod_time + min_interval_seconds)) ]]; then
        log "Skipping API call: Cache file '$cache_file' is newer than ${min_interval_seconds} seconds."
        proceed=false
        exit 0 # Exit gracefully, not an error state
    else
        # Log if the check determines we need to proceed (file old or timestamp read failed)
        if [[ -z "$file_mod_time" ]]; then
             log "Cache file timestamp check failed for '$cache_file', proceeding with API call."
        else
             log "Cache file '$cache_file' is older than ${min_interval_seconds} seconds, proceeding with API call."
        fi
    fi
else
    log "Cache file '$cache_file' not found, proceeding with API call."
fi

# --- Get GUID ---
# Allow overriding via environment variable, otherwise fetch from file
guid_file="${hass_path}/.storage/core.uuid"
if [ -z "$guid" ]; then
    if [ ! -f "$guid_file" ]; then
        log "GUID file not found: ${guid_file}"
        exit 1
    fi
    guid=$(jq -r ".data.uuid" "$guid_file")
    if [ -z "$guid" ]; then
        log "Failed to retrieve guid from ${guid_file}"
        exit 1
    fi
    log "Retrieved guid: $guid"
fi

# --- Get Endpoint URL ---
endpoint_url=$(extract_secret "getservices_endpoint")
if [ -z "$endpoint_url" ]; then
    log "Failed to retrieve endpoint URL using secret 'getservices_endpoint'"
    exit 1
fi
log "Using endpoint URL: $endpoint_url"

# --- Prepare and Make REST Call ---
json_payload=$(jq -n --arg guid "$guid" --arg option "$*" '{guid: $guid, option: $option}')
if [ $? -ne 0 ]; then
    log "Failed to create JSON payload using jq."
    exit 1
fi

log "Getting services for GUID: $guid (Options: '$*')"

# Use curl to get body and HTTP status code separately
# -f/--fail: Make curl exit non-zero on server errors (4xx, 5xx)
# -s/--silent: Don't show progress meter or error messages (we handle errors)
# -S/--show-error: Show error message on failure even with -s (useful with -f)
# -w "%{http_code}": Write HTTP status code to stdout after transfer
# Use process substitution to capture body into variable while getting status code
http_response=$(curl -fsS --header "Content-Type: application/json" \
                     --data "$json_payload" \
                     -w "\n%{http_code}" \
                     "$endpoint_url" 2>&1) # Capture stdout and stderr

curl_exit_status=$?
http_code=$(echo "$http_response" | tail -n1) # Extract status code (last line)
services=$(echo "$http_response" | sed '$d')  # Extract body (all except last line)

# --- Validate API Response ---
# Check 1: curl command execution success
if [ $curl_exit_status -ne 0 ]; then
    # Curl itself failed (network error, timeout, DNS, -f triggered error, etc.)
    log "API call failed. curl exit status: $curl_exit_status. Error: $services" # Variable 'services' contains curl error message here
    exit 1
fi

# Check 2: HTTP Status Code (expecting 200 OK)
if [ "$http_code" -ne 200 ]; then
    log "API call failed. HTTP Status Code: $http_code. Response: $services"
    exit 1
fi

# Check 3: Non-empty response body (optional, but good practice)
if [ -z "$services" ]; then
    log "API call successful (HTTP 200), but received empty response body."
    # Decide if this is an error or acceptable. Assuming it's an error for now.
    exit 1
fi

log "Successfully retrieved services (HTTP $http_code)."

# --- Process Response: Check if content is different ---
# Create cache directory if it doesn't exist
cache_dir=$(dirname "$cache_file")
if [ ! -d "$cache_dir" ]; then
    mkdir -p "$cache_dir"
    if [ $? -ne 0 ]; then
        log "Failed to create cache directory: $cache_dir"
        exit 1
    fi
fi

# Compare new content with cached content (if cache file exists)
cached_services=""
if [ -f "$cache_file" ]; then
    cached_services=$(cat "$cache_file")
fi

if [ "$services" != "$cached_services" ]; then
    log "Service data has changed, updating cache file: $cache_file"
    # Write the new content to the file. The API call was successful.
    echo "$services" > "$cache_file"
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to write to cache file: $cache_file"
        exit 1
    else
        log "Cache file updated successfully."
    fi
else
    log "Service data is unchanged. Cache file not modified."
    touch "$cache_file"
fi

exit 0