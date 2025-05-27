#!/bin/bash
set -e
source /var/www/core_utils.sh

[ $# -lt 1 ] && echo "Usage: $0 <dev-service> [--skip-build]" && exit 1

DEV="$1"
SKIP_BUILD="${2:-false}"

# Verify it's a runtime service
if ! can_ssh "$DEV"; then
    echo "❌ $DEV is not a runtime service"
    exit 1
fi

# Auto-detect stage from .zaia
STAGE=$(get_from_zaia ".deploymentPairs[\"$DEV\"] // \"\"")
[ -z "$STAGE" ] && echo "No stage service for $DEV" && exit 1

STAGE_ID=$(get_service_id "$STAGE")

echo "=== DEPLOYING $DEV → $STAGE ==="

# Verify code exists
safe_ssh "$DEV" "ls -la /var/www | wc -l" 1 5 | grep -q "^[3-9]" || (echo "No code found" && exit 1)

# Check for sensitive data in code
echo "🔒 Checking for hardcoded secrets..."
if safe_ssh "$DEV" "grep -r -i -E '(password|secret|key|token)\\s*[:=]\\s*[\"'\''][^\"'\'']+[\"'\'']' /var/www --include='*.js' --include='*.ts' --include='*.py' --include='*.php' --include='*.rb' --include='*.go' --exclude-dir=node_modules --exclude-dir=.git" 20 10 2>/dev/null | grep -v "example\|sample\|placeholder"; then
    echo "⚠️ WARNING: Possible hardcoded secrets detected!"
    echo "   Use environment variables instead"
fi

# Build check
if [ "$SKIP_BUILD" != "--skip-build" ]; then
    # Detect build command
    BUILD_CMD=""
    if safe_ssh "$DEV" "test -f package.json && jq -e '.scripts.build' package.json" 1 5; then
        BUILD_CMD="npm run build"
    elif safe_ssh "$DEV" "test -f yarn.lock && test -f package.json" 1 5; then
        BUILD_CMD="yarn build"
    elif safe_ssh "$DEV" "test -f requirements.txt" 1 5; then
        BUILD_CMD="pip install -r requirements.txt"
    elif safe_ssh "$DEV" "test -f go.mod" 1 5; then
        BUILD_CMD="go build -o app"
    fi

    if [ -n "$BUILD_CMD" ]; then
        echo "Running build: $BUILD_CMD"
        safe_ssh "$DEV" "cd /var/www && $BUILD_CMD" 200 120 || echo "⚠️ Build issues"
    fi
fi

# Git commit
safe_ssh "$DEV" "cd /var/www && [ -d .git ] || git init && git config --global user.email 'deploy@zerops.io' && git config --global user.name 'Zerops Deploy'" 10 10
safe_ssh "$DEV" "cd /var/www && git add . && git commit -m 'Deploy $(date)' || true" 10 10

# Deploy
echo "Pushing to stage..."
safe_ssh "$DEV" "cd /var/www && zcli push --serviceId $STAGE_ID" 100 120

# Enable subdomain
zcli service enable-subdomain --serviceId "$STAGE_ID" || true
sleep 10

# Update .zaia
/var/www/init_project.sh >/dev/null 2>&1 || true

# Show result
if SUBDOMAIN=$(get_from_zaia ".services[\"$STAGE\"].subdomain // \"\"" 2>/dev/null) && [ -n "$SUBDOMAIN" ]; then
    echo "🌐 Deployed to: https://$SUBDOMAIN"

    # Quick health check
    if curl -sf "https://$SUBDOMAIN/health" >/dev/null 2>&1; then
        echo "✅ Health endpoint responding"
    elif curl -sf "https://$SUBDOMAIN/" >/dev/null 2>&1; then
        echo "✅ Application responding"
    else
        echo "⚠️ Application not responding yet - checking frontend errors..."
        /var/www/diagnose_frontend.sh "https://$SUBDOMAIN" --check-console || true
    fi
fi

echo ""
echo "📊 Deployment logs:"
echo "   zcli service log --serviceId $STAGE_ID --limit 50"
