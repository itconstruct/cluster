#!/bin/bash

NAMESPACES=$(kubectl get ns --no-headers | awk '{print $1}')

for ns in $NAMESPACES; do
  echo "🔍 Checking namespace: $ns"

  # 1. Detect stuck volsync pods
  kubectl get pods -n "$ns" --no-headers | grep "^volsync-" | grep -E 'Pending|ContainerCreating|Error' && \
    echo "⚠️  Stuck VolSync pod(s) detected in $ns"

  # 2. Detect PVCs in Pending or Terminating
  kubectl get pvc -n "$ns" --no-headers | grep -E 'Pending|Terminating' && \
    echo "⚠️  PVCs in problematic state in $ns"

  # 3. Find VolumeSnapshots not ReadyToUse or stuck
  kubectl get volumesnapshots -n "$ns" -o json | jq -r '
    .items[] | select(.status.readyToUse == false or (.metadata.finalizers | length > 0)) |
    "\(.metadata.name) \(.status.readyToUse) \(.metadata.finalizers | join(","))"
  ' | while read -r line; do
    snapshot=$(echo "$line" | awk '{print $1}')
    echo "⚠️  Snapshot $snapshot is not ready or has finalizers in $ns"
    
    echo "➡️  Removing finalizers from $snapshot"
    kubectl patch volumesnapshot "$snapshot" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge
    kubectl delete volumesnapshot "$snapshot" -n "$ns" --ignore-not-found
  done

  # 4. Check if any Longhorn volume clone is stuck
  kubectl get pvc -n "$ns" -o custom-columns=NAME:.metadata.name,VOL:.spec.volumeName --no-headers | grep volsync | while read -r pvc vol; do
    if [[ -n "$vol" ]]; then
      state=$(kubectl get volumes.longhorn.io "$vol" -n longhorn-system -o jsonpath='{.status.cloneStatus.state}' 2>/dev/null)
      if [[ "$state" != "completed" && "$state" != "" ]]; then
        echo "⚠️  Longhorn volume $vol is in clone state: $state (from PVC $pvc)"
      fi
    fi
  done

  echo
done
