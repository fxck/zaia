#!/bin/bash

echo "==================== PROJECT CONTEXT (.zaia ONLY) ===================="

if [ ! -f /var/www/.zaia ]; then
    echo "❌ FATAL: .zaia file not found. Run /var/www/init_state.sh first"
    exit 1
fi

if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ FATAL: .zaia file is corrupted. Run /var/www/init_state.sh"
    exit 1
fi

PROJECT_NAME=$(jq -r '.project.name' /var/www/.zaia)
PROJECT_ID=$(jq -r '.project.id' /var/www/.zaia)
LAST_SYNC=$(jq -r '.project.lastSync' /var/www/.zaia)

if [ "$PROJECT_NAME" = "null" ] || [ -z "$PROJECT_NAME" ]; then
    echo "❌ FATAL: Invalid project data in .zaia"
    exit 1
fi

echo "📋 Project: $PROJECT_NAME ($PROJECT_ID)"
echo "🕒 Last Sync: $LAST_SYNC"
echo ""

echo "🔧 SERVICES (.zaia ONLY):"
TOTAL_SERVICES=$(jq '.services | length' /var/www/.zaia)

if [ "$TOTAL_SERVICES" -gt 0 ]; then
    # Display services with enhanced information
    jq -r '.services | to_entries[] | "  \(.key) (\(.value.type)) - \(.value.role) - \(.value.mode) - ID: \(.value.id)"' /var/www/.zaia

    MISSING_IDS=$(jq -r '.services | to_entries[] | select(.value.id == "ID_NOT_FOUND" or .value.id == "" or .value.id == null) | .key' /var/www/.zaia)
    if [ -n "$MISSING_IDS" ]; then
        echo ""
        echo "⚠️  Services with missing IDs:"
        echo "$MISSING_IDS" | while read -r service; do
            echo "  - $service"
        done
        echo "  💡 Run /var/www/sync_env_to_zaia.sh to refresh API data"
    fi
else
    echo "  No services found in .zaia"
    echo "  💡 Run /var/www/discover_services.sh to discover services"
fi

echo ""
echo "🚀 DEPLOYMENT PAIRS (.zaia ONLY):"
DEPLOYMENT_PAIRS=$(jq '.deploymentPairs | length' /var/www/.zaia)

if [ "$DEPLOYMENT_PAIRS" -gt 0 ]; then
    jq -r '.deploymentPairs | to_entries[] | "  \(.key) → \(.value)"' /var/www/.zaia
else
    echo "  None configured"
fi

echo ""
echo "🌍 ENVIRONMENT VARIABLES (.zaia ONLY):"

# Count services with different types of environment variables
SERVICES_WITH_PROVIDED=$(jq -r '.services | to_entries[] | select(.value.serviceProvidedEnvs | length > 0) | .key' /var/www/.zaia | wc -l)
SERVICES_WITH_SELF_DEFINED=$(jq -r '.services | to_entries[] | select(.value.selfDefinedEnvs | length > 0) | .key' /var/www/.zaia | wc -l)

echo "  Services with provided env vars: $SERVICES_WITH_PROVIDED"
echo "  Services with self-defined env vars: $SERVICES_WITH_SELF_DEFINED"

if [ "$SERVICES_WITH_PROVIDED" -gt 0 ]; then
    echo ""
    echo "🔗 SERVICE-PROVIDED ENVIRONMENT VARIABLES:"
    jq -r '.services | to_entries[] | select(.value.serviceProvidedEnvs | length > 0) | "  \(.key): \(.value.serviceProvidedEnvs | length) variables (\(.value.serviceProvidedEnvs | join(", ")))"' /var/www/.zaia
fi

if [ "$SERVICES_WITH_SELF_DEFINED" -gt 0 ]; then
    echo ""
    echo "⚙️  SELF-DEFINED ENVIRONMENT VARIABLES:"
    jq -r '.services | to_entries[] | select(.value.selfDefinedEnvs | length > 0) | "  \(.key): \(.value.selfDefinedEnvs | keys | length) variables (\(.value.selfDefinedEnvs | keys | join(", ")))"' /var/www/.zaia
fi

# Show subdomains from .zaia
SERVICES_WITH_SUBDOMAINS=$(jq -r '.services | to_entries[] | select(.value.subdomain != null and .value.subdomain != "") | .key' /var/www/.zaia | wc -l)

if [ "$SERVICES_WITH_SUBDOMAINS" -gt 0 ]; then
    echo ""
    echo "🌐 PUBLIC URLs (.zaia ONLY):"
    jq -r '.services | to_entries[] | select(.value.subdomain != null and .value.subdomain != "") | "  \(.key): https://\(.value.subdomain)"' /var/www/.zaia
fi

echo ""
echo "🔧 RUNTIME CONFIGURATION (.zaia ONLY):"
SERVICES_WITH_RUNTIME=$(jq -r '.services | to_entries[] | select(.value.discoveredRuntime | length > 0) | .key' /var/www/.zaia | wc -l)

if [ "$SERVICES_WITH_RUNTIME" -gt 0 ]; then
    echo "  Services with discovered runtime: $SERVICES_WITH_RUNTIME"
    echo ""
    jq -r '.services | to_entries[] | select(.value.discoveredRuntime | length > 0) | "  \(.key):\n    Start: \(.value.discoveredRuntime.startCommand // "not found")\n    Port: \(.value.discoveredRuntime.port // "not found")\n    Build: \(.value.discoveredRuntime.buildCommand // "not found")"' /var/www/.zaia
else
    echo "  No runtime configuration discovered yet"
    echo "  💡 Run /var/www/discover_services.sh to analyze service configurations"
fi

echo ""
echo "📊 SUMMARY (.zaia ONLY):"
echo "  Total Services: $TOTAL_SERVICES"
echo "  Development: $(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia | wc -l)"
echo "  Stage/Prod: $(jq -r '.services | to_entries[] | select(.value.role == "stage") | .key' /var/www/.zaia | wc -l)"
echo "  Databases: $(jq -r '.services | to_entries[] | select(.value.role == "database") | .key' /var/www/.zaia | wc -l)"
echo "  Cache: $(jq -r '.services | to_entries[] | select(.value.role == "cache") | .key' /var/www/.zaia | wc -l)"

DEV_SERVICES=$(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia)
if [ -n "$DEV_SERVICES" ]; then
    echo ""
    echo "🚀 DEPLOYMENT READINESS (.zaia ONLY):"
    echo "$DEV_SERVICES" | while read -r dev_service; do
        STAGE_SERVICE=$(jq -r --arg dev "$dev_service" '.deploymentPairs[$dev] // "none"' /var/www/.zaia)
        if [ "$STAGE_SERVICE" != "none" ] && [ "$STAGE_SERVICE" != "null" ]; then
            STAGE_ID=$(jq -r --arg stage "$STAGE_SERVICE" '.services[$stage].id // "unknown"' /var/www/.zaia)
            if [ "$STAGE_ID" != "unknown" ] && [ "$STAGE_ID" != "ID_NOT_FOUND" ] && [ "$STAGE_ID" != "" ] && [ "$STAGE_ID" != "null" ]; then
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
echo "🛠️  ENVIRONMENT VARIABLE MANAGEMENT (.zaia ONLY):"
echo "  View service env vars:           get_available_envs <service_name>"
echo "  Get environment suggestions:     suggest_env_vars <service_name>"
echo "  Test database connectivity:      test_database_connectivity <service> <db_service>"
echo "  Check restart requirements:      needs_environment_restart <service> <other_service>"

echo ""
echo "🔄 STATE MANAGEMENT (.zaia ONLY):"
echo "  Sync environment data:           /var/www/sync_env_to_zaia.sh"
echo "  Update service discovery:        /var/www/discover_services.sh"
echo "  Get service ID:                  get_service_id <service_name>"
echo "  Get subdomain:                   get_service_subdomain <service_name>"

echo ""
echo "📈 DATA FRESHNESS (.zaia ONLY):"
if [ "$LAST_SYNC" != "null" ] && [ -n "$LAST_SYNC" ]; then
    SYNC_TIMESTAMP=$(date -d "$LAST_SYNC" +%s 2>/dev/null || echo "0")
    CURRENT_TIMESTAMP=$(date +%s)
    AGE_SECONDS=$((CURRENT_TIMESTAMP - SYNC_TIMESTAMP))

    if [ "$AGE_SECONDS" -gt 3600 ]; then  # 1 hour
        echo "  ⚠️  Environment data is older than 1 hour"
        echo "  💡 Consider running: /var/www/sync_env_to_zaia.sh"
    else
        echo "  ✅ Environment data is fresh"
    fi
else
    echo "  ⚠️  No sync timestamp found"
    echo "  💡 Run: /var/www/sync_env_to_zaia.sh"
fi

echo "========================================================"
