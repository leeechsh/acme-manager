#!/usr/bin/env bash

webdav_password() {
  account_get_var WEBDAV_PASSWORD 2>/dev/null || true
}

webdav_base_url() {
  printf '%s\n' "${WEBDAV_URL%/}"
}

webdav_validate() {
  [[ "$WEBDAV_ENABLED" == true ]] || return 0
  [[ -n "$WEBDAV_URL" ]] || { error 'WebDAV URL is not configured'; return 1; }
  [[ "$WEBDAV_URL" =~ ^https?://[^[:space:]]+$ ]] || { error 'WebDAV URL must start with http:// or https://'; return 1; }
  [[ -n "$WEBDAV_USERNAME" ]] || { error 'WebDAV username is not configured'; return 1; }
  [[ -n "$(webdav_password)" ]] || { error 'WebDAV password is not configured'; return 1; }
  command_exists curl || { error 'curl is required for WebDAV synchronization'; return 1; }
}

webdav_url_join() {
  local base="${1%/}" child="${2#/}"
  printf '%s/%s\n' "$base" "$child"
}

webdav_netrc() {
  local url="$1" file host password
  host="${url#*://}"
  host="${host%%/*}"
  host="${host##*@}"
  host="${host%%:*}"
  password=$(webdav_password)
  file=$(mktemp "${TMPDIR:-/tmp}/acme-manager-webdav.XXXXXX") || return 1
  chmod 600 "$file"
  printf 'machine %s login %s password %s\n' "$host" "$WEBDAV_USERNAME" "$password" >"$file"
  printf '%s\n' "$file"
}

webdav_request() {
  local url="$1"; shift
  local netrc rc
  netrc=$(webdav_netrc "$url") || return 1
  curl --fail --silent --show-error --location --netrc-file "$netrc" "$@" "$url"
  rc=$?
  rm -f "$netrc"
  return "$rc"
}

webdav_collection() {
  local url="$1" code
  code=$(webdav_request "$url" -X MKCOL -o /dev/null -w '%{http_code}' 2>/dev/null || true)
  [[ "$code" =~ ^2[0-9][0-9]$ || "$code" == 405 || "$code" == 301 || "$code" == 302 ]]
}

webdav_put() {
  local file="$1" url="$2"
  webdav_request "$url" -T "$file" -o /dev/null
}

webdav_status() {
  printf 'WebDAV enabled: %s\n' "$WEBDAV_ENABLED"
  printf 'WebDAV URL: %s\n' "${WEBDAV_URL:-not configured}"
  printf 'WebDAV username: %s\n' "${WEBDAV_USERNAME:-not configured}"
  if [[ -n "$(webdav_password)" ]]; then
    printf 'WebDAV password: configured\n'
  else
    printf 'WebDAV password: not configured\n'
  fi
  if [[ "$WEBDAV_ENABLED" == true ]]; then
    webdav_validate || return 1
    success 'WebDAV configuration is valid'
  fi
}

webdav_configure() {
  WEBDAV_ENABLED=$(prompt_select 'Enable WebDAV synchronization' "$WEBDAV_ENABLED" \
    true 'Enabled' \
    false 'Disabled') || return 1
  WEBDAV_URL=$(prompt_value 'WebDAV collection URL' "${WEBDAV_URL:-}")
  WEBDAV_USERNAME=$(prompt_value 'WebDAV username' "${WEBDAV_USERNAME:-}")
  local password
  password=$(prompt_value 'WebDAV password (empty keeps current password)') || return 1
  [[ -n "$password" ]] && account_set_var WEBDAV_PASSWORD "$password"
  config_write || return 1
  chmod 600 "$(account_conf_path)"
  webdav_status
}

webdav_test() {
  [[ "$WEBDAV_ENABLED" == true ]] || { error 'Enable WebDAV synchronization first'; return 1; }
  webdav_validate || return 1
  webdav_request "$(webdav_base_url)" -X OPTIONS -o /dev/null
  success 'WebDAV endpoint is reachable'
}

webdav_sync() {
  local meta_file="${1:-}" base="${2:-}" dir domain file remote_dir
  [[ "$WEBDAV_ENABLED" == true ]] || return 0
  webdav_validate || return 1
  meta_file="${meta_file:-$CERT_DIR/meta.json}"
  base=$(webdav_base_url)
  [[ -f "$meta_file" ]] || { error "Metadata file not found: $meta_file"; return 1; }
  webdav_collection "$base" || { error "Unable to create or access WebDAV collection: $base"; return 1; }
  while IFS= read -r -d '' dir; do
    domain=$(basename "$dir")
    [[ -f "$dir/cert.pem" && -f "$dir/fullchain.pem" ]] || continue
    remote_dir=$(webdav_url_join "$base" "$domain")
    webdav_collection "$remote_dir" || { error "Unable to create WebDAV directory: $domain"; return 1; }
    for file in cert.pem privkey.pem fullchain.pem ca.pem "$domain.key" "$domain.pem"; do
      [[ -f "$dir/$file" ]] || continue
      webdav_put "$dir/$file" "$(webdav_url_join "$remote_dir" "$file")" || {
        error "WebDAV upload failed: $domain/$file"
        return 1
      }
    done
  done < <(find "$CERT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  webdav_put "$meta_file" "$(webdav_url_join "$base" "$(basename "$meta_file")")" || {
    error 'WebDAV metadata upload failed'
    return 1
  }
  success "WebDAV synchronization completed: $base"
}

webdav_menu() {
  while true; do
    menu_header 'WebDAV Synchronization' 'Upload deployed certificates and metadata'
    menu_home_status
    ui_section 'Actions'
    ui_menu_item 1 'View WebDAV status' 'URL, account and connectivity settings'
    ui_menu_item 2 'Configure WebDAV' 'Password is stored in the native account file'
    ui_menu_item 3 'Test WebDAV endpoint' 'Run an authenticated OPTIONS request'
    ui_menu_item 4 'Sync certificates now' 'Generate metadata, then upload files and metadata'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose an action [0-4]:' || return 0
    case "$MENU_CHOICE" in
      1) webdav_status || true; pause_screen;;
      2) webdav_configure || true; pause_screen;;
      3) webdav_test || true; pause_screen;;
      4) meta_sync || true; pause_screen;;
      0) return 0;;
      *) warn 'Invalid choice';;
    esac
  done
}
