# CLAUDE BEHAVIOR ENFORCEMENT

## 🚨 CRITICAL ARCHITECTURE REQUIREMENTS

### **MANDATORY: Development Services MUST Include Code-Server**

**IRON RULE**: Every development service (ending in "dev") MUST include code-server configuration.

**WHY THIS KEEPS FAILING:**
1. Assistants follow user requests literally instead of architectural patterns
2. .goosehints examples are not being enforced as mandatory
3. No validation step to ensure code-server is included

### **ENFORCEMENT MECHANISM**

**BEFORE creating ANY zerops.yml for a development service:**

```bash
# MANDATORY CHECK - Development service MUST have code-server
if echo "$service_name" | grep -q "dev"; then
    echo "🔍 ENFORCING: Development service must include code-server"
    
    # VALIDATE configuration includes:
    # 1. prepareCommands with code-server installation
    # 2. Port 8080 for code-server (VPN access)
    # 3. Port 3000 for dev server (public access)
    # 4. start: code-server command
    
    if ! echo "$zerops_config" | grep -q "code-server"; then
        echo "❌ ARCHITECTURE VIOLATION: Development service missing code-server"
        echo "📋 REQUIRED: Use template from .goosehints workflow examples"
        exit 1
    fi
fi
```

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
      cache:
        - node_modules
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
        # ... other env vars
      start: code-server --auth none --bind-addr 0.0.0.0:8080 /var/www
```

### **ROOT CAUSE ANALYSIS**

**Why code-server keeps getting omitted:**

1. **Pattern Not Enforced**: .goosehints shows examples but doesn't enforce them
2. **User Request Override**: Assistants follow "create simple app" instead of architectural requirements
3. **No Validation**: No check that dev services include code-server
4. **Template Confusion**: Multiple examples without clear mandatory vs optional

### **SOLUTION: Template Enforcement**

**Add to core_utils.sh:**

```bash
validate_dev_service_config() {
    local config="$1"
    local service="$2"
    
    if echo "$service" | grep -q "dev"; then
        echo "🔍 Validating development service configuration..."
        
        if ! echo "$config" | grep -q "prepareCommands"; then
            echo "❌ Missing prepareCommands for code-server installation"
            return 1
        fi
        
        if ! echo "$config" | grep -q "code-server"; then
            echo "❌ Missing code-server in start command"
            return 1
        fi
        
        if ! echo "$config" | grep -q "port: 8080"; then
            echo "❌ Missing port 8080 for code-server"
            return 1
        fi
        
        echo "✅ Development service configuration valid"
    fi
    
    return 0
}
```

### **ASSISTANT PROMPT ENFORCEMENT**

**ADD TO SYSTEM PROMPT:**

```
CRITICAL RULE: Development services (names ending in "dev") MUST include code-server configuration.

BEFORE creating zerops.yml for ANY development service:
1. Check if service name ends with "dev"
2. If yes, use MANDATORY template from .goosehints with code-server
3. Validate configuration includes prepareCommands, port 8080, and code-server start command
4. NEVER create development services without code-server

This is NON-NEGOTIABLE architecture requirement.
```

### **IMMEDIATE ACTION REQUIRED**

1. **Update safe_create_remote_file** to validate dev service configs
2. **Add template enforcement** to create_services.sh
3. **Update .goosehints** to emphasize MANDATORY vs optional
4. **Add validation hooks** to prevent architecture violations

**The issue is systemic - we need enforcement at the tooling level, not just documentation.**

## 🚨 WORKFLOW COMPLETION ENFORCEMENT

### **MANDATORY TODO CREATION FOR DUAL SERVICES**

**CRITICAL ISSUE**: Assistants often create only development services and declare "success" without completing the full dev→prod workflow.

**ENFORCEMENT RULE**: When creating dual services (dev + prod), MUST create and track TODO list:

```bash
# MANDATORY: Create TODO when starting dual service workflow
create_workflow_todos() {
    local base_name="$1"  # e.g., "api", "app"
    
    echo "📋 Creating mandatory workflow TODO list..."
    
    # This should be called at the START of any dual service creation
    TodoWrite '[
        {"id": "create-dev-service", "content": "Create '${base_name}'dev development service with code-server", "status": "pending", "priority": "high"},
        {"id": "create-prod-service", "content": "Create '${base_name}' production service", "status": "pending", "priority": "high"},
        {"id": "configure-dev", "content": "Configure development environment and test locally", "status": "pending", "priority": "high"},
        {"id": "deploy-to-prod", "content": "Deploy from dev to production using /var/www/deploy.sh", "status": "pending", "priority": "high"},
        {"id": "verify-prod", "content": "Verify production deployment and enable subdomain", "status": "pending", "priority": "high"}
    ]'
}
```

### **WORKFLOW COMPLETION VALIDATION**

**RULE**: Never declare "success" until ALL todos are completed:

```bash
# MANDATORY: Check before declaring success
validate_workflow_complete() {
    local pending_todos=$(TodoRead | jq -r '.[] | select(.status == "pending" or .status == "in_progress") | .content')
    
    if [ -n "$pending_todos" ]; then
        echo "❌ WORKFLOW INCOMPLETE - Cannot declare success"
        echo "📋 Pending tasks:"
        echo "$pending_todos"
        echo ""
        echo "🔄 Complete all tasks before declaring success"
        return 1
    fi
    
    echo "✅ All workflow tasks completed"
    return 0
}
```

### **ASSISTANT BEHAVIOR ENFORCEMENT**

**ADD TO SYSTEM PROMPT:**

```
CRITICAL WORKFLOW RULE: When creating dual services (dev + production):

1. IMMEDIATELY create TODO list with all required steps
2. Work through TODOs systematically 
3. Mark each TODO complete as you finish it
4. NEVER declare "success" until validate_workflow_complete() passes
5. Production deployment is MANDATORY, not optional

COMMON VIOLATION: Creating only dev service and declaring success
REQUIRED: Complete full dev→prod workflow with verification
```

### **ROOT CAUSE: Premature Success Declaration**

**Why assistants stop at dev:**
1. User asks for "simple app" - sounds complete after dev works
2. No enforcement that prod deployment is required
3. TODO list not used to track workflow completion
4. Success criteria not defined upfront

**SOLUTION: Mandatory TODO tracking for dual workflows**