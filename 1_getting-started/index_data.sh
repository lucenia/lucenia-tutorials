#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <input_file.bz2>"
    exit 1
fi

# Input file passed as an argument
INPUT_FILE="$1"
ADMIN_PASSWORD="${LUCENIA_INITIAL_ADMIN_PASSWORD}"
LINES_PER_BLOCK="${INDEX_BULK_WINDOW_SIZE}"

# Check if the environment variables are set
if [ -z "$ADMIN_PASSWORD" ]; then
    echo "Error: LUCENIA_INITIAL_ADMIN_PASSWORD environment variable is not set."
    exit 1
fi

if [ -z "$LINES_PER_BLOCK" ]; then
    echo "Error: INDEX_BULK_WINDOW_SIZE environment variable is not set."
    exit 1
fi

# Logfile and temporary directory in scratch directory
LOG_DIR="scratch"
TEMP_DIR="$LOG_DIR/temp_chunks"
LOGFILE="$LOG_DIR/bulk_post.log"
mkdir -p "$TEMP_DIR"

# URL for the curl POST request
URL="https://localhost:9200/nyc_taxis/_bulk"

# Print notification to the user
echo "Decompressing and chunking input file..."

# Decompress the bz2 file and split it into chunks with the specified number of lines
bzcat "$INPUT_FILE" | split -l "$LINES_PER_BLOCK" - "$TEMP_DIR/chunk_"

# Count the total number of chunks
TOTAL_CHUNKS=$(ls "$TEMP_DIR"/chunk_* | wc -l)
CHUNK_COUNT=0

# Display initial progress
echo "Indexing data..."
printf "Progress: [%-50s] 0%% (0/%d chunks)\r" "" "$TOTAL_CHUNKS"

# Process each chunk and display a progress bar
for CHUNK in "$TEMP_DIR"/chunk_*; do
    if [ -e "$CHUNK" ]; then
        CHUNK_COUNT=$((CHUNK_COUNT + 1))
        echo "Processing $CHUNK" >> "$LOGFILE"

        # Update progress bar
        PROGRESS=$((CHUNK_COUNT * 100 / TOTAL_CHUNKS))
        BAR_LENGTH=50
        FILLED=$((PROGRESS * BAR_LENGTH / 100))
        UNFILLED=$((BAR_LENGTH - FILLED))
        PROGRESS_BAR=$(printf "%${FILLED}s" | tr ' ' '#')
        PROGRESS_BAR=$(printf "%s%${UNFILLED}s" "$PROGRESS_BAR" | tr ' ' '-')
 
        printf "\rProgress: [%s] %3d%% (%d/%d chunks)" "$PROGRESS_BAR" "$PROGRESS" "$CHUNK_COUNT" "$TOTAL_CHUNKS"

        curl -s -XPOST "$URL" \
             -u "admin:${ADMIN_PASSWORD}" \
             --insecure \
             --header 'Content-Type: application/x-ndjson' \
             --data-binary @"$CHUNK" > /dev/null 2>&1

        # Log successful processing
        echo "Window $WINDOW_NUMBER successfully processed and indexed." >> "$LOGFILE"
        rm "$CHUNK"
    fi
done

# Clean up temporary directory
rm -rf "$TEMP_DIR"

# Finish progress bar
printf "\nProcessing completed. Check %s for details.\n" "$LOGFILE"

