#!/bin/bash

echo "==================== PROJECT CONTEXT ===================="

if [ ! -f /var/www/.zaia ]; then
    echo "❌ No state file. Run /var/www/init_state.sh first"
    exit 1
fi

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
if [ "$(jq '.services | length' /var/www/.zaia)" -gt 0 ]; then
    jq -r '.services | to_entries[] | "  \(.key) (\(.value.type)) - \(.value.role) - \(.value.mode) - ID: \(.value.id)"' /var/www/.zaia

    MISSING_IDS=$(jq -r '.services | to_entries[] | select(.value.id == "ID_NOT_FOUND") | .key' /var/www/.zaia)
    if [ -n "$MISSING_IDS" ]; then
        echo ""
        echo "⚠️  Services with missing IDs:"
        echo "$MISSING_IDS" | while read -r service; do
            echo "  - $service"
        done
        echo "  💡 Run /var/www/get_service_envs.sh to refresh API data"
    fi
else
    echo "  No services found"
fi

echo ""
echo "🚀 DEPLOYMENT PAIRS:"
if [ "$(jq '.deploymentPairs | length' /var/www/.zaia)" -gt 0 ]; then
    jq -r '.deploymentPairs | to_entries[] | "  \(.key) → \(.value)"' /var/www/.zaia
else
    echo "  None configured"
fi

echo ""
echo "🌍 ENVIRONMENT VARIABLES:"
if [ "$(jq '.envs | length' /var/www/.zaia)" -gt 0 ]; then
    jq -r '.envs | to_entries[] | select(.value | length > 0) | "  \(.key): \(.value | length) variables"' /var/www/.zaia

    if [ -f "/tmp/current_envs.env" ]; then
        echo ""
        echo "🔑 API-Discovered Variables:"
        SERVICE_ID_COUNT=$(grep "_serviceId=" /tmp/current_envs.env 2>/dev/null | wc -l || echo "0")
        SUBDOMAIN_COUNT=$(grep "_zeropsSubdomain=" /tmp/current_envs.env 2>/dev/null | wc -l || echo "0")
        echo "  Service IDs available: $SERVICE_ID_COUNT"
        echo "  Subdomains available: $SUBDOMAIN_COUNT"

        if [ "$SUBDOMAIN_COUNT" -gt 0 ]; then
            echo ""
            echo "🌐 Public URLs:"
            grep "_zeropsSubdomain=" /tmp/current_envs.env | while IFS= read -r line; do
                SERVICE_NAME=$(echo "$line" | cut -d_ -f1)
                SUBDOMAIN=$(echo "$line" | cut -d= -f2)
                echo "  $SERVICE_NAME: https://$SUBDOMAIN"
            done
        fi
    else
        echo "  💡 Run /var/www/get_service_envs.sh to discover API variables"
    fi
else
    echo "  No environment variables discovered"
fi

echo ""
echo "📊 SUMMARY:"
echo "  Total Services: $(jq '.services | length' /var/www/.zaia)"
echo "  Development: $(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia | wc -l)"
echo "  Stage/Prod: $(jq -r '.services | to_entries[] | select(.value.role == "stage") | .key' /var/www/.zaia | wc -l)"
echo "  Databases: $(jq -r '.services | to_entries[] | select(.value.role == "database") | .key' /var/www/.zaia | wc -l)"
echo "  Cache: $(jq -r '.services | to_entries[] | select(.value.role == "cache") | .key' /var/www/.zaia | wc -l)"

DEV_SERVICES=$(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia)
if [ -n "$DEV_SERVICES" ]; then
    echo ""
    echo "🚀 DEPLOYMENT READINESS:"
    echo "$DEV_SERVICES" | while read -r dev_service; do
        STAGE_SERVICE=$(jq -r --arg dev "$dev_service" '.deploymentPairs[$dev] // "none"' /var/www/.zaia)
        if [ "$STAGE_SERVICE" != "none" ]; then
            STAGE_ID=$(jq -r --arg stage "$STAGE_SERVICE" '.services[$stage].id // "unknown"' /var/www/.zaia)
            if [ "$STAGE_ID" != "unknown" ] && [ "$STAGE_ID" != "ID_NOT_FOUND" ]; then
                echo "  ✅ $dev_service → $STAGE_SERVICE (ready for deployment)"
            else
                echo "  ⚠️  $dev_service → $STAGE_SERVICE (stage ID missing)"
            fi
        else
            echo "  ❌ $dev_service (no stage service paired)"
        fi
    done
fi

echo ""
echo "🛠️  QUICK COMMANDS:"
echo "  Refresh environment: /var/www/get_service_envs.sh"
echo "  Update discovery: /var/www/discover_services.sh"
echo "  Get recipe: /var/www/get_recipe.sh <technology>"

echo "========================================================"
