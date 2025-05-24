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
if ! yq e '.project.name' /tmp/project_export.yaml >/dev/null 2>&1; then
    echo "❌ Invalid export data"
    exit 1
fi

PROJECT_NAME=$(yq e '.project.name' /tmp/project_export.yaml)

# Initialize .zaia
cat > ./.zaia << ZAIA_EOF
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

echo "State initialized, discovering services..."
/var/www/discover_services.sh
echo "✅ Project state ready"
