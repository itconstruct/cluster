#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Checking for orphaned manifests not referenced in any kustomization.yaml..."

referenced_files=$(grep -rh --include='kustomization.yaml' '^- path:' . | awk '{print $3}' | sort | uniq)
found_orphans=0

for file in $(find clusters kubernetes -type f -name '*.yaml'); do
  relpath="${file#./}"
  if ! echo "$referenced_files" | grep -Fxq "$relpath"; then
    echo "🟠 Orphaned file: $relpath"
    found_orphans=$((found_orphans + 1))
  fi
done

if [[ $found_orphans -gt 0 ]]; then
  echo "⚠️  $found_orphans orphaned manifest(s) found."
else
  echo "✅ No orphaned manifests detected."
fi

