#!/bin/bash
# This script renames the downloaded NZB file using the SABnzbd naming scheme and uploads it to a Hetzner Cloud S3 bucket with metadata.
#
# Expected environment variables provided by SABnzbd:
#   SAB_COMPLETE_DIR - Directory where the file should be stored
#   SAB_FINAL_NAME   - Final file name provided by SABnzbd (format: hash--[[tmdbID]]<extension>) or full path
#
# Configuration for Hetzner Cloud S3 bucket:
#   S3_BUCKET   - The target bucket name (e.g., your-bucket-name)
#   S3_ENDPOINT - The S3 endpoint domain (e.g., fsn1.your-objectstorage.com)
#
# Additional configuration for cURL upload:
#   ACCESS_KEY  - Your Object Storage access key
#   SECRET_KEY  - Your Object Storage secret key
#   REGION      - Storage region (e.g., fsn1)
#
# Usage:
#   ./upload_s3_nzb.sh /path/to/temporary_downloaded_file
#
# The script extracts the hash and tmdbID from SAB_FINAL_NAME, renames the temporary file,
# and uploads it with cURL using AWS Signature Version 4.
#
# Additional metadata is attached as HTTP headers:
#   x-amz-meta-hash:   <hash>
#   x-amz-meta-tmdbID: <tmdbID>

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -f "$DIR/.env" ]; then
    set -o allexport
    source "$DIR/.env"
    set +o allexport
fi

# Logging functions: writes info to info.log and errors to error.log with a timestamp
LOG_INFO="$DIR/info.log"
LOG_ERROR="$DIR/error.log"

log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') INFO: $1" | tee -a "$LOG_INFO"
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: $1" | tee -a "$LOG_ERROR" >&2
}

# Ensure required environment variables are set for SABnzbd
if [ -z "$SAB_COMPLETE_DIR" ] || [ -z "$SAB_FINAL_NAME" ]; then
    log_error "SAB_COMPLETE_DIR and SAB_FINAL_NAME environment variables must be set."
    exit 1
fi

# Ensure required environment variables are set for Hetzner Object Storage
if [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ] || [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$REGION" ]; then
    log_error "S3_BUCKET, S3_ENDPOINT, ACCESS_KEY, SECRET_KEY, and REGION must be set."
    exit 1
fi

# Check if the temporary file parameter is provided
if [ -z "$1" ]; then
    log_error "Usage: $0 <path_to_temp_file>"
    exit 1
fi

TEMP_FILE="$1"

# If SAB_FINAL_NAME contains a "/" assume it's a full path, else use SAB_COMPLETE_DIR and SAB_FINAL_NAME as given.
if [[ "$SAB_FINAL_NAME" == */* ]]; then
    TARGET_DIR=$(dirname "$SAB_FINAL_NAME")
    ORIGINAL_FILENAME=$(basename "$SAB_FINAL_NAME")
else
    TARGET_DIR="$SAB_COMPLETE_DIR"
    ORIGINAL_FILENAME="$SAB_FINAL_NAME"
fi

# Extract the hash and tmdbID from the ORIGINAL_FILENAME (expected format: hash--[[tmdbID]]<extension>)
if [[ "$ORIGINAL_FILENAME" =~ ^(.*?)--\[\[([0-9]+)\]\](\..+)?$ ]]; then
    hash="${BASH_REMATCH[1]}"
    tmdbID="${BASH_REMATCH[2]}"
    extension="${BASH_REMATCH[3]}"
else
    log_error "SAB_FINAL_NAME does not match the expected pattern (hash--[[tmdbID]])."
    exit 1
fi

# Construct the new file name. Use the extracted hash and preserve the extension if available.
newFileName="$hash"
if [ -n "$extension" ]; then
    newFileName="${hash}${extension}"
fi

FINAL_FILE="$TARGET_DIR/$newFileName"

# Rename the temporary file to the final file.
mv "$TEMP_FILE" "$FINAL_FILE"
if [ $? -ne 0 ]; then
    log_error "Error renaming file from '$TEMP_FILE' to '$FINAL_FILE'"
    exit 1
fi

log_info "Renamed file to: $FINAL_FILE"
log_info "Extracted metadata: hash=\"$hash\", tmdbID=$tmdbID"

# Upload the file to the Hetzner Cloud S3 bucket using cURL with AWS Signature Version 4.
log_info "Uploading file to bucket '$S3_BUCKET' at '$S3_ENDPOINT' using cURL..."

# Construct the URL using the virtual-hosted-style as per Hetzner's documentation.
URL="https://${S3_BUCKET}.${S3_ENDPOINT}/${newFileName}"

curl -T "$FINAL_FILE" "$URL" \
  --user "${ACCESS_KEY}:${SECRET_KEY}" \
  --aws-sigv4 "aws:amz:${REGION}:s3" \
  -H "x-amz-meta-hash: ${hash}" \
  -H "x-amz-meta-tmdbID: ${tmdbID}"

if [ $? -eq 0 ]; then
    log_info "File '$newFileName' uploaded successfully to bucket '$S3_BUCKET'."
else
    log_error "Failed to upload file '$newFileName' to bucket '$S3_BUCKET'."
    exit 1
fi 