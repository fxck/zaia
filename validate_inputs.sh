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

# Validate technology specification
validate_technology() {
    local tech="$1"
    if [[ ! "$tech" =~ ^[a-zA-Z0-9@.]+$ ]]; then
        echo "❌ Invalid technology specification '$tech'"
        return 1
    fi
    return 0
}

# Sanitize command inputs
sanitize_command() {
    local cmd="$1"
    echo "$cmd" | sed 's/[;&|`$()]//g' | tr -d '\n\r'
}
