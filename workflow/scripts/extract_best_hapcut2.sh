#!/usr/bin/env bash

main() {
  local input="${1}"

  local top_score_line=$(grep -n BLOCK "${input}" \
                          | sort -k 7 -nr \
                          | cut -f 1 -d ':' \
                          | head -n 1)

  awk -v OFS='\t' -v n="${top_score_line}" '
    NR <= n {next} /^\*\*/ {exit} {print $4, $5, $5}' "${input}"
}

main "${@}"
