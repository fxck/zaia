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

echo "=== DISCOVERING SERVICES (v4 - Advanced zerops.yml Logic) ==="

PROJECT_EXPORT_FILE="/tmp/project_export.yaml" # Should be created by init_state.sh

if [ ! -f "$PROJECT_EXPORT_FILE" ]; then
    echo "FATAL: $PROJECT_EXPORT_FILE not found. Run init_state.sh first."
    exit 1
fi

YAML_CONTENT=$(jq -r '.yaml' "$PROJECT_EXPORT_FILE")
if [ -z "$YAML_CONTENT" ]; then
    echo "FATAL: YAML_CONTENT is empty. Check $PROJECT_EXPORT_FILE and jq extraction."
    exit 1
fi

echo "Fetching current service statuses from zcli..."
zcli service list --projectId "$projectId" > /tmp/service_status.txt

ZAIA_STATE_FILE="/var/www/.zaia"
if [ ! -f "$ZAIA_STATE_FILE" ]; then
    echo "FATAL: State file $ZAIA_STATE_FILE missing. Run init_state.sh first."
    exit 1
fi
cp "$ZAIA_STATE_FILE" /tmp/.zaia.tmp

# Associative array to store full zerops.yml content from dev services
declare -A DEV_SERVICE_FULL_ZEROPS_YMLS

SERVICE_HOSTNAMES_ALL=$(echo "$YAML_CONTENT" | yq e '.services[].hostname' -)
echo "Found service hostnames from YAML: $SERVICE_HOSTNAMES_ALL"

# --- Pass 1: Initial data gathering and processing individual zerops.yml files ---
echo "--- Pass 1: Initial service data & own/dev zerops.yml block processing ---"
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
    SERVICE_ID=$(printenv "${service_hostname}_serviceId" || echo "ID_NOT_IN_ENV")
    if [ "$SERVICE_ID" == "ID_NOT_IN_ENV" ] || [ -z "$SERVICE_ID" ]; then
         echo "WARNING: Service ID for $service_hostname NOT FOUND in env. Using placeholder."
         SERVICE_ID="ID_NOT_IN_ENV"
    else
        echo "Using service ID for $service_hostname from env var: $SERVICE_ID"
    fi

    ROLE="stage" # Default role
    if [[ $service_hostname == *"dev" ]]; then ROLE="development"; fi
    if [[ "$SERVICE_TYPE" =~ ^(postgresql|mariadb|mongodb|mysql) ]]; then ROLE="database"; fi
    if [[ "$SERVICE_TYPE" =~ ^(redis|keydb|valkey) ]]; then ROLE="cache"; fi
    echo "Determined ROLE for $service_hostname: $ROLE"

    SPECIFIC_SETUP_BLOCK_JSON="null" # Default to JSON null string
    # For runtime services, try to get their own specific setup block from their own zerops.yml
    if [[ "$SERVICE_TYPE" =~ ^(nodejs|php|python|go|rust|dotnet|java|bun|deno|gleam|elixir|ruby|static) ]]; then
        echo "Attempting SSH into $service_hostname for its zerops.yml..."
        RAW_SERVICE_YML_CONTENT=""
        if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "$service_hostname" "echo 'SSH_OK'" 2>/dev/null; then
            RAW_SERVICE_YML_CONTENT=$(ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no "$service_hostname" "cat /var/www/zerops.yml 2>/dev/null || cat /var/www/zerops.yaml 2>/dev/null || echo ''")
            if [ -n "$RAW_SERVICE_YML_CONTENT" ]; then
                echo "Found zerops.yml/yaml on $service_hostname."
                # Extract the specific setup block for this service_hostname
                # Output is compact JSON. If block not found, yq returns 'null'.
                SETUP_BLOCK_TEMP=$(echo "$RAW_SERVICE_YML_CONTENT" | yq e ".zerops[] | select(.setup == \"$service_hostname\") | ." -o=json -I0)
                if [ "$SETUP_BLOCK_TEMP" != "null" ] && [ -n "$SETUP_BLOCK_TEMP" ]; then
                    SPECIFIC_SETUP_BLOCK_JSON="$SETUP_BLOCK_TEMP" # Already a JSON string or 'null'
                    echo "Extracted specific setup block for $service_hostname from its own zerops.yml."
                else
                    echo "No specific setup block for '$service_hostname' found in its own zerops.yml/yaml (or file was empty/malformed)."
                fi
                # If it's a dev service, store its full zerops.yml for Pass 2
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

    ENV_VARS=$(env | grep "^${service_hostname}_" | cut -d= -f1 | jq -R . | jq -s . || echo "[]")
    jq --arg hn "$service_hostname" --argjson evs "$ENV_VARS" '.envs[$hn] = $evs' /tmp/.zaia.tmp > /tmp/.zaia.tmp2 && mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
done
echo "--- Pass 1 completed ---"

echo "Mapping deployment pairs..."
ALL_HNS_FOR_PAIRS=$(echo "$YAML_CONTENT" | yq e '.services[].hostname' - || echo "")
# Exclude 'zaia' if it ends with 'dev' from being considered a dev service for pairing
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

# --- Pass 2: Update stage services with actualZeropsYml from their dev pair's FULL zerops.yml ---
echo "--- Pass 2: Updating stage services' zerops.yml block from dev pairs ---"
DEPLOYMENT_PAIRS_JSON=$(jq '.deploymentPairs' /tmp/.zaia.tmp)
if [ "$(echo "$DEPLOYMENT_PAIRS_JSON" | jq 'length')" -gt 0 ]; then
    echo "$DEPLOYMENT_PAIRS_JSON" | jq -c 'to_entries[]' | while IFS= read -r entry; do
        DEV_SERVICE_HOSTNAME=$(echo "$entry" | jq -r '.key')
        STAGE_SERVICE_HOSTNAME=$(echo "$entry" | jq -r '.value')
        echo "Processing pair: Dev '$DEV_SERVICE_HOSTNAME' -> Stage '$STAGE_SERVICE_HOSTNAME'"

        FULL_DEV_YML_CONTENT="${DEV_SERVICE_FULL_ZEROPS_YMLS[$DEV_SERVICE_HOSTNAME]}"
        if [ -n "$FULL_DEV_YML_CONTENT" ]; then
            echo "Found stored full zerops.yml from dev service '$DEV_SERVICE_HOSTNAME'."
            # Extract the specific setup block for the STAGE_SERVICE_HOSTNAME from the DEV_SERVICE's full YML
            STAGE_SETUP_BLOCK_FROM_DEV_YML=$(echo "$FULL_DEV_YML_CONTENT" | yq e ".zerops[] | select(.setup == \"$STAGE_SERVICE_HOSTNAME\") | ." -o=json -I0)
            if [ "$STAGE_SETUP_BLOCK_FROM_DEV_YML" != "null" ] && [ -n "$STAGE_SETUP_BLOCK_FROM_DEV_YML" ]; then
                echo "Extracted setup block for '$STAGE_SERVICE_HOSTNAME' from '$DEV_SERVICE_HOSTNAME's yml. Updating stage service."
                jq --arg sh "$STAGE_SERVICE_HOSTNAME" --argjson yml_block "$STAGE_SETUP_BLOCK_FROM_DEV_YML" \
                   '.services[$sh].actualZeropsYml = $yml_block' /tmp/.zaia.tmp > /tmp/.zaia.tmp2 && mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
            else
                echo "No specific setup block for '$STAGE_SERVICE_HOSTNAME' found in '$DEV_SERVICE_HOSTNAME's zerops.yml. Stage service's current actualZeropsYml (if any) will be kept."
            fi
        else
            echo "Full zerops.yml for dev service '$DEV_SERVICE_HOSTNAME' was not found/stored in Pass 1. Cannot update stage service '$STAGE_SERVICE_HOSTNAME' from it."
        fi
    done
else
    echo "No deployment pairs found to process for Pass 2."
fi
echo "--- Pass 2 completed ---"

echo "Finalizing .zaia state file..."
jq --arg ts "$(date -Iseconds)" '.project.lastSync = $ts' /tmp/.zaia.tmp > "$ZAIA_STATE_FILE"
echo "Successfully wrote final state to $ZAIA_STATE_FILE"

echo "✅ Discovery completed (v4)"
rm -f /tmp/.zaia.tmp*
cp "$ZAIA_STATE_FILE" "${ZAIA_STATE_FILE}.backup"
echo "Backup of $ZAIA_STATE_FILE created."
