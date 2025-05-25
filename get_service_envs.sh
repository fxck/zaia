#!/bin/bash
set -e

echo "=== ENVIRONMENT VARIABLE MANAGEMENT (.zaia ONLY) ==="

# Check if .zaia exists
if [ ! -f /var/www/.zaia ]; then
    echo "❌ FATAL: .zaia file not found"
    echo "   Run /var/www/init_state.sh first to initialize project state"
    exit 1
fi

if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ FATAL: .zaia file is corrupted"
    echo "   Run /var/www/init_state.sh to reinitialize"
    exit 1
fi

echo "ℹ️  This script uses the unified .zaia system as the ONLY source of truth"
echo "   All environment variables are managed through .zaia - NO FALLBACKS"
echo ""

# Always sync environment data to .zaia (this is now the core functionality)
echo "🔄 Syncing environment variables to .zaia..."
if ! /var/www/sync_env_to_zaia.sh; then
    echo "❌ FATAL: Failed to sync environment variables to .zaia"
    exit 1
fi

echo ""
echo "📊 ENVIRONMENT VARIABLE SUMMARY (.zaia ONLY):"

# Show summary from .zaia
TOTAL_SERVICES=$(jq '.services | length' /var/www/.zaia)
SERVICES_WITH_PROVIDED_ENVS=$(jq -r '.services | to_entries[] | select(.value.serviceProvidedEnvs | length > 0) | .key' /var/www/.zaia | wc -l)
SERVICES_WITH_SELF_DEFINED=$(jq -r '.services | to_entries[] | select(.value.selfDefinedEnvs | length > 0) | .key' /var/www/.zaia | wc -l)

echo "  Total Services: $TOTAL_SERVICES"
echo "  With Service-Provided Env Vars: $SERVICES_WITH_PROVIDED_ENVS"
echo "  With Self-Defined Env Vars: $SERVICES_WITH_SELF_DEFINED"

if [ "$SERVICES_WITH_PROVIDED_ENVS" -gt 0 ]; then
    echo ""
    echo "🔗 SERVICES WITH AVAILABLE ENVIRONMENT VARIABLES:"
    jq -r '.services | to_entries[] | select(.value.serviceProvidedEnvs | length > 0) | "  \(.key): \(.value.serviceProvidedEnvs | length) variables"' /var/www/.zaia
fi

# Show service IDs and subdomains if available
SERVICES_WITH_IDS=$(jq -r '.services | to_entries[] | select(.value.id != "ID_NOT_FOUND" and .value.id != "" and .value.id != null) | .key' /var/www/.zaia | wc -l)
if [ "$SERVICES_WITH_IDS" -gt 0 ]; then
    echo ""
    echo "🆔 SERVICE IDs (.zaia):"
    jq -r '.services | to_entries[] | select(.value.id != "ID_NOT_FOUND" and .value.id != "" and .value.id != null) | "  \(.key): \(.value.id)"' /var/www/.zaia
fi

SERVICES_WITH_SUBDOMAINS=$(jq -r '.services | to_entries[] | select(.value.subdomain != null and .value.subdomain != "") | .key' /var/www/.zaia | wc -l)
if [ "$SERVICES_WITH_SUBDOMAINS" -gt 0 ]; then
    echo ""
    echo "🌐 AVAILABLE SUBDOMAINS (.zaia):"
    jq -r '.services | to_entries[] | select(.value.subdomain != null and .value.subdomain != "") | "  \(.key): https://\(.value.subdomain)"' /var/www/.zaia
fi

echo ""
echo "💡 ENVIRONMENT VARIABLE FUNCTIONS (.zaia ONLY):"
echo "  View env vars for a service:     get_available_envs <service_name>"
echo "  Get environment suggestions:     suggest_env_vars <service_name>"
echo "  Test database connectivity:      test_database_connectivity <service> <db_service>"
echo "  Check restart requirements:      needs_environment_restart <service> <other_service>"
echo "  Get service ID:                  get_service_id <service_name>"
echo "  Get subdomain:                   get_service_subdomain <service_name>"

echo ""
echo "🔄 STATE MANAGEMENT:"
echo "  Sync environment data:           /var/www/sync_env_to_zaia.sh"
echo "  Update service discovery:        /var/www/discover_services.sh"
echo "  Show project context:            /var/www/show_project_context.sh"

echo ""
echo "✅ Environment variable data is available in .zaia (ONLY source of truth)"

# Show freshness warning if data is old
LAST_SYNC=$(jq -r '.project.lastSync // "never"' /var/www/.zaia)
if [ "$LAST_SYNC" != "never" ]; then
    SYNC_TIMESTAMP=$(date -d "$LAST_SYNC" +%s 2>/dev/null || echo "0")
    CURRENT_TIMESTAMP=$(date +%s)
    AGE_SECONDS=$((CURRENT_TIMESTAMP - SYNC_TIMESTAMP))

    if [ "$AGE_SECONDS" -gt 3600 ]; then  # 1 hour
        echo ""
        echo "⚠️  WARNING: Environment data is older than 1 hour"
        echo "   Consider running: /var/www/sync_env_to_zaia.sh"
    fi
fi
