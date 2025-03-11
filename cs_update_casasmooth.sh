#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
casasmooth_version="1.2.4.7"
update_version="1.1.50.6"
#
# This script generates the casasmooth dashboard and views calling the various views files. It orchestrates the whole setup of the casasmooth system.
#
#=================================== Update the repository to make sure that we run the last version (even in a sub/detached process)

    cd "/config/casasmooth" >/dev/null 2>&1
    git pull origin main >/dev/null 2>&1
    chmod +x commands/*.sh >/dev/null 2>&1

#=================================== Include cs_library

    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi

    if [[ "$(lib_update_required)" == "false" ]]; then
        logger=true
        verbose=true
        log "casasmooth update has not been determined to be required."
        exit 0
    fi

#=================================== Concurrency management

    cs_update_casasmooth_lock_file="${cs_path}/cs_update_casasmooth.lock"

    # Function to remove the lock file
    remove_cs_update_casasmooth_lock_file() {
        if [ -f "$cs_update_casasmooth_lock_file" ]; then
            log "Removing lock file ${cs_update_casasmooth_lock_file}"
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
        echo "Script is already running (lock is held on $cs_update_casasmooth_lock_file). Exiting."
        exit 1
    fi

#=================================== Register guid/heartbeat
    bash "${cs_commands}/cs_register_guid.sh"
#=================================== Include cs_translation
    include_source "${cs_lib}/cs_translation.sh"
#=================================== Include cs_entities
    include_source "${cs_lib}/cs_entities.sh"
#=================================== Include cs_registry
    include_source "${cs_lib}/cs_registry.sh"
#=================================== Parse command-line arguments

    usage() {
        echo "Usage: $0 [OPTIONS] [--] [files...]"
        echo ""
        echo "Options:"
        echo "  --debug          Enable debug output"
        echo "  --verbose        Enable verbose output"
        echo "  --log            Enable logging"
        echo "  --noinstall      Do not install generated code"
        echo "  --notranslation  Disable translation"
        echo "  --reload         Reload the full registries"
        echo "  --cleanup        Perform cleanup of registry and other elements"
        echo "  --virtuals       Enable virtual dashboard"
        echo "  --test           Enable test mode"
        echo "  --help           Display this help message"
        echo ""
        echo "The '--' argument separates options from filenames. This is useful"
        echo "if filenames might start with a dash ('-')."
        echo ""
        echo "Example:"
        echo "  $0 --debug --log -- file1.txt file2.txt"
        echo "  $0 -- --my-file.txt"
    }

    #----- Parameters (used by cs_library)
    verbose=false
    logger=false
    debug=false

    #----- Script specific options
    registry_reload=false
    install_generated_code=true
    translate=true
    virtuals=false
    cleanup=false
    test_mode=false

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --debug) debug=true; shift ;;
            --verbose) verbose=true; shift ;;
            --log) logger=true; shift ;;
            --noinstall) install_generated_code=false; shift ;;
            --notranslation) translate=false; shift ;;
            --reload) registry_reload=true; shift ;;
            --cleanup) cleanup=true; shift ;;
            --virtuals) virtuals=true; shift ;;
            --test) test_mode=true; shift ;;
            --help) usage; exit 0 ;; # Display help and exit
            --) shift; break ;; # End of options
            -*) echo "Unknown option: $1"; exit 0 ;;
            *) break ;; # Not an option
        esac
    done

    # Now "$@" contains only the positional arguments/files

    #----- Function to analyse the content of the cs_service file to check if a certain service is active

        # Call backend service for packs setup
        log_debug "Cache services from cs_services.txt"

        # Check if the file exists (note that on a running casasmooth this is done two times a day, caching the values. This means that if somebody extends his packs it will need to wait for 12 hours max)
        if [ ! -f "${cs_cache}/cs_services.txt" ]; then
            log "cs_services not found running update"
            ( bash ${cs_commands}/cs_get_services.sh )
        fi

        if [ ! -f "${cs_cache}/cs_services.txt" ]; then
            log_error "cs_services FILE NOT FOUND, IMPOSSIBLE TO PROCEED"
            error_exit 1
        fi

        # Read the entire file content (still encrypted) into a variable.
        if [ -f "${cs_cache}/cs_services.txt" ]; then
            subscribed_services_encoded=$(< "${cs_cache}/cs_services.txt")
            subscribed_services=$(echo -n "$subscribed_services_encoded" | base64 -d)
        else
            log_error "cs_services.txt FILE NOT LOADED, IMPOSSIBLE TO PROCEED"
            error_exit 1
        fi

        # Function to check if a service is subscribed
        subscribed_service() {
            local service="${1,,}"
            if [[ "${subscribed_services}" == *"${service}"* ]]; then
                log_debug "service $service is SUBSCRIBED"
                return 0
            else
                log_debug "service $service is NOT subscribed"
                return 1
            fi
        }

        # Function to get the level of the service (everything before "_")
        service_level() {
            local service="$1"
            echo "$service" | awk -F'_' '{print $1}'
        }

        # Function to get the name of the service (everything after "_")
        service_name() {
            local service="$1"
            echo "$service" | awk -F'_' '{print $2}'
        }

    #----- Helper functions for formatting

        # Initialize indentation level as a global variable
        declare -i current_indent=0
        declare -i indent_size=2  # Number of spaces per indent level

        # Function: set_indent_level
        # Purpose: Sets the current indentation level to a specified value.
        # Parameters:
        #   $1 - Desired indentation level (non-negative integer)
        set_indent_level() {
            local level="$1"
            if [[ "$level" =~ ^[0-9]+$ ]]; then
                current_indent="$level"
            else
                log_error "set_indent_level requires a non-negative integer." >&2
                return 1
            fi
        }

        # Function: indent
        # Purpose: Increases the current indentation level by one.
        indent() {
            let current_indent+=1
        }

        # Function: deindent
        # Purpose: Decreases the current indentation level by one, ensuring it doesn't go below zero.
        deindent() {
            if (( current_indent > 0 )); then
                let current_indent-=1
            else
                log_warning "Attempted to decrease indentation below zero." >&2
            fi
        }

        # Function: ind
        # Purpose: Generates an indentation string based on the current indentation level.
        # Parameters:
        #   $1 - (Optional) Additional indentation levels to add.
        # Output:
        #   Echoes the indentation string.
        ind() {
            local extra_level="${1:-0}"
            local indent_level=$(( current_indent + extra_level ))
            printf '%*s' $(( indent_level * indent_size )) '' | tr ' ' ' '
        }

    #----- Functions to process various files

        log_debug "---------- Setup mechanism to write generated files to a dev place"
        output_folder="${cs_locals}/last"
        backup_folder="${cs_locals}/back"
        production_folder="${cs_locals}/prod"
        mkdir -p "${output_folder}" "${backup_folder}" "${production_folder}"

        manage_files() {
            local operation="${1:-backup}"
            local redirect="${2:-}"  # Only used for the "redirect" operation.

            # Prefix to be added to all filenames.
            local prefix="cs_"

            # List of YAML files to manage.
            local files=(
                "dashboard.yaml"
                "automation.yaml"
                "scene.yaml"
                "input_number.yaml"
                "counter.yaml"
                "template.yaml"
                "media_player.yaml"
                "timer.yaml"
                "input_button.yaml"
                "input_boolean.yaml"
                "customize.yaml"
                "command_line.yaml"
                "input_datetime.yaml"
                "input_text.yaml"
                "input_select.yaml"
                "mqtt_sensor.yaml"
            )

            # Dynamically create global variables for each file.
            # For each file, create a variable named after the file (without extension)
            # where hyphens and dots are replaced with underscores, then append '_file'.
            # The variable's value is the full path to the file in the output folder.
            for file in "${files[@]}"; do
                # Remove the extension.
                local var_name="${file%.*}"
                # Replace hyphens and dots with underscores, then append '_file'.
                var_name="${var_name//[-.]/_}_file"
                # Declare a global variable with the full path.
                declare -g "${var_name}"="${output_folder}/${prefix}${file}"
                log_debug "--- Declared ${var_name}=${output_folder}/${prefix}${file}"
            done

            log_debug "Performing '${operation}' operation on generated files in ${output_folder}"

            case "$operation" in
                "clean")
                    # Remove all files from the output folder.
                    rm -f "${output_folder}"/*
                    log_debug "Cleaned all files in ${output_folder}."
                    ;;
                "backup")
                    # For each file, copy it from the production folder to the backup folder.
                    for file in "${files[@]}"; do
                        local full_path="${production_folder}/${prefix}${file}"
                        if [[ -e "${full_path}" ]]; then
                            log_debug "Backing up ${full_path}..."
                            cp -f "${full_path}" "${backup_folder}"
                        else
                            log_warning "File ${full_path} does not exist. Skipping backup."
                        fi
                    done
                    ;;
                "install")
                    # For each file, copy it from the output folder to the production folder.
                    for file in "${files[@]}"; do
                        local full_path="${output_folder}/${prefix}${file}"
                        if [[ -e "${full_path}" ]]; then
                            log_debug "Installing ${full_path} to ${production_folder}..."
                            cp -f "${full_path}" "${production_folder}"
                        else
                            log_warning "File ${full_path} does not exist. Skipping installation."
                        fi
                    done
                    ;;
                "redirect")
                    # Redirect the file path variables to a new folder.
                    # The new folder path must be provided as the second argument.
                    if [[ -z "$redirect" ]]; then
                        log_error "Redirect folder not specified for redirect operation."
                        return 1
                    fi
                    # Create the redirect folder and clear any existing files.
                    mkdir -p "${redirect}"
                    rm -f "${redirect}"/*
                    # Re-declare the global variables so that they point to the new folder.
                    for file in "${files[@]}"; do
                        local var_name="${file%.*}"
                        var_name="${var_name//[-.]/_}_file"
                        declare -g "${var_name}"="${redirect}/${prefix}${file}"
                        log_debug "--- Updated ${var_name}=${redirect}/${prefix}${file}"
                    done
                    ;;
                *)
                    # Unknown operation.
                    log_error "Unknown operation '${operation}'."
                    return 1
                    ;;
            esac
        }

        # Example Usage:
        #
        # To clean the output folder, call:
        #     manage_files "clean"
        #
        # To backup production files:
        #     manage_files "backup"
        #
        # To install files from the output folder to the production folder:
        #     manage_files "install"
        #
        # To redirect file path variables to a new folder (e.g., "/path/to/new/dir"):
        #     manage_files "redirect" "/path/to/new/dir"

        manage_files "clean"

        dashboard() {
            printf "%s\n" "$(ind "${1:-0}")$2" >> "$dashboard_file"
        }
        dashboard 0 "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        automation() {
            printf "%s\n" "$@" >> "$automation_file"
        }
        automation "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        scene() {
            printf "%s\n" "$@" >> "$scene_file"
        }
        scene "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        input_number() {
            printf "%s\n" "$@" >> "$input_number_file"
        }
        input_number "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        counter() {
            printf "%s\n" "$@" >> "$counter_file"
        }
        counter "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        customize() {
            printf "%s\n" "$@" >> "$customize_file"
        }
        customize "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        command_line() {
            printf "%s\n" "$@" >> "$command_line_file"
        }
        command_line "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        template() {
            printf "%s\n" "$@" >> "$template_file"
        }
        template "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        media_player() {
            printf "%s\n" "$@" >> "$media_player_file"
        }
        media_player "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        timer() {
            printf "%s\n" "$@" >> "$timer_file"
        }
        timer "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        mqtt_sensor() {
            printf "%s\n" "$@" >> "$mqtt_sensor_file"
        }
        mqtt_sensor "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        input_button() {
            printf "%s\n" "$@" >> "$input_button_file"
        }
        input_button "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        input_boolean() {
            printf "%s\n" "$@" >> "$input_boolean_file"
        }
        input_boolean "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        input_datetime() {
            printf "%s\n" "$@" >> "$input_datetime_file"
        }
        input_datetime "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        input_text() {
            printf "%s\n" "$@" >> "$input_text_file"
        }
        input_text "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

        input_select() {
            printf "%s\n" "$@" >> "$input_select_file"
        }
        input_select "# Generated by ${script_name} ${update_version} - copyright teleia - ${timestamp} - do not edit, it will be overwritten"

    #----- Extract some information from the running system and expose them in entities, add also some convenient entities

        log_debug "Get general usable variables from core.config"

        config_registry=$(< "${hass_path}/.storage/core.config_entries")

        if [ -z "$config_registry" ]; then
            error_exit "**** Error: config_registry file could not be read or is empty ****"
        fi

        longitude=$(jq -r '.data.longitude' "${hass_path}/.storage/core.config" 2>/dev/null)
        if [[ $? -ne 0 || -z "$longitude" ]]; then
            error_exit "Failed to retrieve longitude from ${hass_path}/.storage/core.config"
            exit 1
        fi

        latitude=$(jq -r '.data.latitude' "${hass_path}/.storage/core.config" 2>/dev/null)
        if [[ $? -ne 0 || -z "$latitude" ]]; then
            error_exit "Failed to retrieve latitude from ${hass_path}/.storage/core.config"
            exit 1
        fi

        elevation=$(jq -r '.data.elevation' "${hass_path}/.storage/core.config" 2>/dev/null)
        if [[ $? -ne 0 || -z "$elevation" ]]; then
            error_exit "Failed to retrieve elevation from ${hass_path}/.storage/core.config"
            exit 1
        fi

    #----- Specific automations and entities required by some dashboards

        log_debug "Setup general automation for UI management"

        automation "# Define system entities once in a while"
        automation "- id: 'cs_global_variables_update'"
        automation "  alias: 'CS - System - casasmoooth variables update'"
        automation "  description: 'Update global variables for futher display.'"
        automation "  mode: single"
        automation "  trigger:"
        automation "    - platform: time_pattern"
        automation "      minutes: '/59'"
        automation "  action:"

        automation "    - service: input_text.set_value"
        automation "      target:"
        automation "        entity_id: input_text.cs_guid"
        automation "      data:"
        automation "        value: '${guid}'"

        update_timestamp=$(date +"%d.%m.%Y %H:%M:%S")
        automation "    - service: input_text.set_value"
        automation "      target:"
        automation "        entity_id: input_text.cs_update_timestamp"
        automation "      data:"
        automation "        value: '${update_timestamp}'"

        automation "    - service: input_text.set_value"
        automation "      target:"
        automation "        entity_id: input_text.cs_update_version"
        automation "      data:"
        automation "        value: '${update_version}'"

        automation "    - service: input_text.set_value"
        automation "      target:"
        automation "        entity_id: input_text.cs_casasmooth_version"
        automation "      data:"
        automation "        value: '${casasmooth_version}'"

        automation "    - service: input_text.set_value"
        automation "      target:"
        automation "        entity_id: input_text.cs_longitude"
        automation "      data:"
        automation "        value: '${longitude}'"

        automation "    - service: input_text.set_value"
        automation "      target:"
        automation "        entity_id: input_text.cs_latitude"
        automation "      data:"
        automation "        value: '${latitude}'"

        automation "    - service: input_text.set_value"
        automation "      target:"
        automation "        entity_id: input_text.cs_elevation"
        automation "      data:"
        automation "        value: '${elevation}'"

        automation "# Define system entities at restart"
        automation "- id: 'cs_global_variables_restart'"
        automation "  alias: 'CS - System - casasmoooth variables restart'"
        automation "  description: 'Set certain global variables for user information in the config panel.'"
        automation "  mode: single"
        automation "  trigger:"
        automation "    - platform: homeassistant"
        automation "      event: start"
        automation "  action:"
        automation "    - service: input_text.set_value"
        automation "      target:"
        automation "        entity_id: input_text.cs_restart_timestamp"
        automation "      data:"
        automation "        value: \"{{ now().strftime('%d.%m.%Y %H:%M:%S') }}\""


#=================================== Update CS configuration and copy files where they are required, cleanup
    update_configuration() {

        log "Update CS configuration"

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

        # Make folder for TTS and clean it if it was there
        log_info "Setting up TTS folder..."
        mkdir -p "${hass_path}/www/tts"
        if [[ -d "${hass_path}/www/tts" ]]; then
            find "${hass_path}/www/tts" -mindepth 1 -delete && log_info "Cleaned TTS folder." || log_error "Failed to clean TTS folder."
        else
            log_error "TTS folder '${hass_path}/www/tts' does not exist or cannot be created."
        fi

        # Copy API documentation
        safe_copy "${cs_locals}/cs_api.txt" "${hass_path}/www"

        # Install themes
        mkdir -p "${hass_path}/themes"
        safe_copy "${cs_lib}/cs_themes.yaml" "${hass_path}/themes"

        # Install pyscripts
        #safe_copy "${cs_path}/pyscript/" "${hass_path}"

        # Install Python scripts
        #mkdir -p "${hass_path}/python_scripts"
        #safe_copy "${cs_path}/python_scripts/" "${hass_path}"
        #chmod +x "${hass_path}/python_scripts" && log_info "Made python_scripts executable."

        # Install AppDaemon scripts
        #safe_copy "${cs_path}/appdaemon" "${hass_path}/appdaemon/apps"

        # Update systems configuration.yaml
        safe_copy "${hass_path}/configuration.yaml" "${cs_temp}/configuration.yaml"
        sed -i "/# ---------- casasmooth configuration start ----------/,/# ---------- casasmooth configuration end ----------/d" "${cs_temp}/configuration.yaml" 2>/dev/null
        cat "${cs_lib}/cs_configuration.yaml" >> "${cs_temp}/configuration.yaml"
        sed -i "s|cs_guid|${guid}|" "${cs_temp}/configuration.yaml"
        safe_copy "${cs_temp}/configuration.yaml" "${hass_path}/configuration.yaml"

        # Update systems secrets.yaml
        safe_copy "${hass_path}/secrets.yaml" "${cs_temp}/secrets.yaml"
        sed -i "/# ---------- casasmooth configuration start ----------/,/# ---------- casasmooth configuration end ----------/d" "${cs_temp}/secrets.yaml" 2>/dev/null
        #cat "${cs_lib}/.cs_secrets.yaml" >> "${cs_temp}/secrets.yaml"
        #sed -i "s|cs_guid|${guid}|" "${cs_temp}/secrets.yaml" #2>/dev/null
        #sed -i "s|cs_cs_path|${cs_path}|" "${cs_temp}/secrets.yaml" #2>/dev/null
        #sed -i "s|cs_hass_path|${hass_path}|" "${cs_temp}/secrets.yaml" #2>/dev/null
        safe_copy "${cs_temp}/secrets.yaml" "${hass_path}/secrets.yaml"

    }
#=================================== Initialize casasmooth dashboard file
    initialize_casasmooth_dashboard() {
        local title="${1:-}"
        log_debug "Create main dashboard" 
        set_indent_level 0
        : > "$dashboard_file"
        if [[ -n "${title}" ]]; then
            dashboard 0 "title: ${title}"
        else
            dashboard 0 "title: casasmooth"
        fi
        dashboard 0 "views:"
    }

#=================================== Generate general and special automations
    include_source "${cs_lib}/cs_automations.sh"
#=================================== Cleanup, this part is *critical* for the stability of the system
    system_cleanup() {
        if [[ "${cleanup}" == "true" ]]; then
            log " Calling cs_cleanup to search and delete references"
            sync
            bash ${cs_commands}/cs_cleanup.sh
        fi
    }
#=================================== Main script

    #----- Keep track of time
        log "Update ${timestamp}..."

    #----- Load all entities from the registries and load the global_ list structures
        # Call the main registry function that will reparse the whole registry if needed
        reg_update_inventory
        # Includes the last version of reg_inventory data strcutures as updated seconds ago be reg_update_inventory
        include_source "${cs_locals}/cs_registry_data.sh"
        # Dump all values for analysis
        reg_dump_inventory

    #----- Add all standard general automations that may be required, this opens the automation file first
        aut_init_automations

    #----- Source and execute all listed dashboards

        # Initialize the dashboards configuration block (will accumulate YAML snippets)
        dashboards_configs=""

        # Check if the dashboards directory exists
        if [[ -d "$cs_dashboards" ]]; then

            log "Entering dashboard processing loop"

            # Loop through each dashboard folder in the dashboards directory
            for dashboard_folder in "$cs_dashboards"/*/; do

                log "Working on ${dashboard_folder}"

                config_file="${dashboard_folder}cs_config.yaml"
                
                # Check if the configuration file exists in the current folder
                if [[ -f "$config_file" ]]; then

                    log "Processing ${config_file}"
                    
                    # Extract the dashboard name from the folder path (remove trailing slash)
                    dashboard="${dashboard_folder%/}"
                    dashboard="${dashboard##*/}"

                    # Extract keys from the dashboard's config file
                    title=$(extract_key "$config_file" "title")
                    icon=$(extract_key "$config_file" "icon")
                    show_in_sidebar=$(extract_key "$config_file" "show_in_sidebar")
                    require_admin=$(extract_key "$config_file" "require_admin")
                    views=$(extract_key "$config_file" "views")
                    
                    # Initialize the dashboard (expected to set up files and define "dashboard_file")
                    initialize_casasmooth_dashboard

                    # Backup existing dashboard and put a temporary in place
                    safe_copy "${dashboard_folder}cs_dashboard.yaml" "${cs_temp}/cs_dashboard.yaml"
                    safe_copy "${cs_templates}/cs_update_dashboard.yaml" "${dashboard_folder}cs_dashboard.yaml"
                    sync

                    log "Views to execute for dashboard '${dashboard}': ${views}"
                    first_view=""

                    # Split the space-separated list of views into an array
                    IFS=' ' read -r -a views_array <<< "$views"
                    for view in "${views_array[@]}"; do
                        log "Processing view: ${view} for dashboard '${title}'"
                        
                        # Save the first view encountered for possible later use
                        if [[ -z "$first_view" ]]; then
                            first_view="$view"
                        fi

                        # Include the source code for the view
                        log_debug "Including source for view: ${view}"
                        include_source "${dashboard_folder}cs_${view}.sh"

                        # Build the view function name and call it if it exists
                        view_fx="add_${view}_view"
                        log_debug "Trying to call function: ${view_fx}"
                        if type "$view_fx" >/dev/null 2>&1; then
                            log_debug "Calling ${view_fx}; files will go to ${output_folder}"
                            "$view_fx"
                        else
                            log_error "Function '${view_fx}' not found."
                        fi
                    done

                    # Extract entities from the generated dashboard_file, we do it before it is move somewhere else
                    ent_process_entities "${dashboard_file}"

                    # Move the generated dashboard file into the dashboard folder,
                    if [[ -n "${dashboard_file:-}" ]]; then
                        safe_copy "$dashboard_file" "${dashboard_folder}cs_dashboard.yaml"
                    else
                        log_error "dashboard_file is not set. Skipping move operation, restoring previous file for dashboard '${dashboard}'."
                        safe_copy "${cs_temp}/cs_dashboard.yaml" "${dashboard_folder}cs_dashboard.yaml" 
                    fi

                    # If at least one view was processed, build and append the dashboard's YAML snippet
                    if [[ -n "$first_view" ]]; then
                        dashboard_yaml=$(printf "    %s:\n      mode: yaml\n      title: %s\n      icon: %s\n      filename: casasmooth/dashboards/%s/cs_dashboard.yaml\n      show_in_sidebar: %s\n      require_admin: %s\n" \
                            "$dashboard" "$title" "$icon" "$dashboard" "$show_in_sidebar" "$require_admin")
                        dashboards_configs="${dashboards_configs}"$'\n'"${dashboard_yaml}"
                    fi
                fi
            done

            # Extract entities from the complete generated automation_file
             ent_process_entities "${automation_file}"

            # Replace the dashboards section in the main configuration file.
            # This section is expected to be delimited by:
            #   "#---------- start dashboards ----------" and "#---------- end dashboards ----------"
                config_temp=$(mktemp)
                in_section=0
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ "$line" =~ ^#----------[[:space:]]start[[:space:]]dashboards[[:space:]]---------- ]]; then
                        printf "%s" "$line" >> "$config_temp"
                        printf "%s\n" "$dashboards_configs" >> "$config_temp"  # FIX: Avoid extra newline
                        in_section=1
                    elif [[ "$line" =~ ^#----------[[:space:]]end[[:space:]]dashboards[[:space:]]---------- ]]; then
                        printf "%s\n" "$line" >> "$config_temp"
                        in_section=0
                    elif [[ $in_section -eq 0 ]]; then
                        printf "%s\n" "$line" >> "$config_temp"
                    fi
                done < "${cs_lib}/cs_configuration.yaml"

            # Check if we should install the files that have been generated
            if [[ "$install_generated_code" == "true" ]]; then

                    safe_copy "${cs_lib}/cs_configuration.yaml" "${cs_lib}/cs_configuration.yaml.bak"
                    mv "$config_temp" "${cs_lib}/cs_configuration.yaml"
                    log "Modified configuration file saved to: ${cs_lib}/cs_configuration.yaml"

                    log "Backuping previous generated files"
                    manage_files "backup"

                    log "Installing newly generated files"
                    manage_files "install"
                    sync

            else

                mv "$config_temp" "${cs_temp}/cs_configuration.yaml"
                log "Modified configuration file saved to: ${cs_temp}/cs_configuration.yaml"
                log "Generated files NOT INSTALLED "

            fi

        else
            error_exit "Dashboards directory '${cs_dashboards}' does not exist."
        fi

    #----- Update the hass configuration.yaml file
        update_configuration

    #----- Do a system cleanup if requested (default nothing)
        system_cleanup 

    #----- Final cleanup and processing

        # Check if some key files are more recent than others and execute
        # a ha core restart if needed. First compare the folder ${cs_locals}/prod and ${cs_locals}/back
        # if one of the files have a different size, a restart is needed

        # Define the directories
        PROD_DIR="${cs_locals}/prod"
        BACK_DIR="${cs_locals}/back"

        # Verify that both directories exist
        if [ ! -d "$PROD_DIR" ] || [ ! -d "$BACK_DIR" ]; then
            echo "Error: One of the directories does not exist: $PROD_DIR or $BACK_DIR"
            exit 1
        fi

        need_restart=0

        # Build a list of all files (relative to each directory) present in either folder.
        # This handles files that might exist in one directory and not the other.
        files=$( (cd "$PROD_DIR" && find . -type f) ; (cd "$BACK_DIR" && find . -type f) | sort | uniq )

        for f in $files; do
            # Remove the leading "./" if present to get the relative path
            rel_path="${f#./}"
            prod_file="$PROD_DIR/$rel_path"
            back_file="$BACK_DIR/$rel_path"

            # Check that the file exists in both directories.
            if [ ! -f "$prod_file" ] || [ ! -f "$back_file" ]; then
                log "Difference detected: $rel_path is missing in one of the directories."
                need_restart=1
                break
            fi

            # Compare file sizes using stat.
            size_prod=$(stat -c %s "$prod_file")
            size_back=$(stat -c %s "$back_file")

            if [ "$size_prod" -ne "$size_back" ]; then
                log "Difference detected: $rel_path has size $size_prod (prod) vs $size_back (back)."
                need_restart=1
                break
            fi
        done

    #----- Done 
        # Record script end time with high precision
        script_end_time=$(date +%s)

        # Calculate the elapsed time
        script_elapsed_time=$((script_end_time - script_start_time))

        # Log and print the elapsed time
        log "Update done in ${script_elapsed_time} seconds"
        echo "Update ${timestamp} done in ${script_elapsed_time} seconds"

        # Remove the lock before restart (this line is now redundant but harmless as the trap will handle it)
        rm -f $cs_update_casasmooth_lock_file

    #----- If any difference was detected, restart Home Assistant core
        if [ "$need_restart" -eq 1 ]; then
            log "Differences detected. Restarting Home Assistant core..."
            safe_copy "${log_file}" "${hass_path}/www/cs_update_casasmooth.txt"
            sync
            if command -v ha >/dev/null 2>&1; then
                ha core restart
            fi
        else
            log "No differences detected. No restart needed."
            safe_copy "${log_file}" "${hass_path}/www/cs_update_casasmooth.txt"
        fi

        exit 0

