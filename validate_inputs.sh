#!/bin/bash

# Validate service name (Zerops requirements)
validate_service_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9]+$ ]] || [[ ${#name} -gt 25 ]]; then
        echo "❌ Invalid service name '$name'. Use lowercase letters and numbers only. Max 25 chars."
        return 1
    fi
    return 0
}

# Validate technology specification (Corrected Function)
validate_technology() {
    local tech_to_check="$1"

    # First, check the format (as before)
    if [[ ! "$tech_to_check" =~ ^[a-zA-Z0-9@.\+\-]+$ ]]; then # Regex updated to include + and - for php-apache versions
        echo "❌ Invalid technology string format: '$tech_to_check'. Allowed characters: a-z, A-Z, 0-9, @, ., +, -"
        return 1
    fi

    # Now, check against /var/www/technologies.json
    if [ ! -f "/var/www/technologies.json" ]; then
        echo "❌ Critical: /var/www/technologies.json not found. Cannot validate technology '$tech_to_check'."
        return 1 # Cannot validate without the file
    fi

    if jq -e --arg t "$tech_to_check" '.[] | select(. == $t)' /var/www/technologies.json > /dev/null; then
        return 0 # Technology is valid and in the list
    else
        echo "❌ Invalid or unsupported technology: '$tech_to_check'."
        echo "   Ensure the technology is listed in /var/www/technologies.json. Some examples from the file:"
        jq -r '.[]' /var/www/technologies.json | head -n 5 # Show a few examples from the file
        return 1 # Technology is not in the list
    fi
}

# Sanitize command inputs
sanitize_command() {
    local cmd="$1"
    # Removed $ from sed sanitize list as it's often needed for variable expansion safely.
    # If stronger sanitization is needed, this can be adjusted.
    echo "$cmd" | sed 's/[;&|`()]//g' | tr -d '\n\r'
}
