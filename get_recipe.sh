#!/bin/bash
set -e
source /var/www/core_utils.sh

usage() {
    echo "Usage: $0 <framework/technology>"
    echo "Examples:"
    echo "  $0 laravel      # Get Laravel recipe"
    echo "  $0 next.js      # Get Next.js recipe"
    echo "  $0 django       # Get Django recipe"
    echo ""
    echo "Recipes provide:"
    echo "  - Import YAML for quick setup"
    echo "  - Production-ready zerops.yml"
    echo "  - Best practices and patterns"
    exit 1
}

[ $# -eq 0 ] && usage

SEARCH_TERM="$1"

if [ ! -f /var/www/recipes.json ]; then
    echo "❌ recipes.json not found"
    exit 1
fi

# Fuzzy match technology names
fuzzy_match() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')

    case "$lower_input" in
        laravel*) echo "laravel" ;;
        next*|nextjs) echo "nextjs" ;;
        django*) echo "django" ;;
        nuxt*) echo "nuxtjs" ;;
        nest*) echo "nestjs" ;;
        express*) echo "express" ;;
        fastapi*) echo "fastapi" ;;
        rails*|ruby*) echo "rails" ;;
        vue*) echo "vuejs" ;;
        react*) echo "react" ;;
        angular*) echo "angular" ;;
        strapi*) echo "strapi" ;;
        wordpress*) echo "wordpress" ;;
        *) echo "$lower_input" ;;
    esac
}

MATCHED_TERM=$(fuzzy_match "$SEARCH_TERM")
echo "🔍 Searching for '$SEARCH_TERM' (matched: '$MATCHED_TERM')..."

# Search for recipe
RECIPE=$(jq -r --arg term "$MATCHED_TERM" '
    .[] | select(
        .id == $term or
        .slug == $term or
        (.tag | ascii_downcase) == $term or
        (.title | ascii_downcase | contains($term))
    ) | . // empty
' /var/www/recipes.json | head -1)

if [ -z "$RECIPE" ] || [ "$RECIPE" = "null" ]; then
    echo "❌ Recipe not found for '$SEARCH_TERM'"
    echo ""
    echo "Available recipes:"
    jq -r '.[].tag // .[].title' /var/www/recipes.json | sort -u | head -20
    exit 1
fi

# Extract recipe details
TITLE=$(echo "$RECIPE" | jq -r '.title')
TAG=$(echo "$RECIPE" | jq -r '.tag')
DESC=$(echo "$RECIPE" | jq -r '.desc' | sed 's/<[^>]*>//g')
IMPORT_YAML=$(echo "$RECIPE" | jq -r '.importYaml // empty')
ZEROPS_YML=$(echo "$RECIPE" | jq -r '.zeropsYmlContent // empty')
ZEROPS_YML_URL=$(echo "$RECIPE" | jq -r '.zeropsYmlUrl // empty')

echo "✅ Found recipe: $TITLE"
echo ""
echo "📋 RECIPE: $TAG"
echo "================================"
echo "$DESC" | fold -w 80
echo ""

if [ -n "$IMPORT_YAML" ] && [ "$IMPORT_YAML" != "null" ]; then
    echo "📦 IMPORT YAML:"
    echo "--------------------------------"
    echo "$IMPORT_YAML" | head -30
    echo ""
    echo "💡 To use this import:"
    echo "   1. Save the import YAML to a file"
    echo "   2. Review and adjust service names"
    echo "   3. Set sensitive values via GUI after import"
    echo ""
fi

if [ -n "$ZEROPS_YML" ] && [ "$ZEROPS_YML" != "null" ]; then
    echo "🚀 ZEROPS.YML (for deployment):"
    echo "--------------------------------"
    echo "$ZEROPS_YML" | head -50
    if [ $(echo "$ZEROPS_YML" | wc -l) -gt 50 ]; then
        echo "... (truncated, see full version below)"
    fi
    echo ""
fi

if [ -n "$ZEROPS_YML_URL" ] && [ "$ZEROPS_YML_URL" != "null" ]; then
    echo "📄 Full zerops.yml available at:"
    echo "   $ZEROPS_YML_URL"
    echo ""
fi

echo "🔧 KEY PATTERNS FROM THIS RECIPE:"
echo "--------------------------------"

# Extract key patterns
if [ -n "$ZEROPS_YML" ] && [ "$ZEROPS_YML" != "null" ]; then
    # Check for build base
    if echo "$ZEROPS_YML" | grep -q "build:"; then
        BUILD_BASE=$(echo "$ZEROPS_YML" | yq e '.zerops[0].build.base[]? // empty' 2>/dev/null | head -1)
        [ -n "$BUILD_BASE" ] && echo "• Build base: $BUILD_BASE"
    fi

    # Check for runtime base
    RUN_BASE=$(echo "$ZEROPS_YML" | yq e '.zerops[0].run.base // empty' 2>/dev/null)
    [ -n "$RUN_BASE" ] && [ "$RUN_BASE" != "null" ] && echo "• Runtime base: $RUN_BASE"

    # Check for start command
    START_CMD=$(echo "$ZEROPS_YML" | yq e '.zerops[0].run.start // empty' 2>/dev/null)
    [ -n "$START_CMD" ] && [ "$START_CMD" != "null" ] && echo "• Start command: $START_CMD"

    # Check for ports
    if echo "$ZEROPS_YML" | grep -q "ports:"; then
        echo "• Exposes ports for HTTP traffic"
    fi

    # Check for health checks
    if echo "$ZEROPS_YML" | grep -q "healthCheck:"; then
        echo "• Includes health check configuration"
    fi

    # Check for caching
    if echo "$ZEROPS_YML" | grep -q "cache:"; then
        echo "• Build caching configured"
    fi
fi

echo ""
echo "💡 USAGE TIPS:"
echo "• Study the import YAML for service architecture"
echo "• Review zerops.yml for deployment configuration"
echo "• Note environment variable patterns"
echo "• Check for database/cache service integration"
echo "• Observe security practices (envSecrets usage)"

# Save recipe to temp file for reference
TEMP_FILE="/tmp/recipe_${MATCHED_TERM}_$(date +%s).json"
echo "$RECIPE" > "$TEMP_FILE"
echo ""
echo "📁 Full recipe saved to: $TEMP_FILE"
