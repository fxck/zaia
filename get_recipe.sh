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

