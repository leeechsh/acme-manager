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
  *' --list '*) echo 'Main_Domain KeyLength SAN_Domains CA'; echo 'example.com ec-256 *.example.com letsencrypt';;
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

printf '1\ninteractive.example.com\n1\n1\n1\n\n\n\n\n\n\n0\n' |
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
WEBDAV_PASSWORD="sync#secret"
INJECT_WEBDAV
rm -f "$ACME_HOME/account.conf"
"$ROOT/acme-manager.sh" webdav sync >/dev/null
assert_contains "$FAKE_CURL_LOG" 'meta.json'
assert_contains "$FAKE_CURL_LOG" 'interactive.example.com/cert.pem'
! grep -Fq 'sync#secret' "$FAKE_CURL_LOG"
[[ ! -e "$ACME_HOME/account.conf" ]]

cat >"$TMP/agent.conf" <<EOF_AGENT
WEBDAV_URL="https://dav.example.test/acme"
WEBDAV_USERNAME="sync-user"
WEBDAV_PASSWORD="sync-secret"
TARGET_DIR="$TMP/agent-certs"
AGENT_LOG="$TMP/agent.log"
EOF_AGENT
AGENT_REMOTE_META="$TMP/certs/meta.json" ACME_AGENT_CONFIG="$TMP/agent.conf" \
  "$ROOT/acme-agent.sh" sync >/dev/null
[[ -f "$TMP/agent-certs/meta.json" ]]
[[ -f "$TMP/agent-certs/interactive.example.com/fullchain.pem" ]]

"$ROOT/acme-manager.sh" dns configure cloudflare <<'INPUT'
token-value

INPUT
assert_contains "$ACME_HOME/account.conf" "export CF_Token='token-value'"
[[ "$(stat -c '%a' "$ACME_HOME/account.conf")" == 600 ]]
! grep -Fq token-value "$ACME_MANAGER_CONFIG"

"$ROOT/acme-manager.sh" doctor >/dev/null || true

PREFIX="$TMP/prefix" CONFIG_DIR="$TMP/config" sh "$ROOT/install.sh" >/dev/null
[[ -f "$TMP/prefix/acme-manager/acme-manager.sh" ]]
[[ -f "$TMP/prefix/acme-manager/acme-agent.sh" ]]
[[ -L "$TMP/prefix/bin/acme-manager" ]]
[[ "$(readlink "$TMP/prefix/bin/acme-manager")" == "$TMP/prefix/acme-manager/acme-manager.sh" ]]
[[ -L "$TMP/prefix/bin/acme-agent" ]]
[[ "$(readlink "$TMP/prefix/bin/acme-agent")" == "$TMP/prefix/acme-manager/acme-agent.sh" ]]
[[ -L "$TMP/prefix/lib/acme-manager" ]]
[[ "$(readlink "$TMP/prefix/lib/acme-manager")" == "$TMP/prefix/acme-manager" ]]
[[ -f "$TMP/config/agent.conf" ]]
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
