#!/bin/bash
set -e

source /var/www/validate_inputs.sh

echo "=== INITIALIZING PROJECT STATE ==="

if ! zcli project list >/dev/null 2>&1; then
    echo "Authenticating..."
    zcli login "$ZEROPS_ACCESS_TOKEN"
fi

if [ -f /var/www/.zaia ]; then
    cp /var/www/.zaia /var/www/.zaia.backup
    echo "Existing state backed up"
fi

echo "Fetching project configuration..."
if ! curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" \
     "https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/export" \
     -o /tmp/project_export.yaml; then
    echo "❌ Failed to fetch project configuration"
    exit 1
fi

if ! jq -e '.yaml' /tmp/project_export.yaml >/dev/null 2>&1; then
    echo "❌ Invalid export data - missing 'yaml' key"
    echo "Debug: Content of /tmp/project_export.yaml:"
    cat /tmp/project_export.yaml | head -n 10
    exit 1
fi

YAML_CONTENT=$(jq -r '.yaml' /tmp/project_export.yaml)
if [ -z "$YAML_CONTENT" ] || [ "$YAML_CONTENT" == "null" ]; then
    echo "❌ Invalid YAML content in export"
    exit 1
fi

PROJECT_NAME=$(echo "$YAML_CONTENT" | yq e '.project.name' - 2>/dev/null)
if [ -z "$PROJECT_NAME" ] || [ "$PROJECT_NAME" == "null" ]; then
    echo "❌ Could not extract project name from YAML content"
    echo "Debug: First few lines of YAML:"
    echo "$YAML_CONTENT" | head -n 10
    exit 1
fi

echo "Project name extracted: $PROJECT_NAME"

echo "Fetching environment variables from API..."
if ! /var/www/get_service_envs.sh; then
    echo "⚠️  Warning: Failed to fetch environment variables from API"
    echo "   Continuing with initialization, but service IDs may be missing"
fi

ZAIA_FILE_PATH="/var/www/.zaia"

cat > "$ZAIA_FILE_PATH" << ZAIA_EOF
{
  "project": {
    "id": "$projectId",
    "name": "$PROJECT_NAME",
    "lastSync": "$(date -Iseconds)"
  },
  "services": {},
  "deploymentPairs": {},
  "envs": {}
}
ZAIA_EOF

echo "State initialized with project name: $PROJECT_NAME"

echo "Discovering services..."
if [ -x "/var/www/discover_services.sh" ]; then
    /var/www/discover_services.sh
else
    echo "❌ /var/www/discover_services.sh not found or not executable."
    exit 1
fi

echo ""
echo "✅ PROJECT STATE READY"
echo "==================="
TOTAL_SERVICES=$(jq '.services | length' "$ZAIA_FILE_PATH" 2>/dev/null || echo "0")
echo "Project: $PROJECT_NAME ($projectId)"
echo "Services discovered: $TOTAL_SERVICES"

if [ "$TOTAL_SERVICES" -gt 0 ]; then
    echo ""
    echo "Service breakdown:"
    jq -r '.services | to_entries[] | "  \(.key) (\(.value.type)) - \(.value.role)"' "$ZAIA_FILE_PATH" 2>/dev/null || echo "  Error reading service details"
fi

MISSING_IDS=$(jq -r '.services | to_entries[] | select(.value.id == "ID_NOT_FOUND") | .key' "$ZAIA_FILE_PATH" 2>/dev/null | wc -l)
if [ "$MISSING_IDS" -gt 0 ]; then
    echo ""
    echo "⚠️  Note: $MISSING_IDS service(s) have missing IDs"
    echo "   This is normal for newly created services before agent restart"
    echo "   Use /var/www/get_service_envs.sh to refresh API data"
fi

echo ""
echo "State file location: $ZAIA_FILE_PATH"
echo "Use /var/www/show_project_context.sh to view detailed project information"
