#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.5.2
#
# Send SMS using Swisscom service
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

#----- Parameter Validation -----
if [ "$#" -ne 3 ]; then
    log_error "Usage: $0 <from_phone_number> <to_phone_number> <message_text>"
    log_error "Please provide exactly three arguments: from phone number, to phone number, and message text."
    exit 1
fi

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    log_error "Error: All parameters (from_phone_number, to_phone_number, message_text) must be provided and not empty."
    exit 1
fi

from_input="$1"
to_input="$2"
text="$3"

#----- Secret Extraction -----
SWISSCOM_ENDPOINT_URL=$(extract_secret "SWISSCOM_ENDPOINT_URL")  # API Endpoint for sending SMS
SWISSCOM_SCS_VERSION=$(extract_secret "SWISSCOM_SCS_VERSION")    # API Version

# OAuth 2.0 Credentials and Token URL
CLIENT_ID=$(extract_secret "SWISSCOM_CLIENT_ID")
CLIENT_SECRET=$(extract_secret "SWISSCOM_CLIENT_SECRET")
OAUTH_TOKEN_URL=$(extract_secret "SWISSCOM_TOKEN_URL")            # e.g., https://api.swisscom.com/oauth2/token

#----- Token Cache File Path
token_cache_file="${cs_path}/cache/token_cache.txt"

#----- Input Validation Functions

# Validate and normalize phone number (E.164 format)
validate_phone_number() {
    local number="$1"
    local normalized_number

    # Remove any spaces, dashes, dots, or parentheses from the input number before normalization
    number=$(sed 's/[[:space:][dash][dot][parenth]]//g' <<< "$number")

    # Check if the number starts with '00' and replace it with '+'
    if [[ "$number" =~ ^00 ]]; then
        normalized_number="+${number:2}"
    else
        normalized_number="$number"
    fi

    # Validate the normalized number against E.164 format
    # E.164: '+' followed by country code (1-3 digits), then subscriber number (variable length)
    # Relaxed the regex to allow for slightly more variation in subscriber number length after country code
    if [[ ! "$normalized_number" =~ ^\+[1-9][0-9]{1,14}$ ]]; then
        return 1 # Indicate failure
    fi

    # Return the normalized number
    echo "$normalized_number"
    return 0 # Indicate success
}


# Validate message length (assuming max 160 characters)
validate_message_length() {
    local message="$1"
    if [ "${#message}" -gt 160 ]; then
        log_error "Message text exceeds 160 characters. Length: ${#message}"
        exit 1
    fi
}

#----- Perform Input Validations

# Validate and normalize the 'from' phone number
from=$(validate_phone_number "$from_input")
if [ $? -ne 0 ]; then
    exit 1
fi

# Validate and normalize the 'to' phone number
to=$(validate_phone_number "$to_input")
if [ $? -ne 0 ]; then
    exit 1
fi


# Validate message length
validate_message_length "$text"

#----- Function to Obtain a New Access Token
get_access_token() {

    # Perform the token request using the correct POST body parameters
    response=$(curl -s -X POST "$OAUTH_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -u "$CLIENT_ID:$CLIENT_SECRET" \
        -d "grant_type=client_credentials")

    # Parse JSON response using jq
    access_token=$(echo "$response" | jq -r '.access_token')
    expires_in=$(echo "$response" | jq -r '.expires_in')

    if [ -z "$access_token" ] || [ -z "$expires_in" ]; then
        exit 1
    fi

    # Calculate the expiration timestamp
    current_time=$(date +%s)
    expires_at=$((current_time + expires_in))

    # Store the new token and expiration time in the cache file
    echo "$access_token\n$expires_at" > "$token_cache_file"
    chmod 600 "$token_cache_file"  # Secure the token cache file

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
                echo "$token"
                return
            fi
        fi
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