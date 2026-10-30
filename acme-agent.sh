#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SOURCE_FILE="${BASH_SOURCE[0]}"
while [[ -h "$SOURCE_FILE" ]]; do
  SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$SOURCE_FILE")" && pwd)
  SOURCE_FILE=$(readlink "$SOURCE_FILE")
  [[ "$SOURCE_FILE" == /* ]] || SOURCE_FILE="$SOURCE_DIR/$SOURCE_FILE"
done
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$SOURCE_FILE")" && pwd)
AGENT_CONFIG="${ACME_AGENT_CONFIG:-$SCRIPT_DIR/etc/agent.conf}"

WEBDAV_URL=''
WEBDAV_USERNAME=''
WEBDAV_PASSWORD=''
TARGET_DIR='/var/cert'
RELOAD_CMD=''
AGENT_LOG='/var/log/acme-agent.log'
CRON_SCHEDULE='*/5 * * * *'
AGENT_TMP_META=''
AGENT_ENTRIES=''
AGENT_STAGING=''

agent_log() {
  mkdir -p "$(dirname "$AGENT_LOG")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$AGENT_LOG" 2>/dev/null || true
}

agent_config_load() {
  [[ -f "$AGENT_CONFIG" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    case "$key" in
      WEBDAV_URL|WEBDAV_USERNAME|WEBDAV_PASSWORD|TARGET_DIR|RELOAD_CMD|AGENT_LOG|CRON_SCHEDULE)
        printf -v "$key" '%s' "$value" ;;
    esac
  done <"$AGENT_CONFIG"
}

agent_config_validate() {
  [[ "$WEBDAV_URL" =~ ^https?://[^[:space:]]+$ ]] || { printf 'Invalid WEBDAV_URL\n' >&2; return 1; }
  [[ -n "$WEBDAV_USERNAME" && -n "$WEBDAV_PASSWORD" ]] || { printf 'WEBDAV_USERNAME and WEBDAV_PASSWORD are required\n' >&2; return 1; }
  [[ "$TARGET_DIR" == /* ]] || { printf 'TARGET_DIR must be absolute\n' >&2; return 1; }
  command -v curl >/dev/null 2>&1 || { printf 'curl is required\n' >&2; return 1; }
}

agent_url_join() {
  printf '%s/%s\n' "${1%/}" "${2#/}"
}

agent_netrc() {
  local host="${WEBDAV_URL#*://}" file
  host="${host%%/*}"
  host="${host##*@}"
  host="${host%%:*}"
  file=$(mktemp "${TMPDIR:-/tmp}/acme-agent-netrc.XXXXXX")
  chmod 600 "$file"
  printf 'machine %s login %s password %s\n' "$host" "$WEBDAV_USERNAME" "$WEBDAV_PASSWORD" >"$file"
  printf '%s\n' "$file"
}

agent_curl() {
  local url="$1"; shift
  local netrc rc
  netrc=$(agent_netrc)
  curl --fail --silent --show-error --location --netrc-file "$netrc" "$@" "$url"
  rc=$?
  rm -f "$netrc"
  return "$rc"
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
  mkdir -p "$TARGET_DIR"
  remote_meta=$(agent_url_join "$WEBDAV_URL" meta.json)
  AGENT_TMP_META=$(mktemp "${TMPDIR:-/tmp}/acme-agent-meta.XXXXXX")
  trap agent_cleanup EXIT
  agent_curl "$remote_meta" -o "$AGENT_TMP_META" || { printf 'Unable to download WebDAV metadata\n' >&2; return 1; }
  local_meta="$TARGET_DIR/meta.json"
  if [[ -f "$local_meta" ]] && cmp -s "$AGENT_TMP_META" "$local_meta"; then
    printf 'Certificate metadata unchanged\n'
    agent_log 'metadata unchanged'
    return 0
  fi
  AGENT_ENTRIES=$(mktemp "${TMPDIR:-/tmp}/acme-agent-entries.XXXXXX")
  agent_meta_entries "$AGENT_TMP_META" >"$AGENT_ENTRIES"
  AGENT_STAGING=$(mktemp -d "$TARGET_DIR/.acme-agent-sync.XXXXXX")
  while IFS=$'\t' read -r domain directory fingerprint; do
    [[ -n "$domain" && -n "$directory" ]] || continue
    agent_safe_name "$directory" || { printf 'Unsafe certificate directory in metadata: %s\n' "$directory" >&2; return 1; }
    if [[ -f "$local_meta" && -d "$TARGET_DIR/$directory" && -n "$fingerprint" ]] &&
      agent_meta_has_entry "$local_meta" "$directory" "$fingerprint"; then
      continue
    fi
    remote_dir=$(agent_url_join "$WEBDAV_URL" "$directory")
    changed=1
    mkdir -p "$AGENT_STAGING/$directory"
    for file in cert.pem privkey.pem fullchain.pem ca.pem "$directory.key" "$directory.pem"; do
      if ! agent_curl "$(agent_url_join "$remote_dir" "$file")" -o "$AGENT_STAGING/$directory/$file"; then
        if [[ "$file" == cert.pem || "$file" == privkey.pem || "$file" == fullchain.pem ]]; then
          printf 'Required certificate file download failed: %s/%s\n' "$directory" "$file" >&2
          return 1
        fi
        rm -f "$AGENT_STAGING/$directory/$file"
      fi
    done
    chmod 600 "$AGENT_STAGING/$directory/privkey.pem"
    chmod 644 "$AGENT_STAGING/$directory"/*.pem 2>/dev/null || true
  done <"$AGENT_ENTRIES"
  while IFS=$'\t' read -r domain directory fingerprint; do
    [[ -n "$directory" ]] || continue
    [[ -d "$AGENT_STAGING/$directory" ]] || continue
    rm -rf "$TARGET_DIR/$directory"
    mv "$AGENT_STAGING/$directory" "$TARGET_DIR/$directory"
  done < <(agent_meta_entries "$AGENT_TMP_META")
  cp -f "$AGENT_TMP_META" "$local_meta"
  chmod 644 "$local_meta"
  agent_cleanup
  trap - EXIT
  if (( changed )) && [[ -n "$RELOAD_CMD" ]]; then
    bash -c "$RELOAD_CMD" || { printf 'Reload command failed\n' >&2; return 1; }
  fi
  printf 'Certificates synchronized into %s\n' "$TARGET_DIR"
  agent_log "certificates synchronized into $TARGET_DIR"
}

agent_config_show() {
  printf 'Config file: %s\n' "$AGENT_CONFIG"
  printf 'WebDAV URL: %s\n' "${WEBDAV_URL:-not configured}"
  printf 'WebDAV username: %s\n' "${WEBDAV_USERNAME:-not configured}"
  printf 'WebDAV password: %s\n' "$([[ -n "$WEBDAV_PASSWORD" ]] && printf configured || printf not-configured)"
  printf 'Target directory: %s\n' "$TARGET_DIR"
  printf 'Reload command: %s\n' "${RELOAD_CMD:-not configured}"
  printf 'Cron schedule: %s\n' "$CRON_SCHEDULE"
}

agent_cron_install() {
  command -v crontab >/dev/null 2>&1 || { printf 'crontab is required\n' >&2; return 1; }
  local marker='# acme-agent managed job' current job
  current=$(crontab -l 2>/dev/null || true)
  current=$(printf '%s\n' "$current" | sed "/$marker/d")
  job="$CRON_SCHEDULE $SCRIPT_DIR/acme-agent.sh sync >>$AGENT_LOG 2>&1 $marker"
  {
    [[ -n "$current" ]] && printf '%s\n' "$current"
    printf '%s\n' "$job"
  } | crontab -
  printf 'Agent Cron installed: %s\n' "$job"
}

agent_cron_remove() {
  command -v crontab >/dev/null 2>&1 || { printf 'crontab is required\n' >&2; return 1; }
  local marker='# acme-agent managed job' current
  current=$(crontab -l 2>/dev/null || true)
  printf '%s\n' "$current" | sed "/$marker/d" | crontab -
  printf 'Agent Cron removed\n'
}

agent_usage() {
  cat <<'EOF'
Usage: acme-agent <command>

Commands:
  sync                 Download metadata and changed certificates once
  config               Show the agent configuration
  cron install         Install the configured periodic sync job
  cron remove          Remove the periodic sync job
  version              Show the agent version
EOF
}

agent_config_load
case "${1:-sync}" in
  sync) agent_sync ;;
  config) agent_config_show ;;
  cron)
    case "${2:-}" in
      install) agent_cron_install ;;
      remove) agent_cron_remove ;;
      *) agent_usage >&2; exit 2 ;;
    esac
    ;;
  version) printf 'ACME Agent 1.0.0\n' ;;
  help|-h|--help) agent_usage ;;
  *) agent_usage >&2; exit 2 ;;
esac
