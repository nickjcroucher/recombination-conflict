#!/usr/bin/env bash

# File containing the list of URLs
URL_FILE="phaster_urls.list"

# Directory to save files (current dir here)
OUTDIR="."

mkdir -p "$OUTDIR"

while read -r url; do
    # Skip empty lines
    [ -z "$url" ] && continue
    
    # Extract accession code between 'jobs/' and '/summary.txt'
    accession=$(echo "$url" | sed -E 's#.*/jobs/([^/]+)/summary\.txt#\1#')
    
    if [[ ! -e "${OUTDIR}/${accession}.txt" ]]; then

      # Download and save as accession.txt
      wget -O "${OUTDIR}/${accession}.txt" "$url"
    
    fi
    
done < "$URL_FILE"
