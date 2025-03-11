#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 1.1.17.3
#
# Library function for casasmooth scripts
#
#---------- Check if the script is run directly
    if [[ "$0" == "$BASH_SOURCE" ]]; then 
        echo "ERROR: $0 can not be run directly"
        exit 1
    fi

#----- System wide bash settings

    # Enables case-insensitive matching
    shopt -s nocasematch  
    # Enable extended globbing and nullglob for safer array handling
    shopt -s extglob nullglob

    # Allows you to handle errors instead of immediate exit, leave it commented!!!
    #set -e 

    # Reports if any command in a pipe fails, not just the last one
    set -o pipefail 

    # Makes the script report unset variables instead of silently using empty strings
    set -u

    # Enable additional info for debug
    export PS4='[${BASH_SOURCE}:${LINENO}] '

    # Record script start time with high precision
    script_start_time=$(date +%s)
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Initialize script name
    script_name="${0##*/}"
    script_name="${script_name%.sh}"

    # Define log directories and files, as some function require logging even before we loaded the paths...
    cs_logs="/config/casasmooth/logs"
    mkdir -p "$cs_logs"
    log_file="${cs_logs}/${script_name}.log"
    rm -f "$log_file"

#----- Check if commands exists
    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }

    for cmd in jq grep awk sed; do
        if ! command_exists "$cmd"; then
            echo "Required command '${cmd}' is not installed." >&2
            exit 1
        fi
    done

#----- Ensure the script runs with Bash version 4.2 or higher
    if ((BASH_VERSINFO[0] < 4)) || { ((BASH_VERSINFO[0] == 4)) && ((BASH_VERSINFO[1] < 2)); }; then
        echo "This script requires Bash version 4.2 or higher." >&2
        exit 1
    fi

#----- Logging 

    # Default logging configurations
    logger=false
    debug=false
    verbose=false

    # Predefined log level prefixes
    declare -A LOG_PREFIX=(
        ["ERROR"]="[ERR]"
        ["DEBUG"]="[DEB]"
        ["SUCCESS"]="[SUC]"
        ["WARNING"]="[WAR]"
        ["INFO"]="[INF]"
        ["TRACE"]="[TRA]"
    )

    log_message() {
        local level="$1"
        shift

        # Handle DEBUG level separately
        if [[ "$level" == "DEBUG" && "$debug" != "true" ]]; then
            return
        fi

        # Exit early if neither logger nor verbose is enabled
        if [[ "$logger" != "true" && "$verbose" != "true" ]]; then
            return
        fi

        # Generate timestamp once
        local timestamp
        timestamp=$(printf "%(%d.%m.%Y %H:%M:%S)T" -1)

        # Construct the log message (No Color)
        local message="${script_name} ${LOG_PREFIX[$level]} ${timestamp} $*"

        # Log to file
        if [[ "$logger" == "true" ]]; then
            printf "%s\n" "$message" >> "$log_file"
        fi

        # Output to stdout
        if [[ "$verbose" == "true" ]]; then
            printf "%s\n" "$message"
        fi
    }

    log()         { log_message "TRACE"   "$@"; }
    log_error()   { log_message "ERROR"   "$@"; }
    log_debug()   { log_message "DEBUG"   "$@"; }
    log_success() { log_message "SUCCESS" "$@"; }
    log_warning() { log_message "WARNING" "$@"; }
    log_info()    { log_message "INFO"    "$@"; }
    log_trace()   { log_message "TRACE"   "$@"; }

    error_exit() {
        log_error "$@"
        exit 1
    }

#----- Configuration in secrets and others
    #----- Extract functions

        extract_key() {
            local config_file="$1"
            local key="$2"
            local value

            # Check if the secrets file is provided
            if [[ -z "$config_file" ]]; then
                log_error "No file provided."
                echo ""
                return 1
            fi

            # Check if the secrets file exists and is readable
            if [[ ! -f "$config_file" ]]; then
                log_error "File '${config_file}' does not exist."
                echo ""
                return 1
            fi
            if [[ ! -r "$config_file" ]]; then
                log_error "File '${config_file}' is not readable. Check permissions."
                echo ""
                return 1
            fi

            # Use awk to extract the value, handling both quoted and unquoted values
            value=$(awk -F': ' "/^${key}:/ {gsub(/^\"|\"$/, \"\", \$2); print \$2}" "$config_file")

            # Check if the value was found
            if [[ -z "$value" ]]; then
                log_error "Failed to extract value for key '${key}' from '${config_file}'."
                echo ""
                return 1
            fi

            echo "$value"
            return 0
        }

        # Function to extract secrets using the extract_key function
        extract_secret() {
            local key="$1"
            local secrets_file="/config/casasmooth/lib/.cs_secrets.yaml"
            
            # Extract the value using extract_key
            local value
            value=$(extract_key "$secrets_file" "$key")
            local status=$?

            # Return the value and status
            echo "$value"
            return $status
        }

    #----- Extract Paths 
        hass_path=$(extract_secret "hass_path") || exit 1
        cs_path=$(extract_secret "cs_path") || exit 1

    #----- Initialize Paths 
        cs_cache="${cs_path}/cache"
        cs_temp="${cs_path}/temp"
        cs_templates="${cs_path}/templates"
        cs_dashboards="${cs_path}/dashboards"
        cs_images="${cs_path}/images"
        cs_texts="${cs_path}/texts"
        cs_commands="${cs_path}/commands"
        cs_etc="${cs_path}/etc"
        cs_lib="${cs_path}/lib"
        cs_logs="${cs_path}/logs"
        cs_resources="${cs_path}/resources"
        cs_medias="${cs_path}/medias"
        cs_locals="${cs_path}/locals"

        mkdir -p "$cs_cache" "$cs_temp" "$cs_templates" "$cs_dashboards" "$cs_images" "$cs_medias" "$cs_resources" "$cs_commands" "$cs_etc" "$cs_lib" "$cs_logs" "$cs_locals"

        # May change! Should not!
        log_file="${cs_logs}/${script_name}.log"

    #----- Grab guid from hass
        guid=$(jq -r '.data.uuid' "${hass_path}/.storage/core.uuid" 2>/dev/null) || true
        if [[ -z "$guid" ]]; then
            echo "Failed to retrieve guid from ${hass_path}/.storage/core.uuid. Ensure the file exists and contains the correct JSON structure."
        fi

#----- File management
    safe_copy() {
        # Check that exactly two arguments are provided.
        if [ "$#" -ne 2 ]; then
            log_error "safe_copy requires exactly two arguments: source and destination."
            return 1
        fi

        local src="$1"
        local dest="$2"

        # Check if the source exists and whether it is a directory or a file.
        if [[ -d "$src" ]]; then
            # Source is a directory: copy recursively.
            if cp -r "$src" "$dest"; then
                log_info "Successfully copied directory '$src' to '$dest'."
            else
                log_error "Failed to copy directory '$src' to '$dest'."
                return 1
            fi
        elif [[ -f "$src" ]]; then
            # Source is a file: perform a standard copy.
            if cp "$src" "$dest"; then
                log_info "Successfully copied file '$src' to '$dest'."
            else
                log_error "Failed to copy file '$src' to '$dest'."
                return 1
            fi
        else
            # Source does not exist.
            log_warning "Source '$src' does not exist. Operation skipped."
            return 1
        fi
        }

#----- Function to URL-encode a string
    url_encode() {
        local string="${1}"
        local encoded=""
        local length="${#string}"
        for (( i = 0; i < length; i++ )); do
            local c="${string:i:1}"
            case "${c}" in
                [a-zA-Z0-9.~_-]) encoded+="${c}" ;;
                *) encoded+=$(printf '%%%02X' "'${c}") ;;
            esac
        done
        echo "${encoded}"
    }

#----- Debugging
    set_debug(){
        local option=$1
        case "$option" in
            "on")
                set -x
                #trap - DEBUG  # Clear existing DEBUG traps
                #trap 'echo "TRACE: $BASH_COMMAND"' DEBUG
                log_info "Debugging enabled."
                ;;
            "off")
                set +x
                #trap - DEBUG
                log_info "Debugging disabled."
                ;;
            *)
                log_error "Wrong option used for set_debug: $option"
                return 1
                ;;
        esac
    }
#----- Helpers

    # trim: Removes leading and trailing whitespace from a string.
        lib_trim() {
            local text="${1:-}"
            text="${text#"${text%%[![:space:]]*}"}"  # Remove leading whitespace
            text="${text%"${text##*[![:space:]]}"}"    # Remove trailing whitespace
            printf '%s' "$text"
        }

    # escape_pattern: Escapes special characters in a string for safe use in `sed` patterns.
        lib_escape_pattern() {
            local text="$1"
            sed -E 's/([][\\^.$*+?/~()])/\\\1/g' <<< "$text"
        }

#----- Standard way to include other sources
    include_source(){
        local source_file=$1
        if [[ ! -f "${source_file}" ]]; then 
            log_error "File not found: ${source_file}"
            exit 1
        fi
        if ! source "${source_file}"; then
            log_error "Failed to source ${source_file}"
            exit 1
        fi
    }

#----- Analyze if update is required
    lib_get_newest_timestamp() {
        local files=("$@")
        local newest_timestamp=0 # Initialize to epoch time (or earlier if needed)
        local early_timestamp=$(date -d "1970-01-01" +%s) # Get epoch timestamp

        newest_timestamp=$early_timestamp # Default to early timestamp if no file exists

        for file in "${files[@]}"; do
            if [ -f "$file" ]; then
            file_timestamp=$(stat -c %Y "$file" 2>/dev/null) # Get modification timestamp in seconds since epoch
            if [ -n "$file_timestamp" ]; then # Check if stat returned a valid timestamp
                if [ "$file_timestamp" -gt "$newest_timestamp" ]; then
                    newest_timestamp=$file_timestamp
                fi
            fi
            fi
        done
        echo "$newest_timestamp"
    }

    lib_update_required() {
        local hass_timestamp=$(lib_get_newest_timestamp "${hass_path}/core.config" "${hass_path}/core.area_registry" "${hass_path}/core.device_registry" "${hass_path}/core.entity_registry" )
        local cs_timestamp=$(lib_get_newest_timestamp "${cs_dashboards}/cs-home/cs_dashboard.yaml" "${cs_commands}/cs_update_casasmooth.sh" "${cs_path}/cs_update.sh" )
        log_debug "Hass timestamp: $hass_timestamp"
        log_debug "CS timestamp: $cs_timestamp"
        if [[ "$hass_timestamp" -ge "$cs_timestamp" ]]; then
            echo "true"
        else
            echo "false"
        fi
    }   

