#!/usr/bin/env bash

deploy_domain_dir() { printf '%s/%s\n' "$CERT_DIR" "$1"; }
deploy_validate_path() { valid_abs_path "$1" || { error "路径必须是绝对路径且不能包含换行: $1"; return 1; }; }

deploy_cert() {
  local domain="${1:-}" key_type="${2:-$DEFAULT_KEY_TYPE}" target_dir key_file fullchain_file ca_file cert_file reloadcmd
  [[ -n "$domain" ]] || { error '缺少域名'; return 1; }
  valid_domain "$domain" || { error "域名无效: $domain"; return 1; }
  case "$key_type" in ec-256) local key_args=(--ecc);; rsa-2048|rsa-3072|rsa-4096) local key_args=();; *) error '密钥类型无效'; return 1;; esac
  target_dir=$(prompt_value '部署目录' "$(deploy_domain_dir "$domain")")
  deploy_validate_path "$target_dir" || return 1
  key_file=$(prompt_value '私钥路径' "$target_dir/privkey.pem")
  fullchain_file=$(prompt_value 'Fullchain 路径' "$target_dir/fullchain.pem")
  ca_file=$(prompt_value 'CA 链路径' "$target_dir/ca.pem")
  cert_file=$(prompt_value '证书路径' "$target_dir/cert.pem")
  for path in "$key_file" "$fullchain_file" "$ca_file" "$cert_file"; do deploy_validate_path "$path" || return 1; done
  reloadcmd=$(prompt_value 'Reload Hook（例如 nginx -t && systemctl reload nginx；留空不执行）' '')
  [[ -n "$reloadcmd" ]] && ! confirm 'Reload Hook 将由 acme.sh 在续期后执行，确认使用该命令？' && reloadcmd=''
  mkdir -p "$target_dir"
  local args=(--install-cert -d "$domain" "${key_args[@]}" --key-file "$key_file" --fullchain-file "$fullchain_file" --ca-file "$ca_file" --cert-file "$cert_file")
  [[ -n "$reloadcmd" ]] && args+=(--reloadcmd "$reloadcmd")
  if ! run_acme_logged deploy "${args[@]}"; then
    error '证书部署失败，详见日志'
    notify_event '部署失败' "$domain" "目标目录=$target_dir。请查看 $(_log_file)。" || true
    return 1
  fi
  chmod 600 "$key_file" 2>/dev/null || true
  chmod 644 "$fullchain_file" "$ca_file" "$cert_file" 2>/dev/null || true
  notify_event '部署成功' "$domain" "目标目录=$target_dir" || true
  success "证书已部署到 $target_dir"
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
      *) error "未知 deploy 参数: $1"; return 2;;
    esac
  done
  valid_domain "$domain" || { error '缺少或无效域名'; return 2; }
  [[ -n "$target_dir" ]] || target_dir=$(deploy_domain_dir "$domain")
  valid_abs_path "$target_dir" || return 2
  [[ -n "$key_file" ]] || key_file="$target_dir/privkey.pem"
  [[ -n "$fullchain_file" ]] || fullchain_file="$target_dir/fullchain.pem"
  [[ -n "$ca_file" ]] || ca_file="$target_dir/ca.pem"
  [[ -n "$cert_file" ]] || cert_file="$target_dir/cert.pem"
  for path in "$key_file" "$fullchain_file" "$ca_file" "$cert_file"; do deploy_validate_path "$path" || return 2; done
  mkdir -p "$target_dir"
  args+=(--install-cert -d "$domain")
  case "$key_type" in ec-256) args+=(--ecc);; rsa-2048) args+=(--keylength 2048);; rsa-3072) args+=(--keylength 3072);; rsa-4096) args+=(--keylength 4096);; *) error 'key type 无效'; return 2;; esac
  args+=(--key-file "$key_file" --fullchain-file "$fullchain_file" --ca-file "$ca_file" --cert-file "$cert_file")
  [[ -n "$reloadcmd" ]] && args+=(--reloadcmd "$reloadcmd")
  if ! run_acme_logged deploy "${args[@]}"; then
    notify_event '部署失败' "$domain" "目标目录=$target_dir。请查看 $(_log_file)。" || true
    return 1
  fi
  chmod 600 "$key_file" 2>/dev/null || true
  chmod 644 "$fullchain_file" "$ca_file" "$cert_file" 2>/dev/null || true
  notify_event '部署成功' "$domain" "目标目录=$target_dir" || true
}
