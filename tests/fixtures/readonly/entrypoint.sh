#!/bin/sh
# 読み取り専用ファイルシステム分析のテスト用 entrypoint。
# ここでの書き込みはコンテナの起動ごとに走るため、read_only: true にすると
# 書き込み先 (tmpfs / ボリューム) を用意していない限り必ず失敗する。
set -e

APP_LOG_DIR="${APP_LOG_DIR:-/var/log/app}"

# 起動のたびに作る状態ディレクトリ
mkdir -p /var/lib/appstate

# 起動のたびに書き足す起動ログ
mkdir -p "$APP_LOG_DIR"
echo "started" >> "$APP_LOG_DIR/boot.log"

exec "$@"
