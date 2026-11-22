#!/bin/sh

# The generated acme.sh hooks isolate dns_cf's global credential handling.
_amcf_run() (
  _amcf_profile=$1
  _amcf_action=$2
  shift 2
  unset CF_Token CF_Account_ID CF_Zone_ID CF_Key CF_Email
  if ! {
    IFS= read -r CF_Token && IFS= read -r CF_Account_ID
  } <"$LE_WORKING_DIR/.acme-manager-cloudflare/$_amcf_profile" || [ -z "$CF_Token" ]; then
    _err "Missing Cloudflare Token profile: $_amcf_profile"
    return 1
  fi
  CF_Zone_ID=
  CF_Key=
  CF_Email=
  _amcf_native=$(_findHook "" dnsapi dns_cf)
  if [ -z "$_amcf_native" ] || ! . "$_amcf_native"; then
    _err "Cannot load the native Cloudflare DNS hook"
    return 1
  fi
  # Prevent dns_cf from reading or overwriting unrelated native credentials.
  _readaccountconf_mutable() { :; }
  _saveaccountconf_mutable() { :; }
  _clearaccountconf_mutable() { :; }
  _clearaccountconf() { :; }
  "dns_cf_$_amcf_action" "$@"
)
