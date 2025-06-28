#!/bin/bash

NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
CLEANUP=false

if [[ "$1" == "--cleanup" ]]; then
  CLEANUP=true
  echo "⚠️  Cleanup mode enabled — VolSync error pods will be deleted."
else
  echo "🔍 Running in diagnostic mode only. Use --cleanup to enable cleanup."
fi

echo "====================================="
echo "📦 Checking for failed VolSync pods..."
echo "====================================="
for ns in $NAMESPACES; do
  pods=$(kubectl get pods -n "$ns" --no-headers | grep 'volsync' | grep -E 'Error|CrashLoopBackOff|Completed' || true)
  if [[ -n "$pods" ]]; then
    echo -e "\n❗ Namespace: $ns"
    echo "$pods"
    if [[ "$CLEANUP" == true ]]; then
      echo "🧹 Deleting failed VolSync pods in $ns..."
      echo "$pods" | awk '{print $1}' | xargs -r -n1 kubectl delete pod -n "$ns"
    fi
  fi
done

echo -e "\n====================================="
echo "📄 Checking PVCs in Pending or Terminating..."
echo "====================================="
for ns in $NAMESPACES; do
  pvc_status=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | grep -E 'Pending|Terminating|Lost' || true)
  if [[ -n "$pvc_status" ]]; then
    echo -e "\n❗ Namespace: $ns"
    echo "$pvc_status"
  fi
done

echo -e "\n====================================="
echo "🔍 Checking VolumeSnapshots not Ready..."
echo "====================================="
for ns in $NAMESPACES; do
  snapshots=$(kubectl get volumesnapshot -n "$ns" -o json 2>/dev/null |
    jq -r '.items[] | select(.status.readyToUse != true) | "\(.metadata.name)\t\(.status.readyToUse)"')
  if [[ -n "$snapshots" ]]; then
    echo -e "\n❗ Namespace: $ns"
    echo -e "Snapshot\tReadyToUse"
    echo "$snapshots"
  fi
done

echo -e "\n✅ Done."
