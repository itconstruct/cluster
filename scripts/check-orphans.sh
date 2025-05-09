#!/usr/bin/env bash
set -euo pipefail

is_ci=${CI:-false}
exit_code=0

# Function for printing only when not in CI
log() {
  if [[ "$is_ci" != "true" ]]; then
    echo "$@"
  fi
}

log "🔍 Checking for orphaned, duplicate, or broken ks.yaml references..."

# Collect referenced ks.yaml paths
referenced_files=$(grep -rh --include=kustomization.yaml '^- ' clusters/main/kubernetes \
  | awk '{print $2}' \
  | sed 's|/ks.yaml||' \
  | sort \
  | uniq)

# Find all ks.yaml files relative to the kustomization folders
all_files=$(find clusters/main/kubernetes -name ks.yaml \
  | sed 's|clusters/main/kubernetes/||' \
  | sed 's|/ks.yaml||' \
  | sort)

# Orphaned = in filesystem but not referenced
orphans=$(comm -23 <(echo "$all_files") <(echo "$referenced_files"))
if [[ -n "$orphans" ]]; then
  log "❌ Orphaned ks.yaml files not referenced in any kustomization.yaml:"
  log "$orphans"
  exit_code=1
fi

# Duplicates = referenced more than once
duplicates=$(grep -rh --include=kustomization.yaml '^- ' clusters/main/kubernetes \
  | awk '{print $2}' \
  | sort \
  | uniq -d)

if [[ -n "$duplicates" ]]; then
  log "⚠️ Duplicate ks.yaml references found:"
  log "$duplicates"
  exit_code=1
fi

# Broken = referenced but file does not exist
missing=""
for path in $referenced_files; do
  if [[ ! -f "clusters/main/kubernetes/$path" ]]; then
    missing+="$path"$'\n'
  fi
done

if [[ -n "$missing" ]]; then
  log "🚫 Broken ks.yaml references (file does not exist):"
  log "$missing"
  exit_code=1
fi

exit $exit_code

