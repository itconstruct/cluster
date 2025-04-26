#!/usr/bin/env bash
set -euo pipefail

SHOW_PODS=false
SHOW_VOLSYNC_CNPG_PVCS=false
RETENTION_THRESHOLD_HOURS=48

IGNORED_NAMESPACES=(
  "blocky" "cert-manager" "cilium-secrets" "cloudflared" "cloudnative-pg"
  "clusterissuer" "default" "external-service" "flux-system" "kube-node-lease"
  "kube-prometheus-stack" "kube-public" "kube-system" "kubernetes-dashboard"
  "kubernetes-reflector" "kyverno" "longhorn-system" "metallb" "metallb-config"
  "nginx-external" "nginx-internal" "openebs" "snapshot-controller" "spegel"
  "system" "system-upgrade" "tailscale" "volsync"
)

EXCLUDED_VOLSYNC_PVCS=("immich-backups")
ACCEPTED_NFS_PATHS=(
  "/mnt/plex-nfs"
  "/mnt/nextcloud-nfs"
)

AEST_TZ="Australia/Sydney"

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[36m"
RESET="\e[0m"

function check_nfs_mounts() {
  local ns=$1
  pods=$(kubectl get pods -n "$ns" -o json 2>/dev/null)
  echo "$pods" | jq -r '
    .items[] | .spec.volumes[]? | select(.nfs != null) |
    "\(.nfs.server):\(.nfs.path)"' | sort -u
}

echo "🔍 Checking Kubernetes backup configuration (VolSync, CNPG, NFS)..."
echo

namespaces=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
declare -A namespace_states

for ns in $namespaces; do
  skip=false
  for ignored in "${IGNORED_NAMESPACES[@]}"; do
    if [[ "$ns" == "$ignored" ]]; then
      skip=true
      break
    fi
  done
  [[ "$skip" == true ]] && continue

  echo "📦 Namespace: $ns"
  ns_state="OK"

  [[ "$SHOW_PODS" == true ]] && {
    echo "  🔹 Pods:"
    pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null || true)
        [[ -z "$pods" ]] && echo "    - (No pods)" || echo "$pods" | awk '{print "    - " $1 ": " $3}'
  }

  echo "  🔹 Volumes:"
  volumes=$(kubectl get pvc -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.volumeName}{"|"}{.spec.storageClassName}{"\n"}{end}' 2>/dev/null || true)

  volsync_srcs=$(kubectl get replicationsources.volsync.backube -n "$ns" -o json 2>/dev/null || echo '{}')
  volsync_dests=$(kubectl get replicationdestinations.volsync.backube -n "$ns" -o json 2>/dev/null || echo '{}')

  declare -A volsync_pvcs
  while read -r pvc; do [[ -n "$pvc" ]] && volsync_pvcs["$pvc"]=1; done < <(echo "$volsync_srcs" | jq -r '.items? // [] | .[].spec.sourcePVC // empty')
  while read -r pvc; do [[ -n "$pvc" ]] && volsync_pvcs["$pvc"]=1; done < <(echo "$volsync_dests" | jq -r '.items? // [] | .[].spec.destinationPVC // empty')

  if [[ -z "$volumes" ]]; then
    echo "    - No PVCs found"
  else
    for pvc_line in $volumes; do
      IFS='|' read -r pvc vol sc <<<"$pvc_line"

      if [[ "$pvc" == *volsync* || "$pvc" == *-cnpg-* ]]; then
        [[ "$SHOW_VOLSYNC_CNPG_PVCS" == true ]] || continue
      fi

      echo -n "    - PVC: $pvc"

      if [[ ${volsync_pvcs["$pvc"]+exists} ]]; then
        echo -e " ${GREEN}✅ (Handled by VolSync)${RESET}"
        continue
      fi

      excluded=false
      for exclude in "${EXCLUDED_VOLSYNC_PVCS[@]}"; do
        if [[ "$pvc" == *"$exclude"* ]]; then
          excluded=true
          break
        fi
      done

      if [[ "$excluded" == true ]]; then
        echo -e " ${BLUE}(INFO: PVC excluded from VolSync check)${RESET}"
        continue
      fi

      if [[ "$sc" == *"nfs"* ]]; then
        accepted=false
        for path in "${ACCEPTED_NFS_PATHS[@]}"; do
          [[ "$sc" == *"$path"* ]] && accepted=true && break
        done
        if [[ "$accepted" == true ]]; then
          echo -e " ${BLUE}(INFO: Accepted NFS path)${RESET}"
        else
          echo -e " ${YELLOW}WARNING: NFS storage without backup${RESET}"
          ns_state="WARN"
        fi
      else
        echo -e " ${YELLOW}WARNING: No VolSync configured${RESET}"
                ns_state="WARN"
      fi
    done
  fi

  nfs_output=$(check_nfs_mounts "$ns")
  if [[ -n "$nfs_output" ]]; then
    echo "  🔹 NFS Mounts:"
    echo "$nfs_output" | sort -u | while read -r vol; do
      echo -e "    - $vol"
    done
  fi

  # Check for container images containing postgres or cnpg
  pod_images=$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '.items[].spec.containers[].image')
  uses_pg=false
  for img in $pod_images; do
    if [[ "$img" =~ (^|[/:\-])postgres($|[\-:]) ]] || [[ "$img" =~ (^|[/:\-])cnpg($|[\-:]) ]]; then
      uses_pg=true
      break
    fi
  done

  # Check if scheduledbackup or backup exists (safely)
  if kubectl get scheduledbackup -n "$ns" -o json 2>/dev/null | jq -e '.items | length > 0' >/dev/null; then
    uses_pg=true
  fi

  if [[ "$uses_pg" == true ]]; then
    echo "  🔹 CNPG Detection:"
    echo "    - Postgres detected via image or CNPG resource"
    cnpg_backups=$(kubectl get backup -n "$ns" -o json 2>/dev/null || echo '{}')
    cnpg_scheds=$(kubectl get scheduledbackup -n "$ns" -o json 2>/dev/null || echo '{}')

    now_epoch=$(date +%s)
    latest_backup_epoch=0
    backup_found=false

    if [[ $(echo "$cnpg_backups" | jq '.items? // [] | length') -gt 0 ]]; then
      echo "$cnpg_backups" | jq -r '.items[] | [.metadata.name, .status.phase, .status.completionTimestamp] | @tsv' | while IFS=$'\t' read -r name phase ts; do
        if [[ "$ts" != "null" && -n "$ts" ]]; then
          aest_time=$(TZ=$AEST_TZ date -d "$ts" "+%Y-%m-%d %H:%M:%S %Z")
          echo "    - Backup: $name | Status: $phase | Last: $ts UTC / $aest_time AEST"
          ts_epoch=$(date -d "$ts" +%s)
          latest_backup_epoch=$(( ts_epoch > latest_backup_epoch ? ts_epoch : latest_backup_epoch ))
          backup_found=true
        else
          echo "    - Backup: $name | Status: $phase"
        fi
      done
    else
      echo "    - No one-time backups found"
    fi

    if [[ $(echo "$cnpg_scheds" | jq '.items? // [] | length') -gt 0 ]]; then
          echo "$cnpg_scheds" | jq -r '.items[] | [.metadata.name, .status.lastScheduleTime, .status.lastCheckTime, .status.nextScheduleTime] | @tsv' | while IFS=$'\t' read -r name last check next; do
      if [[ "$last" != "null" && -n "$last" ]]; then
        last_aest=$(TZ=$AEST_TZ date -d "$last" "+%Y-%m-%d %H:%M:%S %Z")
        echo "    - ScheduledBackup: $name"
        echo "        Last Schedule Time: $last UTC / $last_aest AEST"
        [[ "$check" != "null" && -n "$check" ]] && check_aest=$(TZ=$AEST_TZ date -d "$check" "+%Y-%m-%d %H:%M:%S %Z") && echo "        Last Check Time: $check UTC / $check_aest AEST"
        [[ "$next" != "null" && -n "$next" ]] && next_aest=$(TZ=$AEST_TZ date -d "$next" "+%Y-%m-%d %H:%M:%S %Z") && echo "        Next Schedule Time: $next UTC / $next_aest AEST"

        last_epoch=$(date -d "$last" +%s)
        latest_backup_epoch=$(( last_epoch > latest_backup_epoch ? last_epoch : latest_backup_epoch ))
        backup_found=true
        else
          echo "    - ScheduledBackup: $name (no recent schedule run)"
        fi
      done
    fi

    if [[ "$backup_found" == true && "$latest_backup_epoch" -gt 0 ]]; then
      age_hr=$(( (now_epoch - latest_backup_epoch) / 3600 ))
      if (( age_hr > RETENTION_THRESHOLD_HOURS )); then
        echo -e "    ${YELLOW}  WARNING: Latest CNPG backup is older than ${RETENTION_THRESHOLD_HOURS}h (${age_hr}h ago)${RESET}"
        ns_state="WARN"
      fi
    fi
  fi

  namespace_states["$ns"]="$ns_state"
done

echo
echo "📋 Backup Check Summary:"
for ns in "${!namespace_states[@]}"; do
  case "${namespace_states[$ns]}" in
    "OK") echo -e "  ${GREEN}$ns: OK${RESET}" ;;
    "WARN") echo -e "  ${YELLOW}$ns: WARNING${RESET}" ;;
    "ERROR") echo -e "  ${RED}$ns: ERROR${RESET}" ;;
  esac
done

# Discord-Friendly Summary
echo -e "\n⚡ Discord-Friendly Summary:"
printf "%-8s | %-15s | %-30s | %-24s | %-6s\n" "Type" "Namespace" "Resource" "Last Run" "State"
printf -- "%.0s-" {1..90}; echo

for ns in "${!namespace_states[@]}"; do
  # VolSync backups
  volsync_srcs=$(kubectl get replicationsources.volsync.backube -n "$ns" -o json 2>/dev/null || echo '{}')
  echo "$volsync_srcs" | jq -r '.items[] | select(.status.lastSyncTime != null) | [.spec.sourcePVC, .status.lastSyncTime] | @tsv' | while IFS=$'\t' read -r pvc time; do
    aest_time=$(TZ=$AEST_TZ date -d "$time" "+%Y-%m-%d %H:%M:%S %Z")
    age_hr=$(( ( $(date +%s) - $(date -d "$time" +%s) ) / 3600 ))
    state="OK"
    (( age_hr > RETENTION_THRESHOLD_HOURS )) && state="WARN"
    printf "%-8s | %-15s | %-30s | %-24s | %-6s\n" "VolSync" "$ns" "$pvc" "$aest_time" "$state"
  done

  # CNPG scheduled backups
  if kubectl get scheduledbackup -n "$ns" -o json 2>/dev/null | jq -e '.items | length > 0' >/dev/null; then
    cnpg_scheds=$(kubectl get scheduledbackup -n "$ns" -o json 2>/dev/null || echo '{}')
    echo "$cnpg_scheds" | jq -r '.items[] | [.metadata.name, .status.lastScheduleTime] | @tsv' | while IFS=$'\t' read -r name last; do
      if [[ "$last" != "null" && -n "$last" ]]; then
        aest_time=$(TZ=$AEST_TZ date -d "$last" "+%Y-%m-%d %H:%M:%S %Z")
        age_hr=$(( ( $(date +%s) - $(date -d "$last" +%s) ) / 3600 ))
        state="OK"
        (( age_hr > RETENTION_THRESHOLD_HOURS )) && state="WARN"
        printf "%-8s | %-15s | %-30s | %-24s | %-6s\n" "CNPG" "$ns" "$name" "$aest_time" "$state"
      else
        printf "%-8s | %-15s | %-30s | %-24s | %-6s\n" "CNPG" "$ns" "$name" "N/A" "ERROR"
      fi
    done
  fi

  # NFS mounts
  nfs_vols=$(check_nfs_mounts "$ns")
  for vol in $nfs_vols; do
    skip_nfs=false
    for path in "${ACCEPTED_NFS_PATHS[@]}"; do
      [[ "$vol" == *"$path"* ]] && skip_nfs=true && break
    done
    if [[ "$skip_nfs" == false ]]; then
      printf "%-8s | %-15s | %-30s | %-24s | %-6s\n" "NFS" "$ns" "$vol" "N/A" "ERROR"
    fi
  done
done

