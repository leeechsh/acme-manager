#!/usr/bin/env bash

cert_key_args() {
  case "$1" in
    ec-256) printf '%s\n' '--keylength' 'ec-256';;
    rsa-2048) printf '%s\n' '--keylength' '2048';;
    rsa-3072) printf '%s\n' '--keylength' '3072';;
    rsa-4096) printf '%s\n' '--keylength' '4096';;
    *) return 1;;
  esac
}

cert_issue_key_exists() {
  local domain="$1" key_type="$2" stem suffix=''
  stem="${domain#\*.}"
  [[ "$key_type" == 'ec-256' ]] && suffix='_ecc'
  [[ -f "$ACME_HOME/${stem}${suffix}/${stem}.key" ]]
}

cert_remove_native_files() {
  local domain="$1" stem path removed=0
  stem="${domain#\*.}"
  for path in "$ACME_HOME/$stem" "$ACME_HOME/${stem}_ecc"; do
    [[ -d "$path" ]] || continue
    rm -rf -- "$path"
    removed=1
  done
  if (( removed )); then
    info "Removed native acme.sh files for $stem"
  else
    ui_hint "No native acme.sh certificate directory found for $stem"
  fi
}

cert_issue() {
  local provider="$DEFAULT_DNS" ca="$DEFAULT_CA" key_type="$DEFAULT_KEY_TYPE" email='' staging=0 force=0 wildcard=1 interactive=0 domains=() domain value
  while (($#)); do
    case "$1" in
      -d|--domain) domains+=("$2"); shift 2;;
      --domains) IFS=',' read -r -a domains <<<"$2"; shift 2;;
      --no-wildcard) wildcard=0; shift;;
      --force) force=1; shift;;
      --interactive) interactive=1; shift;;
      --dns) provider="$2"; shift 2;;
      --ca|--server) ca="$2"; shift 2;;
      --key-type) key_type="$2"; shift 2;;
      --email) email="$2"; shift 2;;
      --staging) staging=1; shift;;
      *) error "Unknown issue argument: $1"; return 2;;
    esac
  done
  if ((${#domains[@]} == 0)); then
    value=$(prompt_value 'Domains (root, wildcard or comma-separated SANs)') || return 1
    IFS=',' read -r -a domains <<<"$value"
  fi
  local index
  for index in "${!domains[@]}"; do
    domain="${domains[index]}"
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    domains[index]="$domain"
    valid_domain "$domain" || { error "Invalid domain: $domain"; return 1; }
  done
  if (( wildcard )) && ((${#domains[@]} == 1)) && [[ "${domains[0]}" != \*.* ]]; then
    domains+=("*.${domains[0]}")
  fi
  if (( interactive )); then
    provider=$(prompt_select 'Select a DNS provider' "$provider" \
      cloudflare 'Cloudflare' \
      dnspod 'Tencent DNSPod' \
      aliyun 'Alibaba Cloud DNS') || return 1
    ca=$(prompt_select 'Select a certificate authority' "$ca" \
      letsencrypt "Let's Encrypt" \
      zerossl 'ZeroSSL') || return 1
    key_type=$(prompt_select 'Select a key type' "$key_type" \
      ec-256 'ECDSA P-256' \
      rsa-2048 'RSA 2048' \
      rsa-3072 'RSA 3072' \
      rsa-4096 'RSA 4096') || return 1
  fi
  valid_choice "$provider" cloudflare dnspod aliyun || { error 'Invalid DNS provider'; return 1; }
  valid_choice "$ca" letsencrypt zerossl || { error 'Invalid CA'; return 1; }
  valid_choice "$key_type" ec-256 rsa-2048 rsa-3072 rsa-4096 || { error 'Invalid key type'; return 1; }
  if [[ -z "$email" && -t 0 ]]; then
    email=$(prompt_value 'Account email (optional)' '')
  fi
  local args=(--issue --dns "$(dns_hook "$provider")" --server "$ca")
  for domain in "${domains[@]}"; do args+=(--domain "$domain"); done
  while IFS= read -r value; do args+=("$value"); done < <(cert_key_args "$key_type")
  (( staging )) && args+=(--staging)
  if (( force )) || cert_issue_key_exists "${domains[0]}" "$key_type"; then
    (( force )) || info "Existing domain key detected; retrying with --force"
    args+=(--force)
  fi
  [[ -n "$email" ]] && args+=(--accountemail "$email")
  if ! run_acme_logged issue "${args[@]}"; then
    error 'Certificate issuance failed; see the log'
    notify_event 'Issuance failed' "${domains[*]}" "CA=$ca DNS=$provider. See $(_log_file)." || true
    return 1
  fi
  notify_event 'Issuance succeeded' "${domains[*]}" "CA=$ca DNS=$provider KEY=$key_type" || true
  success "Certificate issued: ${domains[*]}"
}

cert_list() {
  local raw formatted header
  raw=$(mktemp "${TMPDIR:-/tmp}/acme-manager-list.XXXXXX") || return 1
  if ! run_acme --list >"$raw" 2>&1; then
    cat "$raw"
    rm -f "$raw"
    error 'Unable to read the certificate list'
    return 1
  fi
  formatted=$(awk 'NF { for (i=1; i<=NF; i++) printf "%s%s", $i, (i==NF ? "\n" : "\t") }' "$raw")
  formatted=$(ui_table "$formatted")
  header=$(printf '%s\n' "$formatted" | head -1)
  [[ -n "$header" ]] && printf '%s%s%s\n' "$UI_PRIMARY" "$header" "$UI_RESET"
  printf '%s\n' "$formatted" | tail -n +2
  rm -f "$raw"
  cert_deployment_summary
}

cert_info() { local domain="$1"; valid_domain "$domain" || return 1; run_acme --info --domain "$domain"; }

cert_deployment_summary() {
  local file domain cert key fullchain ca target_dir stem extra_key extra_fullchain
  [[ -d "$ACME_HOME" ]] || return 0
  printf '\n%sDeployment Paths%s\n' "$UI_ACCENT" "$UI_RESET"
  while IFS= read -r -d '' file; do
    domain=$(awk -F= '$1=="Le_Domain" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    [[ -n "$domain" ]] || continue
    cert=$(awk -F= '$1=="Le_RealCertPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    key=$(awk -F= '$1=="Le_RealKeyPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    fullchain=$(awk -F= '$1=="Le_RealFullChainPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    ca=$(awk -F= '$1=="Le_RealCACertPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    printf '  %s%s%s\n' "$UI_PRIMARY" "$domain" "$UI_RESET"
    printf '    %-10s %s\n' 'cert' "${cert:--}"
    printf '    %-10s %s\n' 'key' "${key:--}"
    printf '    %-10s %s\n' 'fullchain' "${fullchain:--}"
    printf '    %-10s %s\n' 'ca' "${ca:--}"
    if [[ -n "$cert" && "$cert" != '-' ]]; then
      target_dir=$(dirname "$cert")
      stem=$(deploy_extra_stem "$domain")
      extra_key="$target_dir/$stem.key"
      extra_fullchain="$target_dir/$stem.pem"
      printf '    %-10s %s\n' 'key-copy' "$extra_key"
      printf '    %-10s %s\n' 'chain-copy' "$extra_fullchain"
    fi
  done < <(find "$ACME_HOME" -mindepth 2 -maxdepth 2 -type f -name '*.conf' -print0 2>/dev/null)
}

cert_renew() {
  local all=0 force=0 domain='' key_type=''
  while (($#)); do
    case "$1" in --all) all=1; shift;; -d|--domain) domain="$2"; shift 2;; --force) force=1; shift;; --key-type) key_type="$2"; shift 2;; *) error "Unknown renew argument: $1"; return 2;; esac
  done
  local args=(--renew)
  if (( all )); then args=(--renew-all); else valid_domain "$domain" || { error 'renew requires --domain, or use --all'; return 2; }; args+=(--domain "$domain"); fi
  case "$key_type" in
    ec-256) args+=(--ecc);;
    rsa-2048) args+=(--keylength 2048);;
    rsa-3072) args+=(--keylength 3072);;
    rsa-4096) args+=(--keylength 4096);;
    '') ;;
    *) error 'Invalid key type'; return 2;;
  esac
  (( force )) && args+=(--force)
  if ! run_acme_logged renew "${args[@]}"; then
    error 'Certificate renewal failed; see the log'
    notify_event 'Renewal failed' "${domain:-all certificates}" "See $(_log_file)." || true
    return 1
  fi
  notify_event 'Renewal succeeded' "${domain:-all certificates}" 'The renewal command completed.' || true
  success 'Certificate renewal completed'
}

cert_remove() {
  local domain="$1" revoke="${2:-false}"
  valid_domain "$domain" || { error 'Invalid domain'; return 1; }
  confirm "Remove the local record for $domain?" || { warn 'Cancelled'; return 1; }
  if [[ "$revoke" == true ]]; then
    confirm "Revoke the $domain certificate at the CA? This cannot be undone" || { warn 'Cancelled'; return 1; }
    run_acme_logged revoke --revoke --domain "$domain" || { error 'Certificate revocation failed'; return 1; }
  fi
  run_acme_logged remove --remove --domain "$domain" || { error 'Certificate removal failed'; return 1; }
  cert_remove_native_files "$domain"
  success "Certificate processed: $domain"
}

cert_expiry_check() {
  local days="${1:-$EXPIRY_DAYS}" file rc=0
  [[ "$days" =~ ^[0-9]+$ ]] || return 2
  if ! command_exists openssl; then error 'openssl is not installed'; return 1; fi
  if [[ ! -d "$CERT_DIR" ]]; then warn "Certificate directory does not exist: $CERT_DIR"; return 0; fi
  while IFS= read -r -d '' file; do
    if openssl x509 -checkend "$((days * 86400))" -noout -in "$file" >/dev/null 2>&1; then
      printf '%sOK%s  %s\n' "$UI_SUCCESS" "$UI_RESET" "$file"
    else
      printf '%sEXPIRING%s  %s\n' "$UI_WARNING" "$UI_RESET" "$file"
      rc=1
    fi
  done < <(find "$CERT_DIR" -type f \( -name '*.pem' -o -name '*.crt' \) -print0 2>/dev/null)
  return "$rc"
}

cert_menu() {
  while true; do
    menu_header 'Certificate Management' 'Manage the complete certificate lifecycle'
    menu_home_status
    ui_section 'Actions'
    ui_menu_item 1 'Issue certificate' 'Single domain / wildcard / multi-SAN'
    ui_menu_item 2 'List certificates' 'Validity, CA and deployment paths'
    ui_menu_item 3 'View certificate details' 'Read native acme.sh information'
    ui_menu_item 4 'Renew certificate' 'One certificate or all certificates'
    ui_menu_item 5 'Check expiry' "Warn ${EXPIRY_DAYS} days before expiry"
    ui_menu_item 6 'Remove / revoke' 'Destructive action; confirmation required'
    ui_menu_item 0 'Back'
    ui_footer
    menu_choice 'Choose an action [0-6]:' || return 0
    local domain revoke
    case "$MENU_CHOICE" in
      1) cert_issue --interactive || true; pause_screen;;
      2) cert_list || true; pause_screen;;
      3) domain=$(prompt_value 'Domain'); cert_info "$domain" || true; pause_screen;;
      4) domain=$(prompt_value 'Domain (leave empty to renew all)' ''); if [[ -n "$domain" ]]; then cert_renew --domain "$domain" || true; else cert_renew --all || true; fi; pause_screen;;
      5) cert_expiry_check || true; pause_screen;;
      6)
        domain=$(prompt_value 'Domain')
        revoke=$(prompt_select 'Also revoke the certificate at the CA?' false \
          false 'No' \
          true 'Yes')
        cert_remove "$domain" "$revoke" || true
        pause_screen
        ;;
      0) return 0;; *) warn 'Invalid choice';;
    esac
  done
}
