#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/build-and-verify-test.XXXXXX")"

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/build-and-verify-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *)
      printf 'Refusing to remove unexpected test directory: %s\n' "$TEST_TMP" >&2
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '$unexpected' in $file"
  fi
}

assert_occurrences() {
  local file="$1" expected="$2" expected_count="$3" actual_count
  actual_count="$({ grep -Fo -- "$expected" "$file" || true; } | wc -l | tr -d '[:space:]')"
  [ "$actual_count" = "$expected_count" ] \
    || fail "expected '$expected' $expected_count times in $file, found $actual_count"
}

assert_matches() {
  local file="$1" pattern="$2"
  grep -Eq -- "$pattern" "$file" || fail "expected /$pattern/ in $file"
}

# 全量レポート (build_and_verify_<日時>.txt) だけを DIR から取り出し、REPORT_FILES へ入れる。
# 同じディレクトリには読み取り専用ファイルシステム分析のテキスト
# (build_and_verify_<日時>_readonly_filesystem.txt)、証明書チェックの
# テキスト (build_and_verify_<日時>_cert_check_<サービス名>.txt)、JBoss
# モジュール一覧 (build_and_verify_<日時>_jboss_modules_<サービス名>.txt) も出力される
# ため、素の glob では件数が増えてしまう。レポートの件数を数えるテストは
# この関数を使う。Java 例外解析のテキスト (_java_exceptions.txt) は
# --deploy-exception-text 指定時にしか作られないが、除外は残しておく。
collect_report_files() {
  local dir="$1" path
  REPORT_FILES=()
  for path in "$dir"/build_and_verify_*.txt; do
    case "$path" in
      *_java_exceptions.txt|*_readonly_filesystem.txt|*_undertow_virtual_host.txt) continue ;;
      *_cert_check_*.txt) continue ;;
      *_jboss_modules_*.txt) continue ;;
    esac
    [ -f "$path" ] && REPORT_FILES+=("$path")
  done
}

assert_before() {
  local file="$1" first="$2" second="$3" first_line second_line
  first_line="$(grep -nF -- "$first" "$file" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" "$file" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$first_line" ] || fail "expected '$first' in $file"
  [ -n "$second_line" ] || fail "expected '$second' in $file"
  [ "$first_line" -lt "$second_line" ] || fail "expected '$first' before '$second' in $file"
}

mkdir -p "$TEST_TMP/bin"
cp "$TEST_DIR/helpers/docker" "$TEST_TMP/bin/docker"
cp "$TEST_DIR/helpers/curl" "$TEST_TMP/bin/curl"
cp "$TEST_DIR/helpers/aws" "$TEST_TMP/bin/aws"
cp "$TEST_DIR/helpers/docker-usage-check.sh" "$TEST_TMP/bin/docker-usage-check.sh"
chmod 755 "$TEST_TMP/bin/docker" "$TEST_TMP/bin/curl" "$TEST_TMP/bin/aws" \
    "$TEST_TMP/bin/docker-usage-check.sh"

export PATH="$TEST_TMP/bin:$PATH"
export FAKE_DOCKER_CALLS="$TEST_TMP/docker.calls"
export FAKE_CURL_CALLS="$TEST_TMP/curl.calls"
export FAKE_AWS_CALLS="$TEST_TMP/aws.calls"
# 対話操作をすべて終えたときの完全クリアは、別プロジェクトの
# docker-usage-check.sh へ委ねている。実物 (兄弟ディレクトリや PATH 上のもの) を
# 拾って本当に削除してしまわないよう、必ず偽物を指させる。
export DOCKER_USAGE_CHECK_SCRIPT="$TEST_TMP/bin/docker-usage-check.sh"
export FAKE_USAGE_CHECK_CALLS="$TEST_TMP/usage-check.calls"
: > "$FAKE_USAGE_CHECK_CALLS"

success_output="$TEST_TMP/success.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! (
  cd "$REPO_ROOT"
  unset NO_COLOR
  CLICOLOR_FORCE=1 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 2 \
    --directory-file-limit 10 \
    --deployment-dir-env APP_CONFIG_DIR \
    --directory-tree-report \
    --report-dir "$TEST_TMP/reports" \
    --suppress-removed-logs
) >"$success_output" 2>&1; then
  cat "$success_output" >&2
  fail "success fixture returned a non-zero status"
fi

assert_contains "$success_output" "BuildKit のビルドログ表示形式: plain"
assert_contains "$success_output" "[fake-build] BUILDKIT_PROGRESS=plain"
assert_contains "$success_output" "ビルド結果: image=j1/base.local, id=sha256:test-image"
assert_contains "$success_output" "jbosseap サーバーの起動完了を確認しました: サービス 'app'"
assert_contains "$success_output" "コンテナ起動ログ (対象サービス: app, 末尾 15/15 行 (指定上限: 50)):"
assert_contains "$success_output" "APP000001: Orders application initialized"
assert_contains "$success_output" $'\033[1;36mapp-1  | 09:17:43,001 INFO'
assert_contains "$success_output" $'\033[1;32mapp-1  | 09:17:47,305 INFO'
assert_contains "$success_output" "java:jboss/datasources/Orders#Primary"
assert_contains "$success_output" "java:app/jdbc/ReportingDS"
assert_contains "$success_output" "orders.war"
assert_contains "$success_output" "/orders"
assert_occurrences "$success_output" "java:/JmsXA" 1
# WFLYSRV0009 の 1 行に old.war が 2 回現れる (名前と runtime-name) ため、
# 「アンデプロイ済みアプリを要約側で再掲しない」= 元ログ 1 行分 = 2 件が期待値。
assert_occurrences "$success_output" "old.war" 2
assert_occurrences "$success_output" "/opt/eap/standalone/data/content/ab/cd/content" 1
assert_not_contains "$success_output" "利用可能な JNDI データソース:"
assert_not_contains "$success_output" "JNDI データソースエラー:"
assert_not_contains "$success_output" "アプリケーションデプロイ結果ログ"
assert_not_contains "$success_output" "デプロイ済みアプリケーション:"
assert_not_contains "$success_output" "登録済み Web コンテキスト:"
assert_not_contains "$success_output" "同時起動 Compose サービスログ"
assert_contains "$success_output" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: 2)"
assert_contains "$success_output" "通常ファイル: 直下 10 件以下は全ファイル名、超過時は拡張子別件数"
assert_contains "$success_output" "├── [ファイル] LICENSE"
assert_contains "$success_output" "├── app/"
assert_contains "$success_output" "│   ├── [ファイル] application.jar"
assert_contains "$success_output" "│   ├── [ファイル] archive.tar.gz"
assert_contains "$success_output" "│   ├── [ファイル] legacy.jar"
assert_contains "$success_output" "│   └── config/"
assert_contains "$success_output" "│       ├── [ファイル] application.yaml"
assert_contains "$success_output" "│       ├── [ファイル] .env"
assert_contains "$success_output" "├── afs/"
assert_contains "$success_output" "├── aws/"
assert_contains "$success_output" "├── etc/"
assert_contains "$success_output" "├── local/"
assert_contains "$success_output" "aws-cli/"
assert_contains "$success_output" "├── proc/"
assert_contains "$success_output" "    └── share/"
assert_contains "$success_output" "├── sys/"
assert_contains "$success_output" "    ├── lib/"
assert_contains "$success_output" "lib64/"
assert_contains "$success_output" "    ├── local/"
assert_contains "$success_output" "├── empty/"
assert_contains "$success_output" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"
assert_contains "$success_output" "[JBoss EAP デプロイ先]"
assert_contains "$success_output" "[Web アプリケーションルート]"
assert_contains "$success_output" "[Java クラスパスルート]"
assert_contains "$success_output" "[環境変数 APP_CONFIG_DIR]"
assert_contains "$success_output" "[ファイル] .class: 11 件"
assert_contains "$success_output" "[ファイル] .properties: 1 件"
assert_contains "$success_output" "[ファイル] runtime.properties"
assert_contains "$success_output" "API_TOKEN=[REDACTED]"
assert_not_contains "$success_output" "do-not-log-this-value"
assert_not_contains "$success_output" "Order01.class"
assert_not_contains "$success_output" "deep.json"
assert_not_contains "$success_output" "aws-cli-hidden/"
assert_not_contains "$success_output" "X11/"
assert_not_contains "$success_output" "doc/"
assert_not_contains "$success_output" "icons/"
assert_not_contains "$success_output" "licenses/"
assert_not_contains "$success_output" "man/"
assert_not_contains "$success_output" "osinfo/"
assert_not_contains "$success_output" "zoneinfo/"
assert_not_contains "$success_output" "X11-hidden"
assert_not_contains "$success_output" "doc-hidden"
assert_not_contains "$success_output" "icons-hidden"
assert_not_contains "$success_output" "licenses-hidden"
assert_not_contains "$success_output" "man-hidden"
assert_not_contains "$success_output" "osinfo-hidden"
assert_not_contains "$success_output" "zoneinfo-hidden"
assert_not_contains "$success_output" "lib64-hidden/"
assert_not_contains "$success_output" "aws-cli-hidden.txt"
assert_not_contains "$success_output" "lib64-hidden.so"
assert_not_contains "$success_output" "public/"
assert_not_contains "$success_output" "[ファイル] readme.txt"
assert_not_contains "$success_output" "zoneinfo.txt"
assert_not_contains "$success_output" "usr-local-hidden"
assert_contains "$success_output" "Java JVM パラメータ (サービス: app, コンテナ: test-app-1, Java プロセス: 1)"
assert_contains "$success_output" "[Java プロセス 1] PID: 1"
assert_contains "$success_output" "実行ファイル     : /opt/java/openjdk/bin/java"
assert_contains "$success_output" 'バージョン       : openjdk version "17.0.11" 2024-04-16 LTS'
assert_contains "$success_output" "起動対象         : -jar /opt/jboss-eap/jboss-modules.jar"
assert_contains "$success_output" "[ヒープ・メモリ] 4 件"
assert_contains "$success_output" "  -Xmx1024m"
assert_contains "$success_output" "  -XX:MaxMetaspaceSize                         = 256m"
assert_contains "$success_output" "[GC (ガベージコレクション)] 2 件"
assert_contains "$success_output" "  -XX:+UseG1GC"
assert_contains "$success_output" "[Java エージェント] 1 件"
assert_contains "$success_output" "  -javaagent                                   = /opt/otel/opentelemetry-javaagent.jar"
assert_contains "$success_output" "[JBoss / WildFly] 2 件"
assert_contains "$success_output" "[システムプロパティ (-D)] 2 件"
assert_contains "$success_output" "[クラスパス・モジュール] 2 件"
assert_contains "$success_output" "  --add-exports                                = java.base/sun.nio.ch=ALL-UNNAMED"
assert_contains "$success_output" "[その他 JVM オプション] 1 件"
assert_contains "$success_output" "[起動対象へ渡される引数] 4 件"
assert_contains "$success_output" "  org.jboss.as.standalone"
assert_contains "$success_output" "[JVM オプションを渡す環境変数] 1 件"
assert_contains "$success_output" "  JAVA_TOOL_OPTIONS                            = -javaagent:/opt/otel/opentelemetry-javaagent.jar"
# JVM パラメータ側の認証情報も環境変数一覧と同じく値だけを伏せる。
assert_contains "$success_output" "  -Djboss.password                             = [REDACTED]"
assert_not_contains "$success_output" "do-not-log-this-jvm-value"
assert_contains "$success_output" "OpenTelemetry 環境変数・JVM パラメータ一覧 (サービス: app, コンテナ: test-app-1)"
assert_contains "$success_output" "[OpenTelemetry 標準環境変数 (OTEL_*)] 4 件"
assert_contains "$success_output" "  OTEL_SERVICE_NAME                            = orders-app"
assert_contains "$success_output" "  OTEL_EXPORTER_OTLP_ENDPOINT                  = http://adot-collector:4317"
# OTLP ヘッダは認証情報を載せる用途が多いため値を伏せる。
assert_contains "$success_output" "  OTEL_EXPORTER_OTLP_HEADERS                   = [REDACTED]"
assert_not_contains "$success_output" "do-not-log-this-header"
assert_contains "$success_output" "[OpenTelemetry 関連環境変数] 1 件"
assert_contains "$success_output" "[OpenTelemetry 関連 JVM パラメータ (コマンドライン)] 4 件"
assert_contains "$success_output" "  -Dotel.exporter.otlp.endpoint                = http://adot-collector:4317"
assert_contains "$success_output" "[OpenTelemetry 関連 JVM パラメータ (環境変数由来)] 1 件"
assert_contains "$success_output" "  JAVA_TOOL_OPTIONS: -javaagent                = /opt/otel/opentelemetry-javaagent.jar"
assert_contains "$success_output" "[未設定の主要 OpenTelemetry 設定] 7 件"
assert_contains "$success_output" "  OTEL_PROPAGATORS (システムプロパティ -Dotel.propagators も未設定)"
# 環境変数・システムプロパティのどちらかで設定済みの項目は未設定側へ出さない。
assert_not_contains "$success_output" "OTEL_SERVICE_NAME (システムプロパティ"
assert_not_contains "$success_output" "OTEL_TRACES_EXPORTER (システムプロパティ"
assert_before "$success_output" "環境変数一覧 (サービス: app" "コンテナ内ディレクトリツリー (サービス: app"
assert_before "$success_output" "コンテナ内ディレクトリツリー (サービス: app" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"
assert_before "$success_output" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造" "Java JVM パラメータ (サービス: app"
assert_before "$success_output" "Java JVM パラメータ (サービス: app" "OpenTelemetry 環境変数・JVM パラメータ一覧 (サービス: app"
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ app'
assert_matches "$FAKE_DOCKER_CALLS" 'exec cid-app find / .* -path /afs .* -path /local/aws-cli .* -path /opt/jboss-eap/modules/system/layers/base .* -path /usr/share .* -path /usr/share/X11 .* -path /usr/share/doc .* -path /usr/share/icons .* -path /usr/share/licenses .* -path /usr/share/man .* -path /usr/share/osinfo .* -path /usr/share/zoneinfo .* -path /usr/lib64 .* -path /usr/local .* -prune -print0 -o -type d -print0'
assert_matches "$FAKE_DOCKER_CALLS" 'exec cid-app find / .* -path /afs .* -path /local/aws-cli .* -path /opt/jboss-eap/modules/system/layers/base .* -path /usr/share .* -path /usr/share/X11 .* -path /usr/share/doc .* -path /usr/share/icons .* -path /usr/share/licenses .* -path /usr/share/man .* -path /usr/share/osinfo .* -path /usr/share/zoneinfo .* -path /usr/lib64 .* -path /usr/local .* -prune -o -type f -print0'
assert_not_contains "$FAKE_DOCKER_CALLS" "-path /share "
assert_matches "$FAKE_DOCKER_CALLS" 'exec cid-app find / -maxdepth 3 .* -type f -print0'

collect_report_files "$TEST_TMP/reports"
report_files=("${REPORT_FILES[@]}")
[ ${#report_files[@]} -eq 1 ] && [ -f "${report_files[0]}" ] \
  || fail "expected one timestamped full build report"
full_report="${report_files[0]}"
[[ "$(basename "$full_report")" =~ ^build_and_verify_[0-9]{14}(_[0-9]+)?\.txt$ ]] \
  || fail "unexpected full build report filename: $full_report"
assert_matches "$full_report" 'build_and_verify\.sh 全量ビルドレポート'
assert_contains "$full_report" "全体結果     : 成功"
assert_contains "$full_report" "[1] ビルド結果"
assert_contains "$full_report" "[2] 環境変数一覧 (全件)"
assert_contains "$full_report" "[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)"
assert_contains "$full_report" "[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)"
assert_contains "$full_report" "[5] Java JVM パラメータ (全件)"
assert_contains "$full_report" "[6] OpenTelemetry 環境変数・JVM パラメータ (全件)"
assert_contains "$full_report" "[8] CloudWatch Logs 送信検証 (cwagent)"
assert_contains "$full_report" "compose ファイルに CloudWatch Agent のサービス (cwagent) が定義されていないため実行していません。"
assert_contains "$full_report" "[9] Compose サービス別ログ (全サービス・全行)"
assert_contains "$full_report" "処理が成功したため、Compose サービス別ログの全文出力は省略しました。"
assert_contains "$full_report" "API_TOKEN=[REDACTED]"
assert_not_contains "$full_report" "do-not-log-this-value"
assert_contains "$full_report" "[Java プロセス 1] PID: 1"
assert_contains "$full_report" "  -Djboss.password                             = [REDACTED]"
assert_not_contains "$full_report" "do-not-log-this-jvm-value"
assert_contains "$full_report" "  OTEL_EXPORTER_OTLP_HEADERS                   = [REDACTED]"
assert_not_contains "$full_report" "do-not-log-this-header"
assert_contains "$full_report" "  OTEL_SERVICE_NAME                            = orders-app"
assert_contains "$full_report" "[未設定の主要 OpenTelemetry 設定] 7 件"
assert_before "$full_report" "[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)" "[5] Java JVM パラメータ (全件)"
assert_before "$full_report" "[5] Java JVM パラメータ (全件)" "[6] OpenTelemetry 環境変数・JVM パラメータ (全件)"
assert_before "$full_report" "[6] OpenTelemetry 環境変数・JVM パラメータ (全件)" "[9] Compose サービス別ログ (全サービス・全行)"
assert_contains "$full_report" "application.yaml"
assert_contains "$full_report" "deep.json"
assert_contains "$full_report" "Order01.class"
assert_contains "$full_report" "Order11.class"
assert_contains "$full_report" ".galleon/"
assert_contains "$full_report" "aws-cli/"
assert_contains "$full_report" "base/"
assert_contains "$full_report" "    └── share/"
assert_contains "$full_report" "    ├── local/"
assert_contains "$full_report" "lib64/"
assert_not_contains "$full_report" "zoneinfo.txt"
assert_not_contains "$full_report" "cache/"
assert_not_contains "$full_report" "hosts"
assert_not_contains "$full_report" "ssl/"
assert_not_contains "$full_report" "galleon-hidden/"
assert_not_contains "$full_report" "metadata.json"
assert_not_contains "$full_report" "status"
assert_not_contains "$full_report" "kernel/"
assert_not_contains "$full_report" "jvm/"
assert_not_contains "$full_report" "libexample.so"
assert_not_contains "$full_report" "uevent_seqnum"
assert_not_contains "$full_report" "aws-cli-hidden/"
assert_not_contains "$full_report" "jboss-base-hidden/"
assert_not_contains "$full_report" "X11/"
assert_not_contains "$full_report" "doc/"
assert_not_contains "$full_report" "icons/"
assert_not_contains "$full_report" "licenses/"
assert_not_contains "$full_report" "man/"
assert_not_contains "$full_report" "osinfo/"
assert_not_contains "$full_report" "zoneinfo/"
assert_not_contains "$full_report" "X11-hidden"
assert_not_contains "$full_report" "doc-hidden"
assert_not_contains "$full_report" "icons-hidden"
assert_not_contains "$full_report" "licenses-hidden"
assert_not_contains "$full_report" "man-hidden"
assert_not_contains "$full_report" "osinfo-hidden"
assert_not_contains "$full_report" "zoneinfo-hidden"
assert_not_contains "$full_report" "lib64-hidden/"
assert_not_contains "$full_report" "aws-cli-hidden.txt"
assert_not_contains "$full_report" "jboss-base-hidden.xml"
assert_not_contains "$full_report" "lib64-hidden.so"
assert_not_contains "$full_report" "public/"
assert_not_contains "$full_report" "assets/"
assert_not_contains "$full_report" "readme.txt"
assert_not_contains "$full_report" "logo.svg"
assert_not_contains "$full_report" "usr-local-hidden"

startup_log_limit_output="$TEST_TMP/startup-log-limit.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --startup-log-lines 2 \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$startup_log_limit_output" 2>&1; then
  cat "$startup_log_limit_output" >&2
  fail "startup log line limit scenario returned a non-zero status"
fi

assert_contains "$startup_log_limit_output" "コンテナ起動ログ (対象サービス: app, 末尾 2/15 行 (指定上限: 2)):"
assert_contains "$startup_log_limit_output" "WFLYSRV0010"
assert_contains "$startup_log_limit_output" "WFLYSRV0025"
assert_not_contains "$startup_log_limit_output" "WFLYSRV0049"
assert_not_contains "$startup_log_limit_output" "APP000001"
assert_not_contains "$startup_log_limit_output" $'\033['

companion_logs_output="$TEST_TMP/companion-logs.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app db cache"
if ! (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app,db,cache \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$companion_logs_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$companion_logs_output" >&2
  fail "companion Compose service log scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$companion_logs_output" "コンテナ起動ログ (対象サービス: app, 末尾 15/15 行 (指定上限: 50)):"
assert_contains "$companion_logs_output" "同時起動 Compose サービスログ (サービス: db, 末尾 50/52 行 (指定上限: 50)):"
assert_contains "$companion_logs_output" "DB003: companion service log"
assert_contains "$companion_logs_output" "DB052: companion service log"
assert_not_contains "$companion_logs_output" "DB001: companion service log"
assert_not_contains "$companion_logs_output" "DB002: companion service log"
assert_contains "$companion_logs_output" "同時起動 Compose サービスログ (サービス: cache, 末尾 2/2 行 (指定上限: 50)):"
assert_contains "$companion_logs_output" "CACHE002: accepting connections"
assert_before "$companion_logs_output" "コンテナ起動ログ (対象サービス: app" "同時起動 Compose サービスログ (サービス: db"
assert_before "$companion_logs_output" "同時起動 Compose サービスログ (サービス: db" "同時起動 Compose サービスログ (サービス: cache"
assert_before "$companion_logs_output" "同時起動 Compose サービスログ (サービス: cache" "環境変数一覧 (サービス: app"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml ps --services"
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ db'
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ cache'

tree_depth_output="$TEST_TMP/tree-depth.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$tree_depth_output" 2>&1; then
  cat "$tree_depth_output" >&2
  fail "directory tree depth scenario returned a non-zero status"
fi

assert_contains "$tree_depth_output" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: 1)"
assert_contains "$tree_depth_output" "通常ファイル: 表示しない"
assert_contains "$tree_depth_output" "├── app/"
assert_contains "$tree_depth_output" "├── empty/"
assert_contains "$tree_depth_output" "├── afs/"
assert_contains "$tree_depth_output" "├── aws/"
assert_contains "$tree_depth_output" "├── etc/"
assert_contains "$tree_depth_output" "├── proc/"
assert_contains "$tree_depth_output" "├── sys/"
assert_not_contains "$tree_depth_output" "config/"
assert_not_contains "$tree_depth_output" "[ファイル]"
assert_matches "$FAKE_DOCKER_CALLS" 'exec cid-app find / -maxdepth 1 .* -prune -print0 -o -type d -print0'
assert_not_contains "$FAKE_DOCKER_CALLS" "-type f -print0"

# 既定ではツリーもデプロイ構造も画面へ出さず、全量レポートにも書かない。
# 表示しない分、コンテナ内 find も呼ばない。
tree_default_output="$TEST_TMP/tree-default.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --report-dir "$TEST_TMP/tree-default-reports" \
    --suppress-removed-logs
) >"$tree_default_output" 2>&1; then
  cat "$tree_default_output" >&2
  fail "default directory tree scenario returned a non-zero status"
fi

assert_contains "$tree_default_output" "コンテナ内ディレクトリツリーと JBoss EAP デプロイ構造は表示しません (--directory-tree で表示します)。"
assert_not_contains "$tree_default_output" "コンテナ内ディレクトリツリー (サービス: app"
assert_not_contains "$tree_default_output" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"
assert_not_contains "$FAKE_DOCKER_CALLS" "exec cid-app find /"
collect_report_files "$TEST_TMP/tree-default-reports"
tree_default_report="${REPORT_FILES[0]:-}"
[ -n "$tree_default_report" ] || fail "expected a full build report for the default directory tree scenario"
assert_contains "$tree_default_report" "[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)"
assert_contains "$tree_default_report" "[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)"
assert_occurrences "$tree_default_report" "--directory-tree-report を指定していないため出力していません。" 2
assert_contains "$tree_default_report" "保存ポリシー  : 環境変数は全件、ツリーと JBoss EAP デプロイ構造は保存しない"
assert_contains "$tree_default_report" "[2] 環境変数一覧 (全件)"
assert_contains "$tree_default_report" "[5] Java JVM パラメータ (全件)"

# --directory-tree は画面表示だけを有効にし、レポートへは書き出さない。
tree_display_only_output="$TEST_TMP/tree-display-only.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree \
    --report-dir "$TEST_TMP/tree-display-reports" \
    --suppress-removed-logs
) >"$tree_display_only_output" 2>&1; then
  cat "$tree_display_only_output" >&2
  fail "--directory-tree scenario returned a non-zero status"
fi

assert_contains "$tree_display_only_output" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: all)"
assert_contains "$tree_display_only_output" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"
assert_not_contains "$tree_display_only_output" "--directory-tree で表示します"
collect_report_files "$TEST_TMP/tree-display-reports"
tree_display_report="${REPORT_FILES[0]:-}"
[ -n "$tree_display_report" ] || fail "expected a full build report for the --directory-tree scenario"
assert_occurrences "$tree_display_report" "--directory-tree-report を指定していないため出力していません。" 2

# --directory-tree-report はレポートへの出力だけを有効にし、画面表示は増やさない。
tree_report_only_output="$TEST_TMP/tree-report-only.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-report \
    --report-dir "$TEST_TMP/tree-report-reports" \
    --suppress-removed-logs
) >"$tree_report_only_output" 2>&1; then
  cat "$tree_report_only_output" >&2
  fail "--directory-tree-report scenario returned a non-zero status"
fi

assert_contains "$tree_report_only_output" "コンテナ内ディレクトリツリーと JBoss EAP デプロイ構造は表示しません (--directory-tree で表示します)。"
assert_not_contains "$tree_report_only_output" "コンテナ内ディレクトリツリー (サービス: app"
collect_report_files "$TEST_TMP/tree-report-reports"
tree_report_only_report="${REPORT_FILES[0]:-}"
[ -n "$tree_report_only_report" ] || fail "expected a full build report for the --directory-tree-report scenario"
assert_not_contains "$tree_report_only_report" "--directory-tree-report を指定していないため出力していません。"
assert_contains "$tree_report_only_report" "保存ポリシー  : 環境変数は全件、ツリーは全深度・全ファイル名"
assert_contains "$tree_report_only_report" "コンテナ内ディレクトリツリー (サービス: app, コンテナ: test-app-1, 最大深さ: all"
assert_contains "$tree_report_only_report" "JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造"

# 深さ指定は画面表示を自動で有効にするが、--no-directory-tree を併記すれば表示しない。
tree_no_display_output="$TEST_TMP/tree-no-display.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --no-directory-tree \
    --suppress-removed-logs
) >"$tree_no_display_output" 2>&1; then
  cat "$tree_no_display_output" >&2
  fail "--no-directory-tree scenario returned a non-zero status"
fi

assert_contains "$tree_no_display_output" "コンテナ内ディレクトリツリーと JBoss EAP デプロイ構造は表示しません (--directory-tree で表示します)。"
assert_not_contains "$tree_no_display_output" "コンテナ内ディレクトリツリー (サービス: app"
assert_not_contains "$FAKE_DOCKER_CALLS" "exec cid-app find /"

# --report-dir が無い実行で --directory-tree-report を指定したら、書き出す先が無いと警告する。
tree_report_without_dir_output="$TEST_TMP/tree-report-without-dir.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --directory-tree-report
) >"$tree_report_without_dir_output" 2>&1; then
  cat "$tree_report_without_dir_output" >&2
  fail "--directory-tree-report without --report-dir unexpectedly returned a non-zero status"
fi
assert_contains "$tree_report_without_dir_output" "--directory-tree-report は --report-dir と併用してください"

invalid_startup_log_lines_output="$TEST_TMP/startup-log-lines-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --startup-log-lines 0
) >"$invalid_startup_log_lines_output" 2>&1; then
  cat "$invalid_startup_log_lines_output" >&2
  fail "invalid startup log line limit unexpectedly returned zero"
fi
assert_contains "$invalid_startup_log_lines_output" "--startup-log-lines には 1 以上の整数を指定してください: 0"

invalid_tree_depth_output="$TEST_TMP/tree-depth-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --directory-tree-depth 0
) >"$invalid_tree_depth_output" 2>&1; then
  cat "$invalid_tree_depth_output" >&2
  fail "invalid directory tree depth unexpectedly returned zero"
fi
assert_contains "$invalid_tree_depth_output" "--directory-tree-depth には 1 以上の整数を指定してください: 0"

invalid_file_limit_output="$TEST_TMP/file-limit-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --directory-file-limit 0
) >"$invalid_file_limit_output" 2>&1; then
  cat "$invalid_file_limit_output" >&2
  fail "invalid directory file limit unexpectedly returned zero"
fi
assert_contains "$invalid_file_limit_output" "--directory-file-limit には 1 以上の整数を指定してください: 0"

invalid_deployment_env_output="$TEST_TMP/deployment-env-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --deployment-dir-env 'INVALID-NAME'
) >"$invalid_deployment_env_output" 2>&1; then
  cat "$invalid_deployment_env_output" >&2
  fail "invalid deployment directory environment name unexpectedly returned zero"
fi
assert_contains "$invalid_deployment_env_output" "--deployment-dir-env に不正な環境変数名が指定されました: INVALID-NAME"

tree_find_failure_output="$TEST_TMP/tree-find-failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_DOCKER_FIND_FAIL="true"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree \
    --suppress-removed-logs
) >"$tree_find_failure_output" 2>&1; then
  cat "$tree_find_failure_output" >&2
  fail "missing container find command unexpectedly failed verification"
fi
unset FAKE_DOCKER_FIND_FAIL

assert_contains "$tree_find_failure_output" "コンテナ内ディレクトリツリーを取得できませんでした (サービス: app, コンテナ: test-app-1, ルート: /)"
assert_contains "$tree_find_failure_output" "ビルドおよび確認が完了しました。"

failure_output="$TEST_TMP/failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-failure.log"
# 起動確認対象 (app) 以外に、コンテナを持つサイドカー (adot-collector) と
# コンテナを持たない定義だけのサービス (base / cache) を混在させる。
export FAKE_COMPOSE_CONFIG_SERVICES="base app adot-collector cache"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector"
if (
  cd "$REPO_ROOT"
  unset NO_COLOR
  CLICOLOR_FORCE=1 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --report-dir "$TEST_TMP/failure-reports" \
    --exit-on-deploy-error \
    --suppress-removed-logs
) >"$failure_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$failure_output" >&2
  fail "failure fixture unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

assert_contains "$failure_output" "JBoss EAP 8.1 が正常起動しませんでした"
assert_contains "$failure_output" "コンテナ起動ログ (対象サービス: app, 末尾 5/5 行 (指定上限: 50)):"
assert_contains "$failure_output" $'\033[1;31mapp-1  | 09:18:00,100 ERROR'
assert_contains "$failure_output" "WFLYSRV0026"
assert_contains "$failure_output" "WFLYSRV0021"
assert_contains "$failure_output" "WFLYJCA0031"
assert_not_contains "$failure_output" "[デプロイエラー関連]"
assert_not_contains "$failure_output" "JNDI データソースエラー:"
assert_not_contains "$failure_output" "アプリケーションデプロイ結果ログ"
assert_not_contains "$failure_output" "起動完了を確認しました"
collect_report_files "$TEST_TMP/failure-reports"
failure_report_files=("${REPORT_FILES[@]}")
[ ${#failure_report_files[@]} -eq 1 ] && [ -f "${failure_report_files[0]}" ] \
  || fail "expected one report for failed verification"
assert_contains "${failure_report_files[0]}" "全体結果     : 失敗 (exit=1)"
assert_contains "${failure_report_files[0]}" "結果          : 成功"
# 失敗レポートには、起動確認対象・サイドカーを問わず全 Compose サービスのログを
# サービス単位に区切って残す。
assert_contains "${failure_report_files[0]}" "[9] Compose サービス別ログ (全サービス・全行)"
assert_contains "${failure_report_files[0]}" "対象サービス  : base app adot-collector cache (4 サービス)"
assert_contains "${failure_report_files[0]}" "[9-1] Compose サービス: base"
assert_contains "${failure_report_files[0]}" "[9-2] Compose サービス: app"
assert_contains "${failure_report_files[0]}" "[9-3] Compose サービス: adot-collector"
assert_contains "${failure_report_files[0]}" "[9-4] Compose サービス: cache"
assert_contains "${failure_report_files[0]}" "コンテナ      : test-app-1 (状態: running)"
assert_contains "${failure_report_files[0]}" "コンテナ      : adot-collector (状態: exited, 終了コード: 1)"
assert_contains "${failure_report_files[0]}" "ログ行数      : 5 行"
assert_contains "${failure_report_files[0]}" "ログ行数      : 1 行"
assert_contains "${failure_report_files[0]}" "ログ行数      : 2 行"
assert_contains "${failure_report_files[0]}" "WFLYSRV0026"
assert_contains "${failure_report_files[0]}" "adot-collector  | TracesExporter resource spans: 2, spans: 4"
assert_contains "${failure_report_files[0]}" "cache-1  | CACHE001: cache ready"
assert_before "${failure_report_files[0]}" "[9-1] Compose サービス: base" "[9-2] Compose サービス: app"
assert_before "${failure_report_files[0]}" "[9-2] Compose サービス: app" "[9-3] Compose サービス: adot-collector"
assert_before "${failure_report_files[0]}" "[9-3] Compose サービス: adot-collector" "[9-4] Compose サービス: cache"
assert_before "${failure_report_files[0]}" "[9-3] Compose サービス: adot-collector" "TracesExporter resource spans"
assert_before "${failure_report_files[0]}" "TracesExporter resource spans" "[9-4] Compose サービス: cache"
# レポートは画面表示の行数制限に影響されず、ANSI 色コードも残さない。
assert_not_contains "${failure_report_files[0]}" $'\033['
# --exit-on-deploy-error 指定時は調査用の対話操作へ入らず、コンテナも残さない。
assert_not_contains "$failure_output" "デプロイエラーを検出しました。コンテナと AP サーバは起動したまま残します。"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# ---- デプロイエラー時の調査モード (既定) ------------------------------------
# AP サーバは起動したがデプロイに失敗した場合、既定ではコンテナを残したまま
# 対話操作へ入り、各 Compose サービスへ接続して調査できる。
deploy_error_keep_output="$TEST_TMP/deploy-error-keep.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-failure.log"
export FAKE_COMPOSE_CONFIG_SERVICES="base app adot-collector"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector"
# 1) app を選択 → 1) ログ表示 → (継続) → 0) サービス選択へ戻る → 0) 対話操作を終了
if printf '1\n1\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$deploy_error_keep_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$deploy_error_keep_output" >&2
  fail "deploy error investigation mode unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

assert_contains "$deploy_error_keep_output" "JBoss EAP 8.1 が正常起動しませんでした"
assert_contains "$deploy_error_keep_output" "デプロイエラーを検出しました。コンテナと AP サーバは起動したまま残します。"
assert_contains "$deploy_error_keep_output" "コンテナ内を調査できるよう、対話操作 (logs) を開始します。"
# 成功後の対話操作と同じ Compose サービス選択メニューが出る
assert_contains "$deploy_error_keep_output" "操作する起動中の Compose サービスを選択してください:"
assert_contains "$deploy_error_keep_output" "デプロイエラーの調査用対話操作を終了しました。コンテナは起動状態のまま残します。"
# 調査できるようコンテナは残す (compose down も SIGTERM 停止も行わない)
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml stop"
assert_contains "$deploy_error_keep_output" "コンテナを残します (--keep-container)。"

# 端末から入力できない場合 (CI 等) は対話操作へ入れないため、従来どおり後始末する。
deploy_error_noinput_output="$TEST_TMP/deploy-error-noinput.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_CONFIG_SERVICES="base app adot-collector"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs < /dev/null
) >"$deploy_error_noinput_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$deploy_error_noinput_output" >&2
  fail "deploy error investigation without stdin unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

assert_contains "$deploy_error_noinput_output" "デプロイエラーを検出しました。コンテナと AP サーバは起動したまま残します。"
assert_contains "$deploy_error_noinput_output" "対話操作を開始できなかったため、通常のエラー終了として後始末します。"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# adot collector の healthcheck 失敗で depends_on: service_healthy を満たせず、
# compose up が失敗する状況。ECS のタスク停止と同じく SIGTERM で終了させ、
# サイドカーの終了処理ログまで画面とレポートへ残す。
shutdown_logs_output="$TEST_TMP/shutdown-logs.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_COMPOSE_CONFIG_SERVICES="base app adot-collector"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector"
export FAKE_COMPOSE_UP_FAIL="true"
export FAKE_COMPOSE_SHUTDOWN_MARKER="$TEST_TMP/compose-stopped"
rm -f "$FAKE_COMPOSE_SHUTDOWN_MARKER"
if (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app,adot-collector \
    --startup-service app \
    --wait-healthy \
    --no-up-retry \
    --report-dir "$TEST_TMP/shutdown-reports"
) >"$shutdown_logs_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL
  unset FAKE_COMPOSE_SHUTDOWN_MARKER
  cat "$shutdown_logs_output" >&2
  fail "unhealthy dependency scenario unexpectedly returned zero"
fi

assert_contains "$shutdown_logs_output" "コンテナの起動に失敗しました (compose up)"
assert_contains "$shutdown_logs_output" "エラー終了のため、ECS のタスク停止と同じく SIGTERM でコンテナを終了させ、終了処理のログを取得します (compose stop -t 30, 対象: app adot-collector)"
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml stop -t 30'
# サイドカーは SIGTERM 受信後の graceful shutdown ログまで表示する。
assert_contains "$shutdown_logs_output" "終了 (SIGTERM) 時のコンテナログ (サービス: adot-collector, 追加 3 行):"
assert_contains "$shutdown_logs_output" 'Received signal from OS {"signal": "terminated"}'
assert_contains "$shutdown_logs_output" "Shutdown complete."
# 終了ログを出さないコンテナは、その旨を明示して差分なしと分かるようにする。
assert_contains "$shutdown_logs_output" "終了 (SIGTERM) 時のコンテナログ (サービス: app, 追加 0 行):"
assert_contains "$shutdown_logs_output" "SIGTERM 受信後に追加されたログはありません。"
assert_before "$shutdown_logs_output" \
  "終了 (SIGTERM) 時のコンテナログ (サービス: app" \
  "終了 (SIGTERM) 時のコンテナログ (サービス: adot-collector"
collect_report_files "$TEST_TMP/shutdown-reports"
shutdown_reports=("${REPORT_FILES[@]}")
[ ${#shutdown_reports[@]} -eq 1 ] && [ -f "${shutdown_reports[0]}" ] \
  || fail "expected one report for unhealthy dependency scenario"
# 全量レポートのログ本文も、SIGTERM 送出後に取得した終了処理込みのものとなる。
assert_contains "${shutdown_reports[0]}" "終了処理      : SIGTERM (compose stop -t 30) 送出後の終了ログまで含む"
assert_contains "${shutdown_reports[0]}" "[9-3] Compose サービス: adot-collector"
assert_contains "${shutdown_reports[0]}" "Shutdown complete."
assert_contains "${shutdown_reports[0]}" "ログ行数      : 4 行"

# --no-shutdown-logs 指定時は SIGTERM 停止も終了ログの取得も行わない。
no_shutdown_logs_output="$TEST_TMP/no-shutdown-logs.out"
: > "$FAKE_DOCKER_CALLS"
rm -f "$FAKE_COMPOSE_SHUTDOWN_MARKER"
if (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app,adot-collector \
    --startup-service app \
    --wait-healthy \
    --no-up-retry \
    --no-shutdown-logs
) >"$no_shutdown_logs_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL
  unset FAKE_COMPOSE_SHUTDOWN_MARKER
  cat "$no_shutdown_logs_output" >&2
  fail "--no-shutdown-logs scenario unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL
unset FAKE_COMPOSE_SHUTDOWN_MARKER

assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml stop"
assert_not_contains "$no_shutdown_logs_output" "終了 (SIGTERM) 時のコンテナログ"

# =============================================================================
# コールド実行 (docker のイメージ・キャッシュを削除した直後) への対策
# -----------------------------------------------------------------------------
# ウォーム実行ではローカルのイメージで飛ばしている取得処理が、コールド実行では
# 実際に走る。そこでの一過性エラーや、依存サービスが healthy になるまでの遅れが
# そのまま compose up の失敗になり、再実行だけで直る事象への対策を確認する。
# =============================================================================

# --- 事前取得が一過性エラーで失敗しても、再試行して起動まで進むこと ---
cold_pull_retry_output="$TEST_TMP/cold-pull-retry.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_COMPOSE_CONFIG_SERVICES="base app"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_COMPOSE_PULL_COUNTER="$TEST_TMP/cold-pull.count"
export FAKE_COMPOSE_PULL_FAIL_TIMES="1"
rm -f "$FAKE_COMPOSE_PULL_COUNTER"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --pull-retry-interval 0 \
    --report-dir "$TEST_TMP/cold-pull-reports"
) >"$cold_pull_retry_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES \
        FAKE_COMPOSE_PULL_COUNTER FAKE_COMPOSE_PULL_FAIL_TIMES
  cat "$cold_pull_retry_output" >&2
  fail "transient pull failure should be retried and succeed"
fi
unset FAKE_COMPOSE_PULL_COUNTER FAKE_COMPOSE_PULL_FAIL_TIMES

# 取得は compose up 任せにせず、事前に切り出して実行する。
# ビルド対象のイメージはレジストリに無いため --ignore-buildable で除外し、
# 取得済みのイメージは問い合わせないよう --policy missing を付ける。
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml pull --ignore-buildable --policy missing app"
assert_contains "$cold_pull_retry_output" "起動に必要なイメージを取得します (compose pull, 未取得のイメージのみ) ..."
assert_contains "$cold_pull_retry_output" "イメージの取得に失敗しました (レジストリ / ネットワークの一過性エラー)"
assert_contains "$cold_pull_retry_output" "イメージの取得を再試行します (試行 2/3) ..."
assert_contains "$cold_pull_retry_output" "イメージの取得が完了しました。"
# 取得は compose up より前に終わっていること (起動と取得の I/O を競合させない)。
assert_before "$cold_pull_retry_output" \
  "イメージの取得が完了しました。" \
  "コンテナを同時に起動します (compose up -d, 対象サービス: app)"
collect_report_files "$TEST_TMP/cold-pull-reports"
cold_pull_reports=("${REPORT_FILES[@]}")
[ ${#cold_pull_reports[@]} -eq 1 ] || fail "expected one report for the cold pull scenario"
assert_contains "${cold_pull_reports[0]}" "イメージ取得  : 成功 (試行 2 回)"
assert_contains "${cold_pull_reports[0]}" "コンテナ起動  : 成功 (試行 1 回)"
assert_matches "${cold_pull_reports[0]}" '^開始時の Docker: ローカルイメージ [0-9]+ 件$'

# --- 事前取得が直らない失敗でも、警告に留めて compose up まで進むこと ---
# オフラインでイメージを投入済みの環境など、取得できなくても起動できる構成を
# この段の追加で壊さないことの確認。
cold_pull_giveup_output="$TEST_TMP/cold-pull-giveup.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PULL_COUNTER="$TEST_TMP/cold-pull-giveup.count"
export FAKE_COMPOSE_PULL_FAIL_TIMES="9"
export FAKE_COMPOSE_PULL_FAIL_MODE="fatal"
rm -f "$FAKE_COMPOSE_PULL_COUNTER"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --pull-retry 1 \
    --pull-retry-interval 0
) >"$cold_pull_giveup_output" 2>&1; then
  unset FAKE_COMPOSE_PULL_COUNTER FAKE_COMPOSE_PULL_FAIL_TIMES FAKE_COMPOSE_PULL_FAIL_MODE
  cat "$cold_pull_giveup_output" >&2
  fail "pull failure should not abort the run"
fi
unset FAKE_COMPOSE_PULL_COUNTER FAKE_COMPOSE_PULL_FAIL_TIMES FAKE_COMPOSE_PULL_FAIL_MODE
assert_contains "$cold_pull_giveup_output" "イメージの事前取得に失敗しました (一過性と判断できないエラー)。"
assert_contains "$cold_pull_giveup_output" "取得できなかったイメージは compose up 側で再度取得が試みられます。"
# 一過性ではないため再試行せず 1 回で切り上げる。
assert_occurrences "$FAKE_DOCKER_CALLS" "compose -f compose.yml pull --ignore-buildable --policy missing app" 1
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml up -d --no-build app"

# --- 事前取得のオプションを持たない compose では、素の pull を発行すること ---
cold_pull_legacy_output="$TEST_TMP/cold-pull-legacy.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PULL_NO_OPTIONS="true"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --verify-startup --compose-service app --startup-service app
) >"$cold_pull_legacy_output" 2>&1; then
  unset FAKE_COMPOSE_PULL_NO_OPTIONS
  cat "$cold_pull_legacy_output" >&2
  fail "legacy compose pull scenario unexpectedly returned non-zero"
fi
unset FAKE_COMPOSE_PULL_NO_OPTIONS
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml pull app"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml pull --ignore-buildable"

# --- --no-pull-images では事前取得を行わないこと ---
no_pull_output="$TEST_TMP/no-pull-images.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --no-pull-images \
    --report-dir "$TEST_TMP/no-pull-reports"
) >"$no_pull_output" 2>&1; then
  cat "$no_pull_output" >&2
  fail "--no-pull-images scenario unexpectedly returned non-zero"
fi
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml pull"
assert_not_contains "$no_pull_output" "起動に必要なイメージを取得します"
collect_report_files "$TEST_TMP/no-pull-reports"
no_pull_reports=("${REPORT_FILES[@]}")
[ ${#no_pull_reports[@]} -eq 1 ] || fail "expected one report for the --no-pull-images scenario"
assert_contains "${no_pull_reports[0]}" "イメージ取得  : 未実行 (--no-pull-images)"

# --- 依存サービスが healthy にならず失敗しても、診断を出して再試行すること ---
# コールド実行では DB の初期化やモックの JVM 起動が healthcheck の猶予を超え、
# 1 回目だけ失敗して再実行すると成功する。利用者が手作業でやり直している
# 再実行を、失敗の種類を判定したうえで自動で行う。
cold_up_retry_output="$TEST_TMP/cold-up-retry.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_UP_COUNTER="$TEST_TMP/cold-up.count"
export FAKE_COMPOSE_UP_FAIL_TIMES="1"
export FAKE_HEALTHCHECK_STATE_FAIL="true"
rm -f "$FAKE_COMPOSE_UP_COUNTER"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --up-retry-interval 0 \
    --report-dir "$TEST_TMP/cold-up-reports"
) >"$cold_up_retry_output" 2>&1; then
  unset FAKE_COMPOSE_UP_COUNTER FAKE_COMPOSE_UP_FAIL_TIMES FAKE_HEALTHCHECK_STATE_FAIL
  cat "$cold_up_retry_output" >&2
  fail "cold start up failure should be retried and succeed"
fi
unset FAKE_COMPOSE_UP_COUNTER FAKE_COMPOSE_UP_FAIL_TIMES FAKE_HEALTHCHECK_STATE_FAIL

assert_contains "$cold_up_retry_output" "コンテナ起動失敗の診断 (compose up)"
assert_contains "$cold_up_retry_output" "失敗の分類          : 依存サービスが期限内に healthy にならなかった"
assert_matches "$cold_up_retry_output" '実行開始時の Docker : ローカルイメージ [0-9]+ 件'
# コンテナを削除する前に、どのサービスが unhealthy なのかまで採取する。
assert_contains "$cold_up_retry_output" "[app] healthcheck: 状態 unhealthy / 連続失敗 3 回"
assert_contains "$cold_up_retry_output" "コンテナの起動を再試行します (試行 2/2) ..."
assert_contains "$cold_up_retry_output" "再試行でコンテナの起動に成功しました (試行 2 回目)。"
assert_occurrences "$FAKE_DOCKER_CALLS" "compose -f compose.yml up -d --no-build app" 2
collect_report_files "$TEST_TMP/cold-up-reports"
cold_up_reports=("${REPORT_FILES[@]}")
[ ${#cold_up_reports[@]} -eq 1 ] || fail "expected one report for the cold up retry scenario"
assert_contains "${cold_up_reports[0]}" "コンテナ起動  : 成功 (試行 2 回)"

# --- 一過性と判断できない失敗は再試行せず、その場で終了すること ---
fatal_up_output="$TEST_TMP/cold-up-fatal.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_UP_COUNTER="$TEST_TMP/fatal-up.count"
export FAKE_COMPOSE_UP_FAIL_TIMES="1"
export FAKE_COMPOSE_UP_FAIL_MODE="fatal"
rm -f "$FAKE_COMPOSE_UP_COUNTER"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --up-retry-interval 0 \
    --no-shutdown-logs \
    --report-dir "$TEST_TMP/fatal-up-reports"
) >"$fatal_up_output" 2>&1; then
  unset FAKE_COMPOSE_UP_COUNTER FAKE_COMPOSE_UP_FAIL_TIMES FAKE_COMPOSE_UP_FAIL_MODE
  cat "$fatal_up_output" >&2
  fail "fatal compose up failure unexpectedly returned zero"
fi
unset FAKE_COMPOSE_UP_COUNTER FAKE_COMPOSE_UP_FAIL_TIMES FAKE_COMPOSE_UP_FAIL_MODE
assert_contains "$fatal_up_output" "失敗の分類          : 一過性と判断できないエラー"
assert_contains "$fatal_up_output" "コンテナの起動に失敗しました (compose up)"
# やり直しても直らない失敗は 1 回で切り上げる。
assert_occurrences "$FAKE_DOCKER_CALLS" "compose -f compose.yml up -d --no-build app" 1
collect_report_files "$TEST_TMP/fatal-up-reports"
fatal_up_reports=("${REPORT_FILES[@]}")
[ ${#fatal_up_reports[@]} -eq 1 ] || fail "expected one report for the fatal up scenario"
assert_contains "${fatal_up_reports[0]}" "コンテナ起動  : 失敗 (試行 1 回, 分類: 一過性と判断できないエラー)"

# --- 再試行の回数指定を検証すること ---
invalid_up_retry_output="$TEST_TMP/up-retry-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --up-retry -1
) >"$invalid_up_retry_output" 2>&1; then
  cat "$invalid_up_retry_output" >&2
  fail "invalid --up-retry unexpectedly returned zero"
fi
assert_contains "$invalid_up_retry_output" "--up-retry には 0 以上の整数を指定してください: -1"

# --- 前回の実行が残したコンテナの点検 (ウォーム再実行) -----------------------
# --keep-container 系でコンテナを残したまま再実行すると、前回のコンテナと
# 今回のコンテナが混在して依存待ち・名前解決が壊れる。compose up の前に点検し、
# 壊れた状態のものだけを --force-recreate で作り直すこと。
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_STALE_NETWORKS="net_default=net-aaa"
export FAKE_STALE_IMAGES="app-image=sha256:img-app mysql:8.4.7=sha256:img-mysql"

# 停止したまま残っているコンテナは作り直す。
stale_exited_output="$TEST_TMP/stale-exited.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_STALE_CONTAINERS='cid-app|app|/app|running|healthy|sha256:img-app|app-image|net_default=net-aaa
cid-mysql|mysql|/mysql|exited||sha256:img-mysql|mysql:8.4.7|net_default=net-aaa '
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --report-dir "$TEST_TMP/stale-exited-reports" \
    --suppress-removed-logs
) >"$stale_exited_output" 2>&1; then
  unset FAKE_STALE_CONTAINERS FAKE_STALE_NETWORKS FAKE_STALE_IMAGES
  cat "$stale_exited_output" >&2
  fail "stale container scenario returned a non-zero status"
fi
assert_contains "$stale_exited_output" "前回の実行が残したコンテナに、起動確認を壊す状態のものがあります:"
assert_contains "$stale_exited_output" "mysql (mysql): 前回の状態 'exited' のまま残っています"
assert_contains "$stale_exited_output" "該当コンテナを compose up で作り直します (--force-recreate)。"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml up -d --no-build --force-recreate app"
collect_report_files "$TEST_TMP/stale-exited-reports"
stale_exited_reports=("${REPORT_FILES[@]}")
[ ${#stale_exited_reports[@]} -eq 1 ] || fail "expected one report for the stale container scenario"
assert_contains "${stale_exited_reports[0]}" "既存コンテナ  : 問題 1 件を検出したため --force-recreate で作り直し"

# 消えたネットワークへ繋がったまま (running / healthy でも名前解決できない) も作り直す。
stale_network_output="$TEST_TMP/stale-network.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_STALE_CONTAINERS='cid-mysql|mysql|/mysql|running|healthy|sha256:img-mysql|mysql:8.4.7|net_removed=net-old '
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-removed-logs
) >"$stale_network_output" 2>&1; then
  unset FAKE_STALE_CONTAINERS FAKE_STALE_NETWORKS FAKE_STALE_IMAGES
  cat "$stale_network_output" >&2
  fail "stale network scenario returned a non-zero status"
fi
assert_contains "$stale_network_output" "既に存在しないネットワーク 'net_removed' へ接続されたままです"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml up -d --no-build --force-recreate app"

# --no-recreate-containers では検出だけ行い、作り直さないこと。
stale_keep_output="$TEST_TMP/stale-keep.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --no-recreate-containers \
    --suppress-removed-logs
) >"$stale_keep_output" 2>&1; then
  unset FAKE_STALE_CONTAINERS FAKE_STALE_NETWORKS FAKE_STALE_IMAGES
  cat "$stale_keep_output" >&2
  fail "--no-recreate-containers scenario returned a non-zero status"
fi
assert_contains "$stale_keep_output" "--no-recreate-containers が指定されているため、そのまま再利用します。"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml up -d --no-build app"
assert_not_contains "$FAKE_DOCKER_CALLS" "--force-recreate"
unset FAKE_STALE_CONTAINERS FAKE_STALE_NETWORKS FAKE_STALE_IMAGES

# --recreate-containers は点検の結果によらず必ず作り直すこと。
stale_always_output="$TEST_TMP/stale-always.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --recreate-containers \
    --suppress-removed-logs
) >"$stale_always_output" 2>&1; then
  cat "$stale_always_output" >&2
  fail "--recreate-containers scenario returned a non-zero status"
fi
assert_contains "$stale_always_output" "前回の実行が残したコンテナは --force-recreate で必ず作り直します。"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml up -d --no-build --force-recreate app"

# --- 名前解決の失敗 (UnknownHostException) の切り分け ------------------------
# 「ホストが見つからない」は接続先名の誤りに見えるが、Compose 構成では依存
# サービスのコンテナが存在しないことが原因であることが多い。ログを出すだけでなく、
# compose の定義とコンテナの状態を突き合わせて示すこと。
unknown_host_output="$TEST_TMP/unknown-host.out"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-unknown-host.log"
export FAKE_COMPOSE_CONFIG_SERVICES="app mysql"
export FAKE_COMPOSE_PS_SERVICES="app mysql"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --no-shutdown-logs \
    --suppress-removed-logs
) >"$unknown_host_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$unknown_host_output" >&2
  fail "unknown host fixture unexpectedly returned zero"
fi
assert_contains "$unknown_host_output" "名前解決の失敗の切り分け"
assert_contains "$unknown_host_output" "解決できなかったホスト名: mysql"
assert_contains "$unknown_host_output" "compose の定義  : サービス 'mysql' として定義されています"

# --- 残っているデータ用ボリュームが壊れている場合の診断 ----------------------
# 前回の実行が DB の初期化中に停止すると、以後は down -v するまで毎回失敗する。
# compose up の失敗診断で、その兆候と down -v の案内まで出すこと。
broken_volume_output="$TEST_TMP/broken-volume.out"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/mysql-broken-data-volume.log"
export FAKE_COMPOSE_UP_FAIL=true
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --no-up-retry \
    --no-shutdown-logs \
    --suppress-removed-logs
) >"$broken_volume_output" 2>&1; then
  unset FAKE_COMPOSE_UP_FAIL FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$broken_volume_output" >&2
  fail "broken data volume fixture unexpectedly returned zero"
fi
unset FAKE_COMPOSE_UP_FAIL
assert_contains "$broken_volume_output" "残っているデータ用ボリュームが壊れている可能性があります:"
assert_contains "$broken_volume_output" "data directory has files in it"
assert_contains "$broken_volume_output" "対処 (ボリュームのデータは消えます):"
assert_contains "$broken_volume_output" "docker compose -f compose.yml down -v"
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"

unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

invalid_shutdown_timeout_output="$TEST_TMP/shutdown-timeout-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --shutdown-timeout 0
) >"$invalid_shutdown_timeout_output" 2>&1; then
  cat "$invalid_shutdown_timeout_output" >&2
  fail "invalid shutdown timeout unexpectedly returned zero"
fi
assert_contains "$invalid_shutdown_timeout_output" "--shutdown-timeout には 1 以上の整数を指定してください: 0"

build_failure_output="$TEST_TMP/build-failure.out"
export FAKE_DOCKER_BUILD_FAIL="true"
export FAKE_COMPOSE_CONFIG_SERVICES="base app adot-collector"
export FAKE_COMPOSE_NO_CONTAINERS="true"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --report-dir "$TEST_TMP/build-failure-reports"
) >"$build_failure_output" 2>&1; then
  unset FAKE_DOCKER_BUILD_FAIL FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_NO_CONTAINERS
  cat "$build_failure_output" >&2
  fail "failed compose build unexpectedly returned zero"
fi
unset FAKE_DOCKER_BUILD_FAIL FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_NO_CONTAINERS
assert_contains "$build_failure_output" "compose build に失敗しました"
collect_report_files "$TEST_TMP/build-failure-reports"
build_failure_reports=("${REPORT_FILES[@]}")
[ ${#build_failure_reports[@]} -eq 1 ] && [ -f "${build_failure_reports[0]}" ] \
  || fail "expected one report for failed compose build"
assert_contains "${build_failure_reports[0]}" "全体結果     : 失敗 (exit=1)"
assert_contains "${build_failure_reports[0]}" "結果          : 失敗"
assert_contains "${build_failure_reports[0]}" "対象コンテナが起動していないため取得していません。"
# ビルド失敗でコンテナが 1 つも作られていない場合も、compose.yml 定義の全サービスを
# 見出しとして残し、ログがないことを明示する。
assert_contains "${build_failure_reports[0]}" "[9] Compose サービス別ログ (全サービス・全行)"
assert_contains "${build_failure_reports[0]}" "取得範囲      : コンテナ作成時からの全期間 (compose up 到達前に終了)"
assert_contains "${build_failure_reports[0]}" "対象サービス  : base app adot-collector (3 サービス)"
assert_contains "${build_failure_reports[0]}" "[9-1] Compose サービス: base"
assert_contains "${build_failure_reports[0]}" "[9-2] Compose サービス: app"
assert_contains "${build_failure_reports[0]}" "[9-3] Compose サービス: adot-collector"
assert_occurrences "${build_failure_reports[0]}" "コンテナ      : (コンテナなし)" 3
assert_occurrences "${build_failure_reports[0]}" "(このサービスのログはありません)" 3
# ビルド失敗で compose up まで到達しなかった場合も Java 例外解析は必ず実行し、
# 「0 件検出」ではなく「未評価」として理由まで残す。
# 画面表示は既定で行わないため (--deploy-exception-display 未指定)、結果が残るのは
# 全量レポートの [10] だけになる。Excel もテキストも既定では出力しない。
if ! grep -Fq "Java 例外解析をスキップしました: Python 3 が見つかりません" "$build_failure_output"; then
  assert_not_contains "$build_failure_output" \
    "WAR デプロイ時 Java 例外解析: コンテナ起動 (compose up) まで到達しなかったため、解析対象のログがありません"
  assert_contains "${build_failure_reports[0]}" "[10] WAR デプロイ時 Java 例外解析"
  assert_contains "${build_failure_reports[0]}" \
    "ログ取得状況  : コンテナ起動 (compose up) まで到達しなかったため、解析対象のログがありません"
  assert_contains "${build_failure_reports[0]}" "総合判定      : 未評価 (解析対象のログが無いため判定できません)"
  assert_not_contains "${build_failure_reports[0]}" "総合判定      : OK (Java 例外は検出されませんでした)"
  assert_contains "${build_failure_reports[0]}" "解析対象のログが 1 行も無いため、Java 例外の有無を判定できていません。"
  build_failure_books=("$TEST_TMP/build-failure-reports"/build_and_verify_*_java_exceptions.xlsx)
  [ ! -e "${build_failure_books[0]}" ] \
    || fail "did not expect a java exception workbook without --deploy-exception-excel"
  build_failure_texts=("$TEST_TMP/build-failure-reports"/build_and_verify_*_java_exceptions.txt)
  [ ! -e "${build_failure_texts[0]}" ] \
    || fail "did not expect a java exception text file without --deploy-exception-text"
fi

# JVM を実行しないコンテナ (OTel Collector / DB など) でも、Java プロセス無しを
# 明示したうえで OpenTelemetry の環境変数側は同じ形式で一覧化する。
no_java_output="$TEST_TMP/no-java-process.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_DOCKER_NO_JAVA_PROCESS="true"
if ! (
  cd "$REPO_ROOT"
  CLICOLOR_FORCE=0 bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$no_java_output" 2>&1; then
  unset FAKE_DOCKER_NO_JAVA_PROCESS
  cat "$no_java_output" >&2
  fail "non-java container scenario returned a non-zero status"
fi
unset FAKE_DOCKER_NO_JAVA_PROCESS

assert_contains "$no_java_output" "Java JVM パラメータ (サービス: app, コンテナ: test-app-1, Java プロセス: 0)"
assert_contains "$no_java_output" "Java プロセスを検出できませんでした。"
assert_not_contains "$no_java_output" "[Java プロセス 1] PID:"
assert_contains "$no_java_output" "[OpenTelemetry 標準環境変数 (OTEL_*)] 4 件"
assert_contains "$no_java_output" "[OpenTelemetry 関連 JVM パラメータ (コマンドライン)] 0 件"
assert_contains "$no_java_output" "[OpenTelemetry 関連 JVM パラメータ (環境変数由来)] 1 件"

invalid_keep_mode_output="$TEST_TMP/keep-mode-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --keep-container-mode invalid
) >"$invalid_keep_mode_output" 2>&1; then
  cat "$invalid_keep_mode_output" >&2
  fail "invalid keep-container mode unexpectedly returned zero"
fi
assert_contains "$invalid_keep_mode_output" "--keep-container-mode には bash、http または logs を指定してください: invalid"

invalid_http_port_output="$TEST_TMP/keep-mode-http-invalid-port.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --dry-run \
    --keep-container-mode http \
    --jboss-http-port 65536
) >"$invalid_http_port_output" 2>&1; then
  cat "$invalid_http_port_output" >&2
  fail "invalid JBoss HTTP port unexpectedly returned zero"
fi
assert_contains "$invalid_http_port_output" "--jboss-http-port には 1 から 65535 の範囲を指定してください: 65536"

bash_mode_output="$TEST_TMP/keep-mode-bash.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --keep-container-mode bash \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$bash_mode_output" 2>&1; then
  cat "$bash_mode_output" >&2
  fail "bash keep-container mode returned a non-zero status"
fi

assert_contains "$bash_mode_output" "検証対象コンテナの bash へ接続します"
assert_contains "$bash_mode_output" \
  "ディレクトリ構造を確認できるよう、tree コマンドを使える状態にしてから開始します。"
assert_contains "$bash_mode_output" "bash セッションを終了しました。コンテナは起動状態を維持します"
assert_contains "$bash_mode_output" "コンテナを残します (--keep-container)"
# 素の bash ではなく、tree を用意するセッションスクリプト経由で起動する。
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-app /bin/bash -c"
assert_contains "$FAKE_DOCKER_CALLS" "_bv_tree_main"
assert_contains "$FAKE_DOCKER_CALLS" "tree コマンドが利用できます"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

logs_mode_output="$TEST_TMP/keep-mode-logs.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_USAGE_CHECK_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app db"
if ! printf 'invalid\n3\n2\ninvalid\n1\n\n0\n1\n2\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,db \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$logs_mode_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$logs_mode_output" >&2
  fail "Compose service action keep-container mode returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_occurrences "$logs_mode_output" "操作する起動中の Compose サービスを選択してください:" 3
assert_occurrences "$logs_mode_output" "  1) app" 3
assert_occurrences "$logs_mode_output" "  2) db" 3
assert_occurrences "$logs_mode_output" "0 から 2 の番号を入力してください。" 2
assert_occurrences "$logs_mode_output" "0 から 3 の番号を入力してください。" 1
assert_occurrences "$logs_mode_output" "Compose サービス 'db' で実行する操作を選択してください:" 3
assert_occurrences "$logs_mode_output" "Compose サービス 'app' で実行する操作を選択してください:" 3
assert_occurrences "$logs_mode_output" "  1) ログを表示" 6
assert_occurrences "$logs_mode_output" "  2) bash へ接続 (cd・tree・任意コマンドを実行可能)" 6
assert_occurrences "$logs_mode_output" "  3) healthcheck 設定・実行履歴・通信を確認" 6
assert_not_contains "$logs_mode_output" "MySQL クライアントへ接続 (SQL クエリを対話実行)"
assert_occurrences "$logs_mode_output" "Compose サービスログ (サービス:" 1
assert_contains "$logs_mode_output" "Compose サービスログ (サービス: db, 末尾 50/52 行 (指定上限: 50)):"
assert_contains "$logs_mode_output" "DB003: companion service log"
assert_contains "$logs_mode_output" "DB052: companion service log"
assert_not_contains "$logs_mode_output" "DB001: companion service log"
assert_not_contains "$logs_mode_output" "DB002: companion service log"
assert_contains "$logs_mode_output" "Compose サービスの bash へ接続します (service=app, container=test-app-1)。"
assert_contains "$logs_mode_output" "この bash セッション内では cd によるディレクトリ移動と任意のコマンド実行が可能です。"
assert_contains "$logs_mode_output" \
  "ディレクトリ構造を確認できるよう、tree コマンドを使える状態にしてから開始します。"
assert_contains "$logs_mode_output" "bash セッションを終了しました。サービス操作の選択へ戻ります。"
assert_contains "$logs_mode_output" "Docker healthcheck 診断"
assert_contains "$logs_mode_output" "Compose サービス : app"
assert_contains "$logs_mode_output" "curl -fs http://127.0.0.1:8080/health >/dev/null || exit 1"
assert_contains "$logs_mode_output" "現在状態       : healthy"
assert_contains "$logs_mode_output" "連続失敗回数   : 0"
assert_contains "$logs_mode_output" "保持された履歴 : 2 件"
assert_contains "$logs_mode_output" "healthcheck request completed"
assert_contains "$logs_mode_output" "手動再実行結果 : OK"
assert_contains "$logs_mode_output" "実行上限   : 60 秒 (--url-timeout)"
assert_contains "$logs_mode_output" "[HTTP healthcheck 通信詳細（補助リクエスト）]"
assert_contains "$logs_mode_output" "リクエスト : [GET] http://127.0.0.1:8080/health"
assert_contains "$logs_mode_output" "HTTP/1.1 200 OK"
assert_contains "$logs_mode_output" 'Set-Cookie: [REDACTED]'
assert_contains "$logs_mode_output" '"status":"UP","token":"[REDACTED]"'
assert_not_contains "$logs_mode_output" "response-cookie-secret"
assert_not_contains "$logs_mode_output" "response-token-secret"
assert_contains "$logs_mode_output" "http_status=200"
assert_contains "$logs_mode_output" "remote=127.0.0.1:8080"
assert_before "$logs_mode_output" "Compose サービスログ (サービス: db" "Compose サービスの bash へ接続します (service=app"
assert_contains "$logs_mode_output" "Compose サービス 'db' の操作を終了し、サービス選択へ戻ります。"
assert_contains "$logs_mode_output" "Compose サービス 'app' の操作を終了し、サービス選択へ戻ります。"
assert_contains "$logs_mode_output" "Compose サービスの対話操作を終了しました。"
# 対話操作をすべて終えた場合は、既定でコンテナを残さず compose down し、
# 未使用リソースの完全クリアと空き容量の一覧まで行う。
assert_contains "$logs_mode_output" "対話操作をすべて終了したため、コンテナを残さず後始末します。"
assert_contains "$logs_mode_output" "対話操作をすべて終了したため、未使用リソースを含めて完全クリアします。"
assert_contains "$logs_mode_output" "未使用リソースを含む Docker の完全クリアが完了しました。"
assert_contains "$logs_mode_output" "各ディレクトリのディスク空き容量"
assert_contains "$logs_mode_output" "用途"
assert_contains "$logs_mode_output" "一時ディレクトリ"
assert_contains "$FAKE_USAGE_CHECK_CALLS" "--clean all --force"
assert_not_contains "$logs_mode_output" "コンテナを残します (--keep-container)"
assert_before "$logs_mode_output" "Compose サービスの対話操作を終了しました。" \
    "各ディレクトリのディスク空き容量"
assert_occurrences "$FAKE_DOCKER_CALLS" "compose -f compose.yml ps --services" 3
assert_matches "$FAKE_DOCKER_CALLS" 'compose -f compose\.yml logs --no-color --since [^ ]+ db'
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-app /bin/bash"
assert_contains "$FAKE_DOCKER_CALLS" ".Config.Healthcheck.Test"
assert_contains "$FAKE_DOCKER_CALLS" ".State.Health.Log"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-app /bin/sh -c curl -fs http://127.0.0.1:8080/health >/dev/null || exit 1"
assert_contains "$FAKE_DOCKER_CALLS" "healthcheck-http-probe http://127.0.0.1:8080/health 60 GET"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# ---- 対話操作の終了後クリーンアップを抑止する ------------------------------
# --keep-container-after-interaction を指定すると、対話操作を終えても従来どおり
# コンテナを残し、完全クリアも空き容量の一覧も行わない。
keep_after_interaction_output="$TEST_TMP/keep-mode-logs-keep-after.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_USAGE_CHECK_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app"
if ! printf '0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode logs \
    --keep-container-after-interaction \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$keep_after_interaction_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$keep_after_interaction_output" >&2
  fail "--keep-container-after-interaction returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$keep_after_interaction_output" "Compose サービスの対話操作を終了しました。"
assert_contains "$keep_after_interaction_output" "コンテナを残します (--keep-container)"
assert_not_contains "$keep_after_interaction_output" "未使用リソースを含めて完全クリアします"
assert_not_contains "$keep_after_interaction_output" "各ディレクトリのディスク空き容量"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"
[ ! -s "$FAKE_USAGE_CHECK_CALLS" ] \
  || fail "docker-usage-check.sh was called despite --keep-container-after-interaction"

# --keep-container を明示した場合も、対話操作の終了後にコンテナを残す。
explicit_keep_output="$TEST_TMP/keep-mode-logs-explicit-keep.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_USAGE_CHECK_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app"
if ! printf '0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$explicit_keep_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$explicit_keep_output" >&2
  fail "explicit --keep-container with logs mode returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$explicit_keep_output" "コンテナを残します (--keep-container)"
assert_not_contains "$explicit_keep_output" "未使用リソースを含めて完全クリアします"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"
[ ! -s "$FAKE_USAGE_CHECK_CALLS" ] \
  || fail "docker-usage-check.sh was called despite an explicit --keep-container"

# 完全クリアに失敗したときは、警告ではなくエラーとして終了コード 1 にする。
usage_check_failure_output="$TEST_TMP/keep-mode-logs-clean-failure.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_USAGE_CHECK_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_USAGE_CHECK_FAIL="true"
if printf '0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$usage_check_failure_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_USAGE_CHECK_FAIL
  cat "$usage_check_failure_output" >&2
  fail "failed usage-check cleanup unexpectedly returned zero"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_USAGE_CHECK_FAIL

assert_contains "$usage_check_failure_output" "未使用リソースの完全クリアに失敗しました"
assert_contains "$usage_check_failure_output" "docker-usage-check.sh は docker と jq を必要とします"
# 失敗しても空き容量の一覧までは出す (どこが逼迫しているかは知りたいため)。
assert_contains "$usage_check_failure_output" "各ディレクトリのディスク空き容量"
assert_contains "$FAKE_USAGE_CHECK_CALLS" "--clean all --force"

# 読み取れないパスを --usage-check-script へ渡した場合は、実行前に弾く。
missing_usage_check_output="$TEST_TMP/usage-check-missing.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --usage-check-script "$TEST_TMP/no-such-usage-check.sh"
) >"$missing_usage_check_output" 2>&1; then
  cat "$missing_usage_check_output" >&2
  fail "unreadable --usage-check-script unexpectedly returned zero"
fi
assert_contains "$missing_usage_check_output" \
    "--usage-check-script のスクリプトを読み取れません:"

no_healthcheck_output="$TEST_TMP/keep-mode-no-healthcheck.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="nohealth"
if ! printf '1\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service nohealth \
    --startup-service nohealth \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$no_healthcheck_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$no_healthcheck_output" >&2
  fail "service without a healthcheck returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$no_healthcheck_output" "Compose サービス : nohealth"
assert_contains "$no_healthcheck_output" "設定             : healthcheck は設定されていません。"
assert_contains "$no_healthcheck_output" "Docker 実行履歴  : 対象外"
assert_not_contains "$FAKE_DOCKER_CALLS" "healthcheck-http-probe"

sensitive_healthcheck_output="$TEST_TMP/keep-mode-sensitive-healthcheck.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_HEALTHCHECK_SECRET="true"
if ! printf '1\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$sensitive_healthcheck_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_HEALTHCHECK_SECRET
  cat "$sensitive_healthcheck_output" >&2
  fail "sensitive healthcheck diagnosis returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_HEALTHCHECK_SECRET

assert_contains "$sensitive_healthcheck_output" "curl -u [REDACTED] -fs http://127.0.0.1:8080/health"
assert_contains "$sensitive_healthcheck_output" "ホストのプロセス引数への露出を避けて手動再実行と HTTP 補助リクエストをスキップします。"
assert_not_contains "$sensitive_healthcheck_output" "super-secret"
assert_not_contains "$FAKE_DOCKER_CALLS" "healthcheck-http-probe"

failed_healthcheck_output="$TEST_TMP/keep-mode-failed-healthcheck.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_HEALTHCHECK_STATE_FAIL="true"
export FAKE_HEALTHCHECK_EXACT_FAIL="true"
export FAKE_HEALTHCHECK_HTTP_FAIL="true"
if ! printf '1\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$failed_healthcheck_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_HEALTHCHECK_STATE_FAIL \
    FAKE_HEALTHCHECK_EXACT_FAIL FAKE_HEALTHCHECK_HTTP_FAIL
  cat "$failed_healthcheck_output" >&2
  fail "failed healthcheck diagnosis did not return to the service action menu"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_HEALTHCHECK_STATE_FAIL \
  FAKE_HEALTHCHECK_EXACT_FAIL FAKE_HEALTHCHECK_HTTP_FAIL

assert_contains "$failed_healthcheck_output" "現在状態       : unhealthy"
assert_contains "$failed_healthcheck_output" "連続失敗回数   : 3"
assert_contains "$failed_healthcheck_output" "終了コード : 22"
assert_contains "$failed_healthcheck_output" "手動再実行結果 : NG (exit=22)"
assert_contains "$failed_healthcheck_output" "curl: (7) Failed to connect to 127.0.0.1 port 8080"
assert_contains "$failed_healthcheck_output" "healthcheck の HTTP 補助リクエストに失敗しました (exit=7)。"
assert_contains "$failed_healthcheck_output" "Compose サービスの対話操作を終了しました。"

mysql_helper_output="$TEST_TMP/keep-mode-mysql-helper.out"
: > "$FAKE_DOCKER_CALLS"
# MySQL 8.0.42 と MySQL 8.4 / Aurora 8.4 互換系を同じ操作経路で確認する。
export FAKE_COMPOSE_PS_SERVICES="app mysql80 aurora84"
if ! printf '2\n4\n0\n3\n4\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,mysql80,aurora84 \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$mysql_helper_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$mysql_helper_output" >&2
  fail "MySQL interactive client helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_occurrences "$mysql_helper_output" "  4) MySQL クライアントへ接続 (SQL クエリを対話実行)" 4
assert_contains "$mysql_helper_output" "MySQL クライアントへ接続します (service=mysql80, container=mysql-8.0.42)。"
assert_contains "$mysql_helper_output" "MySQL クライアントへ接続します (service=aurora84, container=aurora-mysql-8.4)。"
assert_contains "$mysql_helper_output" "SQL クエリを対話実行できます。終了するには exit または \\q を入力してください。"
assert_contains "$mysql_helper_output" "Welcome to the MySQL monitor.  Server version: 8.0.42"
assert_contains "$mysql_helper_output" "Welcome to the MySQL monitor.  Server version: 8.4.6"
assert_before "$mysql_helper_output" "MySQL クライアントへ接続します (service=mysql80" "Welcome to the MySQL monitor.  Server version: 8.0.42"
assert_before "$mysql_helper_output" "Welcome to the MySQL monitor.  Server version: 8.0.42" "MySQL セッションを終了しました。サービス操作の選択へ戻ります。"
assert_occurrences "$mysql_helper_output" "MySQL セッションを終了しました。サービス操作の選択へ戻ります。" 2
assert_occurrences "$mysql_helper_output" "操作する起動中の Compose サービスを選択してください:" 3
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-mysql80 /bin/sh -c"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-mysql84 /bin/sh -c"
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-mysql80 /bin/sh -c set -eu"
assert_contains "$FAKE_DOCKER_CALLS" "exec -it cid-mysql84 /bin/sh -c set -eu"
assert_contains "$FAKE_DOCKER_CALLS" "umask 077"
assert_contains "$FAKE_DOCKER_CALLS" "trap cleanup_mysql_option_file EXIT HUP INT TERM"
assert_contains "$FAKE_DOCKER_CALLS" 'set -- --defaults-extra-file="$mysql_option_file" --protocol=socket --user="$mysql_user"'
assert_not_contains "$FAKE_DOCKER_CALLS" "--password="
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

mysql_failure_output="$TEST_TMP/keep-mode-mysql-failure.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="mysql80"
export FAKE_MYSQL_CLIENT_FAIL="true"
if ! printf '1\n4\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service mysql80 \
    --startup-service mysql80 \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$mysql_failure_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_MYSQL_CLIENT_FAIL
  cat "$mysql_failure_output" >&2
  fail "failed MySQL client scenario did not return to the service action menu"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_MYSQL_CLIENT_FAIL

assert_contains "$mysql_failure_output" "Compose サービス 'mysql80' の MySQL クライアントへ接続できませんでした"
assert_contains "$mysql_failure_output" "MySQL 接続に失敗しました。サービス操作の選択へ戻ります。"
assert_occurrences "$mysql_failure_output" "Compose サービス 'mysql80' で実行する操作を選択してください:" 2
assert_contains "$mysql_failure_output" "Compose サービスの対話操作を終了しました。"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

cert_check_output="$TEST_TMP/keep-mode-cert-check.out"
cert_check_reports="$TEST_TMP/cert-check-reports"
: > "$FAKE_DOCKER_CALLS"
# トラストストアと HTTPS 接続先を設定したコンテナ (front / back 相当) でだけ
# 証明書チェックが追加され、既存操作の番号は変わらないこと。
export FAKE_COMPOSE_PS_SERVICES="app tlsapp"
if ! printf '2\n4\n\n0\n1\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,tlsapp \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --report-dir "$cert_check_reports" \
    --suppress-removed-logs
) >"$cert_check_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$cert_check_output" >&2
  fail "certificate check helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$cert_check_output" "  4) 証明書チェック (トラストストアと HTTPS 接続先を自動検出して確認)"
assert_contains "$cert_check_output" "Compose サービス : tlsapp"
assert_contains "$cert_check_output" "コンテナ         : app-front"
assert_contains "$cert_check_output" "そのコンテナ自身の curl で接続できるかを確認します (追加の入力は不要)。"
assert_contains "$cert_check_output" "できるかを先に表示します (1. と 5.)。"
assert_contains "$cert_check_output" "判定: OK — 検出したトラストストアの証明書で HTTPS 接続できています。"
assert_contains "$cert_check_output" "証明書チェック結果 : OK"
# 接続結果の前に、受領した自己証明書の素性が前提情報として出ていること。
assert_contains "$cert_check_output" "=== 1. 受領した自己証明書 (cacert.crt) の詳細 ==="
assert_contains "$cert_check_output" "種別            : ルート CA 証明書 (自己署名の CA。信頼の連鎖の最上位)"
assert_before "$cert_check_output" \
  "=== 1. 受領した自己証明書 (cacert.crt) の詳細 ===" "=== 3-1. HTTPS 接続 SECURE_API_URL ==="
# 画面と同じ内容がテキストファイルへ残ること (--report-dir 配下へサービス名付きで自動命名)。
cert_check_text="${cert_check_reports}"/build_and_verify_*_cert_check_tlsapp.txt
cert_check_text="$(ls -1 ${cert_check_text} 2>/dev/null | head -n 1)"
[ -n "$cert_check_text" ] && [ -s "$cert_check_text" ] \
  || fail "cert check text was not written under the report directory"
assert_contains "$cert_check_output" "証明書チェック結果のテキスト : ${cert_check_text}"
assert_contains "$cert_check_text" "証明書チェック結果 (build_and_verify.sh)"
assert_contains "$cert_check_text" "Compose サービス : tlsapp"
assert_contains "$cert_check_text" "コンテナ         : app-front"
assert_contains "$cert_check_text" "判定             : OK (検出したトラストストアの証明書で HTTPS 接続できています)"
assert_contains "$cert_check_text" "=== 1. 受領した自己証明書 (cacert.crt) の詳細 ==="
assert_contains "$cert_check_text" "種別            : ルート CA 証明書 (自己署名の CA。信頼の連鎖の最上位)"
assert_contains "$cert_check_text" "=== 5. 受領した自己証明書の全項目 (openssl x509 -text) ==="
assert_contains "$cert_check_text" "判定: OK — 検出したトラストストアの証明書で HTTPS 接続できています。"
# 全量レポートの数え上げに、証明書チェックのテキストが混ざらないこと。
collect_report_files "$cert_check_reports"
[ "${#REPORT_FILES[@]}" -eq 1 ] \
  || fail "expected exactly one full report next to the cert check text (got ${#REPORT_FILES[@]})"
# 証明書チェックを持たないサービスでは従来どおり 0 から 3 のまま。
assert_contains "$cert_check_output" "Compose サービス 'app' で実行する操作を選択してください:"
assert_not_contains "$cert_check_output" "0 から 4 の番号を入力してください。"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-tlsapp /bin/sh -c"
# パスワードはコンテナ内で解決するため、docker のコマンドラインへは載らない。
assert_not_contains "$FAKE_DOCKER_CALLS" "-storepass changeit"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

cert_check_ng_output="$TEST_TMP/keep-mode-cert-check-ng.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="tlsapp"
export FAKE_CERT_CHECK_RESULT="ng"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  TMPDIR="$TEST_TMP" bash ./build_and_verify.sh \
    --compose-service tlsapp \
    --startup-service tlsapp \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$cert_check_ng_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_CERT_CHECK_RESULT
  cat "$cert_check_ng_output" >&2
  fail "NG certificate check did not return to the service action menu"
fi
unset FAKE_CERT_CHECK_RESULT

assert_contains "$cert_check_ng_output" "[FAIL] cacert.crt はこのストアに登録されていない"
assert_contains "$cert_check_ng_output" "証明書チェック結果 : NG (上記 [FAIL] を確認してください)"
# NG は診断結果であり、ヘルパー自体の失敗としては扱わない。
assert_not_contains "$cert_check_ng_output" "証明書チェックに失敗しました。サービス操作の選択へ戻ります。"
assert_occurrences "$cert_check_ng_output" "Compose サービス 'tlsapp' で実行する操作を選択してください:" 2

cert_check_undetectable_output="$TEST_TMP/keep-mode-cert-check-undetectable.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_CERT_CHECK_RESULT="undetectable"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  TMPDIR="$TEST_TMP" bash ./build_and_verify.sh \
    --compose-service tlsapp \
    --startup-service tlsapp \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$cert_check_undetectable_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_CERT_CHECK_RESULT
  cat "$cert_check_undetectable_output" >&2
  fail "undetectable certificate check did not return to the service action menu"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_CERT_CHECK_RESULT

assert_contains "$cert_check_undetectable_output" "証明書チェックに必要な設定をコンテナ内から検出できませんでした。"
assert_contains "$cert_check_undetectable_output" "証明書チェックに失敗しました。サービス操作の選択へ戻ります。"
assert_contains "$cert_check_undetectable_output" "Compose サービスの対話操作を終了しました。"
# 実行不能で終わっても、そこまでに出た内容はテキストへ残す (出力先の指定が無ければ
# 一時ディレクトリへ出し、パスを画面へ示す)。
assert_contains "$cert_check_undetectable_output" "証明書チェック結果のテキスト : "
assert_contains "$cert_check_undetectable_output" \
  "  (--report-dir または --cert-check-text を指定すると出力先を変えられます)"
cert_check_fallback_text="$(sed -n 's/^証明書チェック結果のテキスト : //p' \
  "$cert_check_undetectable_output" | head -n 1)"
[ -n "$cert_check_fallback_text" ] && [ -s "$cert_check_fallback_text" ] \
  || fail "cert check text was not written to the temporary directory fallback"
case "$cert_check_fallback_text" in
  "$TEST_TMP"/*) ;;
  *) fail "cert check text fallback ignored TMPDIR: $cert_check_fallback_text" ;;
esac
assert_contains "$cert_check_fallback_text" \
  "判定             : 実行不能 (必要な設定をコンテナ内から検出できませんでした)"

# --cert-check-text で出力先を明示でき、--no-cert-check-text で出力を止められること。
cert_check_text_opt_output="$TEST_TMP/keep-mode-cert-check-text-opt.out"
cert_check_text_opt="$TEST_TMP/cert-check-explicit/result.txt"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="tlsapp"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service tlsapp \
    --startup-service tlsapp \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --cert-check-text "$cert_check_text_opt" \
    --suppress-removed-logs
) >"$cert_check_text_opt_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$cert_check_text_opt_output" >&2
  fail "explicit --cert-check-text scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES
assert_contains "$cert_check_text_opt_output" "証明書チェック結果のテキスト : ${cert_check_text_opt}"
[ -s "$cert_check_text_opt" ] || fail "--cert-check-text did not create $cert_check_text_opt"
assert_contains "$cert_check_text_opt" "=== 1. 受領した自己証明書 (cacert.crt) の詳細 ==="

cert_check_no_text_output="$TEST_TMP/keep-mode-cert-check-no-text.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="tlsapp"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service tlsapp \
    --startup-service tlsapp \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --no-cert-check-text \
    --suppress-removed-logs
) >"$cert_check_no_text_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$cert_check_no_text_output" >&2
  fail "--no-cert-check-text scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES
assert_contains "$cert_check_no_text_output" "証明書チェック結果のテキスト : 出力しません (--no-cert-check-text)"
# 画面表示そのものは従来どおり行う。
assert_contains "$cert_check_no_text_output" "=== 1. 受領した自己証明書 (cacert.crt) の詳細 ==="

# 出力先を指定しつつ出力を止める指定は、意味が矛盾するため受け付けない。
cert_check_conflict_output="$TEST_TMP/cert-check-option-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --cert-check-text "$TEST_TMP/never-written.txt" \
    --no-cert-check-text \
    --dry-run
) >"$cert_check_conflict_output" 2>&1; then
  cat "$cert_check_conflict_output" >&2
  fail "--cert-check-text with --no-cert-check-text should be rejected"
fi
assert_contains "$cert_check_conflict_output" \
  "--cert-check-text と --no-cert-check-text は同時に指定できません。"

# --- JBoss モジュール一覧 (module-loading:module-info) ------------------------
# jboss-cli.sh と modules を持つコンテナ (frontend / backend の JBoss EAP) だけで
# 操作が増え、既存操作の番号は変わらないこと。
jboss_modules_output="$TEST_TMP/keep-mode-jboss-modules.out"
jboss_modules_reports="$TEST_TMP/jboss-modules-reports"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app eapapp"
if ! printf '2\n4\n\n0\n1\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,eapapp \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --report-dir "$jboss_modules_reports" \
    --suppress-removed-logs
) >"$jboss_modules_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$jboss_modules_output" >&2
  fail "JBoss module list helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$jboss_modules_output" \
  "  4) JBoss モジュール一覧 (jboss-cli.sh -c の module-info で認識済みのモジュール名 / jar を出力)"
assert_contains "$jboss_modules_output" "Compose サービス : eapapp"
assert_contains "$jboss_modules_output" "コンテナ         : app-eap"
assert_contains "$jboss_modules_output" \
  "=== 1. 認識されているモジュール一覧 (module-info = success) ==="
# モジュール名だけでなく jar ファイル名も一覧の対象であること。
assert_contains "$jboss_modules_output" "[   1] org.jboss.logging:main"
assert_contains "$jboss_modules_output" "jboss-logging-3.5.3.Final-redhat-00001.jar"
assert_contains "$jboss_modules_output" "=== 3. 認識されているモジュールの jar ファイル一覧 ==="
assert_contains "$jboss_modules_output" "JBoss モジュール一覧 : OK"
# jboss-cli.sh を持たないサービスには操作を出さない (番号は 0-3 のまま)。
assert_contains "$jboss_modules_output" "Compose サービス 'app' で実行する操作を選択してください:"
assert_not_contains "$jboss_modules_output" "0 から 4 の番号を入力してください。"

# 画面と同じ内容がテキストファイルへ残ること (--report-dir 配下へサービス名付きで自動命名)。
jboss_modules_text="${jboss_modules_reports}"/build_and_verify_*_jboss_modules_eapapp.txt
jboss_modules_text="$(ls -1 ${jboss_modules_text} 2>/dev/null | head -n 1)"
[ -n "$jboss_modules_text" ] && [ -s "$jboss_modules_text" ] \
  || fail "JBoss module list text was not written under $jboss_modules_reports"
assert_contains "$jboss_modules_output" "JBoss モジュール一覧のテキスト : ${jboss_modules_text}"
assert_contains "$jboss_modules_text" "JBoss モジュール一覧 (build_and_verify.sh)"
assert_contains "$jboss_modules_text" "Compose サービス : eapapp"
assert_contains "$jboss_modules_text" \
  "判定             : OK (module-info が success となるモジュールを一覧化しました)"
assert_contains "$jboss_modules_text" "[   2] com.mysql.jdbc:main"
assert_contains "$jboss_modules_text" "mysql-connector-j-8.4.0.jar"
assert_contains "$jboss_modules_text" \
  "=== 4. TSV (モジュール名<TAB>スロット<TAB>jar ファイル名) ==="

# 全量レポートの件数はモジュール一覧テキストの分だけ増えないこと。
collect_report_files "$jboss_modules_reports"
[ "${#REPORT_FILES[@]}" -eq 1 ] \
  || fail "expected a single build report next to the JBoss module list text"

# module-info が 1 件も success にならない構成は NG として扱い、操作自体は成功させる。
jboss_modules_ng_output="$TEST_TMP/keep-mode-jboss-modules-ng.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="eapapp"
export FAKE_JBOSS_MODULE_LIST_RESULT="ng"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  TMPDIR="$TEST_TMP" bash ./build_and_verify.sh \
    --compose-service eapapp \
    --startup-service eapapp \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$jboss_modules_ng_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JBOSS_MODULE_LIST_RESULT
  cat "$jboss_modules_ng_output" >&2
  fail "NG JBoss module list did not return to the service action menu"
fi
unset FAKE_JBOSS_MODULE_LIST_RESULT

assert_contains "$jboss_modules_ng_output" \
  "JBoss モジュール一覧 : NG (module-info が success となるモジュールがありません)"
assert_not_contains "$jboss_modules_ng_output" \
  "JBoss モジュール一覧の取得に失敗しました。サービス操作の選択へ戻ります。"
assert_occurrences "$jboss_modules_ng_output" \
  "Compose サービス 'eapapp' で実行する操作を選択してください:" 2

# jboss-cli.sh -c で接続できない場合は実行不能として扱い、そこまでの内容は残す。
jboss_modules_unavailable_output="$TEST_TMP/keep-mode-jboss-modules-unavailable.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_JBOSS_MODULE_LIST_RESULT="unavailable"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  TMPDIR="$TEST_TMP" bash ./build_and_verify.sh \
    --compose-service eapapp \
    --startup-service eapapp \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$jboss_modules_unavailable_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JBOSS_MODULE_LIST_RESULT
  cat "$jboss_modules_unavailable_output" >&2
  fail "unavailable JBoss module list did not return to the service action menu"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JBOSS_MODULE_LIST_RESULT

assert_contains "$jboss_modules_unavailable_output" \
  "jboss-cli.sh で管理インターフェースへ接続できないか、モジュールを検出できませんでした。"
assert_contains "$jboss_modules_unavailable_output" \
  "JBoss モジュール一覧の取得に失敗しました。サービス操作の選択へ戻ります。"
assert_contains "$jboss_modules_unavailable_output" "JBoss モジュール一覧のテキスト : "
assert_contains "$jboss_modules_unavailable_output" \
  "  (--report-dir または --jboss-module-list-text を指定すると出力先を変えられます)"
jboss_modules_fallback_text="$(sed -n 's/^JBoss モジュール一覧のテキスト : //p' \
  "$jboss_modules_unavailable_output" | head -n 1)"
[ -n "$jboss_modules_fallback_text" ] && [ -s "$jboss_modules_fallback_text" ] \
  || fail "JBoss module list text was not written to the temporary directory fallback"
case "$jboss_modules_fallback_text" in
  "$TEST_TMP"/*) ;;
  *) fail "JBoss module list text fallback ignored TMPDIR: $jboss_modules_fallback_text" ;;
esac
assert_contains "$jboss_modules_fallback_text" \
  "判定             : 実行不能 (jboss-cli.sh での接続またはモジュール検出ができませんでした)"

# --jboss-module-list-text で出力先を明示でき、--no-jboss-module-list-text で止められること。
jboss_modules_text_opt_output="$TEST_TMP/keep-mode-jboss-modules-text-opt.out"
jboss_modules_text_opt="$TEST_TMP/jboss-modules-explicit/modules.txt"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="eapapp"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service eapapp \
    --startup-service eapapp \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --jboss-module-list-text "$jboss_modules_text_opt" \
    --suppress-removed-logs
) >"$jboss_modules_text_opt_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$jboss_modules_text_opt_output" >&2
  fail "explicit --jboss-module-list-text scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES
assert_contains "$jboss_modules_text_opt_output" \
  "JBoss モジュール一覧のテキスト : ${jboss_modules_text_opt}"
[ -s "$jboss_modules_text_opt" ] \
  || fail "--jboss-module-list-text did not create $jboss_modules_text_opt"
assert_contains "$jboss_modules_text_opt" \
  "=== 1. 認識されているモジュール一覧 (module-info = success) ==="

jboss_modules_no_text_output="$TEST_TMP/keep-mode-jboss-modules-no-text.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="eapapp"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service eapapp \
    --startup-service eapapp \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --no-jboss-module-list-text \
    --suppress-removed-logs
) >"$jboss_modules_no_text_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$jboss_modules_no_text_output" >&2
  fail "--no-jboss-module-list-text scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES
assert_contains "$jboss_modules_no_text_output" \
  "JBoss モジュール一覧のテキスト : 出力しません (--no-jboss-module-list-text)"
assert_contains "$jboss_modules_no_text_output" \
  "=== 1. 認識されているモジュール一覧 (module-info = success) ==="

# 出力先を指定しつつ出力を止める指定は、意味が矛盾するため受け付けない。
jboss_modules_conflict_output="$TEST_TMP/jboss-modules-option-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --jboss-module-list-text "$TEST_TMP/never-written-modules.txt" \
    --no-jboss-module-list-text \
    --dry-run
) >"$jboss_modules_conflict_output" 2>&1; then
  cat "$jboss_modules_conflict_output" >&2
  fail "--jboss-module-list-text with --no-jboss-module-list-text should be rejected"
fi
assert_contains "$jboss_modules_conflict_output" \
  "--jboss-module-list-text と --no-jboss-module-list-text は同時に指定できません。"

# --- ALB ヘルスチェック確認 (偽装サービス経由) --------------------------------
# ALB ヘルスチェック偽装サービス (alb-healthcheck) のターゲットに登録された
# サービスだけで操作が増え、既存操作の番号は変わらないこと。
alb_healthcheck_output="$TEST_TMP/keep-mode-alb-healthcheck.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app frontend alb-healthcheck"
if ! printf '2\n4\n\n0\n1\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,frontend,alb-healthcheck \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$alb_healthcheck_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$alb_healthcheck_output" >&2
  fail "ALB health check helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$alb_healthcheck_output" "  4) ALB ヘルスチェック確認 (ステータスコード / 成功失敗判定)"
assert_contains "$alb_healthcheck_output" "確認対象           : frontend"
assert_contains "$alb_healthcheck_output" "偽装サービス       : alb-healthcheck"
# 偽装サービス自身の状態 (判定元が生きているか) を先に出す。
assert_contains "$alb_healthcheck_output" "コンテナ           : alb-healthcheck"
assert_contains "$alb_healthcheck_output" "起動状態           : running"
assert_contains "$alb_healthcheck_output" "自身の healthcheck : healthy (連続失敗 0)"
assert_contains "$alb_healthcheck_output" "再起動回数         : 0"
assert_contains "$alb_healthcheck_output" "状態参照 API       : http://127.0.0.1:18580/targets"
# 偽装サービスのコンテナ内 CLI が出したレポート本文。
assert_contains "$alb_healthcheck_output" "User-Agent         : ELB-HealthChecker/2.0"
assert_contains "$alb_healthcheck_output" "status=200  matcher=一致     判定=成功  戻り値(exit)=0"
assert_contains "$alb_healthcheck_output" "ALB ヘルスチェック判定 : OK (healthy かつその場のチェックも成功)"
assert_before "$alb_healthcheck_output" "起動状態           : running" "ALB ヘルスチェック判定 : OK"
# ターゲットに登録されていないサービスでは従来どおり 0 から 3 のまま。
assert_contains "$alb_healthcheck_output" "Compose サービス 'app' で実行する操作を選択してください:"
assert_not_contains "$alb_healthcheck_output" "0 から 4 の番号を入力してください。"
assert_contains "$FAKE_DOCKER_CALLS" "alb-healthcheck-cli has-service frontend"
assert_contains "$FAKE_DOCKER_CALLS" "alb-healthcheck-cli report frontend"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-alb-healthcheck /bin/sh -c"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# 偽装サービス自身を選ぶと、全ターゲットグループをまとめて確認する。
alb_healthcheck_all_output="$TEST_TMP/keep-mode-alb-healthcheck-all.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="alb-healthcheck"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service alb-healthcheck \
    --startup-service alb-healthcheck \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$alb_healthcheck_all_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$alb_healthcheck_all_output" >&2
  fail "ALB health check helper for the emulator service returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_contains "$alb_healthcheck_all_output" "確認対象           : alb-healthcheck"
assert_contains "$alb_healthcheck_all_output" "ALB ヘルスチェック判定 : OK"
assert_contains "$FAKE_DOCKER_CALLS" "alb-healthcheck-cli report --all"
# 偽装サービス自身は has-service を問い合わせずに対象と判定する。
assert_not_contains "$FAKE_DOCKER_CALLS" "alb-healthcheck-cli has-service alb-healthcheck"

# unhealthy 判定は「診断結果」であり、ヘルパー自体の失敗としては扱わない。
alb_healthcheck_ng_output="$TEST_TMP/keep-mode-alb-healthcheck-ng.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="backend alb-healthcheck"
export FAKE_ALB_HEALTHCHECK_RESULT="ng"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service backend,alb-healthcheck \
    --startup-service backend \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$alb_healthcheck_ng_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_ALB_HEALTHCHECK_RESULT
  cat "$alb_healthcheck_ng_output" >&2
  fail "NG ALB health check did not return to the service action menu"
fi
unset FAKE_ALB_HEALTHCHECK_RESULT

assert_contains "$alb_healthcheck_ng_output" "確認対象           : backend"
assert_contains "$alb_healthcheck_ng_output" "status=404  matcher=不一致    判定=失敗  戻り値(exit)=22"
assert_contains "$alb_healthcheck_ng_output" "ALB ヘルスチェック判定 : NG (unhealthy、またはその場のチェックが失敗)"
assert_contains "$alb_healthcheck_ng_output" "Target.FailedHealthChecks) を上のレポートで確認してください。"
assert_not_contains "$alb_healthcheck_ng_output" "ALB ヘルスチェック確認に失敗しました。サービス操作の選択へ戻ります。"
assert_occurrences "$alb_healthcheck_ng_output" "Compose サービス 'backend' で実行する操作を選択してください:" 2

# initial (登録直後) は判定保留として扱い、失敗にはしない。
alb_healthcheck_initial_output="$TEST_TMP/keep-mode-alb-healthcheck-initial.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_ALB_HEALTHCHECK_RESULT="initial"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service backend,alb-healthcheck \
    --startup-service backend \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$alb_healthcheck_initial_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_ALB_HEALTHCHECK_RESULT
  cat "$alb_healthcheck_initial_output" >&2
  fail "initial ALB health check did not return to the service action menu"
fi
unset FAKE_ALB_HEALTHCHECK_RESULT

assert_contains "$alb_healthcheck_initial_output" "ALB ヘルスチェック判定 : 判定保留 (initial。healthy の連続成功回数に未到達)"
assert_not_contains "$alb_healthcheck_initial_output" "ALB ヘルスチェック確認に失敗しました。サービス操作の選択へ戻ります。"

# 偽装サービスの状態を取得できない場合はヘルパーの失敗として扱い、メニューへ戻る。
alb_healthcheck_unavailable_output="$TEST_TMP/keep-mode-alb-healthcheck-unavailable.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_ALB_HEALTHCHECK_RESULT="unavailable"
export FAKE_ALB_HEALTHCHECK_SERVICE_DOWN="true"
if ! printf '1\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service backend,alb-healthcheck \
    --startup-service backend \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$alb_healthcheck_unavailable_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_ALB_HEALTHCHECK_RESULT FAKE_ALB_HEALTHCHECK_SERVICE_DOWN
  cat "$alb_healthcheck_unavailable_output" >&2
  fail "unavailable ALB health check did not return to the service action menu"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_ALB_HEALTHCHECK_RESULT FAKE_ALB_HEALTHCHECK_SERVICE_DOWN

assert_contains "$alb_healthcheck_unavailable_output" "起動状態           : restarting"
assert_contains "$alb_healthcheck_unavailable_output" "自身の healthcheck : unhealthy (連続失敗 4)"
assert_contains "$alb_healthcheck_unavailable_output" "ALB ヘルスチェック偽装サービスが健全ではありません。"
assert_contains "$alb_healthcheck_unavailable_output" "ALB ヘルスチェック偽装サービスから状態を取得できませんでした。"
assert_contains "$alb_healthcheck_unavailable_output" "ALB ヘルスチェック確認に失敗しました。サービス操作の選択へ戻ります。"
assert_contains "$alb_healthcheck_unavailable_output" "Compose サービスの対話操作を終了しました。"

# 偽装サービスが起動していない構成では操作が増えない (従来どおり 0 から 3)。
alb_healthcheck_absent_output="$TEST_TMP/keep-mode-alb-healthcheck-absent.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_PS_SERVICES="frontend"
if ! printf '1\n3\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service frontend \
    --startup-service frontend \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$alb_healthcheck_absent_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES
  cat "$alb_healthcheck_absent_output" >&2
  fail "service actions without the ALB health check emulator returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES

assert_not_contains "$alb_healthcheck_absent_output" "ALB ヘルスチェック確認 (ステータスコード / 成功失敗判定)"
assert_not_contains "$FAKE_DOCKER_CALLS" "alb-healthcheck-cli"

cwagent_helper_output="$TEST_TMP/keep-mode-cwagent-helper.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app cwagent cloudwatch-logs-mock"
export FAKE_CLOUDWATCH_JOURNAL_FILE="$TEST_DIR/fixtures/cloudwatch-wiremock-requests.json"
if ! printf '2\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$cwagent_helper_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_CLOUDWATCH_JOURNAL_FILE
  cat "$cwagent_helper_output" >&2
  fail "cwagent CloudWatch Logs helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_CLOUDWATCH_JOURNAL_FILE

assert_contains "$cwagent_helper_output" "4) CloudWatch Logs 偽装送達を確認 (ロググループ / ストリーム / イベント)"
assert_contains "$cwagent_helper_output" "CloudWatch Agent → CloudWatch Logs 偽装サービスの送達を確認します。"
assert_contains "$cwagent_helper_output" "WireMock API 受信総数: CreateLogGroup=2, CreateLogStream=2, PutLogEvents=3"
assert_contains "$cwagent_helper_output" "[OK] /mnt/logs/app-front*.log"
assert_contains "$cwagent_helper_output" "log group : /local/myapp/efs/app-front"
assert_contains "$cwagent_helper_output" "log stream: front-local"
assert_contains "$cwagent_helper_output" "[OK] /mnt/logs/app-back*.log"
assert_contains "$cwagent_helper_output" "request completed token=[REDACTED]"
assert_contains "$cwagent_helper_output" "database call completed"
assert_not_contains "$cwagent_helper_output" "dummy-secret"
assert_not_contains "$cwagent_helper_output" "AWS4-HMAC-SHA256"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-cwagent cat /etc/cwagentconfig/cwagent-config.json"
assert_contains "$FAKE_DOCKER_CALLS" "port cid-cloudwatch-logs-mock 8080/tcp"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18480/__admin/requests?limit=100"
assert_contains "$FAKE_CURL_CALLS" "Logs_20140328.PutLogEvents"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

otel_helper_output="$TEST_TMP/keep-mode-otel-helper.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_FILE="$TEST_DIR/fixtures/jaeger-services.json"
export FAKE_JAEGER_TRACES_FILE="$TEST_DIR/fixtures/jaeger-traces.json"
# ADOT Collector は distroless のため、設定は docker cp で取り出す。
export FAKE_ADOT_CONFIG_FILE="$TEST_DIR/fixtures/otel/adot-collector-local.yaml"
if ! printf '2\n3\n\n4\ninvalid\n1\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_helper_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE \
    FAKE_ADOT_CONFIG_FILE
  cat "$otel_helper_output" >&2
  fail "OTel Jaeger trace helper returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE \
  FAKE_ADOT_CONFIG_FILE

assert_contains "$otel_helper_output" "4) X-Ray 偽装 Jaeger のトレースを確認 (サービス / トレース / スパン)"
assert_contains "$otel_helper_output" "[healthcheck 実行ファイル]"
assert_contains "$otel_helper_output" "ファイル: /healthcheck"
assert_contains "$otel_helper_output" "実行権限: あり"
assert_contains "$otel_helper_output" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  /healthcheck"
assert_contains "$otel_helper_output" "手動再実行結果 : OK"
assert_contains "$otel_helper_output" "HTTP(S) URL を含む healthcheck ではないため、HTTP 補助リクエストは対象外です。"
assert_contains "$otel_helper_output" "OTel Collector ヘルスチェック: OK (service=adot-collector)"
assert_contains "$otel_helper_output" "TracesExporter resource spans: 2, spans: 4"
assert_contains "$otel_helper_output" "OTel Collector → X-Ray 偽装 Jaeger のトレース送達を確認します。"
assert_contains "$otel_helper_output" "実 AWS X-Ray への送信確認ではありません。"
assert_contains "$otel_helper_output" "0 から 2 の番号を入力してください。"
assert_contains "$otel_helper_output" "検索サービス: myapp-front"
assert_contains "$otel_helper_output" "取得トレース: 1 件"
assert_contains "$otel_helper_output" "traceID=66a00000000000001234567890abcdef"
assert_contains "$otel_helper_output" "services=myapp-back, myapp-front"
# 送信先の判定 (実 AWS X-Ray か、Compose 内 Jaeger か) をトレース確認の冒頭で示す。
assert_contains "$otel_helper_output" "[ADOT Collector の設定チェック (要点)]"
assert_contains "$otel_helper_output" \
  "[送信先の判定] Compose 内 Jaeger (X-Ray 偽装) へ送っています (実 AWS X-Ray へは送っていません)"
# X-Ray コンソール相当の表示 (トレース ID の変換、セグメント / サブセグメント、
# 注釈とメタデータの区別、サービスマップ)。
assert_contains "$otel_helper_output" "X-Ray 相当ビュー (Compose 内 Jaeger のトレース)"
assert_contains "$otel_helper_output" "X-Ray Trace ID: 1-66a00000-000000001234567890abcdef"
assert_contains "$otel_helper_output" "[トレース一覧] X-Ray コンソールの Traces 表に相当"
assert_contains "$otel_helper_output" \
  "Jaeger UI  : http://127.0.0.1:16686/trace/66a00000000000001234567890abcdef"
assert_contains "$otel_helper_output" "操作=GET /orders"
assert_contains "$otel_helper_output" "操作=SELECT orders"
assert_contains "$otel_helper_output" "セグメント 1 件 / サブセグメント 2 件"
assert_contains "$otel_helper_output" "エッジ myapp-front -> myapp-back: 1 呼び出し / エラー 0 件"
assert_contains "$otel_helper_output" "sanitized_query=SELECT * FROM orders WHERE token=[REDACTED]"
assert_contains "$otel_helper_output" "[Metadata] 注釈にならない属性"
assert_contains "$otel_helper_output" "db.system=mysql"
assert_contains "$otel_helper_output" "http.request.header.authorization=[REDACTED]"
assert_contains "$otel_helper_output" "SELECT * FROM orders WHERE token=[REDACTED]"
assert_not_contains "$otel_helper_output" "dummy-secret"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-adot-collector /healthcheck"
assert_contains "$FAKE_DOCKER_CALLS" "healthcheck-file /healthcheck"
assert_contains "$FAKE_DOCKER_CALLS" "port cid-jaeger 16686/tcp"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:16686/api/services"
assert_contains "$FAKE_CURL_CALLS" "--data-urlencode service=myapp-front"
# Python ヘルパーの出力に CR 等が混ざるとサービス名が壊れるため、後続引数まで検査する。
assert_matches "$FAKE_CURL_CALLS" 'service=myapp-front --data-urlencode'
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:16686/api/traces"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

otel_no_traces_output="$TEST_TMP/keep-mode-otel-no-traces.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_BODY='{"data":[]}'
if ! printf '2\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_no_traces_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY
  cat "$otel_no_traces_output" >&2
  fail "empty Jaeger service scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY
assert_contains "$otel_no_traces_output" "Jaeger にトレースサービスが登録されていません。"
assert_contains "$otel_no_traces_output" "サービス操作の選択へ戻ります"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# distroless の adot-collector: /bin/sh も wget も /healthcheck も無い状態で、
# compose の healthcheck 定義 → シェル無し直接実行 → ホストからの HTTP 確認へ
# フォールバックできることを確認する。
otel_distroless_output="$TEST_TMP/keep-mode-otel-distroless.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_BODY='{"data":[]}'
export FAKE_ADOT_DISTROLESS="true"
if ! printf '2\n3\n\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_distroless_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_DISTROLESS
  cat "$otel_distroless_output" >&2
  fail "distroless adot-collector scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_DISTROLESS

assert_contains "$otel_distroless_output" \
  "実行方式   : コンテナ内にシェルが無いため docker exec で直接実行: wget -q -O- http://127.0.0.1:13133/"
assert_contains "$otel_distroless_output" "コンテナ内にシェルが無いため、ホストからの HTTP 確認へ切り替えます。"
assert_contains "$otel_distroless_output" "送信元     : ホスト (curl、コンテナへは公開ポート/コンテナ IP 経由)"
assert_contains "$otel_distroless_output" '{"status":"Server available"}'
assert_contains "$otel_distroless_output" "OTel Collector ヘルスチェック: OK (service=adot-collector)"
assert_contains "$otel_distroless_output" "確認方式: ホストから health_check エンドポイントへ HTTP 確認"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-adot-collector wget -q -O- http://127.0.0.1:13133/"
assert_contains "$FAKE_DOCKER_CALLS" "port cid-adot-collector 13133/tcp"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:13133/"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# 自動確認の手段が尽きた場合は、手元で実行すべきコマンドを案内する。
otel_manual_output="$TEST_TMP/keep-mode-otel-manual-commands.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_BODY='{"data":[]}'
export FAKE_ADOT_DISTROLESS="true"
export FAKE_OTEL_HEALTH_HTTP_FAIL="true"
if ! printf '2\n4\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_manual_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_DISTROLESS \
    FAKE_OTEL_HEALTH_HTTP_FAIL
  cat "$otel_manual_output" >&2
  fail "adot-collector manual command guidance scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_DISTROLESS \
  FAKE_OTEL_HEALTH_HTTP_FAIL

assert_contains "$otel_manual_output" "health_check エンドポイントへの HTTP 確認にも失敗しました"
assert_contains "$otel_manual_output" "[手動で確認する場合のコマンド]"
assert_contains "$otel_manual_output" \
  "  docker inspect --format '{{json .State.Health}}' adot-collector"
assert_contains "$otel_manual_output" \
  "  docker run --rm --network container:adot-collector curlimages/curl:latest -sS -i http://127.0.0.1:13133/"
assert_contains "$otel_manual_output" "  curl -sS -i http://127.0.0.1:13133/"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# ADOT Collector の設定チェック: 有効な設定・送信先・チェック結果を表示できるか。
# ローカル構成 (Jaeger へ送る = X-Ray 偽装) で、未参照の定義と送信元ポートの
# 食い違いを検出できることを確かめる。
otel_config_output="$TEST_TMP/keep-mode-otel-config-check.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_BODY='{"data":[]}'
export FAKE_ADOT_CONFIG_FILE="$TEST_DIR/fixtures/otel/adot-collector-local.yaml"
if ! printf '2\n5\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_config_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_CONFIG_FILE
  cat "$otel_config_output" >&2
  fail "ADOT collector config check scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_CONFIG_FILE

assert_contains "$otel_config_output" \
  "5) ADOT Collector の設定チェック (有効な設定 / 送信先 / 判定)"
assert_contains "$otel_config_output" "════════════ ADOT Collector 設定チェック ════════════"
assert_contains "$otel_config_output" \
  "設定の取得元  : コンテナ内の /etc/otel/config.yaml (docker cp で取得)"
assert_contains "$otel_config_output" "[有効なパイプライン] service.pipelines に書かれたものだけが動きます"
assert_contains "$otel_config_output" "    exporters  : debug, otlphttp/jaeger"
# 定義はあるがパイプラインから参照されていないものは「無効」として区別する。
assert_contains "$otel_config_output" \
  "参照されていないため無効です: extensions.pprof"
assert_contains "$otel_config_output" \
  "  結論: Compose 内 Jaeger (X-Ray 偽装) へ送っています (実 AWS X-Ray へは送っていません)"
assert_contains "$otel_config_output" \
  "Compose 内 Jaeger ('jaeger') へ送ります。X-Ray コンソールの代替であり、実 AWS X-Ray へは送りません"
# 送信元アプリの OTLP ポートと Collector の待受ポートの食い違いを検出する。
assert_contains "$otel_config_output" \
  "http://adot-collector:4317 へ送っていますが、Collector が待ち受けているのは 4318 だけです。"
assert_contains "$otel_config_output" "0.0.0.0:4318 で待ち受けています (別コンテナから到達できます)。"
assert_contains "$otel_config_output" "[設定ファイルの本文] /etc/otel/config.yaml"
assert_contains "$otel_config_output" "上の [NG] を修正してください"
assert_contains "$FAKE_DOCKER_CALLS" "cp cid-adot-collector:/etc/otel/config.yaml"
assert_contains "$FAKE_CURL_CALLS" "http://172.20.0.2:8888/metrics"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# 実 AWS X-Ray へ送る設定 (ECS 用) をローカルへ持ち込んだ場合。送信先が AWS で
# あること、認証情報が無いこと、内部テレメトリ上も送信に失敗していることを示す。
otel_xray_output="$TEST_TMP/keep-mode-otel-config-xray.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_FILE="$TEST_DIR/fixtures/jaeger-services.json"
export FAKE_JAEGER_TRACES_FILE="$TEST_DIR/fixtures/jaeger-traces.json"
export FAKE_ADOT_CONFIG_FILE="$TEST_DIR/fixtures/otel/adot-collector-xray.yaml"
export FAKE_OTEL_METRICS_BODY='otelcol_receiver_accepted_spans{receiver="otlp"} 12
otelcol_exporter_sent_spans{exporter="awsxray"} 0
otelcol_exporter_send_failed_spans{exporter="awsxray"} 12'
if ! printf '2\n5\n\n4\n1\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs
) >"$otel_xray_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE \
    FAKE_ADOT_CONFIG_FILE FAKE_OTEL_METRICS_BODY
  cat "$otel_xray_output" >&2
  fail "ADOT collector X-Ray destination scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE \
  FAKE_ADOT_CONFIG_FILE FAKE_OTEL_METRICS_BODY

assert_contains "$otel_xray_output" \
  "  結論: 実 AWS X-Ray へ送っています (Compose 内 Jaeger へは送っていません)"
assert_contains "$otel_xray_output" "      区分     : aws"
assert_contains "$otel_xray_output" "      endpoint : xray.ap-northeast-1.amazonaws.com"
assert_contains "$otel_xray_output" \
  "実 AWS X-Ray へ送る設定ですが、コンテナに AWS 認証情報 (環境変数・タスクロール) が見当たりません。"
assert_contains "$otel_xray_output" "送信成功 0 件 / 送信失敗 12 件。送信先へ届いていません。"
assert_contains "$otel_xray_output" "receiver が受け取ったスパン: 12 件。"
assert_contains "$otel_xray_output" \
  "注釈になる属性: service.namespace, deployment.environment, aws.ecs.service.name, aws.ecs.task.family"
# トレース確認の側でも、Jaeger へは送っていないことを警告する。
assert_contains "$otel_xray_output" \
  "この Collector は実 AWS X-Ray へも送っています。"
assert_contains "$otel_xray_output" \
  "この Collector は Compose 内 Jaeger へ送る設定になっていません。Jaeger にトレースが出ないのは設定どおりの結果です。"
# indexed_attributes に挙げた属性が、トレース側では X-Ray の注釈として表示される。
assert_contains "$otel_xray_output" \
  "deployment.environment=local   (X-Ray 上のキー: deployment_environment)"
assert_contains "$otel_xray_output" \
  "service.namespace=myapp   (X-Ray 上のキー: service_namespace)"
# 同じトレースを実 X-Ray コンソールで開くための URL を、設定のリージョンから組み立てる。
assert_contains "$otel_xray_output" \
  "X-Ray 相当 : https://ap-northeast-1.console.aws.amazon.com/xray/home?region=ap-northeast-1#/traces/1-66a00000-000000001234567890abcdef"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# Jaeger トレースの HTML 出力 (1 ファイル形式)。
# Jaeger UI を開けない環境向けに、別端末へコピーしてダブルクリックで開ける
# 単体の .htm を作れること、外部リソースを参照しないことを確認する。
trace_html_output="$TEST_TMP/keep-mode-trace-html.out"
trace_html_dir="$TEST_TMP/trace-report-single"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_FILE="$TEST_DIR/fixtures/jaeger-services.json"
export FAKE_JAEGER_TRACES_FILE="$TEST_DIR/fixtures/jaeger-traces.json"
export FAKE_ADOT_CONFIG_FILE="$TEST_DIR/fixtures/otel/adot-collector-local.yaml"
if ! printf '2\n6\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --trace-report-dir "$trace_html_dir" \
    --suppress-removed-logs
) >"$trace_html_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE \
    FAKE_ADOT_CONFIG_FILE
  cat "$trace_html_output" >&2
  fail "Jaeger trace HTML export scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE \
  FAKE_ADOT_CONFIG_FILE

assert_contains "$trace_html_output" "6) Jaeger トレースを HTML へ出力 (別端末のブラウザで確認)"
assert_contains "$trace_html_output" "Jaeger のトレースを HTML へ書き出します"
assert_contains "$trace_html_output" "  取得: myapp-front"
assert_contains "$trace_html_output" "  取得: myapp-back"
assert_contains "$trace_html_output" "この 1 ファイルを別端末へコピーし、ダブルクリックすると開けます。"
assert_contains "$trace_html_output" \
  "外部のサーバー・CDN を参照しないため、ネットワークに繋がっていない端末でも表示できます。"
# サービスごとに Jaeger Query API を叩いていること (bash から curl した分も拾えるように、
# 選択サービスだけでなく Jaeger に登録された全サービスを取得する)。
assert_contains "$FAKE_CURL_CALLS" "--data-urlencode service=myapp-front"
assert_contains "$FAKE_CURL_CALLS" "--data-urlencode service=myapp-back"
assert_contains "$FAKE_CURL_CALLS" "--data-urlencode lookback=6h"

trace_html_single=()
for trace_html_path in "$trace_html_dir"/*.htm; do
  [ -f "$trace_html_path" ] && trace_html_single+=("$trace_html_path")
done
[ ${#trace_html_single[@]} -eq 1 ] \
  || fail "expected exactly one .htm in $trace_html_dir, found ${#trace_html_single[@]}"
assert_contains "${trace_html_single[0]}" "<!DOCTYPE html>"
assert_contains "${trace_html_single[0]}" "window.TRACE_DATA = {"
assert_contains "${trace_html_single[0]}" "1-66a00000-000000001234567890abcdef"
assert_contains "${trace_html_single[0]}" "Jaeger トレースレポート (X-Ray 相当ビュー)"
assert_contains "${trace_html_single[0]}" "取り扱い注意:"
# 1 ファイル形式は外部ファイル・外部サーバーを一切参照しない。
assert_not_contains "${trace_html_single[0]}" "<script src="
assert_not_contains "${trace_html_single[0]}" "<link rel=\"stylesheet\""
# 画面表示と同じく、機微情報を示す属性は伏せ字にする。
assert_not_contains "${trace_html_single[0]}" "dummy-secret"
assert_contains "${trace_html_single[0]}" "[REDACTED]"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# Jaeger にトレースサービスが 1 件も無いとき、Jaeger Query API は data を配列ではなく
# null で返す。これを配列と同じ扱いにできないと HTML 出力が
# 「data が配列ではありません」で失敗するため、設定チェックだけの HTML を出せることを確認する。
trace_html_null_output="$TEST_TMP/keep-mode-trace-html-null-data.out"
trace_html_null_dir="$TEST_TMP/trace-report-null-data"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_BODY='{"data":null,"total":0,"limit":0,"offset":0,"errors":null}'
export FAKE_ADOT_CONFIG_FILE="$TEST_DIR/fixtures/otel/adot-collector-local.yaml"
if ! printf '2\n6\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --trace-report-dir "$trace_html_null_dir" \
    --suppress-removed-logs
) >"$trace_html_null_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_CONFIG_FILE
  cat "$trace_html_null_output" >&2
  fail "null Jaeger service list scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_BODY FAKE_ADOT_CONFIG_FILE

assert_not_contains "$trace_html_null_output" \
  "Jaeger サービス一覧の data が配列ではありません。"
assert_not_contains "$trace_html_null_output" "Jaeger トレースの HTML を出力できませんでした。"
assert_contains "$trace_html_null_output" \
  "Jaeger にトレースサービスが登録されていません。"
assert_contains "$trace_html_null_output" "設定チェックの結果だけを含む HTML を出力します。"
assert_contains "$trace_html_null_output" "Jaeger トレースを HTML へ出力しました: "

trace_html_null_files=()
for trace_html_path in "$trace_html_null_dir"/*.htm; do
  [ -f "$trace_html_path" ] && trace_html_null_files+=("$trace_html_path")
done
[ ${#trace_html_null_files[@]} -eq 1 ] \
  || fail "expected exactly one .htm in $trace_html_null_dir, found ${#trace_html_null_files[@]}"
assert_contains "${trace_html_null_files[0]}" "<!DOCTYPE html>"
assert_contains "${trace_html_null_files[0]}" "window.TRACE_DATA = {"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# 同じ内容を html + css + js のファイル群としても出力できること。
# エラー (5xx・例外) のトレースを X-Ray の Fault / cause として持てるかも確認する。
trace_files_output="$TEST_TMP/keep-mode-trace-html-files.out"
trace_files_dir="$TEST_TMP/trace-report-files"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app adot-collector jaeger"
export FAKE_JAEGER_SERVICES_FILE="$TEST_DIR/fixtures/jaeger-services.json"
export FAKE_JAEGER_TRACES_FILE="$TEST_DIR/fixtures/jaeger-traces-error.json"
export FAKE_ADOT_CONFIG_FILE="$TEST_DIR/fixtures/otel/adot-collector-xray.yaml"
if ! printf '2\n6\n\n0\n0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app,adot-collector,jaeger \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --trace-report-dir "$trace_files_dir" \
    --trace-report-format files \
    --trace-report-limit 20 \
    --trace-report-lookback 30m \
    --suppress-removed-logs
) >"$trace_files_output" 2>&1; then
  unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE \
    FAKE_ADOT_CONFIG_FILE
  cat "$trace_files_output" >&2
  fail "Jaeger trace HTML files export scenario returned a non-zero status"
fi
unset FAKE_COMPOSE_PS_SERVICES FAKE_JAEGER_SERVICES_FILE FAKE_JAEGER_TRACES_FILE \
  FAKE_ADOT_CONFIG_FILE

assert_contains "$trace_files_output" \
  "ディレクトリごと別端末へコピーし、index.html をダブルクリックすると開けます。"
assert_contains "$FAKE_CURL_CALLS" "--data-urlencode lookback=30m"
assert_contains "$FAKE_CURL_CALLS" "--data-urlencode limit=20"

trace_files_index=""
for trace_html_path in "$trace_files_dir"/*/index.html; do
  [ -f "$trace_html_path" ] && trace_files_index="$trace_html_path"
done
[ -n "$trace_files_index" ] || fail "index.html was not written under $trace_files_dir"
trace_files_base="$(dirname "$trace_files_index")"
for trace_html_asset in trace-report.css trace-report.js trace-data.js; do
  [ -f "${trace_files_base}/${trace_html_asset}" ] \
    || fail "expected ${trace_html_asset} in ${trace_files_base}"
done
# index.html は同じディレクトリの css / js を相対パスで読む (file:// で開けるように)。
assert_contains "$trace_files_index" "<link rel=\"stylesheet\" href=\"trace-report.css\">"
assert_contains "$trace_files_index" "<script src=\"trace-data.js\"></script>"
assert_contains "$trace_files_index" "<script src=\"trace-report.js\"></script>"
assert_not_contains "$trace_files_index" "http://"
assert_not_contains "$trace_files_index" "https://"
# 5xx と例外は X-Ray と同じく Fault / cause として持つ。
assert_contains "${trace_files_base}/trace-data.js" "1-66b11111-111111119876543210fedcba"
assert_contains "${trace_files_base}/trace-data.js" "Fault"
assert_contains "${trace_files_base}/trace-data.js" "java.sql.SQLException"
assert_contains "${trace_files_base}/trace-data.js" "AWS::ECS::Container"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# 指定値の検証。誤った指定は対話へ入る前に弾く。
trace_format_output="$TEST_TMP/trace-report-format-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --trace-report-format zip --compose-service app
) >"$trace_format_output" 2>&1; then
  cat "$trace_format_output" >&2
  fail "--trace-report-format zip should have failed"
fi
assert_contains "$trace_format_output" \
  "--trace-report-format には single または files を指定してください: zip"

trace_lookback_output="$TEST_TMP/trace-report-lookback-invalid.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --trace-report-lookback yesterday --compose-service app
) >"$trace_lookback_output" 2>&1; then
  cat "$trace_lookback_output" >&2
  fail "--trace-report-lookback yesterday should have failed"
fi
assert_contains "$trace_lookback_output" \
  "--trace-report-lookback には 30m / 6h / 2d のような期間を指定してください: yesterday"

http_get_output="$TEST_TMP/keep-mode-http-get.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="201"
export FAKE_CURL_BODY='{"message":"ready"}'
if ! printf '/status\n1\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_get_output" 2>&1; then
  cat "$http_get_output" >&2
  fail "interactive HTTP GET mode returned a non-zero status"
fi

assert_contains "$http_get_output" "JBoss EAP ログからコンテキストルートを検出しました: /orders"
assert_contains "$http_get_output" "JBoss EAP ログから HTTP リスナーポートを検出しました: 8080"
assert_contains "$http_get_output" "Docker 公開ポートを検出しました: 8080/tcp -> 127.0.0.1:18080"
assert_contains "$http_get_output" "HTTP ステータスコード : 201"
assert_contains "$http_get_output" '{"message":"ready"}'
assert_contains "$FAKE_DOCKER_CALLS" "port cid-app 8080/tcp"
assert_contains "$FAKE_CURL_CALLS" "--request GET http://127.0.0.1:18080/orders/status"
assert_not_contains "$FAKE_CURL_CALLS" "--data-binary"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

http_json_output="$TEST_TMP/keep-mode-http-json.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="202"
export FAKE_CURL_BODY='{"accepted":true}'
if ! printf 'submit\n2\n1\n{"target":"orders"}\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_json_output" 2>&1; then
  cat "$http_json_output" >&2
  fail "interactive HTTP JSON POST mode returned a non-zero status"
fi

assert_contains "$http_json_output" "HTTP ステータスコード : 202"
assert_contains "$http_json_output" '{"accepted":true}'
assert_contains "$FAKE_CURL_CALLS" "--request POST"
assert_contains "$FAKE_CURL_CALLS" "--header Content-Type: application/json"
assert_contains "$FAKE_CURL_CALLS" "--data-binary @-"
assert_contains "$FAKE_CURL_CALLS" 'request-body={"target":"orders"}'
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18080/orders/submit"

http_form_output="$TEST_TMP/keep-mode-http-form.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="200"
export FAKE_CURL_BODY='token-issued'
if ! printf '/token\n2\n2\ngrant_type=client_credentials&scope=read\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --jboss-context-root /custom/ \
    --jboss-http-port 8080 \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_form_output" 2>&1; then
  cat "$http_form_output" >&2
  fail "interactive HTTP form POST mode returned a non-zero status"
fi

assert_contains "$http_form_output" "指定された JBoss EAP コンテキストルートを使用します: /custom"
assert_contains "$http_form_output" "指定された JBoss EAP HTTP リスナーポートを使用します: 8080"
assert_contains "$http_form_output" "HTTP ステータスコード : 200"
assert_contains "$http_form_output" "token-issued"
assert_contains "$FAKE_CURL_CALLS" "--header Content-Type: application/x-www-form-urlencoded"
assert_contains "$FAKE_CURL_CALLS" "--data-binary @-"
assert_contains "$FAKE_CURL_CALLS" "request-body=grant_type=client_credentials&scope=read"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18080/custom/token"

http_failure_output="$TEST_TMP/keep-mode-http-curl-failure.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_CURL_STATUS="000"
export FAKE_CURL_BODY='connection failed'
export FAKE_CURL_EXIT_STATUS="7"
if printf '/status\n1\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --env-list-limit 1 \
    --suppress-removed-logs
) >"$http_failure_output" 2>&1; then
  cat "$http_failure_output" >&2
  fail "curl transport failure unexpectedly returned zero"
fi

assert_contains "$http_failure_output" "HTTP ステータスコード : 000"
assert_contains "$http_failure_output" "connection failed"
assert_contains "$http_failure_output" "curl による HTTP 通信に失敗しました (exit=7, HTTP=000)"
assert_contains "$http_failure_output" "コンテナを残します (--keep-container)"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

unset FAKE_CURL_STATUS FAKE_CURL_BODY FAKE_CURL_EXIT_STATUS

export FAKE_DOCKER_CLEANED="$TEST_TMP/docker.cleaned"

dry_run_cleanup_output="$TEST_TMP/cleanup-dry-run.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --cleanup-all-docker-data
) >"$dry_run_cleanup_output" 2>&1; then
  cat "$dry_run_cleanup_output" >&2
  fail "cleanup dry-run returned a non-zero status"
fi

assert_contains "$dry_run_cleanup_output" "現在の Docker context の全ローカルデータを削除します"
assert_contains "$dry_run_cleanup_output" "[DRY-RUN] 確認入力と Docker データ削除は行いません"
assert_contains "$dry_run_cleanup_output" "docker volume prune --all --force"
assert_not_contains "$FAKE_DOCKER_CALLS" "container prune --force"

conflicting_cleanup_output="$TEST_TMP/cleanup-conflicting-options.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --dry-run \
    --cleanup-all-docker-data \
    --keep-container
) >"$conflicting_cleanup_output" 2>&1; then
  cat "$conflicting_cleanup_output" >&2
  fail "conflicting cleanup options unexpectedly returned zero"
fi
assert_contains "$conflicting_cleanup_output" "--cleanup-all-docker-data と --keep-container は同時に指定できません"

declined_cleanup_output="$TEST_TMP/cleanup-declined.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if printf 'cancel\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$declined_cleanup_output" 2>&1; then
  cat "$declined_cleanup_output" >&2
  fail "declined cleanup unexpectedly returned zero"
fi

assert_contains "$declined_cleanup_output" "続行するには 'DELETE ALL DOCKER DATA' と正確に入力してください"
assert_contains "$declined_cleanup_output" "確認フレーズが一致しないため、追加の Docker 全体クリーンアップは実行しません"
assert_not_contains "$FAKE_DOCKER_CALLS" "container prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

failed_build_cleanup_output="$TEST_TMP/cleanup-after-failed-build.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-failure.log"
if printf 'DELETE ALL DOCKER DATA\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --exit-on-deploy-error \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$failed_build_cleanup_output" 2>&1; then
  cat "$failed_build_cleanup_output" >&2
  fail "failed build with confirmed cleanup unexpectedly returned zero"
fi

assert_contains "$failed_build_cleanup_output" "JBoss EAP 8.1 が正常起動しませんでした"
assert_contains "$failed_build_cleanup_output" "確認フレーズを受け付けました"
assert_contains "$failed_build_cleanup_output" "Docker 完全クリーンアップが完了しました"
assert_contains "$FAKE_DOCKER_CALLS" "system prune --all --volumes --force"

confirmed_cleanup_output="$TEST_TMP/cleanup-confirmed.out"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
if ! printf 'DELETE ALL DOCKER DATA\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --suppress-removed-logs \
    --cleanup-all-docker-data
) >"$confirmed_cleanup_output" 2>&1; then
  cat "$confirmed_cleanup_output" >&2
  fail "confirmed cleanup returned a non-zero status"
fi

assert_contains "$confirmed_cleanup_output" "確認フレーズを受け付けました"
assert_contains "$confirmed_cleanup_output" "容量削減結果 (Docker 管理対象・概算): 2.79 GiB"
assert_contains "$confirmed_cleanup_output" "Docker 完全クリーンアップが完了しました"
assert_contains "$FAKE_DOCKER_CALLS" "container unpause cid-paused"
assert_contains "$FAKE_DOCKER_CALLS" "container stop cid-running cid-paused"
assert_contains "$FAKE_DOCKER_CALLS" "container prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "builder prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "image prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "volume prune --all --force"
assert_contains "$FAKE_DOCKER_CALLS" "network prune --force"
assert_contains "$FAKE_DOCKER_CALLS" "system prune --all --volumes --force"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down"

# ---- ディスク使用量の抑制 ---------------------------------------------------
# 検証を繰り返すと、ローカルイメージの旧世代 (dangling) とビルドキャッシュが
# 実行のたびに積み上がる。その回収と計測を行う 3 つの機能を確認する。
#
# 直前のクリーンアップシナリオが FAKE_DOCKER_CLEANED を export したままだと、
# fake docker が「全削除済み」として system df に 0 B を返し、容量の計測結果が
# 変わってしまう。自分のシナリオで使う fixture を明示的に設定し直す。
unset FAKE_DOCKER_CLEANED FAKE_COMPOSE_SHUTDOWN_MARKER FAKE_COMPOSE_NO_CONTAINERS \
      FAKE_COMPOSE_UP_FAIL FAKE_DOCKER_BUILD_FAIL FAKE_COMPOSE_CONFIG_SERVICES \
      FAKE_COMPOSE_PS_SERVICES
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"

# fake docker はこのファイルの内容を image inspect の {{.Id}} として返し、
# compose build のたびに「ビルド後の ID」で上書きする (世代交代の再現)。
disk_image_id_file="$TEST_TMP/image-id"
export FAKE_DOCKER_IMAGE_ID_FILE="$disk_image_id_file"

# (1) 既定でビルド前後の ID を突き合わせ、世代交代した旧イメージを削除する
reclaim_image_output="$TEST_TMP/reclaim-image.out"
printf 'sha256:image-before-build\n' > "$disk_image_id_file"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --no-cache
) >"$reclaim_image_output" 2>&1; then
  cat "$reclaim_image_output" >&2
  fail "reclaiming the previous image returned a non-zero status"
fi

assert_contains "$reclaim_image_output" "世代交代した旧イメージを削除します: sha256:image-before-build"
assert_contains "$FAKE_DOCKER_CALLS" "image rm sha256:image-before-build"
# 削除するのは今回のビルドで生じた 1 件だけで、prune は使わない
# (同じ Docker daemon を使う他プロジェクトの dangling を巻き込まないため)。
assert_not_contains "$FAKE_DOCKER_CALLS" "image prune"
# --no-cache 指定時は、キャッシュが書き込まれ続ける点を案内する
assert_contains "$reclaim_image_output" "--no-cache は既存キャッシュを読まない指定で、書き込みは行われます"

# (2) --no-reclaim-old-image を指定すると旧イメージを残す
keep_image_output="$TEST_TMP/keep-old-image.out"
printf 'sha256:image-before-build\n' > "$disk_image_id_file"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --no-cache --no-reclaim-old-image
) >"$keep_image_output" 2>&1; then
  cat "$keep_image_output" >&2
  fail "--no-reclaim-old-image returned a non-zero status"
fi

assert_not_contains "$keep_image_output" "世代交代した旧イメージを削除します"
assert_not_contains "$FAKE_DOCKER_CALLS" "image rm"
# 回収しないなら、判定用の ID 取得そのものを行わない
assert_not_contains "$FAKE_DOCKER_CALLS" "image inspect --format {{.Id}} j1/base.local"

# (3) 旧 ID が別のタグから参照されている場合は dangling ではないため削除しない
tagged_image_output="$TEST_TMP/tagged-old-image.out"
printf 'sha256:image-before-build\n' > "$disk_image_id_file"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  FAKE_DOCKER_IMAGE_REPOTAGS=2 bash ./build_and_verify.sh
) >"$tagged_image_output" 2>&1; then
  cat "$tagged_image_output" >&2
  fail "tagged previous image returned a non-zero status"
fi

assert_contains "$tagged_image_output" "旧世代イメージは別のタグから参照されているため残します: sha256:image-before-build"
assert_not_contains "$FAKE_DOCKER_CALLS" "image rm"

# (4) ビルドしても ID が変わらなければ削除対象は無い
same_image_output="$TEST_TMP/same-image.out"
unset FAKE_DOCKER_IMAGE_ID_FILE
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh
) >"$same_image_output" 2>&1; then
  cat "$same_image_output" >&2
  fail "unchanged image id returned a non-zero status"
fi

assert_contains "$same_image_output" "ローカルイメージは世代交代していないため、削除するイメージはありません: j1/base.local"
assert_not_contains "$FAKE_DOCKER_CALLS" "image rm"

# (5) 削除に失敗しても警告のみで、ビルド自体は成功のまま終える
rm_failed_output="$TEST_TMP/reclaim-image-failed.out"
export FAKE_DOCKER_IMAGE_ID_FILE="$disk_image_id_file"
printf 'sha256:image-before-build\n' > "$disk_image_id_file"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  FAKE_DOCKER_IMAGE_RM_FAIL=true bash ./build_and_verify.sh
) >"$rm_failed_output" 2>&1; then
  cat "$rm_failed_output" >&2
  fail "a failed image removal must not change the exit status"
fi

assert_contains "$rm_failed_output" "旧イメージを削除できませんでした (他から使用中の可能性があります): sha256:image-before-build"
assert_contains "$rm_failed_output" "手動で削除する場合: docker image rm sha256:image-before-build"
unset FAKE_DOCKER_IMAGE_ID_FILE

# (6) --disk-usage-report と --prune-build-cache-keep
#     fake docker の system df は FAKE_DOCKER_DF_COUNTER を指定すると、
#     呼び出しのたびにビルドキャッシュが 400MB ずつ増える。
#     1 回目 (ビルド前): 2GB + 100MB + 500MB + 400MB  = 2.79 GiB
#     2 回目 (終了時)  : 2GB + 100MB + 500MB + 800MB  = 3.17 GiB (+381.47 MiB)
disk_report_output="$TEST_TMP/disk-usage-report.out"
export FAKE_DOCKER_DF_COUNTER="$TEST_TMP/df.count"
: > "$FAKE_DOCKER_DF_COUNTER"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --disk-usage-report --prune-build-cache-keep 10GB
) >"$disk_report_output" 2>&1; then
  cat "$disk_report_output" >&2
  fail "--disk-usage-report returned a non-zero status"
fi

assert_contains "$disk_report_output" "Docker 使用量 (ビルド前): 2.79 GiB (docker system df による概算)"
assert_contains "$disk_report_output" "Docker 使用量 (終了時): 3.17 GiB (docker system df による概算)"
assert_contains "$disk_report_output" "実行前からの増減: +381.47 MiB"
assert_contains "$disk_report_output" "ビルドキャッシュを削除します (docker builder prune --force --keep-storage 10GB)"
assert_contains "$FAKE_DOCKER_CALLS" "builder prune --force --keep-storage 10GB"
# 計測はビルドの前に行う (ビルドで増えた分を増減へ含めるため)
assert_before "$disk_report_output" "Docker 使用量 (ビルド前)" "docker compose build を実行します"
unset FAKE_DOCKER_DF_COUNTER

# (7) --prune-build-cache は容量指定なしで全削除する
prune_all_cache_output="$TEST_TMP/prune-build-cache.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --no-cache --prune-build-cache
) >"$prune_all_cache_output" 2>&1; then
  cat "$prune_all_cache_output" >&2
  fail "--prune-build-cache returned a non-zero status"
fi

assert_contains "$FAKE_DOCKER_CALLS" "builder prune --force --all"
# キャッシュを片付ける指定があるときは、--no-cache の案内を重ねて出さない
assert_not_contains "$prune_all_cache_output" "終了時にキャッシュを片付けるには --prune-build-cache を併用してください"

# (8) --keep-storage を持たない buildx では削除せず警告に留める
no_keep_storage_output="$TEST_TMP/no-keep-storage.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  FAKE_DOCKER_NO_KEEP_STORAGE=true bash ./build_and_verify.sh --prune-build-cache-keep 512MB
) >"$no_keep_storage_output" 2>&1; then
  cat "$no_keep_storage_output" >&2
  fail "missing --keep-storage support must not change the exit status"
fi

assert_contains "$no_keep_storage_output" "この環境の docker builder prune は --keep-storage を持たないため、ビルドキャッシュを削除しません"
assert_not_contains "$FAKE_DOCKER_CALLS" "builder prune --force --keep-storage"

# (9) --dry-run では削除を行わず、実行予定だけを表示する
disk_dry_run_output="$TEST_TMP/disk-usage-dry-run.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --no-cache --prune-build-cache --disk-usage-report
) >"$disk_dry_run_output" 2>&1; then
  cat "$disk_dry_run_output" >&2
  fail "disk usage options with --dry-run returned a non-zero status"
fi

assert_contains "$disk_dry_run_output" "[DRY-RUN] docker builder prune --force --all"
assert_contains "$disk_dry_run_output" "[DRY-RUN] 世代交代した旧イメージの削除は行いません"
assert_contains "$disk_dry_run_output" "Docker 使用量 (ビルド前):"
assert_not_contains "$FAKE_DOCKER_CALLS" "builder prune --force --all"
assert_not_contains "$FAKE_DOCKER_CALLS" "image rm"

# (10) --prune-build-cache-keep の書式チェック
invalid_keep_output="$TEST_TMP/invalid-keep-storage.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --prune-build-cache-keep '10ギガ'
) >"$invalid_keep_output" 2>&1; then
  cat "$invalid_keep_output" >&2
  fail "an invalid --prune-build-cache-keep value unexpectedly returned zero"
fi
assert_contains "$invalid_keep_output" "--prune-build-cache-keep にはサイズを指定してください (例: 10GB / 512MB): 10ギガ"

# (11) --cleanup-all-docker-data 併用時は、削除前後の容量表示と重複させない
cleanup_disk_report_output="$TEST_TMP/cleanup-disk-report.out"
export FAKE_DOCKER_CLEANED="$TEST_TMP/docker-cleaned-disk-report"
rm -f -- "$FAKE_DOCKER_CLEANED"
: > "$FAKE_DOCKER_CALLS"
if ! printf 'DELETE ALL DOCKER DATA\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --disk-usage-report --cleanup-all-docker-data
) >"$cleanup_disk_report_output" 2>&1; then
  cat "$cleanup_disk_report_output" >&2
  fail "--disk-usage-report with --cleanup-all-docker-data returned a non-zero status"
fi

assert_contains "$cleanup_disk_report_output" "容量削減結果 (Docker 管理対象・概算)"
assert_not_contains "$cleanup_disk_report_output" "Docker 使用量 (終了時)"

unset FAKE_DOCKER_CLEANED FAKE_DOCKER_IMAGE_ID_FILE FAKE_DOCKER_DF_COUNTER

# ---- JBoss マスターパスワードの伝搬検証 -------------------------------------
# compose.yml の環境変数 → BuildKit シークレット → Elytron CredentialStore →
# jboss-cli が生成した standalone.xml → 実行時の値、の各段でパスワードが
# 一致しているかを検証する機能。$ # " ` & を含むパスワードで確認する。
#
# ここまでのシナリオが export した fixture 切り替え用の変数を引き継ぐと、
# 起動確認やクリーンアップの挙動が変わってしまうため、先にすべて解除する。
unset FAKE_DOCKER_CLEANED FAKE_COMPOSE_SHUTDOWN_MARKER FAKE_COMPOSE_NO_CONTAINERS \
      FAKE_COMPOSE_UP_FAIL FAKE_DOCKER_BUILD_FAIL FAKE_COMPOSE_CONFIG_SERVICES \
      FAKE_COMPOSE_PS_SERVICES FAKE_DOCKER_FIND_FAIL FAKE_DOCKER_NO_JAVA_PROCESS \
      FAKE_JBOSS_SECRET_VALUE FAKE_JBOSS_SECRET_MISSING FAKE_JBOSS_PROBE_BUILD_FAIL \
      FAKE_JBOSS_HOME FAKE_JBOSS_CS_PASSWORD FAKE_JBOSS_ELYTRON_TOOL_MISSING \
      FAKE_JBOSS_CS_FILE_MISSING

jboss_password_fixture='pa$w#o"r`d&x'
jboss_standalone_xml="$TEST_TMP/standalone.xml"
cat > "$jboss_standalone_xml" <<'XML'
<?xml version="1.0" ?>
<server>
  <!-- コメント内の <credential-store name="commented-out"> は解析対象外 -->
  <profile>
    <subsystem xmlns="urn:wildfly:elytron:18.0">
      <credential-stores>
        <credential-store name="jbossCS" path="credential-store.jceks" relative-to="jboss.server.config.dir">
          <credential-reference clear-text="pa$$w#o&quot;r`d&amp;x"/>
        </credential-store>
      </credential-stores>
    </subsystem>
    <subsystem xmlns="urn:jboss:domain:datasources:7.0">
      <datasources>
        <datasource jndi-name="java:/OrdersDS" pool-name="OrdersDS">
          <security><credential-reference store="jbossCS" alias="orders-db-pw"/></security>
        </datasource>
      </datasources>
    </subsystem>
  </profile>
</server>
XML

# --- 全段一致するケース ---
jboss_match_output="$TEST_TMP/jboss-password-match.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_JBOSS_STANDALONE_XML="$jboss_standalone_xml"
if ! (
  cd "$REPO_ROOT"
  JBOSS_MASTER_PASSWORD="$jboss_password_fixture" bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --verify-jboss-password \
    --report-dir "$TEST_TMP/jboss-reports" \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$jboss_match_output" 2>&1; then
  cat "$jboss_match_output" >&2
  fail "jboss password verification (match) returned a non-zero status"
fi

# リスク分析は、実際に含まれる文字だけを挙げること
assert_contains "$jboss_match_output" "[パスワード文字列のリスク分析]"
assert_contains "$jboss_match_output" "(ドル記号)"
assert_contains "$jboss_match_output" "(シャープ)"
assert_contains "$jboss_match_output" "(二重引用符)"
assert_contains "$jboss_match_output" "(バッククォート)"
assert_contains "$jboss_match_output" "(アンパサンド)"
assert_not_contains "$jboss_match_output" "(パーセント)"

# 段ごとの判定
assert_contains "$jboss_match_output" "[一致] (1) 取得元 → 環境変数 JBOSS_MASTER_PASSWORD"
assert_contains "$jboss_match_output" "[一致] (2) compose.yml の secrets 定義"
assert_contains "$jboss_match_output" "secrets.jboss_master_password.environment: JBOSS_MASTER_PASSWORD"
assert_contains "$jboss_match_output" "[一致] (3) BuildKit シークレット → ビルド中コンテナの /run/secrets/jboss_master_password"
assert_contains "$jboss_match_output" "[情報] (4) standalone.xml のマスターパスワード定義"
assert_contains "$jboss_match_output" "[一致 (エスケープ済み)] (5) standalone.xml → WildFly が実行時に解釈する値"
assert_contains "$jboss_match_output" "[一致] (6) Elytron CredentialStore をマスターパスワードで開けるか"
assert_contains "$jboss_match_output" "[情報] (7) CredentialStore の値を利用している箇所"
assert_contains "$jboss_match_output" "store=jbossCS, alias=orders-db-pw"
assert_contains "$jboss_match_output" "リソース: OrdersDS"
assert_not_contains "$jboss_match_output" "commented-out"

# 一致した場合も、一致したパスワード文字列を表示すること
assert_contains "$jboss_match_output" "一致した文字列: $jboss_password_fixture"
assert_contains "$jboss_match_output" "16 進ダンプ   : 70 61 24 77 23 6f 22 72 60 64 26 78"
assert_contains "$jboss_match_output" "総合判定: 全段一致"
assert_contains "$jboss_match_output" "一致したパスワード文字列: $jboss_password_fixture"
# ファイル上の表記 (XML エスケープ + WildFly の $$) も見えること
assert_contains "$jboss_match_output" 'pa$$w#o&quot;r`d&amp;x'
# どの段にも不一致の判定が出ないこと (総括の「不一致なし」は本文に含まれるため、
# 判定ラベルの角括弧付きで確認する)
assert_not_contains "$jboss_match_output" "[不一致"
assert_contains "$jboss_match_output" "伝搬検証が完了しました (不一致なし)"

# 全量レポートにも同じ内容が残ること
collect_report_files "$TEST_TMP/jboss-reports"
jboss_report_files=("${REPORT_FILES[@]}")
[ -f "${jboss_report_files[0]}" ] || fail "jboss password report was not created"
assert_contains "${jboss_report_files[0]}" "[7] JBoss マスターパスワードの伝搬検証"
assert_contains "${jboss_report_files[0]}" "総合判定      : 全段一致"
assert_contains "${jboss_report_files[0]}" "原本の文字列  : $jboss_password_fixture"
assert_contains "${jboss_report_files[0]}" "[9] Compose サービス別ログ (全サービス・全行)"
assert_before "${jboss_report_files[0]}" "[7] JBoss マスターパスワードの伝搬検証" "[9] Compose サービス別ログ (全サービス・全行)"

# --- 各段で食い違うケース ---
# ビルドへ届いた値は # 以降が切り捨てられ、standalone.xml と CredentialStore にも
# 別の値が設定されている状況を再現する。
jboss_mismatch_xml="$TEST_TMP/standalone-mismatch.xml"
cat > "$jboss_mismatch_xml" <<'XML'
<?xml version="1.0" ?>
<server>
  <profile>
    <subsystem xmlns="urn:wildfly:elytron:18.0">
      <credential-stores>
        <credential-store name="jbossCS" path="credential-store.jceks" relative-to="jboss.server.config.dir">
          <credential-reference clear-text="pa$w"/>
        </credential-store>
      </credential-stores>
    </subsystem>
  </profile>
</server>
XML
jboss_mismatch_output="$TEST_TMP/jboss-password-mismatch.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_JBOSS_STANDALONE_XML="$jboss_mismatch_xml"
export FAKE_JBOSS_SECRET_VALUE='pa$w'
export FAKE_JBOSS_CS_PASSWORD='pa$w'
if ! (
  cd "$REPO_ROOT"
  JBOSS_MASTER_PASSWORD="$jboss_password_fixture" bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --verify-jboss-password \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$jboss_mismatch_output" 2>&1; then
  cat "$jboss_mismatch_output" >&2
  fail "jboss password verification (mismatch) returned a non-zero status"
fi

# 不一致の段では、原本と実際に設定されている文字列の双方を表示すること
assert_contains "$jboss_mismatch_output" "[不一致] (3) BuildKit シークレット"
assert_contains "$jboss_mismatch_output" "原本 (取得元) : $jboss_password_fixture"
assert_contains "$jboss_mismatch_output" '実際に設定されている文字列: pa$w'
assert_contains "$jboss_mismatch_output" "16 進ダンプ : 70 61 24 77"
assert_contains "$jboss_mismatch_output" "5 バイト目から相違 (原本: 23 / 実際: (ここで終端))"
assert_contains "$jboss_mismatch_output" "[不一致] (5) standalone.xml → WildFly が実行時に解釈する値"
assert_contains "$jboss_mismatch_output" "[不一致] (6) Elytron CredentialStore をマスターパスワードで開けるか"
assert_contains "$jboss_mismatch_output" "CredentialStore からは設定済みのパスワードを取り出せないため"
assert_contains "$jboss_mismatch_output" "総合判定: 不一致あり"
assert_contains "$jboss_mismatch_output" "JBoss マスターパスワードの伝搬検証で不一致を検出しました"
unset FAKE_JBOSS_SECRET_VALUE FAKE_JBOSS_CS_PASSWORD

# --- $ のエスケープ漏れで ${...} が式として残るケース ---
jboss_expr_xml="$TEST_TMP/standalone-expression.xml"
cat > "$jboss_expr_xml" <<'XML'
<?xml version="1.0" ?>
<server>
  <profile>
    <subsystem xmlns="urn:wildfly:elytron:18.0">
      <credential-stores>
        <credential-store name="jbossCS" path="credential-store.jceks" relative-to="jboss.server.config.dir">
          <credential-reference clear-text="pa${env.MISSING}word"/>
        </credential-store>
      </credential-stores>
    </subsystem>
  </profile>
</server>
XML
jboss_expr_output="$TEST_TMP/jboss-password-expression.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_JBOSS_STANDALONE_XML="$jboss_expr_xml"
if ! (
  cd "$REPO_ROOT"
  JBOSS_MASTER_PASSWORD='pa${env.MISSING}word' bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --verify-jboss-password \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$jboss_expr_output" 2>&1; then
  cat "$jboss_expr_output" >&2
  fail "jboss password verification (expression) returned a non-zero status"
fi

assert_contains "$jboss_expr_output" "[不一致 (式が未解決)]"
assert_contains "$jboss_expr_output" 'へエスケープできていない可能性が高いです'
assert_contains "$jboss_expr_output" 'jboss-cli への登録時に $ を $$ へエスケープしてください'
# 式の段はバイト比較に意味が無いため、相違位置を出さないこと
assert_not_contains "$jboss_expr_output" "相違位置      : 差分なし"

# --- --jboss-password-mask で平文を伏せるケース ---
jboss_mask_output="$TEST_TMP/jboss-password-mask.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_JBOSS_STANDALONE_XML="$jboss_standalone_xml"
if ! (
  cd "$REPO_ROOT"
  JBOSS_MASTER_PASSWORD="$jboss_password_fixture" bash ./build_and_verify.sh \
    --verify-jboss-password \
    --jboss-password-mask
) >"$jboss_mask_output" 2>&1; then
  cat "$jboss_mask_output" >&2
  fail "jboss password verification (mask) returned a non-zero status"
fi

assert_contains "$jboss_mask_output" "--jboss-password-mask により非表示: 12 バイト"
assert_not_contains "$jboss_mask_output" "一致した文字列: $jboss_password_fixture"
# 伏字でも判定と 16 進ダンプは残す (切り分けに必要なため)
assert_contains "$jboss_mask_output" "16 進ダンプ   : 70 61 24 77 23 6f 22 72 60 64 26 78"
# コンテナ未起動時は、その旨を未確認として記録すること
assert_contains "$jboss_mask_output" "[未確認] (4) standalone.xml / Elytron CredentialStore の検証"
assert_contains "$jboss_mask_output" "総合判定: 確認できた段はすべて一致 (未確認の段あり)"

# --- compose.yml の environment 名が食い違うケース ---
jboss_bad_compose="$TEST_TMP/bad-compose.yml"
cat > "$jboss_bad_compose" <<'YML'
services:
  base:
    build:
      context: .
      dockerfile: Dockerfile
      secrets:
        - jboss_master_password
    image: j1/base.local
secrets:
  jboss_master_password:
    environment: SOME_OTHER_NAME
YML
jboss_bad_compose_output="$TEST_TMP/jboss-bad-compose.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  JBOSS_MASTER_PASSWORD="$jboss_password_fixture" bash ./build_and_verify.sh \
    --verify-jboss-password \
    --compose-file "$jboss_bad_compose"
) >"$jboss_bad_compose_output" 2>&1; then
  cat "$jboss_bad_compose_output" >&2
  fail "jboss password verification (bad compose) returned a non-zero status"
fi

assert_contains "$jboss_bad_compose_output" "[不一致] (2) compose.yml の secrets 定義"
assert_contains "$jboss_bad_compose_output" "は 'SOME_OTHER_NAME' を参照していますが"
assert_contains "$jboss_bad_compose_output" "ビルドには空の値が渡ります"

# --- 原本を取得できない場合はオプションエラーとすること ---
jboss_no_password_output="$TEST_TMP/jboss-no-password.out"
if (
  cd "$REPO_ROOT"
  env -u JBOSS_MASTER_PASSWORD bash ./build_and_verify.sh --verify-jboss-password
) >"$jboss_no_password_output" 2>&1; then
  cat "$jboss_no_password_output" >&2
  fail "jboss password verification without a password unexpectedly returned zero"
fi
assert_contains "$jboss_no_password_output" "--verify-jboss-password には検証対象のマスターパスワードが必要です"

unset FAKE_JBOSS_STANDALONE_XML

# ---- JBoss EAP Undertow バーチャルホスト (default-host) の分析 ---------------
# standalone.xml の undertow subsystem を読み、Host ヘッダーごとにどのバーチャル
# ホストが処理するのか (default-host が受け皿として使われるのか) を判定する機能。
# 既定で画面とテキストの両方へ出力し、パラメータで抑制できることまで確認する。
#
# ここまでのシナリオが export した fixture 切り替え用の変数を引き継ぐと、
# 起動確認やコンテナ一覧の挙動が変わってしまうため、先にすべて解除する。
unset FAKE_DOCKER_CLEANED FAKE_COMPOSE_SHUTDOWN_MARKER FAKE_COMPOSE_NO_CONTAINERS \
      FAKE_COMPOSE_UP_FAIL FAKE_DOCKER_BUILD_FAIL FAKE_COMPOSE_CONFIG_SERVICES \
      FAKE_COMPOSE_PS_SERVICES FAKE_DOCKER_FIND_FAIL FAKE_DOCKER_NO_JAVA_PROCESS \
      FAKE_JBOSS_SECRET_VALUE FAKE_JBOSS_SECRET_MISSING FAKE_JBOSS_PROBE_BUILD_FAIL \
      FAKE_JBOSS_HOME FAKE_JBOSS_CS_PASSWORD FAKE_JBOSS_ELYTRON_TOOL_MISSING \
      FAKE_JBOSS_CS_FILE_MISSING

export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_JBOSS_STANDALONE_XML="$TEST_DIR/fixtures/standalone-undertow.xml"
# default-host へ落ちたリクエストだけ 404 を返し、振り分けの違いを応答で示す。
export FAKE_UNDERTOW_404_HOSTS="app test-app-1 172.20.0.2 undertow-default-host-check.invalid extra.example.jp"

# --- 既定 (オプション指定なし) で画面とテキストの両方へ出力する ---
undertow_output="$TEST_TMP/undertow-default.out"
undertow_reports="$TEST_TMP/undertow-reports"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --report-dir "$undertow_reports" \
    --undertow-host-header extra.example.jp,orders.example.jp:8443 \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$undertow_output" 2>&1; then
  cat "$undertow_output" >&2
  fail "undertow virtual host analysis returned a non-zero status"
fi

# 見出しと設定ファイルの特定
assert_contains "$undertow_output" "JBoss EAP Undertow バーチャルホスト (default-host) 分析"
assert_contains "$undertow_output" "Undertow バーチャルホスト分析 (サービス: app / コンテナ: test-app-1)"
assert_contains "$undertow_output" "名前空間      : urn:jboss:domain:undertow:14.0"

# [1] subsystem の既定値。XML に書かれた値と、書かれていないスキーマ既定値を区別する
assert_contains "$undertow_output" "default-virtual-host     : default-host"
assert_contains "$undertow_output" "default-security-domain  : other"

# [2] server とリスナー。default-host は XML に無いためスキーマ既定値と示す
assert_contains "$undertow_output" "default-host      : default-host (既定値)"
assert_contains "$undertow_output" "servlet-container : default (既定値)"
assert_contains "$undertow_output" "http-listener   'default' socket-binding=http"
assert_contains "$undertow_output" "https-listener  'https' socket-binding=https"
assert_contains "$undertow_output" "ajp-listener    'ajp' socket-binding=ajp"

# [3] バーチャルホストと別名。コメント内の host は拾わないこと
assert_contains "$undertow_output" "host 'default-host' (server: default-server) [subsystem の default-virtual-host] [server の default-host]"
assert_contains "$undertow_output" "host 'admin-host' (server: default-server)"
assert_contains "$undertow_output" "default-web-module: admin.war"
assert_not_contains "$undertow_output" "commented-out-host"
assert_not_contains "$undertow_output" "ghost.example.com"

# [4] Host ヘッダーごとの振り分け。設定由来・呼び出し由来・利用者指定を区別する
assert_matches "$undertow_output" 'localhost +default-host +別名に一致 \(default-host は不使用\)'
assert_matches "$undertow_output" 'orders\.example\.jp +default-host +別名に一致'
assert_matches "$undertow_output" 'admin-host +admin-host +name に一致'
assert_matches "$undertow_output" 'app +default-host +一致なし → default-host を使用 / Compose サービス名'
assert_matches "$undertow_output" 'test-app-1 +default-host +一致なし → default-host を使用 / コンテナ名'
assert_matches "$undertow_output" '172\.20\.0\.2 +default-host +一致なし → default-host を使用 / コンテナ IP'
assert_matches "$undertow_output" 'extra\.example\.jp +default-host +一致なし → default-host を使用 / --undertow-host-header'
# ポート付きで渡した名前は Undertow と同じ規則でポートを落として判定する
assert_not_contains "$undertow_output" "orders.example.jp:8443"

# [5] default-host 設定の利用状況
assert_contains "$undertow_output" "[5] default-host 設定の利用状況"
assert_contains "$undertow_output" "受け皿となる default-host : default-host"
assert_contains "$undertow_output" "同名の host 定義          : あり"
assert_contains "$undertow_output" "→ 次の Host ヘッダーで呼ばれた場合、default-host ('default-host') が処理します:"
assert_contains "$undertow_output" "      - app (Compose サービス名)"
assert_contains "$undertow_output" "      - extra.example.jp (--undertow-host-header)"

# [6] 実リクエスト。default-host へ落ちた名前だけ 404 になる fixture
assert_contains "$undertow_output" "[6] 実リクエストによる確認"
assert_contains "$undertow_output" "送信内容      : GET /orders (Host ヘッダーだけを差し替えた読み取りリクエスト)"
assert_contains "$undertow_output" "送信元        : コンテナ内 (http://127.0.0.1:8080/orders)"
assert_matches "$undertow_output" 'localhost +HTTP 200 +.default-host. が処理'
assert_matches "$undertow_output" 'app +HTTP 404 +default-host \(.default-host.\) が処理'
assert_matches "$undertow_output" 'undertow-default-host-check\.invalid +HTTP 404 +default-host'

# [7] 別名を持たない host は指摘する
assert_contains "$undertow_output" "[7] 要確認"
assert_contains "$undertow_output" "host 'admin-host' に別名がありません。"

# 総合判定の行。この fixture は要確認が 1 件出るため、判定は WARN 側の
# 「判定: ...」行へ載る (指摘が無い場合は「Undertow バーチャルホスト分析: ...」)。
assert_matches "$undertow_output" '判定: バーチャルホスト 2 件、判定した Host ヘッダー [0-9]+ 件のうち [0-9]+ 件が default-host へ渡ります \(要確認 1 件\)'
assert_matches "$undertow_output" '対象 1 サービス、バーチャルホスト 2 件、判定した Host ヘッダー 10 件 \(うち default-host 経由 6 件\)'

# テキストファイルが --report-dir 配下へ自動出力され、画面と同じ内容を持つこと
undertow_text="$(ls "$undertow_reports"/build_and_verify_*_undertow_virtual_host.txt 2>/dev/null | head -n 1)"
[ -n "$undertow_text" ] && [ -f "$undertow_text" ] \
  || fail "expected an undertow virtual host analysis text file under $undertow_reports"
assert_contains "$undertow_text" "build_and_verify.sh Undertow バーチャルホスト (default-host) 分析"
assert_contains "$undertow_text" "[5] default-host 設定の利用状況"
assert_contains "$undertow_text" "受け皿となる default-host : default-host"
assert_contains "$undertow_output" "Undertow バーチャルホスト分析のテキストを出力しました: $undertow_text"

# 全量レポートの [12] にも同じ結果が載ること
collect_report_files "$undertow_reports"
[ ${#REPORT_FILES[@]} -eq 1 ] || fail "expected one full build report for the undertow scenario"
assert_contains "${REPORT_FILES[0]}" "[12] JBoss EAP Undertow バーチャルホスト (default-host) の分析"
assert_contains "${REPORT_FILES[0]}" "[5] default-host 設定の利用状況"
assert_contains "${REPORT_FILES[0]}" "テキスト      : $undertow_text (この節と同じ内容)"

# --- 設定の食い違いを指摘するケース ---
undertow_mismatch_output="$TEST_TMP/undertow-mismatch.out"
export FAKE_JBOSS_STANDALONE_XML="$TEST_DIR/fixtures/standalone-undertow-mismatch.xml"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --no-undertow-probe \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$undertow_mismatch_output" 2>&1; then
  cat "$undertow_mismatch_output" >&2
  fail "undertow mismatch scenario returned a non-zero status"
fi

# 受け皿は server の default-host であって、subsystem の default-virtual-host ではない
assert_contains "$undertow_mismatch_output" "default-host      : fallback-host"
assert_contains "$undertow_mismatch_output" "default-virtual-host     : app-host"
assert_contains "$undertow_mismatch_output" "受け皿となる default-host : fallback-host"
assert_contains "$undertow_mismatch_output" "subsystem の default-virtual-host ('app-host') と server の default-host ('fallback-host') が異なります。"
# 大文字を含む別名は、小文字の Host ヘッダーと一致しないことを指摘する
assert_contains "$undertow_mismatch_output" "の名前 'Orders.Example.JP' に大文字が含まれます。"
assert_contains "$undertow_mismatch_output" "'orders.example.jp' のように表記の違う Host ヘッダーでは一致せず default-host へ渡ります。"
# 同じ別名を複数の host が登録している場合も指摘する
assert_contains "$undertow_mismatch_output" "名前 'localhost' を複数の host が登録しています。"
# --no-undertow-probe を指定したので実リクエストは送らない
assert_contains "$undertow_mismatch_output" "--no-undertow-probe が指定されたため送信していません。"
assert_not_contains "$undertow_mismatch_output" "送信元        : コンテナ内"
assert_not_contains "$FAKE_DOCKER_CALLS" "undertow-host-probe"

# --- --no-undertow-analysis で分析ごと抑制する ---
undertow_off_output="$TEST_TMP/undertow-off.out"
undertow_off_reports="$TEST_TMP/undertow-off-reports"
export FAKE_JBOSS_STANDALONE_XML="$TEST_DIR/fixtures/standalone-undertow.xml"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --report-dir "$undertow_off_reports" \
    --no-undertow-analysis \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$undertow_off_output" 2>&1; then
  cat "$undertow_off_output" >&2
  fail "--no-undertow-analysis returned a non-zero status"
fi
assert_not_contains "$undertow_off_output" "JBoss EAP Undertow バーチャルホスト (default-host) 分析"
assert_not_contains "$undertow_off_output" "[5] default-host 設定の利用状況"
[ -z "$(ls "$undertow_off_reports"/build_and_verify_*_undertow_virtual_host.txt 2>/dev/null)" ] \
  || fail "--no-undertow-analysis unexpectedly wrote an undertow analysis text file"
collect_report_files "$undertow_off_reports"
assert_contains "${REPORT_FILES[0]}" "--no-undertow-analysis が指定されたため分析していません。"

# --- --no-undertow-analysis-display は画面だけを抑制し、テキストは残す ---
undertow_nodisp_output="$TEST_TMP/undertow-nodisplay.out"
undertow_nodisp_reports="$TEST_TMP/undertow-nodisplay-reports"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --report-dir "$undertow_nodisp_reports" \
    --no-undertow-analysis-display \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$undertow_nodisp_output" 2>&1; then
  cat "$undertow_nodisp_output" >&2
  fail "--no-undertow-analysis-display returned a non-zero status"
fi
assert_not_contains "$undertow_nodisp_output" "[5] default-host 設定の利用状況"
assert_contains "$undertow_nodisp_output" "画面表示は --no-undertow-analysis-display により省略"
undertow_nodisp_text="$(ls "$undertow_nodisp_reports"/build_and_verify_*_undertow_virtual_host.txt 2>/dev/null | head -n 1)"
[ -n "$undertow_nodisp_text" ] \
  || fail "--no-undertow-analysis-display should still write the analysis text file"
assert_contains "$undertow_nodisp_text" "[5] default-host 設定の利用状況"

# --- --no-undertow-analysis-text はテキストだけを抑制し、画面へは出す ---
undertow_notext_output="$TEST_TMP/undertow-notext.out"
undertow_notext_reports="$TEST_TMP/undertow-notext-reports"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --report-dir "$undertow_notext_reports" \
    --no-undertow-analysis-text \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$undertow_notext_output" 2>&1; then
  cat "$undertow_notext_output" >&2
  fail "--no-undertow-analysis-text returned a non-zero status"
fi
assert_contains "$undertow_notext_output" "[5] default-host 設定の利用状況"
assert_contains "$undertow_notext_output" "テキスト出力は --no-undertow-analysis-text により行いません。"
[ -z "$(ls "$undertow_notext_reports"/build_and_verify_*_undertow_virtual_host.txt 2>/dev/null)" ] \
  || fail "--no-undertow-analysis-text unexpectedly wrote an undertow analysis text file"

# --- 矛盾するオプションの組み合わせは起動前に弾く ---
undertow_conflict_output="$TEST_TMP/undertow-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --no-undertow-analysis --undertow-analysis-text "$TEST_TMP/x.txt"
) >"$undertow_conflict_output" 2>&1; then
  cat "$undertow_conflict_output" >&2
  fail "--no-undertow-analysis with --undertow-analysis-text unexpectedly returned zero"
fi
assert_contains "$undertow_conflict_output" "--undertow-analysis-text と --no-undertow-analysis は同時に指定できません。"

undertow_conflict2_output="$TEST_TMP/undertow-conflict2.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --no-undertow-analysis-display --no-undertow-analysis-text
) >"$undertow_conflict2_output" 2>&1; then
  cat "$undertow_conflict2_output" >&2
  fail "suppressing both undertow outputs unexpectedly returned zero"
fi
assert_contains "$undertow_conflict2_output" "--no-undertow-analysis-display と --no-undertow-analysis-text を同時に指定すると出力先が無くなります。"

undertow_conflict3_output="$TEST_TMP/undertow-conflict3.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --undertow-probe-path "orders"
) >"$undertow_conflict3_output" 2>&1; then
  cat "$undertow_conflict3_output" >&2
  fail "a relative --undertow-probe-path unexpectedly returned zero"
fi
assert_contains "$undertow_conflict3_output" "--undertow-probe-path には / で始まるパスを指定してください: orders"

unset FAKE_JBOSS_STANDALONE_XML FAKE_UNDERTOW_404_HOSTS

# ---- CloudWatch Agent (cwagent) のログ送信検証 -------------------------------
# compose.yml の cwagent 定義と設定 JSON の静的チェック (ビルド前) と、起動後の
# 送達チェックを、正常系・異常系の双方で確認する。
cwagent_fixture_dir="$TEST_DIR/fixtures/cwagent"

# --- 設定・送信先・収集対象がすべて揃っているケース ---
cwagent_verify_output="$TEST_TMP/cwagent-verify.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app cwagent cloudwatch-logs-mock"
export FAKE_COMPOSE_CONFIG_SERVICES="base app cwagent cloudwatch-logs-mock"
export FAKE_CLOUDWATCH_JOURNAL_FILE="$TEST_DIR/fixtures/cloudwatch-wiremock-requests.json"
export FAKE_CWAGENT_CONFIG_FILE="$cwagent_fixture_dir/cwagent-config.json"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent.yml" \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs \
    --cwagent-delivery-report \
    --report-dir "$TEST_TMP/cwagent-reports"
) >"$cwagent_verify_output" 2>&1; then
  cat "$cwagent_verify_output" >&2
  fail "cwagent log delivery verification returned a non-zero status"
fi

# 静的チェック (ビルド前) はビルドコマンドより先に出力されること
assert_contains "$cwagent_verify_output" "ビルド前の設定ファイルチェック"
assert_before "$cwagent_verify_output" "ビルド前の設定ファイルチェック" \
  "BuildKit のビルドログ表示形式: plain"
assert_contains "$cwagent_verify_output" "[OK] 設定ファイルの注入 (compose.yml volumes → /etc/cwagentconfig)"
assert_contains "$cwagent_verify_output" "収集対象 2 件 / 送信先: /local/myapp/efs/app-front/front-local, /local/myapp/efs/app-back/back-local / force_flush_interval=5 秒"
assert_contains "$cwagent_verify_output" "http://cloudwatch-logs-mock:8080 → Compose サービス 'cloudwatch-logs-mock'"
assert_contains "$cwagent_verify_output" "[OK] 収集対象ログファイルのマウント"
assert_contains "$cwagent_verify_output" "ap-northeast-1 (設定ファイルの agent.region)"
assert_contains "$cwagent_verify_output" "共有クレデンシャルファイル ./aws-credentials → /root/.aws/credentials"
# 送達チェック (起動後)
assert_contains "$cwagent_verify_output" "CloudWatch Agent の送信状況チェック"
assert_contains "$cwagent_verify_output" "[OK] コンテナ内の設定ファイル (/etc/cwagentconfig/cwagent-config.json)"
assert_contains "$cwagent_verify_output" "[OK] ログイベントの送達 (CloudWatch Logs 偽装サービス)"
assert_contains "$cwagent_verify_output" "[OK] /mnt/logs/app-front*.log"
assert_contains "$cwagent_verify_output" "総合判定: 全段 OK"
# ログ本文の機微情報はマスクしたままであること
assert_contains "$cwagent_verify_output" "request completed token=[REDACTED]"
assert_not_contains "$cwagent_verify_output" "dummy-secret"
assert_contains "$FAKE_DOCKER_CALLS" "exec cid-cwagent cat /etc/cwagentconfig/cwagent-config.json"
assert_contains "$FAKE_CURL_CALLS" "http://127.0.0.1:18480/__admin/requests?limit=100"

# 全量レポートにも検証結果が残ること
collect_report_files "$TEST_TMP/cwagent-reports"
cwagent_report_files=("${REPORT_FILES[@]}")
[ -f "${cwagent_report_files[0]}" ] || fail "cwagent verification report was not created"
assert_contains "${cwagent_report_files[0]}" "[8] CloudWatch Logs 送信検証 (cwagent)"
assert_contains "${cwagent_report_files[0]}" "  - log group=/local/myapp/efs/app-front / log stream=front-local / file=/mnt/logs/app-front*.log"
assert_contains "${cwagent_report_files[0]}" "総合判定: 全段 OK"
assert_before "${cwagent_report_files[0]}" "[8] CloudWatch Logs 送信検証 (cwagent)" \
  "[9] Compose サービス別ログ (全サービス・全行)"

# --- 既定 (--cwagent-delivery-report なし) では送達レポートを行わないこと ---
# コンテナ内設定の照合と cwagent の警告・エラーログは従来どおり実行し、送信先への
# 問い合わせと待ち合わせだけを行わないこと。
cwagent_no_report_output="$TEST_TMP/cwagent-no-delivery-report.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent.yml" \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs \
    --report-dir "$TEST_TMP/cwagent-no-report-reports"
) >"$cwagent_no_report_output" 2>&1; then
  cat "$cwagent_no_report_output" >&2
  fail "cwagent verification without --cwagent-delivery-report returned a non-zero status"
fi
# 静的チェックと、起動後のコンテナ内設定の照合は従来どおり行うこと
assert_contains "$cwagent_no_report_output" "ビルド前の設定ファイルチェック"
assert_contains "$cwagent_no_report_output" "[OK] 収集対象ログファイルのマウント"
assert_contains "$cwagent_no_report_output" "CloudWatch Agent の送信状況チェック"
assert_contains "$cwagent_no_report_output" "[OK] コンテナ内の設定ファイル (/etc/cwagentconfig/cwagent-config.json)"
assert_contains "$cwagent_no_report_output" "[OK] cwagent の警告・エラーログ"
# 送達レポートは実行せず、実施していないことを情報として残すこと
assert_contains "$cwagent_no_report_output" "[情報] ログイベントの送達"
assert_contains "$cwagent_no_report_output" \
  "--cwagent-delivery-report が指定されていないため、送達レポートは実行していません (待ち合わせ 0 秒)"
assert_not_contains "$cwagent_no_report_output" "CloudWatch Logs 偽装送達レポート"
assert_not_contains "$cwagent_no_report_output" "[OK] ログイベントの送達 (CloudWatch Logs 偽装サービス)"
# 送信先 (WireMock) への問い合わせも行わないこと
assert_not_contains "$FAKE_CURL_CALLS" "__admin/requests"
# 情報の段は総合判定を曇らせないこと
assert_contains "$cwagent_no_report_output" "総合判定: 全段 OK"
collect_report_files "$TEST_TMP/cwagent-no-report-reports"
cwagent_no_report_files=("${REPORT_FILES[@]}")
[ -f "${cwagent_no_report_files[0]}" ] || fail "cwagent no-delivery-report report was not created"
assert_contains "${cwagent_no_report_files[0]}" "[情報] ログイベントの送達"

# --- 既定 (--cwagent-create-log-group なし) ではロググループを作成しないこと ---
# 実 CloudWatch Logs 宛てでロググループが存在しない構成でも、明示指定が無ければ
# CreateLogGroup を呼ばず、指定方法を案内するだけにとどめること。
cwagent_default_no_create_output="$TEST_TMP/cwagent-default-no-create.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_AWS_CALLS"
: > "$TEST_TMP/aws-log-groups-default.txt"
export FAKE_AWS_LOG_GROUP_STORE="$TEST_TMP/aws-log-groups-default.txt"
export FAKE_COMPOSE_PS_SERVICES="app cwagent cloudwatch-logs-mock"
export FAKE_COMPOSE_CONFIG_SERVICES="base app cwagent cloudwatch-logs-mock"
export FAKE_CWAGENT_CONFIG_FILE="$cwagent_fixture_dir/cwagent-config.json"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent.yml" \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --suppress-startup-logs \
    --suppress-removed-logs \
    --cwagent-delivery-target aws \
    --cwagent-delivery-timeout 1 \
    --cwagent-delivery-interval 1
) >"$cwagent_default_no_create_output" 2>&1; then
  cat "$cwagent_default_no_create_output" >&2
  fail "cwagent verification without --cwagent-create-log-group returned a non-zero status"
fi
assert_not_contains "$FAKE_AWS_CALLS" "logs create-log-group"
assert_contains "$cwagent_default_no_create_output" \
  "CloudWatch Logs のロググループ自動作成は行いません (--cwagent-create-log-group を指定すると、設定ファイルの log_group_name で作成します)。"
assert_not_contains "$cwagent_default_no_create_output" "[OK] ロググループの自動作成 (CloudWatch Logs)"
# 送達レポートも既定では行わないため、ロググループ不在を NG として報告しないこと
assert_not_contains "$cwagent_default_no_create_output" "[NG] ロググループが存在しません"
assert_contains "$cwagent_default_no_create_output" "[情報] ログイベントの送達"

# --- 実 CloudWatch Logs 宛てで、ロググループが存在しないケース (自動作成) ---
# 設定ファイルの log_group_name のロググループが無い場合、その名前で作成してから
# 送達を確認すること。
cwagent_create_group_output="$TEST_TMP/cwagent-create-log-group.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_AWS_CALLS"
: > "$TEST_TMP/aws-log-groups.txt"
export FAKE_AWS_LOG_GROUP_STORE="$TEST_TMP/aws-log-groups.txt"
export FAKE_COMPOSE_PS_SERVICES="app cwagent cloudwatch-logs-mock"
export FAKE_COMPOSE_CONFIG_SERVICES="base app cwagent cloudwatch-logs-mock"
export FAKE_CWAGENT_CONFIG_FILE="$cwagent_fixture_dir/cwagent-config.json"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent.yml" \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs \
    --cwagent-delivery-target aws \
    --cwagent-delivery-timeout 1 \
    --cwagent-delivery-interval 1 \
    --cwagent-create-log-group \
    --cwagent-delivery-report \
    --report-dir "$TEST_TMP/cwagent-create-reports"
) >"$cwagent_create_group_output" 2>&1; then
  cat "$cwagent_create_group_output" >&2
  fail "cwagent log group auto creation returned a non-zero status"
fi

# コンテナ起動前に、設定ファイルのロググループ名で作成すること
assert_contains "$cwagent_create_group_output" \
  "CloudWatch Logs にロググループがないため、設定ファイルの名前で作成します: /local/myapp/efs/app-front (region=ap-northeast-1)"
assert_before "$cwagent_create_group_output" \
  "CloudWatch Logs にロググループがないため、設定ファイルの名前で作成します: /local/myapp/efs/app-front (region=ap-northeast-1)" \
  "BuildKit のビルドログ表示形式: plain"
assert_contains "$FAKE_AWS_CALLS" \
  "logs create-log-group --region ap-northeast-1 --log-group-name /local/myapp/efs/app-front"
assert_contains "$FAKE_AWS_CALLS" \
  "logs create-log-group --region ap-northeast-1 --log-group-name /local/myapp/efs/app-back"
assert_contains "$cwagent_create_group_output" "[OK] ロググループの自動作成 (CloudWatch Logs)"
assert_contains "$cwagent_create_group_output" \
  "設定ファイルのロググループ名で作成しました (region=ap-northeast-1): /local/myapp/efs/app-front, /local/myapp/efs/app-back"
assert_contains "$cwagent_create_group_output" \
  "[OK] ロググループ: /local/myapp/efs/app-front (存在しなかったため今回の実行で自動作成しました)"
assert_contains "$cwagent_create_group_output" "[OK] ログイベントの送達 (CloudWatch Logs)"
assert_contains "$cwagent_create_group_output" "総合判定: 全段 OK"
assert_contains "$cwagent_create_group_output" "request completed token=[REDACTED]"
assert_not_contains "$cwagent_create_group_output" "dummy-secret"
collect_report_files "$TEST_TMP/cwagent-create-reports"
cwagent_create_report_files=("${REPORT_FILES[@]}")
[ -f "${cwagent_create_report_files[0]}" ] || fail "cwagent auto creation report was not created"
assert_contains "${cwagent_create_report_files[0]}" \
  "自動作成した log group: /local/myapp/efs/app-front /local/myapp/efs/app-back"

# 既に存在するロググループは作成しないこと (2 回目の実行)
cwagent_existing_group_output="$TEST_TMP/cwagent-existing-log-group.out"
: > "$FAKE_AWS_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent.yml" \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --suppress-startup-logs \
    --suppress-removed-logs \
    --cwagent-delivery-target aws \
    --cwagent-delivery-timeout 1 \
    --cwagent-delivery-interval 1 \
    --cwagent-create-log-group \
    --cwagent-delivery-report
) >"$cwagent_existing_group_output" 2>&1; then
  cat "$cwagent_existing_group_output" >&2
  fail "cwagent verification with existing log groups returned a non-zero status"
fi
assert_not_contains "$FAKE_AWS_CALLS" "logs create-log-group"
assert_contains "$cwagent_existing_group_output" \
  "設定ファイルのロググループはすべて存在するため作成していません (region=ap-northeast-1): /local/myapp/efs/app-front, /local/myapp/efs/app-back"
assert_contains "$cwagent_existing_group_output" "[OK] ロググループ: /local/myapp/efs/app-front"
assert_not_contains "$cwagent_existing_group_output" \
  "[OK] ロググループ: /local/myapp/efs/app-front (存在しなかったため今回の実行で自動作成しました)"

# --- --no-cwagent-create-log-group では作成せず NG として報告すること ---
cwagent_no_create_output="$TEST_TMP/cwagent-no-create-log-group.out"
: > "$FAKE_AWS_CALLS"
: > "$TEST_TMP/aws-log-groups-empty.txt"
export FAKE_AWS_LOG_GROUP_STORE="$TEST_TMP/aws-log-groups-empty.txt"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent.yml" \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --suppress-startup-logs \
    --suppress-removed-logs \
    --cwagent-delivery-target aws \
    --cwagent-delivery-timeout 1 \
    --cwagent-delivery-interval 1 \
    --cwagent-delivery-report \
    --no-cwagent-create-log-group
) >"$cwagent_no_create_output" 2>&1; then
  cat "$cwagent_no_create_output" >&2
  fail "--no-cwagent-create-log-group returned a non-zero status"
fi
assert_not_contains "$FAKE_AWS_CALLS" "logs create-log-group"
assert_contains "$cwagent_no_create_output" "[NG] ロググループが存在しません: /local/myapp/efs/app-front"
assert_contains "$cwagent_no_create_output" \
  "--cwagent-create-log-group を指定すると、設定ファイルの名前で自動作成します。"
assert_contains "$cwagent_no_create_output" "[NG] ログイベントの送達 (CloudWatch Logs)"
assert_contains "$cwagent_no_create_output" "総合判定: NG あり"

# --- 権限不足などで作成に失敗した場合は NG として報告すること ---
cwagent_create_failed_output="$TEST_TMP/cwagent-create-log-group-failed.out"
: > "$FAKE_AWS_CALLS"
export FAKE_AWS_CREATE_LOG_GROUP_ERROR="An error occurred (AccessDeniedException) when calling the CreateLogGroup operation: User is not authorized to perform: logs:CreateLogGroup"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent.yml" \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --suppress-startup-logs \
    --suppress-removed-logs \
    --cwagent-delivery-target aws \
    --cwagent-delivery-timeout 1 \
    --cwagent-delivery-interval 1 \
    --cwagent-create-log-group \
    --cwagent-delivery-report
) >"$cwagent_create_failed_output" 2>&1; then
  cat "$cwagent_create_failed_output" >&2
  fail "cwagent log group creation failure returned a non-zero status"
fi
assert_contains "$FAKE_AWS_CALLS" "logs create-log-group --region ap-northeast-1 --log-group-name /local/myapp/efs/app-front"
# 原因は 1 回の実行中に変わらないため、送達確認の前に再試行しないこと
assert_occurrences "$FAKE_AWS_CALLS" \
  "logs create-log-group --region ap-northeast-1 --log-group-name /local/myapp/efs/app-front" 1
assert_occurrences "$cwagent_create_failed_output" "[NG] ロググループの自動作成 (CloudWatch Logs)" 1
assert_contains "$cwagent_create_failed_output" "ロググループを作成できませんでした"
assert_contains "$cwagent_create_failed_output" "AccessDeniedException"
assert_contains "$cwagent_create_failed_output" \
  "logs:CreateLogGroup 権限とリージョン (ap-northeast-1) を確認してください"
assert_contains "$cwagent_create_failed_output" \
  "[NG] ロググループが存在せず、自動作成もできませんでした: /local/myapp/efs/app-front"
assert_contains "$cwagent_create_failed_output" "総合判定: NG あり"
unset FAKE_AWS_CREATE_LOG_GROUP_ERROR FAKE_AWS_LOG_GROUP_STORE

# --- 送信先・収集対象・命名規則・リージョンが揃っていないケース ---
cwagent_broken_output="$TEST_TMP/cwagent-broken.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_CURL_CALLS"
export FAKE_COMPOSE_PS_SERVICES="app cwagent"
export FAKE_COMPOSE_CONFIG_SERVICES="base app cwagent"
export FAKE_CWAGENT_CONFIG_FILE="$cwagent_fixture_dir/cwagent-config-broken.json"
unset FAKE_CLOUDWATCH_JOURNAL_FILE
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent-broken.yml" \
    --compose-service app,cwagent \
    --startup-service app \
    --suppress-startup-logs \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-removed-logs \
    --cwagent-delivery-timeout 1 \
    --cwagent-delivery-interval 1 \
    --cwagent-delivery-report
) >"$cwagent_broken_output" 2>&1; then
  cat "$cwagent_broken_output" >&2
  fail "cwagent verification of the broken fixture returned a non-zero status"
fi

assert_contains "$cwagent_broken_output" "log_group_name が CloudWatch Logs の命名規則に反します"
assert_contains "$cwagent_broken_output" "endpoint_override のホスト 'cloudwatch-logs-stub' が compose.yml のサービス名・container_name のいずれとも一致しません"
assert_contains "$cwagent_broken_output" "[NG] 収集対象ログファイルのマウント"
assert_contains "$cwagent_broken_output" "収集対象パスが cwagent にマウントされていません: /mnt/logs/app-front*.log"
assert_contains "$cwagent_broken_output" "[NG] リージョン (agent.region / AWS_REGION)"
assert_contains "$cwagent_broken_output" "[NG] ログイベントの送達 (CloudWatch Logs 偽装サービス)"
assert_contains "$cwagent_broken_output" "総合判定: NG あり"
# 既定では NG があってもビルド結果の判定は変えない
assert_contains "$cwagent_broken_output" "NG をビルドの失敗として扱う場合は --cwagent-required を指定してください。"

# --- マウント元の設定ファイルがホストに存在しないケース (ビルドのみ) ---
cwagent_missing_output="$TEST_TMP/cwagent-missing-config.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_CONFIG_SERVICES="base cwagent"
unset FAKE_COMPOSE_PS_SERVICES FAKE_CWAGENT_CONFIG_FILE
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent-missing-config.yml"
) >"$cwagent_missing_output" 2>&1; then
  cat "$cwagent_missing_output" >&2
  fail "cwagent verification of the missing config fixture returned a non-zero status"
fi
assert_contains "$cwagent_missing_output" "[NG] 設定ファイルの注入 (compose.yml volumes → /etc/cwagentconfig)"
assert_contains "$cwagent_missing_output" "マウント元のファイルがホストに存在しません: ./missing-cwagent-config.json"
assert_contains "$cwagent_missing_output" "存在しないパスを bind mount すると Docker が空のディレクトリを作るため"
# コンテナ未起動でも、送信先を特定できていない段は水増ししない
assert_not_contains "$cwagent_missing_output" "[未確認] ログイベントの送達"

# --- --cwagent-required では NG を失敗として扱うこと ---
cwagent_required_output="$TEST_TMP/cwagent-required.out"
: > "$FAKE_DOCKER_CALLS"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent-missing-config.yml" \
    --cwagent-required
) >"$cwagent_required_output" 2>&1; then
  cat "$cwagent_required_output" >&2
  fail "--cwagent-required unexpectedly returned zero for a broken cwagent configuration"
fi
assert_contains "$cwagent_required_output" "--cwagent-required が指定されているため失敗として終了します。"

# --- --no-verify-cwagent では検証そのものを行わないこと ---
cwagent_disabled_output="$TEST_TMP/cwagent-disabled.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$cwagent_fixture_dir/compose-cwagent-missing-config.yml" \
    --no-verify-cwagent
) >"$cwagent_disabled_output" 2>&1; then
  cat "$cwagent_disabled_output" >&2
  fail "--no-verify-cwagent returned a non-zero status"
fi
assert_not_contains "$cwagent_disabled_output" "ビルド前の設定ファイルチェック"
assert_not_contains "$cwagent_disabled_output" "CloudWatch Agent のログ送信検証を開始します"

# --- cwagent が定義されていなければ既定では何も出さないこと ---
cwagent_absent_output="$TEST_TMP/cwagent-absent.out"
: > "$FAKE_DOCKER_CALLS"
unset FAKE_COMPOSE_CONFIG_SERVICES
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh
) >"$cwagent_absent_output" 2>&1; then
  cat "$cwagent_absent_output" >&2
  fail "build-only run without a cwagent service returned a non-zero status"
fi
assert_not_contains "$cwagent_absent_output" "CloudWatch Agent のログ送信検証を開始します"

# --- --verify-cwagent なら、定義が無いことを NG として報告すること ---
cwagent_forced_output="$TEST_TMP/cwagent-forced.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --verify-cwagent
) >"$cwagent_forced_output" 2>&1; then
  cat "$cwagent_forced_output" >&2
  fail "--verify-cwagent without a cwagent service returned a non-zero status"
fi
assert_contains "$cwagent_forced_output" "[NG] compose.yml の cwagent サービス定義"
assert_contains "$cwagent_forced_output" "--cwagent-service でサービス名を指定してください"

# --- オプション値の検証 ---
cwagent_option_error_output="$TEST_TMP/cwagent-option-error.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --cwagent-delivery-target other
) >"$cwagent_option_error_output" 2>&1; then
  cat "$cwagent_option_error_output" >&2
  fail "--cwagent-delivery-target accepted an invalid value"
fi
assert_contains "$cwagent_option_error_output" "--cwagent-delivery-target には auto、mock または aws を指定してください: other"

# =============================================================================
# WAR デプロイ時の Java 例外解析
# =============================================================================
# デプロイ処理で Java の例外が投げられたログを与え、
#   - 例外の連鎖 (Caused by) をたどって根本原因の例外クラスを特定すること
#   - 例外クラスに応じた原因分析と対処提案を --deploy-exception-display で画面へ出すこと
#   - 全量レポートの [10] へ同じ内容を残すこと
#   - --deploy-exception-excel の指定時に Excel ブックを出力すること
#   - --deploy-exception-text の指定時にテキストを出力すること
# を確認する。base はビルド専用でコンテナを持たないため、解析対象は app だけにする。
# 画面表示とテキスト出力はいずれも既定では行わないため、この実行では明示的に
# 有効化する (既定の挙動そのものは後段の deploy-exception-quiet で確認する)。
deploy_exception_output="$TEST_TMP/deploy-exception.out"
deploy_exception_text_path="$TEST_TMP/deploy-exception-reports/java_exceptions.txt"
deploy_exception_excel_path="$TEST_TMP/deploy-exception-reports/java_exceptions.xlsx"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-java-exception.log"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --report-dir "$TEST_TMP/deploy-exception-reports" \
    --deploy-exception-display \
    --deploy-exception-excel "$deploy_exception_excel_path" \
    --deploy-exception-text "$deploy_exception_text_path" \
    --exit-on-deploy-error \
    --suppress-removed-logs
) >"$deploy_exception_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$deploy_exception_output" >&2
  fail "java exception fixture unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

# 解析ヘルパーは Python 3 を必要とする。無い環境では解析を省略した旨だけを確認する。
if grep -Fq "Java 例外解析をスキップしました: Python 3 が見つかりません" "$deploy_exception_output"; then
  printf 'SKIP: Java exception analysis assertions (Python 3 is unavailable)\n'
else
  # --- 画面出力: 検出サマリと判定 ---
  assert_contains "$deploy_exception_output" "WAR デプロイ時 Java 例外解析"
  assert_contains "$deploy_exception_output" "検出した例外  : 2 件 (デプロイ処理中: 2 件 / デプロイ外: 0 件)"
  assert_contains "$deploy_exception_output" "総合判定      : NG (デプロイ処理中に致命的な例外が発生しています)"
  assert_contains "$deploy_exception_output" "WAR デプロイ時に Java の例外を 2 件検出しました (デプロイ処理中: 2 件)。"

  # --- 例外 1: StartException に包まれた Weld の未解決依存を根本原因として扱うこと ---
  assert_contains "$deploy_exception_output" "[例外 1/2] org.jboss.msc.service.StartException"
  assert_contains "$deploy_exception_output" "判定: デプロイ失敗の原因 / 深刻度: 致命的 / 分類: CDI (Weld)"
  assert_contains "$deploy_exception_output" "根本原因      : org.jboss.weld.exceptions.DeploymentException"
  assert_contains "$deploy_exception_output" "デプロイ対象  : orders.war"
  assert_contains "$deploy_exception_output" "アプリ内発生点: at com.example.orders.OrderService.<init>(OrderService.java:31)"
  assert_contains "$deploy_exception_output" "■ 発生の仕組み (なぜこの例外になるのか)"
  assert_contains "$deploy_exception_output" "■ 対処方法"
  assert_contains "$deploy_exception_output" "実装クラスへスコープアノテーションを付ける"

  # --- 例外 2: ログ本文とは別行に出た例外も、直前のログ行から発生時刻等を引き継ぐこと ---
  assert_contains "$deploy_exception_output" "[例外 2/2] java.lang.ClassNotFoundException"
  assert_contains "$deploy_exception_output" "分類: クラスロード・依存関係"
  assert_contains "$deploy_exception_output" "発生日時      : 09:18:00,250"
  assert_contains "$deploy_exception_output" "ロガー        : com.example.orders.Bootstrap"
  assert_contains "$deploy_exception_output" "見つからないクラス"
  assert_contains "$deploy_exception_output" "com.example.orders.jdbc.LegacyDriver"
  assert_contains "$deploy_exception_output" "jboss-deployment-structure.xml"

  # --- EAP のメッセージコードと突き合わせて、デプロイ失敗の根拠を示すこと ---
  assert_contains "$deploy_exception_output" "WFLYCTL0080: 起動できなかったサービス (Failed services) の一覧です。"
  assert_contains "$deploy_exception_output" "WFLYSRV0021: デプロイが巻き戻されました。"

  # --- 全量レポート [10] へ同じ解析結果を残すこと ---
  collect_report_files "$TEST_TMP/deploy-exception-reports"
  deploy_exception_reports=("${REPORT_FILES[@]}")
  [ ${#deploy_exception_reports[@]} -eq 1 ] && [ -f "${deploy_exception_reports[0]}" ] \
    || fail "expected one report for the java exception scenario"
  assert_contains "${deploy_exception_reports[0]}" "[10] WAR デプロイ時 Java 例外解析"
  assert_contains "${deploy_exception_reports[0]}" "デプロイ処理の Java 例外解析は [10] に記載"
  assert_contains "${deploy_exception_reports[0]}" "根本原因      : org.jboss.weld.exceptions.DeploymentException"
  assert_before "${deploy_exception_reports[0]}" \
    "[9] Compose サービス別ログ (全サービス・全行)" "[10] WAR デプロイ時 Java 例外解析"

  # --- --deploy-exception-excel で指定した先へ Excel ブックを出力すること ---
  deploy_exception_books=("$deploy_exception_excel_path")
  [ -s "${deploy_exception_books[0]}" ] \
    || fail "expected the java exception workbook at --deploy-exception-excel"
  # 自動命名 (build_and_verify_<日時>_java_exceptions.xlsx) は行わない。
  deploy_exception_auto_books=("$TEST_TMP/deploy-exception-reports"/build_and_verify_*_java_exceptions.xlsx)
  [ ! -e "${deploy_exception_auto_books[0]}" ] \
    || fail "did not expect an auto-named java exception workbook"
  assert_contains "$deploy_exception_output" \
    "Java 例外解析の Excel ブックを出力しました: ${deploy_exception_books[0]}"
  assert_contains "${deploy_exception_reports[0]}" "Excel ブック  : ${deploy_exception_books[0]}"

  # --- Excel と同じ内容を、--deploy-exception-text で指定した先へ出力すること ---
  deploy_exception_texts=("$deploy_exception_text_path")
  [ -s "${deploy_exception_texts[0]}" ] \
    || fail "expected the java exception text file at --deploy-exception-text"
  assert_contains "$deploy_exception_output" \
    "Java 例外解析のテキストを出力しました: ${deploy_exception_texts[0]}"
  assert_contains "${deploy_exception_reports[0]}" "テキスト      : ${deploy_exception_texts[0]}"
  # 自動命名 (build_and_verify_<日時>_java_exceptions.txt) は行わない。
  deploy_exception_auto_texts=("$TEST_TMP/deploy-exception-reports"/build_and_verify_*_java_exceptions.txt)
  [ ! -e "${deploy_exception_auto_texts[0]}" ] \
    || fail "did not expect an auto-named java exception text file"
  # テキストは画面表示と同じ分析に加えて、全スタックフレームと区分付きデプロイログを含む。
  assert_contains "${deploy_exception_texts[0]}" "総合判定      : NG (デプロイ処理中に致命的な例外が発生しています)"
  assert_contains "${deploy_exception_texts[0]}" "根本原因      : org.jboss.weld.exceptions.DeploymentException"
  assert_contains "${deploy_exception_texts[0]}" "■ 対処方法"
  assert_contains "${deploy_exception_texts[0]}" "at com.example.orders.OrderService.<init>(OrderService.java:31)"
  assert_contains "${deploy_exception_texts[0]}" "デプロイログ (行番号 / サービス / 区分 / 本文)"
  assert_contains "${deploy_exception_texts[0]}" "デプロイ失敗"
  assert_contains "${deploy_exception_texts[0]}" "スタックフレーム"
  # 解析結果のテキストなので、ANSI 色コードは含めない。
  assert_not_contains "${deploy_exception_texts[0]}" $'\033['

  # xlsx は ZIP なので、必須パートとシート名が入っているかを中身で確認する。
  workbook_entries="$(unzip -Z1 "${deploy_exception_books[0]}" 2>/dev/null || true)"
  if [ -z "$workbook_entries" ]; then
    printf 'SKIP: workbook content assertions (unzip is unavailable)\n'
  else
    for required_part in "[Content_Types].xml" "xl/workbook.xml" "xl/styles.xml" \
        "xl/worksheets/sheet1.xml" "xl/worksheets/sheet6.xml"; do
      printf '%s\n' "$workbook_entries" | grep -Fqx -- "$required_part" \
        || fail "expected '$required_part' in ${deploy_exception_books[0]}"
    done
    workbook_xml="$(unzip -p "${deploy_exception_books[0]}" xl/workbook.xml)"
    for required_sheet in "概要" "例外一覧" "原因分析" "対処方法" "スタックトレース" "デプロイログ"; do
      case "$workbook_xml" in
        *"name=\"${required_sheet}\""*) ;;
        *) fail "expected sheet '$required_sheet' in ${deploy_exception_books[0]}" ;;
      esac
    done
    # 「概要」シートには実行情報と判定が、「対処方法」シートには手順が入る。
    summary_sheet_xml="$(unzip -p "${deploy_exception_books[0]}" xl/worksheets/sheet1.xml)"
    for required_text in "WAR デプロイ時 Java 例外エラー解析レポート" \
        "NG (デプロイ処理中に致命的な例外が発生しています)" \
        "org.jboss.weld.exceptions.DeploymentException"; do
      case "$summary_sheet_xml" in
        *"$required_text"*) ;;
        *) fail "expected '$required_text' in the summary sheet of ${deploy_exception_books[0]}" ;;
      esac
    done
    fix_sheet_xml="$(unzip -p "${deploy_exception_books[0]}" xl/worksheets/sheet4.xml)"
    case "$fix_sheet_xml" in
      *"jboss-deployment-structure.xml"*) ;;
      *) fail "expected remediation steps in the fix sheet of ${deploy_exception_books[0]}" ;;
    esac
    # フォントは Meiryo UI で統一し、他のフォント名は残さない。
    styles_xml="$(unzip -p "${deploy_exception_books[0]}" xl/styles.xml)"
    case "$styles_xml" in
      *'<name val="Meiryo UI"/>'*) ;;
      *) fail "expected Meiryo UI fonts in ${deploy_exception_books[0]}" ;;
    esac
    case "$styles_xml" in
      *'Yu Gothic'*|*'Consolas'*|*'Calibri'*)
        fail "unexpected non-Meiryo UI font in ${deploy_exception_books[0]}" ;;
    esac
    # 見切れ防止のため、各行に計算済みの行高を持たせる。
    case "$summary_sheet_xml" in
      *'customHeight="1"'*) ;;
      *) fail "expected explicit row heights in ${deploy_exception_books[0]}" ;;
    esac
  fi
fi

# --- 既定では画面表示も Excel / テキスト出力も行わないこと ---
# 同じ例外ログを与えても、--deploy-exception-display / --deploy-exception-excel /
# --deploy-exception-text を指定しなければ、解析結果はビルド結果の画面に現れず、
# Excel もテキストも作らない。解析そのものは動いており、結果は全量レポートの
# [10] に残る。
deploy_exception_quiet_output="$TEST_TMP/deploy-exception-quiet.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-java-exception.log"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --report-dir "$TEST_TMP/deploy-exception-quiet-reports" \
    --exit-on-deploy-error \
    --suppress-removed-logs
) >"$deploy_exception_quiet_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$deploy_exception_quiet_output" >&2
  fail "java exception fixture unexpectedly returned zero without display options"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

if ! grep -Fq "Java 例外解析をスキップしました: Python 3 が見つかりません" "$deploy_exception_quiet_output"; then
  # 画面には解析本文も検出サマリも出さない。
  assert_not_contains "$deploy_exception_quiet_output" "■ 発生の仕組み (なぜこの例外になるのか)"
  assert_not_contains "$deploy_exception_quiet_output" "■ 対処方法"
  assert_not_contains "$deploy_exception_quiet_output" \
    "WAR デプロイ時に Java の例外を 2 件検出しました (デプロイ処理中: 2 件)。"
  assert_not_contains "$deploy_exception_quiet_output" "[例外 1/2] org.jboss.msc.service.StartException"
  # テキストは自動命名でも作らない。
  quiet_texts=("$TEST_TMP/deploy-exception-quiet-reports"/build_and_verify_*_java_exceptions.txt)
  [ ! -e "${quiet_texts[0]}" ] \
    || fail "did not expect a java exception text file without --deploy-exception-text"
  # Excel も自動命名では作らない (--report-dir だけでは出力しない)。
  quiet_books=("$TEST_TMP/deploy-exception-quiet-reports"/build_and_verify_*_java_exceptions.xlsx)
  [ ! -e "${quiet_books[0]}" ] \
    || fail "did not expect a java exception workbook without --deploy-exception-excel"
  assert_not_contains "$deploy_exception_quiet_output" \
    "Java 例外解析の Excel ブックを出力しました:"
  collect_report_files "$TEST_TMP/deploy-exception-quiet-reports"
  quiet_reports=("${REPORT_FILES[@]}")
  [ ${#quiet_reports[@]} -eq 1 ] && [ -f "${quiet_reports[0]}" ] \
    || fail "expected one report for the quiet java exception scenario"
  assert_contains "${quiet_reports[0]}" "[10] WAR デプロイ時 Java 例外解析"
  assert_contains "${quiet_reports[0]}" "根本原因      : org.jboss.weld.exceptions.DeploymentException"
  assert_contains "${quiet_reports[0]}" \
    "Excel ブック  : (未出力。--deploy-exception-excel FILE を指定すると出力します)"
  assert_contains "${quiet_reports[0]}" \
    "テキスト      : (未出力。--deploy-exception-text FILE を指定すると出力します)"
fi

# --- 出力先が 1 つも無い実行では、解析そのものを行わないこと ---
# --report-dir も --deploy-exception-* も無い場合、結果を出す場所が無いため、
# ログ収集と解析ヘルパーの起動ごと省く (画面には何も現れない)。
deploy_exception_nosink_output="$TEST_TMP/deploy-exception-nosink.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-java-exception.log"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --exit-on-deploy-error \
    --suppress-removed-logs
) >"$deploy_exception_nosink_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$deploy_exception_nosink_output" >&2
  fail "java exception fixture unexpectedly returned zero without any output target"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

assert_not_contains "$deploy_exception_nosink_output" "Java 例外解析"
assert_not_contains "$deploy_exception_nosink_output" "WAR デプロイ時に Java の例外を"

# --- --deploy-exception-display だけを指定すると、画面へは出しファイルは作らないこと ---
deploy_exception_display_only_output="$TEST_TMP/deploy-exception-display-only.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-java-exception.log"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --deploy-exception-display \
    --exit-on-deploy-error \
    --suppress-removed-logs
) >"$deploy_exception_display_only_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$deploy_exception_display_only_output" >&2
  fail "java exception fixture unexpectedly returned zero with --deploy-exception-display"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

if ! grep -Fq "Java 例外解析をスキップしました: Python 3 が見つかりません" \
    "$deploy_exception_display_only_output"; then
  assert_contains "$deploy_exception_display_only_output" \
    "WAR デプロイ時に Java の例外を 2 件検出しました (デプロイ処理中: 2 件)。"
  assert_contains "$deploy_exception_display_only_output" "■ 対処方法"
  assert_contains "$deploy_exception_display_only_output" \
    "Java 例外解析のファイル出力は、--deploy-exception-excel / --deploy-exception-text を指定したときだけ行います。"
fi

# --- 例外が無いログでは、解析結果を 1 行にとどめ、Excel は指定時に出力すること ---
deploy_exception_clean_output="$TEST_TMP/deploy-exception-clean.out"
deploy_exception_clean_text_path="$TEST_TMP/deploy-exception-clean-reports/java_exceptions.txt"
deploy_exception_clean_excel_path="$TEST_TMP/deploy-exception-clean-reports/java_exceptions.xlsx"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --report-dir "$TEST_TMP/deploy-exception-clean-reports" \
    --deploy-exception-display \
    --deploy-exception-excel "$deploy_exception_clean_excel_path" \
    --deploy-exception-text "$deploy_exception_clean_text_path" \
    --suppress-removed-logs
) >"$deploy_exception_clean_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$deploy_exception_clean_output" >&2
  fail "clean fixture unexpectedly returned non-zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

if ! grep -Fq "Java 例外解析をスキップしました: Python 3 が見つかりません" "$deploy_exception_clean_output"; then
  assert_contains "$deploy_exception_clean_output" "WAR デプロイ時の Java 例外は検出されませんでした。"
  assert_not_contains "$deploy_exception_clean_output" "■ 発生の仕組み (なぜこの例外になるのか)"
  clean_books=("$deploy_exception_clean_excel_path")
  [ -s "${clean_books[0]}" ] \
    || fail "expected a java exception workbook even when no exception was found"
  clean_texts=("$deploy_exception_clean_text_path")
  [ -s "${clean_texts[0]}" ] \
    || fail "expected a java exception text file even when no exception was found"
  assert_contains "${clean_texts[0]}" "総合判定      : OK (Java 例外は検出されませんでした)"
  # 例外が無くても、Excel の「デプロイログ」シートと同じ内容をテキストへ残す。
  assert_contains "${clean_texts[0]}" "デプロイログ (行番号 / サービス / 区分 / 本文)"
  assert_contains "${clean_texts[0]}" "起動完了"
  collect_report_files "$TEST_TMP/deploy-exception-clean-reports"
  clean_reports=("${REPORT_FILES[@]}")
  assert_contains "${clean_reports[0]}" "検出した例外  : 0 件"
  assert_contains "${clean_reports[0]}" "総合判定      : OK (Java 例外は検出されませんでした)"
fi

# --- コンテナの起動 (compose up) に失敗しても、解析を実行して結果を出力すること ---
# 起動できない原因そのものがデプロイ処理中の Java 例外であることが多いため、
# デプロイ結果ファイルだけを残して解析を省略してしまわないことを確認する。
deploy_exception_upfail_output="$TEST_TMP/deploy-exception-upfail.out"
deploy_exception_upfail_text_path="$TEST_TMP/deploy-exception-upfail-reports/java_exceptions.txt"
deploy_exception_upfail_excel_path="$TEST_TMP/deploy-exception-upfail-reports/java_exceptions.xlsx"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-java-exception.log"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_COMPOSE_UP_FAIL="true"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --no-up-retry \
    --report-dir "$TEST_TMP/deploy-exception-upfail-reports" \
    --deploy-exception-display \
    --deploy-exception-excel "$deploy_exception_upfail_excel_path" \
    --deploy-exception-text "$deploy_exception_upfail_text_path" \
    --suppress-removed-logs
) >"$deploy_exception_upfail_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL
  cat "$deploy_exception_upfail_output" >&2
  fail "compose up failure unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL

assert_contains "$deploy_exception_upfail_output" "コンテナの起動に失敗しました (compose up)"
if ! grep -Fq "Java 例外解析をスキップしました: Python 3 が見つかりません" "$deploy_exception_upfail_output"; then
  # 起動に失敗した時点までのログから、成功時と同じ内容の解析結果を出す。
  assert_contains "$deploy_exception_upfail_output" \
    "WAR デプロイ時に Java の例外を 2 件検出しました (デプロイ処理中: 2 件)。"
  assert_contains "$deploy_exception_upfail_output" \
    "解析範囲: コンテナの起動 (compose up) に失敗したため、失敗するまでに出力されたログを解析しました。"
  assert_contains "$deploy_exception_upfail_output" "根本原因      : org.jboss.weld.exceptions.DeploymentException"

  collect_report_files "$TEST_TMP/deploy-exception-upfail-reports"
  upfail_reports=("${REPORT_FILES[@]}")
  [ ${#upfail_reports[@]} -eq 1 ] && [ -f "${upfail_reports[0]}" ] \
    || fail "expected one report for the compose up failure scenario"
  assert_contains "${upfail_reports[0]}" "[10] WAR デプロイ時 Java 例外解析"
  assert_contains "${upfail_reports[0]}" \
    "ログ取得状況  : コンテナの起動 (compose up) に失敗したため、失敗するまでに出力されたログを解析しました。"
  assert_contains "${upfail_reports[0]}" "根本原因      : org.jboss.weld.exceptions.DeploymentException"
  # 旧実装がここへ記録していた「解析していません」に戻っていないこと。
  assert_not_contains "${upfail_reports[0]}" "コンテナを起動していないため、デプロイ処理のログがありません。"

  upfail_books=("$deploy_exception_upfail_excel_path")
  [ -s "${upfail_books[0]}" ] \
    || fail "expected a java exception workbook when compose up failed"
  upfail_texts=("$deploy_exception_upfail_text_path")
  [ -s "${upfail_texts[0]}" ] \
    || fail "expected a java exception text file when compose up failed"
  assert_contains "${upfail_texts[0]}" "総合判定      : NG (デプロイ処理中に致命的な例外が発生しています)"
  assert_contains "${upfail_texts[0]}" "at com.example.orders.OrderService.<init>(OrderService.java:31)"
fi

# --- 起動に失敗し、ログも 1 行も取得できない場合は「未評価」として出力すること ---
deploy_exception_nolog_output="$TEST_TMP/deploy-exception-nolog.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_COMPOSE_UP_FAIL="true"
export FAKE_COMPOSE_NO_CONTAINERS="true"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --no-up-retry \
    --report-dir "$TEST_TMP/deploy-exception-nolog-reports" \
    --deploy-exception-display \
    --deploy-exception-excel "$TEST_TMP/deploy-exception-nolog-reports/java_exceptions.xlsx" \
    --suppress-removed-logs
) >"$deploy_exception_nolog_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL \
        FAKE_COMPOSE_NO_CONTAINERS
  cat "$deploy_exception_nolog_output" >&2
  fail "compose up failure without containers unexpectedly returned zero"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES FAKE_COMPOSE_UP_FAIL \
      FAKE_COMPOSE_NO_CONTAINERS

if ! grep -Fq "Java 例外解析をスキップしました: Python 3 が見つかりません" "$deploy_exception_nolog_output"; then
  assert_contains "$deploy_exception_nolog_output" \
    "WAR デプロイ時 Java 例外解析: Compose サービスのログを 1 行も取得できませんでした"
  # ログが無いのに「例外なし」と読める表示をしないこと。
  assert_not_contains "$deploy_exception_nolog_output" "WAR デプロイ時の Java 例外は検出されませんでした。"
  collect_report_files "$TEST_TMP/deploy-exception-nolog-reports"
  nolog_reports=("${REPORT_FILES[@]}")
  [ ${#nolog_reports[@]} -eq 1 ] && [ -f "${nolog_reports[0]}" ] \
    || fail "expected one report when no container log was available"
  assert_contains "${nolog_reports[0]}" "総合判定      : 未評価 (解析対象のログが無いため判定できません)"
  nolog_books=("$TEST_TMP/deploy-exception-nolog-reports/java_exceptions.xlsx")
  [ -s "${nolog_books[0]}" ] \
    || fail "expected a java exception workbook when no container log was available"
fi

# --- --no-deploy-exception-analysis で解析と Excel 出力を止められること ---
deploy_exception_off_output="$TEST_TMP/deploy-exception-off.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-java-exception.log"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --report-dir "$TEST_TMP/deploy-exception-off-reports" \
    --no-deploy-exception-analysis \
    --exit-on-deploy-error \
    --suppress-removed-logs
) >"$deploy_exception_off_output" 2>&1; then
  unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES
  cat "$deploy_exception_off_output" >&2
  fail "java exception fixture unexpectedly returned zero with analysis disabled"
fi
unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

assert_not_contains "$deploy_exception_off_output" "WAR デプロイ時 Java 例外解析"
off_books=("$TEST_TMP/deploy-exception-off-reports"/build_and_verify_*_java_exceptions.xlsx)
[ ! -e "${off_books[0]}" ] || fail "did not expect a workbook with --no-deploy-exception-analysis"
off_texts=("$TEST_TMP/deploy-exception-off-reports"/build_and_verify_*_java_exceptions.txt)
[ ! -e "${off_texts[0]}" ] || fail "did not expect a text file with --no-deploy-exception-analysis"
collect_report_files "$TEST_TMP/deploy-exception-off-reports"
off_reports=("${REPORT_FILES[@]}")
assert_contains "${off_reports[0]}" "--no-deploy-exception-analysis が指定されたため解析していません。"

# --- オプション値の検証 ---
deploy_exception_ext_output="$TEST_TMP/deploy-exception-ext.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --deploy-exception-excel "$TEST_TMP/report.xls"
) >"$deploy_exception_ext_output" 2>&1; then
  cat "$deploy_exception_ext_output" >&2
  fail "--deploy-exception-excel accepted a non-.xlsx path"
fi
assert_contains "$deploy_exception_ext_output" "--deploy-exception-excel には .xlsx で終わるパスを指定してください"

deploy_exception_conflict_output="$TEST_TMP/deploy-exception-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --deploy-exception-excel "$TEST_TMP/report.xlsx" \
    --no-deploy-exception-analysis
) >"$deploy_exception_conflict_output" 2>&1; then
  cat "$deploy_exception_conflict_output" >&2
  fail "--deploy-exception-excel accepted --no-deploy-exception-analysis"
fi
assert_contains "$deploy_exception_conflict_output" \
  "--deploy-exception-excel と --no-deploy-exception-analysis は同時に指定できません。"

deploy_exception_display_conflict_output="$TEST_TMP/deploy-exception-display-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --deploy-exception-display \
    --no-deploy-exception-analysis
) >"$deploy_exception_display_conflict_output" 2>&1; then
  cat "$deploy_exception_display_conflict_output" >&2
  fail "--deploy-exception-display accepted --no-deploy-exception-analysis"
fi
assert_contains "$deploy_exception_display_conflict_output" \
  "--deploy-exception-display と --no-deploy-exception-analysis は同時に指定できません。"

# --no-deploy-exception-display は --deploy-exception-display を打ち消すため、
# --no-deploy-exception-analysis と併用しても衝突にはならない。
deploy_exception_display_off_output="$TEST_TMP/deploy-exception-display-off.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --dry-run \
    --deploy-exception-display \
    --no-deploy-exception-display \
    --no-deploy-exception-analysis
) >"$deploy_exception_display_off_output" 2>&1; then
  cat "$deploy_exception_display_off_output" >&2
  fail "--no-deploy-exception-display did not cancel --deploy-exception-display"
fi
assert_not_contains "$deploy_exception_display_off_output" \
  "--deploy-exception-display と --no-deploy-exception-analysis は同時に指定できません。"

deploy_exception_text_conflict_output="$TEST_TMP/deploy-exception-text-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --deploy-exception-text "$TEST_TMP/report.txt" \
    --no-deploy-exception-analysis
) >"$deploy_exception_text_conflict_output" 2>&1; then
  cat "$deploy_exception_text_conflict_output" >&2
  fail "--deploy-exception-text accepted --no-deploy-exception-analysis"
fi
assert_contains "$deploy_exception_text_conflict_output" \
  "--deploy-exception-text と --no-deploy-exception-analysis は同時に指定できません。"

deploy_exception_same_path_output="$TEST_TMP/deploy-exception-same-path.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --deploy-exception-excel "$TEST_TMP/same.xlsx" \
    --deploy-exception-text "$TEST_TMP/same.xlsx"
) >"$deploy_exception_same_path_output" 2>&1; then
  cat "$deploy_exception_same_path_output" >&2
  fail "--deploy-exception-excel and --deploy-exception-text accepted the same path"
fi
assert_contains "$deploy_exception_same_path_output" \
  "--deploy-exception-excel と --deploy-exception-text に同じパスは指定できません"

deploy_exception_limit_output="$TEST_TMP/deploy-exception-limit.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --deploy-exception-limit 0
) >"$deploy_exception_limit_output" 2>&1; then
  cat "$deploy_exception_limit_output" >&2
  fail "--deploy-exception-limit accepted 0"
fi
assert_contains "$deploy_exception_limit_output" "--deploy-exception-limit には 1 以上の整数を指定してください: 0"

# =============================================================================
# 読み取り専用ファイルシステム (read_only) の書き込み先分析
# =============================================================================
# compose.yml の read_only 指定と、実際に動いたコンテナの書き込み状況から、
#   - read_only: true で書き込み先が足りないディレクトリを「要対応」とすること
#   - ビルド時にだけ書き込むディレクトリは「ビルド時のみ」として対象から外すこと
#   - entrypoint.sh など実行時に書き込むディレクトリは「要対応」とすること
#   - 足りている構成では「問題なし」と判定すること
#   - read_only 未設定でも、書き込みが起きるディレクトリを「推奨」で出すこと
#   - テキストと Excel を出力し、全量レポートの [11] へ同じ内容を残すこと
#   - --no-readonly-analysis で一切行わないこと
# を確認する。
readonly_fixture_dir="$TEST_DIR/fixtures/readonly"
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"

# --- read_only: true だが tmpfs が /tmp しか無い (書き込み先が足りない) ---
readonly_missing_output="$TEST_TMP/readonly-missing.out"
: > "$FAKE_DOCKER_CALLS"
export FAKE_COMPOSE_CONFIG_SERVICES="app"
export FAKE_COMPOSE_PS_SERVICES="app"
export FAKE_READONLY_ROOTFS="true"
export FAKE_CONTAINER_TMPFS='/tmp|rw,size=64m'
# 起動スクリプト。entrypoint.sh はビルドコンテキストから、standalone.sh は
# (コンテキストに実体が無いため) 実行中のコンテナから読ませる。
export FAKE_CONTAINER_ENTRYPOINT="/usr/local/bin/entrypoint.sh"
export FAKE_CONTAINER_CMD="/opt/jboss-eap/bin/standalone.sh"
export FAKE_CONTAINER_SCRIPTS="/opt/jboss-eap/bin/standalone.sh|$readonly_fixture_dir/image-standalone.sh"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$readonly_fixture_dir/compose-readonly-missing.yml" \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-startup-logs \
    --suppress-removed-logs \
    --report-dir "$TEST_TMP/readonly-missing-reports"
) >"$readonly_missing_output" 2>&1; then
  cat "$readonly_missing_output" >&2
  fail "readonly filesystem analysis (missing tmpfs) returned a non-zero status"
fi

# 分析ヘルパーは Python 3 を必要とする。無い環境では省略した旨だけを確認する。
if grep -Fq "書き込み先分析をスキップしました: Python 3 が見つかりません" "$readonly_missing_output"; then
  printf 'SKIP: readonly filesystem analysis assertions (Python 3 is unavailable)\n'
else
  assert_contains "$readonly_missing_output" \
    "読み取り専用ルートファイルシステム (read_only) の書き込み先分析"
  assert_contains "$readonly_missing_output" "read_only        : compose.yml=true / 実状態=true"
  # JBoss EAP が起動時に必ず書くディレクトリを、要対応として理由付きで挙げること
  assert_contains "$readonly_missing_output" "[要対応] /opt/jboss-eap/standalone/tmp"
  assert_contains "$readonly_missing_output" "[要対応] /opt/jboss-eap/standalone/log"
  assert_contains "$readonly_missing_output" "[要対応] /opt/jboss-eap/standalone/configuration"
  assert_contains "$readonly_missing_output" "現在の設定  : ルートファイルシステム (読み取り専用)"
  assert_contains "$readonly_missing_output" \
    "根拠        : コンテナ内の /proc/mounts でも読み取り専用 (ro) でマウントされています。"
  # tmpfs を割り当て済みの /tmp は要対応にしないこと
  assert_not_contains "$readonly_missing_output" "[要対応] /tmp"
  # 不足分を埋めた compose.yml の設定例を出すこと
  assert_contains "$readonly_missing_output" "compose.yml の設定例 (不足しているディレクトリのみ):"
  assert_contains "$readonly_missing_output" "- /opt/jboss-eap/standalone/tmp:rw,size=512m"
  # tmpfs でイメージの中身を隠せないディレクトリはボリュームを提案すること
  assert_contains "$readonly_missing_output" \
    "app-opt-jboss-eap-standalone-configuration:/opt/jboss-eap/standalone/configuration"
  assert_contains "$readonly_missing_output" \
    "読み取り専用ファイルシステム分析: 書き込み先が用意されていないディレクトリを"

  # --- ビルド段階と実行段階の切り分け ---
  # Dockerfile がビルド時に書くだけのディレクトリは、イメージへ焼き込み済みの
  # ため read_only: true でも失敗しない。要対応にせず「ビルド時のみ」とすること
  assert_contains "$readonly_missing_output" \
    "ビルド時にだけ書き込むディレクトリ (read_only のままで問題なし):"
  assert_contains "$readonly_missing_output" "/opt/appconfig"
  assert_not_contains "$readonly_missing_output" "[要対応] /opt/appconfig"
  assert_not_contains "$readonly_missing_output" "[要確認] /opt/appconfig"
  # entrypoint.sh が起動のたびに書くディレクトリは、実行時の書き込みとして要対応にすること
  assert_contains "$readonly_missing_output" "[要対応] /var/lib/appstate"
  assert_contains "$readonly_missing_output" "書き込み時期: 実行時"
  assert_contains "$readonly_missing_output" \
    "根拠        : 実行時の書き込み: 起動スクリプトが 1 箇所で書き込みます。例: mkdir /var/lib/appstate"
  # コンテナ内にしか無い起動スクリプト (ベースイメージ同梱) も読んで判定すること
  assert_contains "$readonly_missing_output" "[要対応] /opt/jboss-eap/standalone/boot-work"
  assert_contains "$readonly_missing_output" \
    "起動スクリプト   : /opt/jboss-eap/bin/standalone.sh (コンテナ内)"
  assert_contains "$readonly_missing_output" "ビルド時のみ 4"
  # 実行状況の収集に使ったコマンド
  assert_contains "$FAKE_DOCKER_CALLS" "diff cid-app"
  assert_contains "$FAKE_DOCKER_CALLS" "__BUILD_AND_VERIFY_RO_PROBE__"
  assert_contains "$FAKE_DOCKER_CALLS" "__BUILD_AND_VERIFY_RO_SCRIPT__"

  # --- 出力ファイル (テキスト / Excel) ---
  readonly_missing_texts=("$TEST_TMP/readonly-missing-reports"/build_and_verify_*_readonly_filesystem.txt)
  readonly_missing_excels=("$TEST_TMP/readonly-missing-reports"/build_and_verify_*_readonly_filesystem.xlsx)
  readonly_missing_text_file="${readonly_missing_texts[0]}"
  readonly_missing_excel_file="${readonly_missing_excels[0]}"
  [ -f "$readonly_missing_text_file" ] || fail "readonly filesystem analysis text was not created"
  [ -f "$readonly_missing_excel_file" ] || fail "readonly filesystem analysis workbook was not created"
  # xlsx は ZIP コンテナ (先頭が PK)
  [ "$(head -c 2 "$readonly_missing_excel_file")" = "PK" ] \
    || fail "readonly filesystem analysis workbook is not a zip container"
  # テキストは要約より詳しく、検出の根拠と参考知識まで含むこと
  assert_contains "$readonly_missing_text_file" "検出の根拠  : ソフトウェア別の既知の書き込み先"
  assert_contains "$readonly_missing_text_file" "参考: 書き込みが発生しやすいディレクトリの一覧"
  assert_contains "$readonly_missing_text_file" "{jboss_home}/standalone/tmp"
  # 全量テキストには、ビルド時のみと判定した根拠まで残すこと
  assert_contains "$readonly_missing_text_file" "[ビルド時のみ] /opt/appconfig"
  assert_contains "$readonly_missing_text_file" "検出の根拠  : Dockerfile (ビルド時)"
  assert_contains "$readonly_missing_text_file" \
    "ビルド時の書き込みだけを検出しました。"
  assert_contains "$readonly_missing_text_file" "readonly/Dockerfile"

  # --- 全量レポート ---
  collect_report_files "$TEST_TMP/readonly-missing-reports"
  readonly_missing_reports=("${REPORT_FILES[@]}")
  [ -f "${readonly_missing_reports[0]}" ] || fail "readonly analysis report was not created"
  assert_contains "${readonly_missing_reports[0]}" \
    "[11] 読み取り専用ファイルシステム (read_only) の書き込み先分析"
  assert_contains "${readonly_missing_reports[0]}" "[要対応] /opt/jboss-eap/standalone/tmp"
  assert_contains "${readonly_missing_reports[0]}" "Excel ブック  : ${readonly_missing_excel_file}"
  assert_before "${readonly_missing_reports[0]}" \
    "[10] WAR デプロイ時 Java 例外解析" \
    "[11] 読み取り専用ファイルシステム (read_only) の書き込み先分析"
fi

# --- read_only: true で tmpfs / ボリュームを揃えた構成 (問題なし) ---
readonly_ok_output="$TEST_TMP/readonly-ok.out"
: > "$FAKE_DOCKER_CALLS"
# ベースイメージ同梱の起動スクリプトは、ここでは対象から外す
# (ビルドコンテキストの entrypoint.sh だけで、実行時の書き込みを判定させる)。
unset FAKE_CONTAINER_CMD FAKE_CONTAINER_SCRIPTS
export FAKE_CONTAINER_TMPFS='/tmp|rw,size=256m,mode=1777
/var/tmp|rw,size=64m
/run|rw,size=16m,mode=755
/var/cache|rw,size=64m
/opt/jboss-eap/standalone/tmp|rw,size=512m
/opt/jboss-eap/standalone/data|rw,size=256m
/opt/jboss-eap/standalone/content|rw,size=64m
/var/lib/appstate|rw,size=64m'
export FAKE_CONTAINER_MOUNTS='volume|/var/lib/docker/volumes/app-server-log/_data|/opt/jboss-eap/standalone/log|true
volume|/var/lib/docker/volumes/app-configuration/_data|/opt/jboss-eap/standalone/configuration|true
volume|/var/lib/docker/volumes/app-deployments/_data|/opt/jboss-eap/standalone/deployments|true
volume|/var/lib/docker/volumes/app-var-log/_data|/var/log|true'
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$readonly_fixture_dir/compose-readonly-ok.yml" \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$readonly_ok_output" 2>&1; then
  cat "$readonly_ok_output" >&2
  fail "readonly filesystem analysis (sufficient settings) returned a non-zero status"
fi
if ! grep -Fq "書き込み先分析をスキップしました: Python 3 が見つかりません" "$readonly_ok_output"; then
  assert_contains "$readonly_ok_output" "判定             : 問題なし (読み取り専用のまま動作可能)"
  assert_contains "$readonly_ok_output" "対応が必要なディレクトリはありません。"
  assert_not_contains "$readonly_ok_output" "[要対応] /opt/jboss-eap/standalone/tmp"
  # 起動スクリプトが書く場所へ tmpfs を割り当てていれば、要対応にしないこと
  assert_not_contains "$readonly_ok_output" "[要対応] /var/lib/appstate"
  # ビルド時にだけ書き込むディレクトリは、対応不要として数える
  assert_contains "$readonly_ok_output" \
    "(ビルド時にだけ書き込む 2 件は、イメージへ焼き込み済みのため read_only でも問題になりません"
  # ファイル出力先の指定が無い実行では、その旨を案内すること
  assert_contains "$readonly_ok_output" \
    "読み取り専用ファイルシステム分析のファイル出力は、--report-dir または"
fi

# --- read_only 未設定でも、書き込みが起きるディレクトリを推奨として出すこと ---
readonly_writable_output="$TEST_TMP/readonly-writable.out"
: > "$FAKE_DOCKER_CALLS"
unset FAKE_CONTAINER_TMPFS FAKE_CONTAINER_MOUNTS
export FAKE_READONLY_ROOTFS="false"
export FAKE_DOCKER_DIFF='C /opt/appdata
A /opt/appdata/session-store.db
A /tmp/hsperfdata_jboss'
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$readonly_fixture_dir/compose-readonly-ok.yml" \
    --compose-service app \
    --startup-service app \
    --env-list-limit 1 \
    --directory-tree-depth 1 \
    --suppress-startup-logs \
    --suppress-removed-logs \
    --readonly-analysis-text "$TEST_TMP/readonly-writable.txt" \
    --readonly-analysis-excel "$TEST_TMP/readonly-writable.xlsx"
) >"$readonly_writable_output" 2>&1; then
  cat "$readonly_writable_output" >&2
  fail "readonly filesystem analysis (writable rootfs) returned a non-zero status"
fi
if ! grep -Fq "書き込み先分析をスキップしました: Python 3 が見つかりません" "$readonly_writable_output"; then
  # base サービスは read_only の指定が無い。有効化に必要な設定を推奨として出すこと
  assert_contains "$readonly_writable_output" \
    "read_only        : compose.yml=未設定 (既定 false)"
  assert_contains "$readonly_writable_output" \
    "read_only を有効にするなら書き込み先の用意が要るディレクトリ:"
  assert_contains "$readonly_writable_output" \
    "[推奨] /tmp : 一時ディレクトリ (TMPDIR / java.io.tmpdir の既定値)"
  # docker diff で実際に書き込みを検出したディレクトリも候補に挙げること
  assert_contains "$readonly_writable_output" "[推奨] /opt/appdata"
  # 親ディレクトリ (/opt) は、より深い検出があるため候補にしないこと
  assert_not_contains "$readonly_writable_output" "[推奨] /opt : "
  # ビルド時にだけ書き込むディレクトリは、read_only を有効にするときも用意が要らない
  assert_not_contains "$readonly_writable_output" "[推奨] /opt/appconfig"
  assert_contains "$readonly_writable_output" "read_only 未使用"
  # compose.yml の指定と実際のコンテナが食い違う場合は、その旨を残すこと
  assert_contains "$readonly_writable_output" \
    "compose.yml の read_only (true) と実際のコンテナ (false) が一致していません。"
  # 明示指定した出力先へ書くこと
  [ -f "$TEST_TMP/readonly-writable.txt" ] || fail "--readonly-analysis-text did not write the file"
  [ -f "$TEST_TMP/readonly-writable.xlsx" ] || fail "--readonly-analysis-excel did not write the workbook"
  assert_contains "$TEST_TMP/readonly-writable.txt" "書き込み実績: コンテナ内で"
fi
unset FAKE_DOCKER_DIFF FAKE_READONLY_ROOTFS FAKE_CONTAINER_ENTRYPOINT

# --- --no-readonly-analysis では一切行わないこと ---
readonly_disabled_output="$TEST_TMP/readonly-disabled.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$readonly_fixture_dir/compose-readonly-missing.yml" \
    --compose-service app \
    --suppress-removed-logs \
    --no-readonly-analysis \
    --report-dir "$TEST_TMP/readonly-disabled-reports"
) >"$readonly_disabled_output" 2>&1; then
  cat "$readonly_disabled_output" >&2
  fail "--no-readonly-analysis returned a non-zero status"
fi
assert_not_contains "$readonly_disabled_output" \
  "読み取り専用ルートファイルシステム (read_only) の書き込み先分析"
collect_report_files "$TEST_TMP/readonly-disabled-reports"
readonly_disabled_reports=("${REPORT_FILES[@]}")
[ -f "${readonly_disabled_reports[0]}" ] || fail "report was not created with --no-readonly-analysis"
assert_contains "${readonly_disabled_reports[0]}" \
  "--no-readonly-analysis が指定されたため分析していません。"
for readonly_disabled_path in "$TEST_TMP/readonly-disabled-reports"/build_and_verify_*_readonly_filesystem.*; do
  if [ -e "$readonly_disabled_path" ]; then
    fail "--no-readonly-analysis still produced an analysis file: $readonly_disabled_path"
  fi
done

# --- 出力先オプションの検証 ---
readonly_ext_output="$TEST_TMP/readonly-ext.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --readonly-analysis-excel "$TEST_TMP/readonly.xls"
) >"$readonly_ext_output" 2>&1; then
  cat "$readonly_ext_output" >&2
  fail "--readonly-analysis-excel accepted a non-xlsx path"
fi
assert_contains "$readonly_ext_output" \
  "--readonly-analysis-excel には .xlsx で終わるパスを指定してください"

readonly_conflict_output="$TEST_TMP/readonly-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --no-readonly-analysis \
    --readonly-analysis-text "$TEST_TMP/readonly.txt"
) >"$readonly_conflict_output" 2>&1; then
  cat "$readonly_conflict_output" >&2
  fail "--readonly-analysis-text was accepted together with --no-readonly-analysis"
fi
assert_contains "$readonly_conflict_output" \
  "--readonly-analysis-text と --no-readonly-analysis は同時に指定できません。"

unset FAKE_COMPOSE_CONFIG_SERVICES FAKE_COMPOSE_PS_SERVICES

# ---- --copy-file の事前コピー (強制上書き / 上書き禁止) ----------------------
# 既定はコピー先の同名ファイルを強制上書きし、上書き前のファイルは処理終了時に
# 復元する。--copy-file-no-overwrite 指定時は既存ファイルに触れず中止する。
export FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log"
copy_src="$TEST_TMP/copy-src.npmrc"
printf 'from-copy-file\n' > "$copy_src"

# 既定: 既存ファイルを強制上書きし、ビルドは上書き後の内容を見る。終了後は復元される。
copy_overwrite_dir="$TEST_TMP/copy-overwrite"
mkdir -p "$copy_overwrite_dir"
printf 'pre-existing\n' > "$copy_overwrite_dir/copy-src.npmrc"
copy_overwrite_output="$TEST_TMP/copy-overwrite.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_BUILD_SNAPSHOT="$TEST_TMP/copy-overwrite.snapshot" \
  FAKE_BUILD_SNAPSHOT_SRC="$copy_overwrite_dir/copy-src.npmrc" \
  bash ./build_and_verify.sh --copy-file "${copy_src}:${copy_overwrite_dir}"
) >"$copy_overwrite_output" 2>&1; then
  cat "$copy_overwrite_output" >&2
  fail "--copy-file did not overwrite an existing destination file by default"
fi
assert_contains "$copy_overwrite_output" "コピー先の既存ファイルを強制上書きします: $copy_overwrite_dir/copy-src.npmrc"
assert_contains "$copy_overwrite_output" "上書き前のファイルを復元しました: $copy_overwrite_dir/copy-src.npmrc"
assert_not_contains "$copy_overwrite_output" "削除しました: $copy_overwrite_dir/copy-src.npmrc"
# ビルド時点ではコピー元の内容に置き換わっている
assert_contains "$TEST_TMP/copy-overwrite.snapshot" "from-copy-file"
# 処理終了後は上書き前の内容へ戻っている (自動削除で消えていない)
[ -f "$copy_overwrite_dir/copy-src.npmrc" ] \
  || fail "--copy-file removed the pre-existing destination file instead of restoring it"
assert_contains "$copy_overwrite_dir/copy-src.npmrc" "pre-existing"

# 既存ファイルが無い場合は従来どおりコピー → 自動削除
copy_new_dir="$TEST_TMP/copy-new"
mkdir -p "$copy_new_dir"
copy_new_output="$TEST_TMP/copy-new.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_BUILD_SNAPSHOT="$TEST_TMP/copy-new.snapshot" \
  FAKE_BUILD_SNAPSHOT_SRC="$copy_new_dir/copy-src.npmrc" \
  bash ./build_and_verify.sh --copy-file "${copy_src}:${copy_new_dir}"
) >"$copy_new_output" 2>&1; then
  cat "$copy_new_output" >&2
  fail "--copy-file failed for a destination without an existing file"
fi
assert_contains "$TEST_TMP/copy-new.snapshot" "from-copy-file"
assert_contains "$copy_new_output" "削除しました: $copy_new_dir/copy-src.npmrc"
assert_not_contains "$copy_new_output" "上書き前のファイルを復元しました"
[ -e "$copy_new_dir/copy-src.npmrc" ] \
  && fail "--copy-file left the copied file behind"

# --copy-file-no-overwrite: 既存ファイルがあれば中止し、既存ファイルは変更しない
copy_no_overwrite_dir="$TEST_TMP/copy-no-overwrite"
mkdir -p "$copy_no_overwrite_dir"
printf 'must-not-change\n' > "$copy_no_overwrite_dir/copy-src.npmrc"
copy_no_overwrite_output="$TEST_TMP/copy-no-overwrite.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --copy-file-no-overwrite \
    --copy-file "${copy_src}:${copy_no_overwrite_dir}"
) >"$copy_no_overwrite_output" 2>&1; then
  cat "$copy_no_overwrite_output" >&2
  fail "--copy-file-no-overwrite overwrote an existing destination file"
fi
assert_contains "$copy_no_overwrite_output" \
  "コピー先に同名ファイルが既に存在します: $copy_no_overwrite_dir/copy-src.npmrc (--copy-file-no-overwrite が指定されているため中止します)"
assert_contains "$copy_no_overwrite_dir/copy-src.npmrc" "must-not-change"

# コピー先が通常ファイル以外 (ディレクトリ) の場合は既定でも中止する
copy_dir_conflict_dir="$TEST_TMP/copy-dir-conflict"
mkdir -p "$copy_dir_conflict_dir/copy-src.npmrc"
copy_dir_conflict_output="$TEST_TMP/copy-dir-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --copy-file "${copy_src}:${copy_dir_conflict_dir}"
) >"$copy_dir_conflict_output" 2>&1; then
  cat "$copy_dir_conflict_output" >&2
  fail "--copy-file accepted a destination that is a directory"
fi
assert_contains "$copy_dir_conflict_output" \
  "コピー先が通常ファイルではありません: $copy_dir_conflict_dir/copy-src.npmrc"
[ -d "$copy_dir_conflict_dir/copy-src.npmrc" ] \
  || fail "--copy-file removed the conflicting destination directory"

# 同じコピー先を 2 回上書きしても、最終的に一番最初の内容へ戻る (逆順で巻き戻す)
copy_twice_dir="$TEST_TMP/copy-twice"
mkdir -p "$copy_twice_dir"
printf 'the-original\n' > "$copy_twice_dir/copy-src.npmrc"
copy_src2="$TEST_TMP/copy-src2/copy-src.npmrc"
mkdir -p "$TEST_TMP/copy-src2"
printf 'second-copy\n' > "$copy_src2"
copy_twice_output="$TEST_TMP/copy-twice.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --copy-file "${copy_src}:${copy_twice_dir}" \
    --copy-file "${copy_src2}:${copy_twice_dir}"
) >"$copy_twice_output" 2>&1; then
  cat "$copy_twice_output" >&2
  fail "--copy-file failed when the same destination was written twice"
fi
assert_contains "$copy_twice_dir/copy-src.npmrc" "the-original"

# --dry-run では上書き・復元の予定のみ表示し、実ファイルは変更しない
copy_dry_run_dir="$TEST_TMP/copy-dry-run"
mkdir -p "$copy_dry_run_dir"
printf 'dry-run-original\n' > "$copy_dry_run_dir/copy-src.npmrc"
copy_dry_run_output="$TEST_TMP/copy-dry-run.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --copy-file "${copy_src}:${copy_dry_run_dir}"
) >"$copy_dry_run_output" 2>&1; then
  cat "$copy_dry_run_output" >&2
  fail "--copy-file with --dry-run returned a non-zero status"
fi
assert_contains "$copy_dry_run_output" \
  "[DRY-RUN] 既存ファイルを退避して強制上書き: $copy_dry_run_dir/copy-src.npmrc"
assert_contains "$copy_dry_run_output" \
  "[DRY-RUN] 上書き前のファイルを復元: $copy_dry_run_dir/copy-src.npmrc"
assert_contains "$copy_dry_run_dir/copy-src.npmrc" "dry-run-original"


# ---- コピーしたファイル (WAR など) の取り込み検証 ----------------------------
# --copy-file で差し替えたファイルが、起動したコンテナから「今回コピーした中身」
# として見えているかを SHA-256 で突き合わせる。名前付きボリュームがデプロイ先を
# 覆っていると、イメージを作り直しても古い成果物が動き続けるが、ビルドも起動も
# 成功して見えるため、照合しない限り気付けない。
# 照合は既定では行わないため、各シナリオで --verify-copy-artifact
# (または --copy-artifact-path などの付随オプション) を指定して有効にする。
copy_artifact_src="$TEST_TMP/copy-artifact/frontend.war"
copy_artifact_old="$TEST_TMP/copy-artifact/frontend.war.old"
copy_artifact_ctx="$TEST_TMP/copy-artifact/context"
mkdir -p "$TEST_TMP/copy-artifact" "$copy_artifact_ctx"
printf 'NEW-WAR-CONTENT\n' > "$copy_artifact_src"
printf 'OLD-WAR-CONTENT\n' > "$copy_artifact_old"
copy_artifact_new_sha="$(sha256sum "$copy_artifact_src" | cut -d' ' -f1)"
copy_artifact_old_sha="$(sha256sum "$copy_artifact_old" | cut -d' ' -f1)"
copy_artifact_new_size="$(wc -c < "$copy_artifact_src" | tr -d '[:space:]')"
copy_artifact_deploy_path="/opt/eap/standalone/deployments/frontend.war"

# (0) 既定では照合しない。--copy-file を指定しただけの実行では、コンテナ内の
#     探索も SHA-256 の突き合わせも行わず、全量レポートへ理由だけを残す。
copy_artifact_default_output="$TEST_TMP/copy-artifact-default.out"
copy_artifact_default_reports="$TEST_TMP/copy-artifact-default-reports"
mkdir -p "$copy_artifact_default_reports"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE="FILE|${copy_artifact_deploy_path}|16|${copy_artifact_old_sha}" \
  FAKE_CONTAINER_MOUNTS="volume|/var/lib/docker/volumes/proj_deployments/_data|/opt/eap/standalone/deployments|true" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --report-dir "$copy_artifact_default_reports" \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_default_output" 2>&1; then
  cat "$copy_artifact_default_output" >&2
  fail "the default run must not verify copied artifacts"
fi
assert_not_contains "$copy_artifact_default_output" \
  "コピーしたファイル (--copy-file) の取り込み検証"
# 古い成果物 (不一致) を仕込んでいても、照合しない以上エラーにはしない。
assert_not_contains "$copy_artifact_default_output" "[不一致] app (test-app-1)"
# デプロイ先を覆うマウントの点検も、取り込み検証と同じ条件でのみ行う。
assert_not_contains "$copy_artifact_default_output" "デプロイ先がマウントに覆われています"
collect_report_files "$copy_artifact_default_reports"
assert_contains "${REPORT_FILES[0]}" "コピー取込検証: 未実施 (--verify-copy-artifact 未指定)"
assert_contains "${REPORT_FILES[0]}" \
  "検証の明細はありません (--verify-copy-artifact 未指定、--copy-file 未指定、またはコンテナ未起動)。"

# (1) ボリュームが古い WAR を隠している: 不一致を検出してエラー終了し、
#     イメージ側は一致していることまで示したうえで down -v まで行う。
copy_artifact_stale_output="$TEST_TMP/copy-artifact-stale.out"
: > "$FAKE_DOCKER_CALLS"
if (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE="FILE|${copy_artifact_deploy_path}|16|${copy_artifact_old_sha}" \
  FAKE_CONTAINER_MOUNTS="volume|/var/lib/docker/volumes/proj_deployments/_data|/opt/eap/standalone/deployments|true" \
  FAKE_IMAGE_ARTIFACT_FILE="$copy_artifact_src" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --verify-copy-artifact \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_stale_output" 2>&1; then
  cat "$copy_artifact_stale_output" >&2
  fail "stale artifact hidden by a volume was not reported as an error"
fi
assert_contains "$copy_artifact_stale_output" \
  "デプロイ先がマウントに覆われています: app (test-app-1) 名前付きボリューム proj_deployments -> /opt/eap/standalone/deployments"
assert_contains "$copy_artifact_stale_output" \
  "[不一致] app (test-app-1): ${copy_artifact_deploy_path}"
assert_contains "$copy_artifact_stale_output" \
  "このパスは次のマウントに覆われています: 名前付きボリューム proj_deployments -> /opt/eap/standalone/deployments"
assert_contains "$copy_artifact_stale_output" \
  "イメージ側の同じパスはコピー元と一致しています (ビルドは成功しています)。"
assert_contains "$copy_artifact_stale_output" \
  "=> マウントがイメージの内容を隠しているため、今回ビルドした成果物が使われていません。"
assert_contains "$copy_artifact_stale_output" \
  "コピーしたファイルがコンテナへ取り込まれていません (対象 1 件 (一致 0 / 不一致 1 / 未検出 0))。"
assert_contains "$copy_artifact_stale_output" \
  "※ --no-cache はイメージのビルドにしか効きません。マウントが原因の場合は変化しません。"
# 古い成果物を抱えたボリュームは、次回の実行で作り直せるようその場で削除する。
assert_contains "$copy_artifact_stale_output" \
  "古い成果物を抱えたボリュームを検出したため、後始末で compose down -v を実行します。"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down -t 30 --volumes"

# (2) イメージ側も一致しない場合は、ビルドがコピーを取り込めていないと切り分ける。
copy_artifact_build_output="$TEST_TMP/copy-artifact-build.out"
: > "$FAKE_DOCKER_CALLS"
if (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE="FILE|${copy_artifact_deploy_path}|16|${copy_artifact_old_sha}" \
  FAKE_IMAGE_ARTIFACT_FILE="$copy_artifact_old" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --verify-copy-artifact \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_build_output" 2>&1; then
  cat "$copy_artifact_build_output" >&2
  fail "artifact missing from the built image was not reported as an error"
fi
assert_contains "$copy_artifact_build_output" \
  "このパスを覆っているマウントはありません (イメージの内容がそのまま見えています)。"
assert_contains "$copy_artifact_build_output" \
  "イメージ側の同じパスもコピー元と一致しません (SHA-256: ${copy_artifact_old_sha})。"
assert_contains "$copy_artifact_build_output" \
  "=> ビルドがコピーしたファイルを取り込めていません"
# マウントが原因ではないため、ボリュームの自動削除は行わない。
assert_not_contains "$copy_artifact_build_output" \
  "古い成果物を抱えたボリュームを検出したため"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down -t 30 --volumes"

# (3) 一致していれば成功し、全量レポートの [13] にも結果が残る。
copy_artifact_ok_output="$TEST_TMP/copy-artifact-ok.out"
copy_artifact_reports="$TEST_TMP/copy-artifact-reports"
mkdir -p "$copy_artifact_reports"
if ! (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE="FILE|${copy_artifact_deploy_path}|${copy_artifact_new_size}|${copy_artifact_new_sha}" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --verify-copy-artifact \
    --report-dir "$copy_artifact_reports" \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_ok_output" 2>&1; then
  cat "$copy_artifact_ok_output" >&2
  fail "matching copied artifact returned a non-zero status"
fi
assert_contains "$copy_artifact_ok_output" "[一致] app (test-app-1): ${copy_artifact_deploy_path}"
assert_contains "$copy_artifact_ok_output" \
  "コピーしたファイルの取り込みを確認しました (対象 1 件 (一致 1 / 不一致 0 / 未検出 0))。"
collect_report_files "$copy_artifact_reports"
[ "${#REPORT_FILES[@]}" -eq 1 ] \
  || fail "expected 1 build report for the copied artifact run, found ${#REPORT_FILES[@]}"
assert_contains "${REPORT_FILES[0]}" "コピー取込検証: 対象 1 件 (一致 1 / 不一致 0 / 未検出 0)"
assert_contains "${REPORT_FILES[0]}" "[13] コピーしたファイル (--copy-file) の取り込み検証"
assert_contains "${REPORT_FILES[0]}" "判定          : OK"

# (4) コンテナ内に見つからない場合、既定は警告のみ (ビルド時にだけ使うファイル用)。
copy_artifact_missing_output="$TEST_TMP/copy-artifact-missing.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE="" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --verify-copy-artifact \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_missing_output" 2>&1; then
  cat "$copy_artifact_missing_output" >&2
  fail "missing copied artifact must not fail by default"
fi
assert_contains "$copy_artifact_missing_output" \
  "[未検出] コンテナ内に frontend.war が見つかりませんでした (ビルド時にだけ使うファイルであれば正常です)。"
assert_contains "$copy_artifact_missing_output" \
  "コピーしたファイルの取り込みは確認できませんでした (対象 1 件 (一致 0 / 不一致 0 / 未検出 1))。"

# (5) --copy-artifact-required を付けると、未検出もエラーになる。
#     (--verify-copy-artifact を書かなくても、この指定だけで照合が有効になる)
copy_artifact_required_output="$TEST_TMP/copy-artifact-required.out"
if (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE="" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --copy-artifact-required \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_required_output" 2>&1; then
  cat "$copy_artifact_required_output" >&2
  fail "--copy-artifact-required did not fail for a missing artifact"
fi
assert_contains "$copy_artifact_required_output" \
  "[未検出] コンテナ内に frontend.war が見つかりませんでした (--copy-artifact-required のためエラーとします)。"

# (6) 同名で中身の違うファイルが別の場所にあっても、一致するものが 1 つあれば成功。
#     (ビルド時にだけ使うファイルが複数箇所に置かれている構成を壊さない)
copy_artifact_mixed_output="$TEST_TMP/copy-artifact-mixed.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE="FILE|/opt/backup/frontend.war|16|${copy_artifact_old_sha}
FILE|${copy_artifact_deploy_path}|${copy_artifact_new_size}|${copy_artifact_new_sha}" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --verify-copy-artifact \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_mixed_output" 2>&1; then
  cat "$copy_artifact_mixed_output" >&2
  fail "a matching artifact alongside a differing same-named file must succeed"
fi
assert_contains "$copy_artifact_mixed_output" \
  "(同名で中身の違うファイルが 1 件ありますが、一致するものがあるため取り込みは成功と判定します)"

# (7) --no-verify-copy-artifact を指定すると照合そのものを行わない。
copy_artifact_off_output="$TEST_TMP/copy-artifact-off.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE="FILE|${copy_artifact_deploy_path}|16|${copy_artifact_old_sha}" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --no-verify-copy-artifact \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_off_output" 2>&1; then
  cat "$copy_artifact_off_output" >&2
  fail "--no-verify-copy-artifact returned a non-zero status"
fi
assert_not_contains "$copy_artifact_off_output" "コピーしたファイル (--copy-file) の取り込み検証"

# (8) コンテナにシェルが無い場合は、探索できないことを明示する。
copy_artifact_noshell_output="$TEST_TMP/copy-artifact-noshell.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE_NOSHELL=true \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --verify-copy-artifact \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_noshell_output" 2>&1; then
  cat "$copy_artifact_noshell_output" >&2
  fail "a container without a shell must not fail the run by itself"
fi
assert_contains "$copy_artifact_noshell_output" \
  "--copy-artifact-path でコンテナ内のパスを明示指定すると、docker cp で取り出して照合します。"
assert_contains "$copy_artifact_noshell_output" "探索不可のコンテナ 1 件"

# (8-2) シェルが無くても、--copy-artifact-path を指定すれば docker cp で照合できる。
#       (--verify-copy-artifact を書かなくても、この指定だけで照合が有効になる)
copy_artifact_cp_output="$TEST_TMP/copy-artifact-cp.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE_NOSHELL=true \
  FAKE_CONTAINER_ARTIFACT_FILE="$copy_artifact_src" \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --copy-artifact-path "$copy_artifact_deploy_path" \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_cp_output" 2>&1; then
  cat "$copy_artifact_cp_output" >&2
  fail "--copy-artifact-path did not fall back to docker cp on a shell-less container"
fi
assert_contains "$copy_artifact_cp_output" "コンテナ内にシェルが無いため、--copy-artifact-path のパスを docker cp で照合します"
assert_contains "$copy_artifact_cp_output" "[一致] app (test-app-1): ${copy_artifact_deploy_path}"

# (8-3) シェルが無く、docker cp でも取り出せない場合は「判定不可」として残す
#       (中身を見ていない以上、不一致とは断定しない)。
copy_artifact_unknown_output="$TEST_TMP/copy-artifact-unknown.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_COPY_ARTIFACT_PROBE_NOSHELL=true \
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --suppress-startup-logs \
    --copy-artifact-path "$copy_artifact_deploy_path" \
    --copy-file "${copy_artifact_src}:${copy_artifact_ctx}"
) >"$copy_artifact_unknown_output" 2>&1; then
  cat "$copy_artifact_unknown_output" >&2
  fail "an unreadable artifact must not be reported as a mismatch"
fi
assert_contains "$copy_artifact_unknown_output" "[判定不可] app (test-app-1): ${copy_artifact_deploy_path} (SHA-256 を算出できませんでした)"
assert_contains "$copy_artifact_unknown_output" "判定不可 1 件"
assert_not_contains "$copy_artifact_unknown_output" "[不一致] app (test-app-1)"

# (9) 指定の取り違えはその場で止める。
copy_artifact_conflict_output="$TEST_TMP/copy-artifact-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --no-verify-copy-artifact --copy-artifact-required
) >"$copy_artifact_conflict_output" 2>&1; then
  fail "--no-verify-copy-artifact with --copy-artifact-required was accepted"
fi
assert_contains "$copy_artifact_conflict_output" \
  "--no-verify-copy-artifact と --copy-artifact-path / --copy-artifact-search-dir / --copy-artifact-required は同時に指定できません。"

copy_artifact_relpath_output="$TEST_TMP/copy-artifact-relpath.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --copy-artifact-path deployments/frontend.war
) >"$copy_artifact_relpath_output" 2>&1; then
  fail "--copy-artifact-path accepted a relative path"
fi
assert_contains "$copy_artifact_relpath_output" \
  "--copy-artifact-path にはコンテナ内の絶対パスを指定してください: deployments/frontend.war"

copy_artifact_reldir_output="$TEST_TMP/copy-artifact-reldir.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --copy-artifact-search-dir opt/eap
) >"$copy_artifact_reldir_output" 2>&1; then
  fail "--copy-artifact-search-dir accepted a relative path"
fi
assert_contains "$copy_artifact_reldir_output" \
  "--copy-artifact-search-dir にはコンテナ内の絶対パスを指定してください: opt/eap"

# ---- 後始末でのボリューム削除 ------------------------------------------------
# デプロイ先やログ出力先を覆っているボリュームが残っていると、イメージを作り直しても
# 古い中身が使われ続ける。対話操作を最後まで終えた実行では、既定で down -v する。
volume_interaction_output="$TEST_TMP/volume-interaction.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_USAGE_CHECK_CALLS"
if ! printf '0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode logs \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$volume_interaction_output" 2>&1; then
  cat "$volume_interaction_output" >&2
  fail "interaction cleanup with volume removal returned a non-zero status"
fi
assert_contains "$volume_interaction_output" \
  "Compose プロジェクトのボリュームも削除します (残す場合: --keep-volumes)。"
assert_contains "$volume_interaction_output" \
  "コンテナを停止・削除します (compose down -t 30 --volumes) ..."
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down -t 30 --volumes"

# --keep-volumes を付けると、対話操作の終了後もボリュームは残す (従来の動作)。
volume_keep_output="$TEST_TMP/volume-keep.out"
: > "$FAKE_DOCKER_CALLS"
: > "$FAKE_USAGE_CHECK_CALLS"
if ! printf '0\n' | (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode logs \
    --keep-volumes \
    --suppress-startup-logs \
    --suppress-removed-logs
) >"$volume_keep_output" 2>&1; then
  cat "$volume_keep_output" >&2
  fail "--keep-volumes returned a non-zero status"
fi
assert_not_contains "$volume_keep_output" "compose down -t 30 --volumes"
assert_not_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down -t 30 --volumes"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down -t 30"

# --remove-volumes は、対話操作を伴わない通常の実行でもボリュームまで削除する。
volume_always_output="$TEST_TMP/volume-always.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --verify-startup \
    --compose-service app \
    --startup-service app \
    --remove-volumes \
    --suppress-startup-logs
) >"$volume_always_output" 2>&1; then
  cat "$volume_always_output" >&2
  fail "--remove-volumes returned a non-zero status"
fi
assert_contains "$volume_always_output" \
  "この Compose プロジェクトの名前付きボリュームも削除します (残す場合: --keep-volumes)。"
assert_contains "$FAKE_DOCKER_CALLS" "compose -f compose.yml down -t 30 --volumes"

volume_conflict_output="$TEST_TMP/volume-conflict.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --remove-volumes --keep-volumes
) >"$volume_conflict_output" 2>&1; then
  fail "--remove-volumes with --keep-volumes was accepted"
fi
assert_contains "$volume_conflict_output" \
  "--remove-volumes と --keep-volumes は同時に指定できません。"

# ---- --cacert-dir の証明書アーカイブ (BuildKit シークレット) -----------------
# 提供元ごとのディレクトリを繰り返し指定すると、各ディレクトリ直下の証明書が
# <ディレクトリ名>/<ファイル名> の構成で 1 つの tar にまとまり、compose のビルド
# 開始時点でその tar が実在することを確認する。証明書以外のファイルは混ぜない。
cacert_root="$TEST_TMP/cacerts"
mkdir -p "$cacert_root/extraslb" "$cacert_root/others1" "$cacert_root/others2"
printf -- '-----BEGIN CERTIFICATE-----\nEXTRASLB\n-----END CERTIFICATE-----\n' \
  > "$cacert_root/extraslb/cacert.crt"
printf -- '-----BEGIN CERTIFICATE-----\nOTHERS1\n-----END CERTIFICATE-----\n' \
  > "$cacert_root/others1/cacert.crt"
printf -- '-----BEGIN CERTIFICATE-----\nOTHERS2\n-----END CERTIFICATE-----\n' \
  > "$cacert_root/others2/cacert.crt"
# 同じ提供元に複数枚 (ルート + 中間) 置いた場合も両方取り込む
printf -- '-----BEGIN CERTIFICATE-----\nOTHERS2-INTERMEDIATE\n-----END CERTIFICATE-----\n' \
  > "$cacert_root/others2/intermediate.pem"
# 証明書ではないファイルは tar へ入れない
printf 'not a certificate\n' > "$cacert_root/others2/README.md"

# --cacert-bundle で出力先を固定し、ビルド時点のアーカイブを控えて中身を確かめる。
cacert_bundle="$TEST_TMP/cacerts-bundle.tar"
cacert_output="$TEST_TMP/cacert.out"
if ! (
  cd "$REPO_ROOT"
  FAKE_BUILD_SNAPSHOT="$TEST_TMP/cacert.snapshot" \
  FAKE_BUILD_SNAPSHOT_SRC="$cacert_bundle" \
  bash ./build_and_verify.sh \
    --cacert-bundle "$cacert_bundle" \
    --cacert-dir "$cacert_root/extraslb" \
    --cacert-dir "$cacert_root/others1/" \
    --cacert-dir "$cacert_root/others2" \
    --report-dir "$TEST_TMP/cacert-reports"
) >"$cacert_output" 2>&1; then
  cat "$cacert_output" >&2
  fail "--cacert-dir returned a non-zero status"
fi
assert_contains "$cacert_output" "CA 証明書を 1 つの tar へまとめます (3 ディレクトリ / シークレット id=cacerts) ..."
assert_contains "$cacert_output" "extraslb: 証明書 1 件 <- $cacert_root/extraslb"
# 末尾に / を付けて指定しても提供元名は others1 になる
assert_contains "$cacert_output" "others1: 証明書 1 件 <- $cacert_root/others1"
assert_contains "$cacert_output" "others2: 証明書 2 件 <- $cacert_root/others2"
assert_contains "$cacert_output" "提供元: extraslb others1 others2 / 証明書 4 件"
assert_contains "$cacert_output" "ビルド中のマウント先: /run/secrets/cacerts"
# 同梱 compose.yml には受け取り側の定義があるため、警告ではなく確認のログが出る
assert_contains "$cacert_output" "CA 証明書シークレットの受け取り定義を確認しました"
# 全量レポートにも取り込んだ提供元が残る (配置漏れの事後確認用)
collect_report_files "$TEST_TMP/cacert-reports"
[ "${#REPORT_FILES[@]}" -eq 1 ] || fail "expected 1 report for --cacert-dir, found ${#REPORT_FILES[@]}"
assert_contains "${REPORT_FILES[0]}" \
  "CA 証明書     : 提供元: extraslb others1 others2 / 証明書 4 件 / シークレット id=cacerts"
# ビルド開始時点でアーカイブが実在し、中身が <提供元名>/<ファイル名> になっている
[ -f "$TEST_TMP/cacert.snapshot" ] \
  || fail "--cacert-dir did not have the bundle in place when the build started"
cacert_entries="$TEST_TMP/cacert-entries.txt"
tar -tf "$TEST_TMP/cacert.snapshot" > "$cacert_entries" 2>/dev/null \
  || fail "--cacert-dir produced an archive that tar could not read"
assert_contains "$cacert_entries" "extraslb/cacert.crt"
assert_contains "$cacert_entries" "others1/cacert.crt"
assert_contains "$cacert_entries" "others2/cacert.crt"
assert_contains "$cacert_entries" "others2/intermediate.pem"
assert_not_contains "$cacert_entries" "README.md"

# 指定したディレクトリが無い / 証明書が無い / 名前が重複する場合は、証明書の
# 入らないイメージが黙って完成しないよう、その場で失敗させる。
cacert_missing_output="$TEST_TMP/cacert-missing.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --cacert-dir "$cacert_root/nosuchdir"
) >"$cacert_missing_output" 2>&1; then
  cat "$cacert_missing_output" >&2
  fail "--cacert-dir accepted a directory that does not exist"
fi
assert_contains "$cacert_missing_output" "証明書ディレクトリが見つかりません: $cacert_root/nosuchdir"

mkdir -p "$cacert_root/empty"
cacert_empty_output="$TEST_TMP/cacert-empty.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --cacert-dir "$cacert_root/empty"
) >"$cacert_empty_output" 2>&1; then
  cat "$cacert_empty_output" >&2
  fail "--cacert-dir accepted a directory without any certificate"
fi
assert_contains "$cacert_empty_output" "証明書が見つかりません: $cacert_root/empty"

mkdir -p "$TEST_TMP/cacerts-other/others1"
printf -- '-----BEGIN CERTIFICATE-----\nDUP\n-----END CERTIFICATE-----\n' \
  > "$TEST_TMP/cacerts-other/others1/cacert.crt"
cacert_dup_output="$TEST_TMP/cacert-dup.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --cacert-dir "$cacert_root/others1" \
    --cacert-dir "$TEST_TMP/cacerts-other/others1"
) >"$cacert_dup_output" 2>&1; then
  cat "$cacert_dup_output" >&2
  fail "--cacert-dir accepted duplicated directory names"
fi
assert_contains "$cacert_dup_output" "--cacert-dir のディレクトリ名が重複しています: others1"

# --cacert-dir を指定しない実行は従来どおり (証明書関連の出力を一切増やさない)。
cacert_absent_output="$TEST_TMP/cacert-absent.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --report-dir "$TEST_TMP/cacert-absent-reports"
) >"$cacert_absent_output" 2>&1; then
  cat "$cacert_absent_output" >&2
  fail "build without --cacert-dir returned a non-zero status"
fi
assert_not_contains "$cacert_absent_output" "CA 証明書を 1 つの tar へまとめます"
assert_not_contains "$cacert_absent_output" "証明書アーカイブを作成しました"
collect_report_files "$TEST_TMP/cacert-absent-reports"
[ "${#REPORT_FILES[@]}" -eq 1 ] || fail "expected 1 report without --cacert-dir, found ${#REPORT_FILES[@]}"
assert_contains "${REPORT_FILES[0]}" "CA 証明書     : (未指定)"

# =============================================================================
# ビルドの停滞検知・進捗表示
# -----------------------------------------------------------------------------
# BuildKit の exporting layers は --progress=plain では完了まで何も出力しないため、
# 「止まっているのか進んでいるのか」を画面から判断できない。fake docker に
# 無出力時間を作らせ、進捗表示・停滞診断・上限時間での中断を確認する。
# =============================================================================

# 進捗表示と停滞検知。exporting layers で 8 秒間出力が途切れる状況を作る。
export FAKE_DOCKER_BUILD_EXPORT_STALL=8
export FAKE_DOCKER_DATA_ROOT="$TEST_TMP/fake-data-root"
mkdir -p "$FAKE_DOCKER_DATA_ROOT"
build_stall_output="$TEST_TMP/build-stall.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --build-progress-interval 2 \
    --build-stall-timeout 4 \
    --report-dir "$TEST_TMP/build-stall-reports"
) >"$build_stall_output" 2>&1; then
  cat "$build_stall_output" >&2
  fail "build watchdog scenario returned a non-zero status"
fi
# 監視設定の表示と、ビルド開始前の空き容量チェック
assert_contains "$build_stall_output" "ビルドの停滞検知: 進捗表示 2 秒間隔 / 停滞判定 4 秒 / 上限 なし (無制限)"
assert_contains "$build_stall_output" "ビルド開始前の data root 空き容量:"
# BuildKit のフェーズを出力から検出し、経過時間つきで表示する
assert_matches "$build_stall_output" \
  'ビルド継続中 \(全サービス\): 経過 .+ / 直近の出力から .+ / フェーズ: exporting layers'
assert_contains "$build_stall_output" "  data root の空き容量:"
# 出力が途切れたら停滞と判断し、原因の切り分け診断を出す
assert_contains "$build_stall_output" "停滞の可能性があるため診断します。"
assert_contains "$build_stall_output" "ビルド停滞の診断 (停滞検知)"
assert_contains "$build_stall_output" "BuildKit のフェーズ  : exporting layers (レイヤをイメージストアへ書き出し中)"
assert_contains "$build_stall_output" "Docker daemon        : 応答あり (Server 27.1.1)"
assert_contains "$build_stall_output" "exporting layers から進まないときの主な原因と確認方法:"
assert_contains "$build_stall_output" "1. 遅いだけで進んでいる (最も多い)"
assert_contains "$build_stall_output" "6. 端末のフロー制御 (Ctrl+S) で画面表示だけが止まっている"
# 停滞を検知しても処理は中断せず、ビルド出力はそのまま流れる
assert_contains "$build_stall_output" "#12 exporting layers 8s done"
assert_contains "$build_stall_output" "compose build に成功しました (全サービス)。"
# 全量レポートにも監視結果を残す
collect_report_files "$TEST_TMP/build-stall-reports"
[ "${#REPORT_FILES[@]}" -eq 1 ] \
  || fail "expected exactly 1 report file for the build watchdog scenario"
assert_matches "${REPORT_FILES[0]}" 'ビルド監視    : 進捗表示 2 秒間隔 / 停滞判定 4 秒 / 上限 なし \(無制限\) / 最長の無出力 '

# Docker daemon が応答しない場合は診断でそう表示する
export FAKE_DOCKER_DAEMON_HANG=true
build_hang_output="$TEST_TMP/build-daemon-hang.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --build-progress-interval 0 --build-stall-timeout 3
) >"$build_hang_output" 2>&1; then
  cat "$build_hang_output" >&2
  fail "build watchdog daemon-hang scenario returned a non-zero status"
fi
assert_contains "$build_hang_output" \
  "Docker daemon        : 10 秒以内に応答しません (daemon 側で停止している可能性)"
unset FAKE_DOCKER_DAEMON_HANG

# 上限時間を超えたらビルドを中断し、プロンプトを返す (終了コード 1)。
# 60 秒の無出力を作っても、中断処理により短時間で戻ることを確認する。
export FAKE_DOCKER_BUILD_EXPORT_STALL=60
build_timeout_output="$TEST_TMP/build-timeout.out"
build_timeout_started="$(date +%s)"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --build-timeout 4 \
    --build-progress-interval 0 \
    --build-stall-timeout 0 \
    --report-dir "$TEST_TMP/build-timeout-reports"
) >"$build_timeout_output" 2>&1; then
  cat "$build_timeout_output" >&2
  fail "--build-timeout did not fail the run when the build exceeded the limit"
fi
build_timeout_elapsed=$(( $(date +%s) - build_timeout_started ))
# 中断できずに sleep 60 の完走を待ってしまっていないこと (当初の症状への回帰防止)
[ "$build_timeout_elapsed" -lt 45 ] \
  || fail "--build-timeout took ${build_timeout_elapsed}s to return; the abort did not take effect"
assert_contains "$build_timeout_output" "ビルドが上限時間 4 秒を超えました"
assert_contains "$build_timeout_output" "ビルド停滞の診断 (上限時間超過)"
assert_contains "$build_timeout_output" "ビルドプロセスへ SIGTERM を送ります"
assert_contains "$build_timeout_output" "ビルドを上限時間 (4 秒) で中断しました: 全サービス"
collect_report_files "$TEST_TMP/build-timeout-reports"
[ "${#REPORT_FILES[@]}" -eq 1 ] \
  || fail "expected exactly 1 report file for the build timeout scenario"
assert_contains "${REPORT_FILES[0]}" \
  "詳細          : compose build が上限時間 (4 秒) を超えたため中断しました。"
assert_contains "${REPORT_FILES[0]}" "上限時間超過により中断"
unset FAKE_DOCKER_BUILD_EXPORT_STALL

# --no-build-watchdog では監視を行わず、従来どおりビルド出力をそのまま流す
build_no_watchdog_output="$TEST_TMP/build-no-watchdog.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --no-build-watchdog
) >"$build_no_watchdog_output" 2>&1; then
  cat "$build_no_watchdog_output" >&2
  fail "--no-build-watchdog returned a non-zero status"
fi
assert_contains "$build_no_watchdog_output" \
  "ビルドの停滞検知: 無効 (--no-build-watchdog または各値に 0 を指定)"
assert_not_contains "$build_no_watchdog_output" "ビルドを監視します"
assert_contains "$build_no_watchdog_output" "compose build に成功しました (全サービス)。"

# BUILDKIT_PROGRESS=tty は行単位で読めないため、監視有効時は plain へ切り替える
build_tty_output="$TEST_TMP/build-progress-tty.out"
if ! (
  cd "$REPO_ROOT"
  BUILDKIT_PROGRESS=tty bash ./build_and_verify.sh
) >"$build_tty_output" 2>&1; then
  cat "$build_tty_output" >&2
  fail "BUILDKIT_PROGRESS=tty run returned a non-zero status"
fi
assert_contains "$build_tty_output" \
  "BUILDKIT_PROGRESS=tty はビルド監視と併用できないため plain へ切り替えます。"
assert_contains "$build_tty_output" "BuildKit のビルドログ表示形式: plain"
assert_contains "$build_tty_output" "[fake-build] BUILDKIT_PROGRESS=plain"

# --no-build-watchdog なら tty 指定をそのまま尊重する
build_tty_keep_output="$TEST_TMP/build-progress-tty-keep.out"
if ! (
  cd "$REPO_ROOT"
  BUILDKIT_PROGRESS=tty bash ./build_and_verify.sh --no-build-watchdog
) >"$build_tty_keep_output" 2>&1; then
  cat "$build_tty_keep_output" >&2
  fail "BUILDKIT_PROGRESS=tty with --no-build-watchdog returned a non-zero status"
fi
assert_contains "$build_tty_keep_output" "[fake-build] BUILDKIT_PROGRESS=tty"

# 監視の各値は 0 以上の整数のみ受け付ける
build_bad_value_output="$TEST_TMP/build-bad-value.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --build-timeout abc
) >"$build_bad_value_output" 2>&1; then
  cat "$build_bad_value_output" >&2
  fail "--build-timeout accepted a non-numeric value"
fi
assert_contains "$build_bad_value_output" \
  "--build-timeout には 0 以上の整数を指定してください: abc"
unset FAKE_DOCKER_DATA_ROOT

# ---------------------------------------------------------------------------
# 証明書チェック本体 (コンテナ内で docker exec される埋め込みスクリプト) の詳細診断。
# docker のモックは本体の出力そのものを模擬しているため、埋め込みスクリプトの中身は
# そこでは検証できない。ここでは build_and_verify.sh から本体を取り出し、実物の
# openssl と偽の keytool / curl / getent で直接動かして診断内容を確認する。
#
# 再現するのは「自己証明書 (cacert.crt) だけを受領し、秘密鍵が無い」構成:
#   トラストストア = JDK 標準 CA 2 枚 + 受領 cacert.crt
#   サーバ提示     = リーフ + local-test-ca (自己署名) ← トラストストアに無い
# 取り込みは成功しているのに接続できない、という状態を診断できることを確かめる。
# ---------------------------------------------------------------------------
if ! command -v openssl >/dev/null 2>&1; then
  printf 'SKIP: openssl が無いため証明書チェックの詳細診断テストを省略します\n'
else
  # Git Bash (MSYS2) は "/C=JP/..." を Windows パスへ変換するため除外する。
  # Linux では無害。
  export MSYS2_ARG_CONV_EXCL='/C='

  CC_T="$TEST_TMP/cert-check"
  mkdir -p "$CC_T/pki" "$CC_T/bin" "$CC_T/java/bin" "$CC_T/java/lib/security" \
           "$CC_T/trust" "$CC_T/store"

  cc_begin_line="$(grep -n "cat <<'CERT_CHECK_SCRIPT'" "$REPO_ROOT/build_and_verify.sh" \
    | head -n 1 | cut -d: -f1)"
  cc_end_line="$(grep -n '^CERT_CHECK_SCRIPT$' "$REPO_ROOT/build_and_verify.sh" \
    | head -n 1 | cut -d: -f1)"
  [ -n "$cc_begin_line" ] && [ -n "$cc_end_line" ] \
    || fail "could not locate the CERT_CHECK_SCRIPT heredoc in build_and_verify.sh"
  sed -n "$((cc_begin_line + 1)),$((cc_end_line - 1))p" "$REPO_ROOT/build_and_verify.sh" \
    > "$CC_T/cert-check.sh"
  sh -n "$CC_T/cert-check.sh" \
    || fail "the embedded cert-check script is not valid POSIX sh"

  cc_make_ca() {  # $1=ファイル名の基底 $2=CN
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$CC_T/pki/$1.key" -out "$CC_T/pki/$1.crt" \
      -subj "/C=JP/O=Local Test Org/CN=$2" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1 \
      || fail "openssl could not generate the test CA: $1"
  }
  cc_make_ca jdk-ca-1 "Fake Public Root CA 1"
  cc_make_ca jdk-ca-2 "Fake Public Root CA 2"
  cc_make_ca cacert "Received Self-Signed CA"
  cc_make_ca local-test-ca "Local Test Server-Issuing CA (no received key)"

  cat > "$CC_T/pki/leaf.ext" <<'CERT_CHECK_LEAF_EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:secure-api,DNS:localhost,IP:127.0.0.1
CERT_CHECK_LEAF_EXT
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$CC_T/pki/leaf.key" -out "$CC_T/pki/leaf.csr" \
    -subj "/C=JP/O=Local Test Org/CN=secure-api" >/dev/null 2>&1 \
    || fail "openssl could not generate the test leaf CSR"
  openssl x509 -req -in "$CC_T/pki/leaf.csr" \
    -CA "$CC_T/pki/local-test-ca.crt" -CAkey "$CC_T/pki/local-test-ca.key" \
    -CAcreateserial -days 825 -sha256 -extfile "$CC_T/pki/leaf.ext" \
    -out "$CC_T/pki/leaf.crt" >/dev/null 2>&1 \
    || fail "openssl could not issue the test leaf certificate"

  # サーバが提示するチェーン (リーフ + 発行元の自己署名 CA)
  cat "$CC_T/pki/leaf.crt" "$CC_T/pki/local-test-ca.crt" > "$CC_T/pki/presented.pem"
  # 受領物の投入口 (PKI_TRUST_DIR として渡す)
  cp "$CC_T/pki/cacert.crt" "$CC_T/trust/cacert.crt"

  # keytool -list -rfc が返す「トラストストアの中身」を組み立てる。
  # $1 に追加で入れる CA の基底名を並べる (空なら JDK 標準の 2 枚だけ)。
  cc_write_store() {
    {
      printf 'Keystore type: PKCS12\nKeystore provider: SUN\n\n'
      printf 'Your keystore contains %s entries\n\n' "$(($# + 2))"
      for cc_entry in "jdk-ca-1:fakepublicca1 [jdk]" "jdk-ca-2:fakepublicca2 [jdk]" "$@"; do
        printf 'Alias name: %s\nCreation date: Aug 5, 2026\nEntry type: trustedCertEntry\n\n' \
          "${cc_entry#*:}"
        cat "$CC_T/pki/${cc_entry%%:*}.crt"
        printf '\n\n'
      done
    } > "$CC_T/store-rfc.out"
  }

  # keytool -list (非 rfc) が返す JDK 標準 cacerts の指紋一覧
  {
    printf 'Keystore type: JKS\nKeystore provider: SUN\n\nYour keystore contains 2 entries\n\n'
    for cc_n in 1 2; do
      printf 'fakepublicca%s [jdk], Aug 5, 2026, trustedCertEntry,\n' "$cc_n"
      printf 'Certificate fingerprint (SHA-256): %s\n' \
        "$(openssl x509 -in "$CC_T/pki/jdk-ca-$cc_n.crt" -noout -fingerprint -sha256 \
           | sed 's/^.*=//')"
    done
  } > "$CC_T/jdk-list.out"

  cat > "$CC_T/java/bin/keytool" <<CERT_CHECK_FAKE_KEYTOOL
#!/bin/sh
case " \$* " in
  *" -rfc "*)  cat "$CC_T/store-rfc.out"; exit 0 ;;
  *" -list "*) cat "$CC_T/jdk-list.out";  exit 0 ;;
esac
exit 1
CERT_CHECK_FAKE_KEYTOOL
  chmod +x "$CC_T/java/bin/keytool"
  : > "$CC_T/java/lib/security/cacerts"

  # 偽 curl: サーバ提示チェーンの CA を含む束を渡されたときだけ成功する。
  cat > "$CC_T/bin/curl" <<CERT_CHECK_FAKE_CURL
#!/bin/sh
cc_cacert=""
cc_prev=""
for cc_arg in "\$@"; do
  [ "\$cc_prev" = "--cacert" ] && cc_cacert="\$cc_arg"
  cc_prev="\$cc_arg"
done
cc_mark="\$(sed -n '3p' "$CC_T/pki/local-test-ca.crt")"
if [ -n "\$cc_cacert" ] && grep -qF "\$cc_mark" "\$cc_cacert" 2>/dev/null; then
  printf '200'
  exit 0
fi
printf 'curl: (60) SSL certificate problem: self-signed certificate in certificate chain\n' >&2
exit 60
CERT_CHECK_FAKE_CURL
  chmod +x "$CC_T/bin/curl"

  # openssl は s_client だけ差し替え、他は本物へ委譲する。
  cat > "$CC_T/bin/openssl" <<CERT_CHECK_FAKE_OPENSSL
#!/bin/sh
if [ "\$1" = "s_client" ]; then
  printf 'CONNECTED(00000003)\nCertificate chain\n'
  cat "$CC_T/pki/presented.pem"
  printf -- '---\nVerify return code: 19 (self-signed certificate in certificate chain)\n'
  exit 0
fi
exec "$(command -v openssl)" "\$@"
CERT_CHECK_FAKE_OPENSSL
  chmod +x "$CC_T/bin/openssl"

  cat > "$CC_T/bin/getent" <<'CERT_CHECK_FAKE_GETENT'
#!/bin/sh
[ "${1:-}" = "hosts" ] && [ "${2:-}" = "secure-api" ] || exit 2
printf '172.20.0.5 secure-api\n'
CERT_CHECK_FAKE_GETENT
  chmod +x "$CC_T/bin/getent"

  : > "$CC_T/store/extraslb-truststore.p12"

  cc_run_check() {  # $1=出力ファイル
    (
      PATH="$CC_T/bin:$PATH"
      export PATH
      export JAVA_HOME="$CC_T/java"
      export EXTRASLB_TRUSTSTORE_PATH="$CC_T/store/extraslb-truststore.p12"
      export EXTRASLB_TRUSTSTORE_PASSWORD='changeit'
      export PKI_TRUST_DIR="${PKI_TRUST_DIR_OVERRIDE:-$CC_T/trust}"
      export SECURE_API_URL='https://secure-api:8443/api/v1/ping'
      sh "$CC_T/cert-check.sh"
    ) > "$1" 2>&1
  }

  # --- (1) 受領 CA は入っているが、サーバ証明書の発行元が別 CA ---------------
  cc_missing_output="$TEST_TMP/cert-check-missing-anchor.out"
  cc_write_store "cacert:extraslb-ca-1"
  cc_rc=0
  cc_run_check "$cc_missing_output" || cc_rc=$?
  [ "$cc_rc" -eq 1 ] \
    || { cat "$cc_missing_output" >&2; fail "cert check should exit 1 for a missing trust anchor (got $cc_rc)"; }

  # 接続の合否より前に、受領した自己証明書の素性を確定させている
  assert_contains "$cc_missing_output" "=== 1. 受領した自己証明書 (cacert.crt) の詳細 ==="
  assert_contains "$cc_missing_output" "ファイル形式    : PEM (証明書 1 枚)"
  assert_contains "$cc_missing_output" \
    "X.509 バージョン: v3 (拡張を持てる。CA かどうかを basicConstraints で明示できる)"
  assert_contains "$cc_missing_output" "基本制約        : CA:TRUE, pathlen:0 (critical)"
  assert_contains "$cc_missing_output" "鍵用途          : Certificate Sign, CRL Sign"
  assert_contains "$cc_missing_output" \
    "自己署名        : YES (subject = issuer。自分の公開鍵で署名を検証できた)"
  assert_contains "$cc_missing_output" \
    "種別            : ルート CA 証明書 (自己署名の CA。信頼の連鎖の最上位)"
  assert_contains "$cc_missing_output" \
    "トラストアンカー: できる。この CA が発行した証明書を検証できるようになる"
  assert_contains "$cc_missing_output" \
    "[PASS] cacert.crt は自己署名のルート CA 証明書 (X.509 v3) で、トラストアンカーにできる"
  assert_contains "$cc_missing_output" "[PASS] cacert.crt は有効期間内 ("
  # 判定の材料 (詳細) は、接続結果より前に出ている
  assert_before "$cc_missing_output" \
    "=== 1. 受領した自己証明書 (cacert.crt) の詳細 ===" "=== 3-1. HTTPS 接続 SECURE_API_URL ==="
  # 全項目 (openssl x509 -text) を末尾へ添付し、テキスト 1 枚で追えるようにする
  assert_contains "$cc_missing_output" "=== 5. 受領した自己証明書の全項目 (openssl x509 -text) ==="
  assert_contains "$cc_missing_output" "X509v3 Basic Constraints: critical"
  assert_before "$cc_missing_output" \
    "=== 4. 次の一手 ===" "=== 5. 受領した自己証明書の全項目 (openssl x509 -text) ==="
  # 取り込み自体は成功していることを示す (0 件なら取り込み漏れと区別できない)
  assert_contains "$cc_missing_output" "独自に追加された CA: 1 件 (JDK 標準 cacerts に無い証明書)"
  assert_contains "$cc_missing_output" "alias=extraslb-ca-1"
  assert_contains "$cc_missing_output" "[PASS] cacert.crt と同一の証明書がこのストアに登録されている"
  # サーバが提示しているチェーンを解析できている
  assert_contains "$cc_missing_output" "サーバが提示した証明書: 2 枚 (openssl s_client -showcerts)"
  assert_contains "$cc_missing_output" \
    "自己署名: YES (チェーンの最上位。クライアントが直接信頼している必要がある)"
  assert_contains "$cc_missing_output" \
    "[PASS] 接続先ホスト名 secure-api はサーバ証明書の SAN に含まれている"
  # 失敗の原因を発行者 CA の不在まで特定できている
  assert_contains "$cc_missing_output" "[FAIL] $CC_T/store/extraslb-truststore.p12 由来の PEM で接続失敗 (curl exit=60)"
  assert_contains "$cc_missing_output" "★発行者 CA がこのトラストストアに無い: "
  assert_contains "$cc_missing_output" "CN=Local Test Server-Issuing CA (no received key)"
  assert_contains "$cc_missing_output" "自己署名: YES → これを信頼していないことが exit 60 の直接原因。"
  assert_contains "$cc_missing_output" \
    "★取り込み自体は成功している: cacert.crt はこのストアに入っている。"
  assert_contains "$cc_missing_output" \
    "検証: サーバが提示したチェーンを CA として渡すと接続できた。"
  # 本命も失敗しているときの対照テストは PASS と数えない
  assert_contains "$cc_missing_output" "対照テスト: --cacert 無しでも検証に失敗した (curl exit 60)。"
  assert_not_contains "$cc_missing_output" "[PASS] 対照テスト"
  # 次の一手が出ている
  assert_contains "$cc_missing_output" "● 受領した自己証明書はストアに入っているのに接続できない"
  assert_contains "$cc_missing_output" "● サーバ証明書の発行元 CA がトラストストアに入っていない"
  assert_contains "$cc_missing_output" "判定: NG — 上記 [FAIL] の内容を確認してください。"

  # --- (2) 発行元のローカル CA も信頼させた正常系 -----------------------------
  cc_ok_output="$TEST_TMP/cert-check-trust-local.out"
  cc_write_store "cacert:extraslb-ca-1" "local-test-ca:local-test-ca"
  cc_run_check "$cc_ok_output" \
    || { cat "$cc_ok_output" >&2; fail "cert check should exit 0 once the issuing CA is trusted"; }
  assert_contains "$cc_ok_output" "独自に追加された CA: 2 件 (JDK 標準 cacerts に無い証明書)"
  assert_contains "$cc_ok_output" "由来の PEM で接続成功 (HTTP 200)"
  # 本命が成功しているときだけ対照テストは PASS になる
  assert_contains "$cc_ok_output" "[PASS] 対照テスト: --cacert 無しでは検証に失敗した (curl exit 60)"
  assert_contains "$cc_ok_output" "判定: OK — 検出したトラストストアの証明書で HTTPS 接続できています。"
  assert_not_contains "$cc_ok_output" "=== 4. 次の一手 ==="

  # --- (3) 取り込み自体が漏れている (JDK 標準そのまま) ------------------------
  cc_not_imported_output="$TEST_TMP/cert-check-not-imported.out"
  cc_write_store
  cc_rc=0
  cc_run_check "$cc_not_imported_output" || cc_rc=$?
  [ "$cc_rc" -eq 1 ] \
    || { cat "$cc_not_imported_output" >&2; fail "cert check should exit 1 when nothing was imported (got $cc_rc)"; }
  assert_contains "$cc_not_imported_output" "[WARN] 独自に追加された CA: 0 件"
  assert_contains "$cc_not_imported_output" "[FAIL] cacert.crt はこのストアに登録されていない"
  assert_contains "$cc_not_imported_output" "● 検出した CA 証明書がトラストストアに入っていない"
  assert_contains "$cc_not_imported_output" "● トラストストアが JDK 標準 cacerts と同じ内容"
  # 取り込み済みではないので、発行元違いの案内は出さない
  assert_not_contains "$cc_not_imported_output" "★取り込み自体は成功している"

  # --- (4) 受領物が CA ではないリーフ証明書だった ------------------------------
  # 「cacert.crt を置いたのに接続できない」の原因が、そもそも CA 証明書ではない
  # ことである場合を、接続の合否より前に指摘できることを確かめる。
  cc_leaf_output="$TEST_TMP/cert-check-leaf-cacert.out"
  mkdir -p "$CC_T/trust-leaf"
  cp "$CC_T/pki/leaf.crt" "$CC_T/trust-leaf/cacert.crt"
  cc_write_store "cacert:extraslb-ca-1"
  cc_rc=0
  PKI_TRUST_DIR_OVERRIDE="$CC_T/trust-leaf"
  cc_run_check "$cc_leaf_output" || cc_rc=$?
  unset PKI_TRUST_DIR_OVERRIDE
  [ "$cc_rc" -eq 1 ] \
    || { cat "$cc_leaf_output" >&2; fail "cert check should exit 1 for a leaf cacert.crt (got $cc_rc)"; }
  assert_contains "$cc_leaf_output" "基本制約        : CA:FALSE (critical)"
  assert_contains "$cc_leaf_output" "自己署名        : NO (別の CA が発行した証明書)"
  assert_contains "$cc_leaf_output" \
    "種別            : end-entity 証明書 (CA ではないリーフ。別の CA が発行)"
  assert_contains "$cc_leaf_output" \
    "トラストアンカー: 向かない。発行元の CA 証明書を配布元から入手する"
  assert_contains "$cc_leaf_output" \
    "[WARN] cacert.crt は CA 証明書ではない (別の CA が発行したリーフ)。cacert.crt の取り違えを疑う"
  assert_contains "$cc_leaf_output" "● 受領した証明書が CA 証明書ではない (別の CA が発行したリーフ)"

  # --- (5) 受領物が X.509 v1 の自己署名証明書だった ---------------------------
  # v1 には basicConstraints が無く、CA かどうかを証明書自身では示せない。
  # アンカーにはできるが用途を制限できないことを指摘する。
  # v1 を作れない openssl (拡張が既定で付く) の場合はこの確認だけ省く。
  printf '[req]\ndistinguished_name=cc_dn\n[cc_dn]\n' > "$CC_T/pki/v1.cnf"
  openssl req -x509 -x509v1 -config "$CC_T/pki/v1.cnf" \
    -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CC_T/pki/legacy-v1.key" -out "$CC_T/pki/legacy-v1.crt" \
    -subj "/C=JP/O=Local Test Org/CN=Legacy V1 CA" >/dev/null 2>&1 || :
  cc_v1_version="$(openssl x509 -in "$CC_T/pki/legacy-v1.crt" -noout -text 2>/dev/null \
    | sed -n 's/^[[:space:]]*Version:[[:space:]]*\([0-9]\).*/\1/p' | head -n 1)"
  if [ "${cc_v1_version:-}" != "1" ]; then
    printf 'SKIP: この openssl では X.509 v1 の証明書を生成できないため v1 判定の確認を省略します\n'
  else
    cc_v1_output="$TEST_TMP/cert-check-v1-cacert.out"
    mkdir -p "$CC_T/trust-v1"
    cp "$CC_T/pki/legacy-v1.crt" "$CC_T/trust-v1/cacert.crt"
    cc_rc=0
    PKI_TRUST_DIR_OVERRIDE="$CC_T/trust-v1"
    cc_run_check "$cc_v1_output" || cc_rc=$?
    unset PKI_TRUST_DIR_OVERRIDE
    [ "$cc_rc" -eq 1 ] \
      || { cat "$cc_v1_output" >&2; fail "cert check should exit 1 for a v1 cacert.crt (got $cc_rc)"; }
    assert_contains "$cc_v1_output" \
      "X.509 バージョン: v1 (拡張を持てない。CA かどうかを証明書自身では示せない)"
    assert_contains "$cc_v1_output" "基本制約        : (なし)"
    assert_contains "$cc_v1_output" \
      "種別            : 自己署名証明書 (X.509 v1 / v2 のため CA かどうかを拡張で示せない)"
    assert_contains "$cc_v1_output" \
      "[WARN] cacert.crt は X.509 v1 で basicConstraints を持たない (CA かどうかを判定できない)"
    assert_contains "$cc_v1_output" "● 受領した証明書が X.509 v1 / v2 (拡張を持たない)"
  fi

  # --- (6) 受領物が期限切れのルート CA だった -------------------------------
  # openssl verify は期限切れを理由に失敗するため、素朴に判定すると
  # 「自己署名を検証できない」と読めてしまう。種別はルート CA のまま示し、
  # 期限切れは期限切れとして [FAIL] にすることを確かめる。
  # 過去日付の証明書を作れない openssl の場合はこの確認だけ省く。
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "$CC_T/pki/expired-ca.key" -out "$CC_T/pki/expired-ca.crt" \
    -subj "/C=JP/O=Local Test Org/CN=Expired Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -not_before 20200101000000Z -not_after 20210101000000Z >/dev/null 2>&1 || :
  if [ ! -s "$CC_T/pki/expired-ca.crt" ] \
      || openssl x509 -in "$CC_T/pki/expired-ca.crt" -noout -checkend 0 >/dev/null 2>&1; then
    printf 'SKIP: この openssl では期限切れの証明書を生成できないため期限切れ判定の確認を省略します\n'
  else
    cc_expired_output="$TEST_TMP/cert-check-expired-cacert.out"
    mkdir -p "$CC_T/trust-expired"
    cp "$CC_T/pki/expired-ca.crt" "$CC_T/trust-expired/cacert.crt"
    cc_rc=0
    PKI_TRUST_DIR_OVERRIDE="$CC_T/trust-expired"
    cc_run_check "$cc_expired_output" || cc_rc=$?
    unset PKI_TRUST_DIR_OVERRIDE
    [ "$cc_rc" -eq 1 ] \
      || { cat "$cc_expired_output" >&2; fail "cert check should exit 1 for an expired cacert.crt (got $cc_rc)"; }
    # 期限切れでも「自己署名のルート CA」であることは変わらない
    assert_contains "$cc_expired_output" \
      "自己署名        : YES (subject = issuer。自分の公開鍵で署名を検証できた)"
    assert_contains "$cc_expired_output" \
      "種別            : ルート CA 証明書 (自己署名の CA。信頼の連鎖の最上位)"
    assert_contains "$cc_expired_output" "[FAIL] cacert.crt は有効期限が切れている ("
    assert_contains "$cc_expired_output" "● 有効期限切れの証明書がある"
  fi

  unset MSYS2_ARG_CONV_EXCL
fi


# ---- build コンテキスト / Dockerfile の上書き -------------------------------
# --base-context / --base-dockerfile / --frontend-context / --frontend-dockerfile /
# --backend-context / --backend-dockerfile の確認。
#   - 指定した値が compose へ反映された状態でビルドが行われること
#   - 元の compose ファイルは 1 バイトも書き換えないこと
#   - 生成した実効 compose ファイルは処理終了時に消えること
#   - 指定しなかった項目・キーワードに一致しないサービスは元の値のままであること
#   - build 定義を持たないサービスは、キーワードに一致しても対象にしないこと
# 直前までのシナリオが export したフィクスチャ設定 (ビルド失敗の再現など) を
# 引きずると、この節の確認が別の理由で落ちる。呼び出し記録に使うものだけ残して
# FAKE_* をいったん全部解除する。
while IFS='=' read -r override_fake_var _; do
  case "$override_fake_var" in
    FAKE_DOCKER_CALLS|FAKE_CURL_CALLS|FAKE_AWS_CALLS|FAKE_USAGE_CHECK_CALLS) continue ;;
    FAKE_*) unset "$override_fake_var" ;;
  esac
done < <(env | grep '^FAKE_' || true)

override_compose="$TEST_TMP/override-compose.yml"
cat > "$override_compose" <<'YML'
# 先頭コメント
services:
  base:
    build:
      context: .
      dockerfile: Dockerfile
      secrets:
        - jboss_master_password
    image: j1/base.local

  frontend-web:
    build:
      context: ./web
    # build ブロックの途中のコメント
    ports:
      - "8080:8080"

  api-backend:
    build: ./api

  database:
    image: mysql:8.4

  other:
    build:
      context: ./other
      dockerfile: Dockerfile.other

secrets:
  jboss_master_password:
    environment: JBOSS_MASTER_PASSWORD
YML
override_compose_before="$TEST_TMP/override-compose.before.yml"
cp "$override_compose" "$override_compose_before"

override_output="$TEST_TMP/build-override.out"
override_snapshot="$TEST_TMP/override-effective.yml"
override_report_dir="$TEST_TMP/override-reports"
rm -f "$override_snapshot"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  FAKE_COMPOSE_FILE_SNAPSHOT="$override_snapshot" bash ./build_and_verify.sh \
    --compose-file "$override_compose" \
    --base-context ./base-ctx --base-dockerfile Dockerfile.base \
    --frontend-context ./web-ctx --frontend-dockerfile Dockerfile.front \
    --backend-dockerfile Dockerfile.api \
    --report-dir "$override_report_dir"
) >"$override_output" 2>&1; then
  cat "$override_output" >&2
  fail "build context override returned a non-zero status"
fi

assert_contains "$override_output" "build コンテキスト / Dockerfile の上書きを反映します (対象 3 サービス)。"
assert_contains "$override_output" "base: context '.' -> './base-ctx'"
assert_contains "$override_output" "base: dockerfile 'Dockerfile' -> 'Dockerfile.base'"
assert_contains "$override_output" "frontend-web: context './web' -> './web-ctx'"
assert_contains "$override_output" "frontend-web: dockerfile (未指定) -> 'Dockerfile.front'"
assert_contains "$override_output" "api-backend: dockerfile (未指定) -> 'Dockerfile.api'"
assert_contains "$override_output" "元ファイル (変更していません): ${override_compose}"
# image 指定のみのサービスは、キーワード (base) に一致しても対象にしない
assert_contains "$override_output" "サービス 'database' は build 定義を持たないため、--base-context / --base-dockerfile は適用しません。"
# 対象外のサービスには一切触れない
assert_not_contains "$override_output" "other: context"
assert_not_contains "$override_output" "other: dockerfile"

# 元ファイルは 1 バイトも変わらない
cmp -s "$override_compose" "$override_compose_before" \
  || fail "the original compose file must not be modified by build context override"

# 生成した実効 compose ファイルは処理終了時に消える
for override_leftover in "$TEST_TMP"/.build_and_verify_compose.*.yml; do
  if [ -e "$override_leftover" ]; then
    fail "generated compose file was left behind: $override_leftover"
  fi
done

# compose へ渡ったのは、指定を反映した実効ファイル
[ -s "$override_snapshot" ] || fail "compose did not receive an effective compose file"
assert_contains "$override_snapshot" "context: './base-ctx'"
assert_contains "$override_snapshot" "dockerfile: 'Dockerfile.base'"
assert_contains "$override_snapshot" "context: './web-ctx'"
assert_contains "$override_snapshot" "dockerfile: 'Dockerfile.front'"
assert_contains "$override_snapshot" "dockerfile: 'Dockerfile.api'"
# 短縮形式 "build: ./api" はマッピングへ展開され、元の値が context として残る
assert_contains "$override_snapshot" "context: './api'"
# 上書きしていない定義・対象外サービスはそのまま
assert_contains "$override_snapshot" "dockerfile: Dockerfile.other"
assert_contains "$override_snapshot" "context: ./other"
assert_contains "$override_snapshot" "image: mysql:8.4"
assert_contains "$override_snapshot" "- jboss_master_password"
assert_contains "$override_snapshot" "environment: JBOSS_MASTER_PASSWORD"
assert_contains "$override_snapshot" "# 先頭コメント"
assert_contains "$override_snapshot" "# build ブロックの途中のコメント"
# 差し替え前の値は残らない (残る "context: ." は対象外サービス other の ./other だけ)
assert_occurrences "$override_snapshot" "context: ." 1
assert_not_contains "$override_snapshot" "context: ./web"

# 全量レポートには、何をどう差し替えたのかが残る
collect_report_files "$override_report_dir"
[ ${#REPORT_FILES[@]} -eq 1 ] || fail "expected exactly one report for the build context override run"
override_report="${REPORT_FILES[0]}"
assert_contains "$override_report" "Compose 定義 : ${override_compose} (実効定義: "
assert_contains "$override_report" "ビルド上書き : "
assert_contains "$override_report" "base (--base-*) context=./base-ctx dockerfile=Dockerfile.base"
assert_contains "$override_report" "frontend-web (--frontend-*) context=./web-ctx dockerfile=Dockerfile.front"
assert_contains "$override_report" "api-backend (--backend-*) dockerfile=Dockerfile.api"

# --- 指定が無ければ compose ファイルはそのまま使う (既定の動作) -------------
override_none_output="$TEST_TMP/build-override-none.out"
override_none_snapshot="$TEST_TMP/override-none-effective.yml"
rm -f "$override_none_snapshot"
if ! (
  cd "$REPO_ROOT"
  FAKE_COMPOSE_FILE_SNAPSHOT="$override_none_snapshot" bash ./build_and_verify.sh \
    --compose-file "$override_compose"
) >"$override_none_output" 2>&1; then
  cat "$override_none_output" >&2
  fail "build without context override returned a non-zero status"
fi
assert_not_contains "$override_none_output" "build コンテキスト / Dockerfile の上書きを反映します"
assert_not_contains "$override_none_output" "上書きを反映した compose ファイルを生成しました"
cmp -s "$override_none_snapshot" "$override_compose" \
  || fail "compose should receive the original compose file when no override is given"

# --- キーワードに一致するサービスが無ければエラーで止める -------------------
# 指定が黙って無視されると、意図と違う Dockerfile でできたイメージを
# 「指定どおりのもの」として扱ってしまうため、必ず気付けるようにする。
override_missing_output="$TEST_TMP/build-override-missing.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --frontend-context ./web-ctx
) >"$override_missing_output" 2>&1; then
  cat "$override_missing_output" >&2
  fail "build context override without a matching service unexpectedly returned zero"
fi
assert_contains "$override_missing_output" "--frontend-context / --frontend-dockerfile を指定しましたが、適用できるサービスがありません"
assert_contains "$override_missing_output" "サービス名に 'frontend' を含むサービスがありません。定義されているサービス: base"

# --- 一致したサービスが build 定義を持たない場合もエラーで止める -------------
override_nobuild_compose="$TEST_TMP/override-nobuild.yml"
cat > "$override_nobuild_compose" <<'YML'
services:
  database:
    image: mysql:8.4
YML
override_nobuild_output="$TEST_TMP/build-override-nobuild.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --compose-file "$override_nobuild_compose" --base-context ./base-ctx
) >"$override_nobuild_output" 2>&1; then
  cat "$override_nobuild_output" >&2
  fail "build context override against a service without build unexpectedly returned zero"
fi
assert_contains "$override_nobuild_output" "サービス 'database' は build 定義を持たないため"
assert_contains "$override_nobuild_output" "'base' に一致したサービス (database) は build 定義を持たないため対象外です。"

# --- 複数キーワードに一致し、どちらにも指定がある場合はエラーで止める --------
override_ambiguous_compose="$TEST_TMP/override-ambiguous.yml"
cat > "$override_ambiguous_compose" <<'YML'
services:
  frontend-backend:
    build:
      context: .
      dockerfile: Dockerfile
YML
override_ambiguous_output="$TEST_TMP/build-override-ambiguous.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --compose-file "$override_ambiguous_compose" \
    --frontend-context ./web-ctx --backend-context ./api-ctx
) >"$override_ambiguous_output" 2>&1; then
  cat "$override_ambiguous_output" >&2
  fail "ambiguous build context override unexpectedly returned zero"
fi
assert_contains "$override_ambiguous_output" "サービス 'frontend-backend' が複数のキーワード (frontend, backend) に一致し"
assert_contains "$override_ambiguous_output" "一致するキーワードの指定を 1 つに絞るか、サービス名を見直してください。"

# 片方だけの指定なら、そのまま適用できる
override_single_output="$TEST_TMP/build-override-single.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --compose-file "$override_ambiguous_compose" \
    --frontend-context ./web-ctx
) >"$override_single_output" 2>&1; then
  cat "$override_single_output" >&2
  fail "single-keyword build context override returned a non-zero status"
fi
assert_contains "$override_single_output" "frontend-backend: context '.' -> './web-ctx'"

# --- 空文字は「未指定」と区別が付かないため受け付けない ---------------------
override_empty_output="$TEST_TMP/build-override-empty.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --base-context ""
) >"$override_empty_output" 2>&1; then
  cat "$override_empty_output" >&2
  fail "empty --base-context unexpectedly returned zero"
fi
assert_contains "$override_empty_output" "--base-context には空でない値を指定してください"

# --- dry-run では実効 compose ファイルを作らない ----------------------------
override_dry_output="$TEST_TMP/build-override-dry.out"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --dry-run --base-context ./dry-ctx --base-dockerfile Dockerfile.dry
) >"$override_dry_output" 2>&1; then
  cat "$override_dry_output" >&2
  fail "dry-run build context override returned a non-zero status"
fi
assert_contains "$override_dry_output" "base: context '.' -> './dry-ctx'"
assert_contains "$override_dry_output" "base: dockerfile 'Dockerfile' -> 'Dockerfile.dry'"
assert_contains "$override_dry_output" "[DRY-RUN] 実効 compose ファイルの生成をスキップします"
assert_contains "$override_dry_output" "[DRY-RUN] docker compose -f compose.yml build"
for override_leftover in "$REPO_ROOT"/.build_and_verify_compose.*.yml; do
  if [ -e "$override_leftover" ]; then
    fail "dry-run must not generate an effective compose file: $override_leftover"
  fi
done


# ---- --keep-service (no-cache 除外 / イメージ・ボリュームの保護) -------------
# --keep-service で指定したサービスについて、次の 3 つを確認する。
#   - --no-cache を指定しても、そのサービスだけはキャッシュを使ってビルドすること
#   - 後始末でイメージをローカルに残すこと
#   - 後始末で名前付きボリュームを残すこと
#   - 指定していないサービスは、これまでどおり no-cache でビルドし、削除すること
# 直前までのシナリオが export したフィクスチャ設定を引きずらないよう、
# 呼び出し記録に使うものだけ残して FAKE_* をいったん全部解除する。
while IFS='=' read -r keep_fake_var _; do
  case "$keep_fake_var" in
    FAKE_DOCKER_CALLS|FAKE_CURL_CALLS|FAKE_AWS_CALLS|FAKE_USAGE_CHECK_CALLS) continue ;;
    FAKE_*) unset "$keep_fake_var" ;;
  esac
done < <(env | grep '^FAKE_' || true)

keep_compose="$TEST_TMP/keep-service-compose.yml"
cat > "$keep_compose" <<'YML'
services:
  base:
    build:
      context: .
      dockerfile: Dockerfile
    image: j1/base.local
  app:
    build:
      context: ./app
    volumes:
      - app-logs:/var/log
      - ./conf:/etc/app:ro
  db:
    build:
      context: ./db
    volumes:
      - type: volume
        source: db-data
        target: /var/lib/mysql
volumes:
  app-logs:
  db-data:
YML

# --- (1) --no-cache は保護対象を除いて適用する -------------------------------
keep_nocache_output="$TEST_TMP/keep-service-nocache.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh \
    --compose-file "$keep_compose" \
    --no-cache \
    --keep-service db
) >"$keep_nocache_output" 2>&1; then
  cat "$keep_nocache_output" >&2
  fail "--keep-service with --no-cache returned a non-zero status"
fi
assert_contains "$keep_nocache_output" "--keep-service で保護するサービス: db"
assert_contains "$keep_nocache_output" "--keep-service で指定したサービスは --no-cache の対象外です: db"
assert_contains "$keep_nocache_output" "キャッシュを破棄してビルド (--no-cache): base app"
assert_contains "$keep_nocache_output" "キャッシュを使ってビルド (--keep-service で no-cache から除外): db"
# compose build は 2 回に分かれ、保護対象には --no-cache が付かない
assert_contains "$FAKE_DOCKER_CALLS" "build --no-cache base app"
assert_contains "$FAKE_DOCKER_CALLS" "${keep_compose} build db"
assert_not_contains "$FAKE_DOCKER_CALLS" "build --no-cache base app db"
assert_not_contains "$FAKE_DOCKER_CALLS" "build --no-cache db"

# --- (2) --keep-service が無ければ従来どおり 1 回のビルド --------------------
keep_none_output="$TEST_TMP/keep-service-none.out"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --compose-file "$keep_compose" --no-cache
) >"$keep_none_output" 2>&1; then
  cat "$keep_none_output" >&2
  fail "--no-cache without --keep-service returned a non-zero status"
fi
assert_not_contains "$keep_none_output" "--keep-service"
assert_contains "$FAKE_DOCKER_CALLS" "${keep_compose} build --no-cache"
assert_occurrences "$FAKE_DOCKER_CALLS" " build " 1

# --- (3) compose ファイルに無いサービス名はエラーで止める --------------------
# 取り違えたまま進むと、残すつもりだったボリュームの中身が消える。
keep_unknown_output="$TEST_TMP/keep-service-unknown.out"
if (
  cd "$REPO_ROOT"
  bash ./build_and_verify.sh --compose-file "$keep_compose" --keep-service dbb
) >"$keep_unknown_output" 2>&1; then
  cat "$keep_unknown_output" >&2
  fail "--keep-service with an unknown service unexpectedly returned zero"
fi
assert_contains "$keep_unknown_output" "--keep-service 'dbb' が compose ファイルにありません"
assert_contains "$keep_unknown_output" "定義されているサービス: base app db"
assert_contains "$keep_unknown_output" "保護するつもりのサービスを取り違えると、イメージとボリュームが消えます。"

# --- (4) 旧世代イメージの回収は、保護対象のイメージでは行わない --------------
keep_reclaim_image_id="$TEST_TMP/keep-service-image-id"
keep_reclaim_output="$TEST_TMP/keep-service-reclaim.out"
printf 'sha256:before-keep\n' > "$keep_reclaim_image_id"
if ! (
  cd "$REPO_ROOT"
  FAKE_DOCKER_IMAGE_ID_FILE="$keep_reclaim_image_id" \
  FAKE_DOCKER_IMAGE_ID_AFTER_BUILD="sha256:after-keep" \
  bash ./build_and_verify.sh --compose-file "$keep_compose" --keep-service base
) >"$keep_reclaim_output" 2>&1; then
  cat "$keep_reclaim_output" >&2
  fail "--keep-service base returned a non-zero status"
fi
assert_contains "$keep_reclaim_output" "ローカルイメージは --keep-service の保護対象のため、旧世代の回収は行いません: j1/base.local"
assert_not_contains "$keep_reclaim_output" "世代交代した旧イメージを削除します"

# 保護対象でなければ従来どおり回収する
keep_reclaim_other_output="$TEST_TMP/keep-service-reclaim-other.out"
printf 'sha256:before-keep\n' > "$keep_reclaim_image_id"
if ! (
  cd "$REPO_ROOT"
  FAKE_DOCKER_IMAGE_ID_FILE="$keep_reclaim_image_id" \
  FAKE_DOCKER_IMAGE_ID_AFTER_BUILD="sha256:after-keep" \
  bash ./build_and_verify.sh --compose-file "$keep_compose" --keep-service db
) >"$keep_reclaim_other_output" 2>&1; then
  cat "$keep_reclaim_other_output" >&2
  fail "--keep-service db returned a non-zero status"
fi
assert_contains "$keep_reclaim_other_output" "世代交代した旧イメージを削除します: sha256:before-keep"

# --- (5) compose down のボリューム削除から保護対象を外す ---------------------
keep_volume_output="$TEST_TMP/keep-service-volume.out"
keep_volume_removed="$TEST_TMP/keep-service-volume-removed"
rm -f "$keep_volume_removed"
: > "$FAKE_DOCKER_CALLS"
if ! (
  cd "$REPO_ROOT"
  FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log" \
  FAKE_COMPOSE_PS_SERVICES="app" \
  FAKE_COMPOSE_PROJECT_NAME="testproj" \
  FAKE_DOCKER_PROJECT_VOLUMES="testproj_app-logs testproj_db-data" \
  FAKE_DOCKER_VOLUME_LABELS="testproj_app-logs=app-logs testproj_db-data=db-data" \
  FAKE_DOCKER_VOLUME_RM_FILE="$keep_volume_removed" \
  bash ./build_and_verify.sh \
    --compose-file "$keep_compose" \
    --compose-service app --startup-service app --verify-startup \
    --keep-service db \
    --remove-volumes \
    --suppress-startup-logs --suppress-removed-logs \
    --env-list-limit 1 --directory-tree-depth 1
) >"$keep_volume_output" 2>&1; then
  cat "$keep_volume_output" >&2
  fail "--keep-service volume protection returned a non-zero status"
fi
assert_contains "$keep_volume_output" "ボリュームは --keep-service の保護対象を除いて、この後で個別に削除します。"
assert_contains "$keep_volume_output" "残すボリューム (--keep-service): testproj_db-data"
assert_contains "$keep_volume_output" "Compose ボリュームを削除します (1 件): testproj_app-logs"
# compose down --volumes は使わない (プロジェクトのボリュームを一括で消すため)
assert_not_contains "$FAKE_DOCKER_CALLS" "down -t 30 --volumes"
[ -s "$keep_volume_removed" ] || fail "expected the unprotected volume to be removed"
assert_contains "$keep_volume_removed" "testproj_app-logs"
assert_not_contains "$keep_volume_removed" "testproj_db-data"

# --- (6) --cleanup-all-docker-data でも保護対象を残す ------------------------
keep_cleanup_output="$TEST_TMP/keep-service-cleanup-all.out"
keep_cleanup_images="$TEST_TMP/keep-service-cleanup-images"
keep_cleanup_volumes="$TEST_TMP/keep-service-cleanup-volumes"
rm -f "$keep_cleanup_images" "$keep_cleanup_volumes"
if ! (
  cd "$REPO_ROOT"
  printf 'DELETE ALL DOCKER DATA\n' | \
  FAKE_COMPOSE_PROJECT_NAME="testproj" \
  FAKE_DOCKER_IMAGES="sha256:test-image sha256:image-two sha256:image-three" \
  FAKE_DOCKER_VOLUMES="testproj_app-logs testproj_db-data other-volume" \
  FAKE_DOCKER_VOLUME_LABELS="testproj_app-logs=app-logs testproj_db-data=db-data" \
  FAKE_DOCKER_IMAGE_RM_FILE="$keep_cleanup_images" \
  FAKE_DOCKER_VOLUME_RM_FILE="$keep_cleanup_volumes" \
  FAKE_DOCKER_CLEANED="$TEST_TMP/keep-service-cleaned-marker" \
  bash ./build_and_verify.sh \
    --compose-file "$keep_compose" \
    --keep-service db \
    --cleanup-all-docker-data
) >"$keep_cleanup_output" 2>&1; then
  cat "$keep_cleanup_output" >&2
  fail "--keep-service with --cleanup-all-docker-data returned a non-zero status"
fi
assert_contains "$keep_cleanup_output" "残すもの (--keep-service db):"
assert_contains "$keep_cleanup_output" "--keep-service の保護対象を除く全ローカルイメージを削除します"
assert_contains "$keep_cleanup_output" "--keep-service の保護対象を除く全ローカルボリュームを削除します"
assert_contains "$keep_cleanup_output" "残すボリューム (--keep-service): testproj_db-data"
# 保護対象まで消す prune は使わない (ログの接頭辞込みで、保護版の行と区別する)
assert_not_contains "$keep_cleanup_output" "] 全ローカルイメージを削除します"
assert_not_contains "$keep_cleanup_output" "] 全ローカルボリュームと永続データを削除します"
assert_not_contains "$FAKE_DOCKER_CALLS" "image prune --all --force"
assert_not_contains "$FAKE_DOCKER_CALLS" "volume prune --all --force"
assert_not_contains "$FAKE_DOCKER_CALLS" "system prune --all --volumes --force"
assert_contains "$keep_cleanup_output" "Docker の未使用データを最終確認・削除します (保護対象は残す)"
# 保護対象は削除対象から外れている
assert_contains "$keep_cleanup_images" "sha256:image-two"
assert_contains "$keep_cleanup_images" "sha256:image-three"
assert_not_contains "$keep_cleanup_images" "sha256:test-image"
assert_contains "$keep_cleanup_volumes" "testproj_app-logs"
assert_contains "$keep_cleanup_volumes" "other-volume"
assert_not_contains "$keep_cleanup_volumes" "testproj_db-data"

# --- (7) 対話操作後の完全クリアは、保護できないため行わない ------------------
keep_post_output="$TEST_TMP/keep-service-post-interaction.out"
: > "$FAKE_USAGE_CHECK_CALLS"
if ! printf '0\n' | (
  cd "$REPO_ROOT"
  FAKE_COMPOSE_LOG_FILE="$TEST_DIR/fixtures/jboss-eap-8.1-success.log" \
  FAKE_COMPOSE_PS_SERVICES="app" \
  FAKE_COMPOSE_PROJECT_NAME="testproj" \
  FAKE_DOCKER_PROJECT_VOLUMES="testproj_app-logs testproj_db-data" \
  FAKE_DOCKER_VOLUME_LABELS="testproj_app-logs=app-logs testproj_db-data=db-data" \
  bash ./build_and_verify.sh \
    --compose-file "$keep_compose" \
    --compose-service app --startup-service app --verify-startup \
    --keep-container-mode logs \
    --keep-service db \
    --suppress-startup-logs --suppress-removed-logs \
    --env-list-limit 1 --directory-tree-depth 1
) >"$keep_post_output" 2>&1; then
  cat "$keep_post_output" >&2
  fail "--keep-service with the logs interaction returned a non-zero status"
fi
assert_contains "$keep_post_output" "--keep-service を指定しているため、未使用リソースの完全クリアは行いません。"
assert_contains "$keep_post_output" "保護対象: サービス: db / イメージ: "
assert_contains "$keep_post_output" "完全クリアまで行う場合は --keep-service を外して実行してください。"
assert_not_contains "$keep_post_output" "未使用リソースを含めて完全クリアします。"
[ ! -s "$FAKE_USAGE_CHECK_CALLS" ] \
  || fail "docker-usage-check.sh must not run while --keep-service is in effect"

printf 'PASS: build_and_verify.sh startup/companion log display, tree rendering/pruning, interaction, full report, JBoss master password propagation, Undertow virtual host (default-host) analysis, cwagent CloudWatch Logs delivery verification, WAR deploy Java exception analysis, --copy-file overwrite/restore, disk usage reclaim/prune/report, build stall detection/progress/timeout, cert check received-certificate detail (root CA / v1 / leaf classification) and result text output, cert check chain diagnosis, Docker cleanup scenarios, build context/Dockerfile override, and --keep-service no-cache exclusion / image / volume protection\n'
