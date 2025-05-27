#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# --- Usage function ---
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

# --- Argument check ---
if [ $# -eq 0 ]; then
    usage
fi
SEARCH_TERM_ORIGINAL="$1"

# --- Check for fzf (fuzzy finder) ---
if ! command -v fzf &> /dev/null; then
    echo "❌ fzf (fuzzy finder) is not installed. It's required for fuzzy searching." >&2
    echo "💡 Please install it using: sudo apt-get update && sudo apt-get install fzf" >&2
    exit 1
fi

# --- recipes.json existence check and fallback ---
RECIPES_FILE="/var/www/recipes.json"
if [ ! -f "$RECIPES_FILE" ]; then
    echo "❌ $RECIPES_FILE not found" >&2
    echo ""
    if [[ "$SEARCH_TERM_ORIGINAL" =~ ^(node|nodejs|typescript|ts)$ ]]; then
        echo "📋 Creating basic Node.js TypeScript configuration..." >&2
        # This fallback is from the original script provided by the user.
        cat << 'EOF'
╔══════════════════════════════════════════════════════════╗
║ ✅ Fallback Recipe: Node.js TypeScript                    ║
╚══════════════════════════════════════════════════════════╝

📦 SERVICE ARCHITECTURE (Import YAML)
====================================
services:
  - hostname: db
    type: postgresql@16
    mode: NON_HA
    priority: 100
  - hostname: apidev
    type: nodejs@22
    startWithoutCode: true
    priority: 50
    envSecrets:
      JWT_SECRET: <@generateRandomString(<32>)>
      DATABASE_URL: ${db_connectionString}
  - hostname: api
    type: nodejs@22
    startWithoutCode: true
    priority: 40
    envSecrets:
      JWT_SECRET: <@generateRandomString(<32>)>
      DATABASE_URL: ${db_connectionString}

🚀 DEPLOYMENT CONFIGURATION (zerops.yml)
=======================================
zerops:
  - setup: apidev
    build:
      base: nodejs@22
      buildCommands:
        - npm ci
        - npm run build
    run:
      base: nodejs@22
      ports:
        - port: 3000
          httpSupport: true
      envVariables:
        PORT: 3000
        NODE_ENV: development
      start: npm run dev
  - setup: api
    build:
      base: nodejs@22
      buildCommands:
        - npm ci --production=false
        - npm run build
        - npm prune --production
    run:
      base: nodejs@22
      ports:
        - port: 3000
          httpSupport: true
      envVariables:
        PORT: 3000
        NODE_ENV: production
      start: node dist/index.js

💡 Save the above configurations to files and import them.
EOF
        exit 0
    fi
    echo "   No recipes available for '$SEARCH_TERM_ORIGINAL'" >&2
    exit 1
fi

echo "🔍 Fuzzy searching for '$SEARCH_TERM_ORIGINAL'..."

# --- Prepare data for fzf ---
# Create a list where each line is: "recipe_id<TAB>searchable_text"
# Searchable text includes title, tag, slug, and id itself for good measure.
# We use jq to construct this.
FZF_INPUT_LIST=$(jq -r '.[] | select(.listed != false) | "\(.id)\t\(.title // "") \(.tag // "") \(.slug // "") \(.id)"' "$RECIPES_FILE")

if [ -z "$FZF_INPUT_LIST" ]; then
    echo "❌ No searchable recipe data could be extracted from $RECIPES_FILE." >&2
    exit 1
fi

# --- Use fzf to find the best match ---
# fzf --filter "$QUERY" will output matching lines, best matches usually first.
# We take the first line using head -n 1.
# --nth=2.. tells fzf to perform the search on the text starting from the 2nd field (after the first tab).
BEST_MATCH_LINE=$(echo -e "$FZF_INPUT_LIST" | fzf --filter="$SEARCH_TERM_ORIGINAL" --delimiter='\t' --nth=2.. --no-sort --select-1 --query="$SEARCH_TERM_ORIGINAL" 2>/dev/null || true)
# Added --select-1 and --query to attempt to make fzf non-interactive and pick the best.
# If fzf with --filter still requires interaction or doesn't pick one, a simpler `head -n 1` after default filter output might be needed.
# A more robust way for non-interactive top match:
BEST_MATCH_LINE=$(echo -e "$FZF_INPUT_LIST" | fzf --filter="$SEARCH_TERM_ORIGINAL" --delimiter='\t' --nth=2.. | head -n 1)


if [ -z "$BEST_MATCH_LINE" ]; then
    echo "❌ Recipe not found for '$SEARCH_TERM_ORIGINAL' using fuzzy search."
    echo ""
    echo "📚 Available recipes (sample):"
    jq -r '[.[] | select(.listed != false) | .tag // .title // .id] | unique | sort | .[]' "$RECIPES_FILE" 2>/dev/null | head -20 || echo " (could not list recipes)"
    echo ""
    echo "💡 Try a different search term."
    exit 1
fi

# Extract the recipe ID (the part before the first tab)
MATCHED_RECIPE_ID=$(echo "$BEST_MATCH_LINE" | cut -d$'\t' -f1)

echo "✅ Best match ID found by fzf: $MATCHED_RECIPE_ID"

# --- Fetch the full recipe object using the MATCHED_RECIPE_ID ---
JQ_FILTER_BY_ID='.[] | select(.id == $id_to_find)'
JQ_STDERR_FILE=$(mktemp)
RECIPE_JSON_STRING=$(jq -c --arg id_to_find "$MATCHED_RECIPE_ID" "$JQ_FILTER_BY_ID" "$RECIPES_FILE" 2> "$JQ_STDERR_FILE")
JQ_ACTUAL_EXIT_CODE=$?

# --- Debugging output for the final jq call ---
echo "--- Debug Info (Final Fetch) ---"
echo "JQ Actual Exit Code (fetch by ID): $JQ_ACTUAL_EXIT_CODE"
if [ -s "$JQ_STDERR_FILE" ]; then
    echo "JQ Stderr (fetch by ID):"
    cat "$JQ_STDERR_FILE"
else
    echo "JQ Stderr (fetch by ID): (empty)"
fi
echo "Fetched Recipe JSON String: [$RECIPE_JSON_STRING]"
echo "--- End Debug Info ---"

rm -f "$JQ_STDERR_FILE"

if [ "$JQ_ACTUAL_EXIT_CODE" -ne 0 ]; then
    echo "❌ Error fetching recipe details for ID '$MATCHED_RECIPE_ID'." >&2
    exit 1
fi

if [ -z "$RECIPE_JSON_STRING" ] || [ "$RECIPE_JSON_STRING" = "null" ]; then
    echo "❌ Could not retrieve details for recipe ID '$MATCHED_RECIPE_ID' (was: $BEST_MATCH_LINE)." >&2
    exit 1
fi

# --- If recipe found and fetched, extract details ---
echo ""
# echo "Found recipe data. Parsing details..."

EXT_TITLE=$(echo "$RECIPE_JSON_STRING" | jq -r '.title // "Error: Title Missing"')
EXT_TAG=$(echo "$RECIPE_JSON_STRING" | jq -r '.tag // ""')
EXT_DESC_RAW=$(echo "$RECIPE_JSON_STRING" | jq -r '.desc // ""')
EXT_DESC=$(echo "$EXT_DESC_RAW" | sed 's/<[^>]*>//g' | sed 's/&[^;]*;//g')
EXT_IMPORT_YAML=$(echo "$RECIPE_JSON_STRING" | jq -r '.importYaml // empty')
EXT_ZEROPS_YML_CONTENT=$(echo "$RECIPE_JSON_STRING" | jq -r '.zeropsYmlContent // empty')
EXT_ZEROPS_YML_URL=$(echo "$RECIPE_JSON_STRING" | jq -r '.zeropsYmlUrl // empty')

if [ "$EXT_TITLE" = "Error: Title Missing" ] && ! echo "$RECIPE_JSON_STRING" | jq -e '.title' > /dev/null 2>&1 ; then
    echo "❌ Failed to parse critical details (like title) from the fetched recipe JSON string." >&2
    echo "Original recipe string was: $RECIPE_JSON_STRING" >&2
    exit 1
fi

# --- Display recipe (sections copied & adapted from original script) ---
echo "╔══════════════════════════════════════════════════════════╗"
echo "║ ✅ Found Recipe (Fuzzy Match): $EXT_TITLE"
echo "╚══════════════════════════════════════════════════════════╝"

if [ -n "$EXT_TAG" ]; then
    echo "📌 Tag: $EXT_TAG"
fi

if [ -n "$EXT_DESC" ]; then
    echo ""
    echo "📋 DESCRIPTION"
    echo "=============="
    echo "$EXT_DESC" | fold -s -w 70 | sed 's/^/  /'
fi

IMPORT_FILE_PATH=""
if [ -n "$EXT_IMPORT_YAML" ] && [ "$EXT_IMPORT_YAML" != "empty" ]; then
    echo ""
    echo "📦 SERVICE ARCHITECTURE (Import YAML)"
    echo "===================================="
    # Use SEARCH_TERM_ORIGINAL or MATCHED_RECIPE_ID for temp filename uniqueness
    IMPORT_FILE_PATH="/tmp/recipe_$(echo "$SEARCH_TERM_ORIGINAL" | tr -dc '[:alnum:]')_import_$(date +%s).yaml"
    echo "$EXT_IMPORT_YAML" > "$IMPORT_FILE_PATH"
    echo "$EXT_IMPORT_YAML" | head -50
    if [ $(echo "$EXT_IMPORT_YAML" | wc -l) -gt 50 ]; then echo ""; echo "... (truncated - see full file)"; fi
    echo ""; echo "💾 Saved to: $IMPORT_FILE_PATH"

    if command -v yq >/dev/null 2>&1; then
        echo ""; echo "📊 SERVICE ANALYSIS (requires yq):"
        TOTAL_SERVICES=$(yq e '.services | length' "$IMPORT_FILE_PATH" 2>/dev/null || echo 0)
        if [ "$TOTAL_SERVICES" -gt 0 ]; then
            echo "  Total services: $TOTAL_SERVICES"
            DB_COUNT=$(yq e '[.services[] | select(.type | test("postgresql|mysql|mariadb|mongodb"))] | length' "$IMPORT_FILE_PATH" 2>/dev/null || echo 0)
            CACHE_COUNT=$(yq e '[.services[] | select(.type | test("redis|keydb|valkey"))] | length' "$IMPORT_FILE_PATH" 2>/dev/null || echo 0)
            APP_COUNT=$(yq e '[.services[] | select(.type | test("nodejs|php|python|go|rust|ruby"))] | length' "$IMPORT_FILE_PATH" 2>/dev/null || echo 0)
            [ "$DB_COUNT" -gt 0 ] && echo "  - Databases: $DB_COUNT"
            [ "$CACHE_COUNT" -gt 0 ] && echo "  - Cache services: $CACHE_COUNT"
            [ "$APP_COUNT" -gt 0 ] && echo "  - Application services: $APP_COUNT"
            if echo "$EXT_IMPORT_YAML" | grep -q "envSecrets:"; then echo "  - ✓ Uses envSecrets for sensitive data"; fi
            if echo "$EXT_IMPORT_YAML" | grep -q "mode: HA"; then echo "  - ✓ Includes HA (High Availability) services"; fi
        else echo "  No services found in import YAML for analysis."; fi
    else echo "  (yq not installed, skipping service analysis of Import YAML)"; fi
    echo ""; echo "🔐 SECURITY NOTES:"; echo "  1. Review all envSecrets before import"; echo "  2. Set sensitive values via Zerops GUI after import"; echo "  3. Never commit actual secrets to git"; echo "  4. Use service references like \${db_connectionString}"
fi

ZEROPS_FILE_PATH=""
if [ -n "$EXT_ZEROPS_YML_CONTENT" ] && [ "$EXT_ZEROPS_YML_CONTENT" != "empty" ]; then
    echo ""; echo "🚀 DEPLOYMENT CONFIGURATION (zerops.yml content)"; echo "==============================================="
    ZEROPS_FILE_PATH="/tmp/recipe_$(echo "$SEARCH_TERM_ORIGINAL" | tr -dc '[:alnum:]')_zerops_$(date +%s).yml"
    echo "$EXT_ZEROPS_YML_CONTENT" > "$ZEROPS_FILE_PATH"
    echo "$EXT_ZEROPS_YML_CONTENT" | head -80
    if [ $(echo "$EXT_ZEROPS_YML_CONTENT" | wc -l) -gt 80 ]; then echo ""; echo "... (truncated - see full file)"; fi
    echo ""; echo "💾 Saved to: $ZEROPS_FILE_PATH"
fi

if [ -n "$EXT_ZEROPS_YML_URL" ] && [ "$EXT_ZEROPS_YML_URL" != "empty" ]; then
    echo ""; echo "📄 Full zerops.yml configuration also available at:"; echo "   $EXT_ZEROPS_YML_URL"
fi

if [ -n "$EXT_ZEROPS_YML_CONTENT" ] && [ "$EXT_ZEROPS_YML_CONTENT" != "empty" ]; then
    echo ""; echo "🔧 KEY PATTERNS & BEST PRACTICES (from zerops.yml content)"; echo "======================================================="
    if command -v yq >/dev/null 2>&1; then
        BUILD_BASE=$(echo "$EXT_ZEROPS_YML_CONTENT" | yq e '.zerops[0].build.base // .zerops[0].build.base[] // ""' 2>/dev/null | head -1)
        RUN_BASE=$(echo "$EXT_ZEROPS_YML_CONTENT" | yq e '.zerops[0].run.base // ""' 2>/dev/null)
        [ -n "$BUILD_BASE" ] && [ "$BUILD_BASE" != "\"\"" ] && echo "• Build environment: $BUILD_BASE"
        [ -n "$RUN_BASE" ] && [ "$RUN_BASE" != "\"\"" ] && echo "• Runtime environment: $RUN_BASE"
        if echo "$EXT_ZEROPS_YML_CONTENT" | grep -q "cache:"; then echo "• ✓ Build caching potentially configured"; fi
        if echo "$EXT_ZEROPS_YML_CONTENT" | grep -q "healthCheck:"; then echo "• ✓ Health checks potentially configured"; fi
        if echo "$EXT_ZEROPS_YML_CONTENT" | grep -q "envVariables:"; then echo "• ✓ Environment variables potentially defined"; fi
        if echo "$EXT_ZEROPS_YML_CONTENT" | grep -q "ports:"; then echo "• ✓ HTTP ports potentially exposed"; fi
        if echo "$EXT_ZEROPS_YML_CONTENT" | grep -q "minContainers:"; then echo "• ✓ Auto-scaling (minContainers) potentially configured"; fi
        echo ""; echo "📦 Build Process (sample from first setup):"
        BUILD_CMDS=$(echo "$EXT_ZEROPS_YML_CONTENT" | yq e '.zerops[0].build.buildCommands[]?' 2>/dev/null | head -5)
        if [ -n "$BUILD_CMDS" ] && [ "$BUILD_CMDS" != "null" ]; then echo "$BUILD_CMDS" | sed 's/^/  - /'; else echo "  (No buildCommands found in sample)"; fi
        START_CMD=$(echo "$EXT_ZEROPS_YML_CONTENT" | yq e '.zerops[0].run.start // ""' 2>/dev/null)
        [ -n "$START_CMD" ] && [ "$START_CMD" != "\"\"" ] && echo "" && echo "🚀 Start command (sample from first setup): $START_CMD"
    else echo "  (yq not installed, skipping key patterns analysis from zerops.yml content)"; fi
fi

# Deployment workflow
echo ""; echo "💡 DEPLOYMENT WORKFLOW"; echo "===================="
echo "1. Review and customize the import YAML (saved to ${IMPORT_FILE_PATH:-not generated if no import YAML})"
# ... (rest of deployment workflow from original script)
echo "   - Adjust service names, resource allocations, and environment variables."
echo ""; echo "2. Import services (if YAML was generated):"
if [ -n "$IMPORT_FILE_PATH" ]; then echo "   zcli project service-import \"$IMPORT_FILE_PATH\" --projectId \$projectId"; else echo "   (No import YAML to import for this recipe)"; fi
echo ""; echo "4. Set up your application code:"
if [ -n "$ZEROPS_FILE_PATH" ]; then echo "   - Use $ZEROPS_FILE_PATH (saved zerops.yml content) as a template."; elif [ -n "$EXT_ZEROPS_YML_URL" ]; then echo "   - Refer to $EXT_ZEROPS_YML_URL for the zerops.yml structure."; else echo "   - Create or adapt your zerops.yml."; fi
echo "   - Configure environment variables in Zerops GUI or your zerops.yml."

# Framework-specific tips
echo ""; echo "🎯 FRAMEWORK-SPECIFIC TIPS"; echo "========================="
case "$MATCHED_RECIPE_ID" in # Use the actual ID found for more specific tips if needed, or $EXT_TAG
    laravel) echo "• Run migrations: php artisan migrate --force"; echo "• Clear caches: php artisan cache:clear"; echo "• Generate key: php artisan key:generate"; echo "• Storage link: php artisan storage:link" ;;
    nextjs) echo "• Use standalone output for smaller images"; echo "• Configure ISR cache if needed"; echo "• Set up proper API routes"; echo "• Consider static export for better performance" ;;
    django) echo "• Collect static files: python manage.py collectstatic"; echo "• Run migrations: python manage.py migrate"; echo "• Create superuser after deployment"; echo "• Configure ALLOWED_HOSTS properly" ;;
    rails) echo "• Precompile assets: rails assets:precompile"; echo "• Run migrations: rails db:migrate"; echo "• Set RAILS_ENV=production"; echo "• Configure secrets properly" ;;
    wordpress) echo "• Set up wp-config.php with env vars"; echo "• Configure permalinks after deployment"; echo "• Set up proper file permissions"; echo "• Consider object storage for media" ;;
    *) echo "• Review the specific documentation for '$EXT_TITLE' for deployment best practices." ;;
esac

# Quick start command
if [ -n "$IMPORT_FILE_PATH" ]; then
    echo ""; echo "🚀 QUICK START"; echo "============="
    echo "# Import services now (if YAML was generated):"
    echo "zcli project service-import \"$IMPORT_FILE_PATH\" --projectId \$projectId"
fi

echo ""
echo "✨ Recipe loaded successfully!"
exit 0
