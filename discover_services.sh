#!/bin/bash
set -e

if ! command -v validate_service_name > /dev/null 2>&1; then
    if [ -f "/var/www/validate_inputs.sh" ]; then
        source "/var/www/validate_inputs.sh"
    else
        echo "❌ Critical: /var/www/validate_inputs.sh not found. Cannot proceed."
        exit 1
    fi
fi

echo "=== DISCOVERING SERVICES (v8.2 - API-Enhanced Discovery) ==="

PROJECT_EXPORT_FILE="/tmp/project_export.yaml"

if [ ! -f "$PROJECT_EXPORT_FILE" ]; then
    echo "FATAL: $PROJECT_EXPORT_FILE not found. Run init_state.sh first."
    exit 1
fi

YAML_CONTENT=$(jq -r '.yaml' "$PROJECT_EXPORT_FILE" 2>/dev/null)
if [ -z "$YAML_CONTENT" ] || [ "$YAML_CONTENT" == "null" ]; then
    echo "FATAL: YAML_CONTENT is empty. Check $PROJECT_EXPORT_FILE and jq extraction."
    exit 1
fi

echo "Fetching current service statuses from zcli..."
zcli service list --projectId "$projectId" > /tmp/service_status.txt

echo "Refreshing environment variables from API..."
if ! /var/www/get_service_envs.sh; then
    echo "WARNING: Failed to refresh environment variables from API. Continuing with existing data."
fi

ZAIA_STATE_FILE="/var/www/.zaia"
if [ ! -f "$ZAIA_STATE_FILE" ]; then
    echo "FATAL: State file $ZAIA_STATE_FILE missing. Run init_state.sh first."
    exit 1
fi
cp "$ZAIA_STATE_FILE" /tmp/.zaia.tmp

declare -A DEV_SERVICE_FULL_ZEROPS_YMLS

SERVICE_HOSTNAMES_ALL=$(echo "$YAML_CONTENT" | yq e '.services[].hostname' -)
echo "Found service hostnames from YAML: $SERVICE_HOSTNAMES_ALL"

echo "--- Pass 1: Initial service data & zerops.yml block processing ---"
for service_hostname in $SERVICE_HOSTNAMES_ALL; do
    if [ "$service_hostname" == "zaia" ]; then
        echo "Skipping 'zaia' service (agent container itself)."
        continue
    fi
    if ! validate_service_name "$service_hostname"; then
        echo "⚠️  Skipping invalid service hostname: $service_hostname"
        continue
    fi

    echo "Processing (Pass 1) $service_hostname..."
    SERVICE_TYPE=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service_hostname\") | .type // \"unknown-type\"" -)
    SERVICE_MODE=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service_hostname\") | .mode // \"unknown-mode\"" -)

    SERVICE_ID=""

    SERVICE_ID=$(env | grep "^${service_hostname}_serviceId=" | cut -d= -f2 2>/dev/null || echo "")

    if [ -z "$SERVICE_ID" ] && [ -f "/tmp/current_envs.env" ]; then
        SERVICE_ID=$(grep "^${service_hostname}_serviceId=" /tmp/current_envs.env | cut -d= -f2 2>/dev/null || echo "")
    fi

    if [ -z "$SERVICE_ID" ]; then
        SERVICE_ID=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service_hostname\") | .id // \"ID_NOT_FOUND\"" -)
    fi

    if [ -z "$SERVICE_ID" ] || [ "$SERVICE_ID" == "ID_NOT_FOUND" ]; then
        echo "WARNING: Service ID for $service_hostname NOT FOUND. Using placeholder."
        SERVICE_ID="ID_NOT_FOUND"
    else
        echo "Service ID for $service_hostname: $SERVICE_ID"
    fi

    ROLE="stage"
    if [[ $service_hostname == *"dev" ]]; then ROLE="development"; fi
    if [[ "$SERVICE_TYPE" =~ ^(postgresql|mariadb|mongodb|mysql) ]]; then ROLE="database"; fi
    if [[ "$SERVICE_TYPE" =~ ^(redis|keydb|valkey) ]]; then ROLE="cache"; fi
    echo "Determined ROLE for $service_hostname: $ROLE"

    SPECIFIC_SETUP_BLOCK_JSON="null"

    if [[ "$SERVICE_TYPE" =~ ^(nodejs|php|python|go|rust|dotnet|java|bun|deno|gleam|elixir|ruby|static) ]]; then
        echo "Attempting SSH into $service_hostname for its zerops.yml..."
        RAW_SERVICE_YML_CONTENT=""

        if timeout 15 ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "$service_hostname" "echo 'SSH_OK'" 2>/dev/null; then
            RAW_SERVICE_YML_CONTENT=$(timeout 15 ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "$service_hostname" "cat /var/www/zerops.yml 2>/dev/null || cat /var/www/zerops.yaml 2>/dev/null || echo ''" 2>/dev/null)

            if [ -n "$RAW_SERVICE_YML_CONTENT" ]; then
                echo "Found zerops.yml/yaml on $service_hostname."
                SETUP_BLOCK_TEMP=$(echo "$RAW_SERVICE_YML_CONTENT" | yq e ".zerops[] | select(.setup == \"$service_hostname\") | ." -o=json -I0 2>/dev/null || echo "null")
                if [ "$SETUP_BLOCK_TEMP" != "null" ] && [ -n "$SETUP_BLOCK_TEMP" ]; then
                    SPECIFIC_SETUP_BLOCK_JSON="$SETUP_BLOCK_TEMP"
                    echo "Extracted specific setup block for $service_hostname from its own zerops.yml."
                else
                    echo "No specific setup block for '$service_hostname' found in its own zerops.yml."
                fi

                if [ "$ROLE" == "development" ]; then
                    DEV_SERVICE_FULL_ZEROPS_YMLS["$service_hostname"]="$RAW_SERVICE_YML_CONTENT"
                    echo "Stored full zerops.yml from dev service $service_hostname for Pass 2."
                fi
            else
                echo "No zerops.yml/yaml found or content is empty on $service_hostname."
            fi
        else
            echo "SSH failed or timed out for $service_hostname."
        fi
    fi

    jq --arg hn "$service_hostname" --arg id "$SERVICE_ID" --arg typ "$SERVICE_TYPE" --arg rl "$ROLE" --arg md "$SERVICE_MODE" --argjson zyml "$SPECIFIC_SETUP_BLOCK_JSON" \
       '.services[$hn] = {"id":$id, "type":$typ, "role":$rl, "mode":$md, "actualZeropsYml":$zyml}' /tmp/.zaia.tmp > /tmp/.zaia.tmp2 && mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp

    ENV_VARS="[]"
    if [ -f "/tmp/current_envs.env" ]; then
        ENV_VARS=$(grep "^${service_hostname}_" /tmp/current_envs.env | cut -d= -f1 | jq -R . | jq -s . 2>/dev/null || echo "[]")
    else
        ENV_VARS=$(env | grep "^${service_hostname}_" | cut -d= -f1 | jq -R . | jq -s . 2>/dev/null || echo "[]")
    fi

    jq --arg hn "$service_hostname" --argjson evs "$ENV_VARS" '.envs[$hn] = $evs' /tmp/.zaia.tmp > /tmp/.zaia.tmp2 && mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
done
echo "--- Pass 1 completed ---"

echo "Mapping deployment pairs..."
ALL_HNS_FOR_PAIRS=$(echo "$YAML_CONTENT" | yq e '.services[].hostname' - 2>/dev/null || echo "")
DEV_HNS_FOR_PAIRS=$(echo "$ALL_HNS_FOR_PAIRS" | grep "dev$" | grep -v "^zaia$" || echo "")

if [ -n "$DEV_HNS_FOR_PAIRS" ]; then
    for dev_hn in $DEV_HNS_FOR_PAIRS; do
        base_name=${dev_hn%dev}
        if echo "$ALL_HNS_FOR_PAIRS" | grep -Fxq "$base_name"; then
            echo "Found deployment pair: $dev_hn -> $base_name"
            jq --arg dh "$dev_hn" --arg sh "$base_name" '.deploymentPairs[$dh] = $sh' /tmp/.zaia.tmp > /tmp/.zaia.tmp2 && mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
        fi
    done
else
    echo "No 'dev' services (excluding 'zaia') found to map for deployment pairs."
fi

echo "--- Pass 2: Updating stage services' zerops.yml block from dev pairs ---"
DEPLOYMENT_PAIRS_JSON=$(jq '.deploymentPairs' /tmp/.zaia.tmp 2>/dev/null || echo "{}")

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
                TEMP_STATE=$(jq --arg sh "$STAGE_SERVICE_HOSTNAME" --argjson yml_block "$STAGE_SETUP_BLOCK_FROM_DEV_YML" \
                   '.services[$sh].actualZeropsYml = $yml_block' /tmp/.zaia.tmp)
                echo "$TEMP_STATE" > /tmp/.zaia.tmp
            else
                echo "No specific setup block for '$STAGE_SERVICE_HOSTNAME' found in '$DEV_SERVICE_HOSTNAME's zerops.yml."
            fi
        else
            echo "Full zerops.yml for dev service '$DEV_SERVICE_HOSTNAME' was not found/stored in Pass 1."
        fi
    done
else
    echo "No deployment pairs found to process for Pass 2."
fi
echo "--- Pass 2 completed ---"

echo "Finalizing .zaia state file..."
jq --arg ts "$(date -Iseconds)" '.project.lastSync = $ts' /tmp/.zaia.tmp > "$ZAIA_STATE_FILE"
echo "Successfully wrote final state to $ZAIA_STATE_FILE"

echo "✅ Discovery completed (v8.2)"
rm -f /tmp/.zaia.tmp*
cp "$ZAIA_STATE_FILE" "${ZAIA_STATE_FILE}.backup"
echo "Backup of $ZAIA_STATE_FILE created."

echo ""
echo "📊 DISCOVERY SUMMARY:"
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

MISSING_IDS=$(jq -r '.services | to_entries[] | select(.value.id == "ID_NOT_FOUND") | .key' "$ZAIA_STATE_FILE" | wc -l)
if [ "$MISSING_IDS" -gt 0 ]; then
    echo "  ⚠️  Services with missing IDs: $MISSING_IDS"
    echo "     Run /var/www/get_service_envs.sh to refresh API data"
fi
