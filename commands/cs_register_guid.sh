#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 1.1.5.4
#
# Register the system and various infos using a REST endpoint
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

verbose=true
debug=false

email=${@:-}

if command -v ha >/dev/null 2>&1; then
  on_ha=true
else
  on_ha=false
fi

log "Check guid..."

if [ -z "${guid:-}" ]; then
    guid=$(jq -r ".data.uuid" "${hass_path}/.storage/core.uuid" 2>/dev/null) || { log_error "Failed to retrieve guid from ${hass_path}/.storage/core.uuid"; exit 1; }
fi

if [[ ! "$guid" == "csuuid-"* ]]; then
    log "System does not have a valid casasmooth GUID, updating it."
    csguid="csuuid-$(cat /proc/sys/kernel/random/uuid)"
    sed -i "s|$guid|$csguid|g" "${hass_path}/.storage/core.uuid" || { log_error "Failed to update GUID core.uuid"; exit 1; }
    guid=${csguid}
fi

log "Collecting data..."

trackers=""
if [[ -t reg_device_trackers && ${#reg_device_trackers[@]} -gt 0 ]]; then
    for tracker in "${reg_device_trackers[@]}"; do
        trackers="${trackers}${tracker};"
    done
fi

# Get some information from the local state store
file_path="${cs_locals}/cs_states.yaml"
cs_restart_timestamp=$(extract_key "$file_path" "cs_restart_timestamp")
cs_base_url=$(extract_key "$file_path" "cs_base_url")
cs_user_mail=$(extract_key "$file_path" "cs_user_mail")
casasmooth_version=$(extract_key "$file_path" "casasmooth_version")
update_version=$(extract_key "$file_path" "update_version")
update_timestamp=$(extract_key "$file_path" "update_timestamp")

if [[ "$email" == "" ]]; then
    email=${cs_user_email:-}
fi

# Get some information from the local configuration
longitude=$(jq -r ".data.longitude" "$hass_path/.storage/core.config" 2>/dev/null) || { log_error "Failed to retrieve longitude from ${hass_path}/.storage/core.config"; }
latitude=$(jq -r ".data.latitude" "$hass_path/.storage/core.config" 2>/dev/null) || { log_error "Failed to retrieve latitude from ${hass_path}/.storage/core.config"; }
elevation=$(jq -r ".data.elevation" "$hass_path/.storage/core.config" 2>/dev/null) || { log_error "Failed to retrieve elevation from ${hass_path}/.storage/core.config"; }

# The rest of the code can only run on a Home Assistant system

if [[ "$on_ha" == "false" ]]; then
    log_warning "This is not a Home Assistant system. The registration will not be executed on the backend."
    exit 0
fi

# Gathering information
name=$(ha info | grep "hostname:" | awk '{print $2}')
setup=$(jq -r '.data.entries[] | select(.domain == "hassio") | .title' "$hass_path/.storage/core.config_entries")
ip=$(curl -s ifconfig.me)
machine=$(ha info | grep "machine:" | awk '{print $2}')
hardware=$(ha hardware info)
disk_total=$(ha host info | grep "disk_total:" | awk '{print $2}')
disk_free=$(ha host info | grep "disk_free:" | awk '{print $2}')
system=$(ha os info)
network=$(ha network info)
hassos=$(ha info | grep "hassos:" | awk '{print $2}')
ha=$(ha info | grep "homeassistant:" | awk '{print $2}')
os=$(ha info | grep "operating_system:" | awk '{print $2}')
supervisor=$(ha info | grep "supervisor:" | awk '{print $2}')
docker=$(ha info | grep "docker:" | awk '{print $2}')
addons=$(ha addons list)

backup="https://teleia.sharepoint.com/sites/casasmooth/Configurations/Forms/AllItems.aspx?id=%2Fsites%2Fcasasmooth%2FConfigurations%2F${guid}%2Fbackups"

if [ -z "$email" ]; then
    log_warning "No email provided will keep the one that is registered, user should define it in the UI."
else
    log "System will be registered with $guid $email in the casasmooth backend. The user needs to define mail in the UI."
fi

endpoint_url="https://prod-14.switzerlandnorth.logic.azure.com:443/workflows/59b3f32554494ae280c720fdec68e1ca/triggers/When_a_HTTP_request_is_received/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2FWhen_a_HTTP_request_is_received%2Frun&sv=1.0&sig=D3FOL7LeSk3plf6vqRQLcbuv39h6GqRlCX215njtPrI"

# **Safely construct JSON using jq**
json_payload=$(jq -n \
    --arg guid "${guid:-}" \
    --arg email "${email:-}" \
    --arg name "${name:-}" \
    --arg backup "${backup:-}" \
    --arg setup "${setup:-}" \
    --arg ip "${ip:-}" \
    --arg machine "${machine:-}" \
    --arg hardware "${hardware:-}" \
    --arg disk_total "${disk_total:-}" \
    --arg disk_free "${disk_free:-}" \
    --arg system "${system:-}" \
    --arg network "${network:-}" \
    --arg hassos "${hassos:-}" \
    --arg ha "${ha:-}" \
    --arg os "${os:-}" \
    --arg addons "${addons:-}" \
    --arg supervisor "${supervisor:-}" \
    --arg docker "${docker:-}" \
    --arg trackers "${trackers:-}" \
    --arg longitude "${longitude:-}" \
    --arg latitude "${latitude:-}" \
    --arg elevation "${elevation:-}" \
    --arg cs_restart_timestamp "${cs_restart_timestamp:-}" \
    --arg cs_base_url "${cs_base_url:-}" \
    --arg casasmooth_version "${casasmooth_version:-}" \
    --arg update_version "${update_version:-}" \
    --arg update_timestamp "${update_timestamp:-}" \
    '{ 
        guid: $guid,
        email: $email,
        name: $name,
        backup: $backup,
        setup: $setup,
        ip: $ip,
        machine: $machine,
        hardware: $hardware,
        disk_total: $disk_total,
        disk_free: $disk_free,
        system: $system,
        network: $network,
        hassos: $hassos,
        ha: $ha,
        os: $os,
        addons: $addons,
        supervisor: $supervisor,
        docker: $docker,
        trackers: $trackers,
        longitude: $longitude,
        latitude: $latitude,
        elevation: $elevation,
        cs_restart_timestamp: $cs_restart_timestamp,
        cs_base_url: $cs_base_url,
        casasmooth_version: $casasmooth_version,
        update_version: $update_version,
        update_timestamp: $update_timestamp
    }'
)

temp_file=$(mktemp) || { log_error "Failed to create temporary file"; exit 1; }
trap 'rm -f "$temp_file"' EXIT

echo "$json_payload" > "$temp_file"
log_debug "$json_payload"

# Send the payload safely
response=$(curl --silent --write-out "%{http_code}" --header "Content-Type: application/json" --data @"$temp_file" "$endpoint_url")

http_code=$(echo "$response" | tail -n1)

if [ "$http_code" -ne 202 ]; then
    log_error "Failed to upload payload. HTTP status code: $http_code"
fi

rm -f "$temp_file"

exit 0
