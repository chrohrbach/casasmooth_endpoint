#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.5.1
#
# Send SMS using Swisscom service (Updated for New API with Token Caching and Unified Number Validation)
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

SWISSCOM_ENDPOINT_URL=$(extract_secret "SWISSCOM_ENDPOINT_URL")  # API Endpoint for sending SMS
SWISSCOM_SCS_VERSION=$(extract_secret "SWISSCOM_SCS_VERSION")    # API Version

# OAuth 2.0 Credentials and Token URL
CLIENT_ID=$(extract_secret "SWISSCOM_CLIENT_ID")
CLIENT_SECRET=$(extract_secret "SWISSCOM_CLIENT_SECRET")
OAUTH_TOKEN_URL=$(extract_secret "SWISSCOM_TOKEN_URL")            # e.g., https://api.swisscom.com/oauth2/token

#----- Token Cache File Path
token_cache_file="${cs_path}/cache/token_cache.txt"

from_input="$1"
to_input="$2"
text="$3"

#----- Input Validation Functions

# Validate and normalize phone number (E.164 format)
validate_phone_number() {
    local number="$1"
    local normalized_number

    # Check if the number starts with '00' and replace it with '+'
    if [[ "$number" =~ ^00 ]]; then
        normalized_number="+${number:2}"
        log_success "Normalized number from '00' to '+': $number -> $normalized_number"
    else
        normalized_number="$number"
    fi

    # Validate the normalized number against E.164 format
    if [[ ! "$normalized_number" =~ ^\+[1-9][0-9]{7,14}$ ]]; then
        log_error "Invalid phone number format: $number -> $normalized_number"
        exit 1
    fi

    # Return the normalized number
    echo "$normalized_number"
}

# Validate message length (assuming max 160 characters)
validate_message_length() {
    local message="$1"
    if [ "${#message}" -gt 160 ]; then
        log_error "Message text exceeds 160 characters."
        exit 1
    fi
}

#----- Perform Input Validations

# Validate and normalize the 'from' phone number
from=$(validate_phone_number "$from_input")

# Validate and normalize the 'to' phone number
to=$(validate_phone_number "$to_input")

# Validate message length
validate_message_length "$text"

#----- Function to Obtain a New Access Token
get_access_token() {
    log_success "Requesting a new access token from Swisscom..."

    # Perform the token request using the correct POST body parameters
    response=$(curl -s -X POST "$OAUTH_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -u "$CLIENT_ID:$CLIENT_SECRET" \
        -d "grant_type=client_credentials")

    # Parse JSON response using jq
    access_token=$(echo "$response" | jq -r '.access_token')
    expires_in=$(echo "$response" | jq -r '.expires_in')

    # Temporary Debugging Logs
    log_success "Parsed Access Token: $access_token"
    log_success "Parsed Expires In: $expires_in"

    if [ -z "$access_token" ] || [ -z "$expires_in" ]; then
        log_error "Failed to obtain access token. Response: $response"
        exit 1
    fi

    # Calculate the expiration timestamp
    current_time=$(date +%s)
    expires_at=$((current_time + expires_in))

    # Store the new token and expiration time in the cache file
    echo "$access_token\n$expires_at" > "$token_cache_file"
    chmod 600 "$token_cache_file"  # Secure the token cache file

    log_success "New access token obtained and cached. Expires in $((expires_in / 86400)) days."

    echo "$access_token"
}

#----- Function to Get a Valid Access Token (Cached or New)
get_valid_access_token() {
    local token=""
    local expires_at=""
    local current_time

    if [ -f "$token_cache_file" ]; then
        # Read the cached token and its expiration time
        read -r token expires_at < "$token_cache_file"

        # Check if both token and expiration time are present
        if [ -n "$token" ] && [ -n "$expires_at" ]; then
            current_time=$(date +%s)
            if [ "$current_time" -lt "$expires_at" ]; then
                log_success "Using cached access token."
                echo "$token"
                return
            else
                log_success "Cached access token expired. Fetching a new one."
            fi
        else
            log_error "Token cache file is corrupted or incomplete."
        fi
    else
        log_success "No cached access token found. Fetching a new one."
    fi

    # If token is not valid or cache is missing/corrupted, fetch a new one
    get_access_token
}

#----- Function to Send SMS
send_sms() {
    local access_token="$1"
    local payload
    local response
    local response_body
    local status_code

    # Construct JSON payload using jq
    payload=$(jq -n \
        --arg sender "$from" \
        --arg recipient "$to" \
        --arg message "$text" \
        '{
            from: $sender,
            to: $recipient,
            text: $message
        }')

    # Log the payload for debugging (optional, remove in production)
    log_success "Sending payload: $payload"

    # Send the SMS request using curl with response and HTTP status code
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${access_token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "SCS-Version: ${SWISSCOM_SCS_VERSION}" \
        -d "$payload" \
        "${SWISSCOM_ENDPOINT_URL}")

    # Split response body and status code
    response_body=$(echo "$response" | sed '$d')
    status_code=$(echo "$response" | tail -n1)

    # Log the full response for debugging (optional, remove in production)
    log_success "API Response Body: $response_body"

    # Log based on response
    if [[ "$status_code" -ge 200 && "$status_code" -lt 300 ]]; then
        log_success "Successfully sent SMS. HTTP Status: $status_code, Response: $response_body"
        return 0
    else
        log_error "Error sending SMS: HTTP Status $status_code, Response: $response_body"
        return 1
    fi
}

#----- Function to Implement Retry Logic
send_sms_with_retries() {
    local access_token="$1"
    local max_retries=3
    local retry_delay=5  # seconds
    local attempt=1

    while [ "$attempt" -le "$max_retries" ]; do
        send_sms "$access_token"
        local send_status=$?

        if [[ "$send_status" -eq 0 ]]; then
            break
        else
            log_error "Attempt $attempt: Failed to send SMS."
            if [ "$attempt" -lt "$max_retries" ]; then
                log_error "Retrying in $retry_delay seconds..."
                sleep "$retry_delay"
            fi
        fi

        attempt=$((attempt + 1))
    done

    if [ "$attempt" -gt "$max_retries" ]; then
        log_error "Failed to send SMS after $max_retries attempts."
        exit 1
    fi
}

#----- Main Execution Flow

# Get a valid access token (from cache or new)
valid_access_token=$(get_valid_access_token)

# Send the SMS with retry logic
send_sms_with_retries "$valid_access_token"

#----- End of Script
