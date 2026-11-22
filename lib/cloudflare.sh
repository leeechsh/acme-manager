#!/usr/bin/env bash

cf_valid_profile() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_]{0,47}$ && "$1" != legacy ]]
}

cf_profile_dir() { printf '%s/.acme-manager-cloudflare\n' "$ACME_HOME"; }

cf_profiles() {
  local file name
  for file in "$(cf_profile_dir)"/*; do
    [[ -f "$file" ]] || continue
    name=${file##*/}
    if cf_valid_profile "$name"; then printf '%s\n' "$name"; fi
  done
}

cf_has_legacy_token() {
  local value
  [[ -n "${CF_Token:-}" ]] && return 0
  value=$(account_get_var CF_Token || account_get_var SAVED_CF_Token) || return 1
  [[ -n "$value" ]]
}

cf_install_hook() {
  local profile="$1" hook="dns_amcf_$1" template
  template=$(cat "$SCRIPT_DIR/lib/cloudflare-hook.sh") || return 1
  {
    printf '%s\n' "$template"
    printf '\n%s_add() { _amcf_run %s add "$@"; }\n' "$hook" "$profile"
    printf '%s_rm() { _amcf_run %s rm "$@"; }\n' "$hook" "$profile"
  } | atomic_write "$ACME_HOME/dnsapi/$hook.sh" 600
}

cf_configure_profile() {
  local profile="$1" token account_id
  cf_valid_profile "$profile" || {
    error 'Use 1-48 lowercase letters, digits or underscores, starting with a letter or digit; legacy is reserved'
    return 1
  }
  token=$(prompt_value 'Cloudflare API token (empty cancels)') || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || { error 'Invalid or empty Cloudflare API token'; return 1; }
  account_id=$(prompt_value 'Cloudflare account ID (optional)') || return 1
  [[ "$account_id" =~ ^[A-Za-z0-9_-]*$ ]] || { error 'Invalid Cloudflare account ID'; return 1; }

  cf_install_hook "$profile" || return 1
  printf '%s\n%s\n' "$token" "$account_id" |
    atomic_write "$(cf_profile_dir)/$profile" 600 || return 1
  success "Cloudflare Token saved: $profile"
}

cf_select_profile() {
  local current="$1" mode="${2:-use}" profile selected
  local -a options=()
  while IFS= read -r profile; do
    options+=("$profile" "$profile")
  done < <(cf_profiles)
  if [[ -z "$current" ]]; then
    if cf_has_legacy_token; then
      current=legacy
    elif (( ${#options[@]} > 2 )); then
      current=__cancel
    else
      current=${options[0]:-__new}
    fi
  elif [[ "$current" != legacy && ! -s "$(cf_profile_dir)/$current" ]]; then
    current=__cancel
  fi
  options+=(legacy 'Legacy acme.sh credentials' __new 'Add a Cloudflare Token' __cancel 'Cancel')
  selected=$(prompt_select 'Select a Cloudflare Token' "$current" "${options[@]}") || return 1
  case "$selected" in
    __cancel) return 1;;
    __new)
      selected=$(prompt_value 'New Token name') || return 1
      if cf_valid_profile "$selected" && [[ -e "$(cf_profile_dir)/$selected" ]]; then
        error "Cloudflare Token already exists: $selected"
        return 1
      fi
      cf_configure_profile "$selected" >&2 || return 1
      ;;
    *)
      if [[ "$mode" == configure ]]; then
        if [[ "$selected" == legacy ]]; then
          dns_configure cloudflare >&2 || return 1
        else
          cf_configure_profile "$selected" >&2 || return 1
        fi
      fi
      ;;
  esac
  printf '%s\n' "$selected"
}

cf_profile_hook() {
  local profile="$1"
  if [[ "$profile" == legacy ]]; then
    printf 'dns_cf\n'
    return 0
  fi
  if ! cf_valid_profile "$profile" || [[ ! -s "$(cf_profile_dir)/$profile" ]]; then
    error "Cloudflare Token profile not found: $profile"
    return 1
  fi
  cf_install_hook "$profile" || return 1
  printf 'dns_amcf_%s\n' "$profile"
}
