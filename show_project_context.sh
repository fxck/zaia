#!/bin/bash

echo "==================== PROJECT CONTEXT ===================="

if [ ! -f /var/www/.zaia ]; then
    echo "❌ No state file. Run /var/www/init_state.sh first"
    exit 1
fi

# Validate JSON
if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ Corrupted state file. Run /var/www/init_state.sh"
    exit 1
fi

PROJECT_NAME=$(jq -r '.project.name' /var/www/.zaia)
PROJECT_ID=$(jq -r '.project.id' /var/www/.zaia)
LAST_SYNC=$(jq -r '.project.lastSync' /var/www/.zaia)

echo "📋 Project: $PROJECT_NAME ($PROJECT_ID)"
echo "🕒 Last Sync: $LAST_SYNC"
echo ""

echo "🔧 SERVICES:"
jq -r '.services | to_entries[] | "  \(.key) (\(.value.type)) - \(.value.role) - \(.value.mode)"' /var/www/.zaia

echo ""
echo "🚀 DEPLOYMENT PAIRS:"
if [ "$(jq '.deploymentPairs | length' /var/www/.zaia)" -gt 0 ]; then
    jq -r '.deploymentPairs | to_entries[] | "  \(.key) → \(.value)"' /var/www/.zaia
else
    echo "  None configured"
fi

echo ""
echo "🌍 ENVIRONMENT VARIABLES:"
jq -r '.envs | to_entries[] | select(.value | length > 0) | "  \(.key): \(.value | length) variables"' /var/www/.zaia

echo ""
echo "📊 SUMMARY:"
echo "  Total Services: $(jq '.services | length' /var/www/.zaia)"
echo "  Development: $(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia | wc -l)"
echo "  Stage/Prod: $(jq -r '.services | to_entries[] | select(.value.role == "stage") | .key' /var/www/.zaia | wc -l)"
echo "  Databases: $(jq -r '.services | to_entries[] | select(.value.role == "database") | .key' /var/www/.zaia | wc -l)"
echo "  Cache: $(jq -r '.services | to_entries[] | select(.value.role == "cache") | .key' /var/www/.zaia | wc -l)"

echo "========================================================"
