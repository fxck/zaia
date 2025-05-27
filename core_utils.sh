#!/bin/bash
set -e

# Output limiting wrapper
safe_output() {
    local max_lines="${1:-100}"
    local max_time="${2:-30}"
    shift 2
    timeout "$max_time" "$@" 2>&1 | head -n "$max_lines"
}

# Check if service allows SSH (runtime services only)
can_ssh() {
    local service="$1"
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
        postgresql|mysql|mariadb|mongodb|elasticsearch|clickhouse|kafka|keydb|valkey|redis|meilisearch|nats|rabbitmq|seaweedfs|typesense|qdrant)
            return 1
            ;;
        objectstorage|object-storage|sharedstorage|shared-storage)
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

    safe_output "$max_lines" "$max_time" ssh -o ConnectTimeout=10 "zerops@$service" "$command"
}

# Mask sensitive environment variables
mask_sensitive_output() {
    local input="$1"
    echo "$input" | sed -E 's/(PASSWORD|SECRET|KEY|TOKEN|PRIVATE)=([^ ]+)/\1=***MASKED***/gi'
}

# Safe environment variable display
show_env_safe() {
    local service="$1"
    echo "🔒 Environment variables (sensitive values masked):"
    safe_ssh "$service" "env | sort" 50 10 | mask_sensitive_output
}

# Safe backgrounding pattern
safe_bg() {
    local service="$1"
    local start_cmd="$2"
    local work_dir="${3:-/var/www}"

    if ! can_ssh "$service"; then
        echo "❌ Cannot start process on $service (managed service)" >&2
        return 1
    fi

    echo "🚀 Starting $start_cmd on $service..."
    if timeout 15 ssh "zerops@$service" "cd $work_dir && nohup $start_cmd > app.log 2>&1 < /dev/null &"; then
        echo "✅ Command sent"
    else
        echo "⚠️ Timeout (expected for backgrounding)"
    fi

    sleep 5
    if safe_ssh "$service" "pgrep -f '$start_cmd' >/dev/null && echo 'RUNNING' || echo 'FAILED'" | grep -q "RUNNING"; then
        echo "✅ Process confirmed running"
        return 0
    else
        echo "❌ Process failed to start"
        safe_ssh "$service" "tail -20 app.log"
        return 1
    fi
}

# Get from .zaia only
get_from_zaia() {
    local path="$1"
    [ ! -f /var/www/.zaia ] && echo "FATAL: .zaia missing" >&2 && exit 1
    jq -r "$path" /var/www/.zaia 2>/dev/null || (echo "Path not found: $path" >&2 && exit 1)
}

# Service ID helper
get_service_id() {
    local service="$1"
    local id=$(get_from_zaia ".services[\"$service\"].id // \"\"")
    [ -z "$id" ] || [ "$id" = "ID_NOT_FOUND" ] && echo "Service ID not found" >&2 && exit 1
    echo "$id"
}

# Environment variable helpers
get_available_envs() {
    local service="$1"
    echo "=== ENVIRONMENT VARIABLES FOR $service ==="
    echo "🔗 SERVICE-PROVIDED:"
    get_from_zaia ".services[\"$service\"].serviceProvidedEnvs[]? // empty" | sed 's/^/  /'
    echo "⚙️ SELF-DEFINED:"
    get_from_zaia ".services[\"$service\"].selfDefinedEnvs | to_entries[]? | \"  \\(.key): \\(.value)\""
    echo ""
    echo "🔒 Note: Never hardcode sensitive values like passwords or API keys"
}

needs_restart() {
    local service="$1"
    local other="$2"
    local yml=$(get_from_zaia ".services[\"$service\"].actualZeropsYml // \"\"")
    [[ "$yml" == *"\$$other"* ]] && echo "true" || echo "false"
}

# Restart service for environment variables
restart_service_for_envs() {
    local service="$1"
    local reason="$2"
    local service_id=$(get_service_id "$service")

    echo "🔄 Restarting $service: $reason"
    zcli service stop --serviceId "$service_id"
    sleep 5
    zcli service start --serviceId "$service_id"
    sleep 10
    echo "✅ $service restarted - new environment variables now accessible"
}

# StartWithoutCode workaround
apply_workaround() {
    local service="$1"
    local retries=3

    if ! can_ssh "$service"; then
        echo "⚠️ Workaround not needed for managed service $service"
        return 0
    fi

    echo "🔧 Applying StartWithoutCode workaround..."
    for i in $(seq 1 $retries); do
        if timeout 15 ssh "zerops@$service" "zsc setSecretEnv foo bar" 2>/dev/null; then
            echo "✅ Workaround applied"
            return 0
        fi
        echo "⚠️ Retry $i/$retries..."
        sleep 10
    done
    echo "❌ Workaround failed - run manually: ssh zerops@$service 'zsc setSecretEnv foo bar'"
    return 1
}

# Check if service has live reload
has_live_reload() {
    local service="$1"

    if ! can_ssh "$service"; then
        echo "false"
        return
    fi

    if safe_ssh "$service" "ps aux | grep -E 'webpack-dev-server|vite|next dev|react-scripts start|vue-cli-service serve|ng serve|nodemon|ts-node-dev'" 1 5 | grep -q .; then
        echo "true"
    else
        echo "false"
    fi
}

# Monitor live reload
monitor_reload() {
    local service="$1"
    local files_changed="$2"

    if ! can_ssh "$service"; then
        return 1
    fi

    echo "📝 Changed: $files_changed"
    echo "⏳ Waiting for hot reload..."

    sleep 2

    if safe_ssh "$service" "tail -30 app.log" 50 10 | grep -iE "compiled|rebuilt|hmr|hot.module.replacement|reloading|✓|success|watching"; then
        echo "✅ Hot reload successful"

        if safe_ssh "$service" "tail -50 app.log" 50 10 | grep -iE "error|fail|exception" | grep -v "ErrorBoundary"; then
            echo "⚠️ Errors detected after reload:"
            safe_ssh "$service" "tail -50 app.log | grep -iE 'error|fail|exception'" 20 5
        fi
    else
        echo "⚠️ No reload confirmation found"
    fi
}

# Enhanced 502 diagnosis
diagnose_502_enhanced() {
    local service="$1"
    local port="${2:-3000}"
    local public_url="${3:-}"

    echo "=== ENHANCED 502 DIAGNOSIS ==="

    if ! can_ssh "$service"; then
        echo "❌ Cannot diagnose managed service $service via SSH"
        echo "Check service configuration in zerops.yml"
        return 1
    fi

    # 1. Check runtime errors FIRST
    echo "1️⃣ Checking for runtime errors..."
    if safe_ssh "$service" "tail -200 app.log" 200 10 | grep -iE "error|exception|crash|fatal" | grep -v "ErrorBoundary"; then
        echo "❌ RUNTIME ERRORS FOUND (most likely cause)"
        safe_ssh "$service" "tail -200 app.log | grep -iE 'error|exception|crash|fatal' -A 2 -B 2" 50 10
        return
    fi

    # 2. Check if process is running
    echo "2️⃣ Checking process..."
    if ! safe_ssh "$service" "pgrep -f 'node|python|ruby|php|java|go|rust'" 1 5 | grep -q .; then
        echo "❌ NO PROCESS RUNNING"
        echo "Last logs before crash:"
        safe_ssh "$service" "tail -50 app.log" 50 10
        return
    fi

    # 3. Check binding
    echo "3️⃣ Checking binding..."
    if curl -sf "http://$service:$port/" >/dev/null; then
        echo "✅ Local access works"
        echo "❌ BINDING ISSUE - app must bind to 0.0.0.0"
        safe_ssh "$service" "netstat -tln | grep :$port" 5 5
    else
        echo "❌ Local access failed - app not responding on port $port"
    fi

    # 4. For web apps, check frontend
    if [ -n "$public_url" ]; then
        echo "4️⃣ Checking frontend..."
        /var/www/diagnose_frontend.sh "$public_url" --check-console --check-network || true
    fi
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
        echo "Similar types available:" >&2
        local base_type=$(echo "$type" | cut -d@ -f1)
        grep -F "\"$base_type" /var/www/technologies.json | head -5 | sed 's/^/  /' >&2
        exit 1
    fi
}

# Validation
validate_service_name() {
    [[ "$1" =~ ^[a-z0-9]+$ ]] && [[ ${#1} -le 25 ]] || (echo "Invalid name: $1" >&2 && return 1)
}

# Determine service role from type
get_service_role() {
    local hostname="$1"
    local type="$2"
    local base_type=$(echo "$type" | cut -d@ -f1)

    if [[ "$hostname" == *dev ]]; then
        echo "development"
    elif [[ "$base_type" =~ ^(postgresql|mariadb|mongodb|mysql|elasticsearch|clickhouse|kafka) ]]; then
        echo "database"
    elif [[ "$base_type" =~ ^(redis|keydb|valkey|memcached) ]]; then
        echo "cache"
    elif [[ "$base_type" =~ ^(objectstorage|object-storage|sharedstorage|shared-storage) ]]; then
        echo "storage"
    else
        echo "stage"
    fi
}

# Export all functions
export -f safe_output safe_ssh safe_bg get_from_zaia get_service_id get_available_envs needs_restart
export -f apply_workaround validate_service_name can_ssh has_live_reload monitor_reload
export -f diagnose_502_enhanced get_service_role validate_service_type restart_service_for_envs
export -f mask_sensitive_output show_env_safe
