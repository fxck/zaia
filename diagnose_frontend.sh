#!/bin/bash
set -e
source /var/www/core_utils.sh

[ $# -eq 0 ] && echo "Usage: $0 <url> [--check-console] [--check-network] [--full-analysis]" && exit 1

URL="$1"
shift

CHECK_CONSOLE=false
CHECK_NETWORK=false
FULL_ANALYSIS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --check-console) CHECK_CONSOLE=true; shift ;;
        --check-network) CHECK_NETWORK=true; shift ;;
        --full-analysis) FULL_ANALYSIS=true; shift ;;
        *) shift ;;
    esac
done

[ "$FULL_ANALYSIS" = true ] && CHECK_CONSOLE=true && CHECK_NETWORK=true

echo "🔍 Diagnosing frontend: $URL"

# Run diagnosis with output limiting
RESULT=$(safe_output 200 30 node /var/www/puppeteer_check.js "$URL" \
    $( [ "$CHECK_CONSOLE" = true ] && echo "--check-console" ) \
    $( [ "$CHECK_NETWORK" = true ] && echo "--check-network" ))

# Parse results
CONSOLE_ERRORS=$(echo "$RESULT" | jq -r '.console | length' 2>/dev/null || echo 0)
NETWORK_ERRORS=$(echo "$RESULT" | jq -r '.network | length' 2>/dev/null || echo 0)
RUNTIME_ERRORS=$(echo "$RESULT" | jq -r '.runtime | length' 2>/dev/null || echo 0)

if [ "$CONSOLE_ERRORS" -gt 0 ]; then
    echo "❌ Console Errors ($CONSOLE_ERRORS):"
    echo "$RESULT" | jq -r '.console[]' 2>/dev/null | head -10
fi

if [ "$NETWORK_ERRORS" -gt 0 ]; then
    echo "❌ Network Issues ($NETWORK_ERRORS):"
    echo "$RESULT" | jq -r '.network[] | "\(.status // "FAILED"): \(.url)"' 2>/dev/null | head -10
fi

if [ "$RUNTIME_ERRORS" -gt 0 ]; then
    echo "❌ Runtime Issues ($RUNTIME_ERRORS):"
    echo "$RESULT" | jq -r '.runtime[]' 2>/dev/null | head -10
fi

if [ "$CONSOLE_ERRORS" -eq 0 ] && [ "$NETWORK_ERRORS" -eq 0 ] && [ "$RUNTIME_ERRORS" -eq 0 ]; then
    echo "✅ No frontend issues detected"
else
    echo ""
    echo "💡 Common fixes:"
    echo "  • Console errors: Check for undefined variables, missing imports"
    echo "  • Network 404s: Verify API endpoints and static assets"
    echo "  • CORS errors: Configure proper headers in zerops.yml"
    echo "  • Hydration errors: Ensure server/client rendering match"
fi
