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

# Phase 1: Technology Detection
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 1: TECHNOLOGY DETECTION"
echo "═══════════════════════════════════════════════════════════"

# Function to detect technology
detect_technology() {
    local service="$1"

    # Language-agnostic detection pattern
    local indicators=(
        "package.json:javascript"
        "composer.json:php"
        "requirements.txt:python"
        "Gemfile:ruby"
        "go.mod:go"
        "Cargo.toml:rust"
        "pom.xml:java"
        "build.gradle:java"
        "mix.exs:elixir"
        "pubspec.yaml:dart"
        ".csproj:dotnet"
    )

    for indicator in "${indicators[@]}"; do
        local file="${indicator%%:*}"
        local lang="${indicator#*:}"

        if safe_ssh "$service" "test -f /var/www/$file" 2>/dev/null; then
            echo "$lang"
            return 0
        fi
    done

    echo "unknown"
}

# Detect technology
TECH=$(detect_technology "$DEV")
echo "🔍 Detected technology: $TECH"

# Phase 2: Project Analysis
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 2: PROJECT ANALYSIS"
echo "═══════════════════════════════════════════════════════════"

# Project structure
echo ""
echo "📁 PROJECT STRUCTURE"
echo "-------------------"
safe_ssh "$DEV" "cd /var/www && find . -type f -name '*.*' | grep -v -E '(node_modules|vendor|.git|target|dist|build|cache|tmp|__pycache__|.venv|venv|.tox|coverage|.pytest_cache)' | sort | head -50" 50 10

# Dependencies status
echo ""
echo "📦 DEPENDENCIES STATUS"
echo "---------------------"
case "$TECH" in
    javascript)
        safe_ssh "$DEV" "cd /var/www && [ -d node_modules ] && echo '✅ node_modules exists' && du -sh node_modules || echo '❌ No node_modules'" 2 5
        safe_ssh "$DEV" "cd /var/www && [ -f package-lock.json ] && echo '✅ package-lock.json exists' || echo '⚠️ No package-lock.json'" 1 2
        ;;
    python)
        safe_ssh "$DEV" "cd /var/www && [ -d .venv ] && echo '✅ Python venv exists' || echo '❌ No Python venv'" 2 5
        safe_ssh "$DEV" "cd /var/www && [ -f requirements.txt ] && echo '✅ requirements.txt exists' || echo '❌ No requirements.txt'" 1 2
        ;;
    php)
        safe_ssh "$DEV" "cd /var/www && [ -d vendor ] && echo '✅ vendor exists' && du -sh vendor || echo '❌ No vendor'" 2 5
        safe_ssh "$DEV" "cd /var/www && [ -f composer.lock ] && echo '✅ composer.lock exists' || echo '⚠️ No composer.lock'" 1 2
        ;;
    ruby)
        safe_ssh "$DEV" "cd /var/www && [ -f Gemfile.lock ] && echo '✅ Gemfile.lock exists' || echo '⚠️ No Gemfile.lock'" 1 2
        ;;
    go)
        safe_ssh "$DEV" "cd /var/www && [ -f go.sum ] && echo '✅ go.sum exists' || echo '⚠️ No go.sum'" 1 2
        ;;
esac

# Current process status
echo ""
echo "🏃 CURRENT PROCESS STATUS"
echo "------------------------"
safe_ssh "$DEV" "ps aux | grep -v 'ps aux' | grep -v grep | grep -v sshd | grep -v bash | tail -10" 10 5

# Phase 3: Build Analysis (if not skipped)
if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "PHASE 3: BUILD EXECUTION"
    echo "═══════════════════════════════════════════════════════════"

    echo ""
    echo "🏗️ Running build for $TECH project..."

    case "$TECH" in
        javascript)
            # Check for build script
            if safe_ssh "$DEV" "cd /var/www && grep -q '\"build\"' package.json" 2>/dev/null; then
                echo "📦 Installing dependencies..."
                safe_ssh "$DEV" "cd /var/www && npm ci --production=false" || safe_ssh "$DEV" "cd /var/www && npm install"

                echo "🔨 Running build..."
                if ! safe_ssh "$DEV" "cd /var/www && npm run build"; then
                    [ "$FORCE" = true ] || exit 1
                fi
            else
                echo "⚠️ No build script found in package.json"
            fi
            ;;

        python)
            echo "📦 Installing dependencies..."
            safe_ssh "$DEV" "cd /var/www && pip install -r requirements.txt" || true

            # Check for Django
            if safe_ssh "$DEV" "test -f /var/www/manage.py" 2>/dev/null; then
                echo "🎨 Collecting static files..."
                safe_ssh "$DEV" "cd /var/www && python manage.py collectstatic --noinput" || true
            fi
            ;;

        php)
            echo "📦 Installing dependencies..."
            safe_ssh "$DEV" "cd /var/www && composer install --no-dev --optimize-autoloader" || true
            ;;

        go)
            echo "📦 Building application..."
            safe_ssh "$DEV" "cd /var/www && go build -o app" || [ "$FORCE" = true ] || exit 1
            ;;

        ruby)
            echo "📦 Installing dependencies..."
            safe_ssh "$DEV" "cd /var/www && bundle install" || true

            # Check for Rails
            if safe_ssh "$DEV" "test -f /var/www/Rakefile" 2>/dev/null; then
                echo "🎨 Precompiling assets..."
                safe_ssh "$DEV" "cd /var/www && bundle exec rake assets:precompile" || true
            fi
            ;;

        *)
            echo "⚠️ Unknown technology - skipping build"
            ;;
    esac

    # Verify build output
    verify_build_success "$DEV" || [ "$FORCE" = true ] || exit 1
fi

# Phase 4: Test Execution (if not skipped)
if [ "$SKIP_TESTS" = false ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "PHASE 4: TEST EXECUTION"
    echo "═══════════════════════════════════════════════════════════"

    case "$TECH" in
        javascript)
            if safe_ssh "$DEV" "cd /var/www && grep -q '\"test\"' package.json" 2>/dev/null; then
                echo "🧪 Running tests..."
                safe_ssh "$DEV" "cd /var/www && npm test" || [ "$FORCE" = true ] || exit 1
            else
                echo "⚠️ No test script found"
            fi
            ;;

        python)
            if safe_ssh "$DEV" "test -f /var/www/pytest.ini -o -d /var/www/tests" 2>/dev/null; then
                echo "🧪 Running tests..."
                safe_ssh "$DEV" "cd /var/www && pytest" || [ "$FORCE" = true ] || exit 1
            elif safe_ssh "$DEV" "test -f /var/www/manage.py" 2>/dev/null; then
                echo "🧪 Running Django tests..."
                safe_ssh "$DEV" "cd /var/www && python manage.py test" || [ "$FORCE" = true ] || exit 1
            else
                echo "⚠️ No test framework detected"
            fi
            ;;

        *)
            echo "⚠️ Test execution not configured for $TECH"
            ;;
    esac
fi

# Phase 5: Git Operations
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 5: GIT OPERATIONS"
echo "═══════════════════════════════════════════════════════════"

# Initialize git if needed
if ! safe_ssh "$DEV" "cd /var/www && [ -d .git ]" 2>/dev/null; then
    echo "📝 Initializing git repository..."
    safe_ssh "$DEV" "cd /var/www && git init"
    safe_ssh "$DEV" "cd /var/www && git config user.email 'deploy@zerops.local'"
    safe_ssh "$DEV" "cd /var/www && git config user.name 'Zerops Deploy'"
fi

# Check git status
echo "📝 Current git status:"
safe_ssh "$DEV" "cd /var/www && git status --short" 50 5

# Commit changes
CHANGES=$(safe_ssh "$DEV" "cd /var/www && git status --porcelain | wc -l" 1 5)
if [ "$CHANGES" -gt 0 ]; then
    echo "📝 Committing $CHANGES changes..."
    safe_ssh "$DEV" "cd /var/www && git add -A"
    safe_ssh "$DEV" "cd /var/www && git commit -m 'Deploy: $(date +%Y-%m-%d_%H:%M:%S) - $TECH project'"
fi

# Phase 6: Deployment
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 6: DEPLOYMENT EXECUTION"
echo "═══════════════════════════════════════════════════════════"

echo "🚀 Deploying to $STAGE..."

# Use the new monitoring function
if ! deploy_with_monitoring "$DEV" "$STAGE_ID"; then
    echo "❌ Deployment failed"
    exit 1
fi

# Additional verification
sleep 5  # Brief pause for service startup

# Phase 7: Verification
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "PHASE 7: POST-DEPLOYMENT VERIFICATION"
echo "═══════════════════════════════════════════════════════════"

# Wait for deployment to be active
echo "⏳ Waiting for deployment to be active..."
if ! wait_for_deployment_active "$STAGE_ID"; then
    echo "❌ Deployment failed to become active"
    exit 1
fi

# Check service via zcli logs (stage services can't be SSH'ed into)
echo ""
echo "🏥 Checking service via zcli logs..."
echo "Recent logs from $STAGE:"
zcli service log "$STAGE" --limit 10 || echo "⚠️ Could not retrieve logs"

# Enable subdomain if needed
echo ""
echo "🌐 Checking public access..."
ensure_subdomain "$STAGE"

# Update state
echo ""
echo "🔄 Updating project state..."
sync_env_to_zaia

# Get public URL
PUBLIC_URL=$(get_from_zaia ".services[\"$STAGE\"].subdomain")
if [ -n "$PUBLIC_URL" ] && [ "$PUBLIC_URL" != "null" ]; then
    echo ""
    echo "✅ DEPLOYMENT SUCCESSFUL!"
    echo "🌐 Public URL: https://$PUBLIC_URL"

    # Run frontend diagnostics if applicable (use public URL since we can't SSH to stage)
    if [[ "$TECH" == "javascript" ]]; then
        echo ""
        echo "🔍 Running frontend diagnostics..."
        /var/www/diagnose_frontend.sh "https://$PUBLIC_URL" --check-console --check-network || true
    fi
else
    echo ""
    echo "✅ Deployment complete (no public URL configured)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "📊 DEPLOYMENT SUMMARY"
echo "═══════════════════════════════════════════════════════════"
echo "  Technology: $TECH"
echo "  Source: $DEV"
echo "  Target: $STAGE"
echo "  Status: ✅ Success"
[ -n "$PUBLIC_URL" ] && [ "$PUBLIC_URL" != "null" ] && echo "  URL: https://$PUBLIC_URL"
echo "═══════════════════════════════════════════════════════════"

exit 0
