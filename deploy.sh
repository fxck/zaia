#!/bin/bash
set -e
source /var/www/core_utils.sh

usage() {
    echo "Usage: $0 <dev-service> [options]"
    echo ""
    echo "Options:"
    echo "  --skip-build    Skip build step (deploy as-is)"
    echo "  --force         Deploy even if build fails"
    echo "  --skip-tests    Skip test execution"
    echo ""
    echo "Examples:"
    echo "  $0 myappdev"
    echo "  $0 apidev --skip-build"
    echo "  $0 frontenddev --force"
    exit 1
}

[ $# -lt 1 ] && usage

DEV="$1"
SKIP_BUILD=false
FORCE=false
SKIP_TESTS=false

shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build) SKIP_BUILD=true; shift ;;
        --force) FORCE=true; shift ;;
        --skip-tests) SKIP_TESTS=true; shift ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Verify it's a runtime service
if ! can_ssh "$DEV"; then
    echo "❌ $DEV is not a runtime service or doesn't exist"
    echo "   Check service name and type"
    exit 1
fi

# Auto-detect stage service from .zaia
STAGE=$(get_from_zaia ".deploymentPairs[\"$DEV\"] // \"\"")
if [ -z "$STAGE" ] || [ "$STAGE" = "null" ]; then
    echo "❌ No stage service paired with $DEV"
    echo ""
    echo "Available deployment pairs:"
    jq -r '.deploymentPairs | to_entries[] | "  \(.key) → \(.value)"' /var/www/.zaia 2>/dev/null || echo "  None found"
    exit 1
fi

# Get stage service ID
STAGE_ID=$(get_service_id "$STAGE")

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          INTELLIGENT DEPLOYMENT WORKFLOW                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "📦 Development: $DEV"
echo "🚀 Stage: $STAGE (ID: $STAGE_ID)"
echo "⚙️ Options: $([ "$SKIP_BUILD" = true ] && echo "skip-build ") $([ "$FORCE" = true ] && echo "force ") $([ "$SKIP_TESTS" = true ] && echo "skip-tests")"
echo ""

# Phase 1: Project Analysis
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 1: PROJECT ANALYSIS"
echo "═══════════════════════════════════════════════════════════"

# 1.1 Project Structure
echo ""
echo "📁 PROJECT STRUCTURE"
echo "-------------------"
safe_ssh "$DEV" "cd /var/www && find . -type f -name '*.*' | grep -v -E '(node_modules|vendor|.git|target|dist|build|cache|tmp|__pycache__|.venv|venv|.tox|coverage|.pytest_cache)' | sort | head -150" 150 10

# 1.2 Technology Detection
echo ""
echo "🔍 TECHNOLOGY STACK"
echo "------------------"

# Check for package managers and config files
TECH_INDICATORS=(
    "package.json:Node.js/JavaScript"
    "composer.json:PHP"
    "requirements.txt:Python"
    "Gemfile:Ruby"
    "go.mod:Go"
    "Cargo.toml:Rust"
    "pom.xml:Java Maven"
    "build.gradle:Java Gradle"
    "mix.exs:Elixir"
    "gleam.toml:Gleam"
    ".csproj:.NET"
    "pubspec.yaml:Dart/Flutter"
)

for indicator in "${TECH_INDICATORS[@]}"; do
    FILE="${indicator%%:*}"
    TECH="${indicator#*:}"

    if safe_ssh "$DEV" "test -f /var/www/$FILE && echo '✓ Found: $FILE ($TECH)'" 1 2; then
        echo ""
        echo "📄 Contents of $FILE:"
        safe_ssh "$DEV" "cd /var/www && head -50 $FILE" 50 5
    fi
done

# 1.3 Framework Detection
echo ""
echo "🎯 FRAMEWORK DETECTION"
echo "---------------------"

# Framework-specific files
FRAMEWORK_FILES=(
    "next.config.*:Next.js"
    "nuxt.config.*:Nuxt.js"
    "angular.json:Angular"
    "vue.config.*:Vue.js"
    "gatsby-config.*:Gatsby"
    "astro.config.*:Astro"
    "vite.config.*:Vite"
    "webpack.config.*:Webpack"
    "rollup.config.*:Rollup"
    "tsconfig.json:TypeScript"
    "babel.config.*:Babel"
    ".prettierrc*:Prettier"
    ".eslintrc*:ESLint"
    "jest.config.*:Jest"
    "cypress.json:Cypress"
    "playwright.config.*:Playwright"
)

for pattern in "${FRAMEWORK_FILES[@]}"; do
    FILE_PATTERN="${pattern%%:*}"
    FRAMEWORK="${pattern#*:}"

    if safe_ssh "$DEV" "cd /var/www && ls $FILE_PATTERN 2>/dev/null | head -5" 5 2 | grep -q .; then
        echo "✓ $FRAMEWORK detected"
    fi
done

# 1.4 Dependencies Status
echo ""
echo "📦 DEPENDENCIES STATUS"
echo "---------------------"
safe_ssh "$DEV" "cd /var/www && [ -d node_modules ] && echo '✓ node_modules exists' && du -sh node_modules || echo '✗ No node_modules'" 2 5
safe_ssh "$DEV" "cd /var/www && [ -d vendor ] && echo '✓ vendor exists' && du -sh vendor || echo '✗ No vendor'" 2 5
safe_ssh "$DEV" "cd /var/www && [ -d .venv ] && echo '✓ Python venv exists' || echo '✗ No Python venv'" 2 5
safe_ssh "$DEV" "cd /var/www && [ -f package-lock.json ] && echo '✓ package-lock.json exists' || echo '✗ No package-lock.json'" 1 2
safe_ssh "$DEV" "cd /var/www && [ -f yarn.lock ] && echo '✓ yarn.lock exists' || echo '✗ No yarn.lock'" 1 2
safe_ssh "$DEV" "cd /var/www && [ -f composer.lock ] && echo '✓ composer.lock exists' || echo '✗ No composer.lock'" 1 2

# 1.5 Entry Points
echo ""
echo "🎯 APPLICATION ENTRY POINTS"
echo "--------------------------"
safe_ssh "$DEV" "cd /var/www && find . -maxdepth 3 -type f \( -name 'main.*' -o -name 'index.*' -o -name 'app.*' -o -name 'server.*' -o -name 'start.*' -o -name 'run.*' -o -name 'wsgi.*' -o -name 'asgi.*' -o -name 'manage.py' \) | grep -v -E '(node_modules|vendor|test|spec|.git)' | sort" 30 5

# 1.6 Build Configuration
echo ""
echo "🏗️ BUILD CONFIGURATION"
echo "---------------------"

# Check for build scripts in package.json
if safe_ssh "$DEV" "test -f /var/www/package.json" 1 2; then
    echo "📋 Available npm scripts:"
    safe_ssh "$DEV" "cd /var/www && cat package.json | jq -r '.scripts | to_entries[] | \"  \\(.key): \\(.value)\"' 2>/dev/null | head -20" 20 5 || echo "  Could not parse scripts"
fi

# Check for Makefile
if safe_ssh "$DEV" "test -f /var/www/Makefile" 1 2; then
    echo ""
    echo "📋 Makefile targets:"
    safe_ssh "$DEV" "cd /var/www && grep '^[a-zA-Z].*:' Makefile | head -10" 10 5
fi

# 1.7 Environment Configuration
echo ""
echo "🌍 ENVIRONMENT CONFIGURATION"
echo "---------------------------"

# Show current runtime versions
safe_ssh "$DEV" "cd /var/www && echo 'Node.js:' && node -v 2>/dev/null || echo 'Not found'" 2 2
safe_ssh "$DEV" "cd /var/www && echo 'Python:' && python --version 2>/dev/null || python3 --version 2>/dev/null || echo 'Not found'" 2 2
safe_ssh "$DEV" "cd /var/www && echo 'PHP:' && php -v 2>/dev/null | head -1 || echo 'Not found'" 2 2
safe_ssh "$DEV" "cd /var/www && echo 'Ruby:' && ruby -v 2>/dev/null || echo 'Not found'" 2 2
safe_ssh "$DEV" "cd /var/www && echo 'Go:' && go version 2>/dev/null || echo 'Not found'" 2 2
safe_ssh "$DEV" "cd /var/www && echo 'Java:' && java -version 2>&1 | head -1 || echo 'Not found'" 2 2

# 1.8 Current Process Status
echo ""
echo "🏃 CURRENT PROCESS STATUS"
echo "------------------------"
safe_ssh "$DEV" "ps aux | grep -v 'ps aux' | grep -v grep | grep -v sshd | grep -v bash | tail -20" 20 5

# 1.9 Recent Application Logs
echo ""
echo "📋 RECENT APPLICATION LOGS"
echo "-------------------------"
safe_ssh "$DEV" "cd /var/www && tail -50 app.log 2>/dev/null | tail -30" 30 5 || echo "No app.log found"

# 1.10 Deployment Configuration
echo ""
echo "🚀 DEPLOYMENT CONFIGURATION"
echo "--------------------------"

# Check for zerops.yml
if safe_ssh "$DEV" "test -f /var/www/zerops.yml && echo '✓ zerops.yml found'" 1 2; then
    echo ""
    echo "📄 Current zerops.yml:"
    safe_ssh "$DEV" "cd /var/www && cat zerops.yml" 300 10 | mask_sensitive_output
elif safe_ssh "$DEV" "test -f /var/www/zerops.yaml && echo '✓ zerops.yaml found'" 1 2; then
    echo ""
    echo "📄 Current zerops.yaml:"
    safe_ssh "$DEV" "cd /var/www && cat zerops.yaml" 300 10 | mask_sensitive_output
else
    echo "⚠️ No zerops.yml/yaml found"
    echo "   Deployment will use defaults or fail"
fi

# Phase 2: Security Scan
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 2: SECURITY SCAN"
echo "═══════════════════════════════════════════════════════════"

echo ""
echo "🔒 Scanning for exposed secrets..."
security_scan "$DEV"

# Phase 3: Build Analysis (if not skipped)
if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "PHASE 3: BUILD ANALYSIS"
    echo "═══════════════════════════════════════════════════════════"

    echo ""
    echo "🤖 AI BUILD ANALYSIS REQUIRED"
    echo "----------------------------"
    echo ""
    echo "Based on the project analysis above, the AI should determine:"
    echo ""
    echo "1. TECHNOLOGY STACK"
    echo "   - Primary language and version"
    echo "   - Framework and version"
    echo "   - Build tools required"
    echo ""
    echo "2. BUILD REQUIREMENTS"
    echo "   - Dependencies to install"
    echo "   - Compilation/transpilation needed"
    echo "   - Asset bundling required"
    echo "   - Environment-specific builds"
    echo ""
    echo "3. BUILD SEQUENCE"
    echo "   - Order of operations"
    echo "   - Parallel vs sequential steps"
    echo "   - Cache considerations"
    echo ""
    echo "4. VERIFICATION"
    echo "   - How to verify build success"
    echo "   - Expected output files/directories"
    echo "   - Size/performance checks"
    echo ""
    echo "The AI will use intelligence to determine the exact build"
    echo "commands needed without relying on hardcoded patterns."
else
    echo ""
    echo "⏭️ SKIPPING BUILD PHASE (--skip-build flag set)"
fi

# Phase 4: Test Execution (if not skipped)
if [ "$SKIP_TESTS" = false ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "PHASE 4: TEST EXECUTION"
    echo "═══════════════════════════════════════════════════════════"

    # Check for test configurations
    echo ""
    echo "🧪 TEST CONFIGURATION"
    echo "--------------------"

    # Node.js tests
    if safe_ssh "$DEV" "test -f /var/www/package.json" 1 2; then
        TEST_SCRIPTS=$(safe_ssh "$DEV" "cd /var/www && cat package.json | jq -r '.scripts | to_entries[] | select(.key | test(\"test\")) | \"  \\(.key): \\(.value)\"' 2>/dev/null" 10 5)
        if [ -n "$TEST_SCRIPTS" ]; then
            echo "📦 Available test scripts:"
            echo "$TEST_SCRIPTS"
        fi
    fi

    # Python tests
    if safe_ssh "$DEV" "test -d /var/www/tests -o -d /var/www/test -o -f /var/www/pytest.ini -o -f /var/www/tox.ini" 1 2; then
        echo "🐍 Python test framework detected"
    fi

    # Other test frameworks
    safe_ssh "$DEV" "cd /var/www && ls -la *test* *spec* 2>/dev/null | head -10" 10 5 || true

    echo ""
    echo "💡 AI should determine which tests to run (if any)"
else
    echo ""
    echo "⏭️ SKIPPING TEST PHASE (--skip-tests flag set)"
fi

# Phase 5: Git Operations
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 5: GIT OPERATIONS"
echo "═══════════════════════════════════════════════════════════"

echo ""
echo "📝 GIT STATUS"
echo "-------------"

# Check if git repo exists
GIT_EXISTS=$(safe_ssh "$DEV" "cd /var/www && [ -d .git ] && echo 'true' || echo 'false'" 1 2)

if [ "$GIT_EXISTS" = "true" ]; then
    echo "✓ Git repository exists"

    # Show git status
    echo ""
    echo "Current status:"
    safe_ssh "$DEV" "cd /var/www && git status --short" 50 5

    # Count changes
    CHANGES=$(safe_ssh "$DEV" "cd /var/www && git status --porcelain | wc -l" 1 5)
    echo ""
    echo "📊 Uncommitted changes: $CHANGES"

    # Show recent commits
    echo ""
    echo "Recent commits:"
    safe_ssh "$DEV" "cd /var/www && git log --oneline -5" 5 5
else
    echo "✗ No git repository found"
    echo ""
    echo "💡 Git initialization required for deployment"
fi

# Phase 6: Deployment Preparation
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 6: DEPLOYMENT PREPARATION"
echo "═══════════════════════════════════════════════════════════"

echo ""
echo "🎯 DEPLOYMENT TARGET ANALYSIS"
echo "----------------------------"
echo "  Source: $DEV"
echo "  Target: $STAGE"
echo "  Target ID: $STAGE_ID"
echo "  Target Type: $(get_from_zaia ".services[\"$STAGE\"].type // \"unknown\"")"
echo "  Target Role: $(get_from_zaia ".services[\"$STAGE\"].role // \"unknown\"")"

# Check for stage service configuration
STAGE_CONFIG=$(get_from_zaia ".services[\"$STAGE\"].actualZeropsYml // null" 2>/dev/null)
if [ "$STAGE_CONFIG" != "null" ] && [ -n "$STAGE_CONFIG" ]; then
    echo ""
    echo "✓ Stage service has configuration"
else
    echo ""
    echo "⚠️ Stage service needs configuration from dev"
fi

# Phase 7: AI Decision Point
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 7: AI DEPLOYMENT DECISIONS"
echo "═══════════════════════════════════════════════════════════"

echo ""
echo "🤖 AI DEPLOYMENT WORKFLOW"
echo "========================"
echo ""
echo "Based on ALL the information gathered above, the AI should now:"
echo ""
echo "1. BUILD PHASE (if not skipped)"
echo "   ├─ Install dependencies if needed"
echo "   ├─ Run build commands in correct order"
echo "   ├─ Verify build outputs"
echo "   └─ Handle any build errors"
echo ""
echo "2. TEST PHASE (if not skipped)"
echo "   ├─ Identify available test suites"
echo "   ├─ Run appropriate tests"
echo "   └─ Decide whether to continue on failure"
echo ""
echo "3. GIT OPERATIONS"
echo "   ├─ Initialize git if needed"
echo "   ├─ Stage all changes"
echo "   ├─ Create meaningful commit message"
echo "   └─ Ensure clean state for deployment"
echo ""
echo "4. DEPLOYMENT EXECUTION"
echo "   ├─ Final pre-flight checks"
echo "   ├─ Execute zcli push command"
echo "   ├─ Monitor deployment progress"
echo "   └─ Handle any deployment errors"
echo ""
echo "5. POST-DEPLOYMENT"
echo "   ├─ Enable/update subdomain if needed"
echo "   ├─ Verify deployment success"
echo "   ├─ Check application health"
echo "   └─ Provide access information"

# Command Reference
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "COMMAND REFERENCE FOR AI"
echo "═══════════════════════════════════════════════════════════"

echo ""
echo "📚 DEPENDENCY INSTALLATION"
echo "-------------------------"
echo "# Node.js/npm"
echo "safe_ssh \"$DEV\" \"cd /var/www && npm ci --production=false\""
echo "safe_ssh \"$DEV\" \"cd /var/www && npm install\""
echo "safe_ssh \"$DEV\" \"cd /var/www && yarn install\""
echo ""
echo "# Python"
echo "safe_ssh \"$DEV\" \"cd /var/www && pip install -r requirements.txt\""
echo "safe_ssh \"$DEV\" \"cd /var/www && poetry install\""
echo ""
echo "# PHP"
echo "safe_ssh \"$DEV\" \"cd /var/www && composer install --no-dev --optimize-autoloader\""
echo ""
echo "# Ruby"
echo "safe_ssh \"$DEV\" \"cd /var/www && bundle install\""
echo ""
echo "# Go"
echo "safe_ssh \"$DEV\" \"cd /var/www && go mod download\""

echo ""
echo "🏗️ BUILD COMMANDS"
echo "-----------------"
echo "# Node.js"
echo "safe_ssh \"$DEV\" \"cd /var/www && npm run build\""
echo "safe_ssh \"$DEV\" \"cd /var/www && npm run build:production\""
echo ""
echo "# TypeScript"
echo "safe_ssh \"$DEV\" \"cd /var/www && tsc\""
echo ""
echo "# Next.js"
echo "safe_ssh \"$DEV\" \"cd /var/www && next build\""
echo ""
echo "# Python"
echo "safe_ssh \"$DEV\" \"cd /var/www && python manage.py collectstatic --noinput\""
echo ""
echo "# Go"
echo "safe_ssh \"$DEV\" \"cd /var/www && go build -o app\""

echo ""
echo "🧪 TEST COMMANDS"
echo "----------------"
echo "# Node.js"
echo "safe_ssh \"$DEV\" \"cd /var/www && npm test\""
echo "safe_ssh \"$DEV\" \"cd /var/www && npm run test:ci\""
echo ""
echo "# Python"
echo "safe_ssh \"$DEV\" \"cd /var/www && pytest\""
echo "safe_ssh \"$DEV\" \"cd /var/www && python manage.py test\""

echo ""
echo "📝 GIT COMMANDS"
echo "---------------"
echo "# Initialize (if needed)"
echo "safe_ssh \"$DEV\" \"cd /var/www && git init\""
echo "safe_ssh \"$DEV\" \"cd /var/www && git config user.email 'deploy@zerops.local'\""
echo "safe_ssh \"$DEV\" \"cd /var/www && git config user.name 'Zerops Deploy'\""
echo ""
echo "# Stage and commit"
echo "safe_ssh \"$DEV\" \"cd /var/www && git add -A\""
echo "safe_ssh \"$DEV\" \"cd /var/www && git commit -m 'Deploy: \$(date +%Y-%m-%d_%H:%M:%S)'\""

echo ""
echo "🚀 DEPLOYMENT COMMANDS"
echo "---------------------"
echo "# Deploy to stage"
echo "safe_ssh \"$DEV\" \"cd /var/www && zcli push --serviceId $STAGE_ID\""
echo ""
echo "# Enable subdomain"
echo "zcli service enable-subdomain --serviceId \"$STAGE_ID\""
echo ""
echo "# Check deployment logs"
echo "zcli service log --serviceId \"$STAGE_ID\" --limit 50"

echo ""
echo "✅ VERIFICATION COMMANDS"
echo "-----------------------"
echo "# Check application health"
echo "check_application_health \"$STAGE\" 3000"
echo ""
echo "# Diagnose issues"
echo "diagnose_502_enhanced \"$STAGE\""
echo "diagnose_issue \"$STAGE\" --smart"
echo ""
echo "# Get public URL"
echo "get_from_zaia \".services[\\\"$STAGE\\\"].subdomain\""

# Final instructions
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "🎬 ACTION REQUIRED"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "The AI should now:"
echo "1. Analyze all the gathered information"
echo "2. Make intelligent decisions about the deployment"
echo "3. Execute the appropriate commands in order"
echo "4. Handle any errors gracefully"
echo "5. Provide clear feedback about the deployment status"
echo ""

if [ "$FORCE" = true ]; then
    echo "⚠️ FORCE MODE: Deploy even if build/tests fail"
fi

echo ""
echo "Ready for AI-driven deployment workflow..."
echo "═══════════════════════════════════════════════════════════"

exit 0
