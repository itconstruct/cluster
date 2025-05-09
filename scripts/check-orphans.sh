#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Checking for orphaned, duplicate, or broken ks.yaml references..."

root="clusters/main/kubernetes"

# Find all ks.yaml files and normalize to <subfolder>/<name>/ks.yaml
all_files=$(find "$root" -type f -name ks.yaml | sed -E "s|^$root/([^/]+/[^/]+/ks.yaml)|\1|" | sort)

# Extract all referenced paths from any kustomization.yaml
referenced_files=$(grep -rh --include=kustomization.yaml '^- ' "$root" \
  | sed -E 's/^- +//' \
  | grep 'ks.yaml$' \
  | sort)

# Normalize references (remove folder prefix like apps/, core/, etc.)
normalized_references=$(echo "$referenced_files" | sed -E 's|^([^/]+/[^/]+/ks.yaml)|\1|' | sort)

# Find orphaned (in all_files but not referenced)
orphans=$(comm -23 <(echo "$all_files") <(echo "$normalized_references"))

# Find broken references (in referenced list but file doesn't exist)
broken=$(comm -23 <(echo "$normalized_references") <(echo "$all_files"))

# Find duplicates (paths appearing more than once in referenced list)
duplicates=$(echo "$referenced_files" | sort | uniq -d)

# Output
[[ -n "$orphans" ]] && {
  echo -e "\n❌ Orphaned ks.yaml files not referenced in any kustomization.yaml:"
  echo "$orphans"
}

[[ -n "$broken" ]] && {
  echo -e "\n🚫 Broken ks.yaml references (referenced but file not found):"
  echo "$broken"
}

[[ -n "$duplicates" ]] && {
  echo -e "\n⚠️ Duplicate ks.yaml references:"
  echo "$duplicates"
}

[[ -z "$orphans" && -z "$broken" && -z "$duplicates" ]] && echo "✅ All ks.yaml references are valid and used!"
