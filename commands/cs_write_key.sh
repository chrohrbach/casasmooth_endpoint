#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.1.1
#
# Generate a doc document for the API
#
#=================================== Include cs_library
    include="/config/casasmooth/lib/cs_library.sh"
    if ! source "${include}"; then
        echo "ERROR: Failed to source ${include}"
        exit 1
    fi
#===================================

verbose=true


file_path="${cs_locals}/cs_states.yaml"

#----- Get parameters
key="$1"
value="$2"
key_value_line="${key}: ${value}"

# Check if file exists, create if not
if [ ! -f "${file_path}" ]; then
  touch "${file_path}"
fi

# Read file content
file_content=$(cat "${file_path}")

# Check if key already exists (start of line matching "key:")
if grep -q "^${key}:" <<< "${file_content}"; then
  # Key exists, check if value is different
  current_value=$(grep "^${key}:" <<< "${file_content}" | cut -d':' -f2- | sed 's/^[[:space:]]*//') # Extract current value
  if [ "${current_value}" != "${value}" ]; then
    # Value is different, replace the line using sed
    sed -i "s/^${key}:.*/${key_value_line}/" "${file_path}"
    echo "Value for key '${key}' updated to '${value}' in '${file_path}'"
  else
    echo "Value for key '${key}' is already '${value}' in '${file_path}'. No update needed."
  fi
else
  # Key does not exist, append the line to the file
  echo "${key_value_line}" >> "${file_path}"
  echo "Key-value pair '${key_value_line}' written to '${file_path}'"
fi