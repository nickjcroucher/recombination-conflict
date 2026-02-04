#!/usr/bin/env bash
set -euo pipefail

# Configure input/output
input="phaster_accessions.txt"
out="phaster_metadata.tsv"

# Ensure output file exists with header (do not overwrite if present)
if [[ ! -f "$out" || ! -s "$out" ]]; then
  printf "Accession\tBioSampleAccession\tBioSampleName\tSequenceLength\tSequenceDefinition\n" > "$out"
fi

# Build a set of already processed accession IDs (first column), skipping header
processed_set="$(mktemp)"
awk 'NR==1 && $1=="Accession"{next} {print $1}' "$out" > "$processed_set"

# Read input from FD 3 to avoid stdin conflicts
exec 3< "$input"

while IFS= read -r acc <&3 || [[ -n "$acc" ]]; do
  # Normalize line endings and skip blanks
  acc="${acc%$'\r'}"
  [[ -z "${acc//[[:space:]]/}" ]] && continue

  # Skip if this accession already exists in the output
  if grep -Fqx "$acc" "$processed_set"; then
    # Already processed; skip
    continue
  fi

  # Fetch GenBank flatfile (prefer nuccore, fallback to nucleotide)
  gb=$(efetch -db nuccore -id "$acc" -format gb 2>/dev/null || true)
  if [[ -z "$gb" ]]; then
    gb=$(efetch -db nucleotide -id "$acc" -format gb 2>/dev/null || true)
  fi

  if [[ -z "$gb" ]]; then
    # Append NA row and mark as processed to avoid retry next time
    printf "%s\tNA\tNA\tNA\tNA\n" "$acc" >> "$out"
    echo "$acc" >> "$processed_set"
    continue
  fi

  # Parse length, definition, BioSample (portable awk, no advanced regex)
  tsv=$(printf "%s\n" "$gb" | awk '
    BEGIN {
      in_def = 0; def = "";
      in_db  = 0; dblink = "";
      biosample = "";
      len = "";
    }

    # LOCUS line: token immediately before "bp"
    /^LOCUS/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "bp" && i > 1) { len = $(i-1); break }
      }
    }

    # DEFINITION block (content starts at col 13; continuations at 12 spaces)
    substr($0,1,10) == "DEFINITION" {
      in_def = 1;
      def = substr($0, 13);
      next
    }
    in_def && substr($0,1,12) == "            " {
      def = def " " substr($0, 13);
      next
    }
    in_def && substr($0,1,12) != "            " { in_def = 0 }

    # DBLINK block (col 13; continuations at 12 spaces)
    substr($0,1,6) == "DBLINK" {
      in_db = 1;
      dblink = substr($0, 13);
      next
    }
    in_db && substr($0,1,12) == "            " {
      dblink = dblink " " substr($0, 13);
      next
    }
    in_db && substr($0,1,12) != "            " { in_db = 0 }

    # FEATURES source qualifier fallback: /db_xref="BioSample:..."
    index($0, "/db_xref=\"BioSample:") > 0 {
      if (biosample == "") {
        line = $0
        start = index(line, "BioSample:")
        if (start > 0) {
          rest = substr(line, start + 10)
          while (length(rest) > 0 && (substr(rest,1,1) == " " || substr(rest,1,1) == "\t" || substr(rest,1,1) == "\"")) {
            rest = substr(rest, 2)
          }
          endpos = length(rest)
          for (j = 1; j <= length(rest); j++) {
            c = substr(rest, j, 1)
            if (c == "\"" || c == " " || c == ";" || c == ",") { endpos = j - 1; break }
          }
          if (endpos >= 1) { biosample = substr(rest, 1, endpos) }
        }
      }
    }

    END {
      # If DBLINK contains BioSample, parse if not already set
      if (biosample == "" && index(dblink, "BioSample:") > 0) {
        rest = dblink
        pos = index(rest, "BioSample:")
        if (pos > 0) {
          rest = substr(rest, pos + 10)
          while (length(rest) > 0 && (substr(rest,1,1) == " " || substr(rest,1,1) == "\t")) {
            rest = substr(rest, 2)
          }
          endpos = length(rest)
          for (k = 1; k <= length(rest); k++) {
            c = substr(rest, k, 1)
            if (c == " " || c == ";" || c == "," ) { endpos = k - 1; break }
          }
          if (endpos >= 1) { biosample = substr(rest, 1, endpos) }
        }
      }

      if (def == "") def = "NA";
      if (len == "") len = "NA";
      if (biosample == "") biosample = "NA";
      printf "%s\t%s\t%s\n", len, def, biosample;
    }
  ')

  IFS=$'\t' read -r seq_len seq_def biosample_acc <<< "$tsv"

  # Default BioSampleName to the sequence definition; override with BioSample Title when available
  biosample_name="$seq_def"
  if [[ "$biosample_acc" != "NA" ]]; then
    bs_uid=$(esearch -db biosample -query "\"$biosample_acc\"" 2>/dev/null | xtract -pattern Id -element Id || true)
    if [[ -n "$bs_uid" ]]; then
      biosum=$(esummary -db biosample -id "$bs_uid" 2>/dev/null || true)
      t=$(printf "%s\n" "$biosum" | xtract -pattern DocumentSummary -element Title || true)
      [[ -n "$t" ]] && biosample_name="$t"
    fi
  fi

  # Append the new row and mark accession as processed
  printf "%s\t%s\t%s\t%s\t%s\n" "$acc" "$biosample_acc" "$biosample_name" "$seq_len" "$seq_def" >> "$out"
  echo "$acc" >> "$processed_set"
done

# Close FD and remove temp set
exec 3<&-
rm -f "$processed_set"
