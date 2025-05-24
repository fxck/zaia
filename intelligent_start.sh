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
