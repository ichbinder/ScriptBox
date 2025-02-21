#!/bin/bash
# This script renames the downloaded NZB file using the SABnzbd naming scheme and uploads it to a Hetzner Cloud S2 bucket with metadata.
#
# Expected environment variables provided by SABnzbd:
#   NZBPP_DIRECTORY - Directory where the file should be stored
#   NZBPP_FILENAME  - Final file name provided by SABnzbd (format: hash--[[tmdbID]]<extension>)
#
# Configuration for Hetzner Cloud S2 bucket:
#   S3_BUCKET   - The target bucket name (e.g., your-bucket-name)
#   S3_ENDPOINT - The S3 endpoint URL (e.g., https://s3.your-region.hetzner.cloud)
#
# Usage:
#   ./upload_script.sh /path/to/temporary_downloaded_file
#
# The script extracts the hash and tmdbID from NZBPP_FILENAME, renames the temporary file to the new file name (using only the hash with the extension) 
# and uploads it with metadata: {"hash": "<hash>", "tmdbID": <tmdbID>}.

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -f "$DIR/.env" ]; then
    set -o allexport
    source "$DIR/.env"
    set +o allexport
fi

# Logging functions: writes info to info.log and errors to error.log with a timestamp
LOG_INFO="info.log"
LOG_ERROR="error.log"

log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') INFO: $1" | tee -a "$LOG_INFO"
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: $1" | tee -a "$LOG_ERROR" >&2
}

# Ensure required environment variables are set
if [ -z "$NZBPP_DIRECTORY" ] || [ -z "$NZBPP_FILENAME" ]; then
    log_error "NZBPP_DIRECTORY and NZBPP_FILENAME environment variables must be set."
    exit 1
fi

if [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ]; then
    log_error "S3_BUCKET and S3_ENDPOINT must be set."
    exit 1
fi

# Check if the temporary file parameter is provided
if [ -z "$1" ]; then
    log_error "Usage: $0 <path_to_temp_file>"
    exit 1
fi

TEMP_FILE="$1"
TARGET_DIR="$NZBPP_DIRECTORY"
ORIGINAL_FILENAME="$NZBPP_FILENAME"

# Extract the hash and tmdbID from the NZBPP_FILENAME (expected format: hash--[[tmdbID]]<extension>)
if [[ "$ORIGINAL_FILENAME" =~ ^(.*?)--\[\[([0-9]+)\]\](\..+)?$ ]]; then
    hash="${BASH_REMATCH[1]}"
    tmdbID="${BASH_REMATCH[2]}"
    extension="${BASH_REMATCH[3]}"
else
    log_error "NZBPP_FILENAME does not match the expected pattern (hash--[[tmdbID]])."
    exit 1
fi

# Construct the new file name. Use the extracted hash and preserve the extension if available.
newFileName="$hash"
if [ -n "$extension" ]; then
    newFileName="${hash}${extension}"
fi

FINAL_FILE="$TARGET_DIR/$newFileName"

# Rename the temporary file to the final file
mv "$TEMP_FILE" "$FINAL_FILE"
if [ $? -ne 0 ]; then
    log_error "Error renaming file from '$TEMP_FILE' to '$FINAL_FILE'"
    exit 1
fi

log_info "Renamed file to: $FINAL_FILE"
log_info "Extracted metadata: hash=\"$hash\", tmdbID=$tmdbID"

# Upload the file to the Hetzner Cloud S2 bucket using AWS CLI with metadata
log_info "Uploading file to bucket '$S3_BUCKET' at '$S3_ENDPOINT'..."
aws --endpoint-url="$S3_ENDPOINT" s3api put-object --bucket "$S3_BUCKET" --key "$newFileName" --body "$FINAL_FILE" --metadata hash="$hash",tmdbID="$tmdbID"
if [ $? -eq 0 ]; then
    log_info "File '$newFileName' uploaded successfully to bucket '$S3_BUCKET'."
else
    log_error "Failed to upload file '$newFileName' to bucket '$S3_BUCKET'."
    exit 1
fi 