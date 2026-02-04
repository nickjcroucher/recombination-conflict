#!/usr/bin/env bash
set -euo pipefail

LIST=$1  # one accession per line
OUTDIR=${2/ /_}
mkdir -p "${OUTDIR}_PHASTER"

UA="YourLab/PHASTER-precomputed-client (contact: you@example.com)"

check_precomputed() {
  local acc="$1"
  # Try the zip first; 200 means precomputed exists
  curl -sS -I -m 20 -H "User-Agent: $UA" "http://phaster.ca/submissions/${acc}.zip" | head -n1 | grep -q "200"
}

fetch_summary_if_precomputed() {
  local acc="$1"
  local out="${OUTDIR}/${acc}.summary.txt"
  local json="${OUTDIR}/${acc}.response.json"

  if [ -s "$out" ]; then
    echo "Cached: $acc"
    return 0
  fi

  # Jitter to be polite
  sleep $(( (RANDOM % 3) + 1 ))

  if check_precomputed "$acc"; then
    # Safe to call API; job is already complete
    resp=$(curl -sS --fail -m 30 -H "User-Agent: $UA" "http://phaster.ca/phaster_api?acc=${acc}")
    echo "$resp" > "$json"
    status=$(jq -r '.status // ""' < "$json")
    if [ "$status" = "Complete" ]; then
      jq -r '.summary // empty' < "$json" > "$out"
      if [ -s "$out" ]; then
        echo "Done: $acc"
      else
        echo "No summary text for $acc; see $json"
      fi
    else
      # Do not poll; skip to avoid queuing any new job
      echo "Not precomputed (status: $status). Skipping $acc."
      rm -f "$json"
    fi
  else
    echo "No precomputed submission found for $acc. Skipping."
  fi
}

export -f check_precomputed fetch_summary_if_precomputed
export OUTDIR UA

# Sequential or very low concurrency is recommended
cat "$LIST" | sed 's/\r$//' | grep -v '^\s*$' | xargs -n1 -P1 -I{} bash -c 'fetch_summary_if_precomputed "$@"' _ {}
