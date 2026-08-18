#!/usr/local/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <input_accessions.txt> [output.tsv]" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq required"; exit 1; }

infile="$1"
outfile="${2:-metadata.tsv}"
errfile="${outfile}.errors.log"
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT

ua="mge_search/1.0 (contact: you@institute.edu)"
api_key="${NCBI_API_KEY:-}"

# conservative base pacing for shared cluster workers
base_sleep="${BASE_SLEEP:-0.6}"   # seconds between accessions
max_retry="${MAX_RETRY:-6}"       # retries per HTTP call

: > "$errfile"
echo -e "query_accession\tresolved_accession\tuid\tbiosample\ttaxid\ttitle\tresolved_from" > "$outfile"

build_url() {
  local base="$1"
  if [[ -n "$api_key" ]]; then
    echo "${base}&api_key=${api_key}"
  else
    echo "$base"
  fi
}

# curl with retry/backoff on 429/5xx
fetch() {
  local url="$1"
  local attempt=0
  local wait=1
  local out rc code hdr body

  while :; do
    hdr="$(mktemp)"
    body="$(mktemp)"
    rc=0
    curl -sS -A "$ua" -D "$hdr" -o "$body" "$url" || rc=$?
    code="$(awk 'toupper($1) ~ /^HTTP/ {c=$2} END{print c+0}' "$hdr")"

    if [[ "$rc" -eq 0 && "$code" -ge 200 && "$code" -lt 300 ]]; then
      cat "$body"
      rm -f "$hdr" "$body"
      return 0
    fi

    # retry on 429 or 5xx
    if [[ "$code" -eq 429 || ( "$code" -ge 500 && "$code" -lt 600 ) ]]; then
      attempt=$((attempt+1))
      if [[ "$attempt" -gt "$max_retry" ]]; then
        echo "[HTTP_FAIL] code=$code url=$url" >> "$errfile"
        rm -f "$hdr" "$body"
        return 1
      fi

      ra="$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:/ {gsub("\r","",$2); print $2; exit}' "$hdr")"
      if [[ -n "${ra:-}" && "$ra" =~ ^[0-9]+$ ]]; then
        sleep "$ra"
      else
        # exponential backoff + jitter
        jitter_ms=$((RANDOM % 700))
        sleep "$(awk -v w="$wait" -v j="$jitter_ms" 'BEGIN{printf "%.3f", w + (j/1000)}')"
        wait=$((wait*2))
        [[ "$wait" -gt 30 ]] && wait=30
      fi
    else
      echo "[HTTP_FAIL] code=$code rc=$rc url=$url" >> "$errfile"
      rm -f "$hdr" "$body"
      return 1
    fi

    rm -f "$hdr" "$body"
  done
}

get_uid() {
  local acc="$1"
  local url json
  url="$(build_url "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=${acc}%5BACCN%5D&retmode=json")"
  json="$(fetch "$url" || true)"
  echo "$json" | jq -r '.esearchresult.idlist[0] // empty'
}

get_json_fields() {
  local uid="$1"
  local url json bios tax title
  url="$(build_url "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=nuccore&id=${uid}&retmode=json")"
  json="$(fetch "$url" || true)"
  bios="$(echo "$json"  | jq -r --arg u "$uid" '.result[$u].biosample // empty')"
  tax="$(echo "$json"   | jq -r --arg u "$uid" '.result[$u].taxid // empty')"
  title="$(echo "$json" | jq -r --arg u "$uid" '.result[$u].title // empty')"
  printf "%s\t%s\t%s\n" "$bios" "$tax" "$title"
}

sed 's/\r$//' "$infile" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF && $0 !~ /^#/' > "$tmpfile"

while IFS= read -r acc || [[ -n "$acc" ]]; do
  resolved="$acc"
  source="direct"

  uid="$(get_uid "$acc")"
  if [[ -z "$uid" ]]; then
    if [[ "$acc" == NZ_* ]]; then alt="${acc#NZ_}"; else alt="NZ_${acc}"; fi
    uid="$(get_uid "$alt")"
    if [[ -n "$uid" ]]; then
      resolved="$alt"
      source="alias:${alt}"
    fi
  fi

  if [[ -z "$uid" ]]; then
    echo -e "${acc}\tNA\tNA\tNA\tNA\tNA\tno_uid" >> "$outfile"
    echo "[NO_UID] $acc" >> "$errfile"
    sleep "$base_sleep"
    continue
  fi

  IFS=$'\t' read -r bios tax title < <(get_json_fields "$uid")
  [[ -z "$bios" ]] && bios="NA"
  [[ -z "$tax" ]] && tax="NA"
  [[ -z "$title" ]] && title="NA"

  echo -e "${acc}\t${resolved}\t${uid}\t${bios}\t${tax}\t${title}\t${source}" >> "$outfile"

  # pacing + jitter
  jitter_ms=$((RANDOM % 400))
  sleep "$(awk -v b="$base_sleep" -v j="$jitter_ms" 'BEGIN{printf "%.3f", b + (j/1000)}')"
done < "$tmpfile"

echo "Done: $outfile"
echo "Errors: $errfile"
