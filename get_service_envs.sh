#!/bin/bash
set -e

echo "=== FETCHING ENVIRONMENT VARIABLES VIA API ==="

if [ -z "$ZEROPS_ACCESS_TOKEN" ]; then
    echo "❌ ZEROPS_ACCESS_TOKEN not available"
    exit 1
fi

if [ -z "$projectId" ]; then
    echo "❌ projectId not available"
    exit 1
fi

API_URL="https://api.app-prg1.zerops.io/api/rest/public/project/$projectId/env-file-download"
CACHE_FILE="/tmp/current_envs.env"
CACHE_AGE_LIMIT=300  # 5 minutes

# Check if cache exists and is still valid
if [ -f "$CACHE_FILE" ]; then
    CACHE_AGE=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo "0")))
    if [ $CACHE_AGE -lt $CACHE_AGE_LIMIT ]; then
        echo "✅ Using cached environment variables (age: ${CACHE_AGE}s)"

        TOTAL_VARS=$(wc -l < "$CACHE_FILE")
        SERVICE_IDS=$(grep "_serviceId=" "$CACHE_FILE" | wc -l)
        SUBDOMAINS=$(grep "_zeropsSubdomain=" "$CACHE_FILE" | wc -l)

        echo "📊 Summary (cached):"
        echo "  Total variables: $TOTAL_VARS"
        echo "  Service IDs: $SERVICE_IDS"
        echo "  Subdomains: $SUBDOMAINS"

        if [ $SERVICE_IDS -gt 0 ]; then
            echo ""
            echo "🔧 Available Service IDs:"
            grep "_serviceId=" "$CACHE_FILE" | sort
        fi

        if [ $SUBDOMAINS -gt 0 ]; then
            echo ""
            echo "🌐 Available Subdomains:"
            grep "_zeropsSubdomain=" "$CACHE_FILE" | sort
        fi

        echo ""
        echo "Environment variables loaded from cache: $CACHE_FILE"
        exit 0
    else
        echo "Cache expired (age: ${CACHE_AGE}s), refreshing from API..."
    fi
else
    echo "No cache found, fetching from API..."
fi

echo "Fetching environment variables from API..."
if curl -s -H "Authorization: Bearer $ZEROPS_ACCESS_TOKEN" "$API_URL" -o "$CACHE_FILE"; then
    echo "✅ Environment variables fetched successfully"

    TOTAL_VARS=$(wc -l < "$CACHE_FILE")
    SERVICE_IDS=$(grep "_serviceId=" "$CACHE_FILE" | wc -l)
    SUBDOMAINS=$(grep "_zeropsSubdomain=" "$CACHE_FILE" | wc -l)

    echo "📊 Summary:"
    echo "  Total variables: $TOTAL_VARS"
    echo "  Service IDs: $SERVICE_IDS"
    echo "  Subdomains: $SUBDOMAINS"

    if [ $SERVICE_IDS -gt 0 ]; then
        echo ""
        echo "🔧 Available Service IDs:"
        grep "_serviceId=" "$CACHE_FILE" | sort
    fi

    if [ $SUBDOMAINS -gt 0 ]; then
        echo ""
        echo "🌐 Available Subdomains:"
        grep "_zeropsSubdomain=" "$CACHE_FILE" | sort
    fi

    echo ""
    echo "Environment variables cached to: $CACHE_FILE"

else
    echo "❌ Failed to fetch environment variables from API"
    exit 1
fi
