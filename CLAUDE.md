# CLAUDE BEHAVIOR ENFORCEMENT

## =� CRITICAL ARCHITECTURE REQUIREMENTS

### **MANDATORY: Development Services MUST Include Code-Server**

**IRON RULE**: Every development service (ending in "dev") MUST include code-server configuration.

**ENFORCEMENT**: `safe_create_remote_file()` validates zerops.yml and blocks invalid configurations.

### **MANDATORY TEMPLATE FOR DEVELOPMENT SERVICES**

```yaml
zerops:
  - setup: {servicename}dev
    build:
      base: nodejs@22
      os: ubuntu
      buildCommands:
        - npm install
      deployFiles:
        - ./
    run:
      base: nodejs@22
      os: ubuntu
      prepareCommands:
        - curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone
        - sudo chown -R zerops:zerops /home/zerops/.local/bin/code-server
      ports:
        - port: 8080                    # Code-server (VPN access only)
        - port: 3000                    # Dev server (can be shared publicly)
          httpSupport: true
      envVariables:
        NODE_ENV: development
      start: code-server --auth none --bind-addr 0.0.0.0:8080 /var/www
```

## =� FILE CREATION PATTERN ENFORCEMENT

### **CRITICAL**: No Temp File + Cat Workarounds

**VIOLATION DETECTED**: Assistants creating temp files to bypass validation:

```bash
# L WRONG - This will be detected and blocked
echo "content" > /tmp/zerops_config.yml
ZEROPS_CONFIG=$(cat /tmp/zerops_config.yml)
safe_create_remote_file "apidev" "/var/www/zerops.yml" "$ZEROPS_CONFIG"
```

**ENFORCEMENT**: `safe_create_remote_file()` now detects and blocks temp file usage.

**CORRECT PATTERN**:
```bash
#  CORRECT - Direct heredoc creation
safe_create_remote_file "apidev" "/var/www/zerops.yml" "$(cat << 'EOF'
zerops:
  - setup: apidev
    run:
      prepareCommands:
        - curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone
        - sudo chown -R zerops:zerops /home/zerops/.local/bin/code-server
      ports:
        - port: 8080                    # Code-server (VPN access only)
        - port: 3000                    # Dev server (can be shared publicly)
          httpSupport: true
      start: code-server --auth none --bind-addr 0.0.0.0:8080 /var/www
EOF
)"
```

## =� WORKFLOW COMPLETION ENFORCEMENT

### **MANDATORY TODO CREATION FOR DUAL SERVICES**

**CRITICAL ISSUE**: Assistants often create only development services and declare "success" without completing the full dev�prod workflow.

**ENFORCEMENT RULE**: When creating dual services (dev + prod), MUST create and track TODO list:

```bash
# MANDATORY: Auto-detect technology and create appropriate TODOs
auto_create_workflow_todos "create a simple nodejs app that reads and writes to postgres db"
# Result: nodejs REST API workflow for apidev + api services

# Or manual specification for any stack:
create_workflow_todos "blog" "python" "Django blog application"  # blogdev + blog
create_workflow_todos "shop" "php" "e-commerce store"           # shopdev + shop  
create_workflow_todos "web" "ruby" "Rails web application"      # webdev + web
create_workflow_todos "api" "go" "REST API service"             # apidev + api
```

**SUPPORTS ALL ZEROPS STACKS**:
- **Node.js**: express, fastify, next.js applications
- **Python**: django, flask, fastapi applications  
- **PHP**: laravel, symfony, wordpress applications
- **Ruby**: rails, sinatra applications
- **Go**: gin, echo, fiber applications
- **Java**: spring boot, quarkus applications
- **Rust**: actix-web, warp applications

**RULE**: Never declare "success" until ALL todos are completed.

### **ASSISTANT BEHAVIOR ENFORCEMENT**

**CRITICAL WORKFLOW RULES:**

1. **IMMEDIATELY create TODO list** with all required steps when starting dual service work
2. **Work through TODOs systematically** 
3. **Mark each TODO complete** as you finish it
4. **NEVER declare "success"** until validate_workflow_complete() passes
5. **Production deployment is MANDATORY**, not optional
6. **Development services MUST include code-server** - deployments blocked if missing
7. **Use heredoc directly** - no temp file + cat patterns allowed

**COMMON VIOLATIONS:**
- Creating only dev service and declaring success
- Using temp files to bypass validation
- Missing code-server in development services

**REQUIRED:** Complete full dev�prod workflow with verification before declaring success.
## 🚨 PREMATURE DEPLOYMENT PREVENTION

### **CRITICAL**: Application Structure Before Configuration

**VIOLATION DETECTED**: Deploying zerops.yml before creating basic application structure.

**WRONG ORDER**:
```bash
# ❌ This will fail - no package.json exists yet
safe_create_remote_file "apidev" "/var/www/zerops.yml" "$ZEROPS_CONFIG"
deploy_with_monitoring "apidev" "$(get_service_id 'apidev')"  # FAILS: npm install fails
```

**CORRECT ORDER**:
```bash
# ✅ Create application structure FIRST
safe_ssh "apidev" "cd /var/www && npm init -y"
safe_ssh "apidev" "cd /var/www && npm install express pg"

# Create basic application files
safe_create_remote_file "apidev" "/var/www/index.js" "$APP_CODE"

# THEN deploy configuration
safe_create_remote_file "apidev" "/var/www/zerops.yml" "$ZEROPS_CONFIG"
deploy_with_monitoring "apidev" "$(get_service_id 'apidev')"
```

**ENFORCEMENT**: safe_create_remote_file() now checks for package.json before allowing zerops.yml deployment with npm commands.

**WHY THIS HAPPENS**:
1. Assistants follow configuration-first thinking
2. Want to "set up environment" before coding
3. Don't realize build commands need files to exist

**SOLUTION**: Application structure → Configuration → Deployment

## 🚨 "NEXT STEPS" WORKAROUND DETECTION

### **CRITICAL**: No "Next Steps" Declarations

**VIOLATION DETECTED**: Assistants declaring success and listing production deployment as a "next step":

**WRONG**:
```
### 📈 **Next Steps**
1. **Deploy to Production**: Run `/var/www/deploy.sh apidev` to deploy to the production service
2. **Add Features**: Extend the API...

The application is fully functional!
```

**THIS IS BLOCKED** - Production deployment is NOT a "next step", it's a REQUIRED step.

**CORRECT**:
```bash
# ✅ Actually execute production deployment
/var/www/deploy.sh apidev

# Verify production works
curl https://production-url/health

# THEN declare success
echo "🎉 DEPLOYMENT COMPLETE - Both dev and production verified!"
```

**ENFORCEMENT**: 
- `validate_workflow_complete()` checks for actual production deployment
- `detect_premature_success()` blocks "next steps" language
- Must verify production subdomain exists before declaring success

**WHY "NEXT STEPS" IS WRONG**:
1. User asked for a working app - that means PRODUCTION ready
2. Development-only is incomplete work
3. "Next steps" suggests optional when it's mandatory

**SOLUTION**: Execute full workflow, verify production, THEN declare success

## 🚨 UNIVERSAL DEVELOPMENT/STAGE PAIRING

### **CRITICAL**: Always Create Service Pairs

**CORE PRINCIPLE**: Every application requires TWO services, regardless of type:

1. **Development Service** (`{name}dev`) 
   - For AI/human development
   - Includes code-server for browser IDE access
   - Full source code deployment
   - Manual workflow for iterative development

2. **Stage Service** (`{name}`)
   - For production deployment  
   - Optimized build process
   - Public access capabilities
   - Automated deployment from dev

**EXAMPLES OF UNIVERSAL PAIRING**:
```
Blog application:     blogdev + blog
E-commerce store:     shopdev + shop  
Chat application:     chatdev + chat
REST API:             apidev + api
Web application:      webdev + web
Database application: appdev + app
```

**WHY PAIRING IS MANDATORY**:
- **Development isolation** - Safe environment for experimentation
- **Production stability** - Optimized, tested deployments
- **Proper workflow** - dev→stage deployment process
- **Public access** - Only stage services get subdomains
- **Code-server access** - Only dev services have browser IDE

**ENFORCEMENT**: All validation functions check for complete pairs, not single services.
EOF < /dev/null