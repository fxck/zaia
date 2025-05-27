#!/bin/bash
# Zerops AI Agent Preflight Check
# Ensures all required components are available before operations

set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           ZEROPS AI AGENT PREFLIGHT CHECK                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

ERRORS=0
WARNINGS=0

# Function to check file exists
check_file() {
    local file="$1"
    local description="$2"
    local critical="${3:-true}"

    if [ -f "$file" ]; then
        echo "✅ $description: $file"
        return 0
    else
        if [ "$critical" = "true" ]; then
            echo "❌ MISSING: $description - $file"
            ERRORS=$((ERRORS + 1))
        else
            echo "⚠️  MISSING: $description - $file (optional)"
            WARNINGS=$((WARNINGS + 1))
        fi
        return 1
    fi
}

# Function to check command exists
check_command() {
    local cmd="$1"
    local description="$2"

    if command -v "$cmd" >/dev/null 2>&1; then
        echo "✅ Command available: $cmd ($description)"
        return 0
    else
        echo "❌ MISSING COMMAND: $cmd ($description)"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
}

# Function to check environment variable
check_env() {
    local var="$1"
    local description="$2"

    if [ -n "${!var}" ]; then
        echo "✅ Environment: $var is set ($description)"
        return 0
    else
        echo "❌ MISSING ENV: $var ($description)"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
}

echo "1️⃣ CHECKING CORE SCRIPTS"
echo "========================"
check_file "/var/www/core_utils.sh" "Core utilities"
check_file "/var/www/init_project.sh" "Project initializer"
check_file "/var/www/create_services.sh" "Service creator"
check_file "/var/www/deploy.sh" "Deployment script"
check_file "/var/www/show_project_context.sh" "Context viewer"
check_file "/var/www/get_recipe.sh" "Recipe manager"
check_file "/var/www/diagnose_frontend.sh" "Frontend diagnostics"
check_file "/var/www/puppeteer_check.js" "Puppeteer checker"

echo ""
echo "2️⃣ CHECKING DATA FILES"
echo "====================="
check_file "/var/www/technologies.json" "Technology definitions"
check_file "/var/www/recipes.json" "Framework recipes" false
check_file "/var/www/.zaia" "Project state" false

echo ""
echo "3️⃣ CHECKING COMMANDS"
echo "==================="
check_command "zcli" "Zerops CLI"
check_command "jq" "JSON processor"
check_command "yq" "YAML processor"
check_command "curl" "HTTP client"
check_command "ssh" "SSH client"
check_command "git" "Version control"
check_command "node" "Node.js runtime"

echo ""
echo "4️⃣ CHECKING ENVIRONMENT"
echo "======================="
check_env "ZEROPS_ACCESS_TOKEN" "API authentication"
check_env "projectId" "Project identifier"

echo ""
echo "5️⃣ CHECKING AUTHENTICATION"
echo "=========================="
if zcli project list >/dev/null 2>&1; then
    echo "✅ Zerops CLI authenticated"
else
    echo "⚠️  Zerops CLI not authenticated (will authenticate on first use)"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""
echo "6️⃣ CHECKING PROJECT STATE"
echo "========================"
if [ -f "/var/www/.zaia" ]; then
    if jq empty /var/www/.zaia 2>/dev/null; then
        echo "✅ Project state file is valid JSON"

        # Check state contents
        PROJECT_NAME=$(jq -r '.project.name // ""' /var/www/.zaia 2>/dev/null)
        SERVICE_COUNT=$(jq '.services | length' /var/www/.zaia 2>/dev/null || echo 0)

        if [ -n "$PROJECT_NAME" ]; then
            echo "   Project: $PROJECT_NAME"
            echo "   Services: $SERVICE_COUNT"
        fi
    else
        echo "❌ Project state file is corrupted"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "⚠️  No project state - run init_project.sh"
    WARNINGS=$((WARNINGS + 1))
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                        SUMMARY                              "
echo "═══════════════════════════════════════════════════════════"

if [ $ERRORS -eq 0 ]; then
    if [ $WARNINGS -eq 0 ]; then
        echo "✅ ALL CHECKS PASSED - System ready!"
    else
        echo "✅ System operational with $WARNINGS warnings"
    fi
    echo ""
    echo "💡 Next steps:"
    echo "   1. Source utilities: source /var/www/core_utils.sh"
    echo "   2. Initialize project: /var/www/init_project.sh"
    echo "   3. View context: /var/www/show_project_context.sh"
    exit 0
else
    echo "❌ CRITICAL ERRORS: $ERRORS errors found"
    echo "⚠️  WARNINGS: $WARNINGS warnings found"
    echo ""
    echo "🔧 Fix critical errors before proceeding!"
    exit 1
fi
