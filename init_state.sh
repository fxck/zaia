#!/bin/bash
set -e

source /var/www/validate_inputs.sh

echo "=== INITIALIZING PROJECT STATE (.zaia ONLY) ==="

# Check prerequisites
if [ -z "$ZEROPS_ACCESS_TOKEN" ]; then
    echo "❌ FATAL: ZEROPS_ACCESS_TOKEN not available"
    exit 1
fi

if [ -z "$projectId" ]; then
    echo "❌ FATAL: projectId not available"
    exit 1
fi

if ! zcli project list >/dev/null 2>&1; then
    echo "Authenticating..."
    if ! zcli login "$ZEROPS_ACCESS_TOKEN"; then
        echo "❌ FATAL: Authentication failed"
        exit 1
    fi
fi

# Backup existing .zaia if it exists
if [ -f /var/www/.zaia ]; then
    BACKUP_FILE="/var/www/.zaia.backup.$(date +%s)"
    cp /var/www/.zaia "$BACKUP_FILE"
    echo "Existing state backed up to: $BACKUP_FILE"
fi

echo "Fetching project configuration..."
if ! curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" \
     "https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/export" \
     -o /tmp/project_export.yaml; then
    echo "❌ FATAL: Failed to fetch project configuration"
    exit 1
fi

if ! jq -e '.yaml' /tmp/project_export.yaml >/dev/null 2>&1; then
    echo "❌ FATAL: Invalid export data - missing 'yaml' key"
    echo "Debug: Content of /tmp/project_export.yaml:"
    cat /tmp/project_export.yaml | head -n 10
    exit 1
fi

YAML_CONTENT=$(jq -r '.yaml' /tmp/project_export.yaml)
if [ -z "$YAML_CONTENT" ] || [ "$YAML_CONTENT" == "null" ]; then
    echo "❌ FATAL: Invalid YAML content in export"
    exit 1
fi

PROJECT_NAME=$(echo "$YAML_CONTENT" | yq e '.project.name' - 2>/dev/null)
if [ -z "$PROJECT_NAME" ] || [ "$PROJECT_NAME" == "null" ]; then
    echo "❌ FATAL: Could not extract project name from YAML content"
    echo "Debug: First few lines of YAML:"
    echo "$YAML_CONTENT" | head -n 10
    exit 1
fi

echo "Project name extracted: $PROJECT_NAME"

ZAIA_FILE_PATH="/var/www/.zaia"

# CLEAN: Initialize .zaia with unified structure (ONLY source of truth)
cat > "$ZAIA_FILE_PATH" << ZAIA_EOF
{
  "project": {
    "id": "$projectId",
    "name": "$PROJECT_NAME",
    "lastSync": "$(date -Iseconds)"
  },
  "services": {},
  "deploymentPairs": {}
}
ZAIA_EOF

# Verify .zaia was created correctly
if [ ! -f "$ZAIA_FILE_PATH" ] || ! jq empty "$ZAIA_FILE_PATH" 2>/dev/null; then
    echo "❌ FATAL: Failed to create valid .zaia file"
    exit 1
fi

echo "✅ .zaia initialized with project: $PROJECT_NAME"

echo "Discovering services..."
if [ -x "/var/www/discover_services.sh" ]; then
    if ! /var/www/discover_services.sh; then
        echo "❌ FATAL: Service discovery failed"
        exit 1
    fi
else
    echo "❌ FATAL: /var/www/discover_services.sh not found or not executable"
    exit 1
fi

echo "Syncing environment variables to .zaia..."
if [ -x "/var/www/sync_env_to_zaia.sh" ]; then
    if ! /var/www/sync_env_to_zaia.sh; then
        echo "⚠️  Warning: Environment sync failed - continuing with initialization"
        echo "   Run /var/www/sync_env_to_zaia.sh manually after initialization"
    fi
else
    echo "⚠️  Warning: /var/www/sync_env_to_zaia.sh not found"
    echo "   Environment variables will need to be synced manually"
fi

echo ""
echo "✅ PROJECT STATE READY (.zaia ONLY)"
echo "==================="

# Verify final state
if ! jq empty "$ZAIA_FILE_PATH" 2>/dev/null; then
    echo "❌ FATAL: .zaia file corrupted during initialization"
    exit 1
fi

TOTAL_SERVICES=$(jq '.services | length' "$ZAIA_FILE_PATH" 2>/dev/null || echo "0")
PROJECT_NAME_FINAL=$(jq -r '.project.name' "$ZAIA_FILE_PATH" 2>/dev/null || echo "unknown")

echo "Project: $PROJECT_NAME_FINAL ($projectId)"
echo "Services discovered: $TOTAL_SERVICES"

if [ "$TOTAL_SERVICES" -gt 0 ]; then
    echo ""
    echo "Service breakdown (.zaia):"
    jq -r '.services | to_entries[] | "  \(.key) (\(.value.type)) - \(.value.role)"' "$ZAIA_FILE_PATH" 2>/dev/null || echo "  Error reading service details"

    # Show environment variable status
    SERVICES_WITH_ENVS=$(jq -r '.services | to_entries[] | select(.value.serviceProvidedEnvs | length > 0) | .key' "$ZAIA_FILE_PATH" 2>/dev/null | wc -l)
    if [ "$SERVICES_WITH_ENVS" -gt 0 ]; then
        echo ""
        echo "Environment variable status (.zaia):"
        echo "  Services with env vars: $SERVICES_WITH_ENVS"
    fi
fi

MISSING_IDS=$(jq -r '.services | to_entries[] | select(.value.id == "ID_NOT_FOUND" or .value.id == "" or .value.id == null) | .key' "$ZAIA_FILE_PATH" 2>/dev/null | wc -l)
if [ "$MISSING_IDS" -gt 0 ]; then
    echo ""
    echo "⚠️  Note: $MISSING_IDS service(s) have missing IDs"
    echo "   This is normal for newly created services"
    echo "   Use /var/www/sync_env_to_zaia.sh to refresh API data"
fi

echo ""
echo "State file location: $ZAIA_FILE_PATH (.zaia ONLY)"
echo ""
echo "💡 Next steps (.zaia ONLY):"
echo "  - View project: /var/www/show_project_context.sh"
echo "  - Sync env data: /var/www/sync_env_to_zaia.sh"
echo "  - Check env vars: get_available_envs <service_name>"
echo "  - Get suggestions: suggest_env_vars <service_name>"

# Cleanup
rm -f /tmp/project_export.yaml
