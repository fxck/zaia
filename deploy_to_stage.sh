#!/bin/bash
set -e

source /var/www/validate_inputs.sh

usage() {
    echo "Usage: $0 <dev_service> [stage_service]"
    echo ""
    echo "Arguments:"
    echo "  dev_service     Development service hostname (where code is)"
    echo "  stage_service   Stage service hostname (optional, auto-detected from pairs)"
    echo ""
    echo "Options:"
    echo "  --skip-build    Skip production build verification"
    echo "  --skip-subdomain Skip subdomain enablement"
    echo "  --force         Force deployment even if build fails"
    echo ""
    echo "Examples:"
    echo "  $0 myappdev"
    echo "  $0 myappdev myapp"
    echo "  $0 apidev api --skip-subdomain"
    echo ""
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

DEV_SERVICE="$1"
STAGE_SERVICE="$2"
SKIP_BUILD=false
SKIP_SUBDOMAIN=false
FORCE_DEPLOY=false

shift 2
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-subdomain)
            SKIP_SUBDOMAIN=true
            shift
            ;;
        --force)
            FORCE_DEPLOY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if ! validate_service_name "$DEV_SERVICE"; then
    exit 1
fi

if [ -z "$STAGE_SERVICE" ]; then
    if [ ! -f /var/www/.zaia ]; then
        echo "❌ No state file found. Run /var/www/init_state.sh first"
        exit 1
    fi

    STAGE_SERVICE=$(jq -r --arg dev "$DEV_SERVICE" '.deploymentPairs[$dev] // "none"' /var/www/.zaia)
    if [ "$STAGE_SERVICE" == "none" ] || [ "$STAGE_SERVICE" == "null" ]; then
        echo "❌ No stage service found for $DEV_SERVICE"
        echo "Available deployment pairs:"
        jq -r '.deploymentPairs | to_entries[] | "  \(.key) → \(.value)"' /var/www/.zaia
        exit 1
    fi
    echo "ℹ️  Auto-detected stage service: $STAGE_SERVICE"
fi

if ! validate_service_name "$STAGE_SERVICE"; then
    exit 1
fi

echo "Getting stage service ID..."
STAGE_ID=$(get_service_id "$STAGE_SERVICE")
if [ -z "$STAGE_ID" ]; then
    echo "❌ Could not find service ID for $STAGE_SERVICE"
    echo "Try running: /var/www/get_service_envs.sh"
    exit 1
fi
echo "Stage service ID: $STAGE_ID"

echo "=== DEPLOYMENT WORKFLOW ==="
echo "Development: $DEV_SERVICE"
echo "Stage: $STAGE_SERVICE ($STAGE_ID)"
echo "Skip build: $SKIP_BUILD"
echo "Skip subdomain: $SKIP_SUBDOMAIN"
echo "Force deploy: $FORCE_DEPLOY"
echo ""

echo "=== STEP 1: VERIFYING DEV SERVICE ACCESS ==="
if ! ssh -o ConnectTimeout=10 "$DEV_SERVICE" "echo 'SSH OK'" 2>/dev/null; then
    echo "❌ Cannot SSH to $DEV_SERVICE"
    exit 1
fi
echo "✅ SSH access to $DEV_SERVICE verified"

echo ""
echo "=== STEP 2: CHECKING CODE EXISTENCE ==="
CODE_EXISTS=$(ssh "$DEV_SERVICE" "cd /var/www && ls -la | wc -l")
if [ "$CODE_EXISTS" -lt 3 ]; then
    echo "❌ No code found in /var/www on $DEV_SERVICE"
    echo "Create your application code first"
    exit 1
fi
echo "✅ Code found on $DEV_SERVICE"

if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "=== STEP 3: PRODUCTION BUILD VERIFICATION ==="

    BUILD_CMD=""
    if ssh "$DEV_SERVICE" "test -f /var/www/package.json"; then
        if ssh "$DEV_SERVICE" "cd /var/www && cat package.json | jq -e '.scripts.build' >/dev/null 2>&1"; then
            BUILD_CMD="npm run build"
        elif ssh "$DEV_SERVICE" "cd /var/www && cat package.json | jq -e '.scripts.\"build:production\"' >/dev/null 2>&1"; then
            BUILD_CMD="npm run build:production"
        fi
    elif ssh "$DEV_SERVICE" "test -f /var/www/requirements.txt"; then
        echo "ℹ️  Python project detected - skipping build step"
    elif ssh "$DEV_SERVICE" "test -f /var/www/go.mod"; then
        BUILD_CMD="go build -o app ."
    fi

    if [ -n "$BUILD_CMD" ]; then
        echo "Running build command: $BUILD_CMD"
        if ssh "$DEV_SERVICE" "cd /var/www && $BUILD_CMD 2>&1" | tee /tmp/build_check.log; then
            if grep -qi "error\|failed" /tmp/build_check.log; then
                echo "❌ Build completed but contains errors"
                if [ "$FORCE_DEPLOY" = false ]; then
                    echo "Use --force to deploy anyway, or fix build errors"
                    exit 1
                else
                    echo "⚠️  Continuing with deployment due to --force flag"
                fi
            else
                echo "✅ Build successful"
            fi
        else
            echo "❌ Build failed"
            if [ "$FORCE_DEPLOY" = false ]; then
                echo "Use --force to deploy anyway, or fix build errors"
                exit 1
            else
                echo "⚠️  Continuing with deployment due to --force flag"
            fi
        fi
    else
        echo "ℹ️  No build command detected - proceeding with deployment"
    fi
else
    echo ""
    echo "=== STEP 3: SKIPPED - Build verification disabled ==="
fi

echo ""
echo "=== STEP 4: GIT INITIALIZATION ==="
GIT_STATUS=$(ssh "$DEV_SERVICE" "cd /var/www && if [ -d .git ]; then echo 'exists'; else echo 'missing'; fi")

if [ "$GIT_STATUS" = "missing" ]; then
    echo "Initializing git repository..."
    ssh "$DEV_SERVICE" "git config --global --add safe.directory /var/www"
    ssh "$DEV_SERVICE" "cd /var/www && git init && git add . && git commit -m 'Initial deployment commit'"
    echo "✅ Git repository initialized"
else
    echo "Git repository exists, checking for uncommitted changes..."
    UNCOMMITTED=$(ssh "$DEV_SERVICE" "cd /var/www && git status --porcelain | wc -l")
    if [ "$UNCOMMITTED" -gt 0 ]; then
        echo "Committing changes..."
        ssh "$DEV_SERVICE" "git config --global --add safe.directory /var/www"
        ssh "$DEV_SERVICE" "cd /var/www && git add . && git commit -m 'Deployment commit $(date)'"
        echo "✅ Changes committed"
    else
        echo "✅ No uncommitted changes"
    fi
fi

echo ""
echo "=== STEP 5: DEPLOYING TO STAGE ==="
echo "Pushing to stage service..."
if ssh "$DEV_SERVICE" "cd /var/www && zcli push --serviceId $STAGE_ID 2>&1" | tee /tmp/deploy.log; then
    if grep -qi "error\|failed" /tmp/deploy.log; then
        echo "⚠️  Deployment completed but may have issues"
        echo "Check the logs above for details"
    else
        echo "✅ Deployment successful"
    fi
else
    echo "❌ Deployment failed"
    echo "Check the logs above for details"
    exit 1
fi

if [ "$SKIP_SUBDOMAIN" = false ]; then
    echo ""
    echo "=== STEP 6: ENABLING PUBLIC ACCESS ==="
    echo "Enabling subdomain for stage service..."

    if zcli service enable-subdomain --serviceId "$STAGE_ID"; then
        echo "✅ Subdomain enabled"
        echo "Waiting for DNS propagation..."
        sleep 15

        echo "Refreshing environment variables..."
        /var/www/get_service_envs.sh >/dev/null 2>&1 || true

        SUBDOMAIN=""
        if [ -f "/tmp/current_envs.env" ]; then
            SUBDOMAIN=$(grep "^${STAGE_SERVICE}_zeropsSubdomain=" /tmp/current_envs.env | cut -d= -f2 2>/dev/null || echo "")
        fi

        if [ -n "$SUBDOMAIN" ]; then
            echo ""
            echo "🌐 PUBLIC URL: https://$SUBDOMAIN"
            echo "Testing public access..."
            if curl -sf "https://$SUBDOMAIN" >/dev/null 2>&1; then
                echo "✅ Public deployment verified"
            else
                echo "⚠️  Public URL not responding yet (may need more time)"
            fi
        else
            echo "⚠️  Subdomain not available yet in environment variables"
            echo "Check later with: /var/www/get_service_envs.sh"
        fi
    else
        echo "❌ Failed to enable subdomain"
        echo "You can try manually: zcli service enable-subdomain --serviceId $STAGE_ID"
    fi
else
    echo ""
    echo "=== STEP 6: SKIPPED - Subdomain enablement disabled ==="
fi

echo ""
echo "=== STEP 7: UPDATING PROJECT STATE ==="
/var/www/discover_services.sh >/dev/null 2>&1 || echo "⚠️  Failed to update project state"

echo ""
echo "🎉 DEPLOYMENT COMPLETE!"
echo "================================"
echo "Development: $DEV_SERVICE"
echo "Stage: $STAGE_SERVICE"

if [ "$SKIP_SUBDOMAIN" = false ] && [ -n "$SUBDOMAIN" ]; then
    echo "Public URL: https://$SUBDOMAIN"
fi

echo ""
echo "Next steps:"
echo "- Monitor logs: zcli service log $STAGE_ID --follow"
echo "- Check status: /var/www/show_project_context.sh"
echo "- Continue development on $DEV_SERVICE and redeploy as needed"
