#!/bin/bash
set -e

source /var/www/validate_inputs.sh

echo "=== INITIALIZING PROJECT STATE ==="

# Check authentication
if ! zcli project list >/dev/null 2>&1; then
    echo "Authenticating..."
    zcli login "$ZEROPS_ACCESS_TOKEN"
fi

# Backup existing state
if [ -f /var/www/.zaia ]; then
    cp /var/www/.zaia /var/www/.zaia.backup
    echo "Existing state backed up"
fi

# Get project export
echo "Fetching project configuration..."
if ! curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" \
     "https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/export" \
     -o /tmp/project_export.yaml; then
    echo "❌ Failed to fetch project configuration"
    exit 1
fi

# Validate export
# First check if the 'yaml' key exists and its content has a project name
if ! jq -e '.yaml' /tmp/project_export.yaml >/dev/null 2>&1 || \
   ! (jq -r '.yaml' /tmp/project_export.yaml | yq e '.project.name' - >/dev/null 2>&1); then
    echo "❌ Invalid export data or missing project name in YAML content."
    echo "Debug: Content of /tmp/project_export.yaml:"
    cat /tmp/project_export.yaml | head -n 10 # Show first few lines for debugging
    exit 1
fi

# Corrected line to extract project name
PROJECT_NAME=$(jq -r '.yaml' /tmp/project_export.yaml | yq e '.project.name' -)

# Initialize .zaia
# Ensure the directory for .zaia exists and is writable if not in /var/www
# For this script, it's creating ./.zaia, so it depends on where the script is run from.
# If you intend it to always be /var/www/.zaia, change the path:
ZAIA_FILE_PATH="/var/www/.zaia" # Define path for clarity

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

echo "State initialized with project name: $PROJECT_NAME. Discovering services..."
# Ensure discover_services.sh is executable and uses the correct path
if [ -x "/var/www/discover_services.sh" ]; then
    /var/www/discover_services.sh
else
    echo "❌ /var/www/discover_services.sh not found or not executable."
    exit 1
fi
echo "✅ Project state ready"
