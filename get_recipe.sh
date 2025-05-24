#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <technology>"
    echo "Examples: nodejs, nodejs@22, python, php, go, nextjs, laravel, django"
    echo "Note: For managed services (postgresql, redis, etc.), recipes are not needed"
    exit 1
fi

TECH="$1"

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

if ! is_runtime_service "$TECH"; then
    echo "ℹ️  '$TECH' is a managed service and does not require a recipe."
    echo "   Managed services are created with simple import YAML containing only type and mode."
    echo ""
    echo "Example minimal import for $TECH:"
    cat << EOF
services:
  - hostname: mydb
    type: $TECH
    mode: NON_HA
EOF
    echo ""
    echo "✅ No recipe needed - use the minimal import pattern above"
    exit 0
fi

if [ ! -f /var/www/recipes.json ]; then
    echo "❌ recipes.json not found at /var/www/recipes.json"
    exit 1
fi

fuzzy_match_technology() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    local base_tech=$(echo "$lower_input" | cut -d@ -f1)

    case "$base_tech" in
        "nodejs"|"node"|"node.js"|"js"|"javascript") echo "Node.js" ;;
        "golang"|"go") echo "Golang" ;;
        "python"|"py"|"python3") echo "Python" ;;
        "dotnet"|".net"|"csharp"|"c#") echo ".NET" ;;
        "php") echo "PHP" ;;
        "rust") echo "Rust" ;;
        "java") echo "Java" ;;
        "ruby") echo "Ruby" ;;
        "elixir") echo "Elixir" ;;
        "gleam") echo "Gleam" ;;
        "bun") echo "Bun" ;;
        "deno") echo "Deno" ;;
        "nextjs"|"next.js"|"next") echo "Next.js" ;;
        "laravel") echo "Laravel" ;;
        "django") echo "Django" ;;
        "static"|"html") echo "Static" ;;
        *)
            echo "$base_tech" | sed 's/^./\U&/'
            ;;
    esac
}

MAPPED_TECH=$(fuzzy_match_technology "$TECH")
echo "🔍 Searching for '$TECH' (mapped to '$MAPPED_TECH')..."

RECIPE=""

run_jq_query() {
    local query_string="$1"
    local tech_arg="$2"
    local result_candidate

    result_candidate=$(jq --arg tech "$tech_arg" "$query_string" /var/www/recipes.json 2>/dev/null)
    echo "$result_candidate"
}

if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.id == $tech))' "$TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
fi

if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    BASE_TECH=$(echo "$TECH" | cut -d@ -f1)
    if [ "$BASE_TECH" != "$TECH" ]; then
        TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.id == $tech))' "$BASE_TECH")
        if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
    fi
fi

if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.tag == $tech))' "$MAPPED_TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
fi

if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.title == $tech))' "$MAPPED_TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
fi

if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.title | ascii_downcase == ($tech | ascii_downcase)))' "$MAPPED_TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
fi

if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    echo "❌ Recipe not found for '$TECH' (mapped to '$MAPPED_TECH')."
    echo ""
    echo "Available recipes (first 20 titles from recipes.json):"
    jq -r '.[].title' /var/www/recipes.json | sort | uniq | head -20
    exit 1
fi

RECIPE_TITLE_CANDIDATE=$(echo "$RECIPE" | jq -r '.title' 2>/dev/null)
if [ "$?" -ne 0 ] || [ "$RECIPE_TITLE_CANDIDATE" == "null" ] || [ -z "$RECIPE_TITLE_CANDIDATE" ]; then
    echo "Error: The found RECIPE data seems malformed."
    exit 1
fi

echo "✅ Found recipe: $RECIPE_TITLE_CANDIDATE"
echo ""
echo "📝 NOTE: This recipe is for REFERENCE ONLY."
echo "   Use the zeropsYmlContent for deployment configuration."
echo "   Service creation uses minimal import YAML with startWithoutCode: true"
echo ""
echo "$RECIPE" | jq .
