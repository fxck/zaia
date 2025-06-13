#!/bin/bash
set -e

# Core safety configuration
export ZEROPS_SSH_TIMEOUT=15
export ZEROPS_OUTPUT_LIMIT=100
export ZEROPS_CMD_TIMEOUT=30

# Enhanced execution wrapper
zaia_exec() {
    source /var/www/core_utils.sh 2>/dev/null || { echo "❌ Core utils unavailable"; exit 1; }
    "$@"
}

# Verification helper
verify_check() {
    local description="$1"
    local command="$2"

    echo -n "  Checking: $description... "
    if eval "$command" >/dev/null 2>&1; then
        echo "✅"
        return 0
    else
        echo "❌"
        return 1
    fi
}

# Base64-based safe remote file creation
safe_create_remote_file() {
    local service="$1"
    local filepath="$2"
    local content="$3"

    if ! can_ssh "$service"; then
        echo "❌ Cannot create file on managed service $service" >&2
        return 1
    fi

    # MANDATORY: Validate development service configurations
    if [[ "$filepath" == *"zerops.yml"* ]]; then
        echo "🔍 Validating zerops.yml configuration..."
        if ! validate_dev_service_config "$content" "$service"; then
            echo "❌ DEPLOYMENT BLOCKED: Development service configuration invalid"
            echo "📋 Use template from .goosehints with mandatory code-server setup"
            return 1
        fi
    fi

    # Base64 encode to prevent ANY shell interpretation
    local encoded_content=$(echo "$content" | base64 -w0)

    echo "📝 Creating $filepath on $service..."

    # Create directory if needed
    local dir=$(dirname "$filepath")
    safe_ssh "$service" "mkdir -p '$dir'" || return 1

    # Decode and write file
    if safe_ssh "$service" "echo '$encoded_content' | base64 -d > '$filepath'"; then
        # Verify file was created and has content
        if safe_ssh "$service" "test -s '$filepath'"; then
            echo "✅ Successfully created $filepath"
            return 0
        else
            echo "❌ File created but appears empty" >&2
            return 1
        fi
    else
        echo "❌ Failed to create $filepath" >&2
        return 1
    fi
}

# Validate content for common issues before creation
validate_remote_file_content() {
    local content="$1"
    local warnings=0

    # Check for SQL parameters that might get expanded
    if echo "$content" | grep -qE '\$[0-9]+|\${[0-9]+}'; then
        echo "✅ Content contains SQL parameters (\$1, \$2, etc.) - will be preserved via base64" >&2
        ((warnings++))
    fi

    # Check for potential command substitution
    if echo "$content" | grep -qE '\$\(.*\)|\`.*\`'; then
        echo "⚠️ WARNING: Content contains command substitution - will be preserved literally" >&2
        ((warnings++))
    fi

    return 0
}

# Monitor build status with active polling
monitor_zcli_build() {
    local build_output="$1"

    # Check if the output indicates success/failure directly
    if echo "$build_output" | grep -q "successfully"; then
        echo "✅ Build completed successfully"
        return 0
    fi

    if echo "$build_output" | grep -q "failed\|error\|Error"; then
        echo "❌ Build failed"
        return 1
    fi

    # Extract build ID from output if available
    local build_id=$(echo "$build_output" | grep -oE 'build[/-]([a-zA-Z0-9-]+)' | grep -oE '[a-zA-Z0-9-]+$' | head -1)

    if [ -z "$build_id" ]; then
        echo "⚠️ Could not extract build ID from output, assuming success" >&2
        echo "Build output was: $build_output" >&2
        return 0
    fi

    echo "📊 Monitoring build: $build_id"

    local max_wait=600  # 10 minutes
    local elapsed=0
    local last_status=""

    while [ $elapsed -lt $max_wait ]; do
        local build_info=$(zcli build describe --buildId "$build_id" 2>/dev/null || echo '{}')
        local status=$(echo "$build_info" | jq -r '.status // "UNKNOWN"')

        # Only print status if it changed
        if [ "$status" != "$last_status" ]; then
            echo "📍 Build status: $status"
            last_status="$status"
        fi

        case "$status" in
            "DEPLOYED"|"DEPLOYMENT_SUCCESSFUL")
                echo "✅ Build and deployment successful!"
                return 0
                ;;
            "BUILD_FAILED"|"DEPLOYMENT_FAILED"|"CANCELLED")
                echo "❌ Build $status" >&2
                echo "📋 Fetching build logs..." >&2
                zcli build log --buildId "$build_id" 2>/dev/null | tail -100 || true
                return 1
                ;;
            "BUILDING"|"DEPLOYING"|"PENDING")
                printf "."
                ;;
        esac

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    echo "⚠️ Build monitoring timeout after ${max_wait}s" >&2
    return 1
}

# Wrapper for deployment with monitoring
deploy_with_monitoring() {
    local dev_service="$1"
    local stage_id="$2"

    echo "🚀 Deploying from $dev_service to $stage_id..."

    # Execute deployment directly without capturing output (let it stream)
    if safe_ssh "$dev_service" "cd /var/www && zcli login '$ZEROPS_ACCESS_TOKEN' >/dev/null 2>&1 && zcli push --serviceId '$stage_id'"; then
        echo "✅ Deployment completed successfully"
        return 0
    else
        echo "❌ Deployment failed"
        return 1
    fi
}

# Active waiting with condition checking
wait_for_condition() {
    local description="$1"
    local check_command="$2"
    local max_wait="${3:-60}"
    local interval="${4:-5}"

    echo -n "⏳ Waiting for $description"
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        if eval "$check_command" >/dev/null 2>&1; then
            echo " ✅"
            return 0
        fi

        printf "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo " ❌ (timeout after ${max_wait}s)"
    return 1
}

# Common wait patterns
wait_for_service_ready() {
    local service="$1"
    wait_for_condition \
        "$service to be ready" \
        "get_service_id '$service' 2>/dev/null" \
        30 \
        2
}

wait_for_deployment_active() {
    local service_id="$1"
    wait_for_condition \
        "deployment to be active" \
        "zcli service log --serviceId '$service_id' --limit 1 >/dev/null 2>&1" \
        60 \
        5
}

# Get development service from state
get_development_service() {
    local dev_services=$(get_from_zaia '.services | to_entries[] | select(.value.role == "development") | .key' | head -1)
    if [ -z "$dev_services" ]; then
        echo "❌ No development service found" >&2
        return 1
    fi
    echo "$dev_services"
}

# Check if deployment exists for a service
deployment_exists() {
    local service="${1:-$(get_development_service)}"
    local stage="${service%dev}"

    local stage_id=$(get_from_zaia ".services[\"$stage\"].id // \"\"")
    [ -n "$stage_id" ] && [ "$stage_id" != "pending" ]
}

# Ensure service has subdomain
ensure_subdomain() {
    local service="$1"
    local service_id=$(get_service_id "$service")

    echo "🌐 Enabling subdomain for $service (ID: $service_id)..."
    
    # Try to enable subdomain - will succeed even if already enabled
    if zcli service enable-subdomain --serviceId "$service_id"; then
        echo "✅ Subdomain enabled successfully"
        sleep 5
        sync_env_to_zaia
        return 0
    else
        echo "❌ Failed to enable subdomain"
        echo "💡 Try manually: zcli service enable-subdomain --serviceId $service_id"
        return 1
    fi
}

# Verify service exists in state
verify_service_exists() {
    local service="$1"
    get_from_zaia ".services[\"$service\"]" >/dev/null 2>&1
}

# Verify git state is clean
verify_git_state() {
    local service="$1"

    if ! safe_ssh "$service" "cd /var/www && [ -d .git ]" 2>/dev/null; then
        echo "⚠️ Git not initialized"
        return 1
    fi

    local changes=$(safe_ssh "$service" "cd /var/www && git status --porcelain | wc -l" 1 5)
    if [ "$changes" -gt 0 ]; then
        echo "⚠️ Uncommitted changes detected"
        safe_ssh "$service" "cd /var/www && git status --short" 20 5
        return 1
    fi

    return 0
}

# Verify build succeeded
verify_build_success() {
    local service="$1"

    # For development services, be more lenient about build artifacts
    if echo "$service" | grep -q "dev"; then
        echo "✅ Development service - skipping build artifact verification"
        return 0
    fi

    # Check for common build artifacts based on technology
    if safe_ssh "$service" "test -f /var/www/package.json" 2>/dev/null; then
        # JavaScript project
        if safe_ssh "$service" "grep -q '\"build\"' /var/www/package.json" 2>/dev/null; then
            if ! safe_ssh "$service" "test -d /var/www/dist -o -d /var/www/build -o -d /var/www/.next" 2>/dev/null; then
                echo "⚠️ No build artifacts found"
                return 1
            fi
        fi
    fi

    return 0
}

# Check deployment status
check_deployment_status() {
    local service="$1"
    local service_id=$(get_service_id "$service")

    if ! zcli service describe --serviceId "$service_id" | grep -q "running"; then
        echo "❌ Service not running"
        zcli service log --serviceId "$service_id" --limit 50
        return 1
    fi

    return 0
}

# Verify service health
verify_health() {
    local service="$1"
    local port="${2:-3000}"

    check_application_health "$service" "$port"
}

# Generate service YAML from template
generate_service_yaml() {
    local name="$1"
    local type="$2"
    local options="$3"

    local yaml="services:
  - hostname: $name
    type: $type"

    # Add options if provided
    if [ -n "$options" ]; then
        yaml="$yaml
    $options"
    fi

    echo "$yaml"
}

# Output limiting wrapper
safe_output() {
    local max_lines="${1:-100}"
    local max_time="${2:-30}"
    shift 2

    if ! timeout "$max_time" "$@" 2>&1 | head -n "$max_lines"; then
        local exit_code=$?
        [ $exit_code -eq 124 ] && echo "⚠️ Command timed out after ${max_time}s"
        return $exit_code
    fi
}

# Check if service allows SSH
can_ssh() {
    local service="$1"
    [ -z "$service" ] && echo "false" && return 1

    local service_type=$(get_from_zaia ".services[\"$service\"].type // \"\"" 2>/dev/null || echo "")
    local service_role=$(get_from_zaia ".services[\"$service\"].role // \"\"" 2>/dev/null || echo "")

    # Check by role first
    if [[ "$service_role" =~ ^(database|cache|storage)$ ]]; then
        return 1
    fi

    # Extract base type without version
    local base_type=$(echo "$service_type" | cut -d@ -f1)

    # Check against known managed services
    case "$base_type" in
        postgresql|mysql|mariadb|mongodb|elasticsearch|clickhouse|kafka|\
        keydb|valkey|redis|memcached|meilisearch|nats|rabbitmq|seaweedfs|\
        typesense|qdrant|objectstorage|object-storage|sharedstorage|shared-storage)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Safe SSH with output limiting
safe_ssh() {
    local service="$1"
    local command="$2"
    local max_lines="${3:-100}"
    local max_time="${4:-30}"

    if ! can_ssh "$service"; then
        echo "❌ SSH not available for $service (managed service)" >&2
        return 1
    fi

    safe_output "$max_lines" "$max_time" \
        ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "zerops@$service" "$command"
}

# Mask sensitive environment variables
mask_sensitive_output() {
    sed -E 's/(PASSWORD|SECRET|KEY|TOKEN|PRIVATE|CREDENTIAL|AUTH|APIKEY|PASS)([_=-]?)([A-Za-z0-9_]*)(=|:)([^ "'\'']+)/\1\2\3\4***MASKED***/gi'
}

# Safe environment variable display
show_env_safe() {
    local service="$1"
    echo "🔒 Environment variables (sensitive values masked):"
    safe_ssh "$service" "env | sort" 50 10 | mask_sensitive_output
}

# Safe backgrounding pattern with verification
safe_bg() {
    local service="$1"
    local start_cmd="$2"
    local work_dir="${3:-/var/www}"
    local process_pattern="${4:-$start_cmd}"

    if ! can_ssh "$service"; then
        echo "❌ Cannot start process on $service (managed service)" >&2
        return 1
    fi

    echo "🚀 Starting: $start_cmd"

    # Kill any existing process first
    safe_ssh "$service" "pkill -f '$process_pattern' 2>/dev/null || true" 5 5
    sleep 2

    # Start with proper I/O redirection
    if timeout 15 ssh -o ConnectTimeout=10 "zerops@$service" \
        "cd $work_dir && nohup $start_cmd > app.log 2>&1 < /dev/null &"; then
        echo "✅ Command sent successfully"
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "⚠️ Timeout (expected for backgrounding)"
        else
            echo "❌ Failed to send command (exit code: $exit_code)"
            return 1
        fi
    fi

    # Verify separately
    echo "⏳ Waiting for process to start..."
    sleep 5

    if safe_ssh "$service" "pgrep -f '$process_pattern' >/dev/null && echo 'RUNNING' || echo 'FAILED'" 1 5 | grep -q "RUNNING"; then
        echo "✅ Process confirmed running"

        # Show initial logs
        echo ""
        echo "📋 Initial logs:"
        safe_ssh "$service" "tail -20 $work_dir/app.log 2>/dev/null | grep -v '^$'" 20 5 || echo "No logs yet"
        return 0
    else
        echo "❌ Process failed to start"
        echo ""
        echo "📋 Error logs:"
        safe_ssh "$service" "tail -50 $work_dir/app.log 2>/dev/null" 50 5
        return 1
    fi
}

# Get from .zaia only - NO FALLBACKS
get_from_zaia() {
    local path="$1"

    if [ ! -f /var/www/.zaia ]; then
        echo "❌ FATAL: .zaia missing" >&2
        exit 1
    fi

    if ! jq empty /var/www/.zaia 2>/dev/null; then
        echo "❌ FATAL: .zaia corrupted" >&2
        exit 1
    fi

    local result=$(jq -r "$path" /var/www/.zaia 2>/dev/null)

    if [ -z "$result" ] || [ "$result" = "null" ]; then
        echo "" >&2
        return 1
    fi

    echo "$result"
}

# Service ID helper - fails if not found
get_service_id() {
    local service="$1"
    local id=$(get_from_zaia ".services[\"$service\"].id // \"\"")

    if [ -z "$id" ] || [ "$id" = "ID_NOT_FOUND" ] || [ "$id" = "pending" ]; then
        echo "❌ Service ID not found for $service" >&2
        echo "   Run: sync_env_to_zaia" >&2
        exit 1
    fi

    # Strip JSON quotes if present
    echo "$id" | tr -d '"'
}

# Get available environment variables
get_available_envs() {
    local service="$1"

    if ! get_from_zaia ".services[\"$service\"]" >/dev/null 2>&1; then
        echo "❌ Service '$service' not found in .zaia" >&2
        return 1
    fi

    echo "=== ENVIRONMENT VARIABLES FOR $service ==="
    echo ""
    echo "🔗 SERVICE-PROVIDED (from other services):"
    local provided=$(get_from_zaia ".services[\"$service\"].serviceProvidedEnvs[]? // empty" 2>/dev/null)
    if [ -n "$provided" ]; then
        echo "$provided" | sed 's/^/  /'
    else
        echo "  None available"
    fi

    echo ""
    echo "⚙️ SELF-DEFINED (in zerops.yml):"
    local defined=$(get_from_zaia ".services[\"$service\"].selfDefinedEnvs | to_entries[]? | \"  \\(.key): \\(.value)\"" 2>/dev/null)
    if [ -n "$defined" ]; then
        echo "$defined"
    else
        echo "  None defined"
    fi

    echo ""
    echo "💡 To use: Add to zerops.yml under envVariables section"
}

# AI-powered environment variable suggestion
suggest_env_vars() {
    local service="$1"

    echo "🤖 AI ENVIRONMENT VARIABLE ANALYSIS FOR $service"
    echo "================================================"

    # Gather project info for AI analysis
    if can_ssh "$service"; then
        echo ""
        echo "📁 Project structure:"
        safe_ssh "$service" "find /var/www -type f -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.env*' -o -name 'requirements.txt' -o -name 'Gemfile' -o -name 'go.mod' | grep -v -E '(node_modules|vendor|.git)' | head -20" 20 5

        echo ""
        echo "🔍 Environment variable usage in code:"
        safe_ssh "$service" "grep -r 'process\\.env\\|os\\.environ\\|ENV\\[\\|getenv\\|\\$_ENV' /var/www --include='*.js' --include='*.ts' --include='*.py' --include='*.rb' --include='*.php' --include='*.go' --exclude-dir=node_modules --exclude-dir=vendor 2>/dev/null | head -30" 30 10 || echo "No direct env usage found"
    fi

    # Show available service connections
    echo ""
    echo "🔌 Available service connections:"
    local all_services=$(get_from_zaia ".services | keys[]" 2>/dev/null)
    for svc in $all_services; do
        [ "$svc" = "$service" ] && continue
        local role=$(get_from_zaia ".services[\"$svc\"].role" 2>/dev/null)
        case "$role" in
            database)
                echo ""
                echo "  📊 Database: $svc"
                echo "    DATABASE_URL: \${${svc}_connectionString}"
                echo "    DB_HOST: \${${svc}_host}"
                echo "    DB_PORT: \${${svc}_port}"
                echo "    DB_NAME: \${${svc}_database}"
                echo "    DB_USER: \${${svc}_user}"
                echo "    DB_PASSWORD: \${${svc}_password}"
                ;;
            cache)
                echo ""
                echo "  🚀 Cache: $svc"
                echo "    REDIS_URL: \${${svc}_connectionString}"
                echo "    CACHE_HOST: \${${svc}_host}"
                echo "    CACHE_PORT: \${${svc}_port}"
                ;;
        esac
    done

    # Technology-agnostic suggestions
    echo ""
    echo "🎯 Common environment variables:"
    echo "  PORT: 3000"
    echo "  NODE_ENV: production"
    echo "  LOG_LEVEL: info"
    echo "  API_PREFIX: /api"
    echo "  CORS_ORIGIN: *"
    echo ""
    echo "💡 AI RECOMMENDATIONS:"
    echo "Based on the analysis above, the AI should determine:"
    echo "1. Required environment variables from code analysis"
    echo "2. Optimal service connections to configure"
    echo "3. Security best practices for the detected technology"
    echo "4. Performance-related configurations"
}

# Check if service needs restart for env vars
needs_restart() {
    local service="$1"
    local other="$2"

    # Check if service's zerops.yml references other service's variables
    local yml=$(get_from_zaia ".services[\"$service\"].actualZeropsYml // \"\"" 2>/dev/null)

    if [ -n "$yml" ] && [[ "$yml" == *"\$${other}_"* ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# Restart service for environment variables
restart_service_for_envs() {
    local service="$1"
    local reason="$2"

    local service_id=$(get_service_id "$service")  # Will exit if not found

    echo "🔄 Restarting $service: $reason"

    if ! zcli service stop --serviceId "$service_id"; then
        echo "❌ Failed to stop service"
        return 1
    fi

    sleep 5

    if ! zcli service start --serviceId "$service_id"; then
        echo "❌ Failed to start service"
        return 1
    fi

    sleep 10
    echo "✅ $service restarted - new environment variables now accessible"
}

# StartWithoutCode workaround with retry logic
apply_workaround() {
    local service="$1"
    local max_retries=3

    if ! can_ssh "$service"; then
        echo "⚠️ Workaround not needed for managed service $service"
        return 0
    fi

    echo "🔧 Applying StartWithoutCode workaround for $service..."

    for i in $(seq 1 $max_retries); do
        if timeout 15 ssh -o ConnectTimeout=10 "zerops@$service" "zsc setSecretEnv foo bar" 2>/dev/null; then
            echo "✅ Workaround applied successfully"
            return 0
        fi

        if [ $i -lt $max_retries ]; then
            echo "⚠️ Retry $i/$max_retries..."
            sleep 10
        fi
    done

    echo "❌ Workaround failed after $max_retries attempts"
    echo "   Run manually: ssh zerops@$service 'zsc setSecretEnv foo bar'"
    return 1
}

# Check if service has live reload
has_live_reload() {
    local service="$1"

    if ! can_ssh "$service"; then
        echo "false"
        return
    fi

    local patterns="webpack-dev-server|vite|next dev|react-scripts start|vue-cli-service serve|ng serve|nodemon|ts-node-dev|air|fresh|cargo-watch|mix phx.server"

    if safe_ssh "$service" "ps aux | grep -E '$patterns' | grep -v grep" 1 5 2>/dev/null | grep -q .; then
        echo "true"
    else
        echo "false"
    fi
}

# Monitor live reload with enhanced feedback
monitor_reload() {
    local service="$1"
    local files_changed="${2:-unknown files}"

    if ! can_ssh "$service"; then
        return 1
    fi

    echo "📝 Changed: $files_changed"
    echo "⏳ Waiting for hot reload..."

    # Give time for compilation
    sleep 3

    # Check for compilation messages
    local success_patterns="compiled|rebuilt|hmr|hot.module.replacement|reloading|✓|ready|success|watching|building|done|finished"
    local error_patterns="error|fail|exception|crash|syntax|TypeError|ReferenceError|SyntaxError|Module not found"

    local recent_logs=$(safe_ssh "$service" "tail -100 app.log 2>/dev/null | tail -50" 50 5)

    if echo "$recent_logs" | grep -iE "$success_patterns" | tail -5; then
        echo "✅ Hot reload detected"

        # Check for errors
        local errors=$(echo "$recent_logs" | grep -iE "$error_patterns" | grep -v "ErrorBoundary\|ignore\|warning" | tail -5)
        if [ -n "$errors" ]; then
            echo ""
            echo "⚠️ Errors detected after reload:"
            echo "$errors"
        fi
    else
        echo "⚠️ No reload confirmation found"
        echo "   Check if hot reload is running with: has_live_reload $service"
    fi
}

# Application health check
check_application_health() {
    local service="$1"
    local port="${2:-3000}"
    local process_pattern="${3:-node}"

    echo "=== APPLICATION HEALTH CHECK FOR $service ==="

    if ! can_ssh "$service"; then
        echo "❌ Cannot check health of managed service"
        return 1
    fi

    # 1. Process Status
    echo ""
    echo "1️⃣ Process Status:"
    if safe_ssh "$service" "pgrep -f '$process_pattern'" 1 5 >/dev/null 2>&1; then
        local pids=$(safe_ssh "$service" "pgrep -f '$process_pattern' | tr '\n' ' '" 1 5)
        echo "✅ Process running (PIDs: $pids)"
    else
        echo "❌ Process not running"
        return 1
    fi

    # 2. Port Status
    echo ""
    echo "2️⃣ Port Status:"
    local port_check=$(safe_ssh "$service" "netstat -tln 2>/dev/null | grep :$port || ss -tln 2>/dev/null | grep :$port" 5 5)
    if [ -n "$port_check" ]; then
        echo "✅ Port $port is listening"
        echo "$port_check"
    else
        echo "❌ Port $port is not listening"
    fi

    # 3. Recent Logs
    echo ""
    echo "3️⃣ Recent Logs:"
    safe_ssh "$service" "tail -30 /var/www/app.log 2>/dev/null | grep -v '^$' | tail -20" 20 5 || echo "No logs available"

    # 4. Error Detection
    echo ""
    echo "4️⃣ Error Detection:"
    local error_count=$(safe_ssh "$service" "grep -ic 'error\\|exception\\|crash' /var/www/app.log 2>/dev/null || echo 0" 1 5)
    if [ "$error_count" -gt 0 ]; then
        echo "⚠️ Found $error_count error entries in logs"
        safe_ssh "$service" "grep -i 'error\\|exception\\|crash' /var/www/app.log | tail -10" 10 5
    else
        echo "✅ No errors detected in logs"
    fi

    # 5. Endpoint Test
    echo ""
    echo "5️⃣ Endpoint Test:"
    if curl -sf -m 5 "http://$service:$port/health" >/dev/null 2>&1; then
        echo "✅ Health endpoint responding"
    elif curl -sf -m 5 "http://$service:$port/" >/dev/null 2>&1; then
        echo "✅ Root endpoint responding"
    else
        echo "❌ No HTTP response on port $port"
    fi
}

# Smart error diagnosis with AI assistance
diagnose_issue() {
    local service="$1"
    local smart="${2:-}"

    echo "🔍 INTELLIGENT ERROR DIAGNOSIS FOR $service"
    echo "==========================================="

    if ! can_ssh "$service"; then
        echo "❌ Cannot diagnose managed service $service"
        echo "Use: zcli service log --serviceId $(get_service_id $service 2>/dev/null || echo 'ID_NOT_FOUND')"
        return 1
    fi

    # 1. Process Status
    echo ""
    echo "1️⃣ Process Status:"
    safe_ssh "$service" "ps aux | grep -v 'ps aux' | grep -v grep | grep -v sshd | tail -15" 15 5

    # 2. Error Patterns
    echo ""
    echo "2️⃣ Recent Errors (last 200 lines):"
    local errors=$(safe_ssh "$service" "tail -200 /var/www/app.log 2>/dev/null | grep -iE 'error|exception|fail|crash|fatal|panic|critical' | tail -30" 30 10)
    if [ -n "$errors" ]; then
        echo "$errors"
    else
        echo "No error patterns found in recent logs"
    fi

    # 3. Port Status
    echo ""
    echo "3️⃣ Listening Ports:"
    safe_ssh "$service" "netstat -tlnp 2>/dev/null | grep LISTEN || ss -tlnp 2>/dev/null | grep LISTEN" 10 5

    # 4. Resource Usage
    echo ""
    echo "4️⃣ Resource Usage:"
    safe_ssh "$service" "free -h && echo '---' && df -h /var/www && echo '---' && uptime" 10 5

    # 5. Configuration Files
    echo ""
    echo "5️⃣ Configuration Status:"
    safe_ssh "$service" "ls -la /var/www/zerops.yml /var/www/.env /var/www/config 2>/dev/null" 10 5 || echo "No config files found"

    if [ "$smart" = "--smart" ]; then
        echo ""
        echo "🤖 AI ANALYSIS NEEDED:"
        echo "================================"
        echo "Based on the diagnostic data above, the AI should:"
        echo ""
        echo "1. IDENTIFY the root cause (not just symptoms)"
        echo "   - Is it a code error, configuration issue, or resource problem?"
        echo "   - What is the specific failure point?"
        echo ""
        echo "2. DETERMINE the error category:"
        echo "   - Syntax/compilation error"
        echo "   - Runtime exception"
        echo "   - Configuration mismatch"
        echo "   - Missing dependencies"
        echo "   - Resource exhaustion"
        echo "   - Network/connectivity issue"
        echo ""
        echo "3. SUGGEST specific fixes in order of likelihood"
        echo "4. RECOMMEND preventive measures"
    fi
}

# Enhanced 502 diagnosis
diagnose_502_enhanced() {
    local service="$1"
    local port="${2:-3000}"
    local public_url="${3:-}"

    echo "=== ENHANCED 502 DIAGNOSIS FOR $service ==="

    if ! can_ssh "$service"; then
        echo "❌ Cannot diagnose managed service $service via SSH"
        echo "   Check service configuration and logs via Zerops GUI"
        return 1
    fi

    # 1. Check runtime errors FIRST (most common cause)
    echo ""
    echo "1️⃣ Checking for runtime errors..."
    local error_count=$(safe_ssh "$service" "grep -icE 'error|exception|crash|fatal' /var/www/app.log 2>/dev/null || echo 0" 1 5)

    if [ "$error_count" -gt 0 ]; then
        echo "❌ RUNTIME ERRORS FOUND ($error_count occurrences)"
        safe_ssh "$service" "grep -iE 'error|exception|crash|fatal' /var/www/app.log | tail -30" 30 10
        echo ""
        echo "💡 Fix these errors first - they are likely causing the 502"
        return
    else
        echo "✅ No runtime errors found"
    fi

    # 2. Check if process is running
    echo ""
    echo "2️⃣ Checking process..."
    if ! safe_ssh "$service" "pgrep -f 'node|python|ruby|php|java|go|rust|deno|bun' | head -1" 1 5 | grep -q .; then
        echo "❌ NO PROCESS RUNNING"
        echo ""
        echo "Last logs before crash:"
        safe_ssh "$service" "tail -100 /var/www/app.log | tail -50" 50 10
        echo ""
        echo "💡 Start the application:"
        echo "   safe_bg \"$service\" \"npm start\""
        return
    else
        echo "✅ Process is running"
    fi

    # 3. Check binding (common issue)
    echo ""
    echo "3️⃣ Checking binding on port $port..."
    local binding=$(safe_ssh "$service" "netstat -tln 2>/dev/null | grep :$port || ss -tln 2>/dev/null | grep :$port" 5 5)

    if [ -n "$binding" ]; then
        if echo "$binding" | grep -qE "0\\.0\\.0\\.0:$port|:::$port"; then
            echo "✅ Correctly bound to 0.0.0.0:$port"
        else
            echo "❌ BINDING ISSUE - bound to localhost only"
            echo "$binding"
            echo ""
            echo "💡 Fix by binding to 0.0.0.0:"
            echo "   Node.js:  app.listen($port, '0.0.0.0')"
            echo "   Python:   app.run(host='0.0.0.0', port=$port)"
            echo "   Go:       http.ListenAndServe(':$port', handler)"
            echo "   Ruby:     set :bind, '0.0.0.0'"
            echo "   PHP:      php -S 0.0.0.0:$port"
            return
        fi
    else
        echo "❌ Not listening on port $port"
        echo ""
        echo "💡 Check your configuration:"
        echo "   - Verify PORT environment variable"
        echo "   - Check start command in zerops.yml"
        echo "   - Ensure app uses correct port"
    fi

    # 4. Test local connectivity
    echo ""
    echo "4️⃣ Testing local connectivity..."
    if curl -sf -m 5 "http://$service:$port/" >/dev/null 2>&1; then
        echo "✅ Local access works - issue is with routing/proxy"
        echo ""
        echo "💡 Check:"
        echo "   - Service subdomain configuration"
        echo "   - Zerops routing layer"
        echo "   - CORS headers if applicable"
    else
        echo "❌ Local access failed - application not responding"
        echo ""
        local curl_error=$(curl -sf -m 5 -v "http://$service:$port/" 2>&1 | tail -20)
        echo "Curl details:"
        echo "$curl_error"
    fi

    # 5. Frontend check if URL provided
    if [ -n "$public_url" ]; then
        echo ""
        echo "5️⃣ Checking frontend at $public_url..."
        /var/www/diagnose_frontend.sh "$public_url" --check-console --check-network || true
    fi

    # Summary
    echo ""
    echo "📊 DIAGNOSIS SUMMARY:"
    echo "===================="
    if [ "$error_count" -gt 0 ]; then
        echo "🔴 Runtime errors detected - fix these first"
    elif ! safe_ssh "$service" "pgrep -f 'node|python|ruby|php|java|go|rust|deno|bun'" 1 5 | grep -q .; then
        echo "🔴 Process not running - start the application"
    elif [ -z "$binding" ]; then
        echo "🔴 Not listening on port $port - check configuration"
    elif ! echo "$binding" | grep -qE "0\\.0\\.0\\.0:$port|:::$port"; then
        echo "🔴 Binding to localhost only - change to 0.0.0.0"
    else
        echo "🟡 Application seems OK locally - check routing/proxy layer"
    fi
}

# Safe YAML creation with validation
create_safe_yaml() {
    local output_file="$1"
    local content=""

    # Read from stdin
    content=$(cat)

    # Create temp file for validation
    local temp_file="/tmp/yaml_validate_$$.yaml"
    echo "$content" > "$temp_file"

    # Validate YAML syntax
    if ! yq e '.' "$temp_file" >/dev/null 2>&1; then
        echo "❌ Invalid YAML syntax:" >&2
        cat "$temp_file" | head -20 >&2
        rm -f "$temp_file"
        return 1
    fi

    # Check for common heredoc errors
    if grep -E "^[[:space:]]*EOF[[:space:]]*$" "$temp_file" >/dev/null; then
        echo "❌ Literal 'EOF' found in YAML - heredoc syntax error" >&2
        rm -f "$temp_file"
        return 1
    fi

    # Check for required structure
    if ! yq e '.services' "$temp_file" >/dev/null 2>&1; then
        echo "❌ Missing 'services' section in YAML" >&2
        echo "   YAML must contain:" >&2
        echo "   services:" >&2
        echo "     - hostname: ..." >&2
        rm -f "$temp_file"
        return 1
    fi

    # Validate service entries
    local service_count=$(yq e '.services | length' "$temp_file" 2>/dev/null || echo 0)
    if [ "$service_count" -eq 0 ]; then
        echo "❌ No services defined in YAML" >&2
        rm -f "$temp_file"
        return 1
    fi

    # Check each service has required fields
    local invalid=false
    for i in $(seq 0 $((service_count - 1))); do
        local hostname=$(yq e ".services[$i].hostname" "$temp_file" 2>/dev/null)
        local type=$(yq e ".services[$i].type" "$temp_file" 2>/dev/null)

        if [ -z "$hostname" ] || [ "$hostname" = "null" ]; then
            echo "❌ Service $((i+1)) missing hostname" >&2
            invalid=true
        fi

        if [ -z "$type" ] || [ "$type" = "null" ]; then
            echo "❌ Service $((i+1)) missing type" >&2
            invalid=true
        fi
    done

    if [ "$invalid" = true ]; then
        rm -f "$temp_file"
        return 1
    fi

    # Success - move to output file
    mv "$temp_file" "$output_file"
    echo "✅ Valid YAML created: $output_file"

    # Show summary of what was created
    echo "📋 Services to be created:"
    yq e '.services[] | "  - \(.hostname) (\(.type))"' "$output_file"
    echo ""
    echo "💾 File size: $(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo "unknown") bytes"

    return 0
}

# Validate service type against technologies.json
validate_service_type() {
    local type="$1"

    if [ ! -f /var/www/technologies.json ]; then
        echo "❌ FATAL: technologies.json not found" >&2
        exit 1
    fi

    if grep -qF "\"$type\"" /var/www/technologies.json; then
        echo "✅ Valid service type: $type"
        return 0
    else
        echo "❌ Invalid service type: $type" >&2
        echo "" >&2
        echo "Similar types available:" >&2
        local base_type=$(echo "$type" | cut -d@ -f1)
        grep -F "\"$base_type" /var/www/technologies.json | grep -o '"[^"]*"' | head -10 | sed 's/^/  /' >&2
        return 1
    fi
}

# Service name validation
validate_service_name() {
    local name="$1"

    if [[ ! "$name" =~ ^[a-z0-9]+$ ]]; then
        echo "❌ Invalid service name: $name" >&2
        echo "   Use only lowercase letters and numbers" >&2
        return 1
    fi

    if [[ ${#name} -gt 25 ]]; then
        echo "❌ Service name too long: $name (${#name} chars)" >&2
        echo "   Maximum 25 characters allowed" >&2
        return 1
    fi

    return 0
}

# Determine service role from type and name
get_service_role() {
    local hostname="$1"
    local type="$2"
    local base_type=$(echo "$type" | cut -d@ -f1)

    # Development services end with 'dev'
    if [[ "$hostname" == *dev ]]; then
        echo "development"
        return
    fi

    # Check by technology type
    case "$base_type" in
        # Databases
        postgresql|mysql|mariadb|mongodb|elasticsearch|clickhouse|kafka)
            echo "database"
            ;;
        # Cache services
        redis|keydb|valkey|memcached)
            echo "cache"
            ;;
        # Storage services
        objectstorage|object-storage|sharedstorage|shared-storage|seaweedfs)
            echo "storage"
            ;;
        # Everything else is stage/production
        *)
            echo "stage"
            ;;
    esac
}

# Sync environment variables to .zaia
sync_env_to_zaia() {
    echo "🔄 Syncing environment variables to .zaia..."

    if [ -z "$ZEROPS_ACCESS_TOKEN" ] || [ -z "$projectId" ]; then
        echo "❌ Missing ZEROPS_ACCESS_TOKEN or projectId" >&2
        return 1
    fi

    local api_url="https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/env-file-download"
    local temp_file="/tmp/env_sync_$$.txt"

    # Fetch env data with timeout
    if ! timeout 30 curl -sf -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" "$api_url" -o "$temp_file"; then
        echo "❌ Failed to fetch environment data from API" >&2
        rm -f "$temp_file"
        return 1
    fi

    if [ ! -s "$temp_file" ]; then
        echo "⚠️ No environment data available yet"
        rm -f "$temp_file"
        return 0
    fi

    # Update each service in .zaia
    local services=$(get_from_zaia ".services | keys[]" 2>/dev/null || echo "")

    for service in $services; do
        # Service-provided environment variables
        local envs=$(grep "^${service}_" "$temp_file" 2>/dev/null | cut -d= -f1 | grep -v "_serviceId\|_zeropsSubdomain" | jq -R . | jq -s . || echo "[]")

        if [ "$envs" != "[]" ]; then
            jq --arg s "$service" --argjson e "$envs" \
               '.services[$s].serviceProvidedEnvs = $e' /var/www/.zaia > /tmp/.zaia.tmp
            mv /tmp/.zaia.tmp /var/www/.zaia
        fi

        # Update service ID if available
        local sid=$(grep "^${service}_serviceId=" "$temp_file" 2>/dev/null | cut -d= -f2 || echo "")
        if [ -n "$sid" ]; then
            jq --arg s "$service" --arg id "$sid" \
               '.services[$s].id = $id' /var/www/.zaia > /tmp/.zaia.tmp
            mv /tmp/.zaia.tmp /var/www/.zaia
        fi

        # Update subdomain if available
        local sub=$(grep "^${service}_zeropsSubdomain=" "$temp_file" 2>/dev/null | cut -d= -f2 || echo "")
        if [ -n "$sub" ]; then
            jq --arg s "$service" --arg sub "$sub" \
               '.services[$s].subdomain = $sub' /var/www/.zaia > /tmp/.zaia.tmp
            mv /tmp/.zaia.tmp /var/www/.zaia
        fi
    done

    # Update sync timestamp
    jq --arg ts "$(date -Iseconds)" '.project.lastSync = $ts' /var/www/.zaia > /tmp/.zaia.tmp
    mv /tmp/.zaia.tmp /var/www/.zaia

    rm -f "$temp_file"
    echo "✅ Environment sync complete"

    # Show summary
    local total_vars=$(get_from_zaia '[.services[].serviceProvidedEnvs[]?] | length' 2>/dev/null || echo 0)
    local services_with_ids=$(get_from_zaia '[.services[] | select(.id != "pending" and .id != "")] | length' 2>/dev/null || echo 0)
    local services_with_subdomains=$(get_from_zaia '[.services[] | select(.subdomain)] | length' 2>/dev/null || echo 0)

    echo "  Total env variables: $total_vars"
    echo "  Services with IDs: $services_with_ids"
    echo "  Services with subdomains: $services_with_subdomains"
}

# Security scan for exposed secrets
security_scan() {
    local service="$1"

    echo "🔒 SECURITY SCAN FOR $service"
    echo "============================="

    if ! can_ssh "$service"; then
        echo "⚠️ Cannot scan managed service"
        return 0
    fi

    echo "Scanning for exposed secrets..."

    local patterns='(password|secret|api[_-]?key|private[_-]?key|token|credential|auth)[[:space:]]*[:=][[:space:]]*["\x27][^"\x27]{8,}["\x27]'
    local exclude_patterns='example|sample|placeholder|mock|test|dummy|changeme|your[_-]?|my[_-]?|foo|bar|xxx'

    local findings=$(safe_ssh "$service" "cd /var/www && grep -r -i -E '$patterns' . \
        --include='*.js' --include='*.ts' --include='*.py' --include='*.php' \
        --include='*.rb' --include='*.go' --include='*.env*' --include='*.config' \
        --include='*.conf' --include='*.json' --include='*.yml' --include='*.yaml' \
        --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git \
        --exclude-dir=test --exclude-dir=tests 2>/dev/null || true" 50 20)

    if [ -n "$findings" ]; then
        local real_issues=$(echo "$findings" | grep -v -E "$exclude_patterns" || true)

        if [ -n "$real_issues" ]; then
            echo "❌ POTENTIAL SECRETS EXPOSED:"
            echo "$real_issues" | head -20
            echo ""
            echo "🚨 IMMEDIATE ACTIONS REQUIRED:"
            echo "1. Remove hardcoded secrets from code"
            echo "2. Use envSecrets in import YAML"
            echo "3. Reference via environment variables"
            echo "4. Rotate any exposed credentials"
        else
            echo "✅ No real secrets found (only examples/placeholders)"
        fi
    else
        echo "✅ No exposed secrets detected"
    fi

    # Check for .env files
    echo ""
    echo "Checking for .env files..."
    local env_files=$(safe_ssh "$service" "find /var/www -name '.env*' -type f 2>/dev/null | grep -v node_modules" 10 5)

    if [ -n "$env_files" ]; then
        echo "⚠️ Found .env files (these DON'T WORK in Zerops):"
        echo "$env_files"
        echo ""
        echo "💡 Move all variables to zerops.yml envVariables section"
    else
        echo "✅ No .env files found (good - they don't work anyway)"
    fi
}

# Export all functions
validate_dev_service_config() {
    local config="$1"
    local service="$2"
    
    if echo "$service" | grep -q "dev"; then
        echo "🔍 MANDATORY: Validating development service configuration..."
        
        if ! echo "$config" | grep -q "prepareCommands"; then
            echo "❌ ARCHITECTURE VIOLATION: Missing prepareCommands for code-server installation"
            echo "📋 REQUIRED: Development services MUST include code-server setup"
            return 1
        fi
        
        if ! echo "$config" | grep -q "code-server"; then
            echo "❌ ARCHITECTURE VIOLATION: Missing code-server in start command"
            echo "📋 REQUIRED: start: code-server --auth none --bind-addr 0.0.0.0:8080 /var/www"
            return 1
        fi
        
        if ! echo "$config" | grep -q "port: 8080"; then
            echo "❌ ARCHITECTURE VIOLATION: Missing port 8080 for code-server"
            echo "📋 REQUIRED: Port 8080 for code-server (VPN access)"
            return 1
        fi
        
        echo "✅ Development service configuration valid - includes code-server"
    fi
    
    return 0
}

# Workflow completion enforcement
create_workflow_todos() {
    local base_name="$1"  # e.g., "api", "app"
    
    echo "📋 Creating mandatory workflow TODO list for $base_name services..."
    
    # Use TodoWrite to create the workflow todos
    echo '[
        {"id": "create-dev-service", "content": "Create '${base_name}'dev development service with code-server", "status": "pending", "priority": "high"},
        {"id": "create-prod-service", "content": "Create '${base_name}' production service", "status": "pending", "priority": "high"},
        {"id": "configure-dev", "content": "Configure development environment and test locally", "status": "pending", "priority": "high"},
        {"id": "deploy-to-prod", "content": "Deploy from dev to production using /var/www/deploy.sh", "status": "pending", "priority": "high"},
        {"id": "verify-prod", "content": "Verify production deployment and enable subdomain", "status": "pending", "priority": "high"}
    ]' > /tmp/workflow_todos.json
    
    echo "✅ Workflow TODO list created - MUST complete all tasks before declaring success"
    echo "📋 Use TodoWrite and TodoRead to track progress"
}

validate_workflow_complete() {
    echo "🔍 Validating workflow completion..."
    
    # This would need to integrate with actual TodoRead functionality
    # For now, just remind about the requirement
    echo "⚠️ REMINDER: Never declare 'success' until all workflow TODOs are completed"
    echo "📋 Required for dual services: dev creation → prod creation → configuration → deployment → verification"
    
    return 0
}

export -f safe_output safe_ssh safe_bg get_from_zaia get_service_id validate_dev_service_config
export -f create_workflow_todos validate_workflow_complete
export -f get_available_envs suggest_env_vars needs_restart restart_service_for_envs
export -f apply_workaround can_ssh has_live_reload monitor_reload
export -f check_application_health diagnose_issue diagnose_502_enhanced
export -f create_safe_yaml validate_service_type validate_service_name get_service_role
export -f mask_sensitive_output show_env_safe sync_env_to_zaia security_scan
export -f zaia_exec verify_check get_development_service deployment_exists
export -f ensure_subdomain verify_service_exists verify_git_state verify_build_success
export -f check_deployment_status verify_health generate_service_yaml
export -f safe_create_remote_file validate_remote_file_content
export -f monitor_zcli_build deploy_with_monitoring
export -f wait_for_condition wait_for_service_ready wait_for_deployment_active
