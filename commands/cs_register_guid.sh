#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 1.1.7.3
#
# Register the system and various infos using a REST endpoint
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#=================================== Include cs_registry
if [[ -f "${cs_locals}/cs_registry_data.sh" ]]; then
    include_source "${cs_lib}/cs_registry.sh"
    include_source "${cs_locals}/cs_registry_data.sh"
fi
#===================================

# this script WILL have unbound variables, ignore them
set -u

email="${@:-}"
if [[ -z "$email" ]]; then
    echo "Registering/updating system without an email. The GUID will NOT be associated with a user."
else
    echo "Registering/updating system with this associated email: $email."
fi

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
if [[ -f "${cs_locals}/cs_registry_data.sh" ]]; then
    if [[ -v global_mobile_trackers && ${#global_mobile_trackers[@]} -gt 0 ]]; then
        for tracker in "${global_mobile_trackers[@]}"; do
            trackers="${trackers}${tracker};"
        done
    fi
fi

# Get some information from the local state store
file_path="${cs_locals}/cs_states.yaml"
cs_restart_timestamp=$(extract_key "$file_path" "cs_restart_timestamp")
cs_base_url=$(extract_key "$file_path" "cs_base_url")
cs_user_email=$(extract_key "$file_path" "cs_user_email")
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

if [[ -f "${cs_locals}/cs_registry_data.sh" ]]; then
    # Count elements in each global array and assign directly to variables
    # Use -v test to avoid unbound variable errors with set -u
    area_ids=$([[ -v global_area_ids ]] && echo "${#global_area_ids[@]}" || echo "0")
    entity_ids=$([[ -v global_entity_ids ]] && echo "${#global_entity_ids[@]}" || echo "0")
    lights=$([[ -v global_lights ]] && echo "${#global_lights[@]}" || echo "0")
    bulbs=$([[ -v global_bulbs ]] && echo "${#global_bulbs[@]}" || echo "0")
    cameras=$([[ -v global_cameras ]] && echo "${#global_cameras[@]}" || echo "0")
    frigate_cameras=$([[ -v global_frigate_cameras ]] && echo "${#global_frigate_cameras[@]}" || echo "0")
    climates=$([[ -v global_climates ]] && echo "${#global_climates[@]}" || echo "0")
    heaters=$([[ -v global_heaters ]] && echo "${#global_heaters[@]}" || echo "0")
    power_consumption_sensors=$([[ -v global_power_consumption_sensors ]] && echo "${#global_power_consumption_sensors[@]}" || echo "0")
    switches=$([[ -v global_switches ]] && echo "${#global_switches[@]}" || echo "0")
    temperature_sensors=$([[ -v global_temperature_sensors ]] && echo "${#global_temperature_sensors[@]}" || echo "0")
    humidity_sensors=$([[ -v global_humidity_sensors ]] && echo "${#global_humidity_sensors[@]}" || echo "0")
    illuminance_sensors=$([[ -v global_illuminance_sensors ]] && echo "${#global_illuminance_sensors[@]}" || echo "0")
    motion_sensors=$([[ -v global_motion_sensors ]] && echo "${#global_motion_sensors[@]}" || echo "0")
    occupancy_sensors=$([[ -v global_occupancy_sensors ]] && echo "${#global_occupancy_sensors[@]}" || echo "0")
    co2_sensors=$([[ -v global_co2_sensors ]] && echo "${#global_co2_sensors[@]}" || echo "0")
    pm1_sensors=$([[ -v global_pm1_sensors ]] && echo "${#global_pm1_sensors[@]}" || echo "0")
    pm4_sensors=$([[ -v global_pm4_sensors ]] && echo "${#global_pm4_sensors[@]}" || echo "0")
    pm10_sensors=$([[ -v global_pm10_sensors ]] && echo "${#global_pm10_sensors[@]}" || echo "0")
    pm25_sensors=$([[ -v global_pm25_sensors ]] && echo "${#global_pm25_sensors[@]}" || echo "0")
    open_sensors=$([[ -v global_open_sensors ]] && echo "${#global_open_sensors[@]}" || echo "0")
    buttons=$([[ -v global_buttons ]] && echo "${#global_buttons[@]}" || echo "0")
    dimmers=$([[ -v global_dimmers ]] && echo "${#global_dimmers[@]}" || echo "0")

    # Combined counts (without _count suffix)
    lights_and_bulbs=$((lights + bulbs))
    cameras_and_frigate=$((cameras + frigate_cameras))
    climates_and_heaters=$((climates + heaters))
    buttons_and_dimmers=$((buttons + dimmers))
    sensors=$((temperature_sensors + humidity_sensors + illuminance_sensors + motion_sensors + occupancy_sensors + co2_sensors + pm1_sensors + pm4_sensors + pm10_sensors + pm25_sensors + open_sensors))
fi

# Verify the mode we are running in, if there is no lib/cs_update_casasmooth.sh file its endpoint, if there is no internals/cs_services.json we are release mode, otherwise in development mode
if [[ ! -f "${cs_path}/lib/cs_update_casasmooth.sh" ]]; then
    log "Running in endpoint mode."
    casasmooth_runtime="endpoint"
elif [[ ! -f "${cs_path}/internals/cs_services.json" ]]; then
    log "Running in release mode."
    casasmooth_runtime="release"
else
    log "Running in development mode."
    casasmooth_runtime="development"
fi

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
    --arg casasmooth_runtime "${casasmooth_runtime:-}" \
    --arg update_version "${update_version:-}" \
    --arg update_timestamp "${update_timestamp:-}" \
    --arg area_ids "${area_ids:-}" \
    --arg entity_ids "${entity_ids:-}" \
    --arg lights_and_bulbs "${lights_and_bulbs:-}" \
    --arg cameras_and_frigate "${cameras_and_frigate:-}" \
    --arg climates_and_heaters "${climates_and_heaters:-}" \
    --arg buttons_and_dimmers "${buttons_and_dimmers:-}" \
    --arg sensors "${sensors:-}" \
    --arg power_consumption_sensors "${power_consumption_sensors:-}" \
    --arg switches "${switches:-}" \
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
        casasmooth_runtime: $casasmooth_runtime,
        update_version: $update_version,
        update_timestamp: $update_timestamp,
        area_ids: $area_ids,
        entity_ids: $entity_ids,
        lights_and_bulbs: $lights_and_bulbs,
        cameras_and_frigate: $cameras_and_frigate,
        climates_and_heaters: $climates_and_heaters,
        buttons_and_dimmers: $buttons_and_dimmers,
        sensors: $sensors,
        power_consumption_sensors: $power_consumption_sensors,
        switches: $switches
    }'
)

temp_file=$(mktemp) || { log_error "Failed to create temporary file"; exit 1; }
trap 'rm -f "$temp_file"' EXIT

echo "$json_payload" > "$temp_file"
log_debug "$json_payload"

# Send the payload safely
http_code=$(curl --silent --output /dev/null --write-out "%{http_code}" --header "Content-Type: application/json" --data @"$temp_file" "$endpoint_url")

if [ "$http_code" -ne 202 ]; then
    log_error "Failed to upload payload. HTTP status code: $http_code"
fi

rm -f "$temp_file"

exit 0
