#!/bin/bash

validate_service_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9]+$ ]] || [[ ${#name} -gt 25 ]]; then
        echo "❌ Invalid service name '$name'. Use lowercase letters and numbers only. Max 25 chars."
        return 1
    fi
    return 0
}

is_runtime_service() {
    local tech="$1"
    local base_tech=$(echo "$tech" | cut -d@ -f1)
    case "$base_tech" in
        "nodejs"|"php"|"python"|"go"|"rust"|"dotnet"|"java"|"bun"|"deno"|"gleam"|"elixir"|"ruby"|"static")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_managed_service() {
    local tech="$1"
    if is_runtime_service "$tech"; then
        return 1
    else
        return 0
    fi
}

get_service_id() {
    local service_name="$1"
    local service_id

    service_id=$(env | grep "^${service_name}_serviceId=" | cut -d= -f2 2>/dev/null)

    if [ -n "$service_id" ]; then
        echo "$service_id"
        return 0
    fi

    if [ -f "/tmp/current_envs.env" ]; then
        service_id=$(grep "^${service_name}_serviceId=" /tmp/current_envs.env | cut -d= -f2 2>/dev/null)
        if [ -n "$service_id" ]; then
            echo "$service_id"
            return 0
        fi
    fi

    return 1
}
