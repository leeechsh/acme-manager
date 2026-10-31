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
  CERT_LAST_DOMAIN="${domains[0]}"
  CERT_LAST_KEY_TYPE="$key_type"
  notify_event 'Issuance succeeded' "${domains[*]}" "CA=$ca DNS=$provider KEY=$key_type" || true
  success "Certificate issued: ${domains[*]}"
}

cert_issue_and_deploy() {
  CERT_LAST_DOMAIN=''
  CERT_LAST_KEY_TYPE=''
  cert_issue --interactive || return 1
  [[ -n "$CERT_LAST_DOMAIN" ]] || return 0
  deploy_cert "$CERT_LAST_DOMAIN" "$CERT_LAST_KEY_TYPE"
}

cert_meta_rows() {
  local meta="$1" root="$2"
  [[ -f "$meta" ]] || return 0
  awk -F'"' -v root="$root" '
    function reset_entry() {
      domain=""; directory=""; domains=""; key_type=""; ca=""
      issued_at=""; expires_at=""
    }
    /"domain"[[:space:]]*:/ {
      domain=$4
    }
    /"directory"[[:space:]]*:/ {
      directory=$4
    }
    /"domains"[[:space:]]*:/ {
      domains=$0
      sub(/^[^[]*\[/, "", domains)
      sub(/\].*$/, "", domains)
      gsub(/"/, "", domains)
      gsub(/[[:space:]]+/, "", domains)
    }
    /"key_type"[[:space:]]*:/ {
      key_type=$4
    }
    /"ca"[[:space:]]*:/ {
      ca=$4
    }
    /"issued_at"[[:space:]]*:/ {
      issued_at=$4
    }
    /"expires_at"[[:space:]]*:/ {
      expires_at=$4
    }
    /"files"[[:space:]]*:/ {
      if (domain != "" && directory != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s/%s\n",
          domain, key_type, domains, ca, issued_at, expires_at, root, directory
      }
      reset_entry()
    }
  ' "$meta"
}

cert_native_record_exists() {
  local directory="$1" stem
  stem=$(basename "$directory")
  [[ -f "$ACME_HOME/${stem}_ecc/${stem}.conf" || -f "$ACME_HOME/$stem/$stem.conf" ]]
}

cert_metadata_source() {
  local metadata="$1" directory="$2" node_id local_node
  node_id=$(meta_node_id "$metadata")
  local_node=$(webdav_node_id)
  if [[ -n "$node_id" && "$node_id" != "$local_node" ]]; then
    printf 'Remote %s\n' "$node_id"
  elif cert_native_record_exists "$directory"; then
    printf 'Local acme.sh\n'
  elif webdav_mode_allows_download; then
    printf 'Remote %s\n' "${node_id:-unknown}"
  else
    printf 'Managed files\n'
  fi
}

cert_deployed_list() {
  local metadata root rows filtered='' directory row source
  printf '\n%sManaged / synchronized certificate files%s\n' "$UI_ACCENT" "$UI_RESET"
  while IFS=$'\t' read -r metadata root; do
    [[ -f "$metadata" ]] || continue
    rows=$(cert_meta_rows "$metadata" "$root")
    [[ -n "$rows" ]] || continue
    while IFS= read -r row; do
      directory="${row##*$'\t'}"
      [[ -f "$directory/cert.pem" ]] || continue
      source=$(cert_metadata_source "$metadata" "$directory")
      filtered+="$source"$'\t'"$row"$'\n'
    done <<<"$rows"
  done < <(
    printf '%s\t%s\n' "$CERT_DIR/meta.json" "$CERT_DIR"
    if [[ "$AGENT_TARGET_DIR/meta.json" != "$CERT_DIR/meta.json" ]]; then
      printf '%s\t%s\n' "$AGENT_TARGET_DIR/meta.json" "$AGENT_TARGET_DIR"
    fi
  )
  if [[ -n "$filtered" ]]; then
    local table formatted
    table=$(printf '%s\n%s' 'Source	Domain	Key type	SAN domains	CA	Issued	Expires	Deployment directory' "$filtered")
    formatted=$(ui_table "$table")
    printf '%s\n' "$formatted"
  else
    ui_hint 'No managed certificate metadata found'
  fi
}

cert_list() {
  local raw formatted header native_available=0
  raw=$(mktemp "${TMPDIR:-/tmp}/acme-manager-list.XXXXXX") || return 1
  if acme_command >/dev/null 2>&1; then
    native_available=1
    printf '\n%sNative acme.sh certificates (local)%s\n' "$UI_ACCENT" "$UI_RESET"
    if run_acme --list >"$raw" 2>&1; then
      formatted=$(awk 'NF { for (i=1; i<=NF; i++) printf "%s%s", $i, (i==NF ? "\n" : "\t") }' "$raw")
      formatted=$(ui_table "$formatted")
      header=$(printf '%s\n' "$formatted" | head -1)
      [[ -n "$header" ]] && printf '%s%s%s\n' "$UI_PRIMARY" "$header" "$UI_RESET"
      printf '%s\n' "$formatted" | tail -n +2
    else
      warn 'Unable to read the native acme.sh certificate list; showing managed files only'
      cat "$raw"
    fi
  else
    ui_hint 'acme.sh is not installed; showing managed certificate files only'
  fi
  rm -f "$raw"
  cert_deployed_list
  cert_deployment_summary
  (( native_available )) || return 0
}

cert_info() { local domain="$1"; valid_domain "$domain" || return 1; run_acme --info --domain "$domain"; }

cert_available_domains() {
  local file domain metadata root rows row directory
  if [[ -d "$ACME_HOME" ]]; then
    while IFS= read -r -d '' file; do
      domain=$(awk -F= '$1=="Le_Domain" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
      valid_domain "$domain" && printf '%s\n' "$domain"
    done < <(find "$ACME_HOME" -mindepth 2 -maxdepth 2 -type f -name '*.conf' -print0 2>/dev/null)
  fi
  while IFS=$'\t' read -r metadata root; do
    [[ -f "$metadata" ]] || continue
    rows=$(cert_meta_rows "$metadata" "$root")
    [[ -n "$rows" ]] || continue
    while IFS= read -r row; do
      domain="${row%%$'\t'*}"
      directory="${row##*$'\t'}"
      [[ -f "$directory/cert.pem" ]] || continue
      valid_domain "$domain" && printf '%s\n' "$domain"
    done <<<"$rows"
  done < <(
    printf '%s\t%s\n' "$CERT_DIR/meta.json" "$CERT_DIR"
    if [[ "$AGENT_TARGET_DIR/meta.json" != "$CERT_DIR/meta.json" ]]; then
      printf '%s\t%s\n' "$AGENT_TARGET_DIR/meta.json" "$AGENT_TARGET_DIR"
    fi
  )
}

cert_prompt_domain() {
  local -a domains=() options=()
  local domain
  mapfile -t domains < <(cert_available_domains | sort -u)
  if ((${#domains[@]} == 0)); then
    prompt_value 'Domain' ''
    return
  fi
  options=("" 'Cancel')
  for domain in "${domains[@]}"; do
    options+=("$domain" "$domain")
  done
  prompt_select 'Select a certificate to remove' '' "${options[@]}"
}

cert_webdav_deployment_summary() {
  local metadata root rows row domain directory source stem
  local cert key fullchain ca extra_key extra_fullchain
  local -A seen=()
  while IFS=$'\t' read -r metadata root; do
    [[ -f "$metadata" ]] || continue
    rows=$(cert_meta_rows "$metadata" "$root")
    [[ -n "$rows" ]] || continue
    while IFS= read -r row; do
      domain="${row%%$'\t'*}"
      directory="${row##*$'\t'}"
      [[ -f "$directory/cert.pem" ]] || continue
      source=$(cert_metadata_source "$metadata" "$directory")
      [[ "$source" == Remote\ * ]] || continue
      [[ -n "${seen[$directory]+set}" ]] && continue
      seen["$directory"]=1
      stem=$(deploy_extra_stem "$domain")
      cert="$directory/cert.pem"
      key="$directory/privkey.pem"
      fullchain="$directory/fullchain.pem"
      ca="$directory/ca.pem"
      extra_key="$directory/$stem.key"
      extra_fullchain="$directory/$stem.pem"
      printf '  %s%s%s %s[%s]%s\n' "$UI_PRIMARY" "$domain" "$UI_RESET" "$UI_MUTED" "$source" "$UI_RESET"
      printf '    %-10s %s\n' 'cert' "$cert"
      printf '    %-10s %s\n' 'key' "$key"
      printf '    %-10s %s\n' 'fullchain' "$fullchain"
      printf '    %-10s %s\n' 'ca' "$ca"
      printf '    %-10s %s\n' 'key-copy' "$extra_key"
      printf '    %-10s %s\n' 'chain-copy' "$extra_fullchain"
    done <<<"$rows"
  done < <(
    printf '%s\t%s\n' "$CERT_DIR/meta.json" "$CERT_DIR"
    if [[ "$AGENT_TARGET_DIR/meta.json" != "$CERT_DIR/meta.json" ]]; then
      printf '%s\t%s\n' "$AGENT_TARGET_DIR/meta.json" "$AGENT_TARGET_DIR"
    fi
  )
}

cert_deployment_summary() {
  local file domain cert key fullchain ca target_dir stem extra_key extra_fullchain
  printf '\n%sDeployment Paths%s\n' "$UI_ACCENT" "$UI_RESET"
  if [[ -d "$ACME_HOME" ]]; then
    while IFS= read -r -d '' file; do
      domain=$(awk -F= '$1=="Le_Domain" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
      [[ -n "$domain" ]] || continue
      cert=$(awk -F= '$1=="Le_RealCertPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
      key=$(awk -F= '$1=="Le_RealKeyPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
      fullchain=$(awk -F= '$1=="Le_RealFullChainPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
      ca=$(awk -F= '$1=="Le_RealCACertPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
      printf '  %s%s%s %s[Local acme.sh]%s\n' "$UI_PRIMARY" "$domain" "$UI_RESET" "$UI_MUTED" "$UI_RESET"
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
  fi
  cert_webdav_deployment_summary
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
  local domain="$1" revoke="${2:-false}" remove_rc=0
  valid_domain "$domain" || { error 'Invalid domain'; return 1; }
  confirm "Remove the local record for $domain?" || { warn 'Cancelled'; return 1; }
  if [[ "$revoke" == true ]]; then
    confirm "Revoke the $domain certificate at the CA? This cannot be undone" || { warn 'Cancelled'; return 1; }
    run_acme_logged revoke --revoke --domain "$domain" || { error 'Certificate revocation failed'; return 1; }
  fi
  if run_acme_logged remove --remove --domain "$domain"; then
    remove_rc=0
  else
    remove_rc=$?
    warn 'acme.sh did not remove a matching renewal record; cleaning local native files anyway'
  fi
  cert_remove_native_files "$domain"
  if (( remove_rc != 0 )); then
    error 'Certificate removal failed; local native files were cleaned'
    return "$remove_rc"
  fi
  meta_sync || warn 'Certificate metadata/WebDAV synchronization failed after removal'
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
    ui_menu_item 1 'Issue certificate' 'Issue, then deploy automatically'
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
      1) cert_issue_and_deploy || true; pause_screen;;
      2) cert_list || true; pause_screen;;
      3) domain=$(prompt_value 'Domain'); cert_info "$domain" || true; pause_screen;;
      4) domain=$(prompt_value 'Domain (leave empty to renew all)' ''); if [[ -n "$domain" ]]; then cert_renew --domain "$domain" || true; else cert_renew --all || true; fi; pause_screen;;
      5) cert_expiry_check || true; pause_screen;;
      6)
        domain=$(cert_prompt_domain) || { warn 'Cancelled'; pause_screen; continue; }
        [[ -n "$domain" ]] || { warn 'Cancelled'; pause_screen; continue; }
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
