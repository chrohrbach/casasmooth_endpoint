#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version 1.1.3
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

# File to process
INPUT_FILE="${cs_generated}/prod/cs_automation.yaml"
OUTPUT_FILE="${cs_generated}/cs_api.txt"

# Check if the input file exists
if [[ ! -f $INPUT_FILE ]]; then
  log_error 'Error: File cs_automation.yaml not found.'
  exit 1
fi

# Add header to the output file
echo "API description for casasmooth integration as of $(date)" > $OUTPUT_FILE
echo "=======================================================================================" >> $OUTPUT_FILE
echo "" >> $OUTPUT_FILE

# Process the file and append to the output file
awk '
BEGIN {
  processed_id = "";           # Variable to track the last processed ID
}
/^- id:/ {                     # Match lines starting with "- id:"
  id_value = $3;               # Extract the ID value
  gsub(/^ *["'\'']/, "", id_value);  # Remove leading quotes and single quotes
  gsub(/["'\''] *$/, "", id_value);  # Remove trailing quotes and single quotes
  if (id_value == processed_id) next;  # Skip if this ID was already processed
  processed_id = id_value;     # Update the last processed ID
  getline;                     # Move to the next line
  if ($0 ~ /alias:/) {         # Check if the second line contains an alias
    alias_text = "";           # Reset alias_text
    for (i = 2; i <= NF; i++)  # Extract all parts of the alias
      alias_text = alias_text " " $i
    gsub(/^ *["'\'']/, "", alias_text);  # Remove leading quotes and single quotes
    gsub(/["'\''] *$/, "", alias_text);  # Remove trailing quotes and single quotes
  }
  getline;                     # Move to the third line
  if ($0 ~ /description:/) {   # Check if the third line contains a description
    description_text = "";     # Reset description_text
    for (i = 2; i <= NF; i++)  # Extract all parts of the description
      description_text = description_text " " $i
    gsub(/^ *["'\'']/, "", description_text);  # Remove leading quotes and single quotes
    gsub(/["'\''] *$/, "", description_text);  # Remove trailing quotes and single quotes
  }
}
/trigger:/ {                   # Match the "trigger:" block
  in_trigger = 1;              # Set flag to check for input_boolean
}
/input_boolean.*_trigger/ {    # Match input_boolean ending with "_trigger"
  if (in_trigger && $0 !~ /[{]{2}/ && $0 !~ /[}]{2}/) {  # Check for invalid patterns
    input_boolean_name = $2;   # Extract the input_boolean name
    gsub(/["'\'']/, "", input_boolean_name);  # Remove single quotes from the name
    sub("entity_id: ", "", input_boolean_name);  # Clean up "entity_id: "
    print "ID: " id_value >> "'${OUTPUT_FILE}'";
    print "------------------------------------" >> "'${OUTPUT_FILE}'";
    print "Alias:" >> "'${OUTPUT_FILE}'";
    print alias_text >> "'${OUTPUT_FILE}'";
    print "Description:" >> "'${OUTPUT_FILE}'";
    print description_text >> "'${OUTPUT_FILE}'";
    print "Usage:" >> "'${OUTPUT_FILE}'";
    print "You can set the input_boolean trigger: " input_boolean_name >> "'${OUTPUT_FILE}'";
    print "" >> "'${OUTPUT_FILE}'";
    in_trigger = 0;            # Reset trigger flag to avoid duplication
  }
}' $INPUT_FILE

safe_copy "$OUTPUT_FILE" "${hass_path}/www/cs_api.txt"

log "Results written to $OUTPUT_FILE."
