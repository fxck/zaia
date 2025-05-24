#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <base-url> [options]"
    echo "Options:"
    echo "  --endpoints <list>  Comma-separated endpoints to test"
    echo "  --method <method>   HTTP method (default: GET)"
    echo "  --data <json>       Request body for POST/PUT"
    echo "  --headers <list>    Comma-separated headers"
    exit 1
fi

BASE_URL="$1"
shift

# Default values
ENDPOINTS="/health"
METHOD="GET"
DATA=""
HEADERS="Content-Type: application/json"

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --endpoints)
            ENDPOINTS="$2"
            shift 2
            ;;
        --method)
            METHOD="$2"
            shift 2
            ;;
        --data)
            DATA="$2"
            shift 2
            ;;
        --headers)
            HEADERS="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

echo "=== BACKEND API TESTING ==="
echo "Base URL: $BASE_URL"
echo "Method: $METHOD"

# Convert comma-separated lists to arrays
IFS=',' read -ra ENDPOINT_ARRAY <<< "$ENDPOINTS"
IFS=',' read -ra HEADER_ARRAY <<< "$HEADERS"

# Build curl header arguments
CURL_HEADERS=""
for header in "${HEADER_ARRAY[@]}"; do
    CURL_HEADERS="$CURL_HEADERS -H \"$header\""
done

# Test each endpoint
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

for endpoint in "${ENDPOINT_ARRAY[@]}"; do
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo ""
    echo "Testing: $METHOD $endpoint"
    
    # Build curl command
    if [ -n "$DATA" ]; then
        CURL_CMD="curl -s -X $METHOD $CURL_HEADERS -d '$DATA' -w '\\n%{http_code}' $BASE_URL$endpoint"
    else
        CURL_CMD="curl -s -X $METHOD $CURL_HEADERS -w '\\n%{http_code}' $BASE_URL$endpoint"
    fi
    
    # Execute request
    RESPONSE=$(eval $CURL_CMD)
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -n -1)
    
    # Check status
    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        echo "✅ Status: $HTTP_CODE"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        
        # Try to parse JSON
        if echo "$BODY" | jq . >/dev/null 2>&1; then
            echo "Response: $(echo "$BODY" | jq -c .)"
        else
            echo "Response: $BODY"
        fi
    else
        echo "❌ Status: $HTTP_CODE"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "Response: $BODY"
    fi
    
    # Response time
    TIME=$(curl -o /dev/null -s -w '%{time_total}' $BASE_URL$endpoint)
    echo "Response time: ${TIME}s"
done

echo ""
echo "=== TEST SUMMARY ==="
echo "Total: $TOTAL_TESTS"
echo "Passed: $PASSED_TESTS"
echo "Failed: $FAILED_TESTS"

exit $FAILED_TESTS
