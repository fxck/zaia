#!/bin/bash
set -e
source /var/www/core_utils.sh

[ ! -f /var/www/.zaia ] && echo "FATAL: No .zaia. Run init_project.sh" && exit 1

echo "==================== PROJECT CONTEXT ===================="
jq -r '
"📋 Project: \(.project.name) (\(.project.id))
🕒 Last Sync: \(.project.lastSync)

🔧 SERVICES:
\(.services | to_entries[] | "  \(.key) (\(.value.type)) - \(.value.role) - ID: \(.value.id)")

🚀 DEPLOYMENT PAIRS:
\(.deploymentPairs | to_entries[] | "  \(.key) → \(.value)")

🌍 ENV VARS:
  With provided: \([.services[] | select(.serviceProvidedEnvs | length > 0)] | length)
  With self-defined: \([.services[] | select(.selfDefinedEnvs | length > 0)] | length)

🌐 PUBLIC URLS:
\(.services | to_entries[] | select(.value.subdomain) | "  \(.key): https://\(.value.subdomain)")

📦 RUNTIME INFO:
\(.services | to_entries[] | select(.value.discoveredRuntime.startCommand) | "  \(.key): \(.value.discoveredRuntime.startCommand) (port \(.value.discoveredRuntime.port // \"unknown\"))")"
' /var/www/.zaia

# SSH availability
echo ""
echo "🔌 SSH ACCESS:"
for service in $(jq -r '.services | keys[]' /var/www/.zaia); do
    if can_ssh "$service"; then
        echo "  ✅ $service"
    else
        echo "  ❌ $service (managed service)"
    fi
done

# Check data freshness
LAST_SYNC=$(get_from_zaia '.project.lastSync')
AGE=$(($(date +%s) - $(date -d "$LAST_SYNC" +%s 2>/dev/null || echo 0)))
[ $AGE -gt 3600 ] && echo "⚠️ Data >1hr old. Run: init_project.sh"

echo ""
echo "💡 QUICK ACTIONS:"
echo "  Get recipe: get_recipe.sh <framework>"
echo "  Check envs: get_available_envs <service>"
echo "  Deploy: deploy.sh <dev-service>"
echo "  Diagnose: diagnose_502_enhanced <service>"

echo "========================================================"
