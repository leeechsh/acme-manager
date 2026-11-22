#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/acme-manager-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/fake-acme.sh"
cat >"$FAKE" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${FAKE_LOG:?}"
case " $* " in
  *' --version '*) echo 'https://github.com/acmesh-official/acme.sh 3.1.0';;
  *' --list '*)
    if [[ -n "${FAKE_NATIVE_LIST:-}" ]]; then
      cat "$FAKE_NATIVE_LIST"
    else
      printf '%s\n' 'Main_Domain|KeyLength|SAN_Domains|Profile|CA|Created|Renew' \
        'example.com|"ec-256"|*.example.com||LetsEncrypt.org||'
    fi
    ;;
  *' --renew '*|*' --renew-all '*)
    case "${FAKE_RENEW_RESULT:-ok}" in
      skip)
        if [[ " $* " != *' --force '* ]]; then
          echo 'Skipping. Next renewal time is: 2026-12-29T21:03:22Z'
          exit 2
        fi
        ;;
      fail) echo 'fake acme: validation failed' >&2; exit 1;;
    esac
    echo "fake acme: $*"
    ;;
  *)
    original_args="$*"
    if [[ " $* " == *' --remove '* ]] && [[ "${FAKE_REMOVE_FAIL:-0}" == 1 ]]; then
      echo 'fake acme: renewal record not found' >&2
      exit 1
    fi
    if [[ " $* " == *' --install-cert '* ]]; then
      reloadcmd=''
      while (($#)); do
        case "$1" in
          --key-file|--fullchain-file|--ca-file|--cert-file)
            mkdir -p "$(dirname "$2")"
            printf 'fake certificate file\n' >"$2"
            shift 2
            ;;
          --reloadcmd)
            reloadcmd="$2"
            shift 2
            ;;
          *) shift;;
        esac
      done
      [[ -z "$reloadcmd" ]] || bash -c "$reloadcmd"
    fi
    echo "fake acme: $original_args";;
esac
FAKE
chmod 700 "$FAKE"
mkdir -p "$TMP/bin"
FAKE_CURL="$TMP/bin/curl"
cat >"$FAKE_CURL" <<'FAKE_CURL'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:?}"
args=("$@")
output=''
url=''
for index in "${!args[@]}"; do
  if [[ "${args[index]}" == '-o' && $((index + 1)) -lt ${#args[@]} ]]; then
    output="${args[index+1]}"
  fi
done
url="${args[${#args[@]}-1]}"
if [[ -n "$output" && "$output" != /dev/null ]]; then
  if [[ "$url" == */meta.json && -n "${AGENT_REMOTE_META:-}" ]]; then
    cp "$AGENT_REMOTE_META" "$output"
  else
    printf 'fake remote file\n' >"$output"
  fi
fi
if [[ " $* " == *' -w '* ]]; then
  printf '201'
fi
FAKE_CURL
chmod 700 "$FAKE_CURL"
export FAKE_LOG="$TMP/acme.log"
export FAKE_CURL_LOG="$TMP/curl.log"
export PATH="$TMP/bin:$PATH"
export ACME_MANAGER_CONFIG="$TMP/config.conf"
export ACME_MANAGER_CERT_DIR="$TMP/certs"
export ACME_MANAGER_LOG_DIR="$TMP/log"
export ACME_HOME="$TMP/acme-home"
export ACME_SH_BIN="$FAKE"
export HOME="$TMP/home"
mkdir -p "$HOME"

assert() { "$@" || { echo "FAIL: $*" >&2; exit 1; }; }
assert_contains() { grep -Fq -- "$2" "$1" || { echo "FAIL: $2 not found in $1" >&2; cat "$1" >&2 || true; exit 1; }; }

bash -n "$ROOT/acme-manager.sh"
for file in "$ROOT"/lib/*.sh; do bash -n "$file"; done

"$ROOT/acme-manager.sh" config write
[[ -f "$ACME_MANAGER_CONFIG" ]]
[[ "$(stat -c '%a' "$ACME_MANAGER_CONFIG")" == 600 ]]
[[ "$("$ROOT/acme-manager.sh" version)" == "ACME Manager $(cat "$ROOT/VERSION")" ]]

cat >>"$ACME_MANAGER_CONFIG" <<'INJECT'
UNTRUSTED='touch /tmp/acme-manager-should-not-exist'
INJECT
rm -f /tmp/acme-manager-should-not-exist
"$ROOT/acme-manager.sh" config show >/dev/null
[[ ! -e /tmp/acme-manager-should-not-exist ]]

"$ROOT/acme-manager.sh" issue --domain example.com --domain '*.example.com' --dns cloudflare --ca letsencrypt --key-type ec-256 --staging
assert_contains "$FAKE_LOG" '--issue --dns dns_cf --server letsencrypt --domain example.com --domain *.example.com --keylength ec-256 --staging --home'

"$ROOT/acme-manager.sh" issue --domain single.example.com --dns cloudflare
assert_contains "$FAKE_LOG" '--issue --dns dns_cf --server letsencrypt --domain single.example.com --domain *.single.example.com --keylength ec-256 --home'

"$ROOT/acme-manager.sh" issue --domain root-only.example.com --no-wildcard --dns cloudflare
assert_contains "$FAKE_LOG" '--issue --dns dns_cf --server letsencrypt --domain root-only.example.com --keylength ec-256 --home'

mkdir -p "$ACME_HOME/retry.example.com_ecc"
: >"$ACME_HOME/retry.example.com_ecc/retry.example.com.key"
"$ROOT/acme-manager.sh" issue --domain retry.example.com --dns dnspod
assert_contains "$FAKE_LOG" '--issue --dns dns_tencent --server letsencrypt --domain retry.example.com --domain *.retry.example.com --keylength ec-256 --force --home'

"$ROOT/acme-manager.sh" renew --domain example.com --force --key-type ec-256
assert_contains "$FAKE_LOG" '--renew --domain example.com --ecc --force --home'

mkdir -p "$ACME_HOME/scheduled.example.com_ecc"
printf "Le_Webroot='dns_cf'\n" >"$ACME_HOME/scheduled.example.com_ecc/scheduled.example.com.conf"
FAKE_RENEW_RESULT=skip "$ROOT/acme-manager.sh" renew --domain scheduled.example.com >"$TMP/renew-skip.txt" 2>&1
assert_contains "$TMP/renew-skip.txt" 'Certificate renewal skipped by acme.sh'
FAKE_RENEW_RESULT=skip "$ROOT/acme-manager.sh" renew --all >"$TMP/renew-all-skip.txt" 2>&1
assert_contains "$TMP/renew-all-skip.txt" 'Certificate renewal skipped by acme.sh'
if grep -Eq 'Renewal failed|Certificate renewal failed|Certificate renewal completed' "$TMP"/renew*-skip.txt; then
  echo 'FAIL: skipped renewal reported as a failure or renewal' >&2
  exit 1
fi
if FAKE_RENEW_RESULT=fail "$ROOT/acme-manager.sh" renew --domain scheduled.example.com >"$TMP/renew-fail.txt" 2>&1; then
  echo 'FAIL: validation failure should return an error' >&2
  exit 1
fi
assert_contains "$TMP/renew-fail.txt" 'Certificate renewal failed'
if FAKE_RENEW_RESULT=skip "$ROOT/acme-manager.sh" renew --domain not-issued.example.com >/dev/null 2>&1; then
  echo 'FAIL: missing renewal record should return an error' >&2
  exit 1
fi

printf 'account data\n' >"$ACME_HOME/account.conf"
mkdir -p "$ACME_HOME/remove.example.com_ecc" "$ACME_HOME/remove.example.com"
: >"$ACME_HOME/remove.example.com_ecc/remove.example.com.key"
: >"$ACME_HOME/remove.example.com/remove.example.com.key"
printf 'y\n' | "$ROOT/acme-manager.sh" remove --domain remove.example.com >/dev/null
[[ ! -e "$ACME_HOME/remove.example.com_ecc" ]]
[[ ! -e "$ACME_HOME/remove.example.com" ]]
[[ -f "$ACME_HOME/account.conf" ]]

mkdir -p "$ACME_HOME/stale.example.com_ecc"
: >"$ACME_HOME/stale.example.com_ecc/stale.example.com.key"
if FAKE_REMOVE_FAIL=1 "$ROOT/acme-manager.sh" remove --domain stale.example.com >/dev/null 2>&1 <<'INPUT'
y
INPUT
then
  echo 'FAIL: removal should report the acme.sh record error' >&2
  exit 1
fi
[[ ! -e "$ACME_HOME/stale.example.com_ecc" ]]

printf '1\ninteractive.example.com\n1\n1\n1\n1\n\n\n\n\n\n\n0\n' |
  "$ROOT/acme-manager.sh" menu >/dev/null
assert_contains "$FAKE_LOG" '--issue --dns dns_cf --server letsencrypt --domain interactive.example.com --domain *.interactive.example.com --keylength ec-256 --home'
assert_contains "$FAKE_LOG" '--install-cert -d interactive.example.com --ecc --key-file'
[[ -f "$TMP/certs/interactive.example.com/interactive.example.com.key" ]]
[[ -f "$TMP/certs/meta.json" ]]
grep -Fq '"domain": "interactive.example.com"' "$TMP/certs/meta.json"

"$ROOT/acme-manager.sh" deploy --domain example.com --target-dir "$TMP/certs/example.com" --reloadcmd 'true'
assert_contains "$FAKE_LOG" '--install-cert -d example.com --ecc --key-file'
assert_contains "$FAKE_LOG" 'example.com.key'
assert_contains "$FAKE_LOG" 'example.com.pem'
[[ -f "$TMP/certs/example.com/example.com.key" ]]
[[ -f "$TMP/certs/example.com/example.com.pem" ]]
cmp "$TMP/certs/example.com/privkey.pem" "$TMP/certs/example.com/example.com.key"
cmp "$TMP/certs/example.com/fullchain.pem" "$TMP/certs/example.com/example.com.pem"

cat >>"$ACME_MANAGER_CONFIG" <<'INJECT_WEBDAV'
WEBDAV_ENABLED="true"
WEBDAV_URL="https://dav.example.test/acme"
WEBDAV_USERNAME="sync-user"
WEBDAV_PASSWORD="sync#secret" # inline comments remain safe
AGENT_TARGET_DIR="__AGENT_TARGET_DIR__"
AGENT_LOG="__AGENT_LOG__"
INJECT_WEBDAV
sed -i "s#__AGENT_TARGET_DIR__#$TMP/agent-certs#; s#__AGENT_LOG__#$TMP/agent.log#" "$ACME_MANAGER_CONFIG"
rm -f "$ACME_HOME/account.conf"
"$ROOT/acme-manager.sh" webdav sync >/dev/null
assert_contains "$FAKE_CURL_LOG" 'meta.json'
assert_contains "$FAKE_CURL_LOG" 'interactive.example.com/cert.pem'
! grep -Fq 'sync#secret' "$FAKE_CURL_LOG"
[[ ! -e "$ACME_HOME/account.conf" ]]
grep -Fq '"revision": 1' "$TMP/certs/meta.json"

printf 'WEBDAV_SYNC_MODE="download"\n' >>"$ACME_MANAGER_CONFIG"
AGENT_REMOTE_META="$TMP/certs/meta.json" "$ROOT/acme-manager.sh" agent sync >/dev/null
[[ -f "$TMP/agent-certs/meta.json" ]]
[[ -f "$TMP/agent-certs/interactive.example.com/fullchain.pem" ]]
ACME_MANAGER_CERT_DIR="$TMP/agent-certs" "$ROOT/acme-manager.sh" list >"$TMP/agent-list.txt"
assert_contains "$TMP/agent-list.txt" 'interactive.example.com'
assert_contains "$TMP/agent-list.txt" "$TMP/agent-certs/interactive.example.com"
REMOTE_NODE_ID=$(awk -F'"' '/"node_id"[[:space:]]*:/ {print $4; exit}' "$TMP/agent-certs/meta.json")
assert_contains "$TMP/agent-list.txt" "Remote $REMOTE_NODE_ID"
assert_contains "$TMP/agent-list.txt" "$TMP/agent-certs/interactive.example.com/cert.pem"
env -u ACME_SH_BIN ACME_MANAGER_CERT_DIR="$TMP/agent-certs" "$ROOT/acme-manager.sh" list >"$TMP/agent-list-no-acme.txt"
assert_contains "$TMP/agent-list-no-acme.txt" 'interactive.example.com'
assert_contains "$TMP/agent-list-no-acme.txt" "Remote $REMOTE_NODE_ID"
assert_contains "$TMP/agent-list-no-acme.txt" "$TMP/agent-certs/interactive.example.com/fullchain.pem"
mkdir -p "$ACME_HOME/interactive.example.com_ecc"
cat >"$ACME_HOME/interactive.example.com_ecc/interactive.example.com.conf" <<'EOF_NATIVE_RECORD'
Le_Domain='interactive.example.com'
EOF_NATIVE_RECORD
sed -i 's/"node_id": "[^"]*"/"node_id": "remote-dc9"/' "$TMP/agent-certs/meta.json"
ACME_MANAGER_CERT_DIR="$TMP/agent-certs" "$ROOT/acme-manager.sh" list >"$TMP/agent-list-duplicate.txt"
assert_contains "$TMP/agent-list-duplicate.txt" 'Remote remote-dc9'
assert_contains "$TMP/agent-list-duplicate.txt" 'interactive.example.com [Remote remote-dc9]'
assert_contains "$TMP/agent-list-duplicate.txt" 'interactive.example.com [Local acme.sh]'
cat >>"$ACME_MANAGER_CONFIG" <<EOF_BIDIRECTIONAL
WEBDAV_SYNC_MODE="bidirectional"
AGENT_TARGET_DIR="$TMP/certs"
EOF_BIDIRECTIONAL
AGENT_REMOTE_META="$TMP/certs/meta.json" "$ROOT/acme-manager.sh" agent sync >/dev/null
grep -Fq '"revision": 2' "$TMP/certs/meta.json"
printf '11\n0\n0\n' | "$ROOT/acme-manager.sh" menu >/dev/null

cat >>"$ACME_MANAGER_CONFIG" <<EOF_CONFLICT
WEBDAV_SYNC_MODE="download"
AGENT_TARGET_DIR="$TMP/conflict-certs"
EOF_CONFLICT
mkdir -p "$TMP/conflict-certs/example.com"
cat >"$TMP/conflict-certs/meta.json" <<'EOF_LOCAL_META'
{
  "schema_version": 2,
  "revision": 7,
  "node_id": "local",
  "certificates": [
    {
      "domain": "example.com",
      "directory": "example.com",
      "fingerprint_sha256": "local"
    }
  ]
}
EOF_LOCAL_META
cat >"$TMP/remote-conflict-meta.json" <<'EOF_REMOTE_META'
{
  "schema_version": 2,
  "revision": 7,
  "node_id": "remote",
  "certificates": [
    {
      "domain": "example.com",
      "directory": "example.com",
      "fingerprint_sha256": "remote"
    }
  ]
}
EOF_REMOTE_META
if AGENT_REMOTE_META="$TMP/remote-conflict-meta.json" "$ROOT/acme-manager.sh" agent sync >/dev/null 2>&1; then
  echo 'FAIL: same-revision certificate conflict should stop synchronization' >&2
  exit 1
fi

"$ROOT/acme-manager.sh" dns configure cloudflare <<'INPUT'
token-value

INPUT
assert_contains "$ACME_HOME/account.conf" "export CF_Token='token-value'"
[[ "$(stat -c '%a' "$ACME_HOME/account.conf")" == 600 ]]
! grep -Fq token-value "$ACME_MANAGER_CONFIG"

# Add a profile from the issue prompt, then select a second profile by name.
printf 'work.example.com\n1\n1\n1\n2\nwork\nwork-test-token\nwork-account\n' |
  "$ROOT/acme-manager.sh" issue --interactive >/dev/null
assert_contains "$FAKE_LOG" '--issue --dns dns_amcf_work --server letsencrypt --domain work.example.com'
"$ROOT/acme-manager.sh" dns configure cloudflare personal <<'INPUT'
personal-test-token

INPUT
"$ROOT/acme-manager.sh" issue --domain personal.example.com --dns cloudflare --cf-profile personal >/dev/null
assert_contains "$FAKE_LOG" '--issue --dns dns_amcf_personal --server letsencrypt --domain personal.example.com'
[[ "$(stat -c '%a' "$ACME_HOME/.acme-manager-cloudflare/work")" == 600 ]]
"$ROOT/acme-manager.sh" dns status cloudflare >"$TMP/cf-status.txt"
assert_contains "$TMP/cf-status.txt" 'Profile: work'
assert_contains "$TMP/cf-status.txt" 'Profile: personal'

WORK_CONF="$ACME_HOME/work.example.com_ecc/work.example.com.conf"
mkdir -p "$(dirname "$WORK_CONF")"
cat >"$WORK_CONF" <<'CONF'
Le_Domain='work.example.com'
Le_Webroot='dns_cf'
Le_RealFullChainPath='/var/cert/work.example.com/fullchain.pem'
CONF
"$ROOT/acme-manager.sh" renew --domain work.example.com --key-type ec-256 --cf-profile work >/dev/null
assert_contains "$WORK_CONF" "Le_Webroot='dns_amcf_work'"
assert_contains "$WORK_CONF" "Le_RealFullChainPath='/var/cert/work.example.com/fullchain.pem'"
printf '3\nwork.example.com\n\n1\n0\n' | "$ROOT/acme-manager.sh" menu >/dev/null
assert_contains "$WORK_CONF" "Le_Webroot='dns_amcf_personal'"
assert_contains "$FAKE_LOG" '--renew --domain work.example.com --home'
printf '3\nwork.example.com\n2\n\n0\n' |
  FAKE_RENEW_RESULT=skip "$ROOT/acme-manager.sh" menu >"$TMP/force-menu.txt" 2>&1
assert_contains "$TMP/force-menu.txt" 'Force renewal now'
assert_contains "$FAKE_LOG" '--renew --domain work.example.com --force --home'
cp "$FAKE_LOG" "$TMP/acme-before-force-all"
printf '3\n\n2\nn\n0\n' | "$ROOT/acme-manager.sh" menu >/dev/null 2>&1
cmp "$TMP/acme-before-force-all" "$FAKE_LOG"
printf '3\n\n2\ny\n0\n' | "$ROOT/acme-manager.sh" menu >/dev/null 2>&1
assert_contains "$FAKE_LOG" '--renew-all --force --home'
if "$ROOT/acme-manager.sh" renew --domain work.example.com --cf-profile missing >/dev/null 2>&1; then
  echo 'FAIL: unknown Cloudflare Token profile was accepted' >&2
  exit 1
fi
assert_contains "$WORK_CONF" "Le_Webroot='dns_amcf_personal'"
"$ROOT/acme-manager.sh" renew --all >/dev/null
assert_contains "$FAKE_LOG" '--renew-all --home'

# Exercise both generated hooks with the POSIX shell used by native acme.sh.
cat >"$TMP/fake-dns-cf.sh" <<'DNS_CF'
dns_cf_add() {
  [ "$CF_Token" = "$1" ] && [ "$CF_Account_ID" = "$2" ] &&
    [ -z "$CF_Zone_ID$CF_Key$CF_Email" ] &&
    [ -z "$(_readaccountconf_mutable CF_Account_ID)" ] &&
    _saveaccountconf_mutable CF_Token "$CF_Token" &&
    _clearaccountconf_mutable CF_Zone_ID && _clearaccountconf CF_Zone_ID
}
dns_cf_rm() { dns_cf_add "$@"; }
DNS_CF
sh -eu -s "$ACME_HOME" "$TMP/fake-dns-cf.sh" <<'HOOK_TEST'
LE_WORKING_DIR=$1
native_hook=$2
_findHook() { printf '%s\n' "$native_hook"; }
_err() { printf '%s\n' "$*" >&2; }
_readaccountconf_mutable() { printf 'legacy-account\n'; }
_saveaccountconf_mutable() { return 1; }
_clearaccountconf_mutable() { return 1; }
_clearaccountconf() { return 1; }
CF_Token=legacy-token
CF_Account_ID=legacy-account
CF_Zone_ID=legacy-zone
CF_Key=legacy-key
CF_Email=legacy-email
. "$LE_WORKING_DIR/dnsapi/dns_amcf_work.sh"
. "$LE_WORKING_DIR/dnsapi/dns_amcf_personal.sh"
dns_amcf_work_add work-test-token work-account
dns_amcf_work_rm work-test-token work-account
dns_amcf_personal_add personal-test-token ''
dns_amcf_personal_rm personal-test-token ''
[ "$CF_Token" = legacy-token ] && [ "$CF_Account_ID" = legacy-account ]
HOOK_TEST
assert_contains "$ACME_HOME/account.conf" "export CF_Token='token-value'"
if grep -rEq 'work-test-token|personal-test-token' "$FAKE_LOG" "$ACME_MANAGER_LOG_DIR" "$ACME_MANAGER_CONFIG"; then
  echo 'FAIL: named Cloudflare Token leaked to logs or manager config' >&2
  exit 1
fi

printf '6\n1\n1\n2\nstage\nstage-test-token\n\n0\n0\n0\n' |
  "$ROOT/acme-manager.sh" menu >"$TMP/cf-add-menu.txt" 2>&1
assert_contains "$TMP/cf-add-menu.txt" 'Cloudflare Manage DNS credentials'
assert_contains "$TMP/cf-add-menu.txt" 'Profile: work'
assert_contains "$TMP/cf-add-menu.txt" 'Profile: personal'
[[ -s "$ACME_HOME/.acme-manager-cloudflare/stage" ]]

printf '6\n1\n3\n3\nstage-rotated-token\n\n0\n0\n0\n' |
  "$ROOT/acme-manager.sh" menu >"$TMP/cf-update-menu.txt" 2>&1
assert_contains "$TMP/cf-update-menu.txt" 'Cloudflare profile saved: stage'
[[ "$(head -n 1 "$ACME_HOME/.acme-manager-cloudflare/stage")" == stage-rotated-token ]]

printf '6\n1\n4\n2\n4\n3\ny\n0\n0\n0\n' |
  "$ROOT/acme-manager.sh" menu >"$TMP/cf-remove-menu.txt" 2>&1
assert_contains "$TMP/cf-remove-menu.txt" 'DNS profile is used by a certificate: personal'
assert_contains "$TMP/cf-remove-menu.txt" 'work.example.com_ecc/work.example.com.conf'
assert_contains "$TMP/cf-remove-menu.txt" 'Cloudflare profile removed: stage'
[[ -s "$ACME_HOME/.acme-manager-cloudflare/personal" ]]
[[ ! -e "$ACME_HOME/.acme-manager-cloudflare/stage" ]]
[[ ! -e "$ACME_HOME/dnsapi/dns_amcf_stage.sh" ]]

IMPORT_HOME="$TMP/import-cf-home"
mkdir -p "$IMPORT_HOME"
cat >"$IMPORT_HOME/account.conf" <<'LEGACY_CF'
CF_Token=''
SAVED_CF_Token='legacy-import-test-token'
SAVED_CF_Account_ID='legacy-import-account'
LEGACY_CF
cp "$IMPORT_HOME/account.conf" "$TMP/account-before-import"
printf '6\n1\n1\n6\noffice\n1\n6\noffice\n0\n0\n0\n' |
  env -u CF_Token -u CF_Account_ID ACME_HOME="$IMPORT_HOME" "$ROOT/acme-manager.sh" menu >"$TMP/cf-import-menu.txt" 2>&1
assert_contains "$TMP/cf-import-menu.txt" 'None. Choose Add profile or Import legacy credentials'
assert_contains "$TMP/cf-import-menu.txt" 'Profile: office'
assert_contains "$TMP/cf-import-menu.txt" 'DNS profile already exists: office'
[[ "$(cat "$IMPORT_HOME/.acme-manager-cloudflare/office")" == $'legacy-import-test-token\nlegacy-import-account' ]]
[[ "$(stat -c '%a' "$IMPORT_HOME/.acme-manager-cloudflare/office")" == 600 ]]
[[ -f "$IMPORT_HOME/dnsapi/dns_amcf_office.sh" ]]
cmp "$TMP/account-before-import" "$IMPORT_HOME/account.conf"
if grep -q 'legacy-import-test-token' "$TMP/cf-import-menu.txt"; then
  echo 'FAIL: imported Cloudflare Token was displayed' >&2
  exit 1
fi

# The same profile name can be used independently for different DNS providers.
printf '6\n2\n2\nshared\ndp-id\ndp-test-secret\n\ndp-region\n1\n0\n0\n0\n' |
  "$ROOT/acme-manager.sh" menu >"$TMP/dp-profile-menu.txt" 2>&1
assert_contains "$TMP/dp-profile-menu.txt" 'Tencent DNSPod profile saved: shared'
assert_contains "$TMP/dp-profile-menu.txt" 'Profile: shared'
"$ROOT/acme-manager.sh" dns configure aliyun shared <<'ALI'
ali-id
ali-test-secret

ALI
"$ROOT/acme-manager.sh" dns configure cloudflare shared <<'CF'
cf-shared-test-token

CF
printf '6\n3\n6\nprevious\n0\n0\n0\n' |
  Ali_Key=ali-old-id Ali_Secret=ali-old-secret "$ROOT/acme-manager.sh" menu >"$TMP/ali-import-menu.txt" 2>&1
assert_contains "$TMP/ali-import-menu.txt" 'Alibaba Cloud DNS profile saved: previous'

"$ROOT/acme-manager.sh" issue --domain dp.example.com --dns dnspod --dns-profile shared >/dev/null
assert_contains "$FAKE_LOG" '--issue --dns dns_amdp_shared --server letsencrypt --domain dp.example.com'
printf 'ali.example.com\n3\n1\n1\n2\n' | "$ROOT/acme-manager.sh" issue --interactive >/dev/null
assert_contains "$FAKE_LOG" '--issue --dns dns_amali_shared --server letsencrypt --domain ali.example.com'

mkdir -p "$ACME_HOME/dp.example.com_ecc" "$ACME_HOME/ali.example.com_ecc"
DP_CONF="$ACME_HOME/dp.example.com_ecc/dp.example.com.conf"
ALI_CONF="$ACME_HOME/ali.example.com_ecc/ali.example.com.conf"
printf "Le_Webroot='dns_tencent'\n" >"$DP_CONF"
printf "Le_Webroot='dns_amali_shared'\n" >"$ALI_CONF"
"$ROOT/acme-manager.sh" renew --domain dp.example.com --dns-profile shared >"$TMP/dp-renew-profile"
assert_contains "$DP_CONF" "Le_Webroot='dns_amdp_shared'"
assert_contains "$TMP/dp-renew-profile" 'Tencent DNSPod / shared'
"$ROOT/acme-manager.sh" renew --domain dp.example.com --dns dnspod --dns-profile shared >/dev/null
cp "$FAKE_LOG" "$TMP/acme-before-provider-check"
if "$ROOT/acme-manager.sh" renew --domain dp.example.com --dns cloudflare --dns-profile shared >"$TMP/provider-mismatch" 2>&1; then
  echo 'FAIL: renewal accepted a mismatched DNS provider' >&2
  exit 1
fi
assert_contains "$TMP/provider-mismatch" 'expected cloudflare, configured dnspod'
if "$ROOT/acme-manager.sh" renew --domain dp.example.com --dns-profile previous >"$TMP/provider-no-fallback" 2>&1; then
  echo 'FAIL: renewal reused a profile from a different DNS provider' >&2
  exit 1
fi
assert_contains "$TMP/provider-no-fallback" 'Tencent DNSPod profile not found: previous'
assert_contains "$DP_CONF" "Le_Webroot='dns_amdp_shared'"
cmp "$TMP/acme-before-provider-check" "$FAKE_LOG"
printf '3\nali.example.com\n\n1\n0\n' | "$ROOT/acme-manager.sh" menu >/dev/null
assert_contains "$ALI_CONF" "Le_Webroot='dns_amali_previous'"

cat >"$TMP/dns_tencent.sh" <<'DNS_TENCENT'
dns_tencent_add() {
  [ "$Tencent_SecretId" = dp-id ] && [ "$Tencent_SecretKey" = dp-test-secret ] &&
    [ -z "$Tencent_SessionToken" ] && [ "$Tencent_Region" = dp-region ] &&
    [ -z "$(_readaccountconf_mutable Tencent_SecretKey)" ] &&
    _saveaccountconf_mutable Tencent_SecretKey "$Tencent_SecretKey"
}
dns_tencent_rm() { dns_tencent_add "$@"; }
DNS_TENCENT
cat >"$TMP/dns_ali.sh" <<'DNS_ALI'
dns_ali_add() {
  [ "$Ali_Key" = ali-id ] && [ "$Ali_Secret" = ali-test-secret ] && [ -z "$Ali_SecurityToken" ] &&
    [ -z "$(_readaccountconf_mutable Ali_Secret)" ] &&
    _saveaccountconf_mutable Ali_Secret "$Ali_Secret"
}
dns_ali_rm() { dns_ali_add "$@"; }
DNS_ALI
sh -eu -s "$ACME_HOME" "$TMP" <<'HOOK_TEST'
LE_WORKING_DIR=$1
native_hooks=$2
_findHook() { printf '%s/%s.sh\n' "$native_hooks" "$3"; }
_err() { printf '%s\n' "$*" >&2; }
_readaccountconf_mutable() { printf 'legacy-credential\n'; }
_saveaccountconf_mutable() { return 1; }
export Tencent_SessionToken=legacy-session Ali_SecurityToken=legacy-security
. "$LE_WORKING_DIR/dnsapi/dns_amdp_shared.sh"
. "$LE_WORKING_DIR/dnsapi/dns_amali_shared.sh"
dns_amdp_shared_add
dns_amdp_shared_rm
dns_amali_shared_add
dns_amali_shared_rm
[ "$Tencent_SessionToken" = legacy-session ] && [ "$Ali_SecurityToken" = legacy-security ]
HOOK_TEST
if grep -rEq 'cf-shared-test-token|dp-test-secret|ali-test-secret|ali-old-secret' "$FAKE_LOG" "$ACME_MANAGER_LOG_DIR" "$ACME_MANAGER_CONFIG"; then
  echo 'FAIL: named DNS credentials leaked to logs or manager config' >&2
  exit 1
fi

LIST_ACME="$TMP/list-acme"
LIST_LOCAL="$TMP/list-local"
LIST_REMOTE="$TMP/list-remote"
LIST_CONFIG="$TMP/list-config"
mkdir -p "$LIST_ACME/example.com" "$LIST_ACME/example.com_ecc" "$LIST_ACME/dp.example.com_ecc" \
  "$LIST_LOCAL/example.com" "$LIST_LOCAL/dp.example.com" "$LIST_REMOTE/example.com"
cat >"$LIST_CONFIG" <<CONF
AGENT_TARGET_DIR="$LIST_REMOTE"
WEBDAV_NODE_ID="list-host"
CONF
printf "Le_Domain='example.com'\nLe_Webroot='dns_cf'\n" >"$LIST_ACME/example.com/example.com.conf"
printf "Le_Domain='example.com'\nLe_Webroot='dns_amcf_leeechsh'\n" >"$LIST_ACME/example.com_ecc/example.com.conf"
printf "Le_Domain='dp.example.com'\nLe_Webroot='dns_tencent'\n" >"$LIST_ACME/dp.example.com_ecc/dp.example.com.conf"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -subj '/CN=example.com' -days 1 -keyout "$TMP/list.key" \
  -out "$LIST_ACME/example.com_ecc/example.com.cer" 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -subj '/CN=dp.example.com' -days 1 -keyout "$TMP/list-dp.key" \
  -out "$LIST_ACME/dp.example.com_ecc/dp.example.com.cer" 2>/dev/null
cp "$LIST_ACME/example.com_ecc/example.com.cer" "$LIST_LOCAL/example.com/cert.pem"
cp "$LIST_LOCAL/example.com/cert.pem" "$LIST_LOCAL/dp.example.com/cert.pem"
cp "$LIST_LOCAL/example.com/cert.pem" "$LIST_REMOTE/example.com/cert.pem"
ACME_MANAGER_CONFIG="$LIST_CONFIG" ACME_MANAGER_CERT_DIR="$LIST_LOCAL" ACME_HOME="$LIST_ACME" \
  "$ROOT/acme-manager.sh" meta sync >/dev/null
sed 's/"node_id": "list-host"/"node_id": "other-host"/' "$LIST_LOCAL/meta.json" >"$LIST_REMOTE/meta.json"
sed -i 's/"expires_at": "[^"]*"/"expires_at": ""/' "$LIST_LOCAL/meta.json"

cat >"$TMP/list-raw" <<'LIST'
Main_Domain|KeyLength|SAN_Domains|Profile|CA|Created|Renew
example.com|"ec-256"|*.example.com||LetsEncrypt.org|2026-01-01|2026-03-01
example.com|"2048"|*.example.com|shortlived|LetsEncrypt.org|2026-01-01|2026-01-04
dp.example.com|"ec-256"|*.dp.example.com||LetsEncrypt.org|2026-01-01|2026-03-01
LIST
printf '#!/bin/sh\nexit 93\n' >"$TMP/bin/column"
chmod 700 "$TMP/bin/column"
printf '2\n0\n' | FAKE_NATIVE_LIST="$TMP/list-raw" ACME_MANAGER_CONFIG="$LIST_CONFIG" \
  ACME_MANAGER_CERT_DIR="$LIST_LOCAL" ACME_HOME="$LIST_ACME" \
  "$ROOT/acme-manager.sh" menu >"$TMP/list-credentials"
assert_contains "$TMP/list-credentials" 'DNS credential'
assert grep -Eq '^example\.com[[:space:]].*"ec-256".*Cloudflare / leeechsh[[:space:]]*$' "$TMP/list-credentials"
assert grep -Eq '^example\.com[[:space:]].*"2048".*Cloudflare / legacy[[:space:]]*$' "$TMP/list-credentials"
assert grep -Eq '^dp\.example\.com[[:space:]].*Tencent DNSPod / legacy[[:space:]]*$' "$TMP/list-credentials"
assert grep -Eq '^Local acme\.sh[[:space:]]+example\.com[[:space:]].*Cloudflare / leeechsh[[:space:]]*$' "$TMP/list-credentials"
assert grep -Eq '^Local acme\.sh[[:space:]]+dp\.example\.com[[:space:]].*[[:space:]]-[[:space:]]*$' "$TMP/list-credentials"
assert grep -Eq '^Remote other-host[[:space:]]+example\.com[[:space:]].*[[:space:]]-[[:space:]]*$' "$TMP/list-credentials"
assert awk '
  $1 == "Main_Domain" { profile = index($0, "Profile"); native = index($0, "DNS credential") }
  $1 == "example.com" && /"ec-256"/ {
    if (index($0, "Cloudflare /") != native || substr($0, profile, 1) != "-") bad = 1
    native_rows++
  }
  $1 == "example.com" && /"2048"/ {
    if (index($0, "Cloudflare /") != native || index($0, "shortlived") != profile) bad = 1
    native_rows++
  }
  $1 == "Source" && $2 == "Domain" {
    expires = index($0, "Expires")
    directory = index($0, "Deployment directory")
    managed = index($0, "DNS credential")
  }
  /^Local acme.sh +example.com / {
    if (substr($0, expires, 1) != "-" || index($0, "/list-local/example.com") == 0 ||
        substr($0, directory, 1) != "/" || index($0, "Cloudflare /") != managed) bad = 1
    managed_rows++
  }
  /^Remote other-host +example.com / {
    if (substr($0, directory, 1) != "/" || substr($0, managed, 1) != "-") bad = 1
    managed_rows++
  }
  END { exit (bad || native_rows != 2 || managed_rows != 2) }
' "$TMP/list-credentials"

"$ROOT/acme-manager.sh" doctor >/dev/null || true

mkdir -p "$TMP/prefix/acme-manager" "$TMP/prefix/bin"
: >"$TMP/prefix/acme-manager/acme-agent.sh"
ln -s "$TMP/prefix/acme-manager/acme-agent.sh" "$TMP/prefix/bin/acme-agent"
PREFIX="$TMP/prefix" CONFIG_DIR="$TMP/config" sh "$ROOT/install.sh" >/dev/null
[[ -f "$TMP/prefix/acme-manager/acme-manager.sh" ]]
[[ -f "$TMP/prefix/acme-manager/VERSION" ]]
[[ -f "$TMP/prefix/acme-manager/lib/agent.sh" ]]
[[ -f "$TMP/prefix/acme-manager/lib/dns-profile-hook.sh" ]]
[[ -L "$TMP/prefix/bin/acme-manager" ]]
[[ "$(readlink "$TMP/prefix/bin/acme-manager")" == "$TMP/prefix/acme-manager/acme-manager.sh" ]]
[[ ! -e "$TMP/prefix/bin/acme-agent" ]]
[[ -L "$TMP/prefix/lib/acme-manager" ]]
[[ "$(readlink "$TMP/prefix/lib/acme-manager")" == "$TMP/prefix/acme-manager" ]]
[[ -f "$TMP/config/config.conf" ]]
[[ ! -e "$TMP/config/agent.conf" ]]
PREFIX="$TMP/prefix" CONFIG_DIR="$TMP/config" sh "$ROOT/install.sh" --uninstall >/dev/null
[[ ! -e "$TMP/prefix/acme-manager" ]]
[[ ! -e "$TMP/prefix/bin/acme-manager" ]]
[[ ! -e "$TMP/prefix/bin/acme-agent" ]]

PREFIX="$TMP/prefix-default" sh "$ROOT/install.sh" >/dev/null
[[ -f "$TMP/prefix-default/acme-manager/etc/config.conf" ]]
[[ "$(grep '^CONFIG_DIR=' "$TMP/prefix-default/acme-manager/.install-meta")" == "CONFIG_DIR=$TMP/prefix-default/acme-manager/etc" ]]
PREFIX="$TMP/prefix-default" sh "$ROOT/install.sh" --uninstall >/dev/null
[[ ! -e "$TMP/prefix-default/acme-manager" ]]

printf 'PASS: ACME Manager smoke tests\n'
