#!/bin/bash
set -e

if ! command -v validate_service_name > /dev/null 2>&1; then
    if [ -f "/var/www/validate_inputs.sh" ]; then
        source "/var/www/validate_inputs.sh"
    else
        echo "❌ FATAL: /var/www/validate_inputs.sh not found. Cannot proceed."
        exit 1
    fi
fi

echo "=== DISCOVERING SERVICES (.zaia ONLY) ==="

PROJECT_EXPORT_FILE="/tmp/project_export.yaml"

if [ ! -f "$PROJECT_EXPORT_FILE" ]; then
    echo "❌ FATAL: $PROJECT_EXPORT_FILE not found. Run init_state.sh first."
    exit 1
fi

YAML_CONTENT=$(jq -r '.yaml' "$PROJECT_EXPORT_FILE" 2>/dev/null)
if [ -z "$YAML_CONTENT" ] || [ "$YAML_CONTENT" == "null" ]; then
    echo "❌ FATAL: YAML_CONTENT is empty. Check $PROJECT_EXPORT_FILE and jq extraction."
    exit 1
fi

echo "Fetching current service statuses from zcli..."
if ! zcli service list --projectId "$projectId" > /tmp/service_status.txt; then
    echo "❌ FATAL: Failed to fetch service list from zcli"
    exit 1
fi

ZAIA_STATE_FILE="/var/www/.zaia"
if [ ! -f "$ZAIA_STATE_FILE" ]; then
    echo "❌ FATAL: State file $ZAIA_STATE_FILE missing. Run init_state.sh first."
    exit 1
fi

if ! jq empty "$ZAIA_STATE_FILE" 2>/dev/null; then
    echo "❌ FATAL: .zaia file is corrupted. Run init_state.sh"
    exit 1
fi

# Create working copy
cp "$ZAIA_STATE_FILE" /tmp/.zaia.work

declare -A DEV_SERVICE_FULL_ZEROPS_YMLS

SERVICE_HOSTNAMES_ALL=$(echo "$YAML_CONTENT" | yq e '.services[].hostname' -)
echo "Found service hostnames from YAML: $SERVICE_HOSTNAMES_ALL"

echo "--- Phase 1: Service Discovery & Configuration Processing ---"
for service_hostname in $SERVICE_HOSTNAMES_ALL; do
    if [ "$service_hostname" == "zaia" ]; then
        echo "Skipping 'zaia' service (agent container itself)."
        continue
    fi

    if ! validate_service_name "$service_hostname"; then
        echo "⚠️  Skipping invalid service hostname: $service_hostname"
        continue
    fi

    echo "Processing (Phase 1) $service_hostname..."
    SERVICE_TYPE=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service_hostname\") | .type // \"unknown-type\"" -)
    SERVICE_MODE=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service_hostname\") | .mode // \"unknown-mode\"" -)

    # Determine service role
    ROLE="stage"
    if [[ $service_hostname == *"dev" ]]; then ROLE="development"; fi
    if [[ "$SERVICE_TYPE" =~ ^(postgresql|mariadb|mongodb|mysql) ]]; then ROLE="database"; fi
    if [[ "$SERVICE_TYPE" =~ ^(redis|keydb|valkey) ]]; then ROLE="cache"; fi
    echo "Determined ROLE for $service_hostname: $ROLE"

    # Initialize service in .zaia with clean structure
    jq --arg hn "$service_hostname" --arg typ "$SERVICE_TYPE" --arg rl "$ROLE" --arg md "$SERVICE_MODE" \
       '.services[$hn] = {
           "id": (.services[$hn].id // "ID_NOT_FOUND"),
           "type": $typ,
           "role": $rl,
           "mode": $md,
           "actualZeropsYml": (.services[$hn].actualZeropsYml // null),
           "serviceProvidedEnvs": (.services[$hn].serviceProvidedEnvs // []),
           "selfDefinedEnvs": (.services[$hn].selfDefinedEnvs // {}),
           "subdomain": (.services[$hn].subdomain // null),
           "discoveredRuntime": (.services[$hn].discoveredRuntime // {})
       }' /tmp/.zaia.work > /tmp/.zaia.work2 && mv /tmp/.zaia.work2 /tmp/.zaia.work

    # For runtime services, try to SSH and get zerops.yml
    SPECIFIC_SETUP_BLOCK_JSON="null"

    if [[ "$SERVICE_TYPE" =~ ^(nodejs|php|python|go|rust|dotnet|java|bun|deno|gleam|elixir|ruby|static) ]]; then
        echo "Attempting SSH into $service_hostname for its zerops.yml..."
        RAW_SERVICE_YML_CONTENT=""

        if timeout 15 ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "zerops@$service_hostname" "echo 'SSH_OK'" 2>/dev/null; then
            RAW_SERVICE_YML_CONTENT=$(timeout 15 ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "zerops@$service_hostname" "cat /var/www/zerops.yml 2>/dev/null || cat /var/www/zerops.yaml 2>/dev/null || echo ''" 2>/dev/null)

            if [ -n "$RAW_SERVICE_YML_CONTENT" ]; then
                echo "Found zerops.yml/yaml on $service_hostname."

                # Extract specific setup block for this service
                SETUP_BLOCK_TEMP=$(echo "$RAW_SERVICE_YML_CONTENT" | yq e ".zerops[] | select(.setup == \"$service_hostname\") | ." -o=json -I0 2>/dev/null || echo "null")
                if [ "$SETUP_BLOCK_TEMP" != "null" ] && [ -n "$SETUP_BLOCK_TEMP" ]; then
                    SPECIFIC_SETUP_BLOCK_JSON="$SETUP_BLOCK_TEMP"
                    echo "Extracted specific setup block for $service_hostname from its own zerops.yml."

                    # Extract self-defined environment variables from the setup block
                    SELF_DEFINED_ENVS=$(echo "$SETUP_BLOCK_TEMP" | jq '.run.envVariables // {}' 2>/dev/null || echo "{}")
                    if [ "$SELF_DEFINED_ENVS" != "{}" ]; then
                        echo "Found self-defined environment variables in zerops.yml"
                        jq --arg hn "$service_hostname" --argjson envs "$SELF_DEFINED_ENVS" \
                           '.services[$hn].selfDefinedEnvs = $envs' /tmp/.zaia.work > /tmp/.zaia.work2 && mv /tmp/.zaia.work2 /tmp/.zaia.work
                    fi

                    # Extract runtime information
                    START_CMD=$(echo "$SETUP_BLOCK_TEMP" | jq -r '.run.start // ""' 2>/dev/null)
                    PORT=$(echo "$SETUP_BLOCK_TEMP" | jq -r '.run.ports[0].port // ""' 2>/dev/null)
                    BUILD_CMD=$(echo "$SETUP_BLOCK_TEMP" | jq -r '.build.buildCommands[-1] // ""' 2>/dev/null)

                    if [ -n "$START_CMD" ] || [ -n "$PORT" ] || [ -n "$BUILD_CMD" ]; then
                        RUNTIME_JSON=$(jq -n --arg start "$START_CMD" --arg port "$PORT" --arg build "$BUILD_CMD" \
                                       '{startCommand: $start, port: $port, buildCommand: $build, lastAnalyzed: now | todate}')
                        jq --arg hn "$service_hostname" --argjson runtime "$RUNTIME_JSON" \
                           '.services[$hn].discoveredRuntime = $runtime' /tmp/.zaia.work > /tmp/.zaia.work2 && mv /tmp/.zaia.work2 /tmp/.zaia.work
                    fi
                else
                    echo "No specific setup block for '$service_hostname' found in its own zerops.yml."
                fi

                # Store full zerops.yml for dev services (for stage service discovery in Phase 2)
                if [ "$ROLE" == "development" ]; then
                    DEV_SERVICE_FULL_ZEROPS_YMLS["$service_hostname"]="$RAW_SERVICE_YML_CONTENT"
                    echo "Stored full zerops.yml from dev service $service_hostname for Phase 2."
                fi
            else
                echo "No zerops.yml/yaml found or content is empty on $service_hostname."
            fi
        else
            echo "SSH failed or timed out for $service_hostname."
        fi
    fi

    # Update actualZeropsYml in .zaia
    jq --arg hn "$service_hostname" --argjson zyml "$SPECIFIC_SETUP_BLOCK_JSON" \
       '.services[$hn].actualZeropsYml = $zyml' /tmp/.zaia.work > /tmp/.zaia.work2 && mv /tmp/.zaia.work2 /tmp/.zaia.work
done
echo "--- Phase 1 completed ---"

echo "Mapping deployment pairs..."
ALL_HNS_FOR_PAIRS=$(echo "$YAML_CONTENT" | yq e '.services[].hostname' - 2>/dev/null || echo "")
DEV_HNS_FOR_PAIRS=$(echo "$ALL_HNS_FOR_PAIRS" | grep "dev$" | grep -v "^zaia$" || echo "")

# Clear existing deployment pairs and rebuild
jq '.deploymentPairs = {}' /tmp/.zaia.work > /tmp/.zaia.work2 && mv /tmp/.zaia.work2 /tmp/.zaia.work

if [ -n "$DEV_HNS_FOR_PAIRS" ]; then
    for dev_hn in $DEV_HNS_FOR_PAIRS; do
        base_name=${dev_hn%dev}
        if echo "$ALL_HNS_FOR_PAIRS" | grep -Fxq "$base_name"; then
            echo "Found deployment pair: $dev_hn -> $base_name"
            jq --arg dh "$dev_hn" --arg sh "$base_name" '.deploymentPairs[$dh] = $sh' /tmp/.zaia.work > /tmp/.zaia.work2 && mv /tmp/.zaia.work2 /tmp/.zaia.work
        fi
    done
else
    echo "No 'dev' services (excluding 'zaia') found to map for deployment pairs."
fi

echo "--- Phase 2: Stage Service Configuration from Dev Pairs ---"
DEPLOYMENT_PAIRS_JSON=$(jq '.deploymentPairs' /tmp/.zaia.work 2>/dev/null || echo "{}")

if [ "$(echo "$DEPLOYMENT_PAIRS_JSON" | jq 'length')" -gt 0 ]; then
    echo "$DEPLOYMENT_PAIRS_JSON" | jq -c 'to_entries[]' | while IFS= read -r entry; do
        DEV_SERVICE_HOSTNAME=$(echo "$entry" | jq -r '.key')
        STAGE_SERVICE_HOSTNAME=$(echo "$entry" | jq -r '.value')
        echo "Processing pair: Dev '$DEV_SERVICE_HOSTNAME' -> Stage '$STAGE_SERVICE_HOSTNAME'"

        FULL_DEV_YML_CONTENT="${DEV_SERVICE_FULL_ZEROPS_YMLS[$DEV_SERVICE_HOSTNAME]}"
        if [ -n "$FULL_DEV_YML_CONTENT" ]; then
            echo "Found stored full zerops.yml from dev service '$DEV_SERVICE_HOSTNAME'."
            STAGE_SETUP_BLOCK_FROM_DEV_YML=$(echo "$FULL_DEV_YML_CONTENT" | yq e ".zerops[] | select(.setup == \"$STAGE_SERVICE_HOSTNAME\") | ." -o=json -I0 2>/dev/null || echo "null")

            if [ "$STAGE_SETUP_BLOCK_FROM_DEV_YML" != "null" ] && [ -n "$STAGE_SETUP_BLOCK_FROM_DEV_YML" ]; then
                echo "Extracted setup block for '$STAGE_SERVICE_HOSTNAME' from '$DEV_SERVICE_HOSTNAME's yml. Updating stage service."

                # Update stage service with setup block
                TEMP_STATE=$(jq --arg sh "$STAGE_SERVICE_HOSTNAME" --argjson yml_block "$STAGE_SETUP_BLOCK_FROM_DEV_YML" \
                   '.services[$sh].actualZeropsYml = $yml_block' /tmp/.zaia.work)
                echo "$TEMP_STATE" > /tmp/.zaia.work

                # Extract self-defined environment variables for stage service
                STAGE_SELF_DEFINED_ENVS=$(echo "$STAGE_SETUP_BLOCK_FROM_DEV_YML" | jq '.run.envVariables // {}' 2>/dev/null || echo "{}")
                if [ "$STAGE_SELF_DEFINED_ENVS" != "{}" ]; then
                    echo "Found self-defined environment variables for stage service"
                    TEMP_STATE=$(jq --arg sh "$STAGE_SERVICE_HOSTNAME" --argjson envs "$STAGE_SELF_DEFINED_ENVS" \
                       '.services[$sh].selfDefinedEnvs = $envs' /tmp/.zaia.work)
                    echo "$TEMP_STATE" > /tmp/.zaia.work
                fi

                # Extract runtime information for stage service
                STAGE_START_CMD=$(echo "$STAGE_SETUP_BLOCK_FROM_DEV_YML" | jq -r '.run.start // ""' 2>/dev/null)
                STAGE_PORT=$(echo "$STAGE_SETUP_BLOCK_FROM_DEV_YML" | jq -r '.run.ports[0].port // ""' 2>/dev/null)
                STAGE_BUILD_CMD=$(echo "$STAGE_SETUP_BLOCK_FROM_DEV_YML" | jq -r '.build.buildCommands[-1] // ""' 2>/dev/null)

                if [ -n "$STAGE_START_CMD" ] || [ -n "$STAGE_PORT" ] || [ -n "$STAGE_BUILD_CMD" ]; then
                    STAGE_RUNTIME_JSON=$(jq -n --arg start "$STAGE_START_CMD" --arg port "$STAGE_PORT" --arg build "$STAGE_BUILD_CMD" \
                                   '{startCommand: $start, port: $port, buildCommand: $build, lastAnalyzed: now | todate}')
                    TEMP_STATE=$(jq --arg sh "$STAGE_SERVICE_HOSTNAME" --argjson runtime "$STAGE_RUNTIME_JSON" \
                       '.services[$sh].discoveredRuntime = $runtime' /tmp/.zaia.work)
                    echo "$TEMP_STATE" > /tmp/.zaia.work
                fi
            else
                echo "No specific setup block for '$STAGE_SERVICE_HOSTNAME' found in '$DEV_SERVICE_HOSTNAME's zerops.yml."
            fi
        else
            echo "Full zerops.yml for dev service '$DEV_SERVICE_HOSTNAME' was not found/stored in Phase 1."
        fi
    done
else
    echo "No deployment pairs found to process for Phase 2."
fi
echo "--- Phase 2 completed ---"

echo "Finalizing .zaia state file..."
jq --arg ts "$(date -Iseconds)" '.project.lastSync = $ts' /tmp/.zaia.work > "$ZAIA_STATE_FILE"

# Verify final .zaia is valid
if ! jq empty "$ZAIA_STATE_FILE" 2>/dev/null; then
    echo "❌ FATAL: .zaia corrupted during discovery process"
    if [ -f "${ZAIA_STATE_FILE}.backup" ]; then
        cp "${ZAIA_STATE_FILE}.backup" "$ZAIA_STATE_FILE"
        echo "Restored from backup"
    fi
    rm -f /tmp/.zaia.work*
    exit 1
fi

echo "✅ Discovery completed (.zaia ONLY)"

# Create backup
cp "$ZAIA_STATE_FILE" "${ZAIA_STATE_FILE}.backup"
echo "Backup created: ${ZAIA_STATE_FILE}.backup"

echo ""
echo "📊 DISCOVERY SUMMARY (.zaia ONLY):"
TOTAL_SERVICES=$(jq '.services | length' "$ZAIA_STATE_FILE")
DEV_SERVICES=$(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' "$ZAIA_STATE_FILE" | wc -l)
STAGE_SERVICES=$(jq -r '.services | to_entries[] | select(.value.role == "stage") | .key' "$ZAIA_STATE_FILE" | wc -l)
DATABASE_SERVICES=$(jq -r '.services | to_entries[] | select(.value.role == "database") | .key' "$ZAIA_STATE_FILE" | wc -l)
CACHE_SERVICES=$(jq -r '.services | to_entries[] | select(.value.role == "cache") | .key' "$ZAIA_STATE_FILE" | wc -l)

echo "  Total Services: $TOTAL_SERVICES"
echo "  Development: $DEV_SERVICES"
echo "  Stage/Production: $STAGE_SERVICES"
echo "  Databases: $DATABASE_SERVICES"
echo "  Cache: $CACHE_SERVICES"

# Check for services with environment variables
SERVICES_WITH_SELF_DEFINED=$(jq -r '.services | to_entries[] | select(.value.selfDefinedEnvs | length > 0) | .key' "$ZAIA_STATE_FILE" | wc -l)
echo "  Services with self-defined env vars: $SERVICES_WITH_SELF_DEFINED"

MISSING_IDS=$(jq -r '.services | to_entries[] | select(.value.id == "ID_NOT_FOUND" or .value.id == "" or .value.id == null) | .key' "$ZAIA_STATE_FILE" | wc -l)
if [ "$MISSING_IDS" -gt 0 ]; then
    echo "  ⚠️  Services with missing IDs: $MISSING_IDS"
    echo "     Run /var/www/sync_env_to_zaia.sh to refresh API data and update service IDs"
fi

echo ""
echo "💡 Next steps (.zaia ONLY):"
echo "  - Sync environment variables: /var/www/sync_env_to_zaia.sh"
echo "  - View project context: /var/www/show_project_context.sh"
echo "  - Check service env vars: get_available_envs <service>"
echo "  - Get env suggestions: suggest_env_vars <service>"

# Cleanup
rm -f /tmp/.zaia.work* /tmp/service_status.txt
