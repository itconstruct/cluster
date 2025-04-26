#!/usr/bin/env bash
set -euo pipefail

YAML_FILE="../clusters/main/kubernetes/flux-system/notifications/discord/notification.yaml"

# Get all current namespaces from the cluster
actual_namespaces=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort -u)

# Get namespaces from the "discord" Alert's eventSources (HelmRelease only)
alert_namespaces=$(yq eval '
  select(.kind == "Alert" and .metadata.name == "discord")
  | .spec.eventSources[]
  | select(.kind == "HelmRelease" and has("namespace"))
  | .namespace' "$YAML_FILE" | sort -u)

echo "🔍 Checking for missing namespaces..."

# Compare actual vs declared namespaces
missing_namespaces=$(comm -23 <(echo "$actual_namespaces") <(echo "$alert_namespaces"))

if [[ -z "$missing_namespaces" ]]; then
  echo "✅ All HelmRelease namespaces are present in the discord alert config."
else
  echo "⚠️  The following namespaces are missing:"
  echo "$missing_namespaces"
  echo
  echo "📋 Suggested YAML to add:"
  echo "$missing_namespaces" | while read -r ns; do
    [[ -n "$ns" ]] && cat <<EOF
    - kind: HelmRelease
      name: "*"
      namespace: $ns
EOF
  done
fi
