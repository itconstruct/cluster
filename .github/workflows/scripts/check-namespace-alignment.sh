#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "🔍 Checking namespace alignment for changed HelmReleases..."

BASE="${BASE:-origin/main}"
errors=0
checked=0

mapfile -t dirs < <(git diff --name-only --diff-filter=ACMR "$BASE...HEAD" \
  | grep -E '(helm-release|kustomization|ks|namespace)\.yaml$' \
  | xargs -r -n1 dirname | sort -u)

for dir in "${dirs[@]}"; do
  # A changed ks.yaml lives one level above app/
  hr="$dir/helm-release.yaml"
  [[ -f "$hr" ]] || hr="$dir/app/helm-release.yaml"
  [[ -f "$hr" ]] || continue
  app_dir=$(dirname "$hr")
  checked=$((checked + 1))

  hr_ns=$(yq 'select(.kind == "HelmRelease") | .metadata.namespace // ""' "$hr" | head -n1)
  [[ -z "$hr_ns" || "$hr_ns" == *'$'* ]] && continue

  kz_ns=""
  if [[ -f "$app_dir/kustomization.yaml" ]]; then
    kz_ns=$(yq '.namespace // ""' "$app_dir/kustomization.yaml")
  fi

  nsfile_ns=""
  if [[ -f "$app_dir/namespace.yaml" ]]; then
    nsfile_ns=$(yq 'select(.kind == "Namespace") | .metadata.name // ""' "$app_dir/namespace.yaml" | head -n1)
  fi

  ks_ns=""
  ks="$(dirname "$app_dir")/ks.yaml"
  if [[ -f "$ks" ]]; then
    export rel="${app_dir#./}"
    ks_ns=$(yq '
      select(.kind == "Kustomization" and
        (.spec.path == strenv(rel) or .spec.path == "./" + strenv(rel)))
      | .spec.targetNamespace // ""' "$ks" | head -n1)
  fi

  for pair in "app/kustomization.yaml namespace|$kz_ns" \
              "app/namespace.yaml name|$nsfile_ns" \
              "ks.yaml targetNamespace|$ks_ns"; do
    src=${pair%%|*}
    ns=${pair#*|}
    if [[ -n "$ns" && "$ns" != *'$'* && "$ns" != "$hr_ns" ]]; then
      echo "::error file=$hr::HelmRelease namespace '$hr_ns' != $src '$ns'"
      errors=$((errors + 1))
    fi
  done
done

if (( errors > 0 )); then
  echo "❌ Namespace alignment check failed with $errors error(s)."
  exit 1
fi
echo "✅ Namespace alignment OK ($checked HelmRelease(s) checked, ${#dirs[@]} changed dir(s))."
