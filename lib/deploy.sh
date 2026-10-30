#!/usr/bin/env bash

deploy_domain_dir() { printf '%s/%s\n' "$CERT_DIR" "$1"; }
deploy_validate_path() { valid_abs_path "$1" || { error "Path must be absolute and cannot contain newlines: $1"; return 1; }; }

deploy_cert() {
  local domain="${1:-}" key_type="${2:-$DEFAULT_KEY_TYPE}" target_dir key_file fullchain_file ca_file cert_file reloadcmd
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
  reloadcmd=$(prompt_value 'Reload hook (for example: nginx -t && systemctl reload nginx; empty disables it)' '')
  [[ -n "$reloadcmd" ]] && ! confirm 'acme.sh will execute this reload hook after renewal. Use this command?' && reloadcmd=''
  mkdir -p "$target_dir"
  local args=(--install-cert -d "$domain" "${key_args[@]}" --key-file "$key_file" --fullchain-file "$fullchain_file" --ca-file "$ca_file" --cert-file "$cert_file")
  [[ -n "$reloadcmd" ]] && args+=(--reloadcmd "$reloadcmd")
  if ! run_acme_logged deploy "${args[@]}"; then
    error 'Certificate deployment failed; see the log'
    notify_event 'Deployment failed' "$domain" "Target directory=$target_dir. See $(_log_file)." || true
    return 1
  fi
  chmod 600 "$key_file" 2>/dev/null || true
  chmod 644 "$fullchain_file" "$ca_file" "$cert_file" 2>/dev/null || true
  notify_event 'Deployment succeeded' "$domain" "Target directory=$target_dir" || true
  success "Certificate deployed to $target_dir"
}

deploy_noninteractive() {
  local domain='' target_dir='' reloadcmd='' key_type="$DEFAULT_KEY_TYPE" key_file='' fullchain_file='' ca_file='' cert_file='' args=()
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
  mkdir -p "$target_dir"
  args+=(--install-cert -d "$domain")
  case "$key_type" in ec-256) args+=(--ecc);; rsa-2048) args+=(--keylength 2048);; rsa-3072) args+=(--keylength 3072);; rsa-4096) args+=(--keylength 4096);; *) error 'Invalid key type'; return 2;; esac
  args+=(--key-file "$key_file" --fullchain-file "$fullchain_file" --ca-file "$ca_file" --cert-file "$cert_file")
  [[ -n "$reloadcmd" ]] && args+=(--reloadcmd "$reloadcmd")
  if ! run_acme_logged deploy "${args[@]}"; then
    notify_event 'Deployment failed' "$domain" "Target directory=$target_dir. See $(_log_file)." || true
    return 1
  fi
  chmod 600 "$key_file" 2>/dev/null || true
  chmod 644 "$fullchain_file" "$ca_file" "$cert_file" 2>/dev/null || true
  notify_event 'Deployment succeeded' "$domain" "Target directory=$target_dir" || true
}
