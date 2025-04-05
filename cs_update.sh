#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 0.2.10.12
#
# Launches local or remote update of casasmooth 
#
#=================================== Update the git repo to make sure that we run the last version, restart the script if needed

    cd "/config/casasmooth" >/dev/null 2>&1
    temp_log="$(basename ${0%.*}).log"

    if [[ -z "$SCRIPT_RESTARTED" ]]; then
        : > "${temp_log}" 
    fi

    trace() { 
        printf "%s %s: $1\n" "$0" "$(date '+%Y-%m-%d %H:%M:%S')" | tee -a "${temp_log}"
    }

    timestamp_before=$(stat -c %Y "$(basename ${0})" 2>/dev/null)
    trace "Updating casasmooth sources"
    git fetch origin main && git reset --hard origin/main 2>&1
    timestamp_after=$(stat -c %Y "$(basename ${0})" 2>/dev/null)

    if [[ "$timestamp_before" -lt "$timestamp_after" ]]; then
        export SCRIPT_RESTARTED=true
        trace "$(basename ${0}) source has been updated, restarting the script"
        exec "./$(basename ${0})" "$@"
        trace "CRITICAL: Failed to restart $(basename ${0%.*})"
        exit 0
    fi

    chmod +x commands/*.sh >/dev/null 2>&1

#=================================== Include cs_library

    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        trace "ERROR: Failed to source ${include}"
        exit 1
    fi

#=================================== Concurrency management

    trace "Set lock"
    cs_update_lock_file="${cs_path}/cs_update.lock"

    # Function to remove the lock file
    remove_cs_update_lock_file() {
        if [ -f "$cs_update_lock_file" ]; then
            trace "Reset lock"
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
        trace "Script is already running"
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

    production=true
    cloud=true
    remoting=false

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
        remote_update=true
    fi

    ha_present="true"
    if [[ ! -f "${hass_path}/.storage/core.entity_registry" ]]; then
        ha_present="false"
    fi

#----- Update process

    if [[ "$remote_update" == "false" ]]; then

        #----- We are on a system running HASS, we do a local update

        if [[ "$(lib_update_required)" == "false" ]]; then
            trace "casasmooth local update is not required."
            exit 0
        else
            trace "Update casasmooth locally starting as a detached process..."
            timeout "30m" setsid bash "${cs_lib}/cs_update_casasmooth.sh" "${forward_args[@]}" --log --verbose > /dev/null 2>&1 &
        fi
    
    else

        #----- Setup the environment to be able to execute all remoting interactions with Azure

            BLOB_SERVICE=$(extract_secret "BLOB_SERVICE")
            UPDATE_SAS_TOKEN=$(extract_secret "UPDATE_SAS_TOKEN")

        #----- Check to see if this system is running on HASS

        if [[ "$ha_present" == "true" ]]; then

            #----- We are on a system running HASS

                if [[ "$(lib_update_required)" == "false" ]]; then
                    trace "casasmooth remote update is not required."
                    exit 0
                else
                    trace "Update casasmooth remote starting as a detached process..."
                    timeout "30m" setsid bash "${cs_lib}/cs_update_client.sh" "${forward_args[@]}" --log --verbose > /dev/null 2>&1 &
                fi

        else

            #----- We are on a system without HASS, probably a VM, a container, or a terminal, this means that we dont have timeout problems induced by hass

                if [[ -z "${guid_to_process:-}" ]]; then
                    trace "guid_to_process is required for remoting, exiting..."
                    exit 1
                fi

                guid="${guid_to_process}"

                data_file="dta_${guid}.tar.gz"
                result_file="res_${guid}.tar.gz"

                trace "Starting client update process"
            
            #----- We are in an empty container, we need to process the data file that was uploaded for us but is it ready?

                found=false
                timeout_seconds=600
                poll_interval=5
                elapsed=0
                while [ "$elapsed" -lt "$timeout_seconds" ]; do
                    # Attempt to download the file and capture the HTTP status code
                    http_code=$(curl --silent --show-error --output "${cs_temp}/${data_file}" --write-out "%{http_code}" "${BLOB_SERVICE}/update/${data_file}?${UPDATE_SAS_TOKEN}")
                    if [ "$http_code" = "200" ]; then
                        found=true
                        trace "Data file found"
                        break
                    elif [ "$http_code" = "404" ]; then
                        trace "Not yet available, wait for ${poll_interval} seconds"
                    else
                        trace "Request failed, wait for ${poll_interval} seconds"
                    fi
                    sleep "$poll_interval"
                    elapsed=$((elapsed + poll_interval))
                done
                if [ "$elapsed" -ge "$timeout_seconds" ]; then
                    trace "Polling timeout reached, no file found"
                    exit 1
                fi
                if [[ "$found" != "true" ]]; then
                    trace "No file found"
                    exit 1
                fi

            #----- Extract the data tar file

                trace "Extracting data"
                tar -xzf "${cs_temp}/${data_file}" -C / > /dev/null 2>&1
                rm -f "${cs_temp}/${data_file}"

            #----- Do the update with the update data

                trace "Launch casasmooth update"
                rm -f "${cs_logs}/cs_update_casasmooth.lock" 
                rm -f "${cs_logs}/cs_update_casasmooth.log" 
                bash "${cs_lib}/cs_update_casasmooth.sh" "${forward_args[@]}" --log --verbose # > /dev/null 2>&1 &
                if [ $? -ne 0 ]; then
                    trace "**************** CRITICAL: cs_update_casasmooth.sh failed!"
                    exit 1
                fi

            #----- Collect the results

                tarlist="${cs_temp}/cs_tarlist.txt"
                > "$tarlist"

                add_to_tarlist() {
                    local file="$1"
                    if [ -e "$file" ]; then
                        echo "$file" >> "$tarlist"
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

                add_to_tarlist "/config/casasmooth/locals/cs_registry_data.sh"

                add_to_tarlist "/config/casasmooth/lib/cs_library.sh"
                add_to_tarlist "/config/casasmooth/lib/.cs_secrets.yaml"

                find /config/casasmooth/commands -type f -print0 | while IFS= read -r -d $'\0' file; do
                    add_to_tarlist "$file"
                done

                add_to_tarlist "/config/casasmooth/logs/cs_inventory.csv"
                add_to_tarlist "/config/casasmooth/logs/cs_inventory.txt"
                add_to_tarlist "/config/casasmooth/logs/cs_update_casasmooth.log"

                add_to_tarlist "/config/www/cs_update_casasmooth.txt"

                trace "Collecting results"
                tar -czf "${cs_temp}/${result_file}" -T "$tarlist" > /dev/null 2>&1

            #----- Send the result file to the storage account

                trace "Uploading results to blob"

                response=$(curl -s -w "\n%{http_code}" -X PUT -H "x-ms-blob-type: BlockBlob" --data-binary @"${cs_temp}/${result_file}" "${BLOB_SERVICE}/update/${result_file}?${UPDATE_SAS_TOKEN}")

                http_code=$(echo "$response" | tail -n1)
                response_body=$(echo "$response" | sed '$d')

                if [ "$http_code" -ne "201" ]; then
                    trace "Failed to upload results"
                    exit 1
                fi

            #----- No need to cleanup the container as it is ephemeral
            trace "Update done"

        fi

    fi

    rm -f $cs_update_lock_file

    exit 0