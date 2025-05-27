#!/bin/bash
set -e
source /var/www/core_utils.sh

usage() {
    echo "Usage: $0 <framework/technology>"
    echo ""
    echo "Examples:"
    echo "  $0 laravel      # PHP Laravel framework"
    echo "  $0 next.js      # Next.js React framework"
    echo "  $0 django       # Python Django framework"
    echo "  $0 express      # Express.js Node framework"
    echo "  $0 rails        # Ruby on Rails"
    echo ""
    echo "Recipes provide:"
    echo "  - Service architecture (import YAML)"
    echo "  - Production-ready zerops.yml"
    echo "  - Framework best practices"
    echo "  - Security recommendations"
    echo "  - Performance optimizations"
    exit 1
}

[ $# -eq 0 ] && usage

SEARCH_TERM="$1"

# Check recipes.json exists
if [ ! -f /var/www/recipes.json ]; then
    echo "❌ recipes.json not found"
    echo "   This file contains framework templates and best practices"
    exit 1
fi

# Enhanced fuzzy matching for common variations
fuzzy_match() {
    local input="$1"
    local lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    # Remove common punctuation and variations
    lower=${lower//[.-]/}
    lower=${lower// /}
    lower=${lower//js/}

    # Map common aliases to canonical names
    case "$lower" in
        # PHP Frameworks
        laravel*) echo "laravel" ;;
        symfony*) echo "symfony" ;;
        slim*) echo "slim" ;;
        lumen*) echo "lumen" ;;

        # JavaScript/Node.js
        next*) echo "nextjs" ;;
        nuxt*) echo "nuxtjs" ;;
        nest*) echo "nestjs" ;;
        express*) echo "express" ;;
        fastify*) echo "fastify" ;;
        koa*) echo "koa" ;;

        # Python
        django*) echo "django" ;;
        flask*) echo "flask" ;;
        fastapi*|fast*api*) echo "fastapi" ;;
        pyramid*) echo "pyramid" ;;

        # Ruby
        rails*|ruby*rails*) echo "rails" ;;
        sinatra*) echo "sinatra" ;;

        # Frontend
        vue*) echo "vuejs" ;;
        react*) echo "react" ;;
        angular*) echo "angular" ;;
        svelte*) echo "svelte" ;;
        solid*) echo "solidjs" ;;

        # CMS
        wordpress*|wp*) echo "wordpress" ;;
        strapi*) echo "strapi" ;;
        directus*) echo "directus" ;;
        ghost*) echo "ghost" ;;

        # Others
        spring*) echo "spring" ;;
        asp*|dotnet*|net*) echo "aspnet" ;;

        *) echo "$lower" ;;
    esac
}

# Get fuzzy matched term
MATCHED=$(fuzzy_match "$SEARCH_TERM")
echo "🔍 Searching for '$SEARCH_TERM' (matched: '$MATCHED')..."

# Search for recipe with multiple strategies
RECIPE=$(jq -r --arg term "$MATCHED" --arg orig "$SEARCH_TERM" '
    .[] | select(
        .id == $term or
        .id == $orig or
        .slug == $term or
        .slug == $orig or
        (.tag | ascii_downcase) == $term or
        (.tag | ascii_downcase) == $orig or
        (.title | ascii_downcase | test($term)) or
        (.title | ascii_downcase | test($orig)) or
        (.keywords[]? | ascii_downcase | test($term))
    ) | . // empty
' /var/www/recipes.json | head -1)

# If not found, try partial matching
if [ -z "$RECIPE" ] || [ "$RECIPE" = "null" ]; then
    RECIPE=$(jq -r --arg term "$MATCHED" '
        .[] | select(
            (.title | ascii_downcase | contains($term)) or
            (.desc | ascii_downcase | contains($term))
        ) | . // empty
    ' /var/www/recipes.json | head -1)
fi

# Still not found - show available recipes
if [ -z "$RECIPE" ] || [ "$RECIPE" = "null" ]; then
    echo "❌ Recipe not found for '$SEARCH_TERM'"
    echo ""
    echo "📚 Available recipes:"
    echo "===================="

    # Group by category if possible
    echo ""
    echo "🌐 Frontend Frameworks:"
    jq -r '.[] | select(.category == "frontend" or .tag | test("React|Vue|Angular|Svelte")) | "  - \(.tag // .title)"' /var/www/recipes.json 2>/dev/null | sort -u | head -10

    echo ""
    echo "⚙️ Backend Frameworks:"
    jq -r '.[] | select(.category == "backend" or .tag | test("Laravel|Django|Rails|Express|Spring")) | "  - \(.tag // .title)"' /var/www/recipes.json 2>/dev/null | sort -u | head -10

    echo ""
    echo "📦 All recipes:"
    jq -r '[.[] | .tag // .title] | unique | sort | .[]' /var/www/recipes.json | head -20

    echo ""
    echo "💡 Try searching for one of the above"
    exit 1
fi

# Extract recipe details
TITLE=$(echo "$RECIPE" | jq -r '.title')
TAG=$(echo "$RECIPE" | jq -r '.tag // ""')
DESC=$(echo "$RECIPE" | jq -r '.desc // ""' | sed 's/<[^>]*>//g' | sed 's/&[^;]*;//g')
IMPORT_YAML=$(echo "$RECIPE" | jq -r '.importYaml // empty')
ZEROPS_YML=$(echo "$RECIPE" | jq -r '.zeropsYmlContent // empty')
ZEROPS_YML_URL=$(echo "$RECIPE" | jq -r '.zeropsYmlUrl // empty')

# Display recipe header
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║ ✅ Found Recipe: $TITLE"
echo "╚══════════════════════════════════════════════════════════╝"

[ -n "$TAG" ] && [ "$TAG" != "null" ] && echo "📌 Tag: $TAG"

# Show description
if [ -n "$DESC" ] && [ "$DESC" != "null" ]; then
    echo ""
    echo "📋 DESCRIPTION"
    echo "=============="
    echo "$DESC" | fold -w 70 | sed 's/^/  /'
fi

# Show import YAML
if [ -n "$IMPORT_YAML" ] && [ "$IMPORT_YAML" != "null" ]; then
    echo ""
    echo "📦 SERVICE ARCHITECTURE (Import YAML)"
    echo "===================================="

    # Save to file
    IMPORT_FILE="/tmp/recipe_${MATCHED}_import_$(date +%s).yaml"
    echo "$IMPORT_YAML" > "$IMPORT_FILE"

    # Display with syntax highlighting hints
    echo "$IMPORT_YAML" | head -50

    if [ $(echo "$IMPORT_YAML" | wc -l) -gt 50 ]; then
        echo ""
        echo "... (truncated - see full file)"
    fi

    echo ""
    echo "💾 Saved to: $IMPORT_FILE"

    # Analyze the import structure
    echo ""
    echo "📊 SERVICE ANALYSIS:"

    # Count services by type
    TOTAL_SERVICES=$(echo "$IMPORT_YAML" | yq e '.services | length' 2>/dev/null || echo 0)

    if [ "$TOTAL_SERVICES" -gt 0 ]; then
        echo "  Total services: $TOTAL_SERVICES"

        # Check for specific service types
        DB_COUNT=$(echo "$IMPORT_YAML" | yq e '[.services[] | select(.type | test("postgresql|mysql|mariadb|mongodb"))] | length' 2>/dev/null || echo 0)
        CACHE_COUNT=$(echo "$IMPORT_YAML" | yq e '[.services[] | select(.type | test("redis|keydb|valkey"))] | length' 2>/dev/null || echo 0)
        APP_COUNT=$(echo "$IMPORT_YAML" | yq e '[.services[] | select(.type | test("nodejs|php|python|go|rust|ruby"))] | length' 2>/dev/null || echo 0)

        [ "$DB_COUNT" -gt 0 ] && echo "  - Databases: $DB_COUNT"
        [ "$CACHE_COUNT" -gt 0 ] && echo "  - Cache services: $CACHE_COUNT"
        [ "$APP_COUNT" -gt 0 ] && echo "  - Application services: $APP_COUNT"

        # Check for envSecrets
        if echo "$IMPORT_YAML" | grep -q "envSecrets:"; then
            echo "  - ✓ Uses envSecrets for sensitive data"
        fi

        # Check for HA mode
        if echo "$IMPORT_YAML" | grep -q "mode: HA"; then
            echo "  - ✓ Includes HA (High Availability) services"
        fi
    fi

    echo ""
    echo "🔐 SECURITY NOTES:"
    echo "  1. Review all envSecrets before import"
    echo "  2. Set sensitive values via Zerops GUI after import"
    echo "  3. Never commit actual secrets to git"
    echo "  4. Use service references like \${db_connectionString}"
fi

# Show zerops.yml
if [ -n "$ZEROPS_YML" ] && [ "$ZEROPS_YML" != "null" ]; then
    echo ""
    echo "🚀 DEPLOYMENT CONFIGURATION (zerops.yml)"
    echo "======================================="

    # Save to file
    ZEROPS_FILE="/tmp/recipe_${MATCHED}_zerops_$(date +%s).yml"
    echo "$ZEROPS_YML" > "$ZEROPS_FILE"

    # Display with truncation
    echo "$ZEROPS_YML" | head -80

    if [ $(echo "$ZEROPS_YML" | wc -l) -gt 80 ]; then
        echo ""
        echo "... (truncated - see full file)"
    fi

    echo ""
    echo "💾 Saved to: $ZEROPS_FILE"
fi

# External URL reference
if [ -n "$ZEROPS_YML_URL" ] && [ "$ZEROPS_YML_URL" != "null" ]; then
    echo ""
    echo "📄 Full configuration available at:"
    echo "   $ZEROPS_YML_URL"
fi

# Extract and show key patterns
echo ""
echo "🔧 KEY PATTERNS & BEST PRACTICES"
echo "================================"

if [ -n "$ZEROPS_YML" ] && [ "$ZEROPS_YML" != "null" ]; then
    # Technology stack
    BUILD_BASE=$(echo "$ZEROPS_YML" | yq e '.zerops[0].build.base // .zerops[0].build.base[] // empty' 2>/dev/null | head -1)
    RUN_BASE=$(echo "$ZEROPS_YML" | yq e '.zerops[0].run.base // empty' 2>/dev/null)

    [ -n "$BUILD_BASE" ] && [ "$BUILD_BASE" != "null" ] && echo "• Build environment: $BUILD_BASE"
    [ -n "$RUN_BASE" ] && [ "$RUN_BASE" != "null" ] && echo "• Runtime environment: $RUN_BASE"

    # Key configurations
    echo "$ZEROPS_YML" | grep -q "cache:" && echo "• ✓ Build caching configured"
    echo "$ZEROPS_YML" | grep -q "healthCheck:" && echo "• ✓ Health checks configured"
    echo "$ZEROPS_YML" | grep -q "envVariables:" && echo "• ✓ Environment variables defined"
    echo "$ZEROPS_YML" | grep -q "ports:" && echo "• ✓ HTTP ports exposed"
    echo "$ZEROPS_YML" | grep -q "minContainers:" && echo "• ✓ Auto-scaling configured"

    # Build commands
    echo ""
    echo "📦 Build Process:"
    BUILD_CMDS=$(echo "$ZEROPS_YML" | yq e '.zerops[0].build.buildCommands[]' 2>/dev/null | head -5)
    if [ -n "$BUILD_CMDS" ]; then
        echo "$BUILD_CMDS" | sed 's/^/  - /'
    fi

    # Start command
    START_CMD=$(echo "$ZEROPS_YML" | yq e '.zerops[0].run.start // empty' 2>/dev/null)
    [ -n "$START_CMD" ] && [ "$START_CMD" != "null" ] && echo "" && echo "🚀 Start command: $START_CMD"
fi

# Deployment workflow
echo ""
echo "💡 DEPLOYMENT WORKFLOW"
echo "===================="
echo "1. Review and customize the import YAML"
echo "   - Adjust service names to match your project"
echo "   - Review resource allocations"
echo "   - Check environment variable names"
echo ""
echo "2. Import services:"
echo "   zcli project service-import $IMPORT_FILE --projectId \$projectId"
echo ""
echo "3. Apply platform workarounds:"
echo "   /var/www/init_project.sh"
echo ""
echo "4. Set up your application code:"
echo "   - Use $ZEROPS_FILE as template for zerops.yml"
echo "   - Configure environment variables"
echo "   - Adjust for your specific needs"
echo ""
echo "5. Deploy your application:"
echo "   /var/www/deploy.sh <dev-service-name>"

# Framework-specific tips
echo ""
echo "🎯 FRAMEWORK-SPECIFIC TIPS"
echo "========================="

case "$MATCHED" in
    laravel)
        echo "• Run migrations: php artisan migrate --force"
        echo "• Clear caches: php artisan cache:clear"
        echo "• Generate key: php artisan key:generate"
        echo "• Storage link: php artisan storage:link"
        ;;
    nextjs)
        echo "• Use standalone output for smaller images"
        echo "• Configure ISR cache if needed"
        echo "• Set up proper API routes"
        echo "• Consider static export for better performance"
        ;;
    django)
        echo "• Collect static files: python manage.py collectstatic"
        echo "• Run migrations: python manage.py migrate"
        echo "• Create superuser after deployment"
        echo "• Configure ALLOWED_HOSTS properly"
        ;;
    rails)
        echo "• Precompile assets: rails assets:precompile"
        echo "• Run migrations: rails db:migrate"
        echo "• Set RAILS_ENV=production"
        echo "• Configure secrets properly"
        ;;
    wordpress)
        echo "• Set up wp-config.php with env vars"
        echo "• Configure permalinks after deployment"
        echo "• Set up proper file permissions"
        echo "• Consider object storage for media"
        ;;
esac

# Quick start command
echo ""
echo "🚀 QUICK START"
echo "============="
echo "# Import services now:"
echo "zcli project service-import $IMPORT_FILE --projectId \$projectId"
echo ""
echo "# Then initialize:"
echo "/var/www/init_project.sh"

echo ""
echo "✨ Recipe loaded successfully!"

exit 0
