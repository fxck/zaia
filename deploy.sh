#!/bin/bash
set -e
source /var/www/core_utils.sh

[ $# -lt 1 ] && echo "Usage: $0 <dev-service> [--skip-build] [--force]" && exit 1

DEV="$1"
SKIP_BUILD=false
FORCE=false

shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build) SKIP_BUILD=true; shift ;;
        --force) FORCE=true; shift ;;
        *) shift ;;
    esac
done

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

# Gather project information for AI analysis
echo "🧠 Gathering project information for AI analysis..."

# 1. Project structure
echo ""
echo "📁 PROJECT STRUCTURE:"
safe_ssh "$DEV" "cd /var/www && find . -type f -name '*.*' | grep -v -E '(node_modules|vendor|.git|target|dist|build|cache|tmp)' | sort | head -100" 100 10

# 2. Key files content
echo ""
echo "📄 KEY FILE CONTENTS:"

# Show main entry points if they exist
for file in "package.json" "Gemfile" "requirements.txt" "go.mod" "Cargo.toml" "pom.xml" "build.gradle" "mix.exs" "composer.json" "Makefile" "Dockerfile" ".gitlab-ci.yml" ".github/workflows" "zerops.yml" "zerops.yaml"; do
    if safe_ssh "$DEV" "test -f /var/www/$file" 1 5; then
        echo ""
        echo "=== $file ==="
        safe_ssh "$DEV" "cd /var/www && head -50 $file" 50 5
    fi
done

# 3. Look for main/index/app/server files
echo ""
echo "🔍 ENTRY POINTS:"
safe_ssh "$DEV" "cd /var/www && find . -maxdepth 3 -type f \( -name 'main.*' -o -name 'index.*' -o -name 'app.*' -o -name 'server.*' -o -name 'start.*' -o -name 'run.*' \) | grep -v node_modules | head -20" 20 5

# 4. Check for any README or docs
echo ""
echo "📚 DOCUMENTATION:"
safe_ssh "$DEV" "cd /var/www && find . -maxdepth 2 -type f -iname 'readme*' -o -iname 'doc*' | head -10" 10 5

# 5. Currently running processes
echo ""
echo "🏃 RUNNING PROCESSES:"
safe_ssh "$DEV" "ps aux | grep -v 'ps aux' | grep -v grep | tail -20" 20 5

# 6. Recent logs
echo ""
echo "📋 RECENT LOGS (if any):"
safe_ssh "$DEV" "cd /var/www && find . -name '*.log' -type f -exec tail -10 {} \; 2>/dev/null | head -50" 50 5 || echo "No logs found"

# 7. Environment context
echo ""
echo "🌍 ENVIRONMENT:"
safe_ssh "$DEV" "cd /var/www && pwd && echo '---' && node -v 2>/dev/null || echo 'node: not found'" 5 5
safe_ssh "$DEV" "python --version 2>/dev/null || python3 --version 2>/dev/null || echo 'python: not found'" 2 5
safe_ssh "$DEV" "ruby --version 2>/dev/null || echo 'ruby: not found'" 2 5
safe_ssh "$DEV" "go version 2>/dev/null || echo 'go: not found'" 2 5
safe_ssh "$DEV" "php --version 2>/dev/null | head -1 || echo 'php: not found'" 2 5

echo ""
echo "💡 AI ANALYSIS NEEDED:"
echo "Based on the above information, the AI should determine:"
echo "1. What kind of project this is"
echo "2. Whether it needs building before deployment"
echo "3. What build commands to run (if any)"
echo "4. How to properly prepare it for production deployment"
echo ""
echo "The AI will use its intelligence to understand the project structure,"
echo "framework, dependencies, and deployment requirements."
echo ""

# Security check (but don't prescribe - let AI analyze)
echo "🔒 SECURITY SCAN:"
safe_ssh "$DEV" "cd /var/www && grep -r -i -E '(password|secret|api_key|private_key|token)\\s*[:=]\\s*[\"'\''][^\"'\'']{8,}[\"'\'']' . --include='*.js' --include='*.ts' --include='*.py' --include='*.php' --include='*.rb' --include='*.go' --include='*.rs' --include='*.java' --include='*.cs' --include='*.ex' --include='*.exs' --include='*.env' --include='*.config' --include='*.conf' --include='*.json' --include='*.yml' --include='*.yaml' --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git" 20 10 2>/dev/null | grep -v "example\|sample\|placeholder\|mock\|test\|dummy" || echo "No obvious secrets found"

if [ "$SKIP_BUILD" = true ]; then
    echo ""
    echo "⚠️ SKIPPING BUILD (--skip-build flag set)"
    echo "The AI would normally analyze the project and determine build steps."
else
    echo ""
    echo "🏗️ BUILD ANALYSIS:"
    echo "The AI should analyze the project structure above and determine:"
    echo "- If building is needed"
    echo "- What commands to run"
    echo "- In what order"
    echo "- What files to check for success"
fi

# Git operations
echo ""
echo "📝 Preparing Git repository..."
safe_ssh "$DEV" "cd /var/www && git status --porcelain 2>/dev/null | head -20" 20 5 || safe_ssh "$DEV" "cd /var/www && git init && echo 'Git initialized'" 5 5

# Show git status
echo ""
echo "📊 Git status:"
safe_ssh "$DEV" "cd /var/www && git status --short" 50 10 || echo "Git not initialized"

# Deployment preparation
echo ""
echo "🚀 DEPLOYMENT PREPARATION:"
echo "The AI should now:"
echo "1. Ensure all changes are committed"
echo "2. Verify deployment configuration exists"
echo "3. Check all prerequisites"
echo "4. Execute the deployment"

# Check for deployment configuration
echo ""
echo "⚙️ Deployment configuration:"
if safe_ssh "$DEV" "test -f /var/www/zerops.yml" 1 5; then
    echo "✅ zerops.yml found"
    safe_ssh "$DEV" "cd /var/www && cat zerops.yml" 200 10
else
    echo "❌ No zerops.yml found"
    echo "The AI needs to determine if this is critical or if defaults will work"
fi

# Stage service info
echo ""
echo "🎯 TARGET STAGE SERVICE:"
echo "Service: $STAGE"
echo "ID: $STAGE_ID"
echo "Type: $(get_from_zaia ".services[\"$STAGE\"].type // \"unknown\"")"

# Let AI make all decisions
echo ""
echo "🧠 AI DECISION POINT:"
echo "Based on all the above information, the AI should now intelligently:"
echo "1. Determine the exact build commands needed (if any)"
echo "2. Execute them in the correct order"
echo "3. Commit any changes to git"
echo "4. Deploy using: zcli push --serviceId $STAGE_ID"
echo "5. Verify the deployment succeeded"
echo ""
echo "The AI has full context and can make intelligent decisions about"
echo "this specific project without relying on hardcoded patterns."

# Provide the deployment command for AI to use when ready
echo ""
echo "📌 When ready to deploy, use:"
echo "   safe_ssh \"$DEV\" \"cd /var/www && zcli push --serviceId $STAGE_ID\""
echo ""
echo "📌 After deployment, enable public access with:"
echo "   zcli service enable-subdomain --serviceId \"$STAGE_ID\""
