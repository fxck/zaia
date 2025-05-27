#!/bin/bash
set -e
source /var/www/core_utils.sh

usage() {
    echo "Usage:"
    echo "  $0 <yaml-file>                    # Batch creation from YAML"
    echo "  $0 <hostname> <type> [--dual]     # Single/dual service creation"
    echo ""
    echo "Service types must be from technologies.json"
    echo ""
    echo "Examples:"
    echo "  $0 services.yaml"
    echo "  $0 myapp nodejs@22 --dual"
    echo "  $0 mydb postgresql@16"
    echo "  $0 storage objectstorage"
    echo ""
    echo "💡 For framework templates: /var/www/get_recipe.sh <framework>"
    exit 1
}

# No arguments
[ $# -eq 0 ] && usage

# Batch creation from YAML file
if [ $# -eq 1 ] && [ -f "$1" ]; then
    YAML_FILE="$1"
    echo "📄 Creating services from $YAML_FILE..."

    # Validate YAML structure
    if ! yq e '.' "$YAML_FILE" >/dev/null 2>&1; then
        echo "❌ Invalid YAML syntax in file"
        exit 1
    fi

    if ! yq e '.services' "$YAML_FILE" >/dev/null 2>&1; then
        echo "❌ Missing 'services' section in YAML"
        echo "   Expected structure:"
        echo "   services:"
        echo "     - hostname: ..."
        echo "       type: ..."
        exit 1
    fi

    # Extract and validate all service types
    echo "🔍 Validating service types..."
    SERVICE_COUNT=$(yq e '.services | length' "$YAML_FILE")

    if [ "$SERVICE_COUNT" -eq 0 ]; then
        echo "❌ No services defined in YAML"
        exit 1
    fi

    for i in $(seq 0 $((SERVICE_COUNT - 1))); do
        TYPE=$(yq e ".services[$i].type" "$YAML_FILE")
        HOSTNAME=$(yq e ".services[$i].hostname" "$YAML_FILE")

        echo "  Checking: $HOSTNAME ($TYPE)"

        if ! validate_service_type "$TYPE"; then
            echo "❌ Invalid type for service $HOSTNAME"
            exit 1
        fi

        if ! validate_service_name "$HOSTNAME"; then
            echo "❌ Invalid hostname: $HOSTNAME"
            exit 1
        fi
    done

    # Import services
    echo ""
    echo "🚀 Importing services to project..."
    if ! zcli project service-import "$YAML_FILE" --projectId "$projectId"; then
        echo "❌ Service import failed"
        echo ""
        echo "🔍 Debugging tips:"
        echo "  1. Check projectId: echo \$projectId"
        echo "  2. Verify auth: zcli project list"
        echo "  3. Check for duplicate service names"
        echo "  4. Ensure YAML syntax is correct"
        exit 1
    fi

    echo "✅ Services imported successfully"

    # Apply workarounds for runtime services with startWithoutCode
    echo ""
    echo "🔧 Applying platform workarounds..."
    sleep 20  # Wait for services to initialize

    WORKAROUND_COUNT=0
    for service in $(yq e '.services[] | select(.startWithoutCode == true) | .hostname' "$YAML_FILE" 2>/dev/null); do
        TYPE=$(yq e ".services[] | select(.hostname == \"$service\") | .type" "$YAML_FILE")
        ROLE=$(get_service_role "$service" "$TYPE")

        if [[ "$ROLE" != "database" && "$ROLE" != "cache" && "$ROLE" != "storage" ]]; then
            echo "  Applying workaround for $service..."
            if apply_workaround "$service"; then
                WORKAROUND_COUNT=$((WORKAROUND_COUNT + 1))
            fi
        fi
    done

    if [ $WORKAROUND_COUNT -gt 0 ]; then
        echo "✅ Applied workarounds to $WORKAROUND_COUNT services"
    fi

    echo ""
    echo "🎉 Batch service creation complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Update state: /var/www/init_project.sh"
    echo "  2. Check status: /var/www/show_project_context.sh"
    echo "  3. Configure env: get_available_envs <service>"

    exit 0
fi

# Single/dual service creation
if [ $# -lt 2 ]; then
    usage
fi

HOSTNAME="$1"
TYPE="$2"
DUAL="${3:-false}"

# Validate inputs
echo "🔍 Validating inputs..."
if ! validate_service_name "$HOSTNAME"; then
    exit 1
fi

if ! validate_service_type "$TYPE"; then
    exit 1
fi

# Determine service characteristics
ROLE=$(get_service_role "$HOSTNAME" "$TYPE")
IS_MANAGED=$([[ "$ROLE" =~ ^(database|cache|storage)$ ]] && echo "true" || echo "false")

echo "📋 Service details:"
echo "  Hostname: $HOSTNAME"
echo "  Type: $TYPE"
echo "  Role: $ROLE"
echo "  Managed: $IS_MANAGED"

# Check for dual creation
if [ "$DUAL" = "--dual" ]; then
    if [ "$IS_MANAGED" = "true" ]; then
        echo "❌ Cannot create dual services for managed services"
        echo "   Managed services (databases, cache, storage) are shared"
        exit 1
    fi
    echo "  Mode: Dual (dev + stage)"
fi

# Build YAML content
echo ""
echo "📝 Generating service configuration..."

if [ "$DUAL" = "--dual" ]; then
    # Dual service creation
    YAML_CONTENT="services:
  - hostname: ${HOSTNAME}
    type: $TYPE
    startWithoutCode: true
    priority: 50
  - hostname: ${HOSTNAME}dev
    type: $TYPE
    startWithoutCode: true
    priority: 60"
else
    # Single service creation
    YAML_CONTENT="services:
  - hostname: $HOSTNAME
    type: $TYPE"

    if [ "$IS_MANAGED" = "true" ]; then
        # Add mode for managed services (except storage)
        if [ "$ROLE" != "storage" ]; then
            YAML_CONTENT="$YAML_CONTENT
    mode: NON_HA"
        fi
    else
        # Runtime service
        YAML_CONTENT="$YAML_CONTENT
    startWithoutCode: true"
    fi
fi

# Create and validate YAML
TEMP_YAML="/tmp/service_create_$$.yaml"
if ! create_safe_yaml "$TEMP_YAML" << EOF
$YAML_CONTENT
EOF
then
    echo "❌ Failed to create valid YAML"
    exit 1
fi

# Show what will be created
echo ""
echo "📄 Service configuration:"
echo "------------------------"
cat "$TEMP_YAML"
echo "------------------------"

# Confirm and import
echo ""
echo "🚀 Importing to project..."
if ! zcli project service-import "$TEMP_YAML" --projectId "$projectId"; then
    echo "❌ Service import failed"
    rm -f "$TEMP_YAML"
    exit 1
fi

rm -f "$TEMP_YAML"
echo "✅ Service(s) created successfully"

# Apply workarounds for runtime services
if [ "$IS_MANAGED" = "false" ]; then
    echo ""
    echo "🔧 Applying platform workarounds..."
    sleep 20  # Wait for service initialization

    apply_workaround "$HOSTNAME"

    if [ "$DUAL" = "--dual" ]; then
        apply_workaround "${HOSTNAME}dev"
    fi
fi

# Show next steps
echo ""
echo "🎉 Service creation complete!"
echo ""
echo "Next steps:"
echo "  1. Update state: /var/www/init_project.sh"
echo "  2. Check recipe: /var/www/get_recipe.sh $(echo $TYPE | cut -d@ -f1)"

if [ "$IS_MANAGED" = "false" ]; then
    echo "  3. Setup code: safe_ssh \"$HOSTNAME\" \"cd /var/www && git init\""
    echo "  4. Configure: get_available_envs $HOSTNAME"

    if [ "$DUAL" = "--dual" ]; then
        echo "  5. Deploy: /var/www/deploy.sh ${HOSTNAME}dev"
    fi
else
    echo "  3. Use connection: get_available_envs <your-app-service>"
    echo "  4. Reference: \${${HOSTNAME}_connectionString}"
fi

exit 0
