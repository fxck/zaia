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
        
        # Check for temp file usage (violation of direct creation rule)
        if echo "$content" | grep -q "cat /tmp/"; then
            echo "❌ ARCHITECTURE VIOLATION: Using temp file + cat pattern"
            echo "📋 REQUIRED: Use heredoc directly with safe_create_remote_file"
            echo "❌ WRONG: cat /tmp/file.yml"
            echo "✅ CORRECT: safe_create_remote_file \"service\" \"/var/www/zerops.yml\" \"\$(cat << 'EOF' ...)"
            return 1
        fi
        
        if ! validate_dev_service_config "$content" "$service"; then
            echo "❌ DEPLOYMENT BLOCKED: Development service configuration invalid"
            echo "📋 Use template from .goosehints with mandatory code-server setup"
            return 1
        fi
        
        # Check if basic application structure exists before deploying zerops.yml
        if echo "$content" | grep -q "npm install"; then
            echo "🔍 Checking if package.json exists before deploying..."
            if ! safe_ssh "$service" "test -f /var/www/package.json" 2>/dev/null; then
                echo "❌ DEPLOYMENT BLOCKED: Missing package.json"
                echo "📋 REQUIRED: Create package.json and basic app structure BEFORE deploying zerops.yml"
                echo "💡 Run: safe_ssh \"$service\" \"cd /var/www && npm init -y\""
                return 1
            fi
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

# Monitor build status with active polling - NEVER ASSUME SUCCESS
monitor_zcli_build() {
    local build_output="$1"

    # Check if the output indicates success/failure directly
    if echo "$build_output" | grep -q "successfully\|DEPLOYED"; then
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
        echo "❌ CRITICAL: Cannot extract build ID from output" >&2
        echo "Build output was: $build_output" >&2
        echo "This indicates a platform issue or unexpected output format" >&2
        return 1  # FAIL - never assume success
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

# Deploy service to itself with unique tracking
# USE FOR: Config activation, environment variable updates, zerops.yml changes
deploy_self() {
    local service="$1"
    
    echo "🔄 Deploying $service to itself (activating configuration changes)..."
    
    local service_id=$(get_service_id "$service")
    echo "📋 Service ID: $service_id"
    
    # Create truly unique version with microseconds + random
    local version_name="deploy-$(date +%Y%m%d-%H%M%S)-$(date +%N | cut -c1-3)-$(shuf -i 1000-9999 -n1)"
    echo "📋 Unique version: $version_name"
    
    # Execute deployment with version tracking
    if safe_ssh "$service" "cd /var/www && zcli login '$ZEROPS_ACCESS_TOKEN' >/dev/null 2>&1 && zcli push --serviceId '$service_id' --deploy-git-folder --version-name '$version_name'"; then
        echo "✅ Self-deployment command completed successfully"
        
        # MANDATORY: Wait for THIS SPECIFIC version to be active
        echo "⏳ Waiting for version $version_name to be fully active..."
        if wait_for_version_active "$service_id" "$version_name"; then
            echo "✅ Version $version_name is now active and ready"
            return 0
        else
            echo "❌ Version $version_name failed to become active"
            return 1
        fi
    else
        echo "❌ Self-deployment command failed"
        return 1
    fi
}

# Wrapper for deployment with unique tracking and monitoring
# USE FOR: Dev→Stage deployment (different services)
deploy_with_monitoring() {
    local dev_service="$1"
    local stage_id="$2"

    echo "🚀 Deploying from $dev_service to $stage_id..."

    # Create truly unique version with microseconds + random
    local version_name="deploy-$(date +%Y%m%d-%H%M%S)-$(date +%N | cut -c1-3)-$(shuf -i 1000-9999 -n1)"
    echo "📋 Unique version: $version_name"

    # Execute deployment with explicit version tracking
    if safe_ssh "$dev_service" "cd /var/www && zcli login '$ZEROPS_ACCESS_TOKEN' >/dev/null 2>&1 && zcli push --serviceId '$stage_id' --deploy-git-folder --version-name '$version_name'"; then
        echo "✅ Deployment command sent with version: $version_name"
        
        # MANDATORY: Wait for THIS SPECIFIC version to be active
        echo "⏳ Waiting for version $version_name to be fully active..."
        if wait_for_version_active "$stage_id" "$version_name"; then
            echo "✅ Version $version_name confirmed active and ready"
            return 0
        else
            echo "❌ Version $version_name failed to become active"
            return 1
        fi
    else
        echo "❌ Deployment command failed"
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

# Check if service is currently building/deploying
is_service_building() {
    local service_id="$1"
    
    # Check build logs to see if build is active
    local build_logs=$(zcli service log --serviceId "$service_id" --show-build-logs --limit 10 --format SHORT 2>/dev/null || echo "")
    
    if [ -z "$build_logs" ]; then
        return 1  # No build logs = not building
    fi
    
    # Look for recent build activity (within last few lines)
    # Active builds typically show ongoing progress, completion messages, or recent timestamps
    local recent_activity=$(echo "$build_logs" | tail -3 | grep -E "(Building|Deploying|Downloading|Installing|Running|Copying|Step [0-9]+|DEPLOYED|FAILED)" || echo "")
    
    if [ -n "$recent_activity" ]; then
        # Check if the recent activity indicates completion or ongoing work
        if echo "$recent_activity" | grep -qE "(DEPLOYED|BUILD FAILED|DEPLOYMENT FAILED)"; then
            return 1  # Build completed (success or failure)
        else
            echo "🔄 Build activity detected:"
            echo "$recent_activity" | sed 's/^/  /'
            return 0  # Still building
        fi
    else
        return 1  # No recent build activity
    fi
}

# Wait for specific version to become active using REST API
wait_for_version_active() {
    local service_id="$1"
    local expected_version="$2"
    
    echo "⏳ Waiting for version '$expected_version' to become active..."
    
    local max_wait=600  # 10 minutes total (build + container startup)
    local elapsed=0
    local api_url="https://api.app-prg1.zerops.io/api/rest/public/service-stack/$service_id"
    
    while [ $elapsed -lt $max_wait ]; do
        # Query the service stack API
        local response=$(curl -sf -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" "$api_url" 2>/dev/null || echo '{}')
        
        if [ -n "$response" ] && [ "$response" != '{}' ]; then
            # Extract current status and active version name
            local status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown") 
            local active_version_name=$(echo "$response" | jq -r '.activeAppVersion.name // "none"' 2>/dev/null || echo "none")
            local version_number=$(echo "$response" | jq -r '.versionNumber // "unknown"' 2>/dev/null || echo "unknown")
            
            # Debug: Show what we're comparing
            if [ $elapsed -eq 0 ]; then
                echo "🔍 Looking for version: '$expected_version'"
                echo "📍 Current active version: '$active_version_name'"
            fi
            
            echo "📍 Status: $status, Active Version Name: $active_version_name, Version Number: $version_number (${elapsed}s elapsed)"
            
            # Check if our specific version name is active
            if [ "$active_version_name" = "$expected_version" ] && [ "$status" = "READY" ]; then
                echo "✅ Version '$expected_version' is now active and ready"
                return 0
            elif [ "$active_version_name" = "$expected_version" ] && [ "$status" = "RUNNING" ]; then
                echo "✅ Version '$expected_version' is running and active"
                return 0
            elif [ "$status" = "FAILED" ] || [ "$status" = "ERROR" ]; then
                echo "❌ Deployment failed with status: $status"
                return 1
            else
                # Still building/deploying or version doesn't match yet
                if [ "$active_version_name" != "none" ] && [ "$active_version_name" != "$expected_version" ]; then
                    echo "⏳ Different version active: $active_version_name (waiting for $expected_version)"
                fi
                printf "."
            fi
        else
            echo "⚠️ Failed to query service API"
            printf "."
        fi
        
        sleep 15
        elapsed=$((elapsed + 15))
    done
    
    echo ""
    echo "⚠️ Timeout after ${max_wait}s waiting for version '$expected_version'"
    echo "📋 Final service state:"
    
    # Show final state for debugging
    local final_response=$(curl -sf -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" "$api_url" 2>/dev/null || echo '{}')
    if [ -n "$final_response" ] && [ "$final_response" != '{}' ]; then
        local final_active_name=$(echo "$final_response" | jq -r '.activeAppVersion.name // "unknown"' 2>/dev/null || echo "unknown")
        local final_status=$(echo "$final_response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        local final_version_number=$(echo "$final_response" | jq -r '.versionNumber // "unknown"' 2>/dev/null || echo "unknown")
        echo "  Active Version Name: $final_active_name"
        echo "  Version Number: $final_version_number"
        echo "  Status: $final_status"
    else
        echo "  Unable to query final state"
    fi
    
    return 1
}

# Legacy function - kept for compatibility
wait_for_deployment_active() {
    local service_id="$1"
    
    echo "⏳ Waiting for deployment to be active (using legacy method)..."
    
    # First check if there are active builds using build logs
    if is_service_building "$service_id"; then
        echo "📋 Build/deployment in progress, waiting for completion..."
        
        local max_wait=600  # 10 minutes for builds
        local elapsed=0
        
        while [ $elapsed -lt $max_wait ]; do
            if ! is_service_building "$service_id"; then
                echo ""
                echo "✅ Build/deployment completed"
                break
            fi
            
            printf "."
            sleep 15
            elapsed=$((elapsed + 15))
        done
        
        if [ $elapsed -ge $max_wait ]; then
            echo ""
            echo "⚠️ Build timeout after ${max_wait}s"
            return 1
        fi
    fi
    
    # Now verify service is responsive by checking if we can get runtime logs
    echo "🔍 Verifying service is active..."
    local max_wait=60  # 1 minute for service activation
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        # Try to get runtime logs (not build logs) - this indicates service is active
        if zcli service log --serviceId "$service_id" --limit 1 >/dev/null 2>&1; then
            echo "✅ Service is active and responding"
            return 0
        fi
        
        printf "."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    echo ""
    echo "⚠️ Service not responding after ${max_wait}s"
    echo "📋 Checking build logs for issues..."
    
    # Show recent build logs to help debug
    local build_logs=$(zcli service log --serviceId "$service_id" --show-build-logs --limit 20 --format SHORT 2>/dev/null || echo "")
    if [ -n "$build_logs" ]; then
        echo "Recent build activity:"
        echo "$build_logs" | tail -10 | sed 's/^/  /'
    else
        echo "No build logs available"
    fi
    
    return 1
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
    
    echo "🌐 Processing subdomain for $service..."
    
    # First check if service exists and get ID
    if ! verify_service_exists "$service"; then
        echo "❌ Service $service not found in project state"
        return 1
    fi
    
    local service_id=$(get_service_id "$service")
    echo "📋 Service ID: $service_id"
    
    # Check if subdomain already exists
    sync_env_to_zaia
    local existing_subdomain=$(get_from_zaia ".services[\"$service\"].subdomain" 2>/dev/null | tr -d '"')
    
    if [ -n "$existing_subdomain" ] && [ "$existing_subdomain" != "null" ]; then
        echo "✅ Subdomain already exists: $existing_subdomain"
        return 0
    fi
    
    echo "🔧 Enabling subdomain for $service (ID: $service_id)..."
    
    # Enable subdomain with error handling
    if zcli service enable-subdomain --serviceId "$service_id" 2>&1; then
        echo "✅ Subdomain enable command succeeded"
        
        # Wait for subdomain to be provisioned
        echo "⏳ Waiting for subdomain provisioning..."
        sleep 10
        
        # Refresh state and check
        sync_env_to_zaia
        local new_subdomain=$(get_from_zaia ".services[\"$service\"].subdomain" 2>/dev/null | tr -d '"')
        
        if [ -n "$new_subdomain" ] && [ "$new_subdomain" != "null" ]; then
            echo "✅ Subdomain provisioned: $new_subdomain"
            return 0
        else
            echo "⚠️ Subdomain command succeeded but subdomain not yet visible"
            echo "   This may take a few minutes to propagate"
            return 0
        fi
    else
        local exit_code=$?
        echo "❌ Failed to enable subdomain (exit code: $exit_code)"
        echo ""
        echo "📋 Debugging info:"
        echo "   Service: $service"
        echo "   Service ID: $service_id"
        echo "   Command: zcli service enable-subdomain --serviceId $service_id"
        echo ""
        echo "💡 Try manually:"
        echo "   zcli service enable-subdomain --serviceId $service_id"
        echo "   zcli service list | grep $service"
        return 1
    fi
}

# Ensure subdomain is enabled AND actually working
ensure_subdomain_verified() {
    local service="$1"
    
    echo "🔍 Enabling and verifying subdomain for $service..."
    
    # First, enable the subdomain
    if ! ensure_subdomain "$service"; then
        echo "❌ Failed to enable subdomain"
        return 1
    fi
    
    # Wait a moment for DNS propagation
    echo "⏳ Waiting for DNS propagation..."
    sleep 10
    
    # Get the subdomain URL
    sync_env_to_zaia
    local subdomain=$(get_from_zaia ".services[\"$service\"].subdomain" 2>/dev/null | tr -d '"')
    
    if [ -z "$subdomain" ] || [ "$subdomain" = "null" ]; then
        echo "❌ Subdomain not found in project state"
        return 1
    fi
    
    local public_url="https://$subdomain"
    echo "🌐 Testing subdomain: $public_url"
    
    # Test if subdomain actually responds (try multiple times)
    local max_attempts=6
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "🔄 Attempt $attempt/$max_attempts: Testing $public_url"
        
        if curl -sf -m 10 "$public_url" >/dev/null 2>&1; then
            echo "✅ Subdomain verified and responding!"
            echo "🌐 Public URL: $public_url"
            return 0
        elif curl -sf -m 10 "$public_url/health" >/dev/null 2>&1; then
            echo "✅ Subdomain verified via health endpoint!"
            echo "🌐 Public URL: $public_url"
            return 0
        else
            echo "⚠️ Subdomain not responding yet (attempt $attempt/$max_attempts)"
            if [ $attempt -lt $max_attempts ]; then
                echo "⏳ Waiting 15 seconds before retry..."
                sleep 15
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo "❌ Subdomain enabled but not responding after $max_attempts attempts"
    echo "📋 Possible issues:"
    echo "   - Application not running on the service"
    echo "   - Port configuration incorrect (should be port 3000 with httpSupport: true)"
    echo "   - Service still starting up"
    echo "   - DNS propagation delay"
    echo ""
    echo "💡 Try manually:"
    echo "   curl -v $public_url"
    echo "   Check if app is running: safe_ssh $service 'ps aux | grep node'"
    
    return 1
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

# Direct SSH without output limiting (for simple commands like curl)
direct_ssh() {
    local service="$1"
    local command="$2"
    local max_time="${3:-30}"

    if ! can_ssh "$service"; then
        echo "❌ SSH not available for $service (managed service)" >&2
        return 1
    fi

    timeout "$max_time" ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "zerops@$service" "$command"
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

    # For curl commands, use direct SSH to avoid pipe issues
    if [[ "$command" == *"curl"* ]]; then
        direct_ssh "$service" "$command" "$max_time"
    else
        safe_output "$max_lines" "$max_time" \
            ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no \
            "zerops@$service" "$command"
    fi
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

# Process management with proper verification and clean slate
start_application_properly() {
    local service="$1"
    local start_cmd="$2"
    local port="$3"
    local work_dir="${4:-/var/www}"

    echo "🚀 Starting application with proper verification..."

    if ! can_ssh "$service"; then
        echo "❌ Cannot start process on $service (managed service)" >&2
        return 1
    fi

    # 1. Clean slate - kill any existing processes
    safe_ssh "$service" "pkill -f '$start_cmd' || true" 5 5
    sleep 2

    # 2. Start with background monitoring
    echo "🚀 Starting: $start_cmd"
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

    # 3. Wait for startup with specific checks
    local attempts=0
    while [ $attempts -lt 12 ]; do  # 60 seconds total
        if check_specific_application "$service" "$start_cmd" "$port"; then
            echo "✅ Application started and verified"
            return 0
        fi
        
        echo "⏳ Waiting for application startup... (attempt $((attempts + 1))/12)"
        sleep 5
        attempts=$((attempts + 1))
    done
    
    echo "❌ Application failed to start properly"
    echo "📋 Diagnostics:"
    safe_ssh "$service" "ps aux | grep -v grep" 10 5
    safe_ssh "$service" "ss -tlnp" 10 5
    safe_ssh "$service" "tail -50 $work_dir/app.log" 50 5
    return 1
}

# Multi-signal deployment verification
verify_deployment_complete() {
    local service="$1"
    local expected_version="$2"
    local expected_cmd="$3"
    local expected_port="$4"
    
    echo "🔍 Multi-signal deployment verification..."
    
    if ! can_ssh "$service"; then
        echo "⚠️ Cannot verify managed service via SSH - using API only"
        # For managed services, just check API
        local service_id=$(get_service_id "$service")
        local api_url="https://api.app-prg1.zerops.io/api/rest/public/service-stack/$service_id"
        local response=$(curl -sf -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" "$api_url" 2>/dev/null || echo '{}')
        
        if [ -n "$response" ] && [ "$response" != '{}' ]; then
            local active_version_name=$(echo "$response" | jq -r '.activeAppVersion.name // "unknown"' 2>/dev/null || echo "unknown")
            local status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
            
            if [ "$active_version_name" = "$expected_version" ] && [[ "$status" =~ ^(READY|RUNNING)$ ]]; then
                echo "✅ Managed service deployment verified via API"
                return 0
            fi
        fi
        echo "❌ Managed service verification failed"
        return 1
    fi
    
    # Signal 1: Build logs show successful completion
    if ! zcli service log "$service" --show-build-logs --limit 10 2>/dev/null | grep -q "DEPLOYED\\|SUCCESS"; then
        echo "❌ Build logs don't show successful deployment"
        return 1
    fi
    
    # Signal 2: Specific application process is running (if cmd and port provided)
    if [ -n "$expected_cmd" ] && [ -n "$expected_port" ]; then
        if ! check_specific_application "$service" "$expected_cmd" "$expected_port"; then
            echo "❌ Application health check failed"
            return 1
        fi
    fi
    
    # Signal 3: Recent log activity (not stale)
    local last_log_time=$(zcli service log "$service" --limit 1 --format JSON 2>/dev/null | jq -r '.[0].timestamp // empty' 2>/dev/null || echo "")
    if [ -n "$last_log_time" ]; then
        local log_age=$(( $(date +%s) - $(date -d "$last_log_time" +%s 2>/dev/null || echo 0) ))
        if [ $log_age -gt 300 ]; then  # 5 minutes
            echo "⚠️ Last log is $log_age seconds old - might be stale"
        fi
    fi
    
    echo "✅ All signals confirm successful deployment"
    return 0
}

# Safe backgrounding pattern with verification (legacy - use start_application_properly)
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

    # Verify separately with improved process detection
    echo "⏳ Waiting for process to start..."
    sleep 5

    # Try multiple detection methods
    local process_found=false
    
    # Method 1: Check for exact pattern
    if safe_ssh "$service" "pgrep -f '$process_pattern'" 1 5 >/dev/null 2>&1; then
        process_found=true
    # Method 2: Check for start command
    elif safe_ssh "$service" "pgrep -f '$start_cmd'" 1 5 >/dev/null 2>&1; then
        process_found=true
    # Method 3: Check for any node process if it's a node app
    elif [[ "$start_cmd" == *"node"* ]] && safe_ssh "$service" "pgrep node" 1 5 >/dev/null 2>&1; then
        process_found=true
    fi
    
    if [ "$process_found" = true ]; then
        echo "✅ Process confirmed running"
        
        # Show process details
        echo ""
        echo "📋 Running processes:"
        safe_ssh "$service" "ps aux | grep -E '$process_pattern|$start_cmd' | grep -v grep" 5 5 || true
        
        # Show initial logs
        echo ""
        echo "📋 Initial logs:"
        safe_ssh "$service" "tail -20 $work_dir/app.log 2>/dev/null | grep -v '^$'" 20 5 || echo "No logs yet"
        return 0
    else
        echo "❌ Process failed to start"
        echo ""
        echo "📋 Process check details:"
        echo "  Pattern: '$process_pattern'"
        echo "  Start command: '$start_cmd'"
        safe_ssh "$service" "ps aux | grep -v grep | grep -v ssh" 10 5 || true
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
    echo "  APP_PORT: 3000          # Use APP_PORT, never PORT (reserved)"
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
        if timeout 5 ssh -o ConnectTimeout=5 "zerops@$service" "zsc setSecretEnv foo bar" 2>/dev/null; then
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

# Specific application verification with multi-signal correlation
check_specific_application() {
    local service="$1"
    local expected_cmd="$2"    # e.g., "node index.js"
    local expected_port="$3"   # e.g., 3000

    echo "🔍 Checking specific application: $expected_cmd on port $expected_port"

    if ! can_ssh "$service"; then
        echo "❌ Cannot check managed service"
        return 1
    fi

    # 1. Find exact process
    local pid=$(safe_ssh "$service" "pgrep -f '$expected_cmd'" 1 5 2>/dev/null | head -1)
    if [ -z "$pid" ]; then
        echo "❌ Process not found: $expected_cmd"
        return 1
    fi

    # 2. Verify process is actually that command
    local actual_cmd=$(safe_ssh "$service" "ps -p $pid -o cmd --no-headers" 1 5 2>/dev/null)
    if [[ "$actual_cmd" != *"$expected_cmd"* ]]; then
        echo "❌ Process mismatch. Expected: $expected_cmd, Found: $actual_cmd"
        return 1
    fi

    # 3. Verify port binding by this specific process
    local port_owner=$(safe_ssh "$service" "ss -tlnp | grep :$expected_port | grep -o 'pid=[0-9]*' | cut -d= -f2" 1 5 2>/dev/null | head -1)
    if [ -n "$port_owner" ] && [ "$port_owner" != "$pid" ]; then
        echo "❌ Port $expected_port not owned by process $pid (owner: $port_owner)"
        return 1
    fi

    # 4. Test actual HTTP response
    if safe_ssh "$service" "curl -sf -m 5 http://localhost:$expected_port/" 1 5 >/dev/null 2>&1; then
        echo "✅ Application verified: PID $pid, Port $expected_port, HTTP responding"
        return 0
    else
        echo "❌ Process running but HTTP not responding on port $expected_port"
        return 1
    fi
}

# Application health check (legacy - use check_specific_application for better results)
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
        
        # CRITICAL: Check for PORT environment variable (reserved, causes conflicts)
        if echo "$config" | grep -q "PORT:"; then
            echo "❌ ARCHITECTURE VIOLATION: PORT environment variable is reserved"
            echo "📋 PROBLEM: PORT conflicts with code-server and platform routing"
            echo "🚫 NEVER USE: PORT environment variable"
            echo "✅ USE INSTEAD: APP_PORT environment variable"
            echo "💡 PATTERN: process.env.APP_PORT || 3000"
            return 1
        fi
        
        # Check that both ports are defined (8080 for code-server, 3000 for app)
        if ! echo "$config" | grep -q "port: 3000"; then
            echo "❌ ARCHITECTURE VIOLATION: Missing port 3000 for application"
            echo "📋 REQUIRED: Port 3000 for application (public access)"
            return 1
        fi
        
        echo "✅ Development service configuration valid - includes code-server with proper port isolation"
    fi
    
    return 0
}

# Workflow completion enforcement - technology agnostic
create_workflow_todos() {
    local base_name="$1"    # e.g., "api", "app", "web"
    local tech_stack="$2"   # e.g., "nodejs", "python", "php", "ruby", "go"
    local description="$3"  # e.g., "blog app", "REST API", "web service"
    
    # Default values if not provided
    base_name="${base_name:-app}"
    tech_stack="${tech_stack:-detected}"
    description="${description:-application}"
    
    echo "📋 Creating mandatory workflow TODO list for $tech_stack $description..."
    
    # Technology-agnostic workflow todos
    echo '[
        {"id": "create-dev-service", "content": "Create '${base_name}'dev development service with code-server for '${tech_stack}' stack", "status": "pending", "priority": "high"},
        {"id": "create-prod-service", "content": "Create '${base_name}' production service for '${tech_stack}' deployment", "status": "pending", "priority": "high"},
        {"id": "setup-application", "content": "Create '${description}' with '${tech_stack}' dependencies and configuration", "status": "pending", "priority": "high"},
        {"id": "configure-dev", "content": "Configure development environment and test '${description}' locally", "status": "pending", "priority": "high"},
        {"id": "deploy-to-prod", "content": "Deploy '${description}' from dev to production using /var/www/deploy.sh", "status": "pending", "priority": "high"},
        {"id": "verify-prod", "content": "Verify production deployment of '${description}' and enable public access", "status": "pending", "priority": "high"}
    ]' > /tmp/workflow_todos.json
    
    echo "✅ Workflow TODO list created for $tech_stack $description"
    echo "📋 MUST complete all tasks before declaring success"
    echo "🔧 Supports any Zerops technology stack"
}

validate_workflow_complete() {
    echo "🔍 Validating dev→stage workflow completion..."
    
    # Check for proper service pairing
    local dev_services=$(get_from_zaia '.services | to_entries[] | select(.value.role == "development") | .key')
    local stage_services=$(get_from_zaia '.services | to_entries[] | select(.value.role != "development" and .value.role != "database" and .value.role != "cache" and .value.role != "storage") | .key')
    
    if [ -z "$dev_services" ]; then
        echo "❌ WORKFLOW INCOMPLETE: No development services found"
        echo "📋 REQUIRED: Create development service ({name}dev) with code-server"
        return 1
    fi
    
    if [ -z "$stage_services" ]; then
        echo "❌ WORKFLOW INCOMPLETE: No stage services found"
        echo "📋 REQUIRED: Create stage service ({name}) for production deployment"
        echo "💡 Run: /var/www/deploy.sh <dev-service>"
        return 1
    fi
    
    # Verify dev/stage pairing exists
    local has_valid_pair=false
    for dev_service in $dev_services; do
        local base_name="${dev_service%dev}"  # Remove 'dev' suffix
        if echo "$stage_services" | grep -q "^${base_name}$"; then
            has_valid_pair=true
            break
        fi
    done
    
    if [ "$has_valid_pair" = false ]; then
        echo "❌ WORKFLOW INCOMPLETE: No valid dev/stage pairs found"
        echo "📋 REQUIRED: Ensure {name}dev + {name} service pairing"
        echo "   Example: blogdev + blog, apidev + api, shopdev + shop"
        return 1
    fi
    
    # Check if stage services have public access (indicating successful deployment)
    local has_stage_deployment=false
    for service in $stage_services; do
        local subdomain=$(get_from_zaia ".services[\"$service\"].subdomain // \"\"")
        if [ -n "$subdomain" ] && [ "$subdomain" != "null" ]; then
            has_stage_deployment=true
            break
        fi
    done
    
    if [ "$has_stage_deployment" = false ]; then
        echo "❌ WORKFLOW INCOMPLETE: Stage services exist but not deployed"
        echo "📋 REQUIRED: Deploy to stage and enable public access"
        echo "💡 Run: /var/www/deploy.sh <dev-service>"
        return 1
    fi
    
    echo "✅ Workflow complete: Dev/stage pairing with successful deployment verified"
    return 0
}

# Detect premature success declaration
detect_premature_success() {
    local message="$1"
    
    # Check for "next steps" language indicating incomplete workflow
    if echo "$message" | grep -qi "next steps\|deploy to production\|run.*deploy\.sh"; then
        echo "❌ PREMATURE SUCCESS DETECTED"
        echo "📋 'Next Steps' language indicates incomplete workflow"
        echo "🚫 BLOCKED: Do not suggest production deployment as 'next step'"
        echo "✅ REQUIRED: Actually execute /var/www/deploy.sh and verify production"
        return 1
    fi
    
    return 0
}

# Auto-detect technology and description from user request
auto_create_workflow_todos() {
    local user_request="$1"
    local base_name="app"
    local tech_stack="detected"
    local description="application"
    
    # Detect technology stack from user request
    if echo "$user_request" | grep -qi "node\|javascript\|express\|npm"; then
        tech_stack="nodejs"
    elif echo "$user_request" | grep -qi "python\|django\|flask\|pip"; then
        tech_stack="python"
    elif echo "$user_request" | grep -qi "php\|laravel\|composer"; then
        tech_stack="php"
    elif echo "$user_request" | grep -qi "ruby\|rails\|gem"; then
        tech_stack="ruby"
    elif echo "$user_request" | grep -qi "go\|golang"; then
        tech_stack="go"
    elif echo "$user_request" | grep -qi "java\|spring\|maven"; then
        tech_stack="java"
    elif echo "$user_request" | grep -qi "rust\|cargo"; then
        tech_stack="rust"
    fi
    
    # Detect application type/description
    if echo "$user_request" | grep -qi "api\|rest\|endpoint"; then
        description="REST API"
        base_name="api"
    elif echo "$user_request" | grep -qi "blog\|cms"; then
        description="blog application"
        base_name="blog"
    elif echo "$user_request" | grep -qi "shop\|ecommerce\|store"; then
        description="e-commerce application"
        base_name="shop"
    elif echo "$user_request" | grep -qi "chat\|messaging"; then
        description="chat application"
        base_name="chat"
    elif echo "$user_request" | grep -qi "web\|website\|frontend"; then
        description="web application"
        base_name="web"
    elif echo "$user_request" | grep -qi "database\|crud"; then
        description="database application"
        base_name="app"
    fi
    
    echo "🤖 Auto-detected: $tech_stack $description (service: ${base_name}dev + $base_name)"
    create_workflow_todos "$base_name" "$tech_stack" "$description"
}

# Prevent premature actions during deployment
check_deployment_readiness() {
    local service="$1"
    local action_description="$2"
    
    echo "🔍 Checking if $service is ready for: $action_description"
    
    # Check if this is a development service that was recently deployed
    if echo "$service" | grep -q "dev"; then
        local service_id=$(get_service_id "$service")
        
        # Simple check - try to verify deployment is stable
        if ! wait_for_deployment_active "$service_id"; then
            echo "⚠️ DEPLOYMENT STILL IN PROGRESS"
            echo "📋 Cannot $action_description while deployment is active"
            echo "💡 Wait for deployment to complete before proceeding"
            return 1
        fi
    fi
    
    echo "✅ Service ready for: $action_description"
    return 0
}

export -f safe_output direct_ssh safe_ssh safe_bg get_from_zaia get_service_id validate_dev_service_config
export -f create_workflow_todos auto_create_workflow_todos validate_workflow_complete detect_premature_success
export -f check_deployment_readiness
export -f get_available_envs suggest_env_vars needs_restart restart_service_for_envs
export -f apply_workaround can_ssh has_live_reload monitor_reload
export -f check_application_health check_specific_application start_application_properly verify_deployment_complete
export -f diagnose_issue diagnose_502_enhanced
export -f create_safe_yaml validate_service_type validate_service_name get_service_role
export -f mask_sensitive_output show_env_safe sync_env_to_zaia security_scan
export -f zaia_exec verify_check get_development_service deployment_exists
export -f ensure_subdomain ensure_subdomain_verified verify_service_exists verify_git_state verify_build_success
export -f check_deployment_status verify_health generate_service_yaml
export -f safe_create_remote_file validate_remote_file_content
export -f monitor_zcli_build deploy_self deploy_with_monitoring
export -f wait_for_condition wait_for_service_ready is_service_building wait_for_version_active wait_for_deployment_active
