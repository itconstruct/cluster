#!/bin/bash

# Track processed namespaces
PROCESSED_NAMESPACES=()

function has_processed_namespace() {
  local ns=$1
  for processed in "${PROCESSED_NAMESPACES[@]}"; do
    if [[ "$processed" == "$ns" ]]; then
      return 0
    fi
  done
  return 1
}

NAMESPACES=$(kubectl get ns --no-headers | awk '{print $1}')
echo "🩺 Starting VolSync diagnostics and repair..."

for ns in $NAMESPACES; do
  has_processed_namespace "$ns" && continue

  mapfile -t pods < <(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep '^volsync-' | grep -E 'Pending|ContainerCreating|Error')
  if [[ ${#pods[@]} -eq 0 ]]; then
    continue
  fi

  pod_line=${pods[0]}
  pod_name=$(echo "$pod_line" | awk '{print $1}')
  pod_status=$(echo "$pod_line" | awk '{print $3}')

  pvc_list=$(kubectl get pvc -n "$ns" --no-headers | grep volsync | awk '{print $1}')

  vol_name=""
  for pvc in $pvc_list; do
    vol=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    vol_state=$(kubectl get volumes.longhorn.io "$vol" -n longhorn-system -o jsonpath='{.status.cloneStatus.state}' 2>/dev/null)
    [[ -n "$vol" ]] && vol_name="$vol" && break
  done
  vol_state=${vol_state:-"-"}

  echo -e "\n🚨 Chart in namespace [${ns}] has issues:"
  echo "  ⛔ Pod: ${pod_name} → Status: ${pod_status}"
  echo "  📦 PVC: ${pvc_list}"
  echo "  💾 Longhorn Volume: ${vol_name} → Clone State: ${vol_state}"

  echo "🔍 Current pod status for namespace ${ns}:"
  kubectl get pods -n "$ns"
  echo

  read -rp "🛠️  Do you want to auto-repair this chart? (y/n): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "🔧 Repairing chart in $ns..."

    # Delete VolSync pod
    if [[ -n "$pod_name" ]]; then
      echo "  ➤ Deleting VolSync pod $pod_name"
      kubectl delete pod "$pod_name" -n "$ns" --ignore-not-found
    fi

    # Delete PVCs
    for pvc in $pvc_list; do
      echo "  ➤ Deleting PVC $pvc"
      kubectl delete pvc "$pvc" -n "$ns" --ignore-not-found
    done

    # Clean finalizers on stuck snapshots
    mapfile -t snapshots < <(kubectl get volumesnapshots -n "$ns" -o json | jq -r '.items[] | select(.metadata.finalizers | length > 0) | .metadata.name')
    for snap in "${snapshots[@]}"; do
      echo "  ➤ Patching and deleting stuck VolumeSnapshot $snap"
      kubectl patch volumesnapshot "$snap" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge
      kubectl delete volumesnapshot "$snap" -n "$ns" --ignore-not-found
    done
  else
    echo "⏭️  Skipping $ns"
  fi

  PROCESSED_NAMESPACES+=("$ns")

done
