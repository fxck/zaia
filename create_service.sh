#!/bin/bash
set -e

source /var/www/validate_inputs.sh

usage() {
    echo "Usage: $0 <hostname> <type> [options]"
    echo ""
    echo "Arguments:"
    echo "  hostname    Service hostname (lowercase alphanumeric, max 25 chars)"
    echo "  type        Service type (e.g., nodejs@22, postgresql@16, redis@7)"
    echo ""
    echo "Options:"
    echo "  --dual      Create both dev and stage services (hostname + hostnamedev)"
    echo "  --mode      Set mode for managed services (HA or NON_HA, default: NON_HA)"
    echo ""
    echo "Examples:"
    echo "  $0 myapp nodejs@22 --dual"
    echo "  $0 mydb postgresql@16 --mode NON_HA"
    echo "  $0 mycache redis@7"
    echo ""
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

HOSTNAME="$1"
TYPE="$2"
CREATE_DUAL=false
MODE="NON_HA"

shift 2
while [[ $# -gt 0 ]]; do
    case $1 in
        --dual)
            CREATE_DUAL=true
            shift
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if ! validate_service_name "$HOSTNAME"; then
    exit 1
fi

if [ "$MODE" != "HA" ] && [ "$MODE" != "NON_HA" ]; then
    echo "❌ Invalid mode: $MODE. Must be HA or NON_HA"
    exit 1
fi

create_runtime_service() {
    local hostname="$1"
    local type="$2"

    echo "Creating runtime service: $hostname ($type)"

    cat > /tmp/runtime_import_${hostname}.yaml << EOF
services:
  - hostname: $hostname
    type: $type
    startWithoutCode: true
EOF

    if zcli project service-import /tmp/runtime_import_${hostname}.yaml --projectId "$projectId"; then
        echo "✅ Runtime service $hostname created successfully"
        rm -f /tmp/runtime_import_${hostname}.yaml
        return 0
    else
        echo "❌ Failed to create runtime service $hostname"
        return 1
    fi
}

create_managed_service() {
    local hostname="$1"
    local type="$2"
    local mode="$3"

    echo "Creating managed service: $hostname ($type, $mode)"

    cat > /tmp/managed_import_${hostname}.yaml << EOF
services:
  - hostname: $hostname
    type: $type
    mode: $mode
EOF

    if zcli project service-import /tmp/managed_import_${hostname}.yaml --projectId "$projectId"; then
        echo "✅ Managed service $hostname created successfully"
        rm -f /tmp/managed_import_${hostname}.yaml
        return 0
    else
        echo "❌ Failed to create managed service $hostname"
        return 1
    fi
}

echo "=== CREATING ZEROPS SERVICE(S) ==="
echo "Hostname: $HOSTNAME"
echo "Type: $TYPE"
echo "Dual: $CREATE_DUAL"
echo ""

SUCCESS=true

if [ "$CREATE_DUAL" = true ]; then
    if is_managed_service "$TYPE"; then
        echo "❌ Cannot create dual services for managed services"
        exit 1
    fi

    echo "Creating dual services (dev + stage)..."

    if ! create_runtime_service "$HOSTNAME" "$TYPE"; then
        SUCCESS=false
    fi

    if ! create_runtime_service "${HOSTNAME}dev" "$TYPE"; then
        SUCCESS=false
    fi

elif is_managed_service "$TYPE"; then
    if ! create_managed_service "$HOSTNAME" "$TYPE" "$MODE"; then
        SUCCESS=false
    fi

else
    if ! create_runtime_service "$HOSTNAME" "$TYPE"; then
        SUCCESS=false
    fi
fi

if [ "$SUCCESS" = true ]; then
    echo ""
    echo "✅ Service creation completed successfully"
    echo ""
    echo "Next steps:"
    echo "1. Wait 10-30 seconds for service initialization"
    echo "2. Run: /var/www/get_service_envs.sh"
    echo "3. Run: /var/www/discover_services.sh"
    echo "4. Check status: /var/www/show_project_context.sh"

else
    echo ""
    echo "❌ Service creation failed"
    exit 1
fi
