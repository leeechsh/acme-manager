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
export FAKE_LOG="$TMP/acme.log"
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

"$ROOT/acme-manager.sh" deploy --domain example.com --target-dir "$TMP/certs/example.com" --reloadcmd 'true'
assert_contains "$FAKE_LOG" '--install-cert -d example.com --ecc --key-file'
assert_contains "$FAKE_LOG" 'example.com.key'
assert_contains "$FAKE_LOG" 'example.com.pem'
[[ -f "$TMP/certs/example.com/example.com.key" ]]
[[ -f "$TMP/certs/example.com/example.com.pem" ]]
cmp "$TMP/certs/example.com/privkey.pem" "$TMP/certs/example.com/example.com.key"
cmp "$TMP/certs/example.com/fullchain.pem" "$TMP/certs/example.com/example.com.pem"

"$ROOT/acme-manager.sh" dns configure cloudflare <<'INPUT'
token-value

INPUT
assert_contains "$ACME_HOME/account.conf" "export CF_Token='token-value'"
[[ "$(stat -c '%a' "$ACME_HOME/account.conf")" == 600 ]]
! grep -Fq token-value "$ACME_MANAGER_CONFIG"

"$ROOT/acme-manager.sh" doctor >/dev/null || true

PREFIX="$TMP/prefix" CONFIG_DIR="$TMP/config" sh "$ROOT/install.sh" >/dev/null
[[ -f "$TMP/prefix/acme-manager/acme-manager.sh" ]]
[[ -L "$TMP/prefix/bin/acme-manager" ]]
[[ "$(readlink "$TMP/prefix/bin/acme-manager")" == "$TMP/prefix/acme-manager/acme-manager.sh" ]]
[[ -L "$TMP/prefix/lib/acme-manager" ]]
[[ "$(readlink "$TMP/prefix/lib/acme-manager")" == "$TMP/prefix/acme-manager" ]]
PREFIX="$TMP/prefix" CONFIG_DIR="$TMP/config" sh "$ROOT/install.sh" --uninstall >/dev/null
[[ ! -e "$TMP/prefix/acme-manager" ]]
[[ ! -e "$TMP/prefix/bin/acme-manager" ]]

printf 'PASS: ACME Manager smoke tests\n'
