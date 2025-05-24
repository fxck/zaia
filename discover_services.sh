#!/bin/bash
set -e

source /var/www/validate_inputs.sh

echo "=== DISCOVERING SERVICES ==="

# Ensure export exists
if [ ! -f /tmp/project_export.yaml ]; then
    echo "Fetching project export..."
    curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" \
         "https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/export" \
         -o /tmp/project_export.yaml
fi

# Validate services data
if ! yq e '.services' /tmp/project_export.yaml >/dev/null 2>&1; then
    echo "❌ Invalid services data"
    exit 1
fi

# Get runtime status
zcli service list --projectId "$projectId" > /tmp/service_status.txt

# Check state file
if [ ! -f /var/www/.zaia ]; then
    echo "❌ State file missing. Run init_state.sh first"
    exit 1
fi

cp /var/www/.zaia /tmp/.zaia.tmp

# Process each service
for service in $(yq e '.services[].hostname' /tmp/project_export.yaml); do
    # Validate name
    if ! validate_service_name "$service"; then
        echo "⚠️  Skipping invalid service: $service"
        continue
    fi
    
    echo "Processing $service..."
    
    SERVICE_TYPE=$(yq e ".services[] | select(.hostname == \"$service\") | .type" /tmp/project_export.yaml)
    SERVICE_MODE=$(yq e ".services[] | select(.hostname == \"$service\") | .mode" /tmp/project_export.yaml)
    
    # Get service ID (prefer env var)
    SERVICE_ID=""
    if env | grep -q "^${service}_serviceId="; then
        SERVICE_ID=$(env | grep "^${service}_serviceId=" | cut -d= -f2)
    else
        SERVICE_ID=$(yq e ".services[] | select(.hostname == \"$service\") | .id" /tmp/project_export.yaml)
    fi
    
    # Determine role
    if [[ $service == *"dev" ]]; then
        ROLE="development"
    elif [[ "$SERVICE_TYPE" =~ ^(postgresql|mariadb|mongodb|mysql) ]]; then
        ROLE="database"
    elif [[ "$SERVICE_TYPE" =~ ^(redis|keydb|valkey) ]]; then
        ROLE="cache"
    else
        ROLE="stage"
    fi
    
    # Get zerops.yml for runtime services
    ZEROPS_CONFIG="null"
    if [[ "$SERVICE_TYPE" =~ ^(nodejs|php|python|go|rust|dotnet|java) ]]; then
        if ssh $service "echo 'OK'" 2>/dev/null; then
            ZEROPS_CONTENT=$(ssh $service "cat /var/www/zerops.yml 2>/dev/null || cat /var/www/zerops.yaml 2>/dev/null || echo 'NO_CONFIG'")
            if [[ "$ZEROPS_CONTENT" != "NO_CONFIG" ]]; then
                ZEROPS_CONFIG=$(echo "$ZEROPS_CONTENT" | jq -Rs .)
            fi
        fi
    fi
    
    # Update state
    jq --arg hostname "$service" \
       --arg id "$SERVICE_ID" \
       --arg type "$SERVICE_TYPE" \
       --arg role "$ROLE" \
       --arg mode "$SERVICE_MODE" \
       --argjson zerops "$ZEROPS_CONFIG" \
       '.services[$hostname] = {
         "id": $id,
         "type": $type, 
         "role": $role,
         "mode": $mode,
         "actualZeropsYml": $zerops
       }' /tmp/.zaia.tmp > /tmp/.zaia.tmp2
    
    mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
    
    # Collect env vars
    ENV_VARS=$(env | grep "^${service}_" | cut -d= -f1 | jq -R . | jq -s .)
    jq --arg service "$service" --argjson vars "$ENV_VARS" \
       '.envs[$service] = $vars' /tmp/.zaia.tmp > /tmp/.zaia.tmp2
    mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
done

# Map deployment pairs
echo "Mapping deployment pairs..."
for service in $(yq e '.services[].hostname' /tmp/project_export.yaml | grep "dev$"); do
    BASE_NAME=${service%dev}
    if yq e ".services[].hostname" /tmp/project_export.yaml | grep -q "^${BASE_NAME}$"; then
        jq --arg dev "$service" --arg stage "$BASE_NAME" \
           '.deploymentPairs[$dev] = $stage' /tmp/.zaia.tmp > /tmp/.zaia.tmp2
        mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
    fi
done

# Update timestamp and save
jq --arg timestamp "$(date -Iseconds)" \
   '.project.lastSync = $timestamp' /tmp/.zaia.tmp > /var/www/.zaia

echo "✅ Discovery completed"
rm -f /tmp/.zaia.tmp*
cp /var/www/.zaia /var/www/.zaia.backup
