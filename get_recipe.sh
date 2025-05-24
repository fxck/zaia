#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <technology>"
    echo "Examples: nodejs, python, php, go, nextjs, laravel, django"
    exit 1
fi

TECH="$1"
DEBUG_TECH="golang" # Enable debug for "golang"

if [ ! -f /var/www/recipes.json ]; then
    echo "❌ recipes.json not found at /var/www/recipes.json"
    exit 1
fi

fuzzy_match_technology() {
    local input="$1"
    local lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    case "$lower_input" in
        "nodejs"|"node"|"node.js"|"js"|"javascript") echo "Node.js" ;;
        "golang"|"go") echo "Golang" ;;
        "python"|"py"|"python3") echo "Python" ;;
        "dotnet"|".net"|"csharp"|"c#") echo ".NET" ;;
        *) echo "$input" | sed 's/^./\U&/' ;;
    esac
}

MAPPED_TECH=$(fuzzy_match_technology "$TECH")
echo "🔍 Searching for '$TECH' (mapped to '$MAPPED_TECH')..."

RECIPE="" # Will store the JSON string of the found recipe
JQ_ERROR_OUTPUT="" # To capture any jq errors

# $1: jq query string, expected to return a single object or null
# $2: value for the --arg tech
run_jq_query() {
    local query_string="$1"
    local tech_arg="$2"
    local result_candidate
    local error_log="/tmp/jq_error_$$_${RANDOM}.log"

    trap 'rm -f "$error_log"' EXIT INT TERM HUP
    rm -f "$error_log"

    # The jq query itself should now ensure only one object (or null) is returned.
    # Example: 'first(.[] | select(.id == $tech))'
    result_candidate=$(jq --arg tech "$tech_arg" "$query_string" /var/www/recipes.json 2>"$error_log")

    JQ_ERROR_OUTPUT=$(cat "$error_log" 2>/dev/null)
    rm -f "$error_log"

    if [ -n "$JQ_ERROR_OUTPUT" ]; then
        echo "JQ Error during query '$query_string' for '$tech_arg': $JQ_ERROR_OUTPUT"
    fi
    # If jq returns literal 'null', ensure it's an empty string for shell checks, or handle 'null' string later.
    # For now, pass it as is. jq returning 'null' is valid JSON.
    echo "$result_candidate"
}

# --- New Search Order ---

# 1. Exact ID match (uses original TECH input)
if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: Trying exact ID match for '$TECH'"; fi
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.id == $tech))' "$TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: RECIPE after exact ID: ---$RECIPE---"; fi
fi

# 2. Exact Tag match (uses MAPPED_TECH)
if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: Trying exact tag match for '$MAPPED_TECH'"; fi
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.tag == $tech))' "$MAPPED_TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: RECIPE after exact tag: ---$RECIPE---"; fi
fi

# 3. Exact title match (uses MAPPED_TECH)
if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: Trying exact title match for '$MAPPED_TECH'"; fi
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.title == $tech))' "$MAPPED_TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: RECIPE after exact title: ---$RECIPE---"; fi
fi

# 4. Case-insensitive title match (uses MAPPED_TECH)
if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: Trying case-insensitive title match for '$MAPPED_TECH'"; fi
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.title | ascii_downcase == ($tech | ascii_downcase)))' "$MAPPED_TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: RECIPE after case-insensitive title: ---$RECIPE---"; fi
fi

# 5. Partial match in tag (uses MAPPED_TECH)
if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: Trying partial tag match for '$MAPPED_TECH'"; fi
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.tag | contains($tech)))' "$MAPPED_TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: RECIPE after partial tag: ---$RECIPE---"; fi
fi

# 6. Partial match in title (uses MAPPED_TECH)
if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: Trying partial title match for '$MAPPED_TECH'"; fi
    TEMP_RECIPE=$(run_jq_query 'first(.[] | select(.title | contains($tech)))' "$MAPPED_TECH")
    if [ -n "$TEMP_RECIPE" ] && [ "$TEMP_RECIPE" != "null" ]; then RECIPE="$TEMP_RECIPE"; fi
    if [ "$TECH" == "$DEBUG_TECH" ]; then echo "DEBUG: RECIPE after partial title: ---$RECIPE---"; fi
fi

if [ -z "$RECIPE" ] || [ "$RECIPE" == "null" ]; then
    echo "❌ Recipe not found for '$TECH' (mapped to '$MAPPED_TECH')."
    echo "   Searched by ID, Tag, Title, and partial matches."
    if [ -n "$JQ_ERROR_OUTPUT" ]; then
        echo "   Last JQ error encountered during search: $JQ_ERROR_OUTPUT"
    fi
    echo ""
    echo "Available recipes (first 20 titles from recipes.json):"
    jq -r '.[].title' /var/www/recipes.json | sort | uniq | head -20
    exit 1
fi

if [ "$TECH" == "$DEBUG_TECH" ]; then
  echo "DEBUG: Final RECIPE variable before pretty-printing: ---$RECIPE---"
fi

RECIPE_TITLE_CANDIDATE=$(echo "$RECIPE" | jq -r '.title' 2>/dev/null)
if [ "$?" -ne 0 ] || [ "$RECIPE_TITLE_CANDIDATE" == "null" ] || [ -z "$RECIPE_TITLE_CANDIDATE" ]; then
    echo "Error: The found RECIPE data seems malformed, does not contain a '.title', or title is null/empty."
    echo "Problematic RECIPE content was: ---$RECIPE---"
    exit 1
fi

echo "✅ Found recipe: $RECIPE_TITLE_CANDIDATE"
echo "$RECIPE" | jq . # This is the command that failed for 'golang'
JQ_PRETTY_PRINT_STATUS=$?

if [ $JQ_PRETTY_PRINT_STATUS -ne 0 ]; then
    echo "JQ Error during final pretty-print (status: $JQ_PRETTY_PRINT_STATUS)."
    echo "Problematic RECIPE content was: ---$RECIPE---"
    exit 1
fi
