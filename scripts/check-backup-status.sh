#!/usr/bin/env bash
set -euo pipefail

# Config
SHOW_PODS=false
SHOW_VOLSYNC_CNPG_PVCS=false
RETENTION_THRESHOLD_HOURS=48
HANG_THRESHOLD_MINUTES=30
AEST_TZ="Australia/Sydney"

# Namespaces
IGNORED_NAMESPACES=( "blocky" "cert-manager" "cilium-secrets" "cloudflared" "cloudnative-pg"
  "clusterissuer" "default" "external-service" "flux-system" "kube-node-lease"
  "kube-prometheus-stack" "kube-public" "kube-system" "kubernetes-dashboard"
  "kubernetes-reflector" "kyverno" "longhorn-system" "metallb" "metallb-config"
  "nginx-external" "nginx-internal" "openebs" "snapshot-controller" "spegel"
  "system" "system-upgrade" "tailscale" "volsync" )

EXCLUDED_VOLSYNC_PVCS=("immich-backups")
ACCEPTED_NFS_PATHS=( "/mnt/plex-nfs" "/mnt/nextcloud-nfs" )

# Colors
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; BLUE="\e[36m"; RESET="\e[0m"
declare -A namespace_states
DISCORD_SUMMARY=()

update_namespace_state() {
  local ns=$1 new_state=$2
  local current=${namespace_states["$ns"]:-"OK"}
  case "$current" in
    ERROR) return ;;
    WARN) [[ "$new_state" == "ERROR" ]] && namespace_states["$ns"]="ERROR" ;;
    OK) namespace_states["$ns"]="$new_state" ;;
  esac
}

check_volsync_health() {
  local ns=$1 src=$2
  local json=$(kubectl get replicationsource "$src" -n "$ns" -o json 2>/dev/null || echo '{}')
  local start=$(echo "$json" | jq -r '.status.lastSyncStartTime // empty')
  local last=$(echo "$json" | jq -r '.status.lastSyncTime // empty')
  local cond=$(echo "$json" | jq -r '.status.conditions[]? | select(.type=="Synchronizing") | .status')

  if [[ "$cond" == "True" && -n "$start" ]]; then
    local dur=$(( ($(date +%s) - $(date -d "$start" +%s)) / 60 ))
    if (( dur > HANG_THRESHOLD_MINUTES )); then
      echo -e "${RED}  ❌ HANG: $ns/$src syncing for ${dur}m${RESET}"
      update_namespace_state "$ns" "ERROR"
      DISCORD_SUMMARY+=("VolSync | $ns | $src | HANG: ${dur}m | ERROR")
      return
    fi
  fi

  if [[ -n "$last" ]]; then
    local hours=$(( ($(date +%s) - $(date -d "$last" +%s)) / 3600 ))
    local aest=$(TZ=$AEST_TZ date -d "$last" "+%Y-%m-%d %H:%M:%S %Z")
    if (( hours > RETENTION_THRESHOLD_HOURS )); then
      echo -e "${YELLOW}  ⚠️ STALE: $ns/$src last synced $hours hours ago${RESET}"
      update_namespace_state "$ns" "WARN"
      DISCORD_SUMMARY+=("VolSync | $ns | $src | STALE: ${hours}h | WARNING")
    else
      DISCORD_SUMMARY+=("VolSync | $ns | $src | ${hours}h ago | OK")
    fi
  fi
}

echo "🔍 Checking Kubernetes backup configuration (VolSync, CNPG, NFS)..."
echo

namespaces=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')

for ns in $namespaces; do
  skip=false
  for ignored in "${IGNORED_NAMESPACES[@]}"; do
    [[ "$ns" == "$ignored" ]] && skip=true && break
  done
  [[ "$skip" == true ]] && continue

  echo "📆 Namespace: $ns"
  update_namespace_state "$ns" "OK"

  nfs_mounts=$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '
  .items[]?.spec.volumes[]? | select(.nfs != null) | "\(.nfs.server):\(.nfs.path)"' | sort -u)

  if [[ -n "$nfs_mounts" ]]; then
    echo "  🔹 NFS Mounts:"
    echo "$nfs_mounts" | sed 's/^/    - /'
  fi


  echo "  🔹 Volumes:"
  volumes=$(kubectl get pvc -n "$ns" -o json 2>/dev/null || echo '{}')
  echo "$volumes" | jq -r '.items[] | [.metadata.name, .spec.storageClassName] | @tsv' | while IFS=$'\t' read -r pvc sc; do
    if [[ "$SHOW_VOLSYNC_CNPG_PVCS" == false && ( "$pvc" == *volsync* || "$pvc" == *-cnpg-* ) ]]; then
      continue
    fi

    excluded=false
    for skip in "${EXCLUDED_VOLSYNC_PVCS[@]}"; do
      [[ "$pvc" == *"$skip"* ]] && excluded=true && break
    done
    if [[ "$excluded" == true ]]; then
      echo -e "    - PVC: $pvc ${BLUE}(INFO: PVC excluded from VolSync check)${RESET}"
      continue
    fi

    if [[ "$sc" == *"nfs"* ]]; then
      accepted=false
      for path in "${ACCEPTED_NFS_PATHS[@]}"; do
        [[ "$sc" == *"$path"* ]] && accepted=true && break
      done
      if [[ "$accepted" == true ]]; then
        echo -e "    - PVC: $pvc ${BLUE}(INFO: Accepted NFS path)${RESET}"
      else
        echo -e "    - PVC: $pvc ${RED}❌ ERROR: NFS storage without backup${RESET}"
        update_namespace_state "$ns" "ERROR"
        DISCORD_SUMMARY+=("NFS | $ns | $pvc | N/A | ERROR")
      fi
    else
      echo "    - PVC: $pvc"
    fi
  done

  volsync_json=$(kubectl get replicationsources.volsync.backube -n "$ns" -o json 2>/dev/null || echo '{}')
  if [[ $(echo "$volsync_json" | jq '.items | length') -gt 0 ]]; then
    echo "  🔹 VolSync Last Backup:"
    echo "$volsync_json" | jq -r '.items[] | [.metadata.name, .status?.lastSyncTime] | @tsv' | while IFS=$'\t' read -r name time; do
      [[ -z "$time" || "$time" == "null" ]] && continue
      local_aest=$(TZ=$AEST_TZ date -d "$time" "+%Y-%m-%d %H:%M:%S %Z")
      echo "    - $name: $time UTC / $local_aest AEST"
    done
    while read -r src; do
      check_volsync_health "$ns" "$src"
    done < <(echo "$volsync_json" | jq -r '.items[].metadata.name')

  fi

  uses_pg=false
  images=$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '.items[].spec.containers[].image')
  for img in $images; do
    [[ "$img" =~ (^|[/:\-])(postgres|cnpg)($|[\-:]) ]] && uses_pg=true && break
  done
  kubectl get scheduledbackup -n "$ns" -o json 2>/dev/null | jq -e '.items | length > 0' >/dev/null && uses_pg=true

  if [[ "$uses_pg" == true ]]; then
    echo "  🔹 CNPG Backup Info:"
    scheds=$(kubectl get scheduledbackup -n "$ns" -o json 2>/dev/null || echo '{}')
    while IFS=$'\t' read -r name last; do
      if [[ "$last" != "null" && -n "$last" ]]; then
        last_epoch=$(date -d "$last" +%s)
        now_epoch=$(date +%s)
        diff_hr=$(( (now_epoch - last_epoch) / 3600 ))
        last_aest=$(TZ=$AEST_TZ date -d "$last" "+%Y-%m-%d %H:%M:%S %Z")
        echo "    - ScheduledBackup: $name | Last Schedule Time: $last UTC / $last_aest AEST"

      if (( diff_hr > RETENTION_THRESHOLD_HOURS )); then
        echo -e "    ${YELLOW}  WARNING: CNPG backup is older than $RETENTION_THRESHOLD_HOURS hours${RESET}"
        namespace_states["$ns"]="WARN"
        DISCORD_SUMMARY+=("CNPG | $ns | $name | ${diff_hr}h ago | WARNING")
      else
        DISCORD_SUMMARY+=("CNPG | $ns | $name | $last_aest | OK")
      fi
    fi
done < <(echo "$scheds" | jq -r '.items[] | [.metadata.name, .status.lastScheduleTime] | @tsv')

  fi

done  # ← This is the end of the namespace loop

# Categorize backup results
any_warn_or_error=false

echo "🔍 DISCORD_SUMMARY contains ${#DISCORD_SUMMARY[@]} entries"

for entry in "${DISCORD_SUMMARY[@]}"; do
  # Use IFS to safely split and trim
  IFS='|' read -r _ _ _ _ raw_state <<< "$entry"
  state=$(echo "$raw_state" | xargs)  # Trim leading/trailing whitespace

  echo "🧪 Evaluating backup status state: '$state'"  # Debug line

  if [[ "$state" == "WARN" || "$state" == "WARNING" || "$state" == "ERROR" ]]; then
    any_warn_or_error=true
    break
  fi
done


if [[ "$any_warn_or_error" == true ]]; then
  echo -e "\n🚨 **Discord-Friendly Backup Summary:**"
  echo -e "\n\`\`\`markdown"
  printf "%-10s | %-15s | %-35s | %-22s | %-8s\n" "Type" "Namespace" "Resource" "Last Run" "State"
  printf -- "%-10s-+-%-15s-+-%-35s-+-%-22s-+-%-8s\n" "----------" "---------------" "-----------------------------------" "----------------------" "--------"
  for line in "${DISCORD_SUMMARY[@]}"; do
    IFS='|' read -r type ns res info state <<< "$line"
    printf "%-10s | %-15s | %-35s | %-22s | %-8s\n" "$type" "$ns" "$res" "$info" "$state"
  done
  echo "\`\`\`"
else
  echo -e "\n✅ All backups appear healthy. No warnings or errors to report."
fi

