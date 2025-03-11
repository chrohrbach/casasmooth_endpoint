#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.1.7
#
# Send multiple files to the cloud using a REST endpoint; the cloud will send a single email with all attachments.
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

verbose=true

# Usage function
usage() {
    echo "Usage: $0 email_recipient email_object email_message [file1 file2 ...]"
    echo "The first three arguments are mandatory."
    exit 1
}

# Check for minimum arguments
if [ "$#" -lt 3 ]; then
    usage
fi

email_recipient="$1"
email_object="$2"
email_message="$3"
shift 3 # Remove the first three arguments so $@ contains only file arguments (if any)

# Retrieve endpoint URL
endpoint_url=$(extract_secret "email_endpoint")

# Function to send the email (handles both with and without attachments)
send_email() {
    local json_payload="$1"
    local temp_file
    temp_file=$(mktemp) || { log_error "Failed to create temporary file"; return 1; }
    
    # Trap to remove temp_file when the function returns
    trap 'rm -f "$temp_file"' RETURN

    echo "$json_payload" > "$temp_file"

    local response
    response=$(curl --silent --write-out " HTTPSTATUS:%{http_code}" --header "Content-Type: application/json" \
        --data @"$temp_file" \
        "$endpoint_url")

    local http_code
    http_code=$(echo "$response" | sed -e 's/.*HTTPSTATUS://')

    if [ -z "$http_code" ]; then
        log_error "Failed to retrieve HTTP status code from response."
        log_error "Full response: $response"
        return 1
    fi

    if [ "$http_code" -ne 200 ] && [ "$http_code" -ne 202 ]; then
        local body
        body=$(echo "$response" | sed -e 's/ HTTPSTATUS\:.*//g')
        log_error "Failed to send email. HTTP status code: $http_code"
        log_error "Response body: $body"
        return 1 # Indicate failure
    fi

    echo "Email sent successfully." | tee -a "$log_file"
    return 0 # Indicate success
}

# Initialize attachments array
attachments_json="[]"
has_valid_files=false

# Define maximum attachment size (optional, e.g., 10MB)
max_size=10485760 # 10 * 1024 * 1024 bytes

# Process each file if provided
for file_path in "$@"; do
    if [ -z "$file_path" ]; then
        log_error "Empty file path provided; skipping."
        continue # Skip EMPTY file names
    fi

    if [ ! -f "$file_path" ]; then
        log_error "File not found: $file_path"
        continue # Skip to the next file
    fi

    # Check file size
    file_size=$(stat -c%s "$file_path")
    if [ "$file_size" -gt "$max_size" ]; then
        log_error "File $file_path exceeds the maximum allowed size of 10MB and will be skipped."
        continue
    fi

    # Base64 encode the file content without line breaks
    file_content=$(base64 -w 0 "$file_path" | tr -d '\n') || { log_error "Failed to encode file: $file_path"; continue; }
    file_name=$(basename "$file_path")

    # Escape double quotes in file_name and file_content
    escaped_file_name=$(printf '%s' "$file_name" | sed 's/"/\\"/g')
    escaped_file_content=$(printf '%s' "$file_content" | sed 's/"/\\"/g')

    # Append the attachment to the JSON array
    if [ "$attachments_json" == "[]" ]; then
        attachments_json="["
    else
        attachments_json+=","
    fi

    attachments_json+=$(printf '{"file_name":"%s","file_content":"%s"}' "$escaped_file_name" "$escaped_file_content")
    log_info "Prepared attachment: $file_name"
    has_valid_files=true
done

# Close the attachments array if any attachments were added
if [ "$attachments_json" != "[]" ]; then
    attachments_json+="]"
fi

# Construct JSON payload
if [ "$has_valid_files" = true ]; then
    echo "Sending email with attachments..." | tee -a "$log_file"

    json_payload=$(cat <<EOF
{
    "guid": "$guid",
    "email_recipient": "$email_recipient",
    "email_object": "$email_object",
    "email_message": "$email_message",
    "attachments": $attachments_json
}
EOF
)
else
    echo "No valid files provided. Sending email without attachments." | tee -a "$log_file"

    # Always include 'attachments' as an empty array
    json_payload=$(cat <<EOF
{
    "guid": "$guid",
    "email_recipient": "$email_recipient",
    "email_object": "$email_object",
    "email_message": "$email_message",
    "attachments": []
}
EOF
)
fi

# Send the email
send_email "$json_payload" || exit 1 # Send email and exit if it fails

exit 0
