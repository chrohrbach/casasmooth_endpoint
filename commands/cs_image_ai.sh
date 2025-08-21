#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 2.1.1
#
# Send image to AI analysis service or process locally
# Usage: cs_image_ai.sh <execution_mode> "csuuid" "entity_id" "image_path" [camera_short]

#=================================== Help Function
show_help() {
    printf '%s\n' \
        "casasmooth Image AI Analysis Script v2.1.0" \
        "" \
        "USAGE:" \
        "    cs_image_ai.sh <execution_mode> <csuuid> <entity_id> <image_path> [camera_short]" \
        "" \
        "PARAMETERS:" \
        "    execution_mode    Execution mode: \"remote\" or \"local\"" \
        "    csuuid           Casa Smooth UUID identifier" \
        "    entity_id        Home Assistant entity ID" \
        "    image_path       Path to the image file to analyze" \
        "    camera_short     Camera short name (required for local execution)" \
        "" \
        "EXECUTION MODES:" \
        "    remote          Send image to remote AI analysis service" \
        "    local           Process image locally using AI provider (Gemini or OpenAI)" \
        "" \
        "AI PROVIDER SELECTION:" \
        "    Set IMAGE_AI_PROVIDER environment variable to 'gemini' or 'openai'" \
        "    Default: gemini (for backward compatibility)" \
        "    Example: IMAGE_AI_PROVIDER=openai cs_image_ai.sh local ..." \
        "" \
        "EXAMPLES:" \
        "    # Remote execution" \
        "    cs_image_ai.sh remote \"uuid123\" \"camera.front_door\" \"/config/www/snapshots/front_door.jpg\"" \
        "    " \
        "    # Local execution with Gemini (default)" \
        "    cs_image_ai.sh local \"uuid123\" \"camera.front_door\" \"/config/www/snapshots/front_door.jpg\" \"front_door\"" \
        "    " \
        "    # Local execution with OpenAI" \
        "    IMAGE_AI_PROVIDER=openai cs_image_ai.sh local \"uuid123\" \"camera.front_door\" \"/config/www/snapshots/front_door.jpg\" \"front_door\"" \
        "" \
        "OPTIONS:" \
        "    -h, --help      Show this help message" \
        ""
}

#=================================== Library Integration
include="/config/casasmooth/lib/cs_library.sh"
if ! source "${include}"; then
    echo "ERROR: Failed to source ${include}"
    exit 1
fi

#=================================== Global Variables
logger=true
verbose=true
debug=true

# AI Provider selection - set to "gemini" or "openai"
# Default to "gemini" for backward compatibility
# Can be overridden by environment variable IMAGE_AI_PROVIDER
IMAGE_AI_PROVIDER="${IMAGE_AI_PROVIDER:-gemini}"

# Local execution variables
MANIFEST_FILE=""
MANIFEST_INFO_FILE=""
RESULT_FILE=""
PROMPT_FILE=""
DEVICE_ID=""
GEMINI_API_KEY=""
GEMINI_API_ENDPOINT=""
OPENAI_API_KEY=""
OPENAI_API_ENDPOINT=""
MQTT_HOST=""
MQTT_PORT=""
MQTT_USER=""
MQTT_PASS=""
DEVICE_NAME=""
PROMPT_COUNT=0
PROMPT_NAMES=()
SENSOR_NAMES=()
PROMPT_TEXTS=()
DEVICE_CLASSES=()
COMBINED_PROMPT=""
GEMINI_RESPONSE=""
OPENAI_RESPONSE=""
AI_RESPONSE=""
PARSED_ANSWERS=()
# Note: Manifest can be disabled by setting 'active: false' to avoid unnecessary API calls

#=================================== Argument Validation
# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
    show_help
    exit 0
fi

# Parse arguments
execution_mode="${1:-}"
csuuid="${2:-}"
entity_id="${3:-}"
image_path="${4:-}"
camera_short="${5:-}"

# Validate required arguments
if [[ -z "$execution_mode" || -z "$csuuid" || -z "$entity_id" || -z "$image_path" ]]; then
    echo "ERROR: Missing required parameters"
    echo ""
    show_help
    exit 1
fi

# Validate execution mode
if [[ "$execution_mode" != "remote" && "$execution_mode" != "local" ]]; then
    echo "ERROR: Invalid execution_mode: $execution_mode. Must be 'remote' or 'local'"
    exit 1
fi

# Validate camera_short for local execution
if [[ "$execution_mode" == "local" && -z "$camera_short" ]]; then
    echo "ERROR: camera_short parameter is required for local execution"
    exit 1
fi

# Validate image file exists
if [[ ! -f "$image_path" ]]; then
    echo "ERROR: Image file not found: $image_path"
    exit 1
fi

log_info "Starting image AI analysis:"
log_info "  Mode: $execution_mode"
log_info "  UUID: $csuuid"
log_info "  Entity: $entity_id"
log_info "  Image: $image_path"
if [[ "$execution_mode" == "local" ]]; then
    log_info "  Camera: $camera_short"
fi

#=================================== Remote Execution
execute_remote_analysis() {
    log_info "Executing remote analysis"
    
    # Get endpoint from secrets
    local endpoint_url
    if ! endpoint_url=$(extract_secret "IMAGE_AI_ENDPOINT"); then
        log_error "Failed to extract IMAGE_AI_ENDPOINT secret"
        exit 1
    fi
    
    if [[ -z "$endpoint_url" ]]; then
        log_error "IMAGE_AI_ENDPOINT not configured in secrets"
        exit 1
    fi

    log_debug "Remote endpoint: $endpoint_url"

    # Create payload
    local payload_file="${image_path}.payload.json"
    local image_base64
    image_base64=$(base64 -w 0 "$image_path")
    
    if [[ -z "$image_base64" ]]; then
        log_error "Failed to encode image to base64"
        exit 1
    fi

    # Create JSON payload
    printf '{\n  "csuuid": "%s",\n  "entity_id": "%s",\n  "image_data": "%s"\n}' \
        "$csuuid" "$entity_id" "$image_base64" > "$payload_file"

    # Send request
    log_info "Sending request to remote endpoint"
    if curl -X POST -H "Content-Type: application/json" -d @"$payload_file" "$endpoint_url"; then
        log_info "Remote analysis request sent successfully"
        local exit_code=0
    else
        log_error "Failed to send remote analysis request"
        local exit_code=1
    fi

    # Cleanup
    rm -f "$payload_file"
    exit $exit_code
}

#=================================== Manifest Functions
create_default_manifest() {
    local camera_short="$1"
    local manifest_file="$2"
    local csuuid="$3"
    local entity_id="$4"
    
    mkdir -p "$(dirname "$manifest_file")"
    
    printf '%s\n' \
        "# CasaSmooth AI Image Analysis Manifest" \
        "# Set active to 'true' to enable AI analysis, 'false' to disable" \
        "active: false" \
        "device_id: ${csuuid}_${entity_id}" \
        "device_name: Camera AI Device ${camera_short}" \
        "description: AI image analysis configuration for ${camera_short}" \
        "prompts:" \
        "  - name: General Description" \
        "    sensor_name: camera_general" \
        "    prompt: Describe what you see in this image in detail." \
        "    device_class: text" \
        "  - name: Object Detection" \
        "    sensor_name: camera_objects" \
        "    prompt: List all objects visible in this image." \
        "    device_class: text" \
        "  - name: People Count" \
        "    sensor_name: camera_people" \
        "    prompt: How many people can you see in this image?" \
        "    device_class: text" \
        "  - name: Safety Assessment" \
        "    sensor_name: camera_safety" \
        "    prompt: Are there any safety concerns or hazards visible in this image?" \
        "    device_class: text" \
        "  - name: Weather Conditions" \
        "    sensor_name: camera_weather" \
        "    prompt: What are the weather conditions visible in this image?" \
        "    device_class: text" > "$manifest_file"
    
    log_info "Created default manifest: $manifest_file"
}

load_manifest() {
    local manifest_file="$1"
    local camera_name="$2"

    log_debug "Loading manifest from: $manifest_file"

    # Check if manifest is active
    local manifest_active
    manifest_active=$(grep "^active:" "$manifest_file" 2>/dev/null | cut -d':' -f2 | sed 's/^ *//;s/ *$//' | tr '[:upper:]' '[:lower:]')
    
    if [[ "$manifest_active" != "true" ]]; then
        log_info "Manifest is disabled (active: $manifest_active). Skipping AI analysis."
        return 2  # Special return code to indicate disabled manifest
    fi
    
    log_info "Manifest is active. Proceeding with AI analysis."

    # Extract device name
    DEVICE_NAME=$(grep "^device_name:" "$manifest_file" 2>/dev/null | cut -d':' -f2- | sed 's/^ *//;s/ *$//' || echo "Camera AI Device ${camera_name}")

    # Initialize arrays
    PROMPT_NAMES=()
    SENSOR_NAMES=()
    PROMPT_TEXTS=()
    DEVICE_CLASSES=()

    # Use awk to parse the YAML structure robustly. This is more reliable than line-by-line shell parsing.
    # It reads the file, identifies the 'prompts:' section, and then processes each prompt item (- name: ...).
    # It accumulates the values for each prompt and prints them separated by a pipe (|) when a new prompt starts or at the end.
    local parsed_prompts
    parsed_prompts=$(awk '
        # Set field separators for robust parsing
        BEGIN { FS = ": "; OFS = "|"; in_prompts = 0; }
        
        # Find the start of the prompts section
        /^[[:space:]]*prompts:/ { in_prompts = 1; next; }
        
        # Skip lines outside the prompts section
        !in_prompts { next; }
        
        # Detect a new prompt item
        /^[[:space:]]*- name:/ {
            # Print the previously collected prompt data before starting a new one
            if (name) { print name, sensor, prompt, dev_class; }
            # Reset variables and capture the new name, stripping leading/trailing spaces
            name = substr($0, index($0, $2)); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name);
            sensor = ""; prompt = ""; dev_class = "text"; # Reset for the new prompt
        }
        
        # Capture sensor_name, prompt, and device_class for the current prompt
        /^[[:space:]]+sensor_name:/ { sensor = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", sensor); }
        /^[[:space:]]+prompt:/ { prompt = substr($0, index($0, $2)); gsub(/^[[:space:]]+|[[:space:]]+$/, "", prompt); }
        /^[[:space:]]+device_class:/ { dev_class = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", dev_class); }
        
        # Print the last collected prompt at the end of the file
        END { if (name) { print name, sensor, prompt, dev_class; } }
    ' "$manifest_file")

    # Read the pipe-separated output from awk into shell arrays
    while IFS='|' read -r name sensor_name prompt_text device_class; do
        PROMPT_NAMES+=("$name")
        SENSOR_NAMES+=("$sensor_name")
        PROMPT_TEXTS+=("$prompt_text")
        DEVICE_CLASSES+=("$device_class")
    done <<< "$parsed_prompts"

    PROMPT_COUNT=${#PROMPT_NAMES[@]}

    # Post-load validation to ensure no empty values exist
    for ((i=0; i<PROMPT_COUNT; i++)); do
        if [[ -z "${PROMPT_NAMES[i]}" ]]; then PROMPT_NAMES[i]="Unnamed Prompt $(($i+1))"; fi
        if [[ -z "${SENSOR_NAMES[i]}" ]]; then SENSOR_NAMES[i]="camera_ai_$(($i+1))"; fi
        if [[ -z "${PROMPT_TEXTS[i]}" ]]; then PROMPT_TEXTS[i]="Describe the image."; fi
        if [[ -z "${DEVICE_CLASSES[i]}" ]]; then DEVICE_CLASSES[i]="text"; fi
    done

    log_debug "Loaded manifest with $PROMPT_COUNT prompts"
    return 0
}

#=================================== Prompt Building
build_combined_prompt() {
    if [[ "$PROMPT_COUNT" -eq 0 ]]; then
        log_error "No prompts found in manifest"
        return 1
    fi
    
    # Use printf to initialize the string with actual newlines.
    # This avoids mixing literal '\n' with real newlines.
    local prompt_body
    prompt_body=$(printf "Please analyze the image and provide a numbered list of answers corresponding to each of the following numbered prompts. Your response should only contain the numbered list of answers.\n\n")
    
    # The loop correctly appends formatted strings with newlines.
    for ((i=0; i<PROMPT_COUNT; i++)); do
        prompt_body+=$(printf "%d. %s\n\n" "$((i+1))" "${PROMPT_TEXTS[i]}")
    done

    # No need to re-process the string with printf. Just assign it.
    COMBINED_PROMPT="$prompt_body"
    
    # Save the combined prompt to the specified file
    # Use printf with %s for safer output, preventing interpretation of any special characters in the prompt.
    printf "%s" "$COMBINED_PROMPT" > "$PROMPT_FILE"
    
    log_debug "Built combined prompt with $PROMPT_COUNT questions"
    log_debug "Final prompt saved to: $PROMPT_FILE"
    return 0
}

#=================================== Gemini API Call
call_gemini_api() {
    log_info "Calling Gemini API"
    
    # Encode image to base64
    local image_base64
    image_base64=$(base64 -w 0 "$image_path")
    
    if [[ -z "$image_base64" ]]; then
        log_error "Failed to encode image to base64"
        return 1
    fi
    
    log_debug "Image base64 length: ${#image_base64} characters"
    
    # Use temp file approach to avoid "Argument list too long" error
    log_debug "Calling API: ${GEMINI_API_ENDPOINT}?key=***"
    
    # Create temporary JSON file to avoid command line length limits
    local temp_json
    temp_json=$(mktemp)

    # Use jq to build the JSON payload if available, otherwise use sed for escaping
    if command -v jq &> /dev/null; then
        log_debug "Using jq with temp files to build JSON payload and avoid argument length issues"
        
        # Create temp files for the prompt and image data to avoid passing large strings as arguments
        local prompt_file
        prompt_file=$(mktemp)
        echo -n "$COMBINED_PROMPT" > "$prompt_file"

        local image_file
        image_file=$(mktemp)
        echo -n "$image_base64" > "$image_file"

        # Use --rawfile to read the raw content of the files into jq variables
        # This is the most robust method for handling large, arbitrary strings
        jq -n \
          --rawfile prompt_text "$prompt_file" \
          --rawfile image_data "$image_file" \
          '{
            "contents": [{
                "parts": [
                    {"text": $prompt_text},
                    {"inline_data": {"mime_type": "image/jpeg", "data": $image_data}}
                ]
            }],
            "generationConfig": {
                "temperature": 0.2,
                "topP": 0.5,
                "maxOutputTokens": 512
            }
        }' > "$temp_json"

        # Clean up the temporary data files immediately after use
        rm -f "$prompt_file" "$image_file"

    else
        log_debug "Using sed to build JSON payload"
        # Fallback to manual JSON creation with sed escaping
        local escaped_prompt
        escaped_prompt=$(echo "$COMBINED_PROMPT" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/\\n/g')
        cat > "$temp_json" << EOF
{
    "contents": [{
        "parts": [{
            "text": "$escaped_prompt"
        }, {
            "inline_data": {
                "mime_type": "image/jpeg",
                "data": "$image_base64"
            }
        }]
    }],
    "generationConfig": {
        "temperature": 0.2,
        "topP": 0.5,
        "maxOutputTokens": 512
    }
}
EOF
    fi
    
    # Curl call using temp file
    local response
    log_debug "About to call curl with temp file: $temp_json"
    log_debug "Temp file size: $(wc -c < "$temp_json" 2>/dev/null || echo "unknown") bytes"
    
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d @"$temp_json" \
        "${GEMINI_API_ENDPOINT}?key=${GEMINI_API_KEY}" \
        --connect-timeout 30 \
        --max-time 120 2>&1)
    
    local curl_exit_code=$?
    log_debug "Curl completed with exit code: $curl_exit_code"
    
    # Log the raw response for debugging
    log_debug "--- RAW API RESPONSE START ---"
    log_debug "$response"
    log_debug "--- RAW API RESPONSE END ---"
    
    # Clean up temp file immediately
    rm -f "$temp_json"
    
    if [[ $curl_exit_code -eq 0 ]]; then
        if [[ -z "$response" ]]; then
            log_error "API call succeeded but returned an empty response."
            return 1
        fi

        log_debug "API call succeeded with a non-empty response."
        
        # Parse response
        if command -v jq &> /dev/null; then
            GEMINI_RESPONSE=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // ""' 2>/dev/null)
            
            # Check for API errors
            local error_message
            error_message=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
            if [[ -n "$error_message" ]]; then
                log_error "API returned error: $error_message"
                return 1
            fi
        else
            # Fallback parsing without jq
            GEMINI_RESPONSE=$(echo "$response" | grep -o '"text":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\\n/\n/g')
            
            # Check for errors without jq
            if echo "$response" | grep -q '"error"'; then
                log_error "API returned an error"
                return 1
            fi
        fi
        
        if [[ -z "$GEMINI_RESPONSE" ]]; then
            log_warning "Could not parse a valid response from the API output."
            # We don't return 1 here, as it might be a valid empty response.
            # The calling function should handle empty results.
        fi

        log_debug "Parsed API response: ${GEMINI_RESPONSE:0:200}..."
        return 0
    else
        log_error "API call failed with exit code: $curl_exit_code"
        log_debug "Error response: ${response:0:200}..."
        
        case $curl_exit_code in
            7) log_error "Failed to connect to host - connection refused" ;;
            6) log_error "Couldn't resolve host" ;;
            28) log_error "Operation timeout" ;;
            35) log_error "SSL connection error" ;;
            *) log_error "Unknown curl error (exit code: $curl_exit_code)" ;;
        esac
        
        return 1
    fi
}

#=================================== OpenAI API Call
call_openai_api() {
    log_info "Calling OpenAI API"
    
    # Encode image to base64
    local image_base64
    image_base64=$(base64 -w 0 "$image_path")
    
    if [[ -z "$image_base64" ]]; then
        log_error "Failed to encode image to base64"
        return 1
    fi
    
    log_debug "Image base64 length: ${#image_base64} characters"
    
    # Use temp file approach to avoid "Argument list too long" error
    log_debug "Calling API: ${OPENAI_API_ENDPOINT}"
    
    # Create temporary JSON file to avoid command line length limits
    local temp_json
    temp_json=$(mktemp)

    # Use jq to build the JSON payload if available, otherwise use sed for escaping
    if command -v jq &> /dev/null; then
        log_debug "Using jq with temp files to build JSON payload and avoid argument length issues"
        
        # Create temp files for the prompt to avoid passing large strings as arguments
        local prompt_file
        prompt_file=$(mktemp)
        echo -n "$COMBINED_PROMPT" > "$prompt_file"

        local image_file
        image_file=$(mktemp)
        echo -n "$image_base64" > "$image_file"

        # Use --rawfile to read the raw content of the files into jq variables
        # This is the most robust method for handling large, arbitrary strings
        jq -n \
          --rawfile prompt_text "$prompt_file" \
          --rawfile image_data "$image_file" \
          '{
            "model": "gpt-4o",
            "messages": [{
                "role": "user",
                "content": [
                    {"type": "text", "text": $prompt_text},
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": ("data:image/jpeg;base64," + $image_data),
                            "detail": "low"
                        }
                    }
                ]
            }],
            "max_tokens": 512,
            "temperature": 0.2
        }' > "$temp_json"

        # Clean up the temporary data files immediately after use
        rm -f "$prompt_file" "$image_file"

    else
        log_debug "Using sed to build JSON payload"
        # Fallback to manual JSON creation with sed escaping
        local escaped_prompt
        escaped_prompt=$(echo "$COMBINED_PROMPT" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/\\n/g')
        cat > "$temp_json" << EOF
{
    "model": "gpt-4o",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "$escaped_prompt"},
            {
                "type": "image_url",
                "image_url": {
                    "url": "data:image/jpeg;base64,$image_base64",
                    "detail": "low"
                }
            }
        ]
    }],
    "max_tokens": 512,
    "temperature": 0.2
}
EOF
    fi
    
    # Curl call using temp file
    local response
    log_debug "About to call curl with temp file: $temp_json"
    log_debug "Temp file size: $(wc -c < "$temp_json" 2>/dev/null || echo "unknown") bytes"
    
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -d @"$temp_json" \
        "${OPENAI_API_ENDPOINT}" \
        --connect-timeout 30 \
        --max-time 120 2>&1)
    
    local curl_exit_code=$?
    log_debug "Curl completed with exit code: $curl_exit_code"
    
    # Log the raw response for debugging
    log_debug "--- RAW API RESPONSE START ---"
    log_debug "$response"
    log_debug "--- RAW API RESPONSE END ---"
    
    # Clean up temp file immediately
    rm -f "$temp_json"
    
    if [[ $curl_exit_code -eq 0 ]]; then
        if [[ -z "$response" ]]; then
            log_error "API call succeeded but returned an empty response."
            return 1
        fi

        log_debug "API call succeeded with a non-empty response."
        
        # Parse response
        if command -v jq &> /dev/null; then
            OPENAI_RESPONSE=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
            
            # Check for API errors
            local error_message
            error_message=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
            if [[ -n "$error_message" ]]; then
                log_error "API returned error: $error_message"
                return 1
            fi
        else
            # Fallback parsing without jq
            OPENAI_RESPONSE=$(echo "$response" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\\n/\n/g')
            
            # Check for errors without jq
            if echo "$response" | grep -q '"error"'; then
                log_error "API returned an error"
                return 1
            fi
        fi
        
        if [[ -z "$OPENAI_RESPONSE" ]]; then
            log_warning "Could not parse a valid response from the API output."
            # We don't return 1 here, as it might be a valid empty response.
            # The calling function should handle empty results.
        fi

        log_debug "Parsed API response: ${OPENAI_RESPONSE:0:200}..."
        return 0
    else
        log_error "API call failed with exit code: $curl_exit_code"
        log_debug "Error response: ${response:0:200}..."
        
        case $curl_exit_code in
            7) log_error "Failed to connect to host - connection refused" ;;
            6) log_error "Couldn't resolve host" ;;
            28) log_error "Operation timeout" ;;
            35) log_error "SSL connection error" ;;
            *) log_error "Unknown curl error (exit code: $curl_exit_code)" ;;
        esac
        
        return 1
    fi
}

#=================================== Response Processing
parse_and_save_results() {
    log_debug "Parsing API response"
    
    # Initialize answers array
    PARSED_ANSWERS=()
    for ((i=0; i<PROMPT_COUNT; i++)); do
        PARSED_ANSWERS[$i]=""
    done
    
    # Parse numbered responses
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)\.[[:space:]]*(.*) ]]; then
            local answer_num="${BASH_REMATCH[1]}"
            local answer_text="${BASH_REMATCH[2]}"
            
            log_debug "Found answer $answer_num: ${answer_text:0:100}..."
            
            if [[ $answer_num -gt 0 && $answer_num -le $PROMPT_COUNT ]]; then
                PARSED_ANSWERS[$((answer_num-1))]="$answer_text"
            fi
        fi
    done <<< "$AI_RESPONSE"
    
    # Fill missing answers
    for ((i=0; i<PROMPT_COUNT; i++)); do
        if [[ -z "${PARSED_ANSWERS[$i]:-}" ]]; then
            PARSED_ANSWERS[$i]="Pas de réponse pour la question $((i+1))"
        fi
    done
    
    log_debug "Parsed ${#PARSED_ANSWERS[@]} answers"
    
    # Save results to file
    printf '%s\n' \
        "# AI Analysis Results" \
        "# Generated: $(date)" \
        "# Image: $image_path" \
        "# Camera: $camera_short" \
        "# Device ID: $DEVICE_ID" \
        "" > "$RESULT_FILE"
    
    for ((i=0; i<PROMPT_COUNT; i++)); do
        printf '%s\n' \
            "[${PROMPT_NAMES[i]:-Question $((i+1))}]" \
            "sensor_name: ${SENSOR_NAMES[i]:-camera_$((i+1))}" \
            "prompt: ${PROMPT_TEXTS[i]:-Question $((i+1))}" \
            "result: ${PARSED_ANSWERS[$i]:-Erreur de parsing}" \
            "" >> "$RESULT_FILE"
    done
    
    log_info "Results saved to: $RESULT_FILE"
    return 0
}

#=================================== MQTT Publishing
check_config_sent_today() {
    local sensor_name="$1"
    local cache_dir="${cs_cache}/mqtt_configs"
    local today=$(date +%j) # Day of year (1-366)
    local cache_file="${cache_dir}/${sensor_name}_config_sent"
    
    mkdir -p "$cache_dir"
    
    if [[ -f "$cache_file" ]]; then
        local last_sent_day=$(cat "$cache_file" 2>/dev/null || echo "0")
        if [[ "$last_sent_day" == "$today" ]]; then
            log_debug "Config already sent today for sensor: $sensor_name (day $today)"
            return 0 # Already sent today
        fi
    fi
    
    log_debug "Config not sent today for sensor: $sensor_name (day $today)"
    return 1 # Not sent today
}

mark_config_sent_today() {
    local sensor_name="$1"
    local cache_dir="${cs_cache}/mqtt_configs"
    local today=$(date +%j) # Day of year (1-366)
    local cache_file="${cache_dir}/${sensor_name}_config_sent"
    
    mkdir -p "$cache_dir"
    echo "$today" > "$cache_file"
    log_debug "Marked config as sent today for sensor: $sensor_name (day $today)"
}

force_config_republish() {
    local sensor_name="$1"
    local cache_dir="${cs_cache}/mqtt_configs"
    local cache_file="${cache_dir}/${sensor_name}_config_sent"
    
    if [[ -f "$cache_file" ]]; then
        rm -f "$cache_file"
        log_debug "Cleared config cache for sensor: $sensor_name (forced republish)"
    fi
}

publish_mqtt_messages() {
    if ! command -v mosquitto_pub &> /dev/null; then
        log_warning "mosquitto_pub not available, skipping MQTT publishing"
        return 0
    fi
    
    log_info "Publishing MQTT messages"
    log_debug "MQTT connection details: Host=$MQTT_HOST, Port=$MQTT_PORT, User=$MQTT_USER"
    
    local base_topic="homeassistant/sensor"
    local config_published=0
    local config_skipped=0
    local state_published=0
    
    for ((i=0; i<PROMPT_COUNT; i++)); do
        local sensor_name="${SENSOR_NAMES[i]:-camera_$((i+1))}"
        local prompt_name="${PROMPT_NAMES[i]:-Question $((i+1))}"
        local device_class="${DEVICE_CLASSES[i]:-text}"
        local analysis_result="${PARSED_ANSWERS[i]:-Pas de réponse}"
        
        log_debug "Processing sensor $((i+1))/$PROMPT_COUNT: $sensor_name"
        
        # Config message (only once per day, unless CS_MQTT_DEBUG is set)
        local config_topic="${base_topic}/${sensor_name}/config"
        local config_payload
        config_payload=$(create_config_payload "$sensor_name" "$prompt_name" "$device_class" "$camera_short" "$DEVICE_ID")
        
        # Force republish if debug mode is enabled
        if [[ "${CS_MQTT_DEBUG:-}" == "true" ]]; then
            force_config_republish "$sensor_name"
        fi
        
        if check_config_sent_today "$sensor_name"; then
            log_debug "Skipping config for $sensor_name - already sent today"
            ((config_skipped++))
        else
            log_info "Publishing config to: $config_topic"
            log_debug "Config payload: $config_payload"
            
            if mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
                             -t "$config_topic" -m "$config_payload" -r; then
                ((config_published++))
                mark_config_sent_today "$sensor_name"
                log_info "✓ Config published successfully for sensor: $sensor_name"
            else
                log_error "✗ Failed to publish config for sensor: $sensor_name"
            fi
        fi
        
        # State message (always sent)
        local state_topic="${base_topic}/${sensor_name}/state"
        
        log_info "Publishing state to: $state_topic"
        log_debug "State payload: $analysis_result"
        log_debug "Actual state topic for $sensor_name: $state_topic"
        
        if mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
                         -t "$state_topic" -m "$analysis_result"; then
            ((state_published++))
            log_info "✓ State published successfully for sensor: $sensor_name"
        else
            log_error "✗ Failed to publish state for sensor: $sensor_name"
        fi
    done
    
    log_info "MQTT publishing completed: $config_published/$PROMPT_COUNT configs published, $config_skipped skipped, $state_published/$PROMPT_COUNT states"
    return 0
}

create_config_payload() {
    local sensor_name="$1"
    local prompt_name="$2"
    local device_class="$3"
    local camera_short="$4"
    local device_id="$5"
    
    local config_payload
    # Original version with device_class (commented out for troubleshooting):
    # config_payload=$(printf '{\n  "name": "Camera AI %s - %s",\n  "state_topic": "homeassistant/sensor/%s/state",\n  "unique_id": "%s_%s",\n  "unit_of_measurement": "",\n  "device_class": "%s",\n  "device": {\n    "identifiers": ["%s"],\n    "name": "Camera AI Device %s",\n    "manufacturer": "casasmooth",\n    "model": "AI Camera Device"\n  },\n  "origin": {\n    "name": "casasmooth",\n    "sw": "2.1.0",\n    "url": "https://www.casasmooth.com"\n  }\n}' \
    #     "$camera_short" "$prompt_name" "$sensor_name" "$device_id" "$sensor_name" "$device_class" "$device_id" "$camera_short")
    
    # New version without device_class for better compatibility:
    config_payload=$(printf '{\n  "name": "CS - Synthetic AI sensor based on camera %s, prompt %s",\n  "state_topic": "homeassistant/sensor/%s/state",\n  "unique_id": "%s_%s",\n  "unit_of_measurement": "",\n  "device": {\n    "identifiers": ["%s"],\n    "name": "Camera AI Device %s",\n    "manufacturer": "casasmooth",\n    "model": "AI Camera Device"\n  },\n  "origin": {\n    "name": "casasmooth",\n    "sw": "2.1.0",\n    "url": "https://www.casasmooth.com"\n  }\n}' \
        "$camera_short" "$prompt_name" "$sensor_name" "$device_id" "$sensor_name" "$device_id" "$camera_short")
    
    log_debug "Config state_topic for $sensor_name: homeassistant/sensor/$sensor_name/state"
    echo "$config_payload"
}

#=================================== Local Execution
execute_local_analysis() {
    log_info "Starting local AI analysis for camera: $camera_short"
    
    # Setup paths
    mkdir -p "${cs_locals}/image_ai"
    MANIFEST_FILE="${cs_locals}/image_ai/${camera_short}.yaml"
    MANIFEST_INFO_FILE="${image_path}.yaml"
    RESULT_FILE="${image_path}.llm"
    PROMPT_FILE="${image_path}.prompt"
    DEVICE_ID="${csuuid}_${entity_id}"
    
    # Log which AI provider is being used
    log_info "Using AI provider: ${IMAGE_AI_PROVIDER}"
    
    # Load AI provider secrets based on selection
    if [[ "$IMAGE_AI_PROVIDER" == "gemini" ]]; then
        # Load Gemini secrets
        if ! GEMINI_API_KEY=$(extract_secret "GEMINI_API_KEY"); then
            log_error "Failed to extract GEMINI_API_KEY secret"
            exit 1
        fi
        
        if ! GEMINI_API_ENDPOINT=$(extract_secret "GEMINI_API_ENDPOINT"); then
            log_error "Failed to extract GEMINI_API_ENDPOINT secret"
            exit 1
        fi

        if [[ -z "$GEMINI_API_KEY" || -z "$GEMINI_API_ENDPOINT" ]]; then
            log_error "GEMINI_API_KEY or GEMINI_API_ENDPOINT not configured"
            exit 1
        fi
        
        log_debug "Gemini API endpoint: ${GEMINI_API_ENDPOINT}"
        log_debug "Gemini API key length: ${#GEMINI_API_KEY} characters"
        
    elif [[ "$IMAGE_AI_PROVIDER" == "openai" ]]; then
        # Load OpenAI secrets
        if ! OPENAI_API_KEY=$(extract_secret "OPENAI_API_KEY" "true"); then
            log_error "Failed to extract OPENAI_API_KEY secret"
            exit 1
        fi
        
        if ! OPENAI_API_ENDPOINT=$(extract_secret "OPENAI_API_ENDPOINT"); then
            log_error "Failed to extract OPENAI_API_ENDPOINT secret"
            exit 1
        fi

        if [[ -z "$OPENAI_API_KEY" || -z "$OPENAI_API_ENDPOINT" ]]; then
            log_error "OPENAI_API_KEY or OPENAI_API_ENDPOINT not configured"
            exit 1
        fi
        
        log_debug "OpenAI API endpoint: ${OPENAI_API_ENDPOINT}"
        log_debug "OpenAI API key length: ${#OPENAI_API_KEY} characters"
        
    else
        log_error "Invalid IMAGE_AI_PROVIDER: $IMAGE_AI_PROVIDER. Must be 'gemini' or 'openai'"
        exit 1
    fi
    
    # Load MQTT configuration and add validation
    log_info "Loading MQTT configuration from secrets..."
    MQTT_HOST=$(extract_secret "MQTT_LOCAL_URL")
    MQTT_PORT=$(extract_secret "MQTT_LOCAL_PORT")
    MQTT_USER=$(extract_secret "MQTT_LOCAL_USERNAME")
    MQTT_PASS=$(extract_secret "MQTT_LOCAL_PASSWORD")

    if [[ -z "$MQTT_HOST" || -z "$MQTT_PORT" ]]; then
        log_error "MQTT_LOCAL_URL or MQTT_LOCAL_PORT not configured in secrets. Cannot publish."
        exit 1
    fi

    log_info "MQTT Host: ${MQTT_HOST}"
    log_info "MQTT Port: ${MQTT_PORT}"
    log_info "MQTT User: ${MQTT_USER}"
    log_info "MQTT Pass length: ${#MQTT_PASS} characters"

    # Create manifest if needed
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        log_info "Creating default manifest for camera: $camera_short"
        create_default_manifest "$camera_short" "$MANIFEST_FILE" "$csuuid" "$entity_id"
    fi
    
    # Load manifest
    local load_result
    load_manifest "$MANIFEST_FILE" "$camera_short"
    load_result=$?
    
    if [[ $load_result -eq 2 ]]; then
        log_info "AI analysis skipped - manifest is disabled for camera: $camera_short"
        log_info "To enable, set 'active: true' in manifest: $MANIFEST_FILE"
        exit 0  # Exit successfully but without processing
    elif [[ $load_result -ne 0 ]]; then
        log_error "Failed to load manifest: $MANIFEST_FILE"
        exit 1
    fi
    
    # Copy manifest info
    cp "$MANIFEST_FILE" "$MANIFEST_INFO_FILE" 2>/dev/null || true

    # Build prompt
    if ! build_combined_prompt; then
        log_error "Failed to build combined prompt"
        exit 1
    fi
    
    # Call appropriate AI API based on provider
    log_info "Calling ${IMAGE_AI_PROVIDER} API for image analysis"
    if [[ "$IMAGE_AI_PROVIDER" == "gemini" ]]; then
        if ! call_gemini_api; then
            log_error "Failed to call Gemini API"
            exit 1
        fi
        AI_RESPONSE="$GEMINI_RESPONSE"
    elif [[ "$IMAGE_AI_PROVIDER" == "openai" ]]; then
        if ! call_openai_api; then
            log_error "Failed to call OpenAI API"
            exit 1
        fi
        AI_RESPONSE="$OPENAI_RESPONSE"
    else
        log_error "Invalid IMAGE_AI_PROVIDER: $IMAGE_AI_PROVIDER"
        exit 1
    fi
    
    # Process results
    if ! parse_and_save_results; then
        log_error "Failed to parse and save results"
        exit 1
    fi
    
    # Publish to MQTT
    if ! publish_mqtt_messages; then
        log_error "Failed to publish MQTT messages"
        exit 1
    fi
    
    log_info "Local AI analysis completed successfully"
}

#=================================== Main Execution
if [[ "$execution_mode" == "remote" ]]; then
    execute_remote_analysis
else
    execute_local_analysis
fi
