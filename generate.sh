#!/bin/bash
# Place all scripts in /var/www/ directory

# ============================================================================
# INPUT VALIDATION FUNCTIONS
# ============================================================================
cat > ./validate_inputs.sh << 'EOF'
#!/bin/bash

# Validate service name (Zerops requirements)
validate_service_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9]+$ ]] || [[ ${#name} -gt 25 ]]; then
        echo "❌ Invalid service name '$name'. Use lowercase letters and numbers only. Max 25 chars."
        return 1
    fi
    return 0
}

# Validate technology specification
validate_technology() {
    local tech="$1"
    if [[ ! "$tech" =~ ^[a-zA-Z0-9@.]+$ ]]; then
        echo "❌ Invalid technology specification '$tech'"
        return 1
    fi
    return 0
}

# Sanitize command inputs
sanitize_command() {
    local cmd="$1"
    echo "$cmd" | sed 's/[;&|`$()]//g' | tr -d '\n\r'
}
EOF

chmod +x ./validate_inputs.sh

# ============================================================================
# STATE INITIALIZATION
# ============================================================================
cat > ./init_state.sh << 'EOF'
#!/bin/bash
set -e

source /var/www/validate_inputs.sh

echo "=== INITIALIZING PROJECT STATE ==="

# Check authentication
if ! zcli project list >/dev/null 2>&1; then
    echo "Authenticating..."
    zcli login "$ZEROPS_ACCESS_TOKEN"
fi

# Backup existing state
if [ -f /var/www/.zaia ]; then
    cp /var/www/.zaia /var/www/.zaia.backup
    echo "Existing state backed up"
fi

# Get project export
echo "Fetching project configuration..."
if ! curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" \
     "https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/export" \
     -o /tmp/project_export.yaml; then
    echo "❌ Failed to fetch project configuration"
    exit 1
fi

# Validate export
if ! yq e '.project.name' /tmp/project_export.yaml >/dev/null 2>&1; then
    echo "❌ Invalid export data"
    exit 1
fi

PROJECT_NAME=$(yq e '.project.name' /tmp/project_export.yaml)

# Initialize .zaia
cat > ./.zaia << ZAIA_EOF
{
  "project": {
    "id": "$projectId",
    "name": "$PROJECT_NAME",
    "lastSync": "$(date -Iseconds)"
  },
  "services": {},
  "deploymentPairs": {},
  "envs": {}
}
ZAIA_EOF

echo "State initialized, discovering services..."
/var/www/discover_services.sh
echo "✅ Project state ready"
EOF

chmod +x ./init_state.sh

# ============================================================================
# SERVICE DISCOVERY
# ============================================================================
cat > ./discover_services.sh << 'EOF'
#!/bin/bash
set -e

source /var/www/validate_inputs.sh

echo "=== DISCOVERING SERVICES ==="

# Ensure export exists
if [ ! -f /tmp/project_export.yaml ]; then
    echo "Fetching project export..."
    curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" \
         "https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/export" \
         -o /tmp/project_export.yaml
fi

# Validate services data
if ! yq e '.services' /tmp/project_export.yaml >/dev/null 2>&1; then
    echo "❌ Invalid services data"
    exit 1
fi

# Get runtime status
zcli service list --projectId "$projectId" > /tmp/service_status.txt

# Check state file
if [ ! -f /var/www/.zaia ]; then
    echo "❌ State file missing. Run init_state.sh first"
    exit 1
fi

cp /var/www/.zaia /tmp/.zaia.tmp

# Process each service
for service in $(yq e '.services[].hostname' /tmp/project_export.yaml); do
    # Validate name
    if ! validate_service_name "$service"; then
        echo "⚠️  Skipping invalid service: $service"
        continue
    fi
    
    echo "Processing $service..."
    
    SERVICE_TYPE=$(yq e ".services[] | select(.hostname == \"$service\") | .type" /tmp/project_export.yaml)
    SERVICE_MODE=$(yq e ".services[] | select(.hostname == \"$service\") | .mode" /tmp/project_export.yaml)
    
    # Get service ID (prefer env var)
    SERVICE_ID=""
    if env | grep -q "^${service}_serviceId="; then
        SERVICE_ID=$(env | grep "^${service}_serviceId=" | cut -d= -f2)
    else
        SERVICE_ID=$(yq e ".services[] | select(.hostname == \"$service\") | .id" /tmp/project_export.yaml)
    fi
    
    # Determine role
    if [[ $service == *"dev" ]]; then
        ROLE="development"
    elif [[ "$SERVICE_TYPE" =~ ^(postgresql|mariadb|mongodb|mysql) ]]; then
        ROLE="database"
    elif [[ "$SERVICE_TYPE" =~ ^(redis|keydb|valkey) ]]; then
        ROLE="cache"
    else
        ROLE="stage"
    fi
    
    # Get zerops.yml for runtime services
    ZEROPS_CONFIG="null"
    if [[ "$SERVICE_TYPE" =~ ^(nodejs|php|python|go|rust|dotnet|java) ]]; then
        if ssh $service "echo 'OK'" 2>/dev/null; then
            ZEROPS_CONTENT=$(ssh $service "cat /var/www/zerops.yml 2>/dev/null || cat /var/www/zerops.yaml 2>/dev/null || echo 'NO_CONFIG'")
            if [[ "$ZEROPS_CONTENT" != "NO_CONFIG" ]]; then
                ZEROPS_CONFIG=$(echo "$ZEROPS_CONTENT" | jq -Rs .)
            fi
        fi
    fi
    
    # Update state
    jq --arg hostname "$service" \
       --arg id "$SERVICE_ID" \
       --arg type "$SERVICE_TYPE" \
       --arg role "$ROLE" \
       --arg mode "$SERVICE_MODE" \
       --argjson zerops "$ZEROPS_CONFIG" \
       '.services[$hostname] = {
         "id": $id,
         "type": $type, 
         "role": $role,
         "mode": $mode,
         "actualZeropsYml": $zerops
       }' /tmp/.zaia.tmp > /tmp/.zaia.tmp2
    
    mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
    
    # Collect env vars
    ENV_VARS=$(env | grep "^${service}_" | cut -d= -f1 | jq -R . | jq -s .)
    jq --arg service "$service" --argjson vars "$ENV_VARS" \
       '.envs[$service] = $vars' /tmp/.zaia.tmp > /tmp/.zaia.tmp2
    mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
done

# Map deployment pairs
echo "Mapping deployment pairs..."
for service in $(yq e '.services[].hostname' /tmp/project_export.yaml | grep "dev$"); do
    BASE_NAME=${service%dev}
    if yq e ".services[].hostname" /tmp/project_export.yaml | grep -q "^${BASE_NAME}$"; then
        jq --arg dev "$service" --arg stage "$BASE_NAME" \
           '.deploymentPairs[$dev] = $stage' /tmp/.zaia.tmp > /tmp/.zaia.tmp2
        mv /tmp/.zaia.tmp2 /tmp/.zaia.tmp
    fi
done

# Update timestamp and save
jq --arg timestamp "$(date -Iseconds)" \
   '.project.lastSync = $timestamp' /tmp/.zaia.tmp > /var/www/.zaia

echo "✅ Discovery completed"
rm -f /tmp/.zaia.tmp*
cp /var/www/.zaia /var/www/.zaia.backup
EOF

chmod +x ./discover_services.sh

# ============================================================================
# PROJECT CONTEXT DISPLAY
# ============================================================================
cat > ./show_project_context.sh << 'EOF'
#!/bin/bash

echo "==================== PROJECT CONTEXT ===================="

if [ ! -f /var/www/.zaia ]; then
    echo "❌ No state file. Run /var/www/init_state.sh first"
    exit 1
fi

# Validate JSON
if ! jq empty /var/www/.zaia 2>/dev/null; then
    echo "❌ Corrupted state file. Run /var/www/init_state.sh"
    exit 1
fi

PROJECT_NAME=$(jq -r '.project.name' /var/www/.zaia)
PROJECT_ID=$(jq -r '.project.id' /var/www/.zaia)
LAST_SYNC=$(jq -r '.project.lastSync' /var/www/.zaia)

echo "📋 Project: $PROJECT_NAME ($PROJECT_ID)"
echo "🕒 Last Sync: $LAST_SYNC"
echo ""

echo "🔧 SERVICES:"
jq -r '.services | to_entries[] | "  \(.key) (\(.value.type)) - \(.value.role) - \(.value.mode)"' /var/www/.zaia

echo ""
echo "🚀 DEPLOYMENT PAIRS:"
if [ "$(jq '.deploymentPairs | length' /var/www/.zaia)" -gt 0 ]; then
    jq -r '.deploymentPairs | to_entries[] | "  \(.key) → \(.value)"' /var/www/.zaia
else
    echo "  None configured"
fi

echo ""
echo "🌍 ENVIRONMENT VARIABLES:"
jq -r '.envs | to_entries[] | select(.value | length > 0) | "  \(.key): \(.value | length) variables"' /var/www/.zaia

echo ""
echo "📊 SUMMARY:"
echo "  Total Services: $(jq '.services | length' /var/www/.zaia)"
echo "  Development: $(jq -r '.services | to_entries[] | select(.value.role == "development") | .key' /var/www/.zaia | wc -l)"
echo "  Stage/Prod: $(jq -r '.services | to_entries[] | select(.value.role == "stage") | .key' /var/www/.zaia | wc -l)"
echo "  Databases: $(jq -r '.services | to_entries[] | select(.value.role == "database") | .key' /var/www/.zaia | wc -l)"
echo "  Cache: $(jq -r '.services | to_entries[] | select(.value.role == "cache") | .key' /var/www/.zaia | wc -l)"

echo "========================================================"
EOF

chmod +x ./show_project_context.sh

# ============================================================================
# ZEROPS RECIPE SYSTEM (FIXED - USES recipes.json)
# ============================================================================
cat > ./get_recipe.sh << 'EOF'
#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <technology>"
    echo "Examples: nodejs, python, php, go, nextjs, laravel, django"
    exit 1
fi

TECH="$1"

# Check if recipes.json exists
if [ ! -f /var/www/recipes.json ]; then
    echo "❌ recipes.json not found at /var/www/recipes.json"
    echo "Please ensure recipes.json is available"
    exit 1
fi

# Fuzzy technology mapping to match recipe titles/tags
fuzzy_match_technology() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    
    # Common mappings
    case "$lower_input" in
        "nodejs"|"node"|"node.js"|"js"|"javascript") echo "Node.js" ;;
        "golang"|"go") echo "Golang" ;;
        "python"|"py"|"python3") echo "Python" ;;
        "dotnet"|".net"|"csharp"|"c#") echo ".NET" ;;
        *) 
            # Return input with first letter capitalized for direct matching
            echo "$input" | sed 's/^./\U&/'
            ;;
    esac
}

MAPPED_TECH=$(fuzzy_match_technology "$TECH")
echo "🔍 Searching for '$TECH' (mapped to '$MAPPED_TECH')..."

# Search in recipes.json - try multiple strategies
# 1. Exact title match
RECIPE=$(jq --arg tech "$MAPPED_TECH" '.[] | select(.title == $tech)' /var/www/recipes.json 2>/dev/null)

# 2. Case-insensitive title match
if [ -z "$RECIPE" ]; then
    RECIPE=$(jq --arg tech "$MAPPED_TECH" '.[] | select(.title | ascii_downcase == ($tech | ascii_downcase))' /var/www/recipes.json 2>/dev/null | head -1)
fi

# 3. Tag match
if [ -z "$RECIPE" ]; then
    RECIPE=$(jq --arg tech "$MAPPED_TECH" '.[] | select(.tag == $tech)' /var/www/recipes.json 2>/dev/null | head -1)
fi

# 4. ID match
if [ -z "$RECIPE" ]; then
    RECIPE=$(jq --arg tech "$TECH" '.[] | select(.id == $tech)' /var/www/recipes.json 2>/dev/null | head -1)
fi

# 5. Partial match in title
if [ -z "$RECIPE" ]; then
    RECIPE=$(jq --arg tech "$MAPPED_TECH" '.[] | select(.title | contains($tech))' /var/www/recipes.json 2>/dev/null | head -1)
fi

# 6. Partial match in tag
if [ -z "$RECIPE" ]; then
    RECIPE=$(jq --arg tech "$MAPPED_TECH" '.[] | select(.tag | contains($tech))' /var/www/recipes.json 2>/dev/null | head -1)
fi

# Check if recipe found
if [ -z "$RECIPE" ] || [ "$RECIPE" = "null" ]; then
    echo "❌ Recipe not found for '$TECH'"
    echo ""
    echo "Available recipes:"
    jq -r '.[].title' /var/www/recipes.json | sort | uniq | head -20
    exit 1
fi

# Display recipe information
echo "✅ Found recipe: $(echo "$RECIPE" | jq -r '.title')"
echo "$RECIPE" | jq .

EOF

chmod +x ./get_recipe.sh

# ============================================================================
# INTELLIGENT DEVELOPMENT SERVER STARTUP
# ============================================================================
cat > ./intelligent_start.sh << 'EOF'
#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <service>"
    echo "Example: $0 myappdev"
    exit 1
fi

SERVICE="$1"

# === PHASE 1: TECHNOLOGY DETECTION ===
echo "=== ANALYZING PROJECT STRUCTURE ==="

# Detect primary technology
TECH_INDICATORS=$(ssh $SERVICE "cd /var/www && find . -maxdepth 2 -type f \( -name 'package.json' -o -name 'requirements.txt' -o -name 'composer.json' -o -name 'go.mod' -o -name 'Cargo.toml' -o -name 'pom.xml' -o -name 'build.gradle' \) 2>/dev/null")

# Determine base technology with confidence scoring
TECH_CONFIDENCE=0
DETECTED_TECH=""

if echo "$TECH_INDICATORS" | grep -q "package.json"; then
    DETECTED_TECH="nodejs"
    TECH_CONFIDENCE=90
    PACKAGE_JSON=$(ssh $SERVICE "cat /var/www/package.json 2>/dev/null")
elif echo "$TECH_INDICATORS" | grep -q "requirements.txt"; then
    DETECTED_TECH="python"
    TECH_CONFIDENCE=90
elif echo "$TECH_INDICATORS" | grep -q "composer.json"; then
    DETECTED_TECH="php"
    TECH_CONFIDENCE=90
elif echo "$TECH_INDICATORS" | grep -q "go.mod"; then
    DETECTED_TECH="go"
    TECH_CONFIDENCE=90
else
    # Fallback: analyze file extensions
    FILE_STATS=$(ssh $SERVICE "cd /var/www && find . -type f -name '*.*' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -5")
    echo "File extension analysis: $FILE_STATS"
    DETECTED_TECH="unknown"
    TECH_CONFIDENCE=30
fi

echo "Detected technology: $DETECTED_TECH (confidence: $TECH_CONFIDENCE%)"

# === PHASE 2: FRAMEWORK DETECTION ===
if [ "$DETECTED_TECH" = "nodejs" ] && [ -n "$PACKAGE_JSON" ]; then
    # Analyze dependencies for framework
    FRAMEWORK=""
    if echo "$PACKAGE_JSON" | jq -r '.dependencies | keys[]' 2>/dev/null | grep -qE "^(express|@express)"; then
        FRAMEWORK="express"
    elif echo "$PACKAGE_JSON" | jq -r '.dependencies | keys[]' 2>/dev/null | grep -q "fastify"; then
        FRAMEWORK="fastify"
    elif echo "$PACKAGE_JSON" | jq -r '.dependencies | keys[]' 2>/dev/null | grep -q "next"; then
        FRAMEWORK="nextjs"
    elif echo "$PACKAGE_JSON" | jq -r '.dependencies | keys[]' 2>/dev/null | grep -q "@nestjs"; then
        FRAMEWORK="nestjs"
    fi
    echo "Detected framework: $FRAMEWORK"
    
    # Analyze available scripts
    SCRIPTS=$(echo "$PACKAGE_JSON" | jq -r '.scripts | keys[]' 2>/dev/null || echo "")
    echo "Available scripts: $SCRIPTS"
fi

# === PHASE 3: START COMMAND DETERMINATION ===
START_CMD=""
PORT=""

case "$DETECTED_TECH" in
    nodejs)
        # Intelligent script selection
        if echo "$SCRIPTS" | grep -q "^dev$"; then
            START_CMD="npm run dev"
        elif echo "$SCRIPTS" | grep -q "^start:dev$"; then
            START_CMD="npm run start:dev"
        elif echo "$SCRIPTS" | grep -q "^develop$"; then
            START_CMD="npm run develop"
        elif echo "$SCRIPTS" | grep -q "^start$"; then
            START_CMD="npm start"
        else
            # Analyze main file
            MAIN_FILE=$(echo "$PACKAGE_JSON" | jq -r '.main // "index.js"' 2>/dev/null)
            if ssh $SERVICE "test -f /var/www/$MAIN_FILE"; then
                START_CMD="node $MAIN_FILE"
            else
                # Look for common entry points
                for entry in server.js app.js index.js main.js; do
                    if ssh $SERVICE "test -f /var/www/$entry"; then
                        START_CMD="node $entry"
                        break
                    fi
                done
            fi
        fi
        PORT=3000
        ;;
        
    python)
        # Detect Python framework and entry point
        if ssh $SERVICE "test -f /var/www/manage.py"; then
            # Django
            START_CMD="python manage.py runserver 0.0.0.0:8000"
            PORT=8000
        elif ssh $SERVICE "grep -l 'FastAPI()' /var/www/*.py 2>/dev/null | head -1"; then
            # FastAPI
            FASTAPI_FILE=$(ssh $SERVICE "grep -l 'FastAPI()' /var/www/*.py 2>/dev/null | head -1 | xargs basename")
            START_CMD="uvicorn ${FASTAPI_FILE%.py}:app --reload --host 0.0.0.0 --port 8000"
            PORT=8000
        elif ssh $SERVICE "grep -l 'Flask(__name__)' /var/www/*.py 2>/dev/null | head -1"; then
            # Flask
            FLASK_FILE=$(ssh $SERVICE "grep -l 'Flask(__name__)' /var/www/*.py 2>/dev/null | head -1 | xargs basename")
            START_CMD="python $FLASK_FILE"
            PORT=5000
        else
            # Generic Python app
            MAIN_PY=$(ssh $SERVICE "ls /var/www/{app,main,server,index}.py 2>/dev/null | head -1 | xargs basename" || echo "app.py")
            START_CMD="python $MAIN_PY"
            PORT=8000
        fi
        ;;
        
    php)
        # PHP runs automatically, no manual start needed
        echo "PHP runs automatically on port 80"
        PORT=80
        ;;
        
    go)
        # Check for compiled binary first
        if ssh $SERVICE "test -f /var/www/app"; then
            START_CMD="./app"
        else
            START_CMD="go run ."
        fi
        PORT=8080
        ;;
        
    *)
        echo "❌ Unknown technology, cannot determine start command"
        exit 1
        ;;
esac

# === PHASE 4: PORT DETECTION AND OVERRIDE ===
if [ "$DETECTED_TECH" != "php" ]; then
    # Try to detect port from code
    CODE_PORT=$(ssh $SERVICE "grep -r 'PORT\\|port\\|listen' /var/www --include='*.js' --include='*.py' --include='*.go' 2>/dev/null | grep -oE '[0-9]{4}' | grep -E '^[0-9]{4}$' | head -1")
    
    if [ -n "$CODE_PORT" ] && [ "$CODE_PORT" -ne "$PORT" ]; then
        echo "Detected port $CODE_PORT in code (overriding default $PORT)"
        PORT=$CODE_PORT
    fi
    
    # Check for PORT environment variable usage
    if ssh $SERVICE "grep -q 'process.env.PORT' /var/www/*.js 2>/dev/null" || \
       ssh $SERVICE "grep -q 'os.environ.*PORT' /var/www/*.py 2>/dev/null"; then
        echo "App uses PORT environment variable"
        PORT_PREFIX="PORT=$PORT "
    fi
fi

# === PHASE 5: SAFE STARTUP WITH ERROR HANDLING ===
if [ "$DETECTED_TECH" != "php" ]; then
    echo "=== STARTING DEVELOPMENT SERVER ==="
    echo "Technology: $DETECTED_TECH"
    echo "Start command: $START_CMD"
    echo "Port: $PORT"
    
    # Kill any existing process on the port
    ssh $SERVICE "sudo fuser -k $PORT/tcp 2>/dev/null || true"
    sleep 2
    
    # Start with enhanced error handling
    ssh $SERVICE "cd /var/www && nohup ${PORT_PREFIX}${START_CMD} > dev.log 2>&1 & echo $! > app.pid"
    sleep 5
    
    # Verify startup with multiple checks
    PID_CHECK=$(ssh $SERVICE "kill -0 \$(cat app.pid 2>/dev/null) 2>/dev/null && echo 'RUNNING' || echo 'FAILED'")
    PORT_CHECK=$(ssh $SERVICE "netstat -tln | grep :$PORT >/dev/null && echo 'LISTENING' || echo 'NOT_LISTENING'")
    
    if [ "$PID_CHECK" = "RUNNING" ] && [ "$PORT_CHECK" = "LISTENING" ]; then
        echo "✅ Development server running on port $PORT"
        
        # Additional health check
        sleep 2
        if curl -f http://$SERVICE:$PORT/ >/dev/null 2>&1; then
            echo "✅ Server responding to HTTP requests"
        else
            echo "⚠️  Server running but not responding to HTTP yet"
            echo "Checking logs for errors..."
            ssh $SERVICE "tail -20 /var/www/dev.log | grep -E 'error|Error|failed|Failed' || echo 'No errors in recent logs'"
        fi
    else
        echo "❌ Server startup failed"
        echo "Process status: $PID_CHECK"
        echo "Port status: $PORT_CHECK"
        echo "Recent logs:"
        ssh $SERVICE "tail -30 /var/www/dev.log"
        
        # Attempt recovery
        echo "Attempting recovery..."
        case "$DETECTED_TECH" in
            nodejs)
                ssh $SERVICE "cd /var/www && npm install 2>&1 | tail -10" || true
                ;;
            python)
                ssh $SERVICE "cd /var/www && pip install -r requirements.txt 2>&1 | tail -10" || true
                ;;
        esac
        
        # Retry with more verbose logging
        echo "Retrying with verbose logging..."
        ssh $SERVICE "cd /var/www && ${PORT_PREFIX}${START_CMD} 2>&1 | tee startup.log &"
        sleep 5
        ssh $SERVICE "tail -50 startup.log"
    fi
fi

echo "✅ Startup process completed for $SERVICE"
EOF

chmod +x ./intelligent_start.sh

# ============================================================================
# PUPPETEER DIAGNOSTICS
# ============================================================================
cat > ./diagnose.js << 'EOF'
#!/usr/bin/env node

const puppeteer = require('puppeteer');
const fs = require('fs');

async function diagnoseWebPage(url, options = {}) {
  const results = {
    url,
    timestamp: new Date().toISOString(),
    errors: [],
    warnings: [],
    networkIssues: [],
    loadingProblems: [],
    performance: {},
    pageInfo: {}
  };

  let browser;
  try {
    browser = await puppeteer.launch({
      executablePath: process.env.PUPPETEER_EXECUTABLE_PATH,
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox']
    });

    const page = await browser.newPage();

    // Capture console errors
    page.on('console', msg => {
      const type = msg.type();
      if (type === 'error') {
        results.errors.push({
          type: 'console_error',
          message: msg.text(),
          location: msg.location()
        });
      } else if (type === 'warning') {
        results.warnings.push({
          type: 'console_warning',
          message: msg.text()
        });
      }
    });

    // Capture page errors
    page.on('pageerror', error => {
      results.errors.push({
        type: 'page_error',
        message: error.message,
        stack: error.stack
      });
    });

    // Network failures
    page.on('requestfailed', request => {
      results.networkIssues.push({
        type: 'request_failed',
        url: request.url(),
        error: request.failure().errorText,
        resourceType: request.resourceType()
      });
    });

    // HTTP errors
    page.on('response', response => {
      if (response.status() >= 400) {
        results.networkIssues.push({
          type: 'http_error',
          url: response.url(),
          status: response.status(),
          statusText: response.statusText()
        });
      }
    });

    // Performance timing
    const startTime = Date.now();

    // Navigate
    try {
      await page.goto(url, { 
        waitUntil: 'networkidle2',
        timeout: options.timeout || 30000 
      });
    } catch (error) {
      results.errors.push({
        type: 'navigation_error',
        message: error.message
      });
      return results;
    }

    results.performance.loadTime = Date.now() - startTime;

    // Get page info
    results.pageInfo.title = await page.title();
    results.pageInfo.url = page.url();
    
    // Check selectors
    if (options.checkSelectors) {
      results.pageInfo.selectorChecks = {};
      for (const selector of options.checkSelectors) {
        const exists = !!(await page.$(selector));
        results.pageInfo.selectorChecks[selector] = exists;
        if (!exists) {
          results.loadingProblems.push({
            type: 'missing_element',
            selector: selector
          });
        }
      }
    }

    // Check page content
    const content = await page.evaluate(() => ({
      hasContent: document.body.textContent.trim().length > 100,
      hasLoaders: document.querySelectorAll('[class*="loading"]').length > 0,
      errorElements: document.querySelectorAll('[class*="error"]').length
    }));
    
    if (!content.hasContent) {
      results.loadingProblems.push({
        type: 'minimal_content',
        message: 'Page has very little content'
      });
    }

    if (content.hasLoaders) {
      results.loadingProblems.push({
        type: 'persistent_loading',
        message: 'Loading indicators still visible'
      });
    }

    // Performance metrics
    if (options.performance) {
      const metrics = await page.metrics();
      results.performance.metrics = metrics;
    }

    // Screenshots
    if (options.screenshots) {
      const screenshotPath = `/tmp/screenshot_${Date.now()}.png`;
      await page.screenshot({ path: screenshotPath });
      results.pageInfo.screenshot = screenshotPath;
    }

  } finally {
    if (browser) await browser.close();
  }

  return results;
}

// CLI
async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.log('Usage: node diagnose.js <url> [options]');
    console.log('Options:');
    console.log('  --check-selector <sel>  Check for CSS selector');
    console.log('  --timeout <ms>          Set timeout');
    console.log('  --performance           Capture performance metrics');
    console.log('  --screenshots           Take screenshots');
    console.log('  --output <file>         Save results to file');
    console.log('  --quiet                 Minimal output');
    process.exit(1);
  }

  const url = args[0];
  const options = {};
  
  for (let i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--check-selector':
        if (!options.checkSelectors) options.checkSelectors = [];
        options.checkSelectors.push(args[++i]);
        break;
      case '--timeout':
        options.timeout = parseInt(args[++i]);
        break;
      case '--performance':
        options.performance = true;
        break;
      case '--screenshots':
        options.screenshots = true;
        break;
      case '--output':
        options.outputFile = args[++i];
        break;
      case '--quiet':
        options.quiet = true;
        break;
    }
  }

  console.log(`🔍 Diagnosing: ${url}`);
  const results = await diagnoseWebPage(url, options);
  
  if (options.outputFile) {
    fs.writeFileSync(options.outputFile, JSON.stringify(results, null, 2));
    console.log(`📄 Results saved to: ${options.outputFile}`);
  }

  if (!options.quiet) {
    console.log(`📊 Page Info:`, results.pageInfo);
    if (results.performance.loadTime) {
      console.log(`⏱️  Load time: ${results.performance.loadTime}ms`);
    }
  }

  if (results.errors.length > 0) {
    console.log(`❌ Errors (${results.errors.length}):`);
    results.errors.forEach(e => console.log(`  • ${e.type}: ${e.message}`));
  }

  if (results.networkIssues.length > 0) {
    console.log(`🌐 Network Issues (${results.networkIssues.length}):`);
    results.networkIssues.forEach(i => console.log(`  • ${i.type}: ${i.url}`));
  }

  if (results.loadingProblems.length > 0) {
    console.log(`⏳ Loading Problems:`)
    results.loadingProblems.forEach(p => console.log(`  • ${p.type}: ${p.message || p.selector}`));
  }

  if (results.errors.length === 0 && results.networkIssues.length === 0) {
    console.log('✅ No issues detected!');
  }

  process.exit(results.errors.length > 0 ? 1 : 0);
}

if (require.main === module) {
  main().catch(console.error);
}

module.exports = { diagnoseWebPage };
EOF

chmod +x ./diagnose.js

# ============================================================================
# BACKEND TESTING SCRIPT
# ============================================================================
cat > ./test_backend.sh << 'EOF'
#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <base-url> [options]"
    echo "Options:"
    echo "  --endpoints <list>  Comma-separated endpoints to test"
    echo "  --method <method>   HTTP method (default: GET)"
    echo "  --data <json>       Request body for POST/PUT"
    echo "  --headers <list>    Comma-separated headers"
    exit 1
fi

BASE_URL="$1"
shift

# Default values
ENDPOINTS="/health"
METHOD="GET"
DATA=""
HEADERS="Content-Type: application/json"

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --endpoints)
            ENDPOINTS="$2"
            shift 2
            ;;
        --method)
            METHOD="$2"
            shift 2
            ;;
        --data)
            DATA="$2"
            shift 2
            ;;
        --headers)
            HEADERS="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "=== BACKEND API TESTING ==="
echo "Base URL: $BASE_URL"
echo "Method: $METHOD"

# Convert comma-separated lists to arrays
IFS=',' read -ra ENDPOINT_ARRAY <<< "$ENDPOINTS"
IFS=',' read -ra HEADER_ARRAY <<< "$HEADERS"

# Build curl header arguments
CURL_HEADERS=""
for header in "${HEADER_ARRAY[@]}"; do
    CURL_HEADERS="$CURL_HEADERS -H \"$header\""
done

# Test each endpoint
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

for endpoint in "${ENDPOINT_ARRAY[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo ""
    echo "Testing: $METHOD $endpoint"
    
    # Build curl command
    if [ -n "$DATA" ]; then
        CURL_CMD="curl -s -X $METHOD $CURL_HEADERS -d '$DATA' -w '\\n%{http_code}' $BASE_URL$endpoint"
    else
        CURL_CMD="curl -s -X $METHOD $CURL_HEADERS -w '\\n%{http_code}' $BASE_URL$endpoint"
    fi
    
    # Execute request
    RESPONSE=$(eval $CURL_CMD)
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -n -1)
    
    # Check status
    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        echo "✅ Status: $HTTP_CODE"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        
        # Try to parse JSON
        if echo "$BODY" | jq . >/dev/null 2>&1; then
            echo "Response: $(echo "$BODY" | jq -c .)"
        else
            echo "Response: $BODY"
        fi
    else
        echo "❌ Status: $HTTP_CODE"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "Response: $BODY"
    fi
    
    # Response time
    TIME=$(curl -o /dev/null -s -w '%{time_total}' $BASE_URL$endpoint)
    echo "Response time: ${TIME}s"
done

echo ""
echo "=== TEST SUMMARY ==="
echo "Total: $TOTAL_TESTS"
echo "Passed: $PASSED_TESTS"
echo "Failed: $FAILED_TESTS"

exit $FAILED_TESTS
EOF

chmod +x ./test_backend.sh

echo "✅ Zerops AI Agent v8.0 FINAL helper scripts deployed!"
echo ""
echo "🚀 Quick Start:"
echo "   1. Initialize: /var/www/init_state.sh"
echo "   2. View context: /var/www/show_project_context.sh"
echo "   3. Get recipe: /var/www/get_recipe.sh nodejs"
echo "   4. Start dev server: /var/www/intelligent_start.sh mydevservice"
echo ""
echo "📝 Key Features:"
echo "   • Proper Zerops recipe format (import YAML + zerops.yml)"
echo "   • Intelligent server startup as standalone script"
echo "   • Simple deployment model (no complex rollback)"
echo "   • Comprehensive diagnostics (frontend + backend)"
echo "   • Automated recovery procedures"
echo "   • State management via .zaia"
echo ""
echo "🔧 Key Improvements:"
echo "   • Fixed recipe format to match Zerops requirements"
echo "   • Extracted intelligent startup to helper script"
echo "   • Removed unnecessary deployment complexity"
echo "   • Maintained all critical safety protocols"
echo "   • Enhanced error handling throughout"