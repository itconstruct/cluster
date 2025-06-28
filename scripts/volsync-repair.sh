#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

printf "${BLUE}🩺 Starting VolSync diagnostics and repair...${NC}\n"

# Track already processed charts to avoid infinite loops
declare -A processed_charts

# Get all namespaces
namespaces=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')

for ns in $namespaces; do
  volsync_pods=$(kubectl get pods -n "$ns" -o json | jq -r '.items[] | select(.metadata.name | test("^volsync-src")) | [.metadata.name, .status.phase] | @tsv')
  if [[ -z "$volsync_pods" ]]; then
    continue
  fi

  # Group pods by chart prefix
  declare -A chart_prefixes
  while IFS=$'\t' read -r pod_name pod_status; do
    prefix=$(cut -d'-' -f1-5 <<< "$pod_name")
    chart_prefixes["$prefix"]+="$pod_name $pod_status\n"
  done <<< "$volsync_pods"

  for chart in "${!chart_prefixes[@]}"; do
    # Skip if we've already tried this one
    if [[ -n "${processed_charts["$ns/$chart"]:-}" ]]; then
      continue
    fi

    pod_lines=$(echo -e "${chart_prefixes[$chart]}")
    main_pod_line=$(echo "$pod_lines" | grep -v 'Completed' | head -n1)
    pod_name=$(cut -d' ' -f1 <<< "$main_pod_line")
    pod_status=$(cut -d' ' -f2 <<< "$main_pod_line")

    if [[ "$pod_status" == "Running" ]]; then
      continue
    fi

    printf "\n${RED}🚨 Chart in namespace [$ns] has issues:${NC}\n"
    printf "  ⛔ Pod: ${pod_name} → Status: ${pod_status}\n"

    pvcs=$(kubectl get pvc -n "$ns" -o json | jq -r ".items[] | select(.metadata.name | contains(\"$chart\")) | .metadata.name")
    if [[ -z "$pvcs" ]]; then
      printf "  📦 PVC: None found\n"
    else
      printf "  📦 PVC: $pvcs\n"
    fi

    longhorn_vol=$(kubectl get volumes.longhorn.io -n longhorn-system -o json | jq -r ".items[] | select(.spec.fromBackup == null and .spec.numberOfReplicas != null and (.metadata.name | contains(\"$chart\"))) | [.metadata.name, .status.state, .status.robustness] | @tsv")
    if [[ -z "$longhorn_vol" ]]; then
      printf "  💾 Longhorn Volume: -\n"
    else
      printf "  💾 Longhorn Volume: $longhorn_vol\n"
    fi

    printf "${BLUE}🔍 Current pod status for namespace $ns:${NC}\n"
    kubectl get pods -n "$ns"

    read -rp $'\n🛠️  Do you want to auto-repair this chart? (y/n): ' confirm
    if [[ "$confirm" != "y" ]]; then
      printf "⏭️  Skipping $chart\n"
      processed_charts["$ns/$chart"]=1
      continue
    fi

    printf "🔧 Repairing chart in $ns...\n"

    printf "  ➤ Checking for stuck VolumeSnapshots in $ns\n"
    snapshots=$(kubectl get volumesnapshot -n "$ns" -o json | jq -r ".items[] | select(.metadata.name | contains(\"$chart\")) | .metadata.name")
    for snap in $snapshots; do
      if kubectl get volumesnapshot "$snap" -n "$ns" -o json | jq -e '.metadata.finalizers' &>/dev/null; then
        printf "    - Removing finalizers from snapshot $snap\n"
        kubectl patch volumesnapshot "$snap" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge
      fi
      kubectl delete volumesnapshot "$snap" -n "$ns" || true
    done

    printf "  ➤ Deleting all VolSync pods with prefix $chart in $ns\n"
    pods_to_delete=$(kubectl get pods -n "$ns" -o name | grep "$chart" || true)
    for p in $pods_to_delete; do
      printf "    - Deleting pod ${p##*/}\n"
      kubectl delete "$p" -n "$ns" || true
    done

    printf "  ➤ Deleting PVCs\n"
    for pvc in $pvcs; do
      kubectl delete pvc "$pvc" -n "$ns" || true
    done

    # Mark chart as processed
    processed_charts["$ns/$chart"]=1

    # Wait up to 120 seconds for pod to restart
    printf "  ⏳ Waiting for VolSync pod to restart in $ns..."
    for i in {1..24}; do
      sleep 5
      restarted_pod=$(kubectl get pods -n "$ns" -o json | jq -r ".items[] | select(.metadata.name | contains(\"$chart\")) | select(.status.phase == \"Running\") | .metadata.name" | head -n1)
      if [[ -n "$restarted_pod" ]]; then
        printf "${GREEN} Done${NC}\n"

        # Check logs for restic lock errors
        logs=$(kubectl logs "$restarted_pod" -n "$ns" 2>/dev/null || true)
        if echo "$logs" | grep -qE "repo already locked|circuit breaker open"; then
          printf "${YELLOW}  🔓 Detected restic lock issue. Running restic unlock in $restarted_pod...${NC}\n"
          kubectl exec -n "$ns" "$restarted_pod" -- restic unlock || printf "${RED}  ⚠️ Failed to unlock restic in $restarted_pod${NC}\n"
        fi
        break
      fi
      [[ "$i" -eq 24 ]] && printf "${RED} Timed out waiting for pod restart.${NC}\n"
    done
  done

done
