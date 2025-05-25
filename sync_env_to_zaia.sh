#!/bin/bash
set -e

echo "=== SYNCING ENVIRONMENT VARIABLES TO .ZAIA (ONLY SOURCE) ==="

# Check prerequisites
if [ -z "$ZEROPS_ACCESS_TOKEN" ]; then
    echo "❌ FATAL: ZEROPS_ACCESS_TOKEN not available"
    exit 1
fi

if [ -z "$projectId" ]; then
    echo "❌ FATAL: projectId not available"
    exit 1
fi

if [ ! -f /var/www/.zaia ]; then
    echo "❌ FATAL: .zaia file not found. Run init_state.sh first"
    exit 1
fi

if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ FATAL: .zaia file is corrupted. Run init_state.sh"
    exit 1
fi

# Fetch fresh environment data from API
API_URL="https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/env-file-download"
TEMP_ENV_FILE="/tmp/api_envs_$(date +%s).env"

echo "Fetching environment variables from API..."
if ! curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" "$API_URL" -o "$TEMP_ENV_FILE"; then
    echo "❌ FATAL: Failed to fetch environment variables from API"
    exit 1
fi

if [ ! -s "$TEMP_ENV_FILE" ]; then
    echo "❌ FATAL: API returned empty environment data"
    rm -f "$TEMP_ENV_FILE"
    exit 1
fi

echo "✅ Environment variables fetched from API"

# Update .zaia with environment variable data
echo "Updating .zaia with environment variable data..."

# Create working copy
cp /var/www/.zaia /tmp/.zaia.work

# Get list of services from .zaia
services=$(jq -r '.services | keys[]' /var/www/.zaia)

if [ -z "$services" ]; then
    echo "❌ FATAL: No services found in .zaia. Run discover_services.sh first"
    rm -f "$TEMP_ENV_FILE" /tmp/.zaia.work
    exit 1
fi

for service in $services; do
    echo "Processing environment variables for service: $service"

    # Extract service-provided environment variables (from other services)
    service_provided_envs=$(grep "^${service}_" "$TEMP_ENV_FILE" 2>/dev/null | cut -d= -f1 | jq -R . | jq -s . || echo "[]")

    # Update .zaia with service-provided environment variables
    jq --arg svc "$service" --argjson envs "$service_provided_envs" \
       '.services[$svc].serviceProvidedEnvs = $envs' /tmp/.zaia.work > /tmp/.zaia.work2
    mv /tmp/.zaia.work2 /tmp/.zaia.work

    # Extract and update service ID if available
    service_id=$(grep "^${service}_serviceId=" "$TEMP_ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "")
    if [ -n "$service_id" ]; then
        current_id=$(jq -r --arg svc "$service" '.services[$svc].id // ""' /tmp/.zaia.work)
        if [ "$current_id" = "" ] || [ "$current_id" = "ID_NOT_FOUND" ]; then
            echo "  Updating service ID for $service: $service_id"
            jq --arg svc "$service" --arg id "$service_id" \
               '.services[$svc].id = $id' /tmp/.zaia.work > /tmp/.zaia.work2
            mv /tmp/.zaia.work2 /tmp/.zaia.work
        fi
    fi

    # Extract and update subdomain if available
    service_subdomain=$(grep "^${service}_zeropsSubdomain=" "$TEMP_ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "")
    if [ -n "$service_subdomain" ]; then
        echo "  Updating subdomain for $service: $service_subdomain"
        jq --arg svc "$service" --arg sub "$service_subdomain" \
           '.services[$svc].subdomain = $sub' /tmp/.zaia.work > /tmp/.zaia.work2
        mv /tmp/.zaia.work2 /tmp/.zaia.work
    fi
done

# Update sync timestamp and write final .zaia
jq --arg ts "$(date -Iseconds)" '.project.lastSync = $ts' /tmp/.zaia.work > /var/www/.zaia

# Verify .zaia is still valid after update
if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ FATAL: .zaia corrupted during update. Restoring from backup"
    if [ -f /var/www/.zaia.backup ]; then
        cp /var/www/.zaia.backup /var/www/.zaia
    fi
    rm -f "$TEMP_ENV_FILE" /tmp/.zaia.work*
    exit 1
fi

echo "✅ Environment variables synced to .zaia"

# Summary
echo ""
echo "📊 SYNC SUMMARY:"
TOTAL_VARS=$(wc -l < "$TEMP_ENV_FILE")
SERVICE_IDS=$(grep "_serviceId=" "$TEMP_ENV_FILE" | wc -l)
SUBDOMAINS=$(grep "_zeropsSubdomain=" "$TEMP_ENV_FILE" | wc -l)

echo "  Total API variables: $TOTAL_VARS"
echo "  Service IDs: $SERVICE_IDS"
echo "  Subdomains: $SUBDOMAINS"

# Show services with available environment variables
echo ""
echo "🔗 SERVICES WITH ENVIRONMENT VARIABLES (.zaia):"
for service in $services; do
    env_count=$(jq -r --arg svc "$service" '.services[$svc].serviceProvidedEnvs | length' /var/www/.zaia)
    if [ "$env_count" -gt 0 ]; then
        echo "  $service: $env_count variables available"
    fi
done

# Cleanup
rm -f "$TEMP_ENV_FILE" /tmp/.zaia.work*

echo ""
echo "✅ .zaia is the ONLY source of truth for all environment variable data"
