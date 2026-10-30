#!/bin/sh
# POSIX bootstrap installer. It is intentionally usable as: curl .../install.sh | sh
set -eu

PREFIX=${PREFIX:-}
CONFIG_DIR=${CONFIG_DIR:-}
REPO_SLUG=${REPO_SLUG:-leeechsh/acme-manager}
REPO_REF=${REPO_REF:-main}
TMP_ROOT=
SCRIPT_DIR=

case "${0:-}" in
  */*) SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR= ;;
esac

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
用法: install.sh [选项]

  --update              从 GitHub 下载最新代码并更新已安装版本
  --uninstall           卸载管理器代码，保留配置和 acme.sh 数据
  --repo owner/name     指定 GitHub 仓库
  --ref branch|tag      指定 GitHub 分支或标签

环境变量:
  PREFIX                安装前缀，默认 /usr/local
  CONFIG_DIR            配置目录，默认 /etc/acme-manager
  REPO_SLUG             GitHub 仓库，默认 $REPO_SLUG
  REPO_REF              GitHub 分支或标签，默认 $REPO_REF
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
      [ "$#" -ge 2 ] || { echo '--repo 需要 owner/name' >&2; exit 2; }
      REPO_SLUG=$2; shift 2 ;;
    --ref)
      [ "$#" -ge 2 ] || { echo '--ref 需要分支或标签' >&2; exit 2; }
      REPO_REF=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$REPO_SLUG" in
  */*) ;;
  *) echo "仓库格式必须是 owner/name: $REPO_SLUG" >&2; exit 2 ;;
esac

if [ "$MODE" = uninstall ]; then
  if [ "$(id -u)" -ne 0 ] && case "$PREFIX" in /usr/local*) true;; *) false;; esac; then
    echo '卸载默认系统路径需要 root；用户目录请设置 PREFIX。' >&2
    exit 1
  fi
  rm -f "$BIN"
  if [ -L "$LIB_LINK" ]; then
    rm -f "$LIB_LINK"
  elif [ -d "$LIB_LINK" ] && [ "$LIB_LINK" != "$DEST" ]; then
    rm -rf "$LIB_LINK"
  fi
  rm -rf "$DEST"
  echo "已卸载 ACME Manager；保留 $CONFIG_DIR 和 acme.sh 数据。"
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  case "$PREFIX" in
    /usr/local*) echo '默认安装路径需要 root；可设置 PREFIX=$HOME/.local CONFIG_DIR=$HOME/.config/acme-manager。' >&2; exit 1 ;;
  esac
fi

SOURCE_DIR=
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/acme-manager.sh" ] && [ -d "$SCRIPT_DIR/lib" ] && [ "$MODE" = install ]; then
  SOURCE_DIR=$SCRIPT_DIR
else
  command -v curl >/dev/null 2>&1 || { echo '需要 curl 才能从 GitHub 安装或更新。' >&2; exit 1; }
  command -v tar >/dev/null 2>&1 || { echo '需要 tar 才能从 GitHub 安装或更新。' >&2; exit 1; }
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/acme-manager.XXXXXX")
  ARCHIVE="$TMP_ROOT/source.tar.gz"
  URL="https://github.com/$REPO_SLUG/archive/refs/heads/$REPO_REF.tar.gz"
  case "$REPO_REF" in
    v*|[0-9]*) URL="https://github.com/$REPO_SLUG/archive/refs/tags/$REPO_REF.tar.gz" ;;
  esac
  echo "下载 ACME Manager: $REPO_SLUG@$REPO_REF"
  curl -fsSL "$URL" -o "$ARCHIVE"
  tar -xzf "$ARCHIVE" -C "$TMP_ROOT"
  SOURCE_DIR=$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)
  [ -n "$SOURCE_DIR" ] || { echo '下载内容中未找到项目目录。' >&2; exit 1; }
fi

[ -f "$SOURCE_DIR/acme-manager.sh" ] && [ -d "$SOURCE_DIR/lib" ] || {
  echo "源目录不完整: $SOURCE_DIR" >&2
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
  echo "ACME Manager 已更新: $DEST"
else
  echo "ACME Manager 已安装到 $DEST"
fi
echo "命令链接: $BIN"
echo "库目录链接: $LIB_LINK"
echo "配置文件: $CONFIG_DIR/config.conf"
echo '配置、账户、证书和 acme.sh Cron 不会因更新或卸载管理器代码而删除。'
