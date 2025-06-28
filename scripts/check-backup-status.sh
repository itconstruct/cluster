#!/usr/bin/env bash
set -euo pipefail

# Config
SHOW_PODS=false
SHOW_VOLSYNC_CNPG_PVCS=false
RETENTION_THRESHOLD_HOURS=48
HANG_THRESHOLD_MINUTES=30
AEST_TZ="Australia/Sydney"

# Namespaces to ignore
IGNORED_NAMESPACES=( "blocky" "cert-manager" "cilium-secrets" "cloudflared" "cloudnative-pg"
  "clusterissuer" "default" "external-service" "flux-system" "kube-node-lease"
  "kube-prometheus-stack" "kube-public" "kube-system" "kubernetes-dashboard"
  "kubernetes-reflector" "kyverno" "longhorn-system" "metallb" "metallb-config"
  "nginx-external" "nginx-internal" "openebs" "snapshot-controller" "spegel"
  "system" "system-upgrade" "tailscale" "volsync" )

# PVCs excluded from VolSync checks
EXCLUDED_VOLSYNC_PVCS=("immich-backups")

# Known NFS paths we accept
ACCEPTED_NFS_PATHS=( "/mnt/plex-nfs" "/mnt/nextcloud-nfs" )

# Terminal colors
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

echo -e "\n🔍 Checking Kubernetes backup configuration (VolSync, CNPG, NFS)...\n"
namespaces=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')

for ns in $namespaces; do
  [[ " ${IGNORED_NAMESPACES[*]} " =~ " ${ns} " ]] && continue

  echo "📆 Namespace: $ns"
  update_namespace_state "$ns" "OK"

  [[ "$SHOW_PODS" == true ]] && {
    echo "  🔹 Pods:"
    kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '{print "    - " $1 ": " $3}' || echo "    - (No pods)"
  }

  echo "  🔹 Volumes:"
  volumes=$(kubectl get pvc -n "$ns" -o json 2>/dev/null || echo '{}')
  echo "$volumes" | jq -r '.items[] | [.metadata.name, .spec.storageClassName] | @tsv' | while IFS=$'\t' read -r pvc sc; do
    if [[ "$SHOW_VOLSYNC_CNPG_PVCS" == false && ( "$pvc" == *volsync* || "$pvc" == *-cnpg-* ) ]]; then
      continue
    fi
    for skip in "${EXCLUDED_VOLSYNC_PVCS[@]}"; do
      [[ "$pvc" == *"$skip"* ]] && echo -e "    - PVC: $pvc ${BLUE}(INFO: Excluded from VolSync check)${RESET}" && continue 2
    done
    echo "    - PVC: $pvc"
  done

  # NFS Mount Check
  echo "  🔹 NFS Mounts:"
  nfs_paths=$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '.items[].spec.volumes[]? | select(.nfs != null) | "\(.nfs.path)"' | sort -u)
  if [[ -n "$nfs_paths" ]]; then
    for path in $nfs_paths; do
      if printf '%s\n' "${ACCEPTED_NFS_PATHS[@]}" | grep -qx "$path"; then
        echo -e "    - $path ${YELLOW}(WARNING: Verify external NFS backups)${RESET}"
        update_namespace_state "$ns" "WARN"
        DISCORD_SUMMARY+=("NFS | $ns | $path | External | WARNING")
      else
        echo -e "    - $path ${RED}❌ ERROR: NFS volume unaccounted${RESET}"
        update_namespace_state "$ns" "ERROR"
        DISCORD_SUMMARY+=("NFS | $ns | $path | External | ERROR")
      fi
    done
  else
    echo "    - No NFS volumes"
  fi

  # VolSync check
  volsync_json=$(kubectl get replicationsources.volsync.backube -n "$ns" -o json 2>/dev/null || echo '{}')
  [[ $(echo "$volsync_json" | jq '.items | length') -gt 0 ]] && {
    echo "  🔹 VolSync Last Backup:"
    echo "$volsync_json" | jq -r '.items[] | [.metadata.name, .status?.lastSyncTime] | @tsv' | \
      while IFS=$'\t' read -r name time; do
        [[ -z "$time" || "$time" == "null" ]] && continue
        aest=$(TZ=$AEST_TZ date -d "$time" "+%Y-%m-%d %H:%M:%S %Z")
        echo "    - $name: $time UTC / $aest AEST"
      done
    echo "$volsync_json" | jq -r '.items[].metadata.name' | while read -r name; do
      check_volsync_health "$ns" "$name"
    done
  }

  # CNPG backup check
  uses_pg=false
  images=$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq -r '.items[].spec.containers[].image')
  for img in $images; do
    [[ "$img" =~ (^|[/:\-])(postgres|cnpg)($|[\-:]) ]] && uses_pg=true && break
  done
  kubectl get scheduledbackup -n "$ns" -o json 2>/dev/null | jq -e '.items | length > 0' &>/dev/null && uses_pg=true

  if [[ "$uses_pg" == true ]]; then
    echo "  🔹 CNPG Backup Info:"
    scheds=$(kubectl get scheduledbackup -n "$ns" -o json 2>/dev/null || echo '{}')
    echo "$scheds" | jq -r '.items[] | [.metadata.name, .status?.lastScheduleTime] | @tsv' | \
      while IFS=$'\t' read -r name last; do
        [[ -z "$last" || "$last" == "null" ]] && continue
        last_epoch=$(date -d "$last" +%s)
        now_epoch=$(date +%s)
        diff_hr=$(( (now_epoch - last_epoch) / 3600 ))
        aest_time=$(TZ=$AEST_TZ date -d "$last" "+%Y-%m-%d %H:%M:%S %Z")
        echo "    - ScheduledBackup: $name | Last: $last UTC / $aest_time AEST"
        if (( diff_hr > RETENTION_THRESHOLD_HOURS )); then
          echo -e "    ${YELLOW}  ⚠️ WARNING: CNPG backup older than ${RETENTION_THRESHOLD_HOURS}h${RESET}"
          update_namespace_state "$ns" "WARN"
          DISCORD_SUMMARY+=("CNPG | $ns | $name | ${diff_hr}h ago | WARNING")
        else
          DISCORD_SUMMARY+=("CNPG | $ns | $name | $aest_time | OK")
        fi
      done
  fi

  echo ""
done

# Discord-style summary (always print full summary)
echo -e "\n📊 **Discord-Friendly Backup Summary:**"
echo -e "\n\`\`\`markdown"
printf "%-10s | %-15s | %-35s | %-22s | %-8s\n" "Type" "Namespace" "Resource" "Last Run" "State"
printf -- "%-10s-+-%-15s-+-%-35s-+-%-22s-+-%-8s\n" "----------" "---------------" "-----------------------------------" "----------------------" "--------"
for line in "${DISCORD_SUMMARY[@]}"; do
  IFS='|' read -r type ns res info state <<< "$line"
  printf "%-10s | %-15s | %-35s | %-22s | %-8s\n" "$type" "$ns" "$res" "$info" "$state"
done
echo "\`\`\`"

# Show simple pass/fail footer
any_warn_or_error=false
for entry in "${DISCORD_SUMMARY[@]}"; do
  [[ "$entry" == *"ERROR"* || "$entry" == *"WARN"* || "$entry" == *"WARNING"* ]] && any_warn_or_error=true && break
done

if [[ "$any_warn_or_error" == true ]]; then
  echo -e "\n🚨 One or more backup issues detected. Please review the summary above."
else
  echo -e "\n✅ All VolSync and CNPG backups are healthy and up-to-date."
fi
