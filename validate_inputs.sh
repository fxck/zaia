#!/bin/bash

validate_service_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9]+$ ]] || [[ ${#name} -gt 25 ]]; then
        echo "❌ Invalid service name '$name'. Use lowercase letters and numbers only. Max 25 chars."
        return 1
    fi
    return 0
}

is_runtime_service() {
    local tech="$1"
    local base_tech=$(echo "$tech" | cut -d@ -f1)
    case "$base_tech" in
        "nodejs"|"php"|"python"|"go"|"rust"|"dotnet"|"java"|"bun"|"deno"|"gleam"|"elixir"|"ruby"|"static")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_managed_service() {
    local tech="$1"
    if is_runtime_service "$tech"; then
        return 1
    else
        return 0
    fi
}

# CLEAN: Apply Zerops startWithoutCode bug workaround
apply_startwithoutcode_workaround() {
    local service_name="$1"
    local max_retries="${2:-3}"
    local retry_count=0

    echo "🔧 Applying Zerops startWithoutCode bug workaround for $service_name..."

    while [ $retry_count -lt $max_retries ]; do
        if timeout 15 ssh -o ConnectTimeout=15 "zerops@$service_name" "zsc setSecretEnv foo bar" 2>/dev/null; then
            echo "✅ Bug workaround applied successfully for $service_name"
            return 0
        else
            retry_count=$((retry_count + 1))
            echo "⚠️  Retry $retry_count/$max_retries: Waiting for service $service_name to be ready..."
            sleep 15
        fi
    done

    echo "❌ WARNING: Failed to apply bug workaround for $service_name after $max_retries attempts"
    echo "   Run manually: timeout 15 ssh zerops@$service_name 'zsc setSecretEnv foo bar'"
    return 1
}

# CLEAN: Universal application health monitoring
check_application_health() {
    local service="$1"
    local port="${2:-3000}"
    local process_pattern="${3:-dev}"

    echo "=== APPLICATION HEALTH CHECK ==="

    # 1. Process Status
    if ssh zerops@$service "pgrep -f '$process_pattern'" >/dev/null; then
        echo "✅ Process running"
        local pids=$(ssh zerops@$service "pgrep -f '$process_pattern' | tr '\n' ' '")
        echo "   PIDs: $pids"
    else
        echo "❌ Process not running"
        return 1
    fi

    # 2. Port Status
    if ssh zerops@$service "netstat -tln | grep :$port" >/dev/null; then
        echo "✅ Port $port listening"
    else
        echo "❌ Port $port not listening"
    fi

    # 3. Log Analysis (last 20 lines)
    echo ""
    echo "📋 Recent logs:"
    local logs=$(ssh zerops@$service "tail -20 /var/www/app.log 2>/dev/null || echo 'No logs found'")
    echo "$logs"

    # 4. Error Detection
    if echo "$logs" | grep -i "error\|exception\|failed\|crash" >/dev/null; then
        echo ""
        echo "⚠️  ERRORS DETECTED in logs"
        echo "$logs" | grep -i "error\|exception\|failed\|crash"
    fi

    # 5. Endpoint Test (if port is standard HTTP port)
    if [[ "$port" =~ ^(80|443|3000|8000|8080|5000)$ ]]; then
        echo ""
        echo "🔗 Testing HTTP endpoint..."
        if curl -sf "http://$service:$port/health" >/dev/null 2>&1; then
            echo "✅ Health endpoint responding"
        elif curl -sf "http://$service:$port/" >/dev/null 2>&1; then
            echo "✅ Root endpoint responding"
        else
            echo "❌ HTTP endpoints not responding"
        fi
    fi
}

# CLEAN: Get service ID from .zaia ONLY - NO FALLBACKS
get_service_id() {
    local service_name="$1"

    if [ ! -f "/var/www/.zaia" ]; then
        echo "❌ FATAL: .zaia file not found. Run init_state.sh first" >&2
        exit 1
    fi

    if ! jq empty /var/www/.zaia 2>/dev/null; then
        echo "❌ FATAL: .zaia file is corrupted. Run init_state.sh" >&2
        exit 1
    fi

    local service_id=$(jq -r --arg svc "$service_name" '.services[$svc].id // ""' /var/www/.zaia 2>/dev/null)

    if [ -z "$service_id" ] || [ "$service_id" = "null" ] || [ "$service_id" = "ID_NOT_FOUND" ]; then
        echo "❌ Service ID not found for '$service_name' in .zaia" >&2
        echo "   Run sync_env_to_zaia.sh to update service IDs" >&2
        exit 1
    fi

    echo "$service_id"
    return 0
}

# CLEAN: Get service subdomain from .zaia ONLY - NO FALLBACKS
get_service_subdomain() {
    local service_name="$1"

    if [ ! -f "/var/www/.zaia" ]; then
        echo "❌ FATAL: .zaia file not found. Run init_state.sh first" >&2
        exit 1
    fi

    if ! jq empty /var/www/.zaia 2>/dev/null; then
        echo "❌ FATAL: .zaia file is corrupted. Run init_state.sh" >&2
        exit 1
    fi

    local subdomain=$(jq -r --arg svc "$service_name" '.services[$svc].subdomain // ""' /var/www/.zaia 2>/dev/null)

    if [ -z "$subdomain" ] || [ "$subdomain" = "null" ]; then
        echo "❌ Subdomain not found for '$service_name' in .zaia" >&2
        echo "   Run sync_env_to_zaia.sh to update subdomains" >&2
        return 1
    fi

    echo "$subdomain"
    return 0
}

# CLEAN: Get all available environment variables from .zaia ONLY
get_available_envs() {
    local service="$1"

    if [ ! -f /var/www/.zaia ]; then
        echo "❌ FATAL: .zaia file not found. Run init_state.sh first" >&2
        exit 1
    fi

    if ! jq empty /var/www/.zaia 2>/dev/null; then
        echo "❌ FATAL: .zaia file is corrupted. Run init_state.sh" >&2
        exit 1
    fi

    # Check if service exists
    if ! jq -e --arg svc "$service" '.services[$svc]' /var/www/.zaia >/dev/null 2>&1; then
        echo "❌ Service '$service' not found in .zaia" >&2
        echo "   Available services:" >&2
        jq -r '.services | keys[]' /var/www/.zaia | sed 's/^/     /' >&2
        exit 1
    fi

    echo "=== ENVIRONMENT VARIABLES FOR $service (.zaia ONLY) ==="
    echo ""
    echo "🔗 SERVICE-PROVIDED (from other services):"
    local service_provided=$(jq -r --arg svc "$service" '.services[$svc].serviceProvidedEnvs[]? // empty' /var/www/.zaia 2>/dev/null)
    if [ -n "$service_provided" ]; then
        echo "$service_provided" | sed 's/^/  /'
    else
        echo "  None available"
    fi

    echo ""
    echo "⚙️  SELF-DEFINED (in zerops.yml):"
    local self_defined=$(jq -r --arg svc "$service" '.services[$svc].selfDefinedEnvs | to_entries[]? | "  \(.key): \(.value)"' /var/www/.zaia 2>/dev/null)
    if [ -n "$self_defined" ]; then
        echo "$self_defined"
    else
        echo "  None defined yet"
    fi

    echo ""
    echo "💡 Usage in zerops.yml:"
    echo "  envVariables:"
    echo "    NODE_ENV: production"
    echo "    DATABASE_URL: \$db_connectionString"
    echo ""
    return 0
}

# CLEAN: Suggest environment variables based on .zaia service dependencies
suggest_env_vars() {
    local service="$1"

    if [ ! -f /var/www/.zaia ]; then
        echo "❌ FATAL: .zaia file not found. Run init_state.sh first" >&2
        exit 1
    fi

    if ! jq empty /var/www/.zaia 2>/dev/null; then
        echo "❌ FATAL: .zaia file is corrupted. Run init_state.sh" >&2
        exit 1
    fi

    # Check if service exists
    if ! jq -e --arg svc "$service" '.services[$svc]' /var/www/.zaia >/dev/null 2>&1; then
        echo "❌ Service '$service' not found in .zaia" >&2
        exit 1
    fi

    echo "=== ENVIRONMENT VARIABLE SUGGESTIONS FOR $service (.zaia ONLY) ==="
    echo ""

    # Check for database services in project
    local db_services=$(jq -r '.services | to_entries[] | select(.value.role == "database") | .key' /var/www/.zaia 2>/dev/null)
    if [ -n "$db_services" ]; then
        echo "🗄️  Database connections available:"
        for db in $db_services; do
            echo "  DATABASE_URL: \$${db}_connectionString"
            echo "  DB_HOST: \$${db}_host"
            echo "  DB_PASSWORD: \$${db}_password"
        done
        echo ""
    fi

    # Check for cache services
    local cache_services=$(jq -r '.services | to_entries[] | select(.value.role == "cache") | .key' /var/www/.zaia 2>/dev/null)
    if [ -n "$cache_services" ]; then
        echo "🚀 Cache connections available:"
        for cache in $cache_services; do
            echo "  REDIS_URL: \$${cache}_connectionString"
            echo "  CACHE_HOST: \$${cache}_host"
        done
        echo ""
    fi

    # Suggest common environment variables based on service type
    local service_type=$(jq -r --arg svc "$service" '.services[$svc].type // ""' /var/www/.zaia 2>/dev/null)
    if [[ "$service_type" == nodejs* ]]; then
        echo "📦 Common Node.js environment variables:"
        echo "  NODE_ENV: production  # or development"
        echo "  PORT: 3000"
        echo "  JWT_SECRET: your_jwt_secret"
        echo ""
    elif [[ "$service_type" == python* ]]; then
        echo "🐍 Common Python environment variables:"
        echo "  PYTHONPATH: /var/www"
        echo "  DJANGO_SETTINGS_MODULE: app.settings  # for Django"
        echo "  FLASK_ENV: production  # for Flask"
        echo ""
    fi

    return 0
}

# CLEAN: Check if service needs restart using .zaia ONLY
needs_environment_restart() {
    local service="$1"
    local other_service="$2"

    if [ ! -f /var/www/.zaia ]; then
        echo "❌ FATAL: .zaia file not found" >&2
        exit 1
    fi

    if ! jq empty /var/www/.zaia 2>/dev/null; then
        echo "❌ FATAL: .zaia file is corrupted" >&2
        exit 1
    fi

    # Check if service's zerops.yml references other_service variables
    local yml_content=$(jq -r --arg svc "$service" '.services[$svc].actualZeropsYml // ""' /var/www/.zaia 2>/dev/null)
    if [ -n "$yml_content" ] && echo "$yml_content" | grep -q "\$${other_service}_"; then
        echo "true"
    else
        echo "false"
    fi
}

# CLEAN: Restart service for environment variables (using .zaia ONLY)
restart_service_for_envs() {
    local service="$1"
    local reason="$2"
    local service_id=$(get_service_id "$service")  # This will exit if not found

    echo "🔄 Restarting $service: $reason"
    if zcli service stop --serviceId "$service_id"; then
        sleep 5
        if zcli service start --serviceId "$service_id"; then
            sleep 10
            echo "✅ $service restarted - new environment variables now accessible"
            return 0
        else
            echo "❌ FATAL: Failed to start $service"
            exit 1
        fi
    else
        echo "❌ FATAL: Failed to stop $service"
        exit 1
    fi
}

# CLEAN: Test database connectivity using .zaia ONLY
test_database_connectivity() {
    local service="$1"
    local db_service="$2"

    if [ ! -f /var/www/.zaia ]; then
        echo "❌ FATAL: .zaia file not found" >&2
        exit 1
    fi

    if ! jq empty /var/www/.zaia 2>/dev/null; then
        echo "❌ FATAL: .zaia file is corrupted" >&2
        exit 1
    fi

    # Check if both services exist
    if ! jq -e --arg svc "$service" '.services[$svc]' /var/www/.zaia >/dev/null 2>&1; then
        echo "❌ Service '$service' not found in .zaia" >&2
        exit 1
    fi

    if ! jq -e --arg svc "$db_service" '.services[$svc]' /var/www/.zaia >/dev/null 2>&1; then
        echo "❌ Database service '$db_service' not found in .zaia" >&2
        exit 1
    fi

    echo "🔍 Testing database connectivity from $service to $db_service (.zaia ONLY)..."

    # Check if database variables are available in service
    local db_vars=$(jq -r --arg svc "$service" '.services[$svc].serviceProvidedEnvs[]? // empty' /var/www/.zaia | grep "^${db_service}_" || echo "")
    if [ -z "$db_vars" ]; then
        echo "❌ No database environment variables found for $db_service in $service"
        echo "   Available variables:"
        get_available_envs "$service"
        exit 1
    fi

    echo "✅ Database environment variables are available in .zaia"

    # Test connectivity based on database type
    local db_type=$(jq -r --arg svc "$db_service" '.services[$svc].type // ""' /var/www/.zaia 2>/dev/null)

    if [[ "$db_type" == postgresql* ]]; then
        echo "Testing PostgreSQL connectivity..."
        ssh zerops@"$service" "timeout 10 bash -c 'echo \"SELECT 1;\" | psql \$${db_service}_connectionString 2>/dev/null && echo \"✅ PostgreSQL connection successful\" || echo \"❌ PostgreSQL connection failed\"'" 2>/dev/null || echo "❌ Could not test PostgreSQL connection"
    elif [[ "$db_type" == mysql* ]] || [[ "$db_type" == mariadb* ]]; then
        echo "Testing MySQL/MariaDB connectivity..."
        ssh zerops@"$service" "timeout 10 bash -c 'echo \"SELECT 1;\" | mysql --protocol=tcp -h\$${db_service}_host -u\$${db_service}_user -p\$${db_service}_password \$${db_service}_database 2>/dev/null && echo \"✅ MySQL connection successful\" || echo \"❌ MySQL connection failed\"'" 2>/dev/null || echo "❌ Could not test MySQL connection"
    elif [[ "$db_type" == mongodb* ]]; then
        echo "Testing MongoDB connectivity..."
        ssh zerops@"$service" "timeout 10 bash -c 'echo \"db.runCommand({ping: 1})\" | mongosh \$${db_service}_connectionString --quiet 2>/dev/null && echo \"✅ MongoDB connection successful\" || echo \"❌ MongoDB connection failed\"'" 2>/dev/null || echo "❌ Could not test MongoDB connection"
    else
        echo "ℹ️  Database type '$db_type' - testing network connectivity"
        ssh zerops@"$service" "timeout 5 bash -c 'nc -z \$${db_service}_host \$${db_service}_port 2>/dev/null && echo \"✅ Network connectivity successful\" || echo \"❌ Network connectivity failed\"'" 2>/dev/null || echo "❌ Could not test network connectivity"
    fi

    return 0
}

# CLEAN: Validate service type against technologies.json
validate_service_type() {
    local type="$1"

    if [ ! -f /var/www/technologies.json ]; then
        echo "❌ FATAL: technologies.json not found - cannot validate service type" >&2
        exit 1
    fi

    if grep -q "\"$type\"" /var/www/technologies.json; then
        echo "✅ Valid service type: $type"
        return 0
    else
        echo "❌ Invalid service type: $type" >&2
        echo "" >&2
        echo "Similar types available:" >&2
        local base_type=$(echo "$type" | cut -d@ -f1)
        grep -i "$base_type" /var/www/technologies.json | head -5 | sed 's/^/  /' >&2
        exit 1
    fi
}
