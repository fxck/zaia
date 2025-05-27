#!/bin/bash
set -e
source /var/www/core_utils.sh

echo "=== INITIALIZING PROJECT STATE ==="

# Prerequisites
[ -z "$ZEROPS_ACCESS_TOKEN" ] && echo "FATAL: No token" && exit 1
[ -z "$projectId" ] && echo "FATAL: No projectId" && exit 1

# Backup existing state
[ -f /var/www/.zaia ] && cp /var/www/.zaia "/var/www/.zaia.backup.$(date +%s)"

# Fetch project config
echo "Fetching project configuration..."
curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" \
     "https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/export" \
     -o /tmp/project_export.yaml || (echo "FATAL: API failed" && exit 1)

# Extract project info
YAML_CONTENT=$(jq -r '.yaml' /tmp/project_export.yaml)
PROJECT_NAME=$(echo "$YAML_CONTENT" | yq e '.project.name' -)

# Initialize .zaia
cat > /var/www/.zaia << EOF
{
  "project": {"id": "$projectId", "name": "$PROJECT_NAME", "lastSync": "$(date -Iseconds)"},
  "services": {},
  "deploymentPairs": {}
}
EOF

# Discover services
echo "Discovering services..."
for service in $(echo "$YAML_CONTENT" | yq e '.services[].hostname' -); do
    [ "$service" = "zaia" ] && continue

    TYPE=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service\") | .type" -)
    MODE=$(echo "$YAML_CONTENT" | yq e ".services[] | select(.hostname == \"$service\") | .mode // \"NON_HA\"" -)
    ROLE=$(get_service_role "$service" "$TYPE")

    # Add to .zaia
    jq --arg s "$service" --arg t "$TYPE" --arg r "$ROLE" --arg m "$MODE" \
       '.services[$s] = {"type": $t, "role": $r, "mode": $m, "id": "pending",
        "serviceProvidedEnvs": [], "selfDefinedEnvs": {}}' \
       /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia

    # Try to get zerops.yml for runtime services only
    if can_ssh "$service"; then
        echo "  Checking $service for zerops.yml..."
        if YML=$(safe_ssh "$service" "cat /var/www/zerops.yml 2>/dev/null || cat /var/www/zerops.yaml 2>/dev/null" 100 10); then
            # Extract self-defined env vars
            if SELF_ENV=$(echo "$YML" | yq e ".zerops[] | select(.setup == \"$service\") | .run.envVariables // {}" 2>/dev/null); then
                if [ "$SELF_ENV" != "{}" ] && [ "$SELF_ENV" != "null" ]; then
                    jq --arg s "$service" --argjson env "$SELF_ENV" \
                       '.services[$s].selfDefinedEnvs = $env' \
                       /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
                fi
            fi

            # Store discovered runtime info
            START_CMD=$(echo "$YML" | yq e ".zerops[] | select(.setup == \"$service\") | .run.start // \"\"" 2>/dev/null)
            PORT=$(echo "$YML" | yq e ".zerops[] | select(.setup == \"$service\") | .run.ports[0].port // \"\"" 2>/dev/null)

            if [ -n "$START_CMD" ] || [ -n "$PORT" ]; then
                jq --arg s "$service" --arg start "$START_CMD" --arg port "$PORT" \
                   '.services[$s].discoveredRuntime = {"startCommand": $start, "port": $port}' \
                   /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
            fi
        fi
    fi
done

# Map deployment pairs
for dev in $(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia); do
    base=${dev%dev}
    if jq -e ".services[\"$base\"]" /var/www/.zaia >/dev/null; then
        jq --arg d "$dev" --arg s "$base" '.deploymentPairs[$d] = $s' \
           /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
    fi
done

# Sync environment variables
echo "Syncing environment variables..."
safe_output 1000 30 curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" \
    "https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/env-file-download" \
    -o /tmp/envs.txt

# Update service IDs and env vars
for service in $(jq -r '.services | keys[]' /var/www/.zaia); do
    # Service ID
    if ID=$(grep "^${service}_serviceId=" /tmp/envs.txt 2>/dev/null | cut -d= -f2); then
        jq --arg s "$service" --arg id "$ID" '.services[$s].id = $id' \
           /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
    fi

    # Subdomain
    if SUBDOMAIN=$(grep "^${service}_zeropsSubdomain=" /tmp/envs.txt 2>/dev/null | cut -d= -f2); then
        jq --arg s "$service" --arg sub "$SUBDOMAIN" '.services[$s].subdomain = $sub' \
           /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
    fi

    # Service-provided envs (filter out sensitive info from display)
    ENVS=$(grep "^${service}_" /tmp/envs.txt 2>/dev/null | cut -d= -f1 | jq -R . | jq -s . || echo "[]")
    jq --arg s "$service" --argjson e "$ENVS" '.services[$s].serviceProvidedEnvs = $e' \
       /var/www/.zaia > /tmp/.zaia.tmp && mv /tmp/.zaia.tmp /var/www/.zaia
done

# Summary
echo "✅ PROJECT INITIALIZED"
jq -r '"Project: \(.project.name)
Services: \(.services | length)
Dev: \([.services[] | select(.role=="development")] | length)
Stage: \([.services[] | select(.role=="stage")] | length)
DB: \([.services[] | select(.role=="database")] | length)
Cache: \([.services[] | select(.role=="cache")] | length)
Storage: \([.services[] | select(.role=="storage")] | length)"' /var/www/.zaia

# Security reminder
echo ""
echo "🔒 SECURITY REMINDER:"
echo "   • Never hardcode passwords or API keys"
echo "   • Use envSecrets in import YAML"
echo "   • Reference service variables with \${service_var}"

rm -f /tmp/project_export.yaml /tmp/envs.txt
