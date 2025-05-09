#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Checking namespace alignment between HelmRelease and kustomization.yaml files..."

errors=0

for hr in $(find . -name helm-release.yaml); do
  ns=$(yq e '.metadata.namespace' "$hr")
  dir=$(dirname "$hr")
  kustomization="$dir/../kustomization.yaml"

  if [[ -f "$kustomization" ]]; then
    kns=$(yq e '.namespace' "$kustomization")
    if [[ "$ns" != "$kns" ]]; then
      echo "❌ Namespace mismatch:"
      echo "   - HelmRelease:      $hr (namespace: $ns)"
      echo "   - Kustomization:    $kustomization (namespace: $kns)"
      errors=$((errors + 1))
    fi
  else
    echo "⚠️  No kustomization.yaml found for $hr"
  fi
done

if [[ $errors -gt 0 ]]; then
  echo "❌ Namespace alignment check failed with $errors error(s)."
  exit 1
else
  echo "✅ Namespace alignment check passed."
fi

