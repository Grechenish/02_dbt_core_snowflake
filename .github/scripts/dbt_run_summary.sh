#!/usr/bin/env bash
# Writes a short summary of a dbt run_results.json to the GitHub job summary page:
# counts per status, then every node that didn't simply pass (warnings, errors, skips).
# Usage: dbt_run_summary.sh <title> <path/to/run_results.json>
set -euo pipefail
title="$1"
results="$2"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ ! -f "$results" ]; then
  echo "### $title: no run_results.json (dbt did not start)" >> "$summary"
  exit 0
fi

{
  echo "### $title"
  echo
  jq -r '.results | group_by(.status) | map("- **\(.[0].status)**: \(length)") | .[]' "$results"
  echo
  jq -r '.results[] | select(.status != "success" and .status != "pass")
         | "- `\(.unique_id)`: \(.status)\(if .failures then " (\(.failures) rows)" else "" end) \(.message // "" | gsub("\n"; " "))"' "$results"
} >> "$summary"
