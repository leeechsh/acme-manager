#!/usr/bin/env bash

meta_file() { printf '%s/meta.json\n' "$CERT_DIR"; }

meta_conf_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v wanted="$key" '$1 == wanted {gsub(/'\''|"/, "", $2); print $2; exit}' "$file"
}

meta_json_value() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/}
  value=${value//$'\r'/}
  printf '%s' "$value"
}

meta_iso_date() {
  local value="$1"
  [[ -n "$value" ]] || return 0
  date -u -d "$value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$value"
}

meta_cert_entry() {
  local dir="$1" domain="$2" cert="$3" conf start end fingerprint key_type ca alt
  conf="$ACME_HOME/${domain}_ecc/${domain}.conf"
  [[ -f "$conf" ]] || conf="$ACME_HOME/${domain}/${domain}.conf"
  start=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | sed 's/^notBefore=//' || true)
  end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
  fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/^sha256 Fingerprint=//' | tr -d ':' || true)
  key_type=$(meta_conf_value "$conf" Le_Keylength)
  [[ -n "$key_type" ]] || { [[ "$dir" == *_ecc ]] && key_type='ec-256' || key_type='rsa-2048'; }
  ca=$(meta_conf_value "$conf" Le_API)
  case "$ca" in
    *zerossl*) ca='zerossl';;
    *letsencrypt*) ca='letsencrypt';;
    '') ca="$DEFAULT_CA";;
  esac
  alt=$(meta_conf_value "$conf" Le_Alt)
  printf '    {\n'
  printf '      "domain": "%s",\n' "$(meta_json_value "$domain")"
  printf '      "directory": "%s",\n' "$(meta_json_value "$domain")"
  printf '      "domains": ["%s"%s],\n' "$(meta_json_value "$domain")" "${alt:+, \"$(meta_json_value "$alt")\"}"
  printf '      "key_type": "%s",\n' "$(meta_json_value "$key_type")"
  printf '      "ca": "%s",\n' "$(meta_json_value "$ca")"
  printf '      "issued_at": "%s",\n' "$(meta_json_value "$(meta_iso_date "$start")")"
  printf '      "expires_at": "%s",\n' "$(meta_json_value "$(meta_iso_date "$end")")"
  printf '      "fingerprint_sha256": "%s",\n' "$(meta_json_value "$fingerprint")"
  printf '      "files": ["cert.pem", "privkey.pem", "fullchain.pem", "ca.pem", "%s.key", "%s.pem"]\n' \
    "$(meta_json_value "$domain")" "$(meta_json_value "$domain")"
  printf '    }'
}

meta_generate() {
  local output tmp dir domain cert first=1
  mkdir -p "$CERT_DIR"
  output=$(meta_file)
  tmp=$(mktemp "${output}.tmp.XXXXXX") || return 1
  {
    printf '{\n  "schema_version": 1,\n  "generated_at": "%s",\n  "certificates": [\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    while IFS= read -r -d '' dir; do
      cert="$dir/cert.pem"
      [[ -f "$cert" ]] || continue
      domain=$(basename "$dir")
      if (( first )); then first=0; else printf ',\n'; fi
      meta_cert_entry "$dir" "$domain" "$cert"
    done < <(find "$CERT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    printf '\n  ]\n}\n'
  } >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$output"
  printf '%s\n' "$output"
}

meta_sync() {
  local file
  file=$(meta_generate) || return 1
  if [[ "$WEBDAV_ENABLED" == true ]]; then
    webdav_sync "$file" || return 1
  fi
  success "Certificate metadata generated: $file"
}
