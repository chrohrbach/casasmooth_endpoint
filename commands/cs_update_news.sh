#!/bin/bash
#
# casasmooth - copyright by teleia 2024
#
# Version: 1.1.3
#
# Read news from Google News, clean it up, and save it to cache
#
#=================================== Include cs_library
include="/config/casasmooth/lib/cs_library.sh"
if ! source "${include}"; then
    echo "ERROR: Failed to source ${include}"
    exit 1
fi
#===================================

# Define output files
rss_file="${cs_cache}/news.xml"
output_file="${cs_cache}/news.txt"

current_language=$(jq -r '.data.language // "en"' "${hass_path}/.storage/core.config" 2>/dev/null)
if [[ -z "$current_language" ]]; then
    log_warning "Language not found in '${hass_path}/.storage/core.config'. Falling back to 'en'."
    current_language="en"
else
    log_debug "Using language file: ${hass_path}/.storage/core.config - Selected language: $current_language"
fi

# Fetch RSS feed with User-Agent and handle redirects
curl -s -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36" \
-L "https://news.google.com/rss?hl=${current_language}" -o "$rss_file"

# Verify the file is not empty
if [ ! -s "$rss_file" ]; then
    echo "ERROR: Failed to retrieve news feed."
    exit 1
fi

# Extract and clean news articles
awk '
BEGIN { RS="</item>"; FS="<title>|</title>|<description>|</description>" }
{
    title = $2
    description = $4

    # Replace &nbsp; with spaces and remove &amp;
    gsub(/&nbsp;/, " ", description)
    gsub(/&amp;/, " ", description)
    gsub(/nbsp;/, " ", description)

    # Remove HTML tags and special characters
    gsub(/&lt;/, "<", description)
    gsub(/&gt;/, ">", description)
    gsub(/<[^>]+>/, "", description)  # Remove any remaining HTML tags
    gsub(/ +/, " ", description)  # Normalize spaces

    # Skip first unwanted title
    if (title != "À la une - Google Actualités" && title != "") {
        print "**"title"**" "\n"
        print description "\n"
    }
}' "$rss_file" > "$output_file"

# Confirm the operation
if [ -s "$output_file" ]; then
    echo "News saved to: $output_file"
    cat "$output_file"
else
    echo "ERROR: No valid news extracted."
    exit 1
fi
