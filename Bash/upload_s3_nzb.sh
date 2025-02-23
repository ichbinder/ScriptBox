#!/bin/bash
# This script renames the downloaded NZB file (or directory) using the SABnzbd naming scheme and uploads it to a Hetzner Cloud S3 bucket with metadata.
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
#   ./upload_s3_nzb.sh /path/to/temporary_downloaded_file_or_directory
#
# The script extracts the hash and tmdbID from SAB_FINAL_NAME, renames the temporary file/directory,
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

log_info "SAB_COMPLETE_DIR: $SAB_COMPLETE_DIR"
log_info "SAB_FINAL_NAME: $SAB_FINAL_NAME"
log_info "SAB_CAT: ${SAB_CAT^}"
log_info "SAB_FILENAME: $SAB_FILENAME"

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

# Rename the download directory if it matches the pattern
DOWNLOAD_DIR=$(basename "$SAB_COMPLETE_DIR")
if [[ "$DOWNLOAD_DIR" =~ ^([A-Za-z0-9]+)--\[\[([0-9]+)\]\]$ ]]; then
    hash="${BASH_REMATCH[1]}"
    tmdbID="${BASH_REMATCH[2]}"
    PARENT_DIR=$(dirname "$SAB_COMPLETE_DIR")
    NEW_DIR="$PARENT_DIR/$hash"
    mv "$SAB_COMPLETE_DIR" "$NEW_DIR"
    if [ $? -ne 0 ]; then
        log_error "Error renaming directory from '$SAB_COMPLETE_DIR' to '$NEW_DIR'"
        exit 1
    fi
    log_info "Renamed download directory to: $NEW_DIR"
    SAB_COMPLETE_DIR="$NEW_DIR"
fi

# Find the media file in SAB_COMPLETE_DIR (recursively)
SOURCE_FILE=$(find "$SAB_COMPLETE_DIR" -type f -name "*--\[\[*\]\]*" | head -n 1)
if [ -z "$SOURCE_FILE" ]; then
    log_error "No media file found in '$SAB_COMPLETE_DIR'"
    exit 1
fi

ORIGINAL_FILENAME=$(basename "$SOURCE_FILE")
if [[ "$ORIGINAL_FILENAME" =~ ^([A-Za-z0-9]+)--\[\[([0-9]+)\]\](\..+)?$ ]]; then
    hash="${BASH_REMATCH[1]}"
    tmdbID="${BASH_REMATCH[2]}"
    extension="${BASH_REMATCH[3]}"
    newFileName="$hash"
    if [ -n "$extension" ]; then
        newFileName="${hash}${extension}"
    fi
    FINAL_FILE="$SAB_COMPLETE_DIR/$newFileName"
    mv "$SOURCE_FILE" "$FINAL_FILE"
    if [ $? -ne 0 ]; then
        log_error "Error renaming file from '$SOURCE_FILE' to '$FINAL_FILE'"
        exit 1
    fi
    log_info "Renamed file to: $FINAL_FILE"
    log_info "Extracted metadata: hash=\"$hash\", tmdbID=$tmdbID"
    SAB_CAT_CAPITALIZED="${SAB_CAT^}"
    # URL-encode the filename for the URL
    # newFileNameUrl=$(echo "$newFileName" | sed 's/[^a-zA-Z0-9.-]/\\&/g')
    log_info "Uploading file to bucket '$S3_BUCKET' at '$S3_ENDPOINT' using cURL..."
    URL="https://${S3_ENDPOINT}/${S3_BUCKET}/Media/${SAB_CAT_CAPITALIZED}/$newFileName"
    log_info "Uploading file to URL: $URL"
    log_info "FINAL_FILE: $FINAL_FILE"

    # Get file size (compatible with Linux)
    FILE_SIZE=$(stat -c%s "$FINAL_FILE")
    if [ $? -ne 0 ]; then
        log_error "Failed to get file size"
        exit 1
    fi

    CHUNK_SIZE=$((64*1024*1024)) # 64MB chunks
    TOTAL_CHUNKS=$(( (FILE_SIZE + CHUNK_SIZE - 1) / CHUNK_SIZE ))

    log_info "File size: $FILE_SIZE bytes, will be split into $TOTAL_CHUNKS chunks"

    if [ "$FILE_SIZE" -lt "$CHUNK_SIZE" ]; then
        # Small file, upload directly
        curl "$URL" \
            -T "$FINAL_FILE" \
            --user "${ACCESS_KEY}:${SECRET_KEY}" \
            --aws-sigv4 "aws:amz:${REGION}:s3" \
            -H "x-amz-meta-hash: ${hash}" \
            -H "x-amz-meta-tmdbID: ${tmdbID}"
        UPLOAD_STATUS=$?
    else
        # Large file, use multipart upload
        # Initialize multipart upload
        UPLOAD_ID=$(curl -X POST "${URL}?uploads=" \
            --user "${ACCESS_KEY}:${SECRET_KEY}" \
            --aws-sigv4 "aws:amz:${REGION}:s3" \
            -H "x-amz-meta-hash: ${hash}" \
            -H "x-amz-meta-tmdbID: ${tmdbID}" \
            -s | grep -o '<UploadId>[^<]*</UploadId>' | sed 's/<UploadId>\(.*\)<\/UploadId>/\1/')

        if [ -z "$UPLOAD_ID" ]; then
            log_error "Failed to initialize multipart upload"
            exit 1
        fi

        log_info "Initialized multipart upload with ID: $UPLOAD_ID"
        
        # Upload parts in parallel (max 5 parallel uploads)
        > "/tmp/${UPLOAD_ID}.etags"
        for ((i=1; i<=TOTAL_CHUNKS; i++)); do
            OFFSET=$(( (i-1) * CHUNK_SIZE ))
            if [ $i -eq $TOTAL_CHUNKS ]; then
                LENGTH=$(( FILE_SIZE - OFFSET ))
            else
                LENGTH=$CHUNK_SIZE
            fi
            
            # Upload part and store ETag (in background for parallelization)
            {
                ETAG=$(dd if="$FINAL_FILE" bs="$CHUNK_SIZE" skip=$((i-1)) count=1 2>/dev/null | \
                    curl -X PUT "${URL}?partNumber=${i}&uploadId=${UPLOAD_ID}" \
                    --user "${ACCESS_KEY}:${SECRET_KEY}" \
                    --aws-sigv4 "aws:amz:${REGION}:s3" \
                    --data-binary @- \
                    -H "Content-Length: ${LENGTH}" \
                    -i -s | grep ETag | cut -d'"' -f2)
                echo "${i}:${ETAG}" >> "/tmp/${UPLOAD_ID}.etags"
                log_info "Uploaded part $i/$TOTAL_CHUNKS"
            } &
            
            # Limit parallel uploads
            if [ $(jobs -r | wc -l) -ge 5 ]; then
                wait -n
            fi
        done
        
        # Wait for all uploads to complete
        wait

        # Check if all parts were uploaded successfully
        if [ $(wc -l < "/tmp/${UPLOAD_ID}.etags") -ne $TOTAL_CHUNKS ]; then
            log_error "Not all parts were uploaded successfully"
            exit 1
        fi
        
        # Build completion XML
        echo '<?xml version="1.0" encoding="UTF-8"?><CompleteMultipartUpload>' > "/tmp/${UPLOAD_ID}.xml"
        sort -n -t: -k1 "/tmp/${UPLOAD_ID}.etags" | while IFS=: read -r part etag; do
            echo "<Part><PartNumber>${part}</PartNumber><ETag>${etag}</ETag></Part>" >> "/tmp/${UPLOAD_ID}.xml"
        done
        echo '</CompleteMultipartUpload>' >> "/tmp/${UPLOAD_ID}.xml"
        
        # Complete multipart upload
        COMPLETE_RESPONSE=$(curl -X POST "${URL}?uploadId=${UPLOAD_ID}" \
            --user "${ACCESS_KEY}:${SECRET_KEY}" \
            --aws-sigv4 "aws:amz:${REGION}:s3" \
            -H "Content-Type: application/xml" \
            --data-binary @"/tmp/${UPLOAD_ID}.xml" -s)

        # Check if completion was successful
        if echo "$COMPLETE_RESPONSE" | grep -q "<Error>"; then
            log_error "Failed to complete multipart upload: $COMPLETE_RESPONSE"
            UPLOAD_STATUS=1
        else
            UPLOAD_STATUS=0
        fi
        
        # Cleanup temporary files
        rm -f "/tmp/${UPLOAD_ID}.etags" "/tmp/${UPLOAD_ID}.xml"
    fi

    if [ $UPLOAD_STATUS -eq 0 ]; then
        log_info "File '$newFileName' uploaded successfully to bucket '$S3_BUCKET'."
    else
        log_error "Failed to upload file '$newFileName' to bucket '$S3_BUCKET'."
    fi
else
    log_error "File '$ORIGINAL_FILENAME' does not match expected pattern. Skipping."
fi