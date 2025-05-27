#!/bin/bash
set -e
source /var/www/core_utils.sh 2>/dev/null || true

if [ ! -f /var/www/.zaia ]; then
    echo "❌ FATAL: No .zaia file found"
    echo "   Run: /var/www/init_project.sh"
    exit 1
fi

if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ FATAL: .zaia file is corrupted"
    echo "   Run: /var/www/init_project.sh"
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    PROJECT CONTEXT                        ║"
echo "╚══════════════════════════════════════════════════════════╝"

# Project info
PROJECT_INFO=$(jq -r '
"📋 Project: \(.project.name)
🆔 ID: \(.project.id)
🕒 Last Sync: \(.project.lastSync)"
' /var/www/.zaia)

echo "$PROJECT_INFO"
echo ""

# Services summary
echo "🔧 SERVICES"
echo "==========="
jq -r '.services | to_entries | sort_by(.value.role) | .[] |
"\(.key)
  Type: \(.value.type)
  Role: \(.value.role)
  Mode: \(.value.mode)
  ID: \(.value.id)
  \(if .value.subdomain then "URL: https://\(.value.subdomain)" else "" end)"
' /var/www/.zaia

# Deployment pairs
PAIRS=$(jq -r '.deploymentPairs | length' /var/www/.zaia)
if [ "$PAIRS" -gt 0 ]; then
    echo ""
    echo "🚀 DEPLOYMENT PAIRS"
    echo "=================="
    jq -r '.deploymentPairs | to_entries[] | "  \(.key) → \(.value)"' /var/www/.zaia
fi

# Environment variables summary
echo ""
echo "🌍 ENVIRONMENT VARIABLES"
echo "======================="
jq -r '
"Services with provided vars: \([.services[] | select(.serviceProvidedEnvs | length > 0)] | length)
Services with self-defined: \([.services[] | select(.selfDefinedEnvs | length > 0)] | length)"
' /var/www/.zaia

# Show which services have env vars
if [ "$(jq '[.services[] | select(.serviceProvidedEnvs | length > 0)] | length' /var/www/.zaia)" -gt 0 ]; then
    echo ""
    echo "Services with environment variables:"
    jq -r '.services | to_entries[] |
    select(.value.serviceProvidedEnvs | length > 0) |
    "  \(.key): \(.value.serviceProvidedEnvs | length) variables"' /var/www/.zaia
fi

# Public URLs
URLS=$(jq -r '[.services[] | select(.subdomain)] | length' /var/www/.zaia)
if [ "$URLS" -gt 0 ]; then
    echo ""
    echo "🌐 PUBLIC URLS"
    echo "=============="
    jq -r '.services | to_entries[] |
    select(.value.subdomain) |
    "  \(.key): https://\(.value.subdomain)"' /var/www/.zaia
fi

# SSH access availability
if command -v can_ssh >/dev/null 2>&1; then
    echo ""
    echo "🔌 SSH ACCESS"
    echo "============="
    for service in $(jq -r '.services | keys[]' /var/www/.zaia | head -20); do
        if can_ssh "$service" 2>/dev/null; then
            echo "  ✅ $service"
        else
            echo "  ❌ $service (managed service)"
        fi
    done
fi

# Deployment readiness
echo ""
echo "🎯 DEPLOYMENT READINESS"
echo "======================"
READY=0
NOT_READY=0

for dev in $(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia); do
    stage=$(jq -r ".deploymentPairs[\"$dev\"] // \"\"" /var/www/.zaia)

    if [ -n "$stage" ] && [ "$stage" != "null" ]; then
        stage_id=$(jq -r ".services[\"$stage\"].id // \"\"" /var/www/.zaia)
        if [ -n "$stage_id" ] && [ "$stage_id" != "pending" ]; then
            echo "  ✅ $dev → $stage (ready)"
            READY=$((READY + 1))
        else
            echo "  ⚠️ $dev → $stage (stage ID pending)"
            NOT_READY=$((NOT_READY + 1))
        fi
    else
        echo "  ❌ $dev (no stage service)"
        NOT_READY=$((NOT_READY + 1))
    fi
done

if [ $READY -eq 0 ] && [ $NOT_READY -eq 0 ]; then
    echo "  No development services found"
fi

# Data freshness check
LAST_SYNC=$(jq -r '.project.lastSync' /var/www/.zaia)
if [ "$LAST_SYNC" != "null" ] && command -v date >/dev/null 2>&1; then
    SYNC_TIMESTAMP=$(date -d "$LAST_SYNC" +%s 2>/dev/null || echo 0)
    CURRENT_TIMESTAMP=$(date +%s)
    AGE_SECONDS=$((CURRENT_TIMESTAMP - SYNC_TIMESTAMP))
    AGE_MINUTES=$((AGE_SECONDS / 60))

    echo ""
    echo "📊 DATA FRESHNESS"
    echo "================"
    if [ $AGE_MINUTES -gt 60 ]; then
        echo "  ⚠️ Data is $((AGE_MINUTES / 60)) hours old"
        echo "  💡 Run: sync_env_to_zaia"
    else
        echo "  ✅ Data is $AGE_MINUTES minutes old"
    fi
fi

# Quick actions
echo ""
echo "💡 QUICK ACTIONS"
echo "================"
echo "  Recipe:      /var/www/get_recipe.sh <framework>"
echo "  Create:      /var/www/create_services.sh <name> <type>"
echo "  Deploy:      /var/www/deploy.sh <dev-service>"
echo "  Env vars:    get_available_envs <service>"
echo "  Suggest:     suggest_env_vars <service>"
echo "  Diagnose:    diagnose_issue <service> --smart"
echo "  502 debug:   diagnose_502_enhanced <service>"
echo "  Security:    security_scan <service>"

echo ""
echo "══════════════════════════════════════════════════════════"

exit 0
