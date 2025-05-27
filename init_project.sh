#!/bin/bash
set -e
source /var/www/core_utils.sh

echo "=== INITIALIZING PROJECT STATE ==="

# Prerequisites check
if [ -z "$ZEROPS_ACCESS_TOKEN" ]; then
    echo "❌ FATAL: ZEROPS_ACCESS_TOKEN not set"
    exit 1
fi

if [ -z "$projectId" ]; then
    echo "❌ FATAL: projectId not set"
    exit 1
fi

# Backup existing state
if [ -f /var/www/.zaia ]; then
    BACKUP_FILE="/var/www/.zaia.backup.$(date +%s)"
    cp /var/www/.zaia "$BACKUP_FILE"
    echo "📦 Existing state backed up to: $BACKUP_FILE"
fi

# Authenticate if needed
if ! zcli project list >/dev/null 2>&1; then
    echo "🔐 Authenticating..."
    if ! zcli login "$ZEROPS_ACCESS_TOKEN"; then
        echo "❌ FATAL: Authentication failed"
        exit 1
    fi
fi

# Fetch project configuration
echo "📥 Fetching project configuration..."
EXPORT_URL="https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/export"

if ! curl -sf -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" "$EXPORT_URL" -o /tmp/project_export.yaml; then
    echo "❌ FATAL: Failed to fetch project configuration"
    exit 1
fi

# Validate export data
if ! jq -e '.yaml' /tmp/project_export.yaml >/dev/null 2>&1; then
    echo "❌ FATAL: Invalid export data - missing 'yaml' field"
    echo "Debug info:"
    head -20 /tmp/project_export.yaml
    exit 1
fi

# Extract project information
YAML_CONTENT=$(jq -r '.yaml' /tmp/project_export.yaml)
if [ -z "$YAML_CONTENT" ] || [ "$YAML_CONTENT" = "null" ]; then
    echo "❌ FATAL: Empty YAML content"
    exit 1
fi

PROJECT_NAME=$(echo "$YAML_CONTENT" | yq e '.project.name' - 2>/dev/null)
if [ -z "$PROJECT_NAME" ] || [ "$PROJECT_NAME" = "null" ]; then
    echo "❌ FATAL: Could not extract project name"
    exit 1
fi

echo "📋 Project: $PROJECT_NAME"

# Initialize .zaia structure
cat > /var/www/.zaia << EOF
{
  "project": {
    "id": "$projectId",
    "name": "$PROJECT_NAME",
    "lastSync": "$(date -Iseconds)"
  },
  "services": {},
  "deploymentPairs": {}
}
EOF

# Verify .zaia creation
if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ FATAL: Failed to create valid .zaia file"
    exit 1
fi

# Discover services
echo "🔍 Discovering services..."
SERVICE_COUNT=0

for service in $(echo "$YAML_CONTENT" | yq e '.services[].hostname' -); do
    [ "$service" = "zaia" ] && continue

    SERVICE_COUNT=$((SERVICE_COUNT + 1))

    # Extract service information
    TYPE=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service\") | .type" -)
    MODE=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service\") | .mode // \"NON_HA\"" -)
    ROLE=$(get_service_role "$service" "$TYPE")

    echo "  Found: $service ($TYPE) - $ROLE"

    # Add service to .zaia
    jq --arg s "$service" --arg t "$TYPE" --arg r "$ROLE" --arg m "$MODE" \
       '.services[$s] = {
         "type": $t,
         "role": $r,
         "mode": $m,
         "id": "pending",
         "serviceProvidedEnvs": [],
         "selfDefinedEnvs": {},
         "subdomain": null,
         "actualZeropsYml": null,
         "discoveredRuntime": {}
       }' /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia

    # Try to discover configuration for runtime services
    if can_ssh "$service"; then
        echo "    Checking $service for configuration..."

        # Look for zerops.yml
        if YML_CONTENT=$(safe_ssh "$service" "cat /var/www/zerops.yml 2>/dev/null || cat /var/www/zerops.yaml 2>/dev/null" 300 10); then
            # Try to extract service-specific configuration
            if SERVICE_CONFIG=$(echo "$YML_CONTENT" | yq e ".zerops[] | select(.setup == \"$service\")" -o=json 2>/dev/null); then
                if [ -n "$SERVICE_CONFIG" ] && [ "$SERVICE_CONFIG" != "null" ]; then
                    # Store actual YAML configuration
                    jq --arg s "$service" --argjson cfg "$SERVICE_CONFIG" \
                       '.services[$s].actualZeropsYml = $cfg' \
                       /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia

                    # Extract self-defined environment variables
                    if SELF_ENV=$(echo "$SERVICE_CONFIG" | jq '.run.envVariables // {}' 2>/dev/null); then
                        if [ "$SELF_ENV" != "{}" ] && [ "$SELF_ENV" != "null" ]; then
                            jq --arg s "$service" --argjson env "$SELF_ENV" \
                               '.services[$s].selfDefinedEnvs = $env' \
                               /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
                        fi
                    fi

                    # Extract runtime information
                    START_CMD=$(echo "$SERVICE_CONFIG" | jq -r '.run.start // ""' 2>/dev/null)
                    PORT=$(echo "$SERVICE_CONFIG" | jq -r '.run.ports[0].port // ""' 2>/dev/null)
                    BUILD_CMD=$(echo "$SERVICE_CONFIG" | jq -r '.build.buildCommands[-1] // ""' 2>/dev/null)

                    if [ -n "$START_CMD" ] || [ -n "$PORT" ] || [ -n "$BUILD_CMD" ]; then
                        jq --arg s "$service" --arg start "$START_CMD" --arg port "$PORT" --arg build "$BUILD_CMD" \
                           '.services[$s].discoveredRuntime = {
                             "startCommand": $start,
                             "port": $port,
                             "buildCommand": $build
                           }' /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
                    fi
                fi
            fi
        fi
    fi
done

# Map deployment pairs
echo "🔗 Mapping deployment pairs..."
PAIR_COUNT=0

for dev in $(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia); do
    base=${dev%dev}

    if jq -e ".services[\"$base\"]" /var/www/.zaia >/dev/null 2>&1; then
        echo "  Paired: $dev → $base"
        jq --arg d "$dev" --arg s "$base" '.deploymentPairs[$d] = $s' \
           /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
        PAIR_COUNT=$((PAIR_COUNT + 1))
    fi
done

# Sync environment variables
echo "🔄 Syncing environment variables..."
sync_env_to_zaia

# Final summary
echo ""
echo "✅ PROJECT INITIALIZED SUCCESSFULLY"
echo "==================================="

# Display statistics
STATS=$(jq -r '
"Project: \(.project.name)
Project ID: \(.project.id)
Total Services: \(.services | length)
  Development: \([.services[] | select(.role=="development")] | length)
  Stage/Prod: \([.services[] | select(.role=="stage")] | length)
  Databases: \([.services[] | select(.role=="database")] | length)
  Cache: \([.services[] | select(.role=="cache")] | length)
  Storage: \([.services[] | select(.role=="storage")] | length)
Deployment Pairs: \(.deploymentPairs | length)"
' /var/www/.zaia)

echo "$STATS"

# Check for services needing attention
PENDING_IDS=$(jq -r '.services | to_entries[] | select(.value.id == "pending") | .key' /var/www/.zaia | wc -l)
if [ "$PENDING_IDS" -gt 0 ]; then
    echo ""
    echo "⚠️ Note: $PENDING_IDS services have pending IDs"
    echo "  This is normal for newly created services"
    echo "  Run 'sync_env_to_zaia' later to update"
fi

# Show next steps
echo ""
echo "💡 Next steps:"
echo "  - View details: /var/www/show_project_context.sh"
echo "  - Create services: /var/www/create_services.sh"
echo "  - Get recipes: /var/www/get_recipe.sh <framework>"
echo "  - Deploy: /var/www/deploy.sh <dev-service>"

# Cleanup
rm -f /tmp/project_export.yaml

exit 0
