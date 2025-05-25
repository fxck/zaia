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
            echo "❌ Unknown option: $1"
            usage
            ;;
    esac
done

if ! validate_service_name "$HOSTNAME"; then
    exit 1
fi

# CLEAN: Validate service type (required - will exit if invalid)
validate_service_type "$TYPE"

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
        echo "❌ FATAL: Failed to create runtime service $hostname"
        rm -f /tmp/runtime_import_${hostname}.yaml
        exit 1
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
        echo "❌ FATAL: Failed to create managed service $hostname"
        rm -f /tmp/managed_import_${hostname}.yaml
        exit 1
    fi
}

echo "=== CREATING ZEROPS SERVICE(S) ==="
echo "Hostname: $HOSTNAME"
echo "Type: $TYPE"
echo "Dual: $CREATE_DUAL"
echo ""

if [ "$CREATE_DUAL" = true ]; then
    if is_managed_service "$TYPE"; then
        echo "❌ FATAL: Cannot create dual services for managed services"
        exit 1
    fi

    echo "Creating dual services (dev + stage)..."
    create_runtime_service "$HOSTNAME" "$TYPE"
    create_runtime_service "${HOSTNAME}dev" "$TYPE"

elif is_managed_service "$TYPE"; then
    create_managed_service "$HOSTNAME" "$TYPE" "$MODE"
else
    create_runtime_service "$HOSTNAME" "$TYPE"
fi

echo ""
echo "✅ Service creation completed successfully"
echo ""
echo "🔄 MANDATORY NEXT STEPS (.zaia ONLY):"
echo "1. Wait 10-30 seconds for service initialization"
echo "2. Sync to .zaia: /var/www/sync_env_to_zaia.sh"
echo "3. Update discovery: /var/www/discover_services.sh"
echo "4. Check status: /var/www/show_project_context.sh"
echo "5. View env vars: get_available_envs <service_name>"
echo "6. Get suggestions: suggest_env_vars <service_name>"

echo ""
echo "💡 Remember: All environment data is managed through .zaia ONLY"
