#!/bin/bash
set -e
source /var/www/core_utils.sh

usage() {
    echo "Usage: $0 <url> [options]"
    echo ""
    echo "Options:"
    echo "  --check-console      Check browser console errors"
    echo "  --check-network      Check network/resource loading errors"
    echo "  --full-analysis      Enable all checks (console + network)"
    echo "  --save-screenshot    Save screenshot of the page"
    echo "  --check-performance  Basic performance metrics"
    echo ""
    echo "Examples:"
    echo "  $0 https://myapp.app.zerops.io"
    echo "  $0 https://myapp.app.zerops.io --full-analysis"
    echo "  $0 https://myapp.app.zerops.io --check-console --save-screenshot"
    exit 1
}

[ $# -eq 0 ] && usage

URL="$1"
shift

# Parse options
CHECK_CONSOLE=false
CHECK_NETWORK=false
SAVE_SCREENSHOT=false
CHECK_PERFORMANCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --check-console) CHECK_CONSOLE=true; shift ;;
        --check-network) CHECK_NETWORK=true; shift ;;
        --full-analysis)
            CHECK_CONSOLE=true
            CHECK_NETWORK=true
            CHECK_PERFORMANCE=true
            shift ;;
        --save-screenshot) SAVE_SCREENSHOT=true; shift ;;
        --check-performance) CHECK_PERFORMANCE=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Validate URL
if ! [[ "$URL" =~ ^https?:// ]]; then
    echo "❌ Invalid URL format. Must start with http:// or https://"
    exit 1
fi

echo "╔══════════════════════════════════════════════════════════╗"
echo "║              FRONTEND DIAGNOSIS                           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "🔍 URL: $URL"
echo "⚙️ Checks enabled:"
[ "$CHECK_CONSOLE" = true ] && echo "  ✓ Console errors"
[ "$CHECK_NETWORK" = true ] && echo "  ✓ Network issues"
[ "$CHECK_PERFORMANCE" = true ] && echo "  ✓ Performance metrics"
[ "$SAVE_SCREENSHOT" = true ] && echo "  ✓ Screenshot capture"

# Build puppeteer arguments
ARGS=""
[ "$CHECK_CONSOLE" = true ] && ARGS="$ARGS --check-console"
[ "$CHECK_NETWORK" = true ] && ARGS="$ARGS --check-network"
[ "$CHECK_PERFORMANCE" = true ] && ARGS="$ARGS --check-performance"
[ "$SAVE_SCREENSHOT" = true ] && ARGS="$ARGS --save-screenshot"

# Run puppeteer diagnosis
echo ""
echo "🌐 Running browser diagnostics..."
echo "================================"

RESULT_FILE="/tmp/frontend_diagnosis_$$.json"
SCREENSHOT_FILE="/tmp/screenshot_$(date +%s).png"

# Execute with timeout and output limiting
if ! safe_output 1000 60 node /var/www/puppeteer_check.js "$URL" $ARGS --screenshot-path "$SCREENSHOT_FILE" > "$RESULT_FILE" 2>&1; then
    echo "❌ Diagnosis failed"
    echo ""
    echo "Error output:"
    cat "$RESULT_FILE" | head -50
    rm -f "$RESULT_FILE"
    exit 1
fi

# Check if we got valid JSON
if ! jq empty "$RESULT_FILE" 2>/dev/null; then
    echo "❌ Invalid diagnosis output"
    echo "Raw output:"
    cat "$RESULT_FILE" | head -50
    rm -f "$RESULT_FILE"
    exit 1
fi

# Parse and display results
echo "✅ Diagnosis complete"
echo ""

# Console Errors
if [ "$CHECK_CONSOLE" = true ]; then
    CONSOLE_ERRORS=$(jq -r '.console | length' "$RESULT_FILE" 2>/dev/null || echo 0)

    if [ "$CONSOLE_ERRORS" -gt 0 ]; then
        echo "❌ CONSOLE ERRORS ($CONSOLE_ERRORS found)"
        echo "================================"
        jq -r '.console[] | if type == "object" then .text // . else . end' "$RESULT_FILE" 2>/dev/null | head -20 | while IFS= read -r error; do
            echo "  • $error"
        done
        echo ""
    else
        echo "✅ No console errors detected"
        echo ""
    fi
fi

# Network Issues
if [ "$CHECK_NETWORK" = true ]; then
    NETWORK_ERRORS=$(jq -r '.network | length' "$RESULT_FILE" 2>/dev/null || echo 0)

    if [ "$NETWORK_ERRORS" -gt 0 ]; then
        echo "❌ NETWORK ISSUES ($NETWORK_ERRORS found)"
        echo "================================"
        jq -r '.network[] | "\(.status // "FAILED") \(.method // "GET") \(.url)"' "$RESULT_FILE" 2>/dev/null | head -20 | while IFS= read -r issue; do
            echo "  • $issue"
        done
        echo ""
    else
        echo "✅ No network issues detected"
        echo ""
    fi
fi

# Runtime Issues
RUNTIME_ERRORS=$(jq -r '.runtime | length' "$RESULT_FILE" 2>/dev/null || echo 0)
if [ "$RUNTIME_ERRORS" -gt 0 ]; then
    echo "❌ RUNTIME ISSUES ($RUNTIME_ERRORS found)"
    echo "================================"
    jq -r '.runtime[]' "$RESULT_FILE" 2>/dev/null | head -20 | while IFS= read -r issue; do
        echo "  • $issue"
    done
    echo ""
fi

# Framework-Specific Issues
FRAMEWORK_ISSUES=$(jq -r '.frameworkIssues | length' "$RESULT_FILE" 2>/dev/null || echo 0)
if [ "$FRAMEWORK_ISSUES" -gt 0 ]; then
    echo "⚠️ FRAMEWORK-SPECIFIC ISSUES"
    echo "============================"
    jq -r '.frameworkIssues[]' "$RESULT_FILE" 2>/dev/null | while IFS= read -r issue; do
        echo "  • $issue"
    done
    echo ""
fi

# Performance Metrics
if [ "$CHECK_PERFORMANCE" = true ]; then
    PERF_DATA=$(jq -r '.performance // {}' "$RESULT_FILE" 2>/dev/null)

    if [ "$PERF_DATA" != "{}" ]; then
        echo "📊 PERFORMANCE METRICS"
        echo "===================="

        # Extract key metrics
        LOAD_TIME=$(echo "$PERF_DATA" | jq -r '.totalTime // 0' 2>/dev/null)
        DOM_READY=$(echo "$PERF_DATA" | jq -r '.domContentLoaded // 0' 2>/dev/null)

        if [ "$LOAD_TIME" -gt 0 ]; then
            echo "  Total load time: $(echo "scale=2; $LOAD_TIME / 1000" | bc)s"
        fi

        if [ "$DOM_READY" -gt 0 ]; then
            echo "  DOM ready: $(echo "scale=2; $DOM_READY / 1000" | bc)s"
        fi

        # Performance warnings
        if [ "$LOAD_TIME" -gt 10000 ]; then
            echo "  ⚠️ Slow page load detected (>10s)"
        elif [ "$LOAD_TIME" -gt 5000 ]; then
            echo "  ⚠️ Page load could be optimized (>5s)"
        fi

        echo ""
    fi
fi

# Screenshot info
if [ "$SAVE_SCREENSHOT" = true ] && [ -f "$SCREENSHOT_FILE" ]; then
    echo "📸 SCREENSHOT"
    echo "============"
    echo "  Saved to: $SCREENSHOT_FILE"
    echo "  Size: $(ls -lh "$SCREENSHOT_FILE" | awk '{print $5}')"
    echo ""
fi

# Summary and Recommendations
TOTAL_ISSUES=$((CONSOLE_ERRORS + NETWORK_ERRORS + RUNTIME_ERRORS + FRAMEWORK_ISSUES))

echo "📊 SUMMARY"
echo "========="
if [ "$TOTAL_ISSUES" -eq 0 ]; then
    echo "✅ No issues detected - frontend appears healthy"
else
    echo "Found $TOTAL_ISSUES total issues"
    echo ""
    echo "💡 RECOMMENDATIONS"
    echo "================="

    # Smart recommendations based on detected issues
    if [ "$CONSOLE_ERRORS" -gt 0 ]; then
        echo ""
        echo "For Console Errors:"

        if grep -q "undefined" "$RESULT_FILE" 2>/dev/null; then
            echo "  • Check for undefined variables"
            echo "  • Ensure all imports are correct"
            echo "  • Verify API responses have expected structure"
        fi

        if grep -q "Failed to load resource" "$RESULT_FILE" 2>/dev/null; then
            echo "  • Check API endpoint URLs"
            echo "  • Verify CORS configuration"
            echo "  • Ensure all assets are deployed"
        fi

        if grep -q "SyntaxError" "$RESULT_FILE" 2>/dev/null; then
            echo "  • Check for JavaScript syntax errors"
            echo "  • Verify build process completed successfully"
            echo "  • Ensure proper transpilation for older browsers"
        fi
    fi

    if [ "$NETWORK_ERRORS" -gt 0 ]; then
        echo ""
        echo "For Network Issues:"

        if grep -q "404" "$RESULT_FILE" 2>/dev/null; then
            echo "  • Verify all assets are included in deployment"
            echo "  • Check deployFiles in zerops.yml"
            echo "  • Ensure build output directory is correct"
        fi

        if grep -q "CORS" "$RESULT_FILE" 2>/dev/null; then
            echo "  • Configure CORS headers in backend"
            echo "  • Add Access-Control-Allow-Origin headers"
            echo "  • Check API domain configuration"
        fi

        if grep -q "500\|502\|503" "$RESULT_FILE" 2>/dev/null; then
            echo "  • Check backend service health"
            echo "  • Verify API is running correctly"
            echo "  • Review backend logs for errors"
        fi
    fi

    if echo "$FRAMEWORK_ISSUES" | jq -r '.[]' 2>/dev/null | grep -q "hydration"; then
        echo ""
        echo "For Hydration Issues:"
        echo "  • Ensure server and client render identical content"
        echo "  • Check for client-only code in SSR"
        echo "  • Verify data fetching is consistent"
        echo "  • Review dynamic content generation"
    fi

    if echo "$FRAMEWORK_ISSUES" | jq -r '.[]' 2>/dev/null | grep -q "React"; then
        echo ""
        echo "For React Issues:"
        echo "  • Check React DevTools for component errors"
        echo "  • Verify hooks are used correctly"
        echo "  • Ensure proper key props on lists"
    fi
fi

# Cleanup
rm -f "$RESULT_FILE"

# Exit code based on issues found
if [ "$TOTAL_ISSUES" -gt 0 ]; then
    exit 1
else
    exit 0
fi
