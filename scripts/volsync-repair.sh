#!/usr/bin/env bash
set -euo pipefail

# ============ Colours ============
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'

# ============ Flags ============
AUTO_YES=0
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then AUTO_YES=1; fi

printf "${BLUE}🩺 Starting VolSync diagnostics and repair...${NC}\n"

# ============ Helpers ============

# 30s dynamic spinner wait for a Running volsync pod matching CHART_KEY
wait_for_running_pod() {
  local ns="$1" key="$2"
  local MAX_WAIT=30 INTERVAL=2 elapsed=0
  local spinner='|/-\' i=0
  printf "  ⏳ Waiting for new VolSync pod to become Running..."
  while (( elapsed < MAX_WAIT )); do
    sleep "$INTERVAL"; ((elapsed+=INTERVAL))
    printf "\r  ⏳ Waiting for new VolSync pod... %c (%02ds)" "${spinner:i++%${#spinner}:1}" "$elapsed"
    local pod
    pod="$(kubectl -n "$ns" get pods -o json \
      | jq -r ".items[]
        | select(.metadata.name | test(\"^volsync-(src|dest)-.*${key//\//\\/}.*\"))
        | select(.status.phase==\"Running\")
        | .metadata.name" \
      | head -n1)"
    if [[ -n "$pod" ]]; then
      printf "\r${GREEN}  ✅ New VolSync pod is Running: %s${NC}\n" "$pod"
      return 0
    fi
  done
  printf "\r${RED}  ❌ Timed out waiting for new VolSync pod after %ds${NC}\n" "$MAX_WAIT"
  return 1
}

# Remove finalizers + delete a VolumeSnapshot and its bound VolumeSnapshotContent (if present)
zap_snapshot_and_content() {
  local ns="$1" snap="$2"
  if kubectl -n "$ns" get volumesnapshot "$snap" >/dev/null 2>&1; then
    local vsc
    vsc="$(kubectl -n "$ns" get volumesnapshot "$snap" -o json \
      | jq -r '.status.boundVolumeSnapshotContentName // empty')"
    kubectl -n "$ns" patch volumesnapshot "$snap" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    kubectl -n "$ns" delete volumesnapshot "$snap" --wait=false || true
    if [[ -n "$vsc" ]] && kubectl get volumesnapshotcontent "$vsc" >/dev/null 2>&1; then
      kubectl patch volumesnapshotcontent "$vsc" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      kubectl delete volumesnapshotcontent "$vsc" --wait=false || true
    fi
  fi
}

# Track processed jobs to avoid loops
declare -A processed

# Gather non-succeeded volsync-src pods cluster-wide
mapfile -t volsync_pods < <(
  kubectl get pods -A -o json | jq -r '
    .items[]
    | select(.metadata.name | startswith("volsync-src-"))
    | select(.status.phase != "Succeeded")
    | [.metadata.namespace, .metadata.name, (.metadata.labels["job-name"] // ""), .status.phase]
    | @tsv'
)

if [[ ${#volsync_pods[@]} -eq 0 ]]; then
  printf "${GREEN}✅ No problematic VolSync pods found.${NC}\n"
  exit 0
fi

for line in "${volsync_pods[@]}"; do
  ns=$(printf "%s" "$line" | cut -f1)
  pod=$(printf "%s" "$line" | cut -f2)
  job=$(printf "%s" "$line" | cut -f3)
  phase=$(printf "%s" "$line" | cut -f4)

  # Fallback job when label missing (strip trailing -<rand> from pod name)
  if [[ -z "$job" ]]; then job="${pod%-*}"; fi

  key="$ns/$job"
  [[ -n "${processed[$key]:-}" ]] && continue
  processed[$key]=1

  # Base name (TrueCharts pattern): strip "volsync-src-" prefix
  base="${job#volsync-src-}"
  CHART_KEY="$base"                         # <— single key used everywhere
  : "${CHART_KEY:?CHART_KEY not set}"       # fail fast if empty

  printf "\n${RED}🚨 VolSync issue detected:${NC}\n"
  printf "  📍 Namespace: %s\n" "$ns"
  printf "  🧱 Job:       %s\n" "$job"
  printf "  📦 Base:      %s\n" "$base"
  printf "  ⛔ Pod:       %s → Status: %s\n" "$pod" "$phase"

  # The VolSync source PVC
  src_pvc="volsync-${base}-src"
  printf "  🔎 Checking PVC %s in %s...\n" "$src_pvc" "$ns"
  if ! kubectl -n "$ns" get pvc "$src_pvc" &>/dev/null; then
    printf "    ${YELLOW}PVC %s not found – naming may differ, skipping.${NC}\n" "$src_pvc"
    continue
  fi
  kubectl -n "$ns" get pvc "$src_pvc"

  printf "\n${BLUE}🔍 Current pods in %s:${NC}\n" "$ns"
  kubectl -n "$ns" get pods

  # Confirm
  if [[ "$AUTO_YES" -eq 1 ]]; then
    printf "🛠️  Auto-repair enabled (--yes). Proceeding.\n"
  else
    if [[ -t 0 ]]; then
      read -rp $'\n🛠️  Do you want to auto-repair this chart? (y/n): ' ans
    elif [[ -r /dev/tty ]]; then
      read -rp $'\n🛠️  Do you want to auto-repair this chart? (y/n): ' ans </dev/tty
    else
      printf "${YELLOW}No TTY available; skipping. Use --yes to run non-interactively.${NC}\n"
      ans="n"
    fi
    [[ "$ans" != "y" ]] && { printf "⏭️  Skipping %s/%s\n" "$ns" "$base"; continue; }
  fi

  printf "${YELLOW}🔧 Repairing %s/%s ...${NC}\n" "$ns" "$base"

  # Determine VolumeSnapshot name used by the source PVC (fallback to common pattern)
  snapshot_name="$(kubectl -n "$ns" get pvc "$src_pvc" -o jsonpath='{.spec.dataSource.name}' 2>/dev/null || echo "")"
  [[ -z "$snapshot_name" ]] && snapshot_name="volsync-${base}-src"
  printf "  ➤ Using VolumeSnapshot: %s\n" "$snapshot_name"

  # Get bound VolumeSnapshotContent (if snapshot exists)
  vsc=""
  if kubectl -n "$ns" get volumesnapshot "$snapshot_name" &>/dev/null; then
    vsc="$(kubectl -n "$ns" get volumesnapshot "$snapshot_name" \
      -o jsonpath='{.status.boundVolumeSnapshotContentName}' 2>/dev/null || echo "")"
  else
    printf "    ${YELLOW}VolumeSnapshot %s not found (may already be gone).${NC}\n" "$snapshot_name"
  fi

  # Delete VolSync Job and any pods
  printf "  ➤ Deleting VolSync Job and Pods\n"
  kubectl -n "$ns" delete job "$job" --ignore-not-found || true
  kubectl -n "$ns" delete pod -l job-name="$job" --ignore-not-found || true

  # Clean up snapshot + its content (remove finalizers first)
  if [[ -n "$vsc" ]]; then
    printf "  ➤ Patching VolumeSnapshotContent %s finalizers (if any)\n" "$vsc"
    kubectl patch volumesnapshotcontent "$vsc" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  fi
  zap_snapshot_and_content "$ns" "$snapshot_name"

  # Delete source PVC so VolSync can recreate it cleanly
  printf "  ➤ Deleting PVC %s\n" "$src_pvc"
  kubectl -n "$ns" delete pvc "$src_pvc" --wait=false || true

  # Wait for the new volsync pod to spin up
  wait_for_running_pod "$ns" "$CHART_KEY" || true

  # Trigger a manual sync if the ReplicationSource exists
  printf "  ➤ Triggering manual sync on ReplicationSource %s (if present)\n" "$base"
  kubectl -n "$ns" patch replicationsource "$base" \
    --type=merge -p '{"spec":{"trigger":{"manual":true}}}' >/dev/null 2>&1 || true

done

printf "\n${GREEN}✅ VolSync diagnostics/repair pass completed.${NC}\n"
