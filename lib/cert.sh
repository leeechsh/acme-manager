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

cert_native_home() {
  local configured
  configured=$(account_get_var CERT_HOME || true)
  printf '%s\n' "${configured:-${CERT_HOME:-${LE_CONFIG_HOME:-$ACME_HOME}}}"
}

cert_native_conf() {
  local domain="$1" key_type="$2" base
  base="${3:-$(cert_native_home)}/$domain"
  if [[ "$key_type" == ec-* || ( -z "$key_type" && ! -d "$base" && -d "${base}_ecc" ) ]]; then
    base+='_ecc'
  fi
  printf '%s/%s.conf\n' "$base" "$domain"
}

cert_dns_binding() {
  local hook
  hook=$(meta_conf_value "$1" Le_Webroot) || return 1
  dns_profile_binding "$hook"
}

cert_dns_credential_label() {
  local conf="$1" value hook binding provider profile label result='' seen=$'\n'
  local -a hooks=()
  value=$(meta_conf_value "$conf" Le_Webroot) || return 1
  IFS=',' read -r -a hooks <<<"$value"
  for hook in "${hooks[@]}"; do
    binding=$(dns_profile_binding "$hook") || continue
    IFS=$'\t' read -r provider profile <<<"$binding"
    label="$(dns_label "$provider") / $profile"
    [[ "$seen" == *$'\n'"$label"$'\n'* ]] && continue
    seen+="$label"$'\n'
    result+="${result:+, }$label"
  done
  printf '%s\n' "${result:--}"
}

cert_deployed_credential_label() {
  local domain="$1" deployed="$2" native_home="$3" alt_domain native_conf native_cert
  local deployed_fingerprint native_fingerprint label result=''
  [[ "$domain" =~ ^(\*\.)?[A-Za-z0-9.:_-]+$ && "$domain" != . && "$domain" != .. ]] || return 1
  deployed_fingerprint=$(openssl x509 -in "$deployed" -noout -fingerprint -sha256 2>/dev/null) || return 1
  for alt_domain in "$domain" "*.$domain"; do
    for native_conf in "$native_home/$alt_domain/$alt_domain.conf" "$native_home/${alt_domain}_ecc/$alt_domain.conf"; do
      [[ -f "$native_conf" ]] || continue
      native_cert="${native_conf%.conf}.cer"
      [[ -f "$native_cert" ]] || continue
      native_fingerprint=$(openssl x509 -in "$native_cert" -noout -fingerprint -sha256 2>/dev/null) || continue
      [[ "$deployed_fingerprint" == "$native_fingerprint" ]] || continue
      label=$(cert_dns_credential_label "$native_conf") || continue
      [[ -z "$result" || "$result" == "$label" ]] || return 1
      result="$label"
    done
  done
  [[ -n "$result" ]] || return 1
  printf '%s\n' "$result"
}

cert_dns_bind() {
  local file="$1" hook="$2" updated
  [[ -f "$file" && ! -L "$file" ]] || { error "Cannot update certificate record: $file"; return 1; }
  updated=$(awk -v hook="$hook" '
    /^Le_Webroot=/ { $0 = "Le_Webroot=\047" hook "\047"; count++ }
    { print }
    END { if (count != 1) exit 1 }
  ' "$file") || { error "Invalid DNS hook entry in $file"; return 1; }
  atomic_write "$file" 600 <<<"$updated"
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
  local profile='' current_profile='' current_provider='' cf_only=0 hook binding
  while (($#)); do
    case "$1" in
      -d|--domain) domains+=("$2"); shift 2;;
      --domains) IFS=',' read -r -a domains <<<"$2"; shift 2;;
      --no-wildcard) wildcard=0; shift;;
      --force) force=1; shift;;
      --interactive) interactive=1; shift;;
      --dns) provider="$2"; shift 2;;
      --dns-profile|--cf-profile)
        require_arg "$@" || return 2
        if [[ "$1" == --cf-profile ]]; then cf_only=1; else cf_only=0; fi
        profile="$2"; shift 2;;
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
    provider=$(dns_select_provider "$provider") || return 1
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
  if (( cf_only )) && [[ "$provider" != cloudflare ]]; then
    error '--cf-profile requires the Cloudflare DNS provider'
    return 2
  fi
  if binding=$(cert_dns_binding "$(cert_native_conf "${domains[0]}" "$key_type")"); then
    IFS=$'\t' read -r current_provider current_profile <<<"$binding"
    [[ "$current_provider" == "$provider" ]] || current_profile=''
  fi
  if (( interactive )) && [[ -z "$profile" ]]; then
    profile=$(dns_select_profile "$provider" "$current_profile") || return 1
  fi
  hook=$(dns_profile_hook "$provider" "${profile:-${current_profile:-legacy}}") || return 1
  if [[ -z "$email" && -t 0 ]]; then
    email=$(prompt_value 'Account email (optional)' '')
  fi
  local args=(--issue --dns "$hook" --server "$ca")
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
  local metadata root rows filtered='' directory row source domain credential native_home
  native_home=$(cert_native_home)
  printf '\n%sManaged / synchronized certificate files%s\n' "$UI_ACCENT" "$UI_RESET"
  while IFS=$'\t' read -r metadata root; do
    [[ -f "$metadata" ]] || continue
    rows=$(cert_meta_rows "$metadata" "$root")
    [[ -n "$rows" ]] || continue
    while IFS= read -r row; do
      directory="${row##*$'\t'}"
      [[ -f "$directory/cert.pem" ]] || continue
      source=$(cert_metadata_source "$metadata" "$directory")
      credential='-'
      if [[ "$source" != Remote\ * ]]; then
        domain="${row%%$'\t'*}"
        credential=$(cert_deployed_credential_label "$domain" "$directory/cert.pem" "$native_home") || credential='-'
      fi
      filtered+="$source"$'\t'"$row"$'\t'"$credential"$'\n'
    done <<<"$rows"
  done < <(
    printf '%s\t%s\n' "$CERT_DIR/meta.json" "$CERT_DIR"
    if [[ "$AGENT_TARGET_DIR/meta.json" != "$CERT_DIR/meta.json" ]]; then
      printf '%s\t%s\n' "$AGENT_TARGET_DIR/meta.json" "$AGENT_TARGET_DIR"
    fi
  )
  if [[ -n "$filtered" ]]; then
    local table
    printf -v table 'Source\tDomain\tKey type\tSAN domains\tCA\tIssued\tExpires\tDeployment directory\tDNS credential\n%s' "$filtered"
    ui_table "$table"
  else
    ui_hint 'No managed certificate metadata found'
  fi
}

cert_native_list_rows() {
  local native_home line domain key_type conf credential
  native_home=$(cert_native_home)
  while IFS= read -r line; do
    case "$line" in
      Main_Domain\|*) printf '%s|DNS credential\n' "$line";;
      *\|*)
        IFS='|' read -r domain key_type _ <<<"$line"
        credential='-'
        if [[ "$domain" =~ ^(\*\.)?[A-Za-z0-9.:_-]+$ && "$domain" != . && "$domain" != .. ]]; then
          conf=$(cert_native_conf "$domain" "${key_type//\"/}" "$native_home")
          credential=$(cert_dns_credential_label "$conf") || credential='-'
        fi
        printf '%s|%s\n' "$line" "$credential"
        ;;
      *) [[ -z "$line" ]] || printf '%s\n' "$line" >&2;;
    esac
  done <"$1" | tr '|' '\t'
}

cert_list() {
  local raw table native_available=0
  raw=$(mktemp "${TMPDIR:-/tmp}/acme-manager-list.XXXXXX") || return 1
  if acme_command >/dev/null 2>&1; then
    native_available=1
    printf '\n%sNative acme.sh certificates (local)%s\n' "$UI_ACCENT" "$UI_RESET"
    if run_acme --list --listraw >"$raw" 2>&1; then
      table=$(cert_native_list_rows "$raw")
      ui_table "$table"
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

cert_available_certificates() {
  local file domain metadata root rows row directory source
  if [[ -d "$ACME_HOME" ]]; then
    while IFS= read -r -d '' file; do
      domain=$(awk -F= '$1=="Le_Domain" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
      valid_domain "$domain" && printf 'Local acme.sh\t%s\t\n' "$domain"
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
      source=$(cert_metadata_source "$metadata" "$directory")
      valid_domain "$domain" && printf '%s\t%s\t%s\n' "$source" "$domain" "$directory"
    done <<<"$rows"
  done < <(
    printf '%s\t%s\n' "$CERT_DIR/meta.json" "$CERT_DIR"
    if [[ "$AGENT_TARGET_DIR/meta.json" != "$CERT_DIR/meta.json" ]]; then
      printf '%s\t%s\n' "$AGENT_TARGET_DIR/meta.json" "$AGENT_TARGET_DIR"
    fi
  )
}

cert_prompt_certificate() {
  local -a certificates=() options=()
  local certificate source domain directory selected index
  mapfile -t certificates < <(cert_available_certificates | sort -t $'\t' -k1,2 -u)
  if ((${#certificates[@]} == 0)); then
    domain=$(prompt_value 'Domain' '') || return 1
    printf 'Local acme.sh\t%s\t\n' "$domain"
    return
  fi
  options=("" 'Cancel')
  for index in "${!certificates[@]}"; do
    certificate="${certificates[index]}"
    IFS=$'\t' read -r source domain directory <<<"$certificate"
    options+=("$((index + 1))" "$domain [$source]")
  done
  selected=$(prompt_select 'Select a certificate to remove' '' "${options[@]}") || return 1
  [[ -n "$selected" ]] || return 0
  [[ "$selected" =~ ^[0-9]+$ && "$selected" -ge 1 && "$selected" -le "${#certificates[@]}" ]] || return 1
  printf '%s\n' "${certificates[selected-1]}"
}

cert_remove_remote_copy() {
  local domain="$1" directory="$2" source="$3"
  valid_domain "$domain" || { error "Invalid domain: $domain"; return 1; }
  [[ -n "$directory" && ( "$directory" == "$CERT_DIR/"* || "$directory" == "$AGENT_TARGET_DIR/"* ) ]] || {
    error "Refusing to remove an unsafe synchronized path: $directory"
    return 1
  }
  confirm "Remove the local copy of $domain from $directory? Source $source will remain and may return on the next sync" || {
    warn 'Cancelled'
    return 1
  }
  rm -rf -- "$directory"
  warn "Removed only the local synchronized copy of $domain; $source was not changed"
}

cert_remove_interactive() {
  local selection source domain directory revoke
  selection=$(cert_prompt_certificate) || { warn 'Cancelled'; return 1; }
  [[ -n "$selection" ]] || { warn 'Cancelled'; return 1; }
  IFS=$'\t' read -r source domain directory <<<"$selection"
  [[ -n "$domain" ]] || { warn 'Cancelled'; return 1; }
  if [[ "$source" == Remote\ * ]]; then
    cert_remove_remote_copy "$domain" "$directory" "$source"
    return
  fi
  revoke=$(prompt_select 'Also revoke the certificate at the CA?' false \
    false 'No' \
    true 'Yes') || return 1
  cert_remove "$domain" "$revoke"
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
  local all=0 force=0 interactive=0 domain='' key_type='' profile='' cf_only=0 conf binding provider current_profile hook
  local expected_provider='' selected_profile rc
  while (($#)); do
    case "$1" in
      --all) all=1; shift;;
      -d|--domain) require_arg "$@" || return 2; domain="$2"; shift 2;;
      --force) force=1; shift;;
      --key-type) require_arg "$@" || return 2; key_type="$2"; shift 2;;
      --dns) require_arg "$@" || return 2; expected_provider="$2"; shift 2;;
      --dns-profile|--cf-profile)
        require_arg "$@" || return 2
        if [[ "$1" == --cf-profile ]]; then cf_only=1; else cf_only=0; fi
        profile="$2"; shift 2;;
      --interactive) interactive=1; shift;;
      *) error "Unknown renew argument: $1"; return 2;;
    esac
  done
  if (( cf_only )); then
    [[ -z "$expected_provider" || "$expected_provider" == cloudflare ]] || {
      error '--cf-profile requires --dns cloudflare when --dns is specified'
      return 2
    }
    expected_provider=cloudflare
  fi
  if [[ -n "$expected_provider" ]] && ! valid_choice "$expected_provider" cloudflare dnspod aliyun; then
    error "Invalid DNS provider: $expected_provider"
    return 2
  fi
  local args=(--renew)
  if (( all )); then
    [[ -z "$profile" && -z "$expected_provider" ]] || {
      error '--dns and --dns-profile require a single --domain'
      return 2
    }
    args=(--renew-all)
  else
    valid_domain "$domain" || { error 'renew requires --domain, or use --all'; return 2; }
    args+=(--domain "$domain")
  fi
  case "$key_type" in
    ec-256) args+=(--ecc);;
    rsa-2048) args+=(--keylength 2048);;
    rsa-3072) args+=(--keylength 3072);;
    rsa-4096) args+=(--keylength 4096);;
    '') ;;
    *) error 'Invalid key type'; return 2;;
  esac
  if (( ! all )); then
    conf=$(cert_native_conf "$domain" "$key_type")
    if binding=$(cert_dns_binding "$conf"); then
      IFS=$'\t' read -r provider current_profile <<<"$binding"
      if [[ -n "$expected_provider" && "$provider" != "$expected_provider" ]]; then
        error "DNS provider mismatch for $domain: expected $expected_provider, configured $provider"
        return 2
      fi
      if (( interactive )) && [[ -z "$profile" ]]; then
        profile=$(dns_select_profile "$provider" "$current_profile") || return 1
      fi
      selected_profile="${profile:-$current_profile}"
      hook=$(dns_profile_hook "$provider" "$selected_profile") || return 1
      if [[ "$selected_profile" != "$current_profile" ]]; then
        cert_dns_bind "$conf" "$hook" || return 1
      fi
      info "Renewal DNS credential for $domain: $(dns_label "$provider") / $selected_profile"
    elif [[ -n "$profile" || -n "$expected_provider" ]]; then
      error "No supported DNS renewal record found for $domain"
      return 2
    fi
  fi
  (( force )) && args+=(--force)
  if run_acme_logged renew "${args[@]}"; then
    notify_event 'Renewal succeeded' "${domain:-all certificates}" 'The renewal command completed.' || true
    success 'Certificate renewal completed'
  else
    rc=$?
    # acme.sh reserves exit code 2 for RENEW_SKIP.
    if (( rc == 2 )) && { (( all )) || [[ -f "$conf" ]]; }; then
      info 'Certificate renewal skipped by acme.sh. See its output for the reason.'
      return 0
    fi
    error 'Certificate renewal failed; see the log'
    notify_event 'Renewal failed' "${domain:-all certificates}" "See $(_log_file)." || true
    return 1
  fi
}

cert_renew_interactive() {
  local domain mode
  local -a args=()
  domain=$(prompt_value 'Domain (leave empty to renew all)' '') || return 1
  mode=$(prompt_select 'Renewal mode' scheduled \
    scheduled 'Renew when due' \
    force 'Force renewal now' \
    cancel 'Cancel') || return 1
  [[ "$mode" != cancel ]] || return 0

  if [[ -n "$domain" ]]; then
    args=(--interactive --domain "$domain")
  else
    if [[ "$mode" == force ]]; then
      confirm 'Force renewal for all local acme.sh certificates?' || return 0
    fi
    args=(--all)
  fi
  [[ "$mode" != force ]] || args+=(--force)
  cert_renew "${args[@]}"
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
    ui_menu_item 4 'Renew certificate' 'Scheduled or forced renewal'
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
      4) cert_renew_interactive || true; pause_screen;;
      5) cert_expiry_check || true; pause_screen;;
      6)
        cert_remove_interactive || true
        pause_screen
        ;;
      0) return 0;; *) warn 'Invalid choice';;
    esac
  done
}
