#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -f "$DIR/.env" ]; then
    set -o allexport
    source "$DIR/.env"
    set +o allexport
fi

# Ensure the URL has the correct format and ends with a slash if needed
SABNZBD_URL=${SABNZBD_URL%/}/

# Debugging: Show the URL being used
echo "Base URL: ${SABNZBD_URL}"

# Get the current queue status in JSON format
echo "=== QUEUE STATUS ==="
queue_url="${SABNZBD_URL}?mode=queue&apikey=${API_KEY}&output=json"
echo "Calling API: ${queue_url}"
response=$(curl -s "${queue_url}")

# Debug the raw response
echo "Raw queue response (first 100 chars):"
echo "$response" | head -c 100
echo -e "\n"

# Check if we got a valid JSON response
if ! echo "$response" | jq . &>/dev/null; then
    echo "Error: The API did not return valid JSON for queue. Check your API URL and credentials."
else
    # Get the queue status
    status=$(echo "$response" | jq -r '.queue.status')
    echo "Queue Status: $status"
    
    # Get the number of slots
    slot_count=$(echo "$response" | jq -r '.queue.noofslots')
    echo "Number of jobs in queue: $slot_count"
    
    # Parse the JSON response to find the status of each job
    if [ "$slot_count" -gt 0 ]; then
        echo "Job details:"
        echo "$response" | jq '.queue.slots[] | {filename: .filename, status: .status, size: .size, timeleft: .timeleft}'
    else
        echo "No jobs in queue."
    fi
fi

echo ""
echo "=== WARNINGS ==="
warnings_url="${SABNZBD_URL}?mode=warnings&apikey=${API_KEY}&output=json"
echo "Calling API: ${warnings_url}"

# Get the warnings data
warnings_response=$(curl -s "${warnings_url}")

# Debug the raw response
echo "Raw warnings response (first 100 chars):"
echo "$warnings_response" | head -c 100
echo -e "\n"

# Check if we got a valid JSON response
if ! echo "$warnings_response" | jq . &>/dev/null; then
    echo "Error: The API did not return valid JSON for warnings. Check your API URL and credentials."
else
    # Get the number of warnings
    warnings_count=$(echo "$warnings_response" | jq '.warnings | length')
    echo "Number of warnings: $warnings_count"
    
    # Parse the JSON response to find details of each warning
    if [ "$warnings_count" -gt 0 ]; then
        echo "Recent warnings:"
        echo "$warnings_response" | jq '.warnings[]'
    else
        echo "No warnings reported."
    fi
fi

echo ""
echo "=== HISTORY ==="
history_url="${SABNZBD_URL}?mode=history&apikey=${API_KEY}&output=json&limit=5"
echo "Calling API: ${history_url}"

# Get the history data
history_response=$(curl -s "${history_url}")

# Debug the raw response
echo "Raw history response (first 100 chars):"
echo "$history_response" | head -c 100
echo -e "\n"

# Check if we got a valid JSON response
if ! echo "$history_response" | jq . &>/dev/null; then
    echo "Error: The API did not return valid JSON for history. Check your API URL and credentials."
else
    # Get the number of history items
    history_count=$(echo "$history_response" | jq -r '.history.noofslots')
    echo "Number of completed jobs in history: $history_count"
    
    # Parse the JSON response to find details of each history item
    if [ "$history_count" -gt 0 ]; then
        echo "Recent completed jobs:"
        echo "$history_response" | jq '.history.slots[] | {name: .name, status: .status, completed: .completed, size: .size, category: .category}'
    else
        echo "No jobs in history."
    fi
fi 