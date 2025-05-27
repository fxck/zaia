#!/bin/bash
set -e
source /var/www/core_utils.sh

usage() {
    echo "Usage: $0 <yaml-file> OR $0 <hostname> <type> [--dual]"
    echo ""
    echo "Service types must be from technologies.json"
    echo "Examples:"
    echo "  $0 services.yaml"
    echo "  $0 myapp nodejs@22 --dual"
    echo "  $0 mydb postgresql@16"
    echo "  $0 storage objectstorage"
    echo ""
    echo "For framework templates, use: get_recipe.sh <framework>"
    exit 1
}

# Batch creation from YAML
if [ $# -eq 1 ] && [ -f "$1" ]; then
    YAML_FILE="$1"
    echo "Creating services from $YAML_FILE..."

    # Validate all types first
    for type in $(yq e '.services[].type' "$YAML_FILE"); do
        validate_service_type "$type" || exit 1
    done

    zcli project service-import "$YAML_FILE" --projectId "$projectId" || exit 1

    # Apply workarounds for runtime services with startWithoutCode
    sleep 20
    for service in $(yq e '.services[] | select(.startWithoutCode == true) | .hostname' "$YAML_FILE"); do
        TYPE=$(yq e ".services[] | select(.hostname == \"$service\") | .type" "$YAML_FILE")
        ROLE=$(get_service_role "$service" "$TYPE")

        if [[ "$ROLE" != "database" && "$ROLE" != "cache" && "$ROLE" != "storage" ]]; then
            apply_workaround "$service"
        fi
    done

    echo "✅ Services created. Run init_project.sh to update .zaia"
    exit 0
fi

# Single service creation
[ $# -lt 2 ] && usage

HOSTNAME="$1"
TYPE="$2"
DUAL="${3:-false}"

validate_service_name "$HOSTNAME" || exit 1
validate_service_type "$TYPE" || exit 1

# Determine if managed service
IS_MANAGED=false
BASE_TYPE=$(echo "$TYPE" | cut -d@ -f1)
ROLE=$(get_service_role "$HOSTNAME" "$TYPE")

[[ "$ROLE" =~ ^(database|cache|storage)$ ]] && IS_MANAGED=true

# Create YAML
cat > /tmp/service.yaml << EOF
services:
  - hostname: $HOSTNAME
    type: $TYPE
EOF

if [ "$IS_MANAGED" = true ]; then
    # Add mode for databases/cache (not for storage)
    if [[ "$ROLE" != "storage" ]]; then
        echo "    mode: NON_HA" >> /tmp/service.yaml
    fi
else
    # Runtime service
    echo "    startWithoutCode: true" >> /tmp/service.yaml
fi

if [ "$DUAL" = "--dual" ]; then
    if [ "$IS_MANAGED" = true ]; then
        echo "❌ Cannot create dual services for managed services"
        rm -f /tmp/service.yaml
        exit 1
    fi

    cat >> /tmp/service.yaml << EOF
  - hostname: ${HOSTNAME}dev
    type: $TYPE
    startWithoutCode: true
EOF
fi

# Show what will be created
echo "📋 Creating service(s):"
cat /tmp/service.yaml

# Import
zcli project service-import /tmp/service.yaml --projectId "$projectId" || exit 1
rm -f /tmp/service.yaml

# Apply workarounds for runtime services only
if [ "$IS_MANAGED" = false ]; then
    sleep 20
    apply_workaround "$HOSTNAME"
    [ "$DUAL" = "--dual" ] && apply_workaround "${HOSTNAME}dev"
fi

echo "✅ Service(s) created. Run init_project.sh to update .zaia"

# Show relevant recipe if available
echo ""
echo "💡 Tip: Check recipe for $BASE_TYPE patterns:"
echo "   get_recipe.sh $BASE_TYPE"
