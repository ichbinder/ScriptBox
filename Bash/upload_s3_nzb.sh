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
# The script finds the largest file in the download directory, extracts the hash and tmdbID from SAB_FINAL_NAME,
# renames the file, and uploads it with AWS CLI using proper authentication.
#
# Additional metadata is attached:
#   hash:   <hash>
#   tmdbID: <tmdbID>

# Set script to exit on error
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -f "$DIR/.env" ]; then
    set -o allexport
    source "$DIR/.env"
    set +o allexport
fi

# Logging functions: writes info to info.log and errors to error.log with a timestamp
LOG_INFO="$DIR/info.log"
LOG_ERROR="$DIR/error.log"

# Make sure log directories exist
touch "$LOG_INFO" 2>/dev/null || mkdir -p "$(dirname "$LOG_INFO")" && touch "$LOG_INFO"
touch "$LOG_ERROR" 2>/dev/null || mkdir -p "$(dirname "$LOG_ERROR")" && touch "$LOG_ERROR"

log_info() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') INFO: $1" | tee -a "$LOG_INFO"
}

log_error() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: $1" | tee -a "$LOG_ERROR" >&2
}

# Log all environment variables for debugging
log_info "==================== SCRIPT STARTED ===================="
log_info "SAB_COMPLETE_DIR: $SAB_COMPLETE_DIR"
log_info "SAB_FINAL_NAME: $SAB_FINAL_NAME"
log_info "SAB_CAT: ${SAB_CAT:-unset}"
log_info "SAB_FILENAME: $SAB_FILENAME"
log_info "Running as user: $(whoami)"
log_info "Current directory: $(pwd)"

# Add debug info about the directory structure
if [ -d "$SAB_COMPLETE_DIR" ]; then
    log_info "SAB_COMPLETE_DIR exists and is a directory"
    log_info "Directory permissions: $(ls -ld "$SAB_COMPLETE_DIR")"
    log_info "Parent directory contents: $(ls -la "$(dirname "$SAB_COMPLETE_DIR")")"
else
    log_error "SAB_COMPLETE_DIR does not exist or is not a directory"
fi

# Store the original directory path to track even after renaming
DIRECTORY_TO_DELETE=""

# Ensure required environment variables are set for SABnzbd
if [ -z "$SAB_COMPLETE_DIR" ] || [ -z "$SAB_FINAL_NAME" ]; then
    log_error "SAB_COMPLETE_DIR and/or SAB_FINAL_NAME environment variables are not set"
    log_error "Current values: SAB_COMPLETE_DIR='$SAB_COMPLETE_DIR', SAB_FINAL_NAME='$SAB_FINAL_NAME'"
    # Use default values or exit more gracefully
    if [ -z "$SAB_COMPLETE_DIR" ]; then
        SAB_COMPLETE_DIR="/downloads"
        log_info "Using default SAB_COMPLETE_DIR: $SAB_COMPLETE_DIR"
    fi
    if [ -z "$SAB_FINAL_NAME" ]; then
        log_error "SAB_FINAL_NAME is required. Exiting."
        exit 1
    fi
fi

# Check for AWS CLI installation
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed. Please install it first."
    log_info "You can install it using: apt-get update && apt-get install -y awscli"
    exit 1
fi

# Ensure required environment variables are set for Hetzner Object Storage
if [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ] || [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$REGION" ]; then
    log_error "One or more S3 configuration variables are missing:"
    [ -z "$S3_BUCKET" ] && log_error "- S3_BUCKET is not set"
    [ -z "$S3_ENDPOINT" ] && log_error "- S3_ENDPOINT is not set"
    [ -z "$ACCESS_KEY" ] && log_error "- ACCESS_KEY is not set"
    [ -z "$SECRET_KEY" ] && log_error "- SECRET_KEY is not set"
    [ -z "$REGION" ] && log_error "- REGION is not set"
    exit 1
fi

# Check if SAB_COMPLETE_DIR exists
if [ ! -d "$SAB_COMPLETE_DIR" ]; then
    log_error "Directory '$SAB_COMPLETE_DIR' does not exist"
    exit 1
fi

# Rename the download directory if it matches the pattern
DOWNLOAD_DIR=$(basename "$SAB_COMPLETE_DIR")
log_info "Extracted directory name: $DOWNLOAD_DIR"
# This pattern matches hash--[[tmdbID]].version format 
if [[ "$DOWNLOAD_DIR" =~ ^([A-Za-z0-9]+)--\[\[([0-9]+)\]\](\.([0-9]+))?$ ]]; then
    hash="${BASH_REMATCH[1]}"
    tmdbID="${BASH_REMATCH[2]}"
    version="${BASH_REMATCH[4]}"
    log_info "Regex matched! Extracted hash=$hash, tmdbID=$tmdbID, version=${version:-none}"
    PARENT_DIR=$(dirname "$SAB_COMPLETE_DIR")
    NEW_DIR="$PARENT_DIR/$hash"
    log_info "Attempting to rename directory from '$SAB_COMPLETE_DIR' to '$NEW_DIR'"
    mv "$SAB_COMPLETE_DIR" "$NEW_DIR"
    if [ $? -ne 0 ]; then
        log_error "Error renaming directory from '$SAB_COMPLETE_DIR' to '$NEW_DIR'"
        exit 1
    fi
    log_info "Renamed download directory to: $NEW_DIR"
    # Store this as the directory to delete later
    DIRECTORY_TO_DELETE="$NEW_DIR"
    SAB_COMPLETE_DIR="$NEW_DIR"
else
    # If we didn't rename, use the original directory for deletion
    DIRECTORY_TO_DELETE="$SAB_COMPLETE_DIR"
fi

# Add more detailed logging about the directory contents
log_info "Directory structure: $(find "$SAB_COMPLETE_DIR" -type d | sort)"

# First, try a simple ls to see if there are visible files
VISIBLE_FILES=$(ls -la "$SAB_COMPLETE_DIR" | grep -v "^d" | grep -v "^total" | wc -l)
log_info "Number of visible files in directory: $VISIBLE_FILES"

# Improved find command with better error handling for special characters
if [ "$VISIBLE_FILES" -gt 0 ]; then
    log_info "Using primary file search method..."
    SOURCE_FILE=$(find "$SAB_COMPLETE_DIR" -type f -not -path "*/\.*" -print0 2>/dev/null | xargs -0 -r du -s 2>/dev/null | sort -rn | head -n 1 | cut -f2-)
    
    if [ -z "$SOURCE_FILE" ]; then
        log_info "Primary method failed, trying secondary method..."
        # Try with a different approach for paths with spaces
        SOURCE_FILE=$(find "$SAB_COMPLETE_DIR" -type f -not -path "*/\.*" -exec du -s {} \; 2>/dev/null | sort -rn | head -n 1 | cut -f2-)
    fi
else
    log_info "No visible files found with ls, trying direct find methods..."
    SOURCE_FILE=$(find "$SAB_COMPLETE_DIR" -type f -exec du -s {} \; 2>/dev/null | sort -rn | head -n 1 | cut -f2-)
fi

if [ -z "$SOURCE_FILE" ]; then
    log_error "No files found in '$SAB_COMPLETE_DIR'"
    log_info "Directory contents: $(ls -la "$SAB_COMPLETE_DIR")"
    # Try direct glob as a last resort
    log_info "Trying direct glob as last resort..."
    shopt -s nullglob dotglob
    FILES=("$SAB_COMPLETE_DIR"/*)
    shopt -u nullglob dotglob
    
    if [ ${#FILES[@]} -gt 0 ]; then
        for file in "${FILES[@]}"; do
            if [ -f "$file" ]; then
                SOURCE_FILE="$file"
                log_info "Found file using glob: $SOURCE_FILE"
                break
            fi
        done
    fi
    
    if [ -z "$SOURCE_FILE" ]; then
        log_error "All search methods failed. Exiting."
        exit 1
    fi
fi

# Verify file exists and is readable
if [ ! -f "$SOURCE_FILE" ]; then
    log_error "Found path '$SOURCE_FILE' is not a regular file"
    exit 1
fi

if [ ! -r "$SOURCE_FILE" ]; then
    log_error "Found file '$SOURCE_FILE' is not readable"
    log_info "File permissions: $(ls -l "$SOURCE_FILE")"
    exit 1
fi

log_info "Largest file found: $SOURCE_FILE ($(du -h "$SOURCE_FILE" | cut -f1))"
log_info "File details: $(ls -la "$SOURCE_FILE")"
log_info "File type: $(file -b "$SOURCE_FILE")"

# Extract hash and tmdbID from SAB_FINAL_NAME instead of the filename
log_info "Parsing SAB_FINAL_NAME: $SAB_FINAL_NAME"
# This pattern matches hash--[[tmdbID]].version format
if [[ "$SAB_FINAL_NAME" =~ ^([A-Za-z0-9]+)--\[\[([0-9]+)\]\](\.([0-9]+))?$ ]]; then
    hash="${BASH_REMATCH[1]}"
    tmdbID="${BASH_REMATCH[2]}"
    version="${BASH_REMATCH[4]}"
    log_info "SAB_FINAL_NAME regex matched! Extracted hash=$hash, tmdbID=$tmdbID, version=${version:-none}"
    
    # Get the extension from the source file
    ORIGINAL_FILENAME=$(basename "$SOURCE_FILE")
    extension="${ORIGINAL_FILENAME##*.}"
    if [ -n "$extension" ]; then
        extension=".$extension"
    fi
    
    newFileName="${hash}${extension}"
    FINAL_FILE="$SAB_COMPLETE_DIR/$newFileName"
    
    log_info "Renaming largest file from '$SOURCE_FILE' to '$FINAL_FILE'"
    # Check if source and destination are the same
    if [ "$SOURCE_FILE" = "$FINAL_FILE" ]; then
        log_info "Source and destination are the same. Skipping rename."
    else
        # Use cp with quotes to handle special characters better
        cp -- "$SOURCE_FILE" "$FINAL_FILE"
        CP_STATUS=$?
        if [ $CP_STATUS -ne 0 ]; then
            log_error "Error copying file from '$SOURCE_FILE' to '$FINAL_FILE' (status: $CP_STATUS)"
            log_info "Trying alternative copy method..."
            # Try rsync as an alternative
            rsync -a -- "$SOURCE_FILE" "$FINAL_FILE"
            if [ $? -ne 0 ]; then
                log_error "All copy methods failed. Exiting."
                exit 1
            else
                log_info "Alternative copy method succeeded."
            fi
        fi
    fi
    
    log_info "File ready for upload: $FINAL_FILE"
    log_info "Extracted metadata: hash=\"$hash\", tmdbID=$tmdbID"
    
    # Default to "movies" if SAB_CAT is not set
    if [ -z "$SAB_CAT" ]; then
        SAB_CAT="movies"
        log_info "SAB_CAT not set, using default: $SAB_CAT"
    fi
    
    SAB_CAT_CAPITALIZED="${SAB_CAT^}"
    log_info "Uploading file to bucket '$S3_BUCKET' at '$S3_ENDPOINT' using AWS CLI..."
    S3_PATH="s3://${S3_BUCKET}/Media/${SAB_CAT_CAPITALIZED}/$newFileName"
    log_info "Uploading file to S3 path: $S3_PATH"
    log_info "FINAL_FILE: $FINAL_FILE"

    # Configure AWS CLI (without writing to disk, using environment variables)
    export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
    export AWS_DEFAULT_REGION="$REGION" 
    
    # Check if the file exists
    if [ ! -f "$FINAL_FILE" ]; then
        log_error "File '$FINAL_FILE' does not exist"
        exit 1
    fi
    
    log_info "File size: $(du -h "$FINAL_FILE" | cut -f1)"
    
    # Upload command with better error handling
    log_info "Uploading file with aws s3 cp..."
    set +e  # Disable exit on error temporarily
    aws s3 cp "$FINAL_FILE" "$S3_PATH" --endpoint-url "https://$S3_ENDPOINT" --metadata "hash=$hash,tmdbID=$tmdbID"
    UPLOAD_STATUS=$?
    set -e  # Re-enable exit on error

    # Report success or failure
    if [ $UPLOAD_STATUS -eq 0 ]; then
        log_info "File '$newFileName' uploaded successfully to bucket '$S3_BUCKET'."
        
        # Delete the source directory after successful upload
        log_info "Deleting source directory '$DIRECTORY_TO_DELETE' after successful upload..."
        set +e  # Disable exit on error temporarily
        rm -rf "$DIRECTORY_TO_DELETE"
        DELETE_STATUS=$?
        set -e  # Re-enable exit on error
        
        if [ $DELETE_STATUS -eq 0 ]; then
            log_info "Source directory '$DIRECTORY_TO_DELETE' successfully deleted."
        else
            log_error "Failed to delete source directory '$DIRECTORY_TO_DELETE'. Status: $DELETE_STATUS"
            # Not exiting with error as the upload was successful
        fi
    else
        log_error "Failed to upload file '$newFileName' to bucket '$S3_BUCKET'. Status: $UPLOAD_STATUS"
        exit $UPLOAD_STATUS
    fi
else
    log_error "SAB_FINAL_NAME '$SAB_FINAL_NAME' does not match expected pattern. Skipping."
    
    # Try to extract a hash from the directory name as a fallback
    if [[ -n "$DOWNLOAD_DIR" && "$DOWNLOAD_DIR" =~ ^([A-Za-z0-9]+) ]]; then
        hash="${BASH_REMATCH[1]}"
        log_info "Extracted hash='$hash' from directory name as a fallback"
        
        # Try to find TMDB ID from the filename
        ORIGINAL_FILENAME=$(basename "$SOURCE_FILE")
        log_info "Looking for TMDB ID in filename: $ORIGINAL_FILENAME"
        
        if [[ "$ORIGINAL_FILENAME" =~ \.([0-9]+)\.[0-9]+\.([a-zA-Z0-9]+)$ ]]; then
            tmdbID="${BASH_REMATCH[1]}"
            extension=".${BASH_REMATCH[2]}"
            log_info "Extracted tmdbID=$tmdbID and extension=$extension from filename"
            
            newFileName="${hash}${extension}"
            FINAL_FILE="$SAB_COMPLETE_DIR/$newFileName"
            
            log_info "Using fallback method with hash=$hash, tmdbID=$tmdbID, newFileName=$newFileName"
            
            # Continue with file copy, etc.
            log_info "Renaming largest file from '$SOURCE_FILE' to '$FINAL_FILE'"
            # Check if source and destination are the same
            if [ "$SOURCE_FILE" = "$FINAL_FILE" ]; then
                log_info "Source and destination are the same. Skipping rename."
            else
                # Use cp with quotes to handle special characters better
                cp -- "$SOURCE_FILE" "$FINAL_FILE"
                CP_STATUS=$?
                if [ $CP_STATUS -ne 0 ]; then
                    log_error "Error copying file from '$SOURCE_FILE' to '$FINAL_FILE' (status: $CP_STATUS)"
                    log_info "Trying alternative copy method..."
                    # Try rsync as an alternative
                    rsync -a -- "$SOURCE_FILE" "$FINAL_FILE"
                    if [ $? -ne 0 ]; then
                        log_error "All copy methods failed. Exiting."
                        exit 1
                    else
                        log_info "Alternative copy method succeeded."
                    fi
                fi
            fi
            
            log_info "File ready for upload: $FINAL_FILE"
            log_info "Extracted metadata: hash=\"$hash\", tmdbID=$tmdbID"
            
            # Default to "movies" if SAB_CAT is not set
            if [ -z "$SAB_CAT" ]; then
                SAB_CAT="movies"
                log_info "SAB_CAT not set, using default: $SAB_CAT"
            fi
            
            SAB_CAT_CAPITALIZED="${SAB_CAT^}"
            log_info "Uploading file to bucket '$S3_BUCKET' at '$S3_ENDPOINT' using AWS CLI..."
            S3_PATH="s3://${S3_BUCKET}/Media/${SAB_CAT_CAPITALIZED}/$newFileName"
            log_info "Uploading file to S3 path: $S3_PATH"
            log_info "FINAL_FILE: $FINAL_FILE"
        
            # Configure AWS CLI (without writing to disk, using environment variables)
            export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
            export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
            export AWS_DEFAULT_REGION="$REGION" 
            
            # Check if the file exists
            if [ ! -f "$FINAL_FILE" ]; then
                log_error "File '$FINAL_FILE' does not exist"
                exit 1
            fi
            
            log_info "File size: $(du -h "$FINAL_FILE" | cut -f1)"
            
            # Upload command with better error handling
            log_info "Uploading file with aws s3 cp..."
            set +e  # Disable exit on error temporarily
            aws s3 cp "$FINAL_FILE" "$S3_PATH" --endpoint-url "https://$S3_ENDPOINT" --metadata "hash=$hash,tmdbID=$tmdbID"
            UPLOAD_STATUS=$?
            set -e  # Re-enable exit on error
        
            # Report success or failure
            if [ $UPLOAD_STATUS -eq 0 ]; then
                log_info "File '$newFileName' uploaded successfully to bucket '$S3_BUCKET'."
                
                # Delete the source directory after successful upload
                log_info "Deleting source directory '$DIRECTORY_TO_DELETE' after successful upload..."
                set +e  # Disable exit on error temporarily
                rm -rf "$DIRECTORY_TO_DELETE"
                DELETE_STATUS=$?
                set -e  # Re-enable exit on error
                
                if [ $DELETE_STATUS -eq 0 ]; then
                    log_info "Source directory '$DIRECTORY_TO_DELETE' successfully deleted."
                else
                    log_error "Failed to delete source directory '$DIRECTORY_TO_DELETE'. Status: $DELETE_STATUS"
                    # Not exiting with error as the upload was successful
                fi
                
                log_info "===== SCRIPT COMPLETED SUCCESSFULLY ====="
                exit 0
            else
                log_error "Failed to upload file '$newFileName' to bucket '$S3_BUCKET'. Status: $UPLOAD_STATUS"
                exit $UPLOAD_STATUS
            fi
        else
            log_error "Could not extract TMDB ID from filename. Exiting."
            exit 1
        fi
    else
        log_error "Could not extract hash from directory name. Exiting."
        exit 1
    fi
fi 