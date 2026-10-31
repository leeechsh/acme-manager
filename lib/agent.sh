#!/usr/bin/env bash

# Certificate pull agent. It shares the manager configuration and WebDAV
# transport with the upload side, so it can run without acme.sh.

AGENT_TMP_META=''
AGENT_ENTRIES=''
AGENT_STAGING=''

agent_log() {
  mkdir -p "$(dirname "$AGENT_LOG")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$AGENT_LOG" 2>/dev/null || true
}

agent_config_validate() {
  [[ "$WEBDAV_ENABLED" == true ]] || { error 'Enable WebDAV synchronization before using the certificate agent'; return 1; }
  webdav_validate || return 1
  valid_abs_path "$AGENT_TARGET_DIR" || { error 'AGENT_TARGET_DIR must be an absolute path'; return 1; }
  valid_abs_path "$AGENT_LOG" || { error 'AGENT_LOG must be an absolute path'; return 1; }
}

agent_url_join() {
  printf '%s/%s\n' "${1%/}" "${2#/}"
}

agent_cleanup() {
  rm -f "$AGENT_TMP_META" "$AGENT_ENTRIES"
  rm -rf "$AGENT_STAGING"
}

agent_meta_entries() {
  awk -F'"' '
    /"domain":/ { domain=$4 }
    /"directory":/ { directory=$4 }
    /"fingerprint_sha256":/ {
      fingerprint=$4
      if (domain != "" && directory != "") {
        print domain "\t" directory "\t" fingerprint
        domain=""; directory=""; fingerprint=""
      }
    }
  ' "$1"
}

agent_meta_has_entry() {
  local file="$1" directory="$2" fingerprint="$3"
  agent_meta_entries "$file" | awk -F '\t' -v wanted_dir="$directory" -v wanted_fp="$fingerprint" \
    '$2 == wanted_dir && $3 == wanted_fp { found=1 } END { exit(found ? 0 : 1) }'
}

agent_safe_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && "$1" != *..* ]]
}

agent_sync() {
  local remote_meta local_meta domain directory fingerprint file remote_dir changed=0
  agent_config_validate || return 1
  mkdir -p "$AGENT_TARGET_DIR"
  remote_meta=$(agent_url_join "$WEBDAV_URL" meta.json)
  AGENT_TMP_META=$(mktemp "${TMPDIR:-/tmp}/acme-manager-agent-meta.XXXXXX") || return 1
  trap agent_cleanup EXIT
  webdav_request "$remote_meta" -o "$AGENT_TMP_META" || {
    error 'Unable to download WebDAV metadata'
    return 1
  }
  local_meta="$AGENT_TARGET_DIR/meta.json"
  if [[ -f "$local_meta" ]] && cmp -s "$AGENT_TMP_META" "$local_meta"; then
    printf 'Certificate metadata unchanged\n'
    agent_log 'metadata unchanged'
    return 0
  fi
  AGENT_ENTRIES=$(mktemp "${TMPDIR:-/tmp}/acme-manager-agent-entries.XXXXXX") || return 1
  agent_meta_entries "$AGENT_TMP_META" >"$AGENT_ENTRIES"
  AGENT_STAGING=$(mktemp -d "$AGENT_TARGET_DIR/.acme-manager-agent-sync.XXXXXX") || return 1
  while IFS=$'\t' read -r domain directory fingerprint; do
    [[ -n "$domain" && -n "$directory" ]] || continue
    agent_safe_name "$directory" || { error "Unsafe certificate directory in metadata: $directory"; return 1; }
    if [[ -f "$local_meta" && -d "$AGENT_TARGET_DIR/$directory" && -n "$fingerprint" ]] &&
      agent_meta_has_entry "$local_meta" "$directory" "$fingerprint"; then
      continue
    fi
    remote_dir=$(agent_url_join "$WEBDAV_URL" "$directory")
    changed=1
    mkdir -p "$AGENT_STAGING/$directory"
    for file in cert.pem privkey.pem fullchain.pem ca.pem "$directory.key" "$directory.pem"; do
      if ! webdav_request "$(agent_url_join "$remote_dir" "$file")" -o "$AGENT_STAGING/$directory/$file"; then
        if [[ "$file" == cert.pem || "$file" == privkey.pem || "$file" == fullchain.pem ]]; then
          error "Required certificate file download failed: $directory/$file"
          return 1
        fi
        rm -f "$AGENT_STAGING/$directory/$file"
      fi
    done
    chmod 600 "$AGENT_STAGING/$directory/privkey.pem"
    chmod 644 "$AGENT_STAGING/$directory"/*.pem 2>/dev/null || true
  done <"$AGENT_ENTRIES"
  while IFS=$'\t' read -r domain directory fingerprint; do
    [[ -n "$directory" && -d "$AGENT_STAGING/$directory" ]] || continue
    rm -rf "$AGENT_TARGET_DIR/$directory"
    mv "$AGENT_STAGING/$directory" "$AGENT_TARGET_DIR/$directory"
  done < <(agent_meta_entries "$AGENT_TMP_META")
  cp -f "$AGENT_TMP_META" "$local_meta"
  chmod 644 "$local_meta"
  agent_cleanup
  trap - EXIT
  if (( changed )) && [[ -n "$AGENT_RELOAD_CMD" ]]; then
    bash -c "$AGENT_RELOAD_CMD" || { error 'Agent reload command failed'; return 1; }
  fi
  success "Certificates synchronized into $AGENT_TARGET_DIR"
  agent_log "certificates synchronized into $AGENT_TARGET_DIR"
}

agent_status() {
  printf 'Agent enabled: %s\n' "$WEBDAV_ENABLED"
  printf 'Config file: %s\n' "$CONFIG_FILE"
  printf 'WebDAV URL: %s\n' "${WEBDAV_URL:-not configured}"
  printf 'WebDAV username: %s\n' "${WEBDAV_USERNAME:-not configured}"
  printf 'WebDAV password: %s\n' "$([[ -n "$WEBDAV_PASSWORD" ]] && printf configured || printf not-configured)"
  printf 'Target directory: %s\n' "$AGENT_TARGET_DIR"
  printf 'Reload command: %s\n' "${AGENT_RELOAD_CMD:-not configured}"
  printf 'Cron schedule: %s\n' "$AGENT_CRON_SCHEDULE"
  printf 'Agent log: %s\n' "$AGENT_LOG"
  [[ "$WEBDAV_ENABLED" == true ]] && agent_config_validate || true
}

agent_configure() {
  AGENT_TARGET_DIR=$(prompt_value 'Agent target directory' "$AGENT_TARGET_DIR") || return 1
  local reload_cmd
  reload_cmd=$(prompt_value 'Reload command after certificate changes (type - to clear)' "${AGENT_RELOAD_CMD:-}") || return 1
  [[ "$reload_cmd" == '-' ]] && reload_cmd=''
  AGENT_RELOAD_CMD="$reload_cmd"
  AGENT_LOG=$(prompt_value 'Agent log file' "$AGENT_LOG") || return 1
  AGENT_CRON_SCHEDULE=$(prompt_value 'Agent Cron schedule' "$AGENT_CRON_SCHEDULE") || return 1
  config_write
}

agent_cron_install() {
  agent_config_validate || return 1
  command -v crontab >/dev/null 2>&1 || { error 'crontab is required'; return 1; }
  local marker='# acme-manager agent managed job' current job
  current=$(crontab -l 2>/dev/null || true)
  current=$(printf '%s\n' "$current" | sed '/# acme-agent managed job/d; /# acme-manager agent managed job/d')
  job="$AGENT_CRON_SCHEDULE $SCRIPT_DIR/acme-manager.sh agent sync >>$AGENT_LOG 2>&1 $marker"
  {
    [[ -n "$current" ]] && printf '%s\n' "$current"
    printf '%s\n' "$job"
  } | crontab -
  success "Agent Cron installed: $job"
}

agent_cron_remove() {
  command -v crontab >/dev/null 2>&1 || { error 'crontab is required'; return 1; }
  local current
  current=$(crontab -l 2>/dev/null || true)
  printf '%s\n' "$current" | sed '/# acme-agent managed job/d; /# acme-manager agent managed job/d' | crontab -
  success 'Agent Cron removed'
}

agent_menu() {
  while true; do
    menu_header 'Certificate Agent' 'Pull changed certificates from the shared WebDAV store'
    menu_home_status
    ui_section 'Agent'
    ui_menu_item 1 'View agent status' 'Shared WebDAV settings and local target'
    ui_menu_item 2 'Sync certificates now' 'Download metadata and changed certificate directories'
    ui_menu_item 3 'Configure agent' 'Target directory, reload command and Cron'
    ui_menu_item 4 'Install agent Cron' 'Run the pull agent on a schedule'
    ui_menu_item 5 'Remove agent Cron' 'Keep certificates and remove only the job'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose an action [0-5]:' || return 0
    case "$MENU_CHOICE" in
      1) agent_status; pause_screen;;
      2) agent_sync || true; pause_screen;;
      3) agent_configure || true; pause_screen;;
      4) agent_cron_install || true; pause_screen;;
      5) agent_cron_remove || true; pause_screen;;
      0) return 0;;
      *) warn 'Invalid choice';;
    esac
  done
}
