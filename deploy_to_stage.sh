#!/bin/bash
set -e

source /var/www/validate_inputs.sh

usage() {
    echo "Usage: $0 <dev_service> [stage_service]"
    echo ""
    echo "Arguments:"
    echo "  dev_service     Development service hostname (where code is)"
    echo "  stage_service   Stage service hostname (optional, auto-detected from .zaia pairs)"
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

shift
if [ -n "$1" ] && [[ "$1" != --* ]]; then
    STAGE_SERVICE="$1"
    shift
fi

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
            echo "❌ Unknown option: $1"
            usage
            ;;
    esac
done

if ! validate_service_name "$DEV_SERVICE"; then
    exit 1
fi

# CLEAN: Check .zaia exists and is valid
if [ ! -f /var/www/.zaia ]; then
    echo "❌ FATAL: .zaia file not found. Run /var/www/init_state.sh first"
    exit 1
fi

if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ FATAL: .zaia file is corrupted. Run /var/www/init_state.sh"
    exit 1
fi

if [ -z "$STAGE_SERVICE" ]; then
    STAGE_SERVICE=$(jq -r --arg dev "$DEV_SERVICE" '.deploymentPairs[$dev] // "none"' /var/www/.zaia)
    if [ "$STAGE_SERVICE" == "none" ] || [ "$STAGE_SERVICE" == "null" ]; then
        echo "❌ FATAL: No stage service found for $DEV_SERVICE in .zaia"
        echo "Available deployment pairs:"
        jq -r '.deploymentPairs | to_entries[] | "  \(.key) → \(.value)"' /var/www/.zaia
        exit 1
    fi
    echo "ℹ️  Auto-detected stage service: $STAGE_SERVICE"
fi

if ! validate_service_name "$STAGE_SERVICE"; then
    exit 1
fi

echo "Getting stage service ID from .zaia..."
STAGE_ID=$(get_service_id "$STAGE_SERVICE")  # This will exit if not found
echo "Stage service ID: $STAGE_ID"

echo "=== DEPLOYMENT WORKFLOW (.zaia ONLY) ==="
echo "Development: $DEV_SERVICE"
echo "Stage: $STAGE_SERVICE ($STAGE_ID)"
echo "Skip build: $SKIP_BUILD"
echo "Skip subdomain: $SKIP_SUBDOMAIN"
echo "Force deploy: $FORCE_DEPLOY"
echo ""

echo "=== STEP 1: VERIFYING DEV SERVICE ACCESS ==="
if ! ssh -o ConnectTimeout=10 "zerops@$DEV_SERVICE" "echo 'SSH OK'" 2>/dev/null; then
    echo "❌ FATAL: Cannot SSH to $DEV_SERVICE"
    exit 1
fi
echo "✅ SSH access to $DEV_SERVICE verified"

echo ""
echo "=== STEP 2: CHECKING CODE EXISTENCE ==="
CODE_EXISTS=$(ssh "zerops@$DEV_SERVICE" "cd /var/www && ls -la | wc -l")
if [ "$CODE_EXISTS" -lt 3 ]; then
    echo "❌ FATAL: No code found in /var/www on $DEV_SERVICE"
    echo "Create your application code first"
    exit 1
fi
echo "✅ Code found on $DEV_SERVICE"

if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "=== STEP 3: PRODUCTION BUILD VERIFICATION ==="

    BUILD_CMD=""
    if ssh "zerops@$DEV_SERVICE" "test -f /var/www/package.json"; then
        if ssh "zerops@$DEV_SERVICE" "cd /var/www && cat package.json | jq -e '.scripts.build' >/dev/null 2>&1"; then
            BUILD_CMD="npm run build"
        elif ssh "zerops@$DEV_SERVICE" "cd /var/www && cat package.json | jq -e '.scripts.\"build:production\"' >/dev/null 2>&1"; then
            BUILD_CMD="npm run build:production"
        fi
    elif ssh "zerops@$DEV_SERVICE" "test -f /var/www/requirements.txt"; then
        echo "ℹ️  Python project detected - skipping build step"
    elif ssh "zerops@$DEV_SERVICE" "test -f /var/www/go.mod"; then
        BUILD_CMD="go build -o app ."
    fi

    if [ -n "$BUILD_CMD" ]; then
        echo "Running build command: $BUILD_CMD"
        if ssh "zerops@$DEV_SERVICE" "cd /var/www && $BUILD_CMD 2>&1" | tee /tmp/build_check.log; then
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
GIT_STATUS=$(ssh "zerops@$DEV_SERVICE" "cd /var/www && if [ -d .git ]; then echo 'exists'; else echo 'missing'; fi")

if [ "$GIT_STATUS" = "missing" ]; then
    echo "Initializing git repository..."
    ssh "zerops@$DEV_SERVICE" "git config --global --add safe.directory /var/www"
    ssh "zerops@$DEV_SERVICE" "cd /var/www && git init && git add . && git commit -m 'Initial deployment commit'"
    echo "✅ Git repository initialized"
else
    echo "Git repository exists, checking for uncommitted changes..."
    UNCOMMITTED=$(ssh "zerops@$DEV_SERVICE" "cd /var/www && git status --porcelain | wc -l")
    if [ "$UNCOMMITTED" -gt 0 ]; then
        echo "Committing changes..."
        ssh "zerops@$DEV_SERVICE" "git config --global --add safe.directory /var/www"
        ssh "zerops@$DEV_SERVICE" "cd /var/www && git add . && git commit -m 'Deployment commit $(date)'"
        echo "✅ Changes committed"
    else
        echo "✅ No uncommitted changes"
    fi
fi

echo ""
echo "=== STEP 5: DEPLOYING TO STAGE ==="
echo "Pushing to stage service..."
if ssh "zerops@$DEV_SERVICE" "cd /var/www && zcli push --serviceId $STAGE_ID 2>&1" | tee /tmp/deploy.log; then
    if grep -qi "error\|failed" /tmp/deploy.log; then
        echo "⚠️  Deployment completed but may have issues"
        echo "Check the logs above for details"
    else
        echo "✅ Deployment successful"
    fi
else
    echo "❌ FATAL: Deployment failed"
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

        echo "Refreshing .zaia with latest subdomain data..."
        /var/www/sync_env_to_zaia.sh >/dev/null 2>&1 || true

        # CLEAN: Get subdomain from .zaia ONLY
        if SUBDOMAIN=$(get_service_subdomain "$STAGE_SERVICE" 2>/dev/null); then
            echo ""
            echo "🌐 PUBLIC URL: https://$SUBDOMAIN"
            echo "Testing public access..."
            if curl -sf "https://$SUBDOMAIN" >/dev/null 2>&1; then
                echo "✅ Public deployment verified"
            else
                echo "⚠️  Public URL not responding yet (may need more time)"
                echo "You can test manually: curl -f https://$SUBDOMAIN"
            fi
        else
            echo "⚠️  Subdomain not available yet in .zaia"
            echo "Check later with: get_service_subdomain $STAGE_SERVICE"
        fi
    else
        echo "❌ FATAL: Failed to enable subdomain"
        exit 1
    fi
else
    echo ""
    echo "=== STEP 6: SKIPPED - Subdomain enablement disabled ==="
fi

echo ""
echo "=== STEP 7: UPDATING PROJECT STATE ==="
if ! /var/www/discover_services.sh >/dev/null 2>&1; then
    echo "⚠️  Failed to update project state - continuing anyway"
fi

echo ""
echo "🎉 DEPLOYMENT COMPLETE!"
echo "================================"
echo "Development: $DEV_SERVICE"
echo "Stage: $STAGE_SERVICE"

# CLEAN: Get subdomain from .zaia ONLY for final summary
if [ "$SKIP_SUBDOMAIN" = false ]; then
    if FINAL_SUBDOMAIN=$(get_service_subdomain "$STAGE_SERVICE" 2>/dev/null); then
        echo "Public URL: https://$FINAL_SUBDOMAIN"
    fi
fi

echo ""
echo "Next steps (.zaia ONLY):"
echo "- Monitor logs: zcli service log --serviceId $STAGE_ID --follow"
echo "- Check status: /var/www/show_project_context.sh"
echo "- View env vars: get_available_envs $STAGE_SERVICE"
echo "- Continue development on $DEV_SERVICE and redeploy as needed"

# Cleanup
rm -f /tmp/build_check.log /tmp/deploy.log
