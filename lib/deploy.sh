#!/usr/bin/env bash

deploy_extra_stem() {
  local domain="$1"
  [[ "$domain" == \*.* ]] && domain="${domain#*.}"
  printf '%s\n' "$domain"
}
deploy_domain_dir() { printf '%s/%s\n' "$CERT_DIR" "$(deploy_extra_stem "$1")"; }
deploy_validate_path() { valid_abs_path "$1" || { error "Path must be absolute and cannot contain newlines: $1"; return 1; }; }
deploy_extra_sync_command() {
  local domain="$1" target_dir="$2" key_file="$3" fullchain_file="$4" stem extra_key extra_fullchain
  stem=$(deploy_extra_stem "$domain")
  extra_key="$target_dir/$stem.key"
  extra_fullchain="$target_dir/$stem.pem"
  printf 'cp -- %s %s && chmod 600 %s && cp -- %s %s && chmod 644 %s' \
    "$(shell_quote "$key_file")" "$(shell_quote "$extra_key")" "$(shell_quote "$extra_key")" \
    "$(shell_quote "$fullchain_file")" "$(shell_quote "$extra_fullchain")" "$(shell_quote "$extra_fullchain")"
}
deploy_meta_sync_command() {
  printf '%s meta sync >/dev/null 2>&1 || true' "$(shell_quote "$SCRIPT_DIR/acme-manager.sh")"
}
deploy_sync_extra_files() {
  local domain="$1" target_dir="$2" key_file="$3" fullchain_file="$4" stem extra_key extra_fullchain
  [[ -f "$key_file" && -f "$fullchain_file" ]] || {
    error "acme.sh did not create the certificate files required for extra copies"
    return 1
  }
  stem=$(deploy_extra_stem "$domain")
  extra_key="$target_dir/$stem.key"
  extra_fullchain="$target_dir/$stem.pem"
  cp -f -- "$key_file" "$extra_key"
  cp -f -- "$fullchain_file" "$extra_fullchain"
  chmod 600 "$extra_key"
  chmod 644 "$extra_fullchain"
}

deploy_cert() {
  local domain="${1:-}" key_type="${2:-$DEFAULT_KEY_TYPE}" target_dir key_file fullchain_file ca_file cert_file reloadcmd sync_cmd meta_cmd
  [[ -n "$domain" ]] || { error 'Domain is required'; return 1; }
  valid_domain "$domain" || { error "Invalid domain: $domain"; return 1; }
  case "$key_type" in ec-256) local key_args=(--ecc);; rsa-2048|rsa-3072|rsa-4096) local key_args=();; *) error 'Invalid key type'; return 1;; esac
  target_dir=$(prompt_value 'Deployment directory' "$(deploy_domain_dir "$domain")")
  deploy_validate_path "$target_dir" || return 1
  key_file=$(prompt_value 'Private key path' "$target_dir/privkey.pem")
  fullchain_file=$(prompt_value 'Fullchain path' "$target_dir/fullchain.pem")
  ca_file=$(prompt_value 'CA chain path' "$target_dir/ca.pem")
  cert_file=$(prompt_value 'Certificate path' "$target_dir/cert.pem")
  for path in "$key_file" "$fullchain_file" "$ca_file" "$cert_file"; do deploy_validate_path "$path" || return 1; done
  reloadcmd=$(prompt_value 'Service reload hook (for example: nginx -t && systemctl reload nginx; empty skips service reload)' '')
  [[ -n "$reloadcmd" ]] && ! confirm 'acme.sh will execute this reload hook after renewal. Use this command?' && reloadcmd=''
  sync_cmd=$(deploy_extra_sync_command "$domain" "$target_dir" "$key_file" "$fullchain_file")
  meta_cmd=$(deploy_meta_sync_command)
  reloadcmd="$sync_cmd && { $meta_cmd; }${reloadcmd:+ && $reloadcmd}"
  mkdir -p "$target_dir"
  local args=(--install-cert -d "$domain" "${key_args[@]}" --key-file "$key_file" --fullchain-file "$fullchain_file" --ca-file "$ca_file" --cert-file "$cert_file")
  [[ -n "$reloadcmd" ]] && args+=(--reloadcmd "$reloadcmd")
  if ! run_acme_logged deploy "${args[@]}"; then
    error 'Certificate deployment failed; see the log'
    notify_event 'Deployment failed' "$domain" "Target directory=$target_dir. See $(_log_file)." || true
    return 1
  fi
  deploy_sync_extra_files "$domain" "$target_dir" "$key_file" "$fullchain_file" || return 1
  chmod 600 "$key_file" 2>/dev/null || true
  chmod 644 "$fullchain_file" "$ca_file" "$cert_file" 2>/dev/null || true
  meta_sync || warn 'Certificate metadata/WebDAV synchronization failed; local deployment is complete'
  notify_event 'Deployment succeeded' "$domain" "Target directory=$target_dir" || true
  success "Certificate deployed to $target_dir"
}

deploy_noninteractive() {
  local domain='' target_dir='' reloadcmd='' key_type="$DEFAULT_KEY_TYPE" key_file='' fullchain_file='' ca_file='' cert_file='' sync_cmd meta_cmd args=()
  while (($#)); do
    case "$1" in
      -d|--domain) domain="$2"; shift 2;;
      --key-type) key_type="$2"; shift 2;;
      --target-dir) target_dir="$2"; shift 2;;
      --key-file) key_file="$2"; shift 2;;
      --fullchain-file) fullchain_file="$2"; shift 2;;
      --ca-file) ca_file="$2"; shift 2;;
      --cert-file) cert_file="$2"; shift 2;;
      --reloadcmd) reloadcmd="$2"; shift 2;;
      *) error "Unknown deploy argument: $1"; return 2;;
    esac
  done
  valid_domain "$domain" || { error 'Missing or invalid domain'; return 2; }
  [[ -n "$target_dir" ]] || target_dir=$(deploy_domain_dir "$domain")
  valid_abs_path "$target_dir" || return 2
  [[ -n "$key_file" ]] || key_file="$target_dir/privkey.pem"
  [[ -n "$fullchain_file" ]] || fullchain_file="$target_dir/fullchain.pem"
  [[ -n "$ca_file" ]] || ca_file="$target_dir/ca.pem"
  [[ -n "$cert_file" ]] || cert_file="$target_dir/cert.pem"
  for path in "$key_file" "$fullchain_file" "$ca_file" "$cert_file"; do deploy_validate_path "$path" || return 2; done
  sync_cmd=$(deploy_extra_sync_command "$domain" "$target_dir" "$key_file" "$fullchain_file")
  meta_cmd=$(deploy_meta_sync_command)
  reloadcmd="$sync_cmd && { $meta_cmd; }${reloadcmd:+ && $reloadcmd}"
  mkdir -p "$target_dir"
  args+=(--install-cert -d "$domain")
  case "$key_type" in ec-256) args+=(--ecc);; rsa-2048) args+=(--keylength 2048);; rsa-3072) args+=(--keylength 3072);; rsa-4096) args+=(--keylength 4096);; *) error 'Invalid key type'; return 2;; esac
  args+=(--key-file "$key_file" --fullchain-file "$fullchain_file" --ca-file "$ca_file" --cert-file "$cert_file")
  args+=(--reloadcmd "$reloadcmd")
  if ! run_acme_logged deploy "${args[@]}"; then
    notify_event 'Deployment failed' "$domain" "Target directory=$target_dir. See $(_log_file)." || true
    return 1
  fi
  deploy_sync_extra_files "$domain" "$target_dir" "$key_file" "$fullchain_file" || return 1
  chmod 600 "$key_file" 2>/dev/null || true
  chmod 644 "$fullchain_file" "$ca_file" "$cert_file" 2>/dev/null || true
  meta_sync || warn 'Certificate metadata/WebDAV synchronization failed; local deployment is complete'
  notify_event 'Deployment succeeded' "$domain" "Target directory=$target_dir" || true
}
