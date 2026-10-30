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

cert_issue() {
  local provider="$DEFAULT_DNS" ca="$DEFAULT_CA" key_type="$DEFAULT_KEY_TYPE" email='' staging=0 domains=() domain value
  while (($#)); do
    case "$1" in
      -d|--domain) domains+=("$2"); shift 2;;
      --domains) IFS=',' read -r -a domains <<<"$2"; shift 2;;
      --dns) provider="$2"; shift 2;;
      --ca|--server) ca="$2"; shift 2;;
      --key-type) key_type="$2"; shift 2;;
      --email) email="$2"; shift 2;;
      --staging) staging=1; shift;;
      *) error "未知 issue 参数: $1"; return 2;;
    esac
  done
  if ((${#domains[@]} == 0)); then
    value=$(prompt_value '域名（可输入根域名或泛域名，多个域名用逗号分隔）') || return 1
    IFS=',' read -r -a domains <<<"$value"
  fi
  for domain in "${domains[@]}"; do
    domain="${domain## }"; domain="${domain%% }"
    valid_domain "$domain" || { error "域名无效: $domain"; return 1; }
  done
  valid_choice "$provider" cloudflare dnspod aliyun || { error 'DNS provider 无效'; return 1; }
  valid_choice "$ca" letsencrypt zerossl || { error 'CA 无效'; return 1; }
  valid_choice "$key_type" ec-256 rsa-2048 rsa-3072 rsa-4096 || { error '密钥类型无效'; return 1; }
  if [[ -z "$email" && -t 0 ]]; then
    email=$(prompt_value '账户邮箱（可选，已有账户可留空）' '')
  fi
  local args=(--issue --dns "$(dns_hook "$provider")" --server "$ca")
  for domain in "${domains[@]}"; do args+=(--domain "$domain"); done
  while IFS= read -r value; do args+=("$value"); done < <(cert_key_args "$key_type")
  (( staging )) && args+=(--staging)
  [[ -n "$email" ]] && args+=(--accountemail "$email")
  if ! run_acme_logged issue "${args[@]}"; then
    error '证书签发失败，详见日志'
    notify_event '签发失败' "${domains[*]}" "CA=$ca DNS=$provider。请查看 $(_log_file)。" || true
    return 1
  fi
  notify_event '签发成功' "${domains[*]}" "CA=$ca DNS=$provider KEY=$key_type" || true
  success "证书签发完成: ${domains[*]}"
}

cert_list() {
  run_acme --list || { error '无法读取证书列表'; return 1; }
  cert_deployment_summary
}
cert_info() { local domain="$1"; valid_domain "$domain" || return 1; run_acme --info --domain "$domain"; }

cert_deployment_summary() {
  local file domain cert key fullchain ca
  [[ -d "$ACME_HOME" ]] || return 0
  printf '\n部署路径（来自 acme.sh 证书配置）:\n'
  while IFS= read -r -d '' file; do
    domain=$(awk -F= '$1=="Le_Domain" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    [[ -n "$domain" ]] || continue
    cert=$(awk -F= '$1=="Le_RealCertPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    key=$(awk -F= '$1=="Le_RealKeyPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    fullchain=$(awk -F= '$1=="Le_RealFullChainPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    ca=$(awk -F= '$1=="Le_RealCACertPath" {gsub(/'\''|"/, "", $2); print $2; exit}' "$file")
    printf '  %-30s cert=%s key=%s fullchain=%s ca=%s\n' "$domain" "${cert:--}" "${key:--}" "${fullchain:--}" "${ca:--}"
  done < <(find "$ACME_HOME" -mindepth 2 -maxdepth 2 -type f -name '*.conf' -print0 2>/dev/null)
}

cert_renew() {
  local all=0 force=0 domain='' key_type=''
  while (($#)); do
    case "$1" in --all) all=1; shift;; -d|--domain) domain="$2"; shift 2;; --force) force=1; shift;; --key-type) key_type="$2"; shift 2;; *) error "未知 renew 参数: $1"; return 2;; esac
  done
  local args=(--renew)
  if (( all )); then args=(--renew-all); else valid_domain "$domain" || { error 'renew 需要 --domain，或使用 --all'; return 2; }; args+=(--domain "$domain"); fi
  case "$key_type" in
    ec-256) args+=(--ecc);;
    rsa-2048) args+=(--keylength 2048);;
    rsa-3072) args+=(--keylength 3072);;
    rsa-4096) args+=(--keylength 4096);;
    '') ;;
    *) error 'key type 无效'; return 2;;
  esac
  (( force )) && args+=(--force)
  if ! run_acme_logged renew "${args[@]}"; then
    error '续期失败，详见日志'
    notify_event '续期失败' "${domain:-全部证书}" "请查看 $(_log_file)。" || true
    return 1
  fi
  notify_event '续期成功' "${domain:-全部证书}" "续期命令已完成。" || true
  success '续期命令已完成'
}

cert_remove() {
  local domain="$1" revoke="${2:-false}"
  valid_domain "$domain" || { error '域名无效'; return 1; }
  confirm "确认删除 $domain 的本地管理记录？" || { warn '已取消'; return 1; }
  if [[ "$revoke" == true ]]; then
    confirm "确认向 CA 撤销 $domain 证书？此操作不可逆" || { warn '已取消'; return 1; }
    run_acme_logged revoke --revoke --domain "$domain" || { error '撤销失败'; return 1; }
  fi
  run_acme_logged remove --remove --domain "$domain" || { error '删除失败'; return 1; }
  success "已处理证书: $domain"
}

cert_expiry_check() {
  local days="${1:-$EXPIRY_DAYS}" file end rc=0
  [[ "$days" =~ ^[0-9]+$ ]] || return 2
  if ! command_exists openssl; then error '未找到 openssl'; return 1; fi
  if [[ ! -d "$CERT_DIR" ]]; then warn "证书目录不存在: $CERT_DIR"; return 0; fi
  while IFS= read -r -d '' file; do
    if openssl x509 -checkend "$((days * 86400))" -noout -in "$file" >/dev/null 2>&1; then
      printf '有效期充足: %s\n' "$file"
    else
      printf '即将过期或已过期: %s\n' "$file"
      rc=1
    fi
  done < <(find "$CERT_DIR" -type f \( -name '*.pem' -o -name '*.crt' \) -print0 2>/dev/null)
  return "$rc"
}

cert_menu() {
  while true; do
    menu_header '证书管理' '证书全生命周期操作'
    menu_home_status
    ui_section '操作'
    ui_menu_item 1 '申请 SSL 证书' '单域名 / 泛域名 / 多 SAN'
    ui_menu_item 2 '查看证书列表' '有效期、CA 和部署路径'
    ui_menu_item 3 '查看证书详情' '读取 acme.sh 原生信息'
    ui_menu_item 4 '手动续期' '单张证书或全部证书'
    ui_menu_item 5 '过期检查' "提前 ${EXPIRY_DAYS} 天提醒"
    ui_menu_item 6 '删除 / 撤销证书' '危险操作，需要二次确认'
    ui_menu_item 0 '返回上一级'
    ui_footer
    menu_choice '请选择操作 [0-6]:' || return 0
    local domain revoke
    case "$MENU_CHOICE" in
      1) cert_issue || true; pause_screen;;
      2) cert_list || true; pause_screen;;
      3) domain=$(prompt_value '域名'); cert_info "$domain" || true; pause_screen;;
      4) domain=$(prompt_value '域名（留空续期全部）' ''); if [[ -n "$domain" ]]; then cert_renew --domain "$domain" || true; else cert_renew --all || true; fi; pause_screen;;
      5) cert_expiry_check || true; pause_screen;;
      6) domain=$(prompt_value '域名'); revoke=$(prompt_value '同时撤销证书 (true/false)' 'false'); cert_remove "$domain" "$revoke" || true; pause_screen;;
      0) return 0;; *) warn '无效选择';;
    esac
  done
}
