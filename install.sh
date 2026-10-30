#!/bin/sh
# POSIX bootstrap installer. It is intentionally usable as: curl .../install.sh | sh
set -eu

PREFIX=${PREFIX:-}
CONFIG_DIR=${CONFIG_DIR:-}
REPO_SLUG=${REPO_SLUG:-leeechsh/acme-manager}
REPO_REF=${REPO_REF:-main}
TMP_ROOT=
SCRIPT_DIR=

if [ -f "${0:-}" ]; then
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR=
fi

# Installed copies remember their paths so `acme-manager update` also works
# when the installation used a user-owned PREFIX and CONFIG_DIR.
if [ -z "$PREFIX" ] && [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/.install-meta" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      PREFIX) PREFIX=$value ;;
      CONFIG_DIR) CONFIG_DIR=$value ;;
      REPO_SLUG) REPO_SLUG=$value ;;
    esac
  done <"$SCRIPT_DIR/.install-meta"
fi

PREFIX=${PREFIX:-/usr/local}
CONFIG_DIR=${CONFIG_DIR:-/etc/acme-manager}
DEST=$PREFIX/acme-manager
BIN=$PREFIX/bin/acme-manager
LIB_LINK=$PREFIX/lib/acme-manager

usage() {
  cat <<USAGE
Usage: install.sh [options]

  --update              Download the latest code from GitHub and update the installation
  --uninstall           Remove manager code while keeping config and acme.sh data
  --repo owner/name     Use a different GitHub repository
  --ref branch|tag      Use a different GitHub branch or tag

Environment:
  PREFIX                Installation prefix, default /usr/local
  CONFIG_DIR            Config directory, default /etc/acme-manager
  REPO_SLUG             GitHub repository, default $REPO_SLUG
  REPO_REF              GitHub branch or tag, default $REPO_REF
USAGE
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM

MODE=install
while [ "$#" -gt 0 ]; do
  case "$1" in
    --update) MODE=update; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --repo)
      [ "$#" -ge 2 ] || { echo '--repo requires owner/name' >&2; exit 2; }
      REPO_SLUG=$2; shift 2 ;;
    --ref)
      [ "$#" -ge 2 ] || { echo '--ref requires a branch or tag' >&2; exit 2; }
      REPO_REF=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$REPO_SLUG" in
  */*) ;;
  *) echo "Repository must use owner/name format: $REPO_SLUG" >&2; exit 2 ;;
esac

if [ "$MODE" = uninstall ]; then
  if [ "$(id -u)" -ne 0 ] && case "$PREFIX" in /usr/local*) true;; *) false;; esac; then
    echo 'Removing the default system path requires root; set PREFIX for a user directory.' >&2
    exit 1
  fi
  rm -f "$BIN"
  if [ -L "$LIB_LINK" ]; then
    rm -f "$LIB_LINK"
  elif [ -d "$LIB_LINK" ] && [ "$LIB_LINK" != "$DEST" ]; then
    rm -rf "$LIB_LINK"
  fi
  rm -rf "$DEST"
  echo "ACME Manager removed; $CONFIG_DIR and acme.sh data were kept."
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  case "$PREFIX" in
    /usr/local*) echo 'The default installation path requires root; set PREFIX=$HOME/.local and CONFIG_DIR=$HOME/.config/acme-manager.' >&2; exit 1 ;;
  esac
fi

SOURCE_DIR=
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/acme-manager.sh" ] && [ -d "$SCRIPT_DIR/lib" ] && [ "$MODE" = install ]; then
  SOURCE_DIR=$SCRIPT_DIR
else
  command -v curl >/dev/null 2>&1 || { echo 'curl is required to install or update from GitHub.' >&2; exit 1; }
  command -v tar >/dev/null 2>&1 || { echo 'tar is required to install or update from GitHub.' >&2; exit 1; }
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/acme-manager.XXXXXX")
  ARCHIVE="$TMP_ROOT/source.tar.gz"
  URL="https://github.com/$REPO_SLUG/archive/refs/heads/$REPO_REF.tar.gz"
  case "$REPO_REF" in
    v*|[0-9]*) URL="https://github.com/$REPO_SLUG/archive/refs/tags/$REPO_REF.tar.gz" ;;
  esac
  echo "Downloading ACME Manager: $REPO_SLUG@$REPO_REF"
  curl -fsSL "$URL" -o "$ARCHIVE"
  tar -xzf "$ARCHIVE" -C "$TMP_ROOT"
  SOURCE_DIR=$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)
  [ -n "$SOURCE_DIR" ] || { echo 'The downloaded archive did not contain a project directory.' >&2; exit 1; }
fi

[ -f "$SOURCE_DIR/acme-manager.sh" ] && [ -d "$SOURCE_DIR/lib" ] || {
  echo "Source directory is incomplete: $SOURCE_DIR" >&2
  exit 1
}

mkdir -p "$DEST" "$PREFIX/bin" "$CONFIG_DIR"
cp -R "$SOURCE_DIR/acme-manager.sh" "$SOURCE_DIR/install.sh" "$SOURCE_DIR/lib" "$SOURCE_DIR/config.conf.example" "$DEST/"
chmod 755 "$DEST/acme-manager.sh" "$DEST/install.sh" "$DEST/lib"/*.sh
ln -sfn "$DEST/acme-manager.sh" "$BIN"
if [ -e "$LIB_LINK" ] && [ ! -L "$LIB_LINK" ] && [ "$LIB_LINK" != "$DEST" ]; then
  rm -rf "$LIB_LINK"
fi
mkdir -p "$PREFIX/lib"
ln -sfn "$DEST" "$LIB_LINK"
printf 'PREFIX=%s\nCONFIG_DIR=%s\nREPO_SLUG=%s\nREPO_REF=%s\n' \
  "$PREFIX" "$CONFIG_DIR" "$REPO_SLUG" "$REPO_REF" >"$DEST/.install-meta"
chmod 600 "$DEST/.install-meta"

if [ ! -e "$CONFIG_DIR/config.conf" ]; then
  cp "$DEST/config.conf.example" "$CONFIG_DIR/config.conf"
  chmod 600 "$CONFIG_DIR/config.conf"
fi

if [ "$MODE" = update ]; then
  echo "ACME Manager updated: $DEST"
else
  echo "ACME Manager installed to $DEST"
fi
echo "Command link: $BIN"
echo "Library link: $LIB_LINK"
echo "Config file: $CONFIG_DIR/config.conf"
echo 'Config, account data, certificates and the acme.sh Cron job are kept during manager updates and uninstall.'
