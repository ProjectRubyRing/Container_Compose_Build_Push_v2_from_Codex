#!/usr/bin/env bash
#
# build_and_verify.sh
# -----------------------------------------------------------------------------
# 想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。
#
# build_and_push.sh の「ビルドのみ実行する処理」を切り出した専用スクリプト。
# compose.yml で定義したローカルベースイメージ (既定: j1/base.local) を
# docker compose build でビルドする。ECR ログイン/タグ付け/プッシュ/
# imagedefinition.json の出力は一切行わない。
#
# ビルドに加えて、以下の確認・診断を任意で行える:
#   (1) --verify-startup : ビルドしたイメージをコンテナとして起動し、
#                          jbosseap (WildFly/JBoss EAP) サーバーの起動完了を
#                          ログから確認し、起動ログと重要ログの色分けを表示する。
#   (2) --verify-url URL : 起動確認後、指定 URL へ HTTP リクエストを送り、
#                          その応答 (ステータスコード/本文) を確認する。
#   (3) Compose サービスログ: 起動確認対象と同時に起動した他サービスのログを、
#                          起動ログの直後へサービス単位で順次表示する。
#   (4) ディレクトリツリー表示: 動作確認したコンテナのディレクトリを階層表示する。
#                          通常ファイルはオプション指定時のみ出力する。
#   (5) デプロイ構造表示    : JBoss デプロイ先、Web ルート、Java クラスパスルート、
#                          指定環境変数のディレクトリを検出して階層表示する。
#   (6) JVM パラメータ表示  : コンテナ内の Java プロセスを検出し、起動時の JVM
#                          パラメータをヒープ・GC・エージェント・システム
#                          プロパティ等へ分類して表示する。
#   (7) OpenTelemetry 表示  : OTEL_* をはじめとする OpenTelemetry 関連の環境変数と
#                          JVM パラメータを 1 つの一覧にまとめて表示する。
#   (8) 全量レポート        : ビルド結果と全量の環境変数・ツリー・デプロイ構造・
#                          JVM パラメータ・OpenTelemetry 設定を日時付きテキスト
#                          ファイルへ保存する。
#   (9) --keep-container-mode: 起動確認後もコンテナを残し、検証対象へ直接
#                          bash 接続するか、対話式の HTTP リクエスト、または
#                          起動中 Compose サービスのログ閲覧・bash / MySQL 接続、
#                          healthcheck 設定・実行履歴・HTTP 通信、
#                          cwagent / OTel のローカル送達診断、および
#                          JVM トラストストアを持つコンテナ (front / back 等) の
#                          証明書チェック (自己証明書による HTTPS 接続確認) を
#                          実行する。
#  (10) CloudWatch Logs 送信検証:
#                          compose.yml に cwagent (CloudWatch Agent サイドカー) が
#                          定義されている場合、ビルド前に設定ファイルを静的に
#                          チェックし (注入経路・収集定義・送信先の名前解決・
#                          収集対象のマウント・リージョン/認証)、起動確認後に
#                          設定済みロググループ / ログストリームへ実際にログが
#                          届いたかを確認する。
#  (11) 終了 (SIGTERM) ログ : エラー終了時は、ECS のタスク停止と同じく SIGTERM で
#                          コンテナを終了させてから最終ログを取得する。これにより
#                          adot collector などサイドカーの graceful shutdown ログ
#                          (シグナル受信 → パイプライン停止 → 終了) まで、画面と
#                          全量レポートの双方へ残る。
#  (12) Java 例外解析      : WAR のデプロイ処理で Java の例外が投げられた場合、
#                          スタックトレースと Caused by の連鎖から根本原因の
#                          例外クラスを特定し、発生の仕組み・想定される原因・
#                          確認手順・対処方法・再発防止を生成して表示する。
#                          解析結果は全量レポートへ保存するほか、Excel ブック
#                          (build_and_verify_<日時>_java_exceptions.xlsx) と、
#                          同じ内容のテキスト (同 _java_exceptions.txt) として
#                          も出力する。ブックは 概要 / 例外一覧 / 原因分析 /
#                          対処方法 / スタックトレース / デプロイログ の 6 シート
#                          構成で、フォントは Meiryo UI、行高は内容と列幅から
#                          計算して明示するため、折り返した本文が切れない。
#  (13) デプロイエラー時の調査:
#                          AP サーバ (JBoss EAP 等) は起動したが、アプリのデプロイで
#                          エラーとなった場合、既定ではコンテナと AP サーバを起動した
#                          まま残し、デプロイ成功後と同じ対話操作を開始して、各
#                          Compose サービスへの bash 接続やログ確認を行える状態にする。
#                          --exit-on-deploy-error 指定時は、従来どおりログを出力して
#                          そのまま終了する。
#
# --verify-startup / --verify-url いずれも指定しなければ、純粋にビルドのみを
# 行って終了する (従来の build_and_push.sh --build-only 相当)。
#
# JBoss マスターパスワード (BuildKit シークレット):
#   - ビルド前に、パラメータストアの指定キー (--jboss-password-param) から
#     JBoss のマスターパスワードを取得できる (直接指定 --jboss-password も可)。
#   - 取得した値は環境変数 (--jboss-password-env, 既定: JBOSS_MASTER_PASSWORD)
#     へ export し、compose.yml の environment 型シークレット定義を通じて
#     BuildKit シークレットとして安全にビルドへ注入する。
#   - パラメータストアを使う場合のみ AWS 認証 (aws login --remote 実施済み) が
#     必要で、未認証の場合は認証を促す警告を表示して終了する。
#
# 使い方:
#   # ビルドのみ
#   ./build_and_verify.sh
#
#   # ビルド + jbosseap 起動確認
#   ./build_and_verify.sh --verify-startup
#
#   # ビルド + 起動確認 + URL 応答確認 (例: ヘルスチェックエンドポイント)
#   ./build_and_verify.sh --verify-startup \
#       --verify-url http://localhost:8080/health --expect-status 200
#
#   # base を先行ビルド後、複数サービスを同時にビルド・起動し、
#   # app サービスのみ起動確認する
#   ./build_and_verify.sh --compose-service app --compose-service db \
#       --startup-service app
#   # (カンマ区切りでも指定可: --compose-service app,db)
# -----------------------------------------------------------------------------

set -uo pipefail

# ---- 表示タイムゾーン (JST 固定) --------------------------------------------
# ホストや CI が UTC でも、このスクリプトが表示・保存する時刻はすべて JST に揃える。
# tzdata を持たない環境でも +09:00 になるよう、Asia/Tokyo が使えない場合は tzdata
# 不要の POSIX 形式 (JST-9) へフォールバックする。日本標準時は夏時間を持たないため
# 固定オフセットでも Asia/Tokyo と同じ結果になる。
# 時刻表示へ付ける名前は %Z が空になる環境があるため、この変数から明示的に付ける。
DISPLAY_TZ_LABEL='JST'
setup_display_timezone() {
  local tz_candidate
  for tz_candidate in 'Asia/Tokyo' 'JST-9'; do
    if [ "$(TZ="$tz_candidate" date '+%z' 2>/dev/null)" = "+0900" ]; then
      export TZ="$tz_candidate"
      return 0
    fi
  done
  DISPLAY_TZ_LABEL="$(date '+%Z' 2>/dev/null)"
  [ -n "$DISPLAY_TZ_LABEL" ] || DISPLAY_TZ_LABEL="ローカル時刻"
  return 1
}
if ! setup_display_timezone; then
  # ログ用ヘルパはまだ定義前のため、ここだけ printf で警告する。
  printf '[%s %s] [WARN] JST へ切り替えられないため、ホストのタイムゾーンで表示します。\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$DISPLAY_TZ_LABEL" >&2
fi

# ---- 既定値 -----------------------------------------------------------------
RUN_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S') ${DISPLAY_TZ_LABEL}"
RUN_TIMESTAMP="$(date '+%Y%m%d%H%M%S')"
# CloudWatch Logs のイベント時刻は UTC のエポックミリ秒のため、今回の実行で送られた
# イベントだけを数えられるよう、開始時刻をミリ秒で保持しておく。
RUN_STARTED_EPOCH_MS="$(( $(date '+%s') * 1000 ))"
LOCAL_IMAGE="j1/base.local"       # compose build で生成されるローカルベースイメージ名
COMPOSE_FILE="compose.yml"
COMPOSE_SERVICES=()               # 指定時はそのサービスのみビルド/起動 (複数指定可、空なら全サービス)
BASE_SERVICE="base"              # 複数サービス指定時に必ず先行ビルドするベースサービス名
NO_CACHE="false"                  # true: キャッシュを破棄してビルド (--no-cache)
DRY_RUN="false"                   # true: 実際の変更は行わず、実行内容のプレビューのみ表示
CLEANUP_ALL_DOCKER_DATA="false"   # true: 終了時に確認後、現在の Docker context の全データを削除
DOCKER_CLEANUP_CONFIRM_PHRASE="DELETE ALL DOCKER DATA"

# ---- ディスク使用量の抑制 ---------------------------------------------------
# compose build はローカルイメージ名のタグを新しいイメージへ付け替えるだけで、
# 直前の世代はタグを失った <none>:<none> (dangling) として残り続ける。
# --no-cache では全レイヤが作り直され、直前世代と共有するレイヤが 1 つも無いため、
# 実行のたびにイメージ 1 個分がそのまま積み上がる。既定で回収する。
# docker image prune と違い、今回のビルドで世代交代した ID だけを削除するため、
# 同じ Docker daemon を使う他プロジェクトの dangling イメージには影響しない。
RECLAIM_OLD_IMAGE="true"          # false (--no-reclaim-old-image): 旧世代を残す
PREVIOUS_IMAGE_ID=""              # ビルド前の $LOCAL_IMAGE の image ID
# BuildKit のビルドキャッシュ。--no-cache は「既存のキャッシュを読まない」指定で
# あって「書かない」指定ではないため、実行のたびに全レイヤ分のキャッシュが増える。
PRUNE_BUILD_CACHE="false"         # true: 終了時にビルドキャッシュを削除する
PRUNE_BUILD_CACHE_KEEP=""         # 空: 全削除 / "10GB" 等: その量まで残す
DISK_USAGE_REPORT="false"         # true: Docker 管理対象の使用量と増減を表示する
DISK_USAGE_BEFORE=""              # 最初に測定した使用量 (bytes)。増減の基準にする
DISK_USAGE_REPORTED="false"       # 終了時レポートの二重実行を防ぐ

# ---- ビルドの停滞検知・進捗表示 ---------------------------------------------
# BuildKit の "exporting to image" / "exporting layers" は、ビルドしたレイヤを
# Docker のイメージストアへ書き出す段。--progress=plain では開始の 1 行を出した
# あと、完了するまで追加の出力が一切出ない。ベースイメージのように 1 レイヤが
# 大きいとこの段だけで数分〜数十分かかることがあり、画面が止まったまま
# プロンプトが戻らないように見える (実際には書き出しが進んでいることが多い)。
# 「遅いだけなのか、本当に停止しているのか」を画面から判断できるよう、
#   (1) 一定間隔で経過時間・BuildKit のフェーズ・data root の空き容量の増減を出す
#   (2) 出力が一定時間途切れたら停滞と判断し、原因を切り分ける診断を出す
#   (3) 上限時間を超えたらビルドを中断してプロンプトを返す
# の 3 段構えで監視する。(1)(2) は既定で有効、(3) は明示指定時のみ。
BUILD_WATCHDOG="true"             # false (--no-build-watchdog): 監視を一切行わない
BUILD_PROGRESS_INTERVAL="30"      # 進捗を表示する間隔 (秒)。0 で進捗表示を行わない
BUILD_STALL_TIMEOUT="300"         # 出力が途切れてから停滞と判断するまでの秒数。0 で無効
BUILD_TIMEOUT="0"                 # ビルド全体の上限秒数。0 (既定) は無制限
BUILD_TIMEOUT_KILL_GRACE="20"     # 上限超過時、SIGTERM から SIGKILL までの猶予秒数
BUILD_WATCHDOG_TICK="5"           # 監視ループの点検間隔 (秒)。判定の時間分解能になる
BUILD_WATCHDOG_READ_TIMEOUT="2"   # ビルド出力の読み取り待ち上限 (秒)。中断指示への反応間隔
# data root の空きがこの値未満でビルドを始めると、exporting layers の途中で
# 容量が尽きて停滞・失敗しやすい。開始前に警告して気付けるようにする。
BUILD_MIN_FREE_GIB="5"            # 開始前に警告する data root 空き容量のしきい値 (GiB)
BUILD_WATCHDOG_DIR=""             # 監視用の一時ディレクトリ (EXIT で削除)
BUILD_WATCHDOG_SUMMARY=""         # 全量レポートへ載せる監視結果
BUILD_WATCHDOG_DATA_ROOT=""       # docker data root (ローカル接続時のみ特定できる)
BUILD_WATCHDOG_DATA_ROOT_RESOLVED="false"
BUILD_TIMED_OUT="false"           # 上限時間で中断したか

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"  # パラメータストア参照時に使用

# JBoss マスターパスワード (BuildKit シークレット) 関連
JBOSS_PASSWORD_PARAM=""           # パラメータストアのキー名 (--jboss-password-param)
JBOSS_PASSWORD_VALUE=""           # 直接指定されたマスターパスワード (--jboss-password)
JBOSS_PASSWORD_ENV="JBOSS_MASTER_PASSWORD"  # シークレット受け渡しに使う環境変数名
JBOSS_PASSWORD_ENV_SET="false"    # --jboss-password-env が明示指定されたか
JBOSS_SECRET_ENABLED="false"      # マスターパスワードをビルドシークレットとして注入するか
JBOSS_SECRET_ID="jboss_master_password"  # BuildKit シークレットの id。compose.yml の
                                  # secrets 名および Dockerfile の
                                  # RUN --mount=type=secret,id=... と一致させる。
                                  # 伝搬検証のプローブビルドで参照する。

# ---- JBoss マスターパスワードの伝搬検証 (--verify-jboss-password) ------------
# 「compose.yml の環境変数 → BuildKit シークレット → Elytron CredentialStore →
#  jboss-cli が生成した standalone.xml → 実行時に解決される値」の各段で、
# パスワード文字列が原本と一致しているかを突き合わせる。
# $ # " ` \ 等はシェル・XML・WildFly 式のいずれかで意味を持つため、
# 段のどこかで欠落・展開・二重エスケープされていても気付けるようにする。
VERIFY_JBOSS_PASSWORD="false"     # true: 伝搬検証を実行する
JBOSS_PASSWORD_SHOW="true"        # false: 平文表示を伏字にする (--jboss-password-mask)
JBOSS_CONFIG_FILE=""              # コンテナ内 standalone.xml のパス (未指定は自動探索)
JBOSS_CLI_PATH=""                 # コンテナ内 jboss-cli.sh のパス (未指定は自動探索)
JBOSS_ELYTRON_TOOL_PATH=""        # コンテナ内 elytron-tool.sh のパス (未指定は自動探索)
JBOSS_CREDENTIAL_STORE_FILE=""    # コンテナ内 CredentialStore ファイル (未指定は XML から特定)
JBOSS_PASSWORD_ORIGIN=""          # 取得元から読み出した原本パスワード (比較の基準)
JBOSS_PASSWORD_ORIGIN_SET="false" # 原本を取得できたか
JBOSS_PASSWORD_SOURCE_LABEL=""    # 取得元の説明 (画面表示用)
JBOSS_PASSWORD_STAGE_RESULTS=()   # 段ごとの検証結果 (画面表示・全量レポート共通)
JBOSS_PASSWORD_MISMATCH="false"   # 1 段でも不一致を検出したか
JBOSS_PASSWORD_UNKNOWN="false"    # 1 段でも確認できなかったか
# 段の記録に使う区切り。パスワードにも説明文にも現れない制御文字を使う。
JBOSS_STAGE_SEPARATOR=$'\037'
# コンテナ内で JBoss のインストール先を探す既定の候補。
# JBOSS_HOME / JBOSS_EAP_HOME が設定されていればそちらを優先する。
JBOSS_HOME_CANDIDATES=(
  /opt/jboss-eap
  /opt/eap
  /opt/jboss/jboss-eap
  /opt/jboss
  /opt/wildfly
  /usr/local/jboss-eap
  /usr/local/wildfly
)

# ビルド前に一時コピーし、ビルド後に自動削除するファイル群
# COPY_SPECS: "SRC:DEST_DIR" の配列 (--copy-file で繰り返し指定)
# COPIED_FILES: 実際にコピーしたコピー先ファイルパス (削除対象として記録)
# COPIED_BACKUPS: 上書き前の既存ファイルの退避先パス (COPIED_FILES と同じ添字)。
#                 退避していない要素は空文字。処理終了時に削除ではなく復元する。
COPY_SPECS=()
COPIED_FILES=()
COPIED_BACKUPS=()
# コピー先に同名ファイルが既に存在する場合の動作
#   true  (既定)                    : 強制上書きする (元ファイルは退避し、処理終了時に復元)
#   false (--copy-file-no-overwrite): 上書きせず処理を中止する
COPY_OVERWRITE="true"
COPY_BACKUP_DIR=""                # 上書き前ファイルの退避先 (初回の上書き時に作成)
# 退避したことを示す dry-run 用のマーカー (dry-run では実ファイルを退避しないため)
COPY_BACKUP_DRY_RUN_MARK="(dry-run)"

# ---- 起動確認 (jbosseap) 関連 ----------------------------------------------
VERIFY_STARTUP="false"            # true: ビルド後にコンテナを起動し起動完了を確認
STARTUP_SERVICES=()               # 起動完了チェックの対象サービス (複数指定可)。
                                  # 空なら対象サービス全体のログをまとめて確認する。
# 起動完了とみなすログのパターン (拡張正規表現)。
# JBoss EAP 8.1 では WFLYSRV0025 が正常起動、WFLYSRV0026 はエラー付き起動を表す。
# 両者を成功扱いしないよう、正常系と異常系を明確に分離する。
STARTUP_LOG_PATTERN='WFLYSRV0025:'
STARTUP_FAILURE_LOG_PATTERN='WFLYSRV0026:|WFLYSRV0056:'
STARTUP_TIMEOUT="120"             # 起動完了を待つ最大秒数
STARTUP_INTERVAL="3"              # 起動確認ポーリング間隔 (秒)
# compose up に --wait を付け、依存サービスが healthy (healthcheck 未定義なら running)
# になるまで compose 側で待機させる。compose.yml の healthcheck 整備が前提。
STARTUP_WAIT="false"
STARTUP_WAIT_TIMEOUT="600"        # --wait の最大待機秒数
# 起動確認中に停止していても失敗扱いにしないサービス (初期化専用の短命サービス等)
ALLOW_SERVICE_EXIT=()
KEEP_CONTAINER="false"            # true: 確認後もコンテナを停止・削除せずに残す
KEEP_CONTAINER_MODE=""            # bash/http/logs: 確認後に実行する対話操作 (指定時はコンテナを残す)
# デプロイエラー (AP サーバ自体は起動したが、アプリのデプロイに失敗した状態) を
# 検出した場合の動作。
#   true  (既定)                  : コンテナと AP サーバを起動したまま、調査用の
#                                   対話操作 (成功時と同じ操作) へ入る
#   false (--exit-on-deploy-error): 従来どおりログを出力してそのまま終了する
KEEP_CONTAINER_ON_DEPLOY_ERROR="true"
# デプロイエラー時に開始する対話操作。--keep-container-mode 指定時はその指定を使う。
# 既定の logs は「各 Compose サービスを選んで bash 接続・ログ確認」を行うモード。
DEPLOY_ERROR_INTERACTION_MODE="logs"
STARTUP_DEPLOY_ERROR="false"      # 起動確認でデプロイエラー (起動失敗ログ) を検出したか
INTERACTION_MENU_ENTERED="false"  # 対話操作の選択を 1 度でも読み取れたか (調査に入れたか)
SUPPRESS_REMOVED_LOGS="false"     # true: compose down の Removed ログ等を抑制する
SUPPRESS_STARTUP_LOGS="false"     # true: 起動確認対象と同時起動サービスのログ表示を抑制する
STARTUP_LOG_LINES="50"            # all: 全行表示 / 数値: 末尾からの最大表示行数
# エラー終了時に、削除 (compose down) の前へ SIGTERM による停止 (compose stop) を
# 挟み、コンテナの終了処理が出すログまで取得するか。ECS はタスク停止時に各
# コンテナへ SIGTERM を送るため、ローカル検証でも同じ終了ログを残せるようにする。
CAPTURE_SHUTDOWN_LOGS="true"
SHUTDOWN_LOG_TIMEOUT="30"         # SIGTERM 後に SIGKILL するまでの猶予秒数 (ECS 既定と同じ)
SHUTDOWN_LOGS_CAPTURED="false"    # 終了ログの取得を試行済みか (二重実行の防止)
SHUTDOWN_STOP_EXECUTED="false"    # 実際に SIGTERM で停止したか (レポートの記載条件)
# EAP 8.1 の起動、ドライバー、データソース、リスナー、デプロイ、終了状態を
# 重要ログとして色分けする。
STARTUP_IMPORTANT_LOG_PATTERN='WFLYSRV0049|WFLYJCA0009|WFLYJCA0018|WFLYJCA0001|WFLYJCA0098|WFLYDS0013|WFLYSRV0027|WFLYSRV0207|WFLYUT0006|WFLYUT0021|WFLYSRV0010|WFLYSRV0051|WFLYSRV0060|WFLYSRV0025|WFLYSRV0026|WFLYSRV0056'
# 起動完了、ドライバー、データソース、HTTP リスナー、デプロイ完了は成功色で表示する。
STARTUP_SUCCESS_LOG_PATTERN='WFLYJCA0018|WFLYJCA0001|WFLYJCA0098|WFLYUT0006|WFLYUT0021|WFLYSRV0010|WFLYSRV0025'

# ---- URL 応答確認 関連 ------------------------------------------------------
VERIFY_URL=""                     # 空でなければ起動確認後にこの URL を呼び出して確認
EXPECT_STATUS="200"               # 期待する HTTP ステータスコード
URL_METHOD="GET"                  # HTTP メソッド
URL_CONTENT_TYPE=""               # Content-Type ヘッダ値 (未指定時は curl 既定)
URL_BODY_JSON=""                  # JSON 文字列をリクエストボディとして送る
URL_BODY_FORM=""                  # form 文字列 (key=value&...) をリクエストボディとして送る
URL_TIMEOUT="60"                  # URL 応答待機と HTTP / healthcheck 診断の最大秒数
URL_INTERVAL="3"                  # URL 呼び出しリトライ間隔 (秒)
URL_INSECURE="false"             # true: TLS 証明書検証を無効化して呼び出す (curl -k)

# ---- 起動維持後の対話操作 関連 ----------------------------------------------
JBOSS_CONTEXT_ROOT=""             # HTTP モードで使うコンテキストルート (空ならログから検出)
JBOSS_HTTP_PORT=""                # JBoss EAP のコンテナ側 HTTP ポート (空ならログから検出)
INTERACTION_CONTAINER_ID=""
INTERACTION_SERVICE_NAME=""
INTERACTION_CONTAINER_NAME=""
INTERACTION_CONTEXT_ROOT=""
INTERACTION_CONTAINER_PORT=""
INTERACTION_HTTP_HOST=""
INTERACTION_HTTP_PORT=""
INTERACTIVE_HTTP_BODY_FILE=""
HEALTHCHECK_DIAGNOSTIC_FILE=""
HTTP_REQUEST_METHOD=""
HTTP_REQUEST_PATH=""
HTTP_REQUEST_BODY=""
HTTP_REQUEST_CONTENT_TYPE=""
OBSERVABILITY_HTTP_HOST=""
OBSERVABILITY_HTTP_PORT=""
OBSERVABILITY_HTTP_BASE_URL=""
OBSERVABILITY_CONTAINER_NAME=""
OBSERVABILITY_PYTHON=""
OBSERVABILITY_WIREMOCK_REQUEST_LIMIT="100"
OBSERVABILITY_EVENT_DISPLAY_LIMIT="20"
OBSERVABILITY_TRACE_LIMIT="5"
# OTel Collector の health_check 拡張が待ち受ける既定ポート。コンテナ内で
# healthcheck コマンドを実行できない場合の代替確認先として使う。
OTEL_HEALTH_CHECK_PORT="13133"

# ---- CloudWatch Agent (cwagent) のログ送信検証 --------------------------------
# ECS の taskdef と同じ CloudWatch Agent サイドカーを compose.yml で起動する構成では、
# 「設定ファイルがコンテナへ届いていない」「logs.endpoint_override の送信先を名前解決
# できない」「収集対象のログファイルが cwagent へマウントされていない」のいずれでも、
# エージェント自体は正常に起動したまま CloudWatch Logs へ 1 件も届かない。起動ログにも
# 明確なエラーが出ないことが多いため、ビルド時のチェックとして次の 2 段で検証する。
#   (A) 設定ファイルのチェック : ビルド前にホスト側だけで完結する静的照合
#   (B) 送信状況のチェック     : 起動確認後に実際の送達 (ロググループ/ストリーム) を確認
VERIFY_CWAGENT="auto"             # auto: cwagent が定義されていれば実行 / true: 必ず実行 / false: 実行しない
CWAGENT_SERVICE="cwagent"         # CloudWatch Agent の Compose サービス名
# ECS サイドカーの慣例に合わせた、コンテナ内の設定ディレクトリ。
CWAGENT_CONFIG_DIR="/etc/cwagentconfig"
# CloudWatch Agent 本体が読み込む既定の設定ファイル。/etc/cwagentconfig を使わず
# こちらへ直接マウントする構成でも設定は届くため、注入経路の候補として扱う。
CWAGENT_CONFIG_FALLBACK_PATH="/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"
CWAGENT_DELIVERY_TARGET="auto"    # auto: endpoint_override の有無で判定 / mock: 偽装サービス / aws: 実 CloudWatch Logs
CWAGENT_DELIVERY_TIMEOUT="60"     # 送達を待つ最大秒数 (force_flush_interval より十分長くする)
CWAGENT_DELIVERY_INTERVAL="5"     # 送達確認のポーリング間隔 (秒)
# 送達レポート (送信先への問い合わせ・最大 CWAGENT_DELIVERY_TIMEOUT 秒の待ち合わせ・
# 収集対象ごとの結果表示) は、実 CloudWatch Logs / 偽装サービスへ実際に問い合わせるうえ
# ビルド時間も延ばすため、既定では行わず --cwagent-delivery-report 指定時だけ実行する。
CWAGENT_DELIVERY_REPORT="false"   # true: 送達を待ち合わせて送達レポートを表示する
CWAGENT_MOCK_SERVICE=""           # 偽装 CloudWatch Logs の Compose サービス名 (空なら endpoint_override から解決)
CWAGENT_MOCK_PORT=""              # 偽装 CloudWatch Logs のコンテナ側ポート (空なら endpoint_override から解決)
CWAGENT_REQUIRED="false"          # true: 検証 NG を終了コード 1 として扱う
# 実 CloudWatch Logs 宛ての構成で、設定ファイルの log_group_name が CloudWatch Logs に
# 存在しない場合、PutLogEvents は ResourceNotFoundException となり 1 件も残らない。
# cwagent 自身に logs:CreateLogGroup 権限が無い構成ではエージェント側でも作成できない
# ため、スクリプト側から設定ファイルのロググループ名で作成できるようにしている。ただし
# AWS アカウントへ実体を残す副作用を伴うため、既定では作成せず、
# --cwagent-create-log-group を指定した実行だけで作成する。
CWAGENT_CREATE_LOG_GROUP="false"  # true: 存在しないロググループを設定ファイルの名前で作成する
CWAGENT_ENSURED_LOG_GROUPS=()     # この実行で存在を確認・作成済みのロググループ (再確認の抑止)
CWAGENT_CREATED_LOG_GROUPS=()     # この実行で新規作成したロググループ (表示・レポート用)
CWAGENT_FAILED_LOG_GROUPS=()      # この実行で作成に失敗したロググループ (再試行・二重記録の抑止)
CWAGENT_LOG_GROUP_STAGE_RECORDED="false"  # 自動作成の前提不足を段として記録済みか
# 段の記録に使う区切り。ログ group 名にも説明文にも現れない制御文字を使う。
CWAGENT_STAGE_SEPARATOR=$'\037'
COMPOSE_YAML_SEPARATOR=$'\037'    # compose.yml 展開結果の区切り
CWAGENT_STAGE_RESULTS=()          # "ラベル<US>判定<US>詳細"
CWAGENT_NG="false"                # 1 段でも NG を検出したか
CWAGENT_UNKNOWN="false"           # 1 段でも確認できなかったか
CWAGENT_VERIFY_ACTIVE="false"     # 静的チェックで検証対象と判定できたか (送達チェックの実行条件)
# 静的チェックで解決し、送達チェックへ引き継ぐ値。
CWAGENT_HOST_CONFIG_FILE=""       # ホスト側の設定 JSON パス
CWAGENT_CONTAINER_CONFIG_FILE=""  # コンテナ内の設定 JSON パス
CWAGENT_CONTAINER_CONFIG_JSON=""  # 起動中の cwagent から取り出した設定 JSON
CWAGENT_ENDPOINT_OVERRIDE=""      # logs.endpoint_override の生値 (空なら実 CloudWatch Logs 宛て)
CWAGENT_ENDPOINT_HOST=""          # endpoint_override のホスト名
CWAGENT_ENDPOINT_PORT=""          # endpoint_override のポート
CWAGENT_FORCE_FLUSH_INTERVAL=""   # logs.force_flush_interval (未設定なら空)
CWAGENT_CONFIG_REGION=""          # agent.region または環境変数 AWS_REGION で解決したリージョン
CWAGENT_CONFIG_PARSED="false"     # 設定 JSON を解析できたか (送信先・収集対象の照合可否)
CWAGENT_EXPECTED_DESTINATIONS=()  # "log_group<US>log_stream<US>file_path"
# compose.yml の展開結果 (cwagent の照合に使う)。
declare -A CWAGENT_ENV_VALUES=()          # cwagent の environment
declare -A CWAGENT_DEPENDS_ON=()          # cwagent の depends_on (サービス名 → condition)
declare -A COMPOSE_CONTAINER_NAMES=()     # サービス名 → container_name
declare -A COMPOSE_DEFINED_SERVICES=()    # compose.yml に定義されたサービス名
CWAGENT_VOLUME_SPECS=()                   # cwagent の volumes (短縮記法)
COMPOSE_VOLUME_SPECS=()                   # "サービス名<US>volumes 指定" (全サービス)
CWAGENT_IMAGE=""                          # cwagent の image
CWAGENT_LONG_SYNTAX_VOLUMES="false"       # cwagent の volumes に長記法があるか

# BuildKit の tty 表示はログ保存時に途中経過が上書きされるため、未指定時は
# plain を使用して各ビルドステップの出力を確実に残す。利用者が環境変数を
# 明示している場合はその値を尊重する。
BUILD_PROGRESS="${BUILDKIT_PROGRESS:-plain}"

# ---- 環境変数一覧出力 --------------------------------------------------------
ENV_LIST_LIMIT="all"              # all: 全件表示 / 数値: 各コンテナごとの最大表示件数
ENV_LIST_FILE=""                  # 指定時は環境変数一覧をファイルにも出力
BUILD_ARG_ENV_NAMES_LOADED="false"
declare -A BUILD_ARG_ENV_NAME_SET=()

# ---- コンテナ内ディレクトリツリー出力 -----------------------------------------
DIRECTORY_TREE_DEPTH="all"        # all: 最下層まで / 数値: / 直下を 1 とする最大ディレクトリ深さ
DIRECTORY_TREE_DEPTH_SET="false"  # 深さが明示指定されたか (ビルドのみ実行時の警告用)
DIRECTORY_FILE_LIMIT="none"       # none: ファイル非表示 / all・数値: ファイル表示を有効化
DIRECTORY_FILE_LIMIT_SET="false"  # 表示上限が明示指定されたか (ビルドのみ実行時の警告用)
DEPLOYMENT_DIR_ENVS=()            # ディレクトリパスを値に持つ環境変数名 (複数指定可)
# コンテナ全体ツリーでは、巨大・仮想・実行基盤固有の各ディレクトリ配下を
# 探索しない。通常はディレクトリ自体を 1 ノードとして表示するが、
# DIRECTORY_TREE_HIDDEN_PATHS に含まれるパスはそのノードも表示しない。
# 個別のデプロイ構造表示には適用しない。
DIRECTORY_TREE_PRUNE_PATHS=(
  /afs
  /aws
  /etc
  /local/aws-cli
  /opt/jboss-eap/.galleon
  /opt/jboss-eap/modules/system/layers/base
  /proc
  /usr/share
  /usr/share/X11
  /usr/share/doc
  /usr/share/icons
  /usr/share/licenses
  /usr/share/man
  /usr/share/osinfo
  /usr/share/zoneinfo
  /sys
  /usr/lib
  /usr/lib64
  /usr/local
)
# RHEL 9 / UBI 9 の /usr/share 配下にある実行基盤固有ディレクトリは、
# 枝刈りするだけでなく画面と全量レポートの双方からディレクトリ自体も除外する。
DIRECTORY_TREE_HIDDEN_PATHS=(
  /usr/share/X11
  /usr/share/doc
  /usr/share/icons
  /usr/share/licenses
  /usr/share/man
  /usr/share/osinfo
  /usr/share/zoneinfo
)

# ---- Java JVM パラメータ / OpenTelemetry 設定出力 -----------------------------
# /proc/<pid>/cmdline は NUL 区切りのため、コンテナ内で US (0x1f) へ置き換えてから
# ホスト側の Bash で分解する。JVM パラメータに 0x1f が現れることはない。
JVM_FIELD_SEPARATOR=$'\037'
# 名前と値を桁揃えして表示する際の名前欄の幅 (半角換算)。
JVM_PARAM_NAME_WIDTH="44"
# JVM オプションを渡す代表的な環境変数。ここで指定した内容は起動コマンドラインへ
# 現れないため、/proc/<pid>/cmdline とは別に収集して表示する。
JVM_OPTION_ENV_NAMES=(
  JAVA_OPTS
  JAVA_OPTS_APPEND
  JAVA_TOOL_OPTIONS
  JDK_JAVA_OPTIONS
  _JAVA_OPTIONS
  JBOSS_JAVA_OPTS
  JBOSS_JAVA_SIZING
  JAVA_ARGS
)
# OpenTelemetry の標準環境変数は接頭辞 OTEL_ で始まる (OpenTelemetry 仕様
# "General SDK Configuration" / Java エージェントの設定名)。接頭辞で判定するため、
# OTEL_SERVICE_NAME・OTEL_EXPORTER_OTLP_*・OTEL_INSTRUMENTATION_* などは
# 個別に列挙しなくても検出できる。
OTEL_ENV_NAME_PREFIX="OTEL_"
# 接頭辞 OTEL_ を持たないが OpenTelemetry の構成に使われる環境変数。
# 設定されていれば常に OpenTelemetry 関連として一覧へ出す。
# OTEL_ で始まる名前は上の接頭辞判定で拾えるため、ここには入れない (二重表示になる)。
OTEL_RELATED_ENV_NAMES=(
  AWS_XRAY_DAEMON_ADDRESS       # ADOT / X-Ray デーモンの送信先
  AWS_XRAY_CONTEXT_MISSING      # X-Ray のコンテキスト欠落時の挙動
  AWS_XRAY_TRACING_NAME         # X-Ray のセグメント名
  AWS_LAMBDA_EXEC_WRAPPER       # ADOT Lambda レイヤーの計装ラッパー
  AOT_CONFIG_CONTENT            # ADOT Collector の設定内容 (YAML)
)
# JVM オプション用の環境変数は、値が OpenTelemetry を参照している場合のみ
# OpenTelemetry 関連として扱う (JAVA_TOOL_OPTIONS で javaagent を注入する構成)。
OTEL_JVM_OPTION_ENV_NAMES=(
  JAVA_TOOL_OPTIONS
  JDK_JAVA_OPTIONS
  _JAVA_OPTIONS
  JAVA_OPTS
  JAVA_OPTS_APPEND
  JBOSS_JAVA_OPTS
)
# 送達不良の切り分けでまず確認する主要設定。環境変数と、それに対応する
# システムプロパティ (OTEL_SERVICE_NAME → -Dotel.service.name) の
# どちらも無い場合に「未設定」として表示する。
OTEL_KEY_ENV_NAMES=(
  OTEL_SERVICE_NAME
  OTEL_RESOURCE_ATTRIBUTES
  OTEL_TRACES_EXPORTER
  OTEL_METRICS_EXPORTER
  OTEL_LOGS_EXPORTER
  OTEL_EXPORTER_OTLP_ENDPOINT
  OTEL_EXPORTER_OTLP_PROTOCOL
  OTEL_PROPAGATORS
  OTEL_TRACES_SAMPLER
  OTEL_SDK_DISABLED
)

# ---- 全量ビルドレポート出力 --------------------------------------------------
BUILD_REPORT_DIR=""               # 指定時は日時付きテキストレポートをこの配下へ出力
BUILD_REPORT_DIR_SET="false"
BUILD_REPORT_FILE=""
BUILD_RESULT_STATUS="未実行"
BUILD_RESULT_DETAIL=""
BUILD_IMAGE_INFO=""

# ---- WAR デプロイ時 Java 例外解析 ---------------------------------------------
# JBoss EAP は standalone/deployments 配下の WAR を展開し、記述子の解析・モジュール
# 依存の解決・CDI / JPA / Servlet の初期化を MSC サービスとして起動する。この過程で
# Java の例外が投げられると、当該デプロイユニットは failed となり WFLYCTL0080 /
# WFLYSRV0021 でロールバックされる。ログにはスタックトレースがそのまま出るものの、
# 「どの例外クラスが根本原因か」「なぜそうなるのか」「どう直すのか」はログを読む側の
# 知識に依存していた。そこで、デプロイ処理のログから例外ブロック (Caused by の連鎖と
# スタックフレーム) を切り出し、例外クラスごとの知識をもとに原因分析と対処提案を
# 生成し、画面・全量レポート・Excel ブックの 3 か所へ出力する。
DEPLOY_EXCEPTION_ANALYSIS="true"   # false: Java 例外の解析を行わない
DEPLOY_EXCEPTION_EXCEL=""          # Excel の出力先。空なら --report-dir 配下へ自動命名する
DEPLOY_EXCEPTION_EXCEL_SET="false" # 出力先が明示指定されたか (未指定時の警告条件)
DEPLOY_EXCEPTION_TEXT=""           # テキストの出力先。空なら --report-dir 配下へ自動命名する
DEPLOY_EXCEPTION_TEXT_SET="false"  # 出力先が明示指定されたか
DEPLOY_EXCEPTION_MAX="50"          # 詳細分析を行う例外の最大件数
DEPLOY_EXCEPTION_LOG_ROWS="3000"   # デプロイログの出力上限 (Excel シート・テキスト共通)
DEPLOY_EXCEPTION_ANALYZED="false"  # 解析を実行済みか (成功経路と EXIT 経路の二重実行防止)
# 画面表示と全量レポートへ転記する解析結果の一時ファイル (スタックトレースは要約)。
# 独立して出力するテキストファイル (下の DEPLOY_EXCEPTION_TEXT_OUTPUT) とは別物で、
# そちらは Excel と同じ情報量 (全フレーム + デプロイログ) を持つ。
DEPLOY_EXCEPTION_TEXT_FILE=""
DEPLOY_EXCEPTION_EXCEL_FILE=""     # 実際に出力した Excel のパス
DEPLOY_EXCEPTION_TEXT_OUTPUT=""    # 実際に出力したテキストのパス
DEPLOY_EXCEPTION_TOTAL="0"         # 検出した例外の総数
DEPLOY_EXCEPTION_DEPLOY_TOTAL="0"  # うちデプロイ処理中に発生したもの
DEPLOY_EXCEPTION_WORST=""          # 最も高い深刻度
DEPLOY_EXCEPTION_VERDICT=""        # 解析の総合判定
DEPLOY_EXCEPTION_SKIP_REASON=""    # 解析しなかった理由 (全量レポートへ記載する)
# 解析対象ログの取得状況。コンテナの起動に失敗した場合でも解析自体は必ず行うため、
# 「どこまでのログを解析できたのか」を画面・全量レポート・Excel の三方へ明示する。
DEPLOY_EXCEPTION_LOG_STATUS=""
DEPLOY_EXCEPTION_LOG_COLLECTED="false" # 解析対象のログを 1 行でも取得できたか
# 解析ヘルパーへ渡すログのサービス区切り。ログ本文の行頭には現れない制御文字を使う。
DEPLOY_EXCEPTION_SERVICE_MARKER=$'\037'

# ---- ログ用ヘルパ -----------------------------------------------------------
# 表示する時刻はすべて JST。UTC と読み違えないよう、必ずタイムゾーン名を併記する。
now_display_time() { printf '%s %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$DISPLAY_TZ_LABEL"; }
log()  { printf '[%s] %s\n'  "$(now_display_time)" "$*"; }
warn() { printf '[%s] [WARN] %s\n'  "$(now_display_time)" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(now_display_time)" "$*" >&2; }
# 診断ガイド等の整形出力用 (タイムスタンプ等の接頭辞を付けず、そのまま表示する)
diag() { printf '%s\n' "$*" >&2; }
# dry-run 時は実行内容を表示するだけ、通常時はそのままコマンドを実行する。
run()  {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[%s] [DRY-RUN] %s\n' "$(now_display_time)" "$*"
    return 0
  fi
  "$@"
}

# docker inspect や docker image inspect が返す時刻は、TZ 設定によらず RFC3339 の
# UTC 表記になる。表示前にこのヘルパで JST へ変換し、スクリプト全体の時刻表記を
# 揃える。date -d を持たない環境や解釈できない値は、元の文字列をそのまま返す。
DATE_PARSE_SUPPORTED=""
date_parse_supported() {
  if [ -z "$DATE_PARSE_SUPPORTED" ]; then
    if date -d '2000-01-02T03:04:05Z' '+%s' >/dev/null 2>&1; then
      DATE_PARSE_SUPPORTED="true"
    else
      DATE_PARSE_SUPPORTED="false"
    fi
  fi
  [ "$DATE_PARSE_SUPPORTED" = "true" ]
}

to_jst_display_time() {
  local value="$1" converted
  case "$value" in
    ''|0001-01-01T00:00:00Z)  # Docker が「未設定」を表すゼロ値はそのまま扱う
      printf '%s' "$value"
      return 0
      ;;
  esac
  if ! date_parse_supported; then
    printf '%s' "$value"
    return 0
  fi
  if converted="$(date -d "$value" '+%Y-%m-%d %H:%M:%S.%3N' 2>/dev/null)" \
      && [ -n "$converted" ]; then
    printf '%s %s' "$converted" "$DISPLAY_TZ_LABEL"
  else
    printf '%s' "$value"
  fi
}

# 「開始: <RFC3339>」「終了: <RFC3339>」形式の行だけを JST 表記へ書き換える。
# healthcheck 履歴の出力本文 (任意のテキスト) は変換対象にしない。
rewrite_health_history_time() {
  local line prefix value
  while IFS= read -r line; do
    case "$line" in
      '開始: '[0-9][0-9][0-9][0-9]-[0-9][0-9]-*|'終了: '[0-9][0-9][0-9][0-9]-[0-9][0-9]-*)
        prefix="${line%%: *}"
        value="${line#*: }"
        printf '%s: %s\n' "$prefix" "$(to_jst_display_time "$value")"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage: build_and_verify.sh [OPTIONS]

build_and_push.sh の「ビルドのみ」処理を切り出した専用スクリプト。
compose build でローカルイメージをビルドし、必要に応じて起動確認・URL 応答確認を行う。
ECR ログイン/タグ付け/プッシュ/imagedefinition.json の出力は行わない。

ビルド関連:
  --local-image NAME       compose build で生成されるローカルイメージ名 (既定: j1/base.local)
  --compose-file FILE      compose ファイル (既定: compose.yml)
  --compose-service NAME   ビルド/起動対象サービス名 (未指定なら全サービス)。
                           繰り返し指定またはカンマ区切りで複数指定できる。
                           複数指定時は base サービスを必ず単独で先行ビルドし、
                           ベースイメージの生成確認後、base を除く指定サービスを
                           まとめて並列ビルドする。base を除く指定サービスは同時に起動する。
                           base はビルド専用のため、指定に含めても起動対象にはしない。
                           例: --compose-service app --compose-service db
                               --compose-service app,db
  --no-cache               キャッシュを破棄して compose build する
  --dry-run                実際のビルド/起動/URL 呼び出し/ファイル操作は行わず、
                           実行される内容のプレビューのみ表示する

ビルドの停滞検知・進捗表示:
  (既定で有効) ビルド監視
                           BuildKit の "exporting to image" / "exporting layers"
                           は、ビルドしたレイヤを Docker のイメージストアへ
                           書き出す段で、--progress=plain では開始の 1 行を
                           出したあと完了するまで追加の出力が出ない。
                           ベースイメージのようにレイヤが大きいとこの段だけで
                           数分〜数十分かかり、停止したのか進んでいるのかを
                           画面から判断できなくなる。
                           そこでビルド中は 30 秒ごとに「経過時間 / 直近の出力
                           からの経過 / BuildKit のフェーズ / data root の空き
                           容量の増減」を表示する。空き容量が減り続けていれば
                           遅いだけで進行中、変化がなければ停滞と判断できる。
                           出力が 300 秒途切れた場合は、Docker daemon の応答・
                           空き容量・inode・I/O 状況を自動で調べ、想定原因と
                           対処方法を一覧表示する (処理は中断しない)。
  --build-progress-interval SEC
                           進捗表示の間隔 (既定: 30)。0 で進捗表示を行わない。
  --build-stall-timeout SEC
                           ビルド出力がこの秒数途切れたら停滞と判断して診断を
                           表示する (既定: 300)。0 で停滞検知を行わない。
                           検知しても処理は継続する (中断はしない)。
  --build-timeout SEC      ビルド全体の上限秒数 (既定: 0 = 無制限)。超えた場合は
                           診断を表示したうえで SIGTERM でビルドを中断し
                           (20 秒後に SIGKILL)、終了コード 1 で終了する。
                           プロンプトが戻らない状態を確実に打ち切りたい場合に
                           指定する。
  --no-build-watchdog      上記の監視をすべて行わず、ビルド出力をそのまま流す。
                           BUILDKIT_PROGRESS=tty のように行単位でない進捗表示を
                           使いたい場合に指定する。
                           ※ 監視は行単位でビルド出力を読むため、有効な間は
                             BUILDKIT_PROGRESS=tty を plain へ切り替える。

ディスク使用量の抑制:
  (既定で有効) 旧世代イメージの回収
                           compose build はローカルイメージ名のタグを新しいイメージへ
                           付け替えるだけで、直前の世代はタグを失った <none>:<none>
                           として残り続ける。--no-cache では共有レイヤが無いため、
                           実行のたびにイメージ 1 個分がそのまま積み上がる。
                           ビルドの前後で image ID を突き合わせ、世代交代した旧 ID が
                           どのタグからも参照されていない場合のみ削除する。
                           docker image prune と違い今回のビルドで生じた 1 件だけを
                           対象とするため、同じ Docker daemon を使う他プロジェクトの
                           dangling イメージには影響しない。
  --no-reclaim-old-image   旧世代イメージの回収を行わない (従来どおり残す)。
                           世代を比較したい調査時などに指定する。
  --prune-build-cache      処理終了時 (成功・失敗を問わず) に、削除可能なビルド
                           キャッシュをすべて削除する
                           (docker builder prune --all --force)。
                           --no-cache は「既存のキャッシュを読まない」指定であって
                           「書かない」指定ではないため、指定した実行でも
                           キャッシュは毎回増える点に注意する。
                           ※ 同じ Docker daemon を使う他プロジェクトのビルド
                             キャッシュも削除される。
  --prune-build-cache-keep SIZE
                           --prune-build-cache と同じ処理を、SIZE の容量を残して
                           実行する (docker builder prune --force
                           --keep-storage SIZE)。例: 10GB / 512MB
                           ※ 環境の buildx が --keep-storage を持たない場合は
                             警告を表示して削除を行わない。
  --disk-usage-report      ビルド前と処理終了時に Docker 管理対象の使用量
                           (docker system df の合計) を測定し、実行前からの増減を
                           表示する。Docker data root を特定できる場合は、
                           その空き容量も併せて表示する。
                           容量を削除する処理は行わない (計測のみ)。

終了時の Docker 完全クリーンアップ:
  --cleanup-all-docker-data
                           処理終了時 (成功・失敗を問わず)、現在の Docker context にある
                           全コンテナ (Compose を含む。一時停止中は解除) を通常停止した後、
                           停止済みを含む全コンテナ、
                           全ローカルイメージ、全ローカルボリューム、未使用の
                           ユーザー定義ネットワーク、削除可能な全ビルドキャッシュを
                           削除する。
                           実行直前に削除対象と件数を表示し、確認フレーズの入力を
                           必須とする。確認できない場合は Docker 全体クリーンアップを
                           実行せず、終了コード 1 とする。
                           Docker daemon / Docker Desktop、標準ネットワーク、context、
                           認証情報、daemon 設定は削除・停止しない。
                           --keep-container とは同時に指定できない。

  --copy-file SRC:DEST_DIR ビルド前に SRC を DEST_DIR ディレクトリへコピーし、
                           処理終了後 (成功・失敗を問わず) に自動削除する。
                           複数ファイルに対応するため繰り返し指定できる。
                           例: --copy-file .npmrc:./app --copy-file cert.pem:./app/certs
                           - DEST_DIR は既存ディレクトリである必要がある
                           - コピー先に同名ファイルが既存の場合は強制上書きする (既定)。
                             上書き前のファイルは一時退避し、処理終了時に削除ではなく
                             復元するため、コピー先は実行前の状態に戻る
                           - コピー先が通常ファイル以外 (ディレクトリ / シンボリック
                             リンク等) の場合は、上書き・自動削除とも行わず中止する

  --copy-file-no-overwrite --copy-file のコピー先に同名ファイルが既に存在する場合、
                           上書きせず処理を中止する (exit 1)。
                           既存ファイルへ一切触れたくない場合に指定する。

JBoss マスターパスワード (BuildKit シークレット):
  --jboss-password-param NAME
                           JBoss のマスターパスワードを AWS パラメータストア
                           (SSM Parameter Store) の指定キー NAME から取得する
                           (aws ssm get-parameter --with-decryption)。
                           取得した値は --jboss-password-env の環境変数へ export され、
                           compose.yml の environment 型シークレット定義を通じて
                           BuildKit シークレットとしてビルドに注入される。
                           このオプション使用時は aws コマンドと AWS 認証
                           (aws login --remote 実施済み) が必要で、未認証の場合は
                           認証を促す警告を表示して終了する (exit 1)。
  --jboss-password VALUE   JBoss のマスターパスワードを直接指定する
                           (パラメータストアから取得しない場合)。
                           --jboss-password-param とは同時に指定できない。
                           ※ コマンドライン (ps / シェル履歴) に平文が残るため、
                             可能なら --jboss-password-param か、事前 export +
                             --jboss-password-env の利用を推奨。
  --jboss-password-env NAME
                           シークレットの受け渡しに使う環境変数名
                           (既定: JBOSS_MASTER_PASSWORD)。compose.yml の
                           secrets の environment: と一致させること。
                           このオプションのみを指定した場合は、事前に export
                           済みの環境変数の値をそのままパスワードとして使う。
  --jboss-secret-id ID     BuildKit シークレットの id (既定: jboss_master_password)。
                           compose.yml の secrets 名、および Dockerfile の
                           RUN --mount=type=secret,id=... と一致させる。
                           --verify-jboss-password のプローブビルドで参照する。
  --region REGION          パラメータストア参照時の AWS リージョン
                           (既定: ap-northeast-1 / env: AWS_REGION)

JBoss マスターパスワードの伝搬検証:
  --verify-jboss-password  マスターパスワードが「取得元 → 環境変数 →
                           compose.yml の secrets → BuildKit シークレット
                           (/run/secrets) → Elytron CredentialStore →
                           jboss-cli が生成した standalone.xml → 実行時に
                           解決される値」の各段で原本と一致しているかを検証し、
                           結果をビルド時に画面へ出力する。
                           - 一致した段は「一致」と、一致したパスワード文字列を表示
                           - 一致しない段は「不一致」と、原本・実際に設定されている
                             文字列の双方を、バイト長・16 進ダンプ付きで表示
                           - $ # " ` \ 等、シェル / XML / WildFly 式のいずれかで
                             意味を持つ文字を検出し、壊れうる段を併せて表示
                           standalone.xml と CredentialStore の確認には
                           コンテナ起動が必要なため、--verify-startup または
                           --verify-url と併用する (単独指定時はビルドまでの段のみ)。
  --jboss-password-mask    伝搬検証の出力でパスワード文字列を伏字にする。
                           一致・不一致の判定とバイト長・差分位置は表示する。
  --jboss-config-file PATH コンテナ内の standalone.xml のパス。
                           未指定時は JBOSS_HOME 等から自動探索する。
  --jboss-cli-path PATH    コンテナ内の jboss-cli.sh のパス (未指定時は自動探索)
  --jboss-elytron-tool PATH
                           コンテナ内の elytron-tool.sh のパス (未指定時は自動探索)
  --jboss-credential-store PATH
                           コンテナ内の CredentialStore ファイルのパス。
                           未指定時は standalone.xml の credential-store 定義から特定する。

起動確認 (jbosseap / WildFly):
  --verify-startup         ビルド後にコンテナを起動し、jbosseap サーバーの起動完了を
                           ログから確認する。確認後はコンテナを停止・削除する
                           (--keep-container 指定時は残す)。
  --startup-service NAME   起動完了チェックを行うサービス名。繰り返し指定または
                           カンマ区切りで複数指定でき、指定した全サービスの起動完了を
                           それぞれのログから個別に確認する。指定時は --verify-startup
                           を暗黙に有効化する。未指定なら対象サービス全体のログを
                           まとめて確認する (従来動作)。
                           例: --compose-service app,db --startup-service app
  --startup-log-pattern P  起動完了とみなすログのパターン (拡張正規表現)。
                           既定: 'WFLYSRV0025:' (WFLYSRV0026 は失敗扱い)
  --startup-timeout SEC    起動完了を待つ最大秒数 (既定: 120)
  --startup-interval SEC   起動確認のポーリング間隔・秒 (既定: 3)
  --startup-log-lines N|all
                           起動確認対象と、同時に起動した他 Compose サービスの
                           ログ、および logs モードで選択したサービスの画面表示行数。
                           N は各サービスの末尾 N 行、all は全行を表示する (既定: 50)
  --wait-healthy           compose up に --wait を付け、起動対象サービスが healthy
                           (healthcheck 未定義なら running) になるまで compose 側で
                           待ってから起動確認へ進む。依存サービスの準備完了を待たずに
                           アプリが起動して失敗するのを防ぐ。compose.yml 側で依存
                           サービスに healthcheck と depends_on の condition:
                           service_healthy を定義しておくこと。
  --wait-timeout SEC       --wait の最大待機秒数 (既定: 600)。指定すると
                           --wait-healthy も暗黙に有効化する
  --allow-service-exit NAME
                           起動確認中に停止していても失敗扱いにしないサービス名。
                           繰り返し指定またはカンマ区切りで複数指定できる。
                           既定では --compose-service で指定した全サービス
                           (base を除く) の停止を失敗として即座に報告する
  --suppress-startup-logs  起動確認対象と同時起動サービスのログ表示を抑制する
                           (起動判定は継続)
  --shutdown-timeout SEC   エラー終了時に SIGTERM でコンテナを終了させる際、
                           SIGKILL へ切り替えるまでの猶予秒数 (既定: 30 /
                           ECS の StopTimeout 既定と同じ)。この停止を挟むことで、
                           adot collector などサイドカーの終了処理ログまで
                           画面・全量レポートへ残す
  --no-shutdown-logs       エラー終了時の SIGTERM 停止と終了ログ取得を行わない。
                           コンテナは従来どおり compose down でまとめて削除する
  --keep-container         確認後もコンテナを停止・削除せずに残す (調査用)
  --keep-container-mode MODE
                           起動確認後もコンテナを残し、検証対象コンテナで MODE の
                           対話操作を実行する。指定時は --verify-startup と
                           --keep-container を暗黙に有効化する。
                           MODE:
                             bash  docker exec で /bin/bash へ直接接続する
                             http  JBoss EAP へ対話式の HTTP リクエストを送る
                              logs  起動中 Compose サービスを番号で選択後、
                                    ログ表示、対話式 bash 接続、healthcheck の
                                    設定・実行履歴・通信確認を繰り返す。
                                    MySQL サーバーでは SQL の対話実行も選択できる。
                                    cwagent / cloudwatch-logs-mock では CloudWatch
                                    Logs 偽装送達、otel / adot-collector / jaeger
                                    では X-Ray 偽装トレースも確認できる。
                                    JVM トラストストアと https:// の接続先を
                                    設定済みのコンテナ (front / back 等) では
                                    証明書チェックも選択でき、コンテナ内の
                                    設定だけで自己証明書による HTTPS 接続を
                                    確認する (パラメータ入力なし)
                                    (bash 接続先には /bin/bash が必要)
                           bash/http で対象が複数ある場合と、logs のサービス選択では
                           番号選択ダイアログを表示する。
                           送達診断の JSON 整形には curl と Python 3 が必要。
  --exit-on-deploy-error   デプロイエラー (AP サーバは起動したが、アプリのデプロイで
                           失敗した状態) を検出したときに、調査用の対話操作へ入らず
                           そのまま終了する (従来の動作)。
                           既定では、デプロイエラーを検出してもコンテナと AP サーバを
                           起動したまま残し、デプロイ成功後と同じ対話操作
                           (--keep-container-mode 未指定なら logs) を開始して、
                           各 Compose サービスへの bash 接続やログ確認を行える。
                           対話操作を終えてもコンテナは起動状態のまま残るため、
                           不要になったら compose down で削除する。
                           端末から入力できない場合 (CI 等) は対話操作へ入れないため、
                           自動的に従来どおりの終了処理へ切り替える。
                           起動確認のタイムアウトやコンテナの途中停止は、
                           デプロイエラーではないため従来どおり終了する。
  --jboss-context-root ROOT
                           http モードで使う JBoss EAP のコンテキストルート。
                           未指定時は WFLYUT0021 ログから検出し、複数なら選択する。
  --jboss-http-port PORT   http モードで使うコンテナ側 HTTP リスナーポート。
                           未指定時は WFLYUT0006 ログから検出する (検出不能時: 8080)。
                           Docker の公開ポートがあれば接続先ポートへ自動変換する。
  --suppress-removed-logs  compose down 実行時の "Container ... Removed" 等の
                           出力を抑制する (ログが煩雑な場合に使用)
  --env-list-limit N|all   動作確認成功時に表示する環境変数一覧の件数。
                           各対象コンテナごとに先頭 N 件を表示する。
                           既定: all (全件表示)
  --env-list-file FILE     動作確認成功時の環境変数一覧を FILE にも出力する。
                           画面表示は従来どおり継続する
  --directory-tree-depth N|all
                           環境変数一覧の後に表示するコンテナ内ディレクトリツリーの
                           最大深さ。/ 直下を深さ 1 とし、既定の all は最下層まで表示する。
                           JBoss EAP のデプロイ構造にも同じ深さを適用する
  --directory-file-limit N|all
                           通常ファイルの画面表示を有効にする。各ディレクトリ直下が
                           N 件以下なら全ファイル名、超過時は拡張子別件数を表示する。
                           all は件数にかかわらず全ファイル名を表示する。
                           未指定時はディレクトリのみを表示する
  --deployment-dir-env NAME
                           ディレクトリパスを値に持つコンテナ環境変数名。
                           JBoss デプロイ先、Web アプリケーションルート、
                           WEB-INF/classes と併せて、そのディレクトリ構造を表示する。
                           繰り返し指定またはカンマ区切りで複数指定できる
  --report-dir DIR         ビルド結果、環境変数一覧、コンテナ内ツリー、JBoss EAP
                           デプロイ構造、JVM パラメータ、OpenTelemetry 設定、
                           WAR デプロイ時 Java 例外解析を
                           DIR/build_and_verify_<日時>.txt へ保存する。
                           保存内容は画面の制限にかかわらず全深度・全ファイル名となる。
                           あわせて Java 例外解析を
                           DIR/build_and_verify_<日時>_java_exceptions.xlsx と
                           DIR/build_and_verify_<日時>_java_exceptions.txt へ
                           追加出力する (Excel とテキストは同じ内容)

WAR デプロイ時の Java 例外解析:
  (オプション指定不要。デプロイ処理のログに Java 例外があれば自動で解析する)
  解析内容               コンテナ起動後のログから Java の例外ブロックを切り出し、
                         Caused by の連鎖をたどって根本原因の例外クラスを特定する。
                         例外クラスごとに「何が起きたか」「発生の仕組み」
                         「想定される原因」「確認手順」「対処方法」「再発防止」を
                         生成し、画面と全量レポートへ出力する。
                         クラスロード / データソース / JNDI / CDI (Weld) /
                         JPA / TLS / メモリなど、EAP のデプロイで起きやすい
                         例外クラスを分類し、WFLYSRV0021・WFLYCTL0080 といった
                         EAP のメッセージコードと突き合わせて、デプロイ失敗の
                         直接原因かどうかまで判定する
  --deploy-exception-excel FILE
                         Java 例外解析の結果を Excel ブック (.xlsx) として
                         FILE へ出力する。--report-dir 指定時は未指定でも
                         DIR/build_and_verify_<日時>_java_exceptions.xlsx へ
                         自動出力する。ブックは「概要」「例外一覧」「原因分析」
                         「対処方法」「スタックトレース」「デプロイログ」の
                         6 シート構成 (フォントは Meiryo UI、列幅・行高・
                         折り返しを内容から計算し、文字が切れないようにする)。
                         出力には Python 3 が必要
  --deploy-exception-text FILE
                         Excel と同じ内容を、テキストファイルとして FILE へ
                         出力する。--report-dir 指定時は未指定でも
                         DIR/build_and_verify_<日時>_java_exceptions.txt へ
                         自動出力する。全スタックフレームと区分付きデプロイログ
                         まで含むため、Excel を開けない環境でも同じ情報を追える
  --deploy-exception-limit N
                         詳細分析を行う例外の最大件数 (既定: 50)
  --no-deploy-exception-analysis
                         Java 例外の解析とファイル出力を行わない

  (オプション指定不要の自動表示)
  Java JVM パラメータ一覧  動作確認したコンテナ内の Java プロセスを /proc から検出し、
                           起動時の JVM パラメータをヒープ・メモリ / GC /
                           Java エージェント / OpenTelemetry / JBoss /
                           システムプロパティ / クラスパス・モジュール / その他へ
                           分類して表示する。JAVA_OPTS・JAVA_TOOL_OPTIONS など、
                           コマンドラインに現れない環境変数経由の指定も併記する。
  OpenTelemetry 設定一覧   OTEL_ で始まる標準環境変数、AWS_XRAY_* などの関連環境変数、
                           -Dotel.* や OpenTelemetry の -javaagent といった JVM
                           パラメータを 1 つの一覧にまとめて表示する。
                           主要設定が環境変数・システムプロパティのどちらにも
                           無い場合は「未設定」として併せて表示する。
                           ※ 値に認証情報を含みやすい名前 (PASSWORD / TOKEN /
                             SECRET / HEADERS 等) は [REDACTED] で表示する

CloudWatch Agent (cwagent) のログ送信検証:
  (compose.yml に cwagent サービスが定義されていれば自動で実行する)
  設定ファイルのチェック   ビルド前に、compose.yml の cwagent 定義とマウントする
                           設定 JSON を突き合わせ、次の不備を検出する。
                           - 設定ファイルが /etc/cwagentconfig へ注入されていない、
                             またはホスト側の実ファイルが存在しない
                             (存在しないパスを bind mount すると Docker が空の
                              ディレクトリを作るため、設定は届かない)
                           - 設定 JSON の構文エラー、collect_list の必須キー欠落、
                             CloudWatch Logs の命名規則に反する
                             log_group_name / log_stream_name
                           - logs.endpoint_override の送信先ホストが compose.yml の
                             サービス名・container_name のいずれとも一致しない
                             (コンテナ内から名前解決できず送信が失敗する)
                           - collect_list の file_path が cwagent の volumes へ
                             マウントされていない (tail 対象が存在しない)
                           - リージョン (agent.region / AWS_REGION) と認証情報が無い
  送信状況のチェック       起動確認後に、実際に起動した cwagent が読み込んだ設定を
                           コンテナから取り出してホスト側と比較し、cwagent の
                           警告・エラーログも併せて表示する。
                           --cwagent-delivery-report を指定した場合は、さらに設定済みの
                           ロググループ / ログストリームへログイベントが届くまで待って
                           確認し、送達レポートを表示する (既定では行わない)。
                           - logs.endpoint_override が偽装サービス (WireMock) を指す
                             場合は、その request journal の PutLogEvents を確認する
                           - endpoint_override が無い場合は aws logs コマンドで
                             実 CloudWatch Logs のロググループ / ストリーム /
                             今回の実行以降のイベントを確認する (AWS 認証が必要)
                           - 実 CloudWatch Logs 宛てで設定ファイルのロググループが
                             存在しない場合は、--cwagent-create-log-group 指定時のみ
                             コンテナ起動前にその名前で自動作成する (既定では作成しない)
  --verify-cwagent         cwagent サービスが定義されていない場合も検証を試み、
                           見つからなければ NG として報告する
  --no-verify-cwagent      cwagent のログ送信検証を行わない
  --cwagent-service NAME   CloudWatch Agent の Compose サービス名 (既定: cwagent)
  --cwagent-config-dir PATH
                           コンテナ内の設定ディレクトリ (既定: /etc/cwagentconfig)
  --cwagent-delivery-target auto|mock|aws
                           送信状況の確認先。auto は logs.endpoint_override が
                           あれば mock、無ければ aws を選ぶ (既定: auto)
  --cwagent-delivery-report
                           設定済みのロググループ / ログストリームへログイベントが
                           届くまで待ち合わせ、収集対象ごとの送達レポートを表示する
                           (既定では行わない。指定しない場合は待ち合わせもしない)
  --no-cwagent-delivery-report
                           送達レポートを行わない (既定)
  --cwagent-delivery-timeout SEC
                           送達を待つ最大秒数。--cwagent-delivery-report 指定時に
                           使う (既定: 60)
  --cwagent-delivery-interval SEC
                           送達確認のポーリング間隔・秒。--cwagent-delivery-report
                           指定時に使う (既定: 5)
  --cwagent-mock-service NAME
                           偽装 CloudWatch Logs (WireMock) の Compose サービス名。
                           未指定時は endpoint_override のホスト名から解決する
  --cwagent-mock-port PORT 偽装 CloudWatch Logs のコンテナ側ポート。
                           未指定時は endpoint_override のポート (既定: 8080)
  --cwagent-required       設定・送達の検証で NG があった場合、終了コード 1 とする
                           (既定は警告のみでビルド結果の判定は変えない)
  --cwagent-create-log-group
                           実 CloudWatch Logs 宛ての構成で、設定ファイルの
                           log_group_name のロググループが存在しない場合に、
                           その名前で自動作成する (既定では作成しない)
  --no-cwagent-create-log-group
                           ロググループの自動作成を行わない (既定。存在しない場合は
                           NG として報告するだけにする)

URL 応答確認:
  --verify-url URL         起動確認後、この URL へ HTTP リクエストを送り応答を確認する。
                           (単独指定でもコンテナを起動して確認する)
  --expect-status CODE     期待する HTTP ステータスコード (既定: 200)
  --url-method METHOD      HTTP メソッド (既定: GET)
  --url-content-type TYPE  verify-url 時の Content-Type ヘッダ値
  --url-body-json JSON     verify-url 時のリクエストボディに JSON を設定する。
                           Content-Type 未指定時は application/json を自動設定する。
  --url-body-form DATA     verify-url 時のリクエストボディに form データ
                           (key=value&...) を設定する。Content-Type 未指定時は
                           application/x-www-form-urlencoded を自動設定する。
  --url-timeout SEC        期待する応答を得るまで待つ最大秒数・リトライ、および
                           HTTP / healthcheck 診断の 1 回あたりの最大秒数。
                           対話式 http モードでは 1 リクエストの最大秒数 (既定: 60)
  --url-interval SEC       URL 呼び出しのリトライ間隔・秒 (既定: 3)
  --url-insecure           TLS 証明書検証を無効化して呼び出す (curl -k)

  -h, --help               このヘルプを表示
EOF
}

# ---- 引数パース -------------------------------------------------------------
# カンマ区切りの値を分割して配列変数 (名前を $1 で受ける) に追加する。
# 例: append_services COMPOSE_SERVICES "app,db"
append_services() {
  local _var="$1" _value="$2" _s
  local -a _parts=()
  IFS=',' read -r -a _parts <<< "$_value"
  for _s in "${_parts[@]}"; do
    [ -n "$_s" ] && eval "$_var+=(\"\$_s\")"
  done
}

# 値を取るオプションで値が省略されると "$2" の参照が set -u の unbound variable
# となり、原因の分からないエラーになる。各 case の先頭で残り引数数を検証する。
need_value() {
  if [ "$2" -lt 2 ]; then
    err "オプションに値が指定されていません: $1"
    err "  使い方は --help を参照してください。"
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local-image)         need_value "$1" $#; LOCAL_IMAGE="$2"; shift 2 ;;
    --compose-file)        need_value "$1" $#; COMPOSE_FILE="$2"; shift 2 ;;
    --compose-service)     need_value "$1" $#; append_services COMPOSE_SERVICES "$2"; shift 2 ;;
    --no-cache)            NO_CACHE="true"; shift ;;
    --build-progress-interval) need_value "$1" $#; BUILD_PROGRESS_INTERVAL="$2"; shift 2 ;;
    --build-stall-timeout) need_value "$1" $#; BUILD_STALL_TIMEOUT="$2"; shift 2 ;;
    --build-timeout)       need_value "$1" $#; BUILD_TIMEOUT="$2"; shift 2 ;;
    --no-build-watchdog)   BUILD_WATCHDOG="false"; shift ;;
    --no-reclaim-old-image) RECLAIM_OLD_IMAGE="false"; shift ;;
    --prune-build-cache)   PRUNE_BUILD_CACHE="true"; shift ;;
    --prune-build-cache-keep)
                           need_value "$1" $#
                           PRUNE_BUILD_CACHE="true"
                           PRUNE_BUILD_CACHE_KEEP="$2"
                           shift 2 ;;
    --disk-usage-report)   DISK_USAGE_REPORT="true"; shift ;;
    --dry-run)             DRY_RUN="true"; shift ;;
    --cleanup-all-docker-data) CLEANUP_ALL_DOCKER_DATA="true"; shift ;;
    --copy-file)           need_value "$1" $#; COPY_SPECS+=("$2"); shift 2 ;;
    --copy-file-no-overwrite) COPY_OVERWRITE="false"; shift ;;
    --region)              need_value "$1" $#; REGION="$2"; shift 2 ;;
    --jboss-password-param) need_value "$1" $#; JBOSS_PASSWORD_PARAM="$2"; shift 2 ;;
    --jboss-password)       need_value "$1" $#; JBOSS_PASSWORD_VALUE="$2"; shift 2 ;;
    --jboss-password-env)   need_value "$1" $#; JBOSS_PASSWORD_ENV="$2"; JBOSS_PASSWORD_ENV_SET="true"; shift 2 ;;
    --jboss-secret-id)      need_value "$1" $#; JBOSS_SECRET_ID="$2"; shift 2 ;;
    --verify-jboss-password) VERIFY_JBOSS_PASSWORD="true"; shift ;;
    --jboss-password-mask)  JBOSS_PASSWORD_SHOW="false"; shift ;;
    --jboss-config-file)    need_value "$1" $#; JBOSS_CONFIG_FILE="$2"; VERIFY_JBOSS_PASSWORD="true"; shift 2 ;;
    --jboss-cli-path)       need_value "$1" $#; JBOSS_CLI_PATH="$2"; VERIFY_JBOSS_PASSWORD="true"; shift 2 ;;
    --jboss-elytron-tool)   need_value "$1" $#; JBOSS_ELYTRON_TOOL_PATH="$2"; VERIFY_JBOSS_PASSWORD="true"; shift 2 ;;
    --jboss-credential-store) need_value "$1" $#; JBOSS_CREDENTIAL_STORE_FILE="$2"; VERIFY_JBOSS_PASSWORD="true"; shift 2 ;;
    --verify-startup)      VERIFY_STARTUP="true"; shift ;;
    --startup-service)     need_value "$1" $#; append_services STARTUP_SERVICES "$2"; VERIFY_STARTUP="true"; shift 2 ;;
    --startup-log-pattern) need_value "$1" $#; STARTUP_LOG_PATTERN="$2"; shift 2 ;;
    --startup-timeout)     need_value "$1" $#; STARTUP_TIMEOUT="$2"; shift 2 ;;
    --startup-interval)    need_value "$1" $#; STARTUP_INTERVAL="$2"; shift 2 ;;
    --startup-log-lines)   need_value "$1" $#; STARTUP_LOG_LINES="$2"; shift 2 ;;
    --wait-healthy)        STARTUP_WAIT="true"; shift ;;
    --wait-timeout)        need_value "$1" $#; STARTUP_WAIT_TIMEOUT="$2"; STARTUP_WAIT="true"; shift 2 ;;
    --allow-service-exit)  need_value "$1" $#; append_services ALLOW_SERVICE_EXIT "$2"; shift 2 ;;
    --suppress-startup-logs) SUPPRESS_STARTUP_LOGS="true"; shift ;;
    --shutdown-timeout)    need_value "$1" $#; SHUTDOWN_LOG_TIMEOUT="$2"; shift 2 ;;
    --no-shutdown-logs)    CAPTURE_SHUTDOWN_LOGS="false"; shift ;;
    --keep-container)      KEEP_CONTAINER="true"; shift ;;
    --keep-container-mode) need_value "$1" $#; KEEP_CONTAINER_MODE="$2"; shift 2 ;;
    --exit-on-deploy-error) KEEP_CONTAINER_ON_DEPLOY_ERROR="false"; shift ;;
    --jboss-context-root)  need_value "$1" $#; JBOSS_CONTEXT_ROOT="$2"; shift 2 ;;
    --jboss-http-port)     need_value "$1" $#; JBOSS_HTTP_PORT="$2"; shift 2 ;;
    --suppress-removed-logs) SUPPRESS_REMOVED_LOGS="true"; shift ;;
    --env-list-limit)      need_value "$1" $#; ENV_LIST_LIMIT="$2"; shift 2 ;;
    --env-list-file)       need_value "$1" $#; ENV_LIST_FILE="$2"; shift 2 ;;
    --directory-tree-depth) need_value "$1" $#; DIRECTORY_TREE_DEPTH="$2"; DIRECTORY_TREE_DEPTH_SET="true"; shift 2 ;;
    --directory-file-limit) need_value "$1" $#; DIRECTORY_FILE_LIMIT="$2"; DIRECTORY_FILE_LIMIT_SET="true"; shift 2 ;;
    --deployment-dir-env) need_value "$1" $#; append_services DEPLOYMENT_DIR_ENVS "$2"; shift 2 ;;
    --report-dir)          need_value "$1" $#; BUILD_REPORT_DIR="$2"; BUILD_REPORT_DIR_SET="true"; shift 2 ;;
    --deploy-exception-excel) need_value "$1" $#; DEPLOY_EXCEPTION_EXCEL="$2"; DEPLOY_EXCEPTION_EXCEL_SET="true"; shift 2 ;;
    --deploy-exception-text) need_value "$1" $#; DEPLOY_EXCEPTION_TEXT="$2"; DEPLOY_EXCEPTION_TEXT_SET="true"; shift 2 ;;
    --deploy-exception-limit) need_value "$1" $#; DEPLOY_EXCEPTION_MAX="$2"; shift 2 ;;
    --no-deploy-exception-analysis) DEPLOY_EXCEPTION_ANALYSIS="false"; shift ;;
    --verify-cwagent)      VERIFY_CWAGENT="true"; shift ;;
    --no-verify-cwagent)   VERIFY_CWAGENT="false"; shift ;;
    --cwagent-service)     need_value "$1" $#; CWAGENT_SERVICE="$2"; shift 2 ;;
    --cwagent-config-dir)  need_value "$1" $#; CWAGENT_CONFIG_DIR="$2"; shift 2 ;;
    --cwagent-delivery-target) need_value "$1" $#; CWAGENT_DELIVERY_TARGET="$2"; shift 2 ;;
    --cwagent-delivery-report)    CWAGENT_DELIVERY_REPORT="true"; shift ;;
    --no-cwagent-delivery-report) CWAGENT_DELIVERY_REPORT="false"; shift ;;
    --cwagent-delivery-timeout) need_value "$1" $#; CWAGENT_DELIVERY_TIMEOUT="$2"; shift 2 ;;
    --cwagent-delivery-interval) need_value "$1" $#; CWAGENT_DELIVERY_INTERVAL="$2"; shift 2 ;;
    --cwagent-mock-service) need_value "$1" $#; CWAGENT_MOCK_SERVICE="$2"; shift 2 ;;
    --cwagent-mock-port)   need_value "$1" $#; CWAGENT_MOCK_PORT="$2"; shift 2 ;;
    --cwagent-required)    CWAGENT_REQUIRED="true"; shift ;;
    --cwagent-create-log-group)    CWAGENT_CREATE_LOG_GROUP="true"; shift ;;
    --no-cwagent-create-log-group) CWAGENT_CREATE_LOG_GROUP="false"; shift ;;
    --verify-url)          need_value "$1" $#; VERIFY_URL="$2"; shift 2 ;;
    --expect-status)       need_value "$1" $#; EXPECT_STATUS="$2"; shift 2 ;;
    --url-method)          need_value "$1" $#; URL_METHOD="$2"; shift 2 ;;
    --url-content-type)    need_value "$1" $#; URL_CONTENT_TYPE="$2"; shift 2 ;;
    --url-body-json)       need_value "$1" $#; URL_BODY_JSON="$2"; shift 2 ;;
    --url-body-form)       need_value "$1" $#; URL_BODY_FORM="$2"; shift 2 ;;
    --url-timeout)         need_value "$1" $#; URL_TIMEOUT="$2"; shift 2 ;;
    --url-interval)        need_value "$1" $#; URL_INTERVAL="$2"; shift 2 ;;
    --url-insecure)        URL_INSECURE="true"; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) err "不明なオプション: $1"; usage; exit 2 ;;
  esac
done

# 表示件数・階層深さは、何も表示されない指定を避けるため 1 以上に制限する。
validate_positive_integer() {
  local value="$1" opt_name="$2"
  case "$value" in
    ''|*[!0-9]*|0)
      err "${opt_name} には 1 以上の整数を指定してください: ${value}"
      return 1
    ;;
  esac
  return 0
}

# ビルド監視の各値は「0 = その監視を行わない」を意味するため 0 を許す。
validate_non_negative_integer() {
  local value="$1" opt_name="$2"
  case "$value" in
    ''|*[!0-9]*)
      err "${opt_name} には 0 以上の整数を指定してください: ${value}"
      return 1
    ;;
  esac
  return 0
}

if [ "$STARTUP_LOG_LINES" != "all" ]; then
  validate_positive_integer "$STARTUP_LOG_LINES" "--startup-log-lines" || exit 2
fi
validate_non_negative_integer "$BUILD_PROGRESS_INTERVAL" "--build-progress-interval" || exit 2
validate_non_negative_integer "$BUILD_STALL_TIMEOUT" "--build-stall-timeout" || exit 2
validate_non_negative_integer "$BUILD_TIMEOUT" "--build-timeout" || exit 2
validate_positive_integer "$STARTUP_TIMEOUT" "--startup-timeout" || exit 2
validate_positive_integer "$STARTUP_WAIT_TIMEOUT" "--wait-timeout" || exit 2
# 0 を許すと SIGTERM 直後に SIGKILL となり、終了処理のログが残らないため 1 以上とする。
validate_positive_integer "$SHUTDOWN_LOG_TIMEOUT" "--shutdown-timeout" || exit 2
validate_positive_integer "$URL_TIMEOUT" "--url-timeout" || exit 2
if [ "$ENV_LIST_LIMIT" != "all" ]; then
  validate_positive_integer "$ENV_LIST_LIMIT" "--env-list-limit" || exit 2
fi
if [ "$DIRECTORY_TREE_DEPTH" != "all" ]; then
  validate_positive_integer "$DIRECTORY_TREE_DEPTH" "--directory-tree-depth" || exit 2
fi
if [ "$DIRECTORY_FILE_LIMIT_SET" = "true" ] && [ "$DIRECTORY_FILE_LIMIT" != "all" ]; then
  validate_positive_integer "$DIRECTORY_FILE_LIMIT" "--directory-file-limit" || exit 2
fi
for _deployment_env in "${DEPLOYMENT_DIR_ENVS[@]}"; do
  if ! printf '%s' "$_deployment_env" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
    err "--deployment-dir-env に不正な環境変数名が指定されました: $_deployment_env"
    exit 2
  fi
done
if [ "$BUILD_REPORT_DIR_SET" = "true" ] && { [ -z "$BUILD_REPORT_DIR" ] || [ "$BUILD_REPORT_DIR" = "-" ]; }; then
  err "--report-dir にはディレクトリパスを指定してください: $BUILD_REPORT_DIR"
  exit 2
fi
validate_positive_integer "$DEPLOY_EXCEPTION_MAX" "--deploy-exception-limit" || exit 2
if [ "$DEPLOY_EXCEPTION_EXCEL_SET" = "true" ]; then
  if [ -z "$DEPLOY_EXCEPTION_EXCEL" ] || [ "$DEPLOY_EXCEPTION_EXCEL" = "-" ]; then
    err "--deploy-exception-excel にはファイルパスを指定してください: $DEPLOY_EXCEPTION_EXCEL"
    exit 2
  fi
  # 拡張子が .xlsx でないと Excel が形式を判別できず、開けないファイルになる。
  case "$DEPLOY_EXCEPTION_EXCEL" in
    *.xlsx) ;;
    *)
      err "--deploy-exception-excel には .xlsx で終わるパスを指定してください: $DEPLOY_EXCEPTION_EXCEL"
      exit 2
      ;;
  esac
  if [ "$DEPLOY_EXCEPTION_ANALYSIS" != "true" ]; then
    err "--deploy-exception-excel と --no-deploy-exception-analysis は同時に指定できません。"
    exit 2
  fi
fi
if [ "$DEPLOY_EXCEPTION_TEXT_SET" = "true" ]; then
  if [ -z "$DEPLOY_EXCEPTION_TEXT" ] || [ "$DEPLOY_EXCEPTION_TEXT" = "-" ]; then
    err "--deploy-exception-text にはファイルパスを指定してください: $DEPLOY_EXCEPTION_TEXT"
    exit 2
  fi
  if [ "$DEPLOY_EXCEPTION_ANALYSIS" != "true" ]; then
    err "--deploy-exception-text と --no-deploy-exception-analysis は同時に指定できません。"
    exit 2
  fi
fi
if [ "$DEPLOY_EXCEPTION_EXCEL_SET" = "true" ] && [ "$DEPLOY_EXCEPTION_TEXT_SET" = "true" ] \
    && [ "$DEPLOY_EXCEPTION_EXCEL" = "$DEPLOY_EXCEPTION_TEXT" ]; then
  err "--deploy-exception-excel と --deploy-exception-text に同じパスは指定できません: $DEPLOY_EXCEPTION_EXCEL"
  exit 2
fi

# ---- cwagent 検証オプションの検証 -------------------------------------------
validate_positive_integer "$CWAGENT_DELIVERY_TIMEOUT" "--cwagent-delivery-timeout" || exit 2
validate_positive_integer "$CWAGENT_DELIVERY_INTERVAL" "--cwagent-delivery-interval" || exit 2
if [ "$CWAGENT_DELIVERY_INTERVAL" -gt "$CWAGENT_DELIVERY_TIMEOUT" ]; then
  err "--cwagent-delivery-interval は --cwagent-delivery-timeout 以下にしてください: ${CWAGENT_DELIVERY_INTERVAL} > ${CWAGENT_DELIVERY_TIMEOUT}"
  exit 2
fi
case "$CWAGENT_DELIVERY_TARGET" in
  auto|mock|aws) ;;
  *)
    err "--cwagent-delivery-target には auto、mock または aws を指定してください: ${CWAGENT_DELIVERY_TARGET}"
    exit 2
    ;;
esac
if [ -z "$CWAGENT_SERVICE" ]; then
  err "--cwagent-service にはサービス名を指定してください"
  exit 2
fi
case "$CWAGENT_CONFIG_DIR" in
  /*) ;;
  *)
    err "--cwagent-config-dir にはコンテナ内の絶対パスを指定してください: ${CWAGENT_CONFIG_DIR}"
    exit 2
    ;;
esac
if [ -n "$CWAGENT_MOCK_PORT" ]; then
  case "$CWAGENT_MOCK_PORT" in
    *[!0-9]*)
      err "--cwagent-mock-port には 1 から 65535 の範囲を指定してください: ${CWAGENT_MOCK_PORT}"
      exit 2
      ;;
  esac
  if [ "${#CWAGENT_MOCK_PORT}" -gt 5 ] \
      || (( 10#$CWAGENT_MOCK_PORT < 1 || 10#$CWAGENT_MOCK_PORT > 65535 )); then
    err "--cwagent-mock-port には 1 から 65535 の範囲を指定してください: ${CWAGENT_MOCK_PORT}"
    exit 2
  fi
fi
if [ "$VERIFY_CWAGENT" = "false" ] \
    && { [ -n "$CWAGENT_MOCK_SERVICE" ] || [ -n "$CWAGENT_MOCK_PORT" ] || [ "$CWAGENT_REQUIRED" = "true" ]; }; then
  err "--no-verify-cwagent と cwagent 検証の詳細オプションは同時に指定できません"
  exit 2
fi

case "$KEEP_CONTAINER_MODE" in
  "") ;;
  bash|http|logs)
    KEEP_CONTAINER="true"
    VERIFY_STARTUP="true"
    ;;
  *)
    err "--keep-container-mode には bash、http または logs を指定してください: ${KEEP_CONTAINER_MODE}"
    exit 2
    ;;
esac

if [ -n "$JBOSS_HTTP_PORT" ]; then
  case "$JBOSS_HTTP_PORT" in
    *[!0-9]*)
      err "--jboss-http-port には 1 から 65535 の範囲を指定してください: ${JBOSS_HTTP_PORT}"
      exit 2
      ;;
  esac
  if [ "${#JBOSS_HTTP_PORT}" -gt 5 ] \
      || (( 10#$JBOSS_HTTP_PORT < 1 || 10#$JBOSS_HTTP_PORT > 65535 )); then
    err "--jboss-http-port には 1 から 65535 の範囲を指定してください: ${JBOSS_HTTP_PORT}"
    exit 2
  fi
fi

if { [ -n "$JBOSS_CONTEXT_ROOT" ] || [ -n "$JBOSS_HTTP_PORT" ]; } \
    && [ "$KEEP_CONTAINER_MODE" != "http" ]; then
  err "--jboss-context-root / --jboss-http-port は --keep-container-mode http と併用してください"
  exit 2
fi

if [ -n "$JBOSS_CONTEXT_ROOT" ]; then
  case "$JBOSS_CONTEXT_ROOT" in
    *://*|*\?*|*\#*|*[[:space:]]*)
      err "--jboss-context-root には URL ではなくコンテキストルートのパスだけを指定してください: ${JBOSS_CONTEXT_ROOT}"
      exit 2
      ;;
  esac
fi

if [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ] && [ "$KEEP_CONTAINER" = "true" ]; then
  err "--cleanup-all-docker-data と --keep-container は同時に指定できません"
  exit 2
fi

# --prune-build-cache-keep は docker builder prune --keep-storage へそのまま渡すため、
# ここで書式を検証する。誤記のまま渡すと docker 側のエラーになるだけで、
# 「削除したつもりが削除されていない」状態に気付きにくい。
# 受け付ける形式: 10GB / 10G / 512MB / 1.5GB / 10000000 (バイト数)
if [ -n "$PRUNE_BUILD_CACHE_KEEP" ] \
    && ! [[ "$PRUNE_BUILD_CACHE_KEEP" =~ ^[0-9]+(\.[0-9]+)?([KkMmGgTt][Bb]?|[Bb])?$ ]]; then
  err "--prune-build-cache-keep にはサイズを指定してください (例: 10GB / 512MB): ${PRUNE_BUILD_CACHE_KEEP}"
  exit 2
fi

# --startup-service が --compose-service の対象に含まれているか検証する。
# (--compose-service 未指定 = 全サービス対象なので、その場合は検証不要)
if [ ${#STARTUP_SERVICES[@]} -gt 0 ] && [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
  for _ss in "${STARTUP_SERVICES[@]}"; do
    _found="false"
    for _cs in "${COMPOSE_SERVICES[@]}"; do
      [ "$_ss" = "$_cs" ] && _found="true"
    done
    if [ "$_found" != "true" ]; then
      err "--startup-service '$_ss' が --compose-service で指定した対象 (${COMPOSE_SERVICES[*]}) に含まれていません"
      exit 2
    fi
  done
fi

# base はベースイメージを提供するビルド専用サービスであり、起動しても即終了するだけで
# 検証の役に立たない。--compose-service に明示指定されていてもビルドのみに使い、
# 起動・ログ収集・生存監視の対象からは除外する (README の仕様と実装を一致させる)。
COMPOSE_TARGET_SERVICES=()
for _cs in ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"}; do
  [ "$_cs" = "$BASE_SERVICE" ] || COMPOSE_TARGET_SERVICES+=("$_cs")
done
if [ ${#COMPOSE_SERVICES[@]} -gt 0 ] && [ ${#COMPOSE_TARGET_SERVICES[@]} -eq 0 ]; then
  if [ "$VERIFY_STARTUP" = "true" ] || [ -n "$VERIFY_URL" ]; then
    err "--compose-service にベースサービス '${BASE_SERVICE}' しか指定されていないため、起動対象がありません"
    err "  起動確認を行う場合は、起動したいサービスも --compose-service に指定してください。"
    exit 2
  fi
fi

# --verify-url が指定されている場合、コンテナ起動が前提となる。
# 明示的に --verify-startup が付いていなくてもコンテナは起動する
# (起動完了のログ確認を行うかどうかは VERIFY_STARTUP で制御)。
NEED_CONTAINER="false"
if [ "$VERIFY_STARTUP" = "true" ] || [ -n "$VERIFY_URL" ]; then
  NEED_CONTAINER="true"
fi

# URL ボディ指定は JSON / form のどちらか一方のみ許可する。
if [ -n "$URL_BODY_JSON" ] && [ -n "$URL_BODY_FORM" ]; then
  err "--url-body-json と --url-body-form は同時に指定できません (リクエストボディは一つのみ指定できます)"
  exit 2
fi

# verify-url 用の追加指定は --verify-url と組み合わせて使う。
HAS_URL_REQUEST_OPTIONS="false"
if [ -n "$URL_CONTENT_TYPE" ] || [ -n "$URL_BODY_JSON" ] || [ -n "$URL_BODY_FORM" ]; then
  HAS_URL_REQUEST_OPTIONS="true"
fi
if [ -z "$VERIFY_URL" ] && [ "$HAS_URL_REQUEST_OPTIONS" = "true" ]; then
  err "--url-content-type / --url-body-json / --url-body-form は --verify-url と併用してください"
  exit 2
fi

# ボディ形式に応じて Content-Type の既定値を補う。
if [ -z "$URL_CONTENT_TYPE" ]; then
  if [ -n "$URL_BODY_JSON" ]; then
    URL_CONTENT_TYPE="application/json"
  elif [ -n "$URL_BODY_FORM" ]; then
    URL_CONTENT_TYPE="application/x-www-form-urlencoded"
  fi
fi

# ---- JBoss マスターパスワード関連オプションの検証 ----------------------------
# 取得元はパラメータストア (--jboss-password-param) / 直接指定 (--jboss-password) /
# 事前 export 済み環境変数 (--jboss-password-env のみ指定) のいずれか 1 つ。
if [ -n "$JBOSS_PASSWORD_PARAM" ] && [ -n "$JBOSS_PASSWORD_VALUE" ]; then
  err "--jboss-password-param と --jboss-password は同時に指定できません (どちらか一方を指定してください)"
  exit 2
fi
if [ -n "$JBOSS_PASSWORD_PARAM" ] || [ -n "$JBOSS_PASSWORD_VALUE" ] || [ "$JBOSS_PASSWORD_ENV_SET" = "true" ]; then
  JBOSS_SECRET_ENABLED="true"
fi
if ! printf '%s' "$JBOSS_PASSWORD_ENV" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
  err "--jboss-password-env に不正な環境変数名が指定されました: $JBOSS_PASSWORD_ENV"
  exit 2
fi
# シークレット id は BuildKit のマウント先 (/run/secrets/<id>) とプローブビルドの
# Dockerfile へそのまま埋め込むため、パス・シェルの特殊文字を含めさせない。
if ! printf '%s' "$JBOSS_SECRET_ID" | grep -qE '^[A-Za-z0-9._-]+$'; then
  err "--jboss-secret-id には英数字と . _ - のみ指定できます: $JBOSS_SECRET_ID"
  exit 2
fi
# 伝搬検証は、マスターパスワードの取得元が決まっていて初めて突き合わせができる。
# どの取得オプションも無い場合は、事前 export 済みの環境変数を取得元として扱う。
if [ "$VERIFY_JBOSS_PASSWORD" = "true" ] && [ "$JBOSS_SECRET_ENABLED" != "true" ]; then
  if [ -n "${!JBOSS_PASSWORD_ENV:-}" ]; then
    JBOSS_SECRET_ENABLED="true"
    log "--verify-jboss-password: 事前 export 済みの環境変数 ${JBOSS_PASSWORD_ENV} を検証対象のマスターパスワードとして使用します。"
  else
    err "--verify-jboss-password には検証対象のマスターパスワードが必要です。"
    err "  --jboss-password-param / --jboss-password のいずれかを指定するか、"
    err "  環境変数 ${JBOSS_PASSWORD_ENV} を export してから再実行してください。"
    exit 2
  fi
fi
# コンテナ内のパスは、docker exec へ渡すシェルスクリプトに埋め込む。
# 引用を壊す文字が混ざっていると意図しないコマンドが動くため、事前に弾く。
for _jboss_path_opt in \
    "--jboss-config-file:$JBOSS_CONFIG_FILE" \
    "--jboss-cli-path:$JBOSS_CLI_PATH" \
    "--jboss-elytron-tool:$JBOSS_ELYTRON_TOOL_PATH" \
    "--jboss-credential-store:$JBOSS_CREDENTIAL_STORE_FILE"; do
  _jboss_path_name="${_jboss_path_opt%%:*}"
  _jboss_path_value="${_jboss_path_opt#*:}"
  [ -n "$_jboss_path_value" ] || continue
  case "$_jboss_path_value" in
    /*) ;;
    *)
      err "${_jboss_path_name} にはコンテナ内の絶対パスを指定してください: ${_jboss_path_value}"
      exit 2
      ;;
  esac
  case "$_jboss_path_value" in
    *[\'\"\`\$\;\&\|\<\>\*\?]*|*' '*)
      err "${_jboss_path_name} に使用できない文字が含まれています: ${_jboss_path_value}"
      exit 2
      ;;
  esac
done

# ---- 依存コマンド確認 -------------------------------------------------------
# ビルドには docker が必須。URL 応答確認または対話式 HTTP 通信では curl も必須。
# logs モードの可観測性ヘルパーは、選択時に curl と Python 3 を確認する。
# パラメータストアからパスワードを取得する場合は aws も必須。
REQUIRED_CMDS=(docker)
if [ -n "$VERIFY_URL" ] || [ "$KEEP_CONTAINER_MODE" = "http" ]; then
  REQUIRED_CMDS+=(curl)
fi
[ -n "$JBOSS_PASSWORD_PARAM" ] && REQUIRED_CMDS+=(aws)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "必須コマンドが見つかりません: $cmd"
    exit 1
  fi
done

# ---- AWS 認証 (aws login --remote) 済みかのチェック --------------------------
# このスクリプトは通常 AWS を操作しないが、パラメータストアからパスワードを
# 取得する場合のみ AWS 認証が必要になる。事前に aws login --remote による認証
# 操作が実行されているかを sts get-caller-identity で確認し、未認証なら
# 認証を促して終了する。
if [ -n "$JBOSS_PASSWORD_PARAM" ]; then
  log "AWS 認証状態を確認します (aws login --remote 実施済みか) ..."
  if aws sts get-caller-identity >/dev/null 2>&1; then
    log "AWS 認証を確認しました。"
  elif [ "$DRY_RUN" = "true" ]; then
    warn "AWS 認証が確認できませんが、DRY-RUN のため中止せずにプレビューを継続します。"
    warn "  実際に実行する場合は、事前に 'aws login --remote' で認証してください。"
  else
    err "AWS 認証が確認できません (aws sts get-caller-identity に失敗)。未認証の状態です。"
    err "  事前に 'aws login --remote' を実行して認証してから、再実行してください。"
    exit 1
  fi
fi

# docker compose (v2) / docker-compose (v1) の判定。
# 複数サービス指定時は Compose の並列実行オプションも準備する。v2 はグローバルの
# --parallel N、v1 は build サブコマンドの --parallel を使用する。
COMPOSE_PARALLEL_OPTS=()
COMPOSE_BUILD_PARALLEL_OPTS=()
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
  if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
    COMPOSE_PARALLEL_OPTS=(--parallel "${#COMPOSE_SERVICES[@]}")
  fi
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
  if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
    if docker-compose build --help 2>&1 | grep -q -- '--parallel'; then
      COMPOSE_BUILD_PARALLEL_OPTS=(--parallel)
    else
      err "複数サービスの並列ビルドには --parallel 対応の docker-compose が必要です"
      exit 1
    fi
  fi
else
  err "docker compose / docker-compose が見つかりません"
  exit 1
fi

if [ "$DRY_RUN" = "true" ]; then
  log "*** DRY-RUN モードです。実際のビルド/起動/URL 呼び出し/ファイル操作は行いません。 ***"
fi

# ---- JBoss マスターパスワードの取得 / BuildKit シークレット注入準備 ----------
# --jboss-password-param / --jboss-password / --jboss-password-env のいずれかが
# 指定された場合に、マスターパスワードを取得して環境変数へ export する。
# compose.yml 側で secrets の environment: に同じ環境変数名を定義しておくことで、
# BuildKit シークレット (RUN --mount=type=secret) としてビルドから参照できる。
# パスワードの値そのものは、ログにもコマンドラインにも出力しない。
prepare_jboss_password() {
  [ "$JBOSS_SECRET_ENABLED" = "true" ] || return 0
  local password=""
  if [ -n "$JBOSS_PASSWORD_PARAM" ]; then
    JBOSS_PASSWORD_SOURCE_LABEL="パラメータストア ${JBOSS_PASSWORD_PARAM} (region=${REGION})"
    log "パラメータストアから JBoss マスターパスワードを取得します: ${JBOSS_PASSWORD_PARAM} (region=${REGION}) ..."
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] aws ssm get-parameter --name ${JBOSS_PASSWORD_PARAM} --with-decryption --region ${REGION} (値の取得・表示は行いません)"
    else
      local ssm_errfile
      ssm_errfile="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/ssm_err.$$")"
      if ! password="$(aws ssm get-parameter --name "$JBOSS_PASSWORD_PARAM" \
            --with-decryption --region "$REGION" \
            --query 'Parameter.Value' --output text 2>"$ssm_errfile")"; then
        err "パラメータストアからの取得に失敗しました: ${JBOSS_PASSWORD_PARAM}"
        sed 's/^/  /' "$ssm_errfile" >&2
        rm -f "$ssm_errfile"
        err "  パラメータ名 / リージョン (${REGION}) / ssm:GetParameter 権限を確認してください。"
        exit 1
      fi
      rm -f "$ssm_errfile"
      if [ -z "$password" ] || [ "$password" = "None" ]; then
        err "パラメータストアから取得した値が空です: ${JBOSS_PASSWORD_PARAM}"
        exit 1
      fi
      log "パラメータストアから取得しました (値はログに出力しません)。"
    fi
  elif [ -n "$JBOSS_PASSWORD_VALUE" ]; then
    JBOSS_PASSWORD_SOURCE_LABEL="コマンドライン引数 --jboss-password"
    log "直接指定された JBoss マスターパスワードを使用します (値はログに出力しません)。"
    password="$JBOSS_PASSWORD_VALUE"
  else
    # --jboss-password-env のみ指定: 事前に export 済みの環境変数の値をそのまま使う
    JBOSS_PASSWORD_SOURCE_LABEL="事前 export 済みの環境変数 ${JBOSS_PASSWORD_ENV}"
    password="${!JBOSS_PASSWORD_ENV:-}"
    if [ -z "$password" ] && [ "$DRY_RUN" != "true" ]; then
      err "環境変数 ${JBOSS_PASSWORD_ENV} が未設定または空です。"
      err "  --jboss-password-param / --jboss-password で渡すか、事前に export してから再実行してください。"
      exit 1
    fi
    log "既存の環境変数 ${JBOSS_PASSWORD_ENV} の値を JBoss マスターパスワードとして使用します。"
  fi
  # 伝搬検証の基準となる原本を、export する前の値として記録しておく。
  # 以降の各段は、この値とのバイト列一致で判定する。
  if [ "$DRY_RUN" != "true" ]; then
    JBOSS_PASSWORD_ORIGIN="$password"
    JBOSS_PASSWORD_ORIGIN_SET="true"
  fi
  export "${JBOSS_PASSWORD_ENV}=${password}"
  log "JBoss マスターパスワードを環境変数 ${JBOSS_PASSWORD_ENV} 経由で BuildKit シークレットとして注入します。"
  log "  (compose.yml の secrets で environment: ${JBOSS_PASSWORD_ENV} を定義しておくこと)"
}

# ---- JBoss マスターパスワードの伝搬検証 -------------------------------------
# compose.yml の環境変数へ設定したマスターパスワードが、
#   (1) 取得元 → 環境変数
#   (2) 環境変数 → compose.yml の secrets 定義 (BuildKit シークレットの入口)
#   (3) BuildKit シークレット → ビルド中コンテナの /run/secrets/<id>
#   (4) Elytron CredentialStore (原本パスワードで実際に開けるか)
#   (5) jboss-cli が生成した standalone.xml の credential-reference
#   (6) WildFly が実行時に解釈する値 (利用される箇所の実効値)
# のどの段で変質するかを、バイト列の突き合わせで特定する。
#
# $ # " ` \ ' & < > などは、シェル (変数展開・コマンド置換・コメント)、
# XML (実体参照)、WildFly の式 (${...} と $$ エスケープ) のそれぞれで別の意味を持つ。
# 「途中の段までは合っているのに最後で化ける」ことがあるため、段ごとに独立して
# 原本と比較し、一致した段は一致した文字列を、一致しない段は原本と実際の双方を
# 16 進ダンプ付きで表示する。

# コマンド出力を「末尾の改行を落とさずに」変数へ取り込む。
# $(...) は末尾の改行をすべて削るため、パスワード末尾に改行や CR が混入している
# 事故 (CRLF ファイル / echo での生成) をそのままでは検出できない。
# 使い方: jboss_read_exact <格納先変数名> <関数またはコマンド> [引数...]
jboss_read_exact() {
  local _target_var="$1"
  shift
  local _captured
  _captured="$("$@"; printf 'x')"
  printf -v "$_target_var" '%s' "${_captured%x}"
}

# パスワードを段の間で受け渡すための base64 化 / 復元。
# 改行・NUL 以外の制御文字・非 ASCII バイトを、シェルや docker exec の引数解釈に
# 触れさせずに運ぶ。
jboss_b64_encode() { printf '%s' "$1" | base64 2>/dev/null | tr -d '\n'; }
jboss_b64_decode() { printf '%s' "$1" | base64 -d 2>/dev/null; }

# 16 進文字列 (空白等は無視) をバイト列へ戻す。
# base64 を持たないコンテナからの取り込み用フォールバック。
jboss_hex_decode() {
  local hex="$1" format="" index
  hex="${hex//[^0-9a-fA-F]/}"
  # 奇数桁は壊れた入力のため、末尾の 1 桁を捨てて解釈可能な範囲だけ戻す。
  for (( index = 0; index + 1 < ${#hex}; index += 2 )); do
    format+="\\x${hex:index:2}"
  done
  [ -n "$format" ] && printf "$format"
  return 0
}

# バイト単位の 16 進ダンプ (空白区切り)。目に見えない差分 (末尾改行・CR・全角空白・
# 非 ASCII の別コードポイント) を突き合わせるために使う。
jboss_password_hex() {
  local value="$1"
  [ -n "$value" ] || return 0
  if command -v od >/dev/null 2>&1; then
    printf '%s' "$value" | od -An -v -tx1 2>/dev/null | tr -s ' \n' ' ' | sed -e 's/^ //' -e 's/ $//'
  fi
  return 0
}

jboss_password_byte_length() {
  local hex
  hex="$(jboss_password_hex "$1")"
  if [ -z "$hex" ]; then
    printf '%s' "${#1}"
    return 0
  fi
  printf '%s' "$hex" | awk '{ print NF }'
}

# 表示可能な ASCII (0x20-0x7E) を並べた表。可視化でコードから文字を引くために使う。
JBOSS_PRINTABLE_ASCII=' !"#$%&'"'"'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~'

# 制御文字・空白・非 ASCII バイトを目に見える表記へ置き換える。
# 例: 'pa$s ' + CR → pa$s<SP><CR>
jboss_password_visible() {
  local value="$1" hex byte code visible=""
  [ -n "$value" ] || { printf '(空文字)'; return 0; }
  hex="$(jboss_password_hex "$value")"
  if [ -z "$hex" ]; then
    printf '%s' "$value"
    return 0
  fi
  for byte in $hex; do
    code=$((16#$byte))
    if [ "$code" -eq 9 ]; then
      visible+='<TAB>'
    elif [ "$code" -eq 10 ]; then
      visible+='<LF>'
    elif [ "$code" -eq 13 ]; then
      visible+='<CR>'
    elif [ "$code" -eq 32 ]; then
      visible+='<SP>'
    elif [ "$code" -gt 32 ] && [ "$code" -lt 127 ]; then
      visible+="${JBOSS_PRINTABLE_ASCII:$((code - 32)):1}"
    else
      visible+="$(printf '<x%02X>' "$code")"
    fi
  done
  printf '%s' "$visible"
}

# 画面・レポートへ出すパスワード文字列。--jboss-password-mask 指定時は伏字にするが、
# 何バイトの値だったかは残して切り分けに使えるようにする。
jboss_password_display() {
  local value="$1"
  if [ "$JBOSS_PASSWORD_SHOW" = "true" ]; then
    if [ -n "$value" ]; then
      printf '%s' "$value"
    else
      printf '(空文字)'
    fi
  else
    printf '(--jboss-password-mask により非表示: %s バイト)' "$(jboss_password_byte_length "$value")"
  fi
}

# 原本と実測値が最初に食い違うバイト位置を返す。
# 「見た目は同じなのに一致しない」場合に、どのバイトが違うのかを 1 行で示す。
jboss_password_first_diff() {
  local expected="$1" actual="$2" index max_count
  local -a expected_bytes=() actual_bytes=()
  read -r -a expected_bytes <<< "$(jboss_password_hex "$expected")"
  read -r -a actual_bytes <<< "$(jboss_password_hex "$actual")"
  max_count=${#expected_bytes[@]}
  [ ${#actual_bytes[@]} -gt "$max_count" ] && max_count=${#actual_bytes[@]}
  for (( index = 0; index < max_count; index++ )); do
    if [ "${expected_bytes[index]:-}" != "${actual_bytes[index]:-}" ]; then
      printf '%s バイト目から相違 (原本: %s / 実際: %s)' \
          "$((index + 1))" "${expected_bytes[index]:-(ここで終端)}" "${actual_bytes[index]:-(ここで終端)}"
      return 0
    fi
  done
  printf '差分なし'
}

# ---- パスワード文字列に含まれる危険文字の分析 -------------------------------
# 文字そのものではなく「どの段で・どう壊れるか」を出す。伝搬検証が不一致を
# 出したときに、原因の当たりを付けられるようにするのが目的。
JBOSS_RISKY_CHAR_SPECS=()
jboss_add_risky_char_spec() {
  JBOSS_RISKY_CHAR_SPECS+=("${1}${JBOSS_STAGE_SEPARATOR}${2}${JBOSS_STAGE_SEPARATOR}${3}")
}

jboss_init_risky_char_specs() {
  [ ${#JBOSS_RISKY_CHAR_SPECS[@]} -eq 0 ] || return 0
  jboss_add_risky_char_spec '$' 'ドル記号' \
      'シェルは二重引用符の中でも変数展開する ("$PW" 等が空文字や別の値に化ける)。WildFly は standalone.xml の属性値を ${...} 式として解決するため、リテラルの $ は $$ と書く必要がある (jboss-cli の add 時にエスケープしないと起動時に値が変わる)'
  jboss_add_risky_char_spec '`' 'バッククォート' \
      'シェルのコマンド置換。二重引用符の中でも実行されるため、値が消えるだけでなく意図しないコマンドが動く'
  jboss_add_risky_char_spec '"' '二重引用符' \
      'シェルと jboss-cli の引用を終端させる。XML 属性値の区切りでもあるため standalone.xml では &quot; へのエスケープが必要'
  jboss_add_risky_char_spec '#' 'シャープ' \
      '引用しないとシェルのコメント開始となり以降が捨てられる。jboss-cli のスクリプトと properties ファイルでも行コメントになる'
  jboss_add_risky_char_spec '\' 'バックスラッシュ' \
      'シェル・jboss-cli・properties ファイルのエスケープ文字。多段で解釈されて 1 個消える / 2 個に増える'
  jboss_add_risky_char_spec "'" 'シングルクォート' \
      'シェルの引用を終端させる。XML では &apos; となるため、生成側と読み出し側でエスケープの有無が食い違いやすい'
  jboss_add_risky_char_spec '&' 'アンパサンド' \
      'XML の実体参照の開始文字 (&amp; が必要)。引用漏れ時はシェルのバックグラウンド実行として解釈される'
  jboss_add_risky_char_spec '<' '小なり' \
      'XML では &lt; が必要。引用漏れ時はシェルの入力リダイレクトになる'
  jboss_add_risky_char_spec '>' '大なり' \
      'XML では &gt; が推奨。引用漏れ時はシェルの出力リダイレクトになり、ファイルを上書きする'
  jboss_add_risky_char_spec '%' 'パーセント' \
      'printf 系の書式指定として解釈されうる。Windows のバッチ経由で渡すと変数展開される'
  jboss_add_risky_char_spec '!' 'エクスクラメーション' \
      '対話 bash の履歴展開 (二重引用符の中でも展開される)。非対話実行では問題にならないため、手元での再現時のみ影響する'
  jboss_add_risky_char_spec ';' 'セミコロン' \
      '引用漏れ時にシェルのコマンド区切りになる'
  jboss_add_risky_char_spec '|' 'パイプ' \
      '引用漏れ時にシェルのパイプになる'
  jboss_add_risky_char_spec ',' 'カンマ' \
      'jboss-cli の操作構文 op(name=value,name2=value2) の引数区切り。引用しないと値が途中で切れる'
  jboss_add_risky_char_spec '=' 'イコール' \
      'jboss-cli の name=value と properties ファイルの区切り'
  jboss_add_risky_char_spec ':' 'コロン' \
      'jboss-cli のアドレスと操作の区切り (/subsystem=elytron:read-resource)'
  jboss_add_risky_char_spec '(' '左丸括弧' \
      'jboss-cli の操作引数の開始。引用漏れ時はシェルのサブシェルになる'
  jboss_add_risky_char_spec ')' '右丸括弧' \
      'jboss-cli の操作引数の終端。引用漏れ時はシェルの構文エラーになる'
}

# パスワードに含まれる危険文字を、実際に含まれるものだけ列挙する。
# 併せて空白・改行・CR・非 ASCII バイトの有無も判定する。
jboss_report_risky_characters() {
  local password="$1" spec risky_char char_name risk_note found_any="false"
  local hex byte code
  local has_space="false" has_tab="false" has_lf="false" has_cr="false" has_non_ascii="false" has_control="false"

  jboss_init_risky_char_specs
  diag "  [パスワード文字列のリスク分析]"
  diag "    バイト長  : $(jboss_password_byte_length "$password") バイト"
  diag "    可視化表記: $(jboss_password_visible "$password")"

  for spec in "${JBOSS_RISKY_CHAR_SPECS[@]}"; do
    IFS="$JBOSS_STAGE_SEPARATOR" read -r risky_char char_name risk_note <<< "$spec"
    case "$password" in
      *"$risky_char"*)
        found_any="true"
        diag "    - '${risky_char}' (${char_name}): ${risk_note}"
        ;;
    esac
  done

  hex="$(jboss_password_hex "$password")"
  for byte in $hex; do
    code=$((16#$byte))
    if [ "$code" -eq 32 ]; then
      has_space="true"
    elif [ "$code" -eq 9 ]; then
      has_tab="true"
    elif [ "$code" -eq 10 ]; then
      has_lf="true"
    elif [ "$code" -eq 13 ]; then
      has_cr="true"
    elif [ "$code" -lt 32 ] || [ "$code" -eq 127 ]; then
      has_control="true"
    elif [ "$code" -gt 127 ]; then
      has_non_ascii="true"
    fi
  done

  if [ "$has_space" = "true" ]; then
    found_any="true"
    diag "    - 空白 (0x20): 引用漏れで引数が分割される。先頭・末尾の空白はパラメータストアの登録時に混入しやすい"
  fi
  if [ "$has_tab" = "true" ]; then
    found_any="true"
    diag "    - タブ (0x09): aws ssm get-parameter --output text はタブ区切りで出力するため、値の一部が欠落しうる (--output json での確認を推奨)"
  fi
  if [ "$has_lf" = "true" ]; then
    found_any="true"
    diag "    - 改行 (0x0A): \$(cat /run/secrets/...) など、コマンド置換で末尾の改行が落ちる。CredentialStore へ登録した値とファイル上の値が 1 バイト違う原因になる"
  fi
  if [ "$has_cr" = "true" ]; then
    found_any="true"
    diag "    - CR (0x0D): CRLF 改行のファイルから読み込んだ際に混入する。画面では見えないため、一致しない原因として最も気付きにくい"
  fi
  if [ "$has_control" = "true" ]; then
    found_any="true"
    diag "    - 制御文字: XML の属性値に直接書けない (数値文字参照が必要) ため、standalone.xml 生成時に欠落・置換されうる"
  fi
  if [ "$has_non_ascii" = "true" ]; then
    found_any="true"
    diag "    - 非 ASCII バイト: ホストとコンテナの文字エンコーディング (UTF-8 / cp932 等) の差で化ける。JVM の -Dfile.encoding とも整合させる必要がある"
  fi

  if [ "$found_any" != "true" ]; then
    diag "    - 検出なし (英数字と、シェル・XML・WildFly 式のいずれでも意味を持たない文字のみで構成されています)"
  fi
}

# ---- 段ごとの検証結果の記録と表示 -------------------------------------------
# 1 段 = 「label / 判定 / 補足 / 実測値(base64) / 実測値を取得できたか」。
# 画面表示と全量レポートで同じ内容を使い回すため、いったん配列へ積む。
jboss_record_stage() {
  local label="$1" verdict="$2" note="$3" actual_b64="${4:-}" has_value="${5:-false}"
  JBOSS_PASSWORD_STAGE_RESULTS+=(
    "${label}${JBOSS_STAGE_SEPARATOR}${verdict}${JBOSS_STAGE_SEPARATOR}${note}${JBOSS_STAGE_SEPARATOR}${actual_b64}${JBOSS_STAGE_SEPARATOR}${has_value}"
  )
  case "$verdict" in
    不一致*) JBOSS_PASSWORD_MISMATCH="true" ;;
    未確認*) JBOSS_PASSWORD_UNKNOWN="true" ;;
  esac
}

# 実測値を原本と突き合わせて 1 段分を記録する。
# escaped_source を渡した場合は「ファイル上の表記」と「エスケープを戻した値」が
# 異なることを意味し、戻した値が一致していれば「一致 (エスケープ済み)」とする。
jboss_compare_stage() {
  local label="$1" actual="$2" note="${3:-}" escaped_source="${4:-}"
  local verdict detail
  if [ "$actual" = "$JBOSS_PASSWORD_ORIGIN" ]; then
    if [ -n "$escaped_source" ] && [ "$escaped_source" != "$actual" ]; then
      verdict="一致 (エスケープ済み)"
      detail="${note:+${note} / }ファイル上の表記: $(jboss_password_display "$escaped_source")"
    else
      verdict="一致"
      detail="$note"
    fi
  else
    verdict="不一致"
    detail="$note"
  fi
  jboss_record_stage "$label" "$verdict" "$detail" "$(jboss_b64_encode "$actual")" "true"
}

# 積んだ段の結果を画面へ出す。
# 一致した段は一致したパスワード文字列を、一致しない段は原本と実際の双方を
# 可視化表記・16 進ダンプ・最初の相違バイト位置とともに表示する。
jboss_print_stage_results() {
  local entry label verdict note actual_b64 has_value actual index=0
  local origin_display origin_hex

  origin_display="$(jboss_password_display "$JBOSS_PASSWORD_ORIGIN")"
  origin_hex="$(jboss_password_hex "$JBOSS_PASSWORD_ORIGIN")"

  for entry in "${JBOSS_PASSWORD_STAGE_RESULTS[@]}"; do
    index=$((index + 1))
    IFS="$JBOSS_STAGE_SEPARATOR" read -r label verdict note actual_b64 has_value <<< "$entry"
    diag ""
    diag "  [${verdict}] (${index}) ${label}"
    [ -n "$note" ] && diag "      補足    : ${note}"
    if [ "$has_value" != "true" ]; then
      continue
    fi
    jboss_read_exact actual jboss_b64_decode "$actual_b64"
    case "$verdict" in
      一致*)
        # 「一致していること」だけでなく、一致したパスワード文字列も必ず示す。
        diag "      一致した文字列: ${origin_display}"
        diag "      可視化表記    : $(jboss_password_visible "$actual")"
        diag "      16 進ダンプ   : ${origin_hex}"
        diag "      バイト長      : $(jboss_password_byte_length "$actual") バイト"
        ;;
      '不一致 (式が未解決)')
        # ファイル上の値が式のため、実効値は起動時にしか決まらない。
        # バイト列を突き合わせても意味が無いので、相違位置は出さない。
        diag "      原本 (取得元) : ${origin_display}"
        diag "        可視化表記  : $(jboss_password_visible "$JBOSS_PASSWORD_ORIGIN")"
        diag "        16 進ダンプ : ${origin_hex}"
        diag "      standalone.xml に設定されている文字列: $(jboss_password_display "$actual")"
        diag "        可視化表記  : $(jboss_password_visible "$actual")"
        diag "        16 進ダンプ : $(jboss_password_hex "$actual")"
        diag "      実行時の値    : \${...} の解決結果となるため、この文字列のままでは使われません"
        diag "      対処          : jboss-cli への登録時に \$ を \$\$ へエスケープしてください"
        diag "                      (例: pa\$word → clear-text=\"pa\$\$word\")"
        ;;
      不一致*)
        diag "      原本 (取得元) : ${origin_display}"
        diag "        可視化表記  : $(jboss_password_visible "$JBOSS_PASSWORD_ORIGIN")"
        diag "        16 進ダンプ : ${origin_hex}"
        diag "        バイト長    : $(jboss_password_byte_length "$JBOSS_PASSWORD_ORIGIN") バイト"
        diag "      実際に設定されている文字列: $(jboss_password_display "$actual")"
        diag "        可視化表記  : $(jboss_password_visible "$actual")"
        diag "        16 進ダンプ : $(jboss_password_hex "$actual")"
        diag "        バイト長    : $(jboss_password_byte_length "$actual") バイト"
        diag "      相違位置      : $(jboss_password_first_diff "$JBOSS_PASSWORD_ORIGIN" "$actual")"
        ;;
      *)
        diag "      取得した文字列: $(jboss_password_display "$actual")"
        diag "      可視化表記    : $(jboss_password_visible "$actual")"
        ;;
    esac
  done
}

# 検証結果の総括。1 段でも不一致があれば警告として目立たせる。
# 終了コードは変えない (ビルド成否の判定は従来どおり)。
jboss_print_stage_summary() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  if [ "$JBOSS_PASSWORD_MISMATCH" = "true" ]; then
    diag "  総合判定: 不一致あり — 上記の [不一致] の段で、原本と異なる文字列が設定されています。"
    diag "            表示された「実際に設定されている文字列」と 16 進ダンプを、"
    diag "            リスク分析に挙がった文字のエスケープ規則と突き合わせてください。"
  elif [ "$JBOSS_PASSWORD_UNKNOWN" = "true" ]; then
    diag "  総合判定: 確認できた段はすべて一致 (未確認の段あり)"
    diag "            [未確認] の段は、対象ファイル・コマンドが見つからないか、コンテナ未起動のため比較していません。"
  else
    diag "  総合判定: 全段一致 — 取得元から実行時に利用される値まで、同一のパスワード文字列です。"
    diag "            一致したパスワード文字列: $(jboss_password_display "$JBOSS_PASSWORD_ORIGIN")"
  fi
  diag "───────────────────────────────────────────────────────────────────"
  diag ""
}

# ---- compose.yml の展開 (JBoss シークレット / cwagent 設定の照合で共用) ------
# YAML のパスと値を awk で取り出し、
#   kv <パス> <値>      : key: value 形式
#   list <パス> <値>    : - value 形式のリスト要素
# として列挙する。第 2 引数で区切り文字を指定できる (既定は US)。
compose_yaml_entries() {
  local compose_file="$1" separator="${2:-$'\037'}"
  [ -f "$compose_file" ] || return 1
  awk -v SEP="$separator" '
    function path_string(   i, s) {
      s = ""
      for (i = 1; i <= depth; i++) s = s (i > 1 ? "." : "") stack[i]
      return s
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next
      match(line, /^[ ]*/)
      indent = RLENGTH
      content = substr(line, indent + 1)
      # インデントが浅くなった分だけ階層を畳む
      while (depth > 0 && indent <= indents[depth]) depth--
      if (content ~ /^- /) {
        item = substr(content, 3)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        gsub(/^["'"'"']|["'"'"']$/, "", item)
        sub(/[[:space:]]*#.*$/, "", item)
        printf "list%s%s%s%s\n", SEP, path_string(), SEP, item
        next
      }
      if (content ~ /^[^:]+:/) {
        key = content
        sub(/:.*$/, "", key)
        gsub(/^["'"'"']|["'"'"']$/, "", key)
        value = content
        sub(/^[^:]*:[[:space:]]*/, "", value)
        sub(/[[:space:]]+$/, "", value)
        gsub(/^["'"'"']|["'"'"']$/, "", value)
        depth++
        stack[depth] = key
        indents[depth] = indent
        if (value != "") printf "kv%s%s%s%s\n", SEP, path_string(), SEP, value
      }
    }
  ' "$compose_file"
}

verify_jboss_password_compose_definition() {
  local kind entry_path value secret_name
  local matched_secret="" mismatched_env="" file_secret="" build_services="" note=""
  local stage_label="compose.yml の secrets 定義 (BuildKit シークレットの入口)"
  local -a defined_env_secrets=()
  local -A build_refs_by_secret=()

  if [ ! -f "$COMPOSE_FILE" ]; then
    jboss_record_stage "$stage_label" "未確認" "compose.yml が見つかりません: ${COMPOSE_FILE}"
    return 0
  fi

  while IFS="$JBOSS_STAGE_SEPARATOR" read -r kind entry_path value; do
    [ -n "$kind" ] || continue
    case "$kind:$entry_path" in
      kv:secrets.*.environment)
        secret_name="${entry_path#secrets.}"
        secret_name="${secret_name%.environment}"
        defined_env_secrets+=("${secret_name} → ${value}")
        if [ "$value" = "$JBOSS_PASSWORD_ENV" ]; then
          matched_secret="$secret_name"
        elif [ "$secret_name" = "$JBOSS_SECRET_ID" ]; then
          mismatched_env="$value"
        fi
        ;;
      kv:secrets.*.file)
        secret_name="${entry_path#secrets.}"
        secret_name="${secret_name%.file}"
        [ "$secret_name" = "$JBOSS_SECRET_ID" ] && file_secret="$value"
        ;;
      list:services.*.build.secrets)
        # シークレット名ごとに、それをビルドで参照するサービス名を集める
        secret_name="${entry_path#services.}"
        secret_name="${secret_name%.build.secrets}"
        build_refs_by_secret["$value"]="${build_refs_by_secret[$value]:-}${secret_name} "
        ;;
    esac
  done < <(compose_yaml_entries "$COMPOSE_FILE" "$JBOSS_STAGE_SEPARATOR")

  if [ -n "$mismatched_env" ]; then
    jboss_record_stage "$stage_label" "不一致" \
        "secrets.${JBOSS_SECRET_ID}.environment は '${mismatched_env}' を参照していますが、パスワードを export しているのは '${JBOSS_PASSWORD_ENV}' です。ビルドには空の値が渡ります (--jboss-password-env と compose.yml を一致させてください)" \
        "$(jboss_b64_encode "")" "true"
    return 0
  fi

  if [ -n "$file_secret" ]; then
    jboss_record_stage "$stage_label" "未確認" \
        "secrets.${JBOSS_SECRET_ID} は file 型 (${file_secret}) で定義されています。ファイル経由のため環境変数の値は使われません。末尾改行の混入と \$ の展開に注意してください"
    return 0
  fi

  if [ -z "$matched_secret" ]; then
    jboss_record_stage "$stage_label" "不一致" \
        "環境変数 ${JBOSS_PASSWORD_ENV} を参照する environment 型シークレットが ${COMPOSE_FILE} にありません。secrets.<名前>.environment: ${JBOSS_PASSWORD_ENV} を定義してください。現在の定義: ${defined_env_secrets[*]:-(なし)}" \
        "$(jboss_b64_encode "")" "true"
    return 0
  fi

  build_services="${build_refs_by_secret[$matched_secret]:-}"
  if [ -z "$build_services" ]; then
    jboss_record_stage "$stage_label" "不一致" \
        "secrets.${matched_secret} は定義されていますが、どのサービスの build.secrets からも参照されていません。ビルド中に /run/secrets/${matched_secret} はマウントされません" \
        "$(jboss_b64_encode "")" "true"
    return 0
  fi

  note="secrets.${matched_secret}.environment: ${JBOSS_PASSWORD_ENV} / build.secrets で参照するサービス: ${build_services% }"
  # シークレット名と --jboss-secret-id がずれていると、後続のプローブビルドが
  # 実際の Dockerfile と違うマウント先を見てしまう。判定は環境変数の突き合わせの
  # ままとし、ずれていることは補足として必ず伝える。
  if [ "$matched_secret" != "$JBOSS_SECRET_ID" ]; then
    note="${note} / 注意: シークレット名 '${matched_secret}' が --jboss-secret-id '${JBOSS_SECRET_ID}' と異なります。Dockerfile は /run/secrets/${matched_secret} を参照するため、--jboss-secret-id ${matched_secret} を指定して検証してください"
  fi

  jboss_compare_stage "$stage_label" "${!JBOSS_PASSWORD_ENV:-}" "$note"
}

# aws ssm get-parameter --output text は、値をタブ区切りのテキストとして出力するため
# 末尾の空白・改行が落ち、タブが区切りと解釈されることがある。原本が壊れていないかを
# --output json の生の値と突き合わせて確認する。
verify_jboss_password_parameter_store_encoding() {
  local json_value decoder=""
  [ -n "$JBOSS_PASSWORD_PARAM" ] || return 0

  if command -v python3 >/dev/null 2>&1; then
    decoder="python3"
  elif command -v jq >/dev/null 2>&1; then
    decoder="jq"
  else
    jboss_record_stage "パラメータストアの生値との突き合わせ (--output text の欠落確認)" \
        "未確認" "python3 も jq も見つからないため、--output json の値と比較できません"
    return 0
  fi

  if [ "$decoder" = "python3" ]; then
    jboss_read_exact json_value jboss_ssm_value_via_python
  else
    jboss_read_exact json_value jboss_ssm_value_via_jq
  fi
  if [ -z "$json_value" ]; then
    jboss_record_stage "パラメータストアの生値との突き合わせ (--output text の欠落確認)" \
        "未確認" "aws ssm get-parameter --output json の取得に失敗しました"
    return 0
  fi

  jboss_compare_stage "パラメータストアの生値との突き合わせ (--output text の欠落確認)" \
      "$json_value" \
      "--output json で取得した生の値と、実際に使用している --output text の値を比較"
}

jboss_ssm_value_via_python() {
  aws ssm get-parameter --name "$JBOSS_PASSWORD_PARAM" --with-decryption \
      --region "$REGION" --output json 2>/dev/null \
    | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["Parameter"]["Value"])' 2>/dev/null
}

jboss_ssm_value_via_jq() {
  aws ssm get-parameter --name "$JBOSS_PASSWORD_PARAM" --with-decryption \
      --region "$REGION" --output json 2>/dev/null \
    | jq -j '.Parameter.Value' 2>/dev/null
}

# ビルド前に実行する段。取得元 → 環境変数 → compose.yml までを確認する。
verify_jboss_password_host_stages() {
  [ "$VERIFY_JBOSS_PASSWORD" = "true" ] || return 0

  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] JBoss マスターパスワードの伝搬検証をスキップします (実際の値を取得しないため比較できません)。"
    return 0
  fi
  if [ "$JBOSS_PASSWORD_ORIGIN_SET" != "true" ]; then
    warn "JBoss マスターパスワードの伝搬検証: 原本を取得できなかったため検証をスキップします。"
    return 0
  fi

  log "JBoss マスターパスワードの伝搬検証を開始します (取得元: ${JBOSS_PASSWORD_SOURCE_LABEL:-不明})。"

  diag ""
  diag "==================================================================="
  diag "JBoss マスターパスワードの伝搬検証"
  diag "  取得元        : ${JBOSS_PASSWORD_SOURCE_LABEL:-不明}"
  diag "  環境変数      : ${JBOSS_PASSWORD_ENV}"
  diag "  シークレット id: ${JBOSS_SECRET_ID} (ビルド中のマウント先: /run/secrets/${JBOSS_SECRET_ID})"
  diag "==================================================================="
  jboss_report_risky_characters "$JBOSS_PASSWORD_ORIGIN"

  # (1) 取得元 → export した環境変数
  jboss_compare_stage "取得元 → 環境変数 ${JBOSS_PASSWORD_ENV} (compose.yml へ渡る値)" \
      "${!JBOSS_PASSWORD_ENV:-}" \
      "取得元: ${JBOSS_PASSWORD_SOURCE_LABEL:-不明}"

  # (1-補足) パラメータストア利用時のみ、--output text による欠落を確認する
  verify_jboss_password_parameter_store_encoding

  # (2) compose.yml の secrets 定義
  verify_jboss_password_compose_definition
}

# ---- (3) BuildKit シークレットがビルド中コンテナへ届いた値の検証 ------------
# ビルド済みのローカルイメージをベースに、シークレットを読み出して base64 で
# 書き出すだけのプローブをビルドする。BuildKit はシークレットの内容をキャッシュ
# キーに含めないため、必ず --no-cache を付けて前回の結果を拾わないようにする。
# 出力は --output type=local で取り出し、イメージにもレイヤにも値を残さない。
jboss_write_probe_dockerfile() {
  local dockerfile="$1" base_image="$2" secret_id="$3"
  cat > "$dockerfile" <<EOF
# JBoss マスターパスワードの伝搬検証用プローブ (build_and_verify.sh が自動生成)。
# /run/secrets/${secret_id} の内容をそのまま符号化して取り出すだけで、
# 値をイメージへ焼き込むことはしない (最終ステージは scratch)。
FROM ${base_image} AS probe
# BuildKit はシークレットを uid=0 / mode=0400 でマウントする。JBoss EAP のイメージ
# のように既定の USER が非 root だと読み取れず、値が届いていても「マウントされて
# いない」と誤判定するため、プローブの実行ユーザーだけ root に戻す。
# 読み取るのはファイルの内容だけなので、実行ユーザーの違いは結果に影響しない。
USER root
RUN --mount=type=secret,id=${secret_id} \\
    mkdir -p /jboss-secret-probe && \\
    if [ -r /run/secrets/${secret_id} ]; then \\
      if command -v base64 >/dev/null 2>&1; then \\
        printf 'base64' > /jboss-secret-probe/encoding && \\
        base64 < /run/secrets/${secret_id} | tr -d '\\n' > /jboss-secret-probe/value; \\
      elif command -v od >/dev/null 2>&1; then \\
        printf 'hex' > /jboss-secret-probe/encoding && \\
        od -An -v -tx1 < /run/secrets/${secret_id} | tr -d ' \\n' > /jboss-secret-probe/value; \\
      else \\
        printf 'unsupported' > /jboss-secret-probe/encoding && \\
        : > /jboss-secret-probe/value; \\
      fi; \\
    else \\
      printf 'missing' > /jboss-secret-probe/encoding && \\
      : > /jboss-secret-probe/value; \\
    fi
FROM scratch
COPY --from=probe /jboss-secret-probe/ /
EOF
}

verify_jboss_password_build_secret() {
  local probe_dir context_dir dockerfile output_dir build_log encoding encoded actual
  local stage_label="BuildKit シークレット → ビルド中コンテナの /run/secrets/${JBOSS_SECRET_ID}"

  [ "$VERIFY_JBOSS_PASSWORD" = "true" ] || return 0
  [ "$JBOSS_PASSWORD_ORIGIN_SET" = "true" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] BuildKit シークレットの到達値を確認するプローブビルドをスキップします。"
    return 0
  fi

  if ! probe_dir="$(mktemp -d 2>/dev/null)"; then
    jboss_record_stage "$stage_label" "未確認" "プローブビルド用の一時ディレクトリを作成できませんでした"
    return 0
  fi
  # 取り出し先はビルドコンテキストの外に置き、コンテキストへ余計なファイルを
  # 含めない (プローブは Dockerfile 以外のファイルを一切必要としない)。
  context_dir="${probe_dir}/ctx"
  output_dir="${probe_dir}/out"
  dockerfile="${context_dir}/Dockerfile"
  build_log="${probe_dir}/build.log"
  mkdir -p "$context_dir" "$output_dir"
  jboss_write_probe_dockerfile "$dockerfile" "$LOCAL_IMAGE" "$JBOSS_SECRET_ID"

  log "BuildKit シークレットの到達値を確認します (プローブビルド: ${LOCAL_IMAGE} ベース, --no-cache) ..."
  if ! DOCKER_BUILDKIT=1 docker build --no-cache \
        --secret "id=${JBOSS_SECRET_ID},env=${JBOSS_PASSWORD_ENV}" \
        --file "$dockerfile" \
        --output "type=local,dest=${output_dir}" \
        "$context_dir" >"$build_log" 2>&1; then
    jboss_record_stage "$stage_label" "未確認" \
        "プローブビルドに失敗しました (docker build --secret / --output type=local が使えない環境の可能性があります)。詳細: $(tail -n 3 "$build_log" 2>/dev/null | tr '\n' ' ')"
    rm -rf -- "$probe_dir"
    return 0
  fi

  if [ ! -f "${output_dir}/encoding" ]; then
    jboss_record_stage "$stage_label" "未確認" "プローブビルドの出力を取り出せませんでした"
    rm -rf -- "$probe_dir"
    return 0
  fi
  encoding="$(cat "${output_dir}/encoding" 2>/dev/null)"
  encoded="$(cat "${output_dir}/value" 2>/dev/null)"

  case "$encoding" in
    base64)
      jboss_read_exact actual jboss_b64_decode "$encoded"
      ;;
    hex)
      jboss_read_exact actual jboss_hex_decode "$encoded"
      ;;
    missing)
      jboss_record_stage "$stage_label" "不一致" \
          "ビルド中に /run/secrets/${JBOSS_SECRET_ID} が存在しませんでした。compose.yml の build.secrets 参照と、Dockerfile の RUN --mount=type=secret,id=${JBOSS_SECRET_ID} を確認してください" \
          "$(jboss_b64_encode "")" "true"
      rm -rf -- "$probe_dir"
      return 0
      ;;
    *)
      jboss_record_stage "$stage_label" "未確認" \
          "ベースイメージに base64 も od も無いため、シークレットの内容を取り出せませんでした"
      rm -rf -- "$probe_dir"
      return 0
      ;;
  esac

  jboss_compare_stage "$stage_label" "$actual" \
      "プローブビルド (--no-cache) でマウント内容をそのまま取得。Dockerfile 側で \$(cat /run/secrets/...) を使うと、ここで一致していても末尾の改行が落ちる点に注意"
  rm -rf -- "$probe_dir"
}

# ---- (4)(5)(6) コンテナ内の Elytron / standalone.xml の検証 -----------------
# コンテナ内でシェルを開き、標準出力をそのまま (末尾の改行も落とさずに) 取り込む。
jboss_container_exec() {
  local cid="$1" script="$2"
  shift 2
  docker exec "$cid" /bin/sh -c "$script" _ "$@" 2>/dev/null
}

# コンテナ内のファイルを base64 で取り出す (XML の改行・エンコーディングを保つ)。
jboss_container_read_file() {
  local cid="$1" path="$2"
  jboss_container_exec "$cid" '[ -f "$1" ] && base64 < "$1" | tr -d "\n"' "$path"
}

# JBoss のインストール先を特定する。JBOSS_HOME / JBOSS_EAP_HOME を優先し、
# 無ければ既定の候補から bin と standalone を持つディレクトリを探す。
jboss_detect_home() {
  local cid="$1"
  jboss_container_exec "$cid" '
    for candidate in "${JBOSS_HOME:-}" "${JBOSS_EAP_HOME:-}" "$@"; do
      [ -n "$candidate" ] || continue
      if [ -d "$candidate/bin" ] && [ -d "$candidate/standalone" ]; then
        printf "%s" "$candidate"
        exit 0
      fi
    done
    exit 1
  ' "${JBOSS_HOME_CANDIDATES[@]}"
}

# 起動中のサーバーが実際に読み込んだ設定ファイル名を、Java プロセスの
# コマンドライン (-c NAME / --server-config=NAME) から特定する。
# 既定以外の設定 (standalone-full.xml 等) で起動している場合に、
# 誤ったファイルを比較して「不一致」と誤判定しないために必要。
jboss_detect_running_config_name() {
  local cid="$1" cmdline previous="" argument
  cmdline="$(jboss_container_exec "$cid" '
    for proc_dir in /proc/[0-9]*; do
      [ -r "$proc_dir/cmdline" ] || continue
      line=$(tr "\0" "\n" < "$proc_dir/cmdline" | tr "\n" " ")
      case "$line" in
        *jboss-modules.jar*) printf "%s" "$line"; exit 0 ;;
      esac
    done
    exit 1
  ')"
  [ -n "$cmdline" ] || return 1
  for argument in $cmdline; do
    case "$argument" in
      --server-config=*)
        printf '%s' "${argument#--server-config=}"
        return 0
        ;;
      -c)
        previous="config"
        continue
        ;;
    esac
    if [ "$previous" = "config" ]; then
      printf '%s' "$argument"
      return 0
    fi
    previous=""
  done
  return 1
}

# 比較対象の standalone.xml を決める。--jboss-config-file が最優先。
jboss_detect_config_file() {
  local cid="$1" home="$2" running_name=""
  if [ -n "$JBOSS_CONFIG_FILE" ]; then
    printf '%s' "$JBOSS_CONFIG_FILE"
    return 0
  fi
  [ -n "$home" ] || return 1
  running_name="$(jboss_detect_running_config_name "$cid")"
  jboss_container_exec "$cid" '
    home="$1"
    running="$2"
    if [ -n "$running" ] && [ -f "$home/standalone/configuration/$running" ]; then
      printf "%s" "$home/standalone/configuration/$running"
      exit 0
    fi
    for name in standalone.xml standalone-full.xml standalone-ha.xml standalone-full-ha.xml; do
      if [ -f "$home/standalone/configuration/$name" ]; then
        printf "%s" "$home/standalone/configuration/$name"
        exit 0
      fi
    done
    exit 1
  ' "$home" "$running_name"
}

# standalone.xml から、要素のパスと属性を取り出す。
# 出力 1 行 = attr<SEP><要素の通し番号><SEP><要素パス><SEP><属性名><SEP><属性値>
# 属性値は XML エスケープされたままの「ファイル上の表記」を返す。
# コメント内の < > に引きずられないよう、先に <!-- --> を取り除く。
jboss_xml_attributes() {
  local xml_file="$1"
  awk '
    BEGIN { RS = "-->"; ORS = "" }
    {
      text = $0
      start = 1
      last = 0
      while ((found = index(substr(text, start), "<!--")) > 0) {
        last = start + found - 1
        start = last + 4
      }
      if (last > 0) text = substr(text, 1, last - 1)
      print text
    }
  ' "$xml_file" \
  | awk -v SEP="$JBOSS_STAGE_SEPARATOR" '
    function attr_value(tag, key,   pattern, rest, quote, position) {
      pattern = "(^|[ \t\r\n])" key "[ \t]*="
      if (!match(tag, pattern)) return ABSENT
      rest = substr(tag, RSTART + RLENGTH)
      sub(/^[ \t]*/, "", rest)
      quote = substr(rest, 1, 1)
      if (quote != "\"" && quote != "'"'"'") return ABSENT
      rest = substr(rest, 2)
      position = index(rest, quote)
      if (position == 0) return ABSENT
      return substr(rest, 1, position - 1)
    }
    function path_string(   i, s) {
      s = ""
      for (i = 1; i <= depth; i++) s = s (i > 1 ? "." : "") stack[i]
      return s
    }
    BEGIN {
      RS = "<"
      ABSENT = "\002"
      depth = 0
      element_index = 0
      key_count = split("name clear-text store alias path relative-to type pool-name jndi-name", keys, " ")
    }
    {
      record = $0
      if (record == "") next
      close_position = index(record, ">")
      if (close_position == 0) next
      tag = substr(record, 1, close_position - 1)
      if (tag == "") next
      first = substr(tag, 1, 1)
      if (first == "/") { if (depth > 0) depth--; next }
      if (first == "?" || first == "!") next
      element_name = tag
      sub(/[ \t\r\n\/].*$/, "", element_name)
      if (element_name == "") next
      self_closing = (substr(tag, length(tag), 1) == "/")
      depth++
      stack[depth] = element_name
      element_index++
      for (i = 1; i <= key_count; i++) {
        value = attr_value(tag, keys[i])
        if (value != ABSENT) {
          printf "attr%s%s%s%s%s%s%s%s\n", SEP, element_index, SEP, path_string(), SEP, keys[i], SEP, value
        }
      }
      if (self_closing) depth--
    }
  '
}

# XML の実体参照を戻す。standalone.xml の属性値は & < > " '"'"' が必ずエスケープ
# されるため、ファイル上の表記のまま比較すると必ず不一致になる。
# 出力は変数へ直接入れる (コマンド置換だと末尾の改行が落ちるため)。
jboss_xml_unescape() {
  local _target_var="$1" value="$2"
  local result="" rest="$value" head entity code decoded
  while [ -n "$rest" ]; do
    head="${rest:0:1}"
    if [ "$head" != '&' ]; then
      result+="$head"
      rest="${rest:1}"
      continue
    fi
    entity="${rest%%;*}"
    if [ "$entity" = "$rest" ]; then
      # 対応する ; が無いため実体参照ではない
      result+="$head"
      rest="${rest:1}"
      continue
    fi
    rest="${rest#*;}"
    entity="${entity:1}"
    case "$entity" in
      amp)  result+='&' ;;
      lt)   result+='<' ;;
      gt)   result+='>' ;;
      quot) result+='"' ;;
      apos) result+="'" ;;
      '#x'*|'#X'*)
        code="${entity:2}"
        if printf '%s' "$code" | grep -qE '^[0-9a-fA-F]+$'; then
          printf -v decoded '%b' "\\u$(printf '%04X' "$((16#$code))")"
          result+="$decoded"
        else
          result+="&${entity};"
        fi
        ;;
      '#'*)
        code="${entity:1}"
        if printf '%s' "$code" | grep -qE '^[0-9]+$'; then
          printf -v decoded '%b' "\\u$(printf '%04X' "$code")"
          result+="$decoded"
        else
          result+="&${entity};"
        fi
        ;;
      *)
        # 未知の実体参照はそのまま残す
        result+="&${entity};"
        ;;
    esac
  done
  printf -v "$_target_var" '%s' "$result"
}

# WildFly が属性値を解釈した結果 (実行時に利用される値) を求める。
#   $$    → リテラルの $
#   ${..} → 起動時にシステムプロパティ / 環境変数として解決される式
# パスワードに $ を含む場合、jboss-cli 側で $$ へエスケープしていないと
# WildFly が式として解決しようとするため、ここで検出する。
JBOSS_WILDFLY_EXPRESSION_FOUND="false"
jboss_wildfly_literal() {
  local _target_var="$1" value="$2"
  local result="" index=0 length=${#2} current next
  JBOSS_WILDFLY_EXPRESSION_FOUND="false"
  while [ "$index" -lt "$length" ]; do
    current="${value:index:1}"
    if [ "$current" = '$' ]; then
      next="${value:index+1:1}"
      if [ "$next" = '$' ]; then
        result+='$'
        index=$((index + 2))
        continue
      fi
      if [ "$next" = '{' ]; then
        JBOSS_WILDFLY_EXPRESSION_FOUND="true"
      fi
    fi
    result+="$current"
    index=$((index + 1))
  done
  printf -v "$_target_var" '%s' "$result"
}

# credential-store の path / relative-to から、コンテナ内の実ファイルパスを組み立てる。
jboss_resolve_credential_store_path() {
  local home="$1" store_path="$2" relative_to="$3" base=""
  [ -n "$store_path" ] || return 1
  case "$store_path" in
    /*) printf '%s' "$store_path"; return 0 ;;
  esac
  case "$relative_to" in
    jboss.server.config.dir) base="${home}/standalone/configuration" ;;
    jboss.server.data.dir)   base="${home}/standalone/data" ;;
    jboss.server.base.dir)   base="${home}/standalone" ;;
    jboss.home.dir)          base="$home" ;;
    '')                      base="${home}/standalone/configuration" ;;
    *)                       return 1 ;;
  esac
  printf '%s/%s' "$base" "$store_path"
}

# CredentialStore を原本パスワードで実際に開けるかを確認する。
# パスワードはコマンドラインではなく標準入力から base64 で渡し、
# ホスト側の ps とコンテナの環境変数の双方に平文を残さない。
jboss_open_credential_store() {
  local cid="$1" tool="$2" store_path="$3" password_b64="$4"
  printf '%s' "$password_b64" | docker exec -i "$cid" /bin/sh -c '
    tool="$1"
    store="$2"
    encoded=$(cat)
    # base64 -d の出力を末尾の改行ごと保つ (パスワード末尾の改行を落とさない)
    password=$(printf "%s" "$encoded" | base64 -d; printf x)
    password=${password%x}
    "$tool" credential-store --location "$store" --password "$password" --aliases 2>&1
  ' _ "$tool" "$store_path" 2>/dev/null
}

# standalone.xml を解析し、credential-store のパスワード定義と、その値を利用する
# リソースを取り出して段ごとに記録する。
jboss_verify_config_file_stages() {
  local cid="$1" home="$2" config_file="$3" xml_b64="$4"
  local xml_file entry kind index element_path attr_name attr_value
  local store_index="" store_name="" store_path="" store_relative_to=""
  local reference_raw="" reference_found="false"
  local unescaped="" literal="" resource_name parent_path parent_index usage_text
  local -A element_path_by_index=()
  local -A attribute_by_key=()
  local -A last_index_by_path=()
  local -a element_indexes=()
  local -a usage_lines=()

  if ! xml_file="$(mktemp 2>/dev/null)"; then
    jboss_record_stage "standalone.xml の解析" "未確認" "一時ファイルを作成できませんでした"
    return 0
  fi
  if ! jboss_b64_decode "$xml_b64" > "$xml_file"; then
    rm -f -- "$xml_file"
    jboss_record_stage "standalone.xml の解析" "未確認" "設定ファイルを取り出せませんでした: ${config_file}"
    return 0
  fi

  while IFS="$JBOSS_STAGE_SEPARATOR" read -r kind index element_path attr_name attr_value; do
    [ "$kind" = "attr" ] || continue
    if [ -z "${element_path_by_index[$index]+_}" ]; then
      element_path_by_index["$index"]="$element_path"
      element_indexes+=("$index")
    fi
    attribute_by_key["${index}|${attr_name}"]="$attr_value"
  done < <(jboss_xml_attributes "$xml_file")
  rm -f -- "$xml_file"

  if [ ${#element_indexes[@]} -eq 0 ]; then
    jboss_record_stage "standalone.xml の解析" "未確認" \
        "設定ファイルから要素を読み取れませんでした: ${config_file}"
    return 0
  fi

  # 文書順に走査し、credential-store とその直下の credential-reference を特定する。
  # 併せて、各要素パスで最後に現れた要素を覚えておき、利用箇所を表示する際に
  # 親要素 (datasource など) の名前を引けるようにする。同じパスの要素が複数ある
  # 場合、文書順で直前のものが常にその時点の祖先になる。
  for index in "${element_indexes[@]}"; do
    element_path="${element_path_by_index[$index]}"
    last_index_by_path["$element_path"]="$index"
    case "$element_path" in
      *.credential-store|credential-store)
        store_index="$index"
        store_name="${attribute_by_key["${index}|name"]:-(名前なし)}"
        store_path="${attribute_by_key["${index}|path"]:-}"
        store_relative_to="${attribute_by_key["${index}|relative-to"]:-}"
        ;;
      *.credential-store.credential-reference)
        if [ -n "$store_index" ] && [ "$reference_found" != "true" ]; then
          if [ -n "${attribute_by_key["${index}|clear-text"]+_}" ]; then
            reference_raw="${attribute_by_key["${index}|clear-text"]}"
            reference_found="true"
          fi
        fi
        ;;
      *.credential-reference)
        # 直近の親要素 (security / datasource 等) から、リソースを識別できる
        # 属性を name → pool-name → jndi-name の順に探す。
        parent_path="${element_path%.*}"
        resource_name="(名前なし)"
        while [ -n "$parent_path" ]; do
          parent_index="${last_index_by_path[$parent_path]:-}"
          if [ -n "$parent_index" ]; then
            if [ -n "${attribute_by_key["${parent_index}|name"]:-}" ]; then
              resource_name="${attribute_by_key["${parent_index}|name"]}"
              break
            elif [ -n "${attribute_by_key["${parent_index}|pool-name"]:-}" ]; then
              resource_name="${attribute_by_key["${parent_index}|pool-name"]}"
              break
            elif [ -n "${attribute_by_key["${parent_index}|jndi-name"]:-}" ]; then
              resource_name="${attribute_by_key["${parent_index}|jndi-name"]}"
              break
            fi
          fi
          [ "$parent_path" = "${parent_path%.*}" ] && break
          parent_path="${parent_path%.*}"
        done
        if [ -n "${attribute_by_key["${index}|store"]+_}" ]; then
          usage_lines+=("${element_path} (リソース: ${resource_name}) → store=${attribute_by_key["${index}|store"]}, alias=${attribute_by_key["${index}|alias"]:-(未指定)}")
        elif [ -n "${attribute_by_key["${index}|clear-text"]+_}" ]; then
          usage_lines+=("${element_path} (リソース: ${resource_name}) → clear-text を直接記述 (CredentialStore を経由していません)")
        fi
        ;;
    esac
  done

  if [ -z "$store_index" ]; then
    jboss_record_stage "standalone.xml の credential-store 定義 (${config_file})" \
        "未確認" "Elytron の credential-store 定義が見つかりませんでした。jboss-cli による生成がまだ行われていない可能性があります"
    return 0
  fi

  if [ "$reference_found" != "true" ]; then
    jboss_record_stage "standalone.xml の credential-store 定義 (${config_file})" \
        "未確認" "credential-store '${store_name}' に clear-text 属性がありません (マスターパスワードを別の方式で渡している構成です)"
  else
    # (4) ファイル上の表記そのもの。エスケープの有無を目で確かめられるようにする。
    jboss_record_stage \
        "standalone.xml のマスターパスワード定義 (ファイル上の表記 / credential-store '${store_name}')" \
        "情報" "jboss-cli が書き込んだ clear-text 属性の生の文字列。XML の実体参照と WildFly の \$\$ エスケープが含まれうる" \
        "$(jboss_b64_encode "$reference_raw")" "true"

    # (5) XML の実体参照を戻し、さらに WildFly の式解釈を適用した「実行時の値」。
    jboss_xml_unescape unescaped "$reference_raw"
    jboss_wildfly_literal literal "$unescaped"
    if [ "$JBOSS_WILDFLY_EXPRESSION_FOUND" = "true" ]; then
      case "$JBOSS_PASSWORD_ORIGIN" in
        *'$'*)
          jboss_record_stage \
              "standalone.xml → WildFly が実行時に解釈する値 (利用される値)" \
              "不一致 (式が未解決)" \
              "clear-text に未解決の \${...} 式が残っています。マスターパスワードに \$ が含まれるため、jboss-cli への登録時に \$ を \$\$ へエスケープできていない可能性が高いです。WildFly は起動時にこの式をシステムプロパティ / 環境変数として解決するため、実行時に使われる値はファイル上の文字列とは異なります" \
              "$(jboss_b64_encode "$literal")" "true"
          ;;
        *)
          jboss_record_stage \
              "standalone.xml → WildFly が実行時に解釈する値 (利用される値)" \
              "未確認" \
              "clear-text が \${...} 式のため、静的には実効値を決定できません (起動時にシステムプロパティ / 環境変数から解決されます): $(jboss_password_display "$unescaped")"
          ;;
      esac
    else
      jboss_compare_stage \
          "standalone.xml → WildFly が実行時に解釈する値 (利用される値)" \
          "$literal" \
          "XML の実体参照と WildFly の \$\$ エスケープを戻した結果" \
          "$reference_raw"
    fi
  fi

  # (6) CredentialStore を原本パスワードで実際に開けるか (実効確認)
  jboss_verify_credential_store_stage "$cid" "$home" "$store_name" "$store_path" "$store_relative_to"

  # (7) マスターパスワードで守られた値の利用箇所 (情報表示)
  if [ ${#usage_lines[@]} -gt 0 ]; then
    usage_text="$(printf '%s ; ' "${usage_lines[@]}")"
    jboss_record_stage "CredentialStore の値を利用している箇所 (${#usage_lines[@]} 件)" "情報" \
        "${usage_text% ; }"
  else
    jboss_record_stage "CredentialStore の値を利用している箇所" "情報" \
        "credential-reference で store / alias を参照しているリソースはありません"
  fi
}

# CredentialStore ファイルを原本パスワードで開けるかどうかを確かめる。
# 開ければ「CredentialStore に設定されているマスターパスワード = 原本」と言える。
jboss_verify_credential_store_stage() {
  local cid="$1" home="$2" store_name="$3" store_path="$4" store_relative_to="$5"
  local resolved_store tool_path output status
  local stage_label="Elytron CredentialStore をマスターパスワードで開けるか (credential-store '${store_name}')"

  if [ -n "$JBOSS_CREDENTIAL_STORE_FILE" ]; then
    resolved_store="$JBOSS_CREDENTIAL_STORE_FILE"
  elif ! resolved_store="$(jboss_resolve_credential_store_path "$home" "$store_path" "$store_relative_to")"; then
    jboss_record_stage "$stage_label" "未確認" \
        "CredentialStore のパスを特定できませんでした (path=${store_path:-(未設定)}, relative-to=${store_relative_to:-(未設定)})。--jboss-credential-store で指定してください"
    return 0
  fi

  if [ -n "$JBOSS_ELYTRON_TOOL_PATH" ]; then
    tool_path="$JBOSS_ELYTRON_TOOL_PATH"
  else
    tool_path="${home}/bin/elytron-tool.sh"
  fi

  if ! jboss_container_exec "$cid" '[ -x "$1" ]' "$tool_path"; then
    jboss_record_stage "$stage_label" "未確認" \
        "elytron-tool.sh が見つかりません: ${tool_path} (--jboss-elytron-tool で指定できます)"
    return 0
  fi
  if ! jboss_container_exec "$cid" '[ -f "$1" ]' "$resolved_store"; then
    jboss_record_stage "$stage_label" "未確認" \
        "CredentialStore ファイルが見つかりません: ${resolved_store}"
    return 0
  fi

  output="$(jboss_open_credential_store "$cid" "$tool_path" "$resolved_store" \
      "$(jboss_b64_encode "$JBOSS_PASSWORD_ORIGIN")")"
  status=$?
  if [ "$status" -eq 0 ]; then
    jboss_record_stage "$stage_label" "一致" \
        "${resolved_store} を原本パスワードで開けました。CredentialStore に設定されているマスターパスワードは原本と同一です。登録エイリアス: $(printf '%s' "$output" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/ $//')" \
        "$(jboss_b64_encode "$JBOSS_PASSWORD_ORIGIN")" "true"
  else
    # CredentialStore は鍵ストアであり、設定済みのマスターパスワードそのものを
    # 取り出す手段は無い (取り出せてしまえば保護の意味が無い)。
    # 実際に設定されている文字列は、standalone.xml の段の表示で確認する。
    jboss_record_stage "$stage_label" "不一致" \
        "${resolved_store} を原本パスワードで開けませんでした。CredentialStore の作成時に、原本とは異なる文字列が使われています (シェルの変数展開・コメント切り捨て・エスケープ差が疑われます)。CredentialStore からは設定済みのパスワードを取り出せないため、実際に設定されている文字列は standalone.xml の段の表示を参照してください。elytron-tool の出力: $(printf '%s' "$output" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/ $//')"
  fi
}

# コンテナ起動後に実行する段。standalone.xml と CredentialStore を確認する。
verify_jboss_password_container_stages() {
  local cid service_name home config_file xml_b64 checked="false"
  local -a target_container_ids=()

  [ "$VERIFY_JBOSS_PASSWORD" = "true" ] || return 0
  [ "$JBOSS_PASSWORD_ORIGIN_SET" = "true" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] standalone.xml / CredentialStore の検証をスキップします。"
    return 0
  fi

  mapfile -t target_container_ids < <(verification_target_container_ids)
  if [ ${#target_container_ids[@]} -eq 0 ]; then
    jboss_record_stage "standalone.xml / Elytron CredentialStore の検証" "未確認" \
        "対象コンテナが起動していないため確認できません (--verify-startup または --verify-url を併用してください)"
    return 0
  fi

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"

    home="$(jboss_detect_home "$cid")"
    if [ -z "$home" ] && [ -z "$JBOSS_CONFIG_FILE" ]; then
      continue
    fi
    if ! config_file="$(jboss_detect_config_file "$cid" "$home")" || [ -z "$config_file" ]; then
      continue
    fi
    xml_b64="$(jboss_container_read_file "$cid" "$config_file")"
    if [ -z "$xml_b64" ]; then
      jboss_record_stage "standalone.xml の読み出し (サービス: ${service_name})" "未確認" \
          "設定ファイルを読み出せませんでした: ${config_file}"
      checked="true"
      continue
    fi
    log "standalone.xml を確認します (サービス: ${service_name}, ファイル: ${config_file}) ..."
    jboss_verify_config_file_stages "$cid" "$home" "$config_file" "$xml_b64"
    checked="true"
  done

  if [ "$checked" != "true" ]; then
    jboss_record_stage "standalone.xml / Elytron CredentialStore の検証" "未確認" \
        "起動中のコンテナから JBoss のインストール先と standalone.xml を特定できませんでした (--jboss-config-file で指定できます)"
  fi
}

# 伝搬検証の結果をまとめて画面へ出す。ビルドのみの場合はビルド直後に、
# 起動確認を伴う場合は起動後の確認出力と並べて呼び出す。
show_verified_jboss_password_stages() {
  [ "$VERIFY_JBOSS_PASSWORD" = "true" ] || return 0
  [ ${#JBOSS_PASSWORD_STAGE_RESULTS[@]} -gt 0 ] || return 0
  diag ""
  diag "==================================================================="
  diag "JBoss マスターパスワードの伝搬検証結果 (${#JBOSS_PASSWORD_STAGE_RESULTS[@]} 段)"
  diag "==================================================================="
  jboss_print_stage_results
  jboss_print_stage_summary
  if [ "$JBOSS_PASSWORD_MISMATCH" = "true" ]; then
    warn "JBoss マスターパスワードの伝搬検証で不一致を検出しました (上記を参照)。"
  else
    log "JBoss マスターパスワードの伝搬検証が完了しました (不一致なし)。"
  fi
}

# ---- ビルド前後の一時ファイルコピー / 自動削除 ------------------------------
# --copy-file で指定した SRC:DEST_DIR を検証し、SRC を DEST_DIR へコピーする。
# コピーしたコピー先パスは COPIED_FILES に記録し、EXIT トラップで自動削除する。
#
# コピー先に同名ファイルが既にある場合の動作:
#   既定                      強制上書きする。ただし処理終了時の自動削除で元ファイルを
#                             失わないよう、上書き前のファイルを退避しておき、削除では
#                             なく復元することでコピー先を実行前の状態へ戻す。
#   --copy-file-no-overwrite  上書きせず中止する (既存ファイルへ一切触れない)。

# 上書き前ファイルの退避先ディレクトリを (初回のみ) 作成する。
ensure_copy_backup_dir() {
  [ -n "$COPY_BACKUP_DIR" ] && return 0
  if ! COPY_BACKUP_DIR="$(mktemp -d 2>/dev/null)"; then
    COPY_BACKUP_DIR=""
    err "上書き前ファイルの退避先ディレクトリを作成できませんでした"
    return 1
  fi
  return 0
}

prepare_copy_files() {
  [ ${#COPY_SPECS[@]} -eq 0 ] && return 0
  log "ビルド前の一時ファイルコピーを実行します (${#COPY_SPECS[@]} 件) ..."
  if [ "$COPY_OVERWRITE" = "true" ]; then
    log "コピー先に同名ファイルがある場合は強制上書きします (上書き前のファイルは処理終了時に復元します)。"
  else
    log "コピー先に同名ファイルがある場合は中止します (--copy-file-no-overwrite)。"
  fi
  local spec src dest_dir dest backup
  for spec in "${COPY_SPECS[@]}"; do
    # 最初の ':' で SRC と DEST_DIR に分割する (':' が無ければ書式エラー)
    if [ "${spec%%:*}" = "$spec" ]; then
      err "--copy-file の書式が不正です: '$spec' (SRC:DEST_DIR 形式で指定してください)"
      exit 2
    fi
    src="${spec%%:*}"
    dest_dir="${spec#*:}"
    if [ -z "$src" ] || [ -z "$dest_dir" ]; then
      err "--copy-file の書式が不正です: '$spec' (SRC / DEST_DIR が空です)"
      exit 2
    fi
    if [ ! -f "$src" ]; then
      err "コピー元ファイルが見つかりません: $src"
      exit 1
    fi
    if [ ! -d "$dest_dir" ]; then
      err "コピー先ディレクトリが存在しません: $dest_dir"
      exit 1
    fi
    dest="${dest_dir%/}/$(basename "$src")"
    backup=""
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      # 通常ファイル以外 (ディレクトリ / シンボリックリンク / 特殊ファイル) は、
      # 上書きも自動削除も別の実体を壊しうるため、指定によらず常に中止する。
      if [ -L "$dest" ] || [ ! -f "$dest" ]; then
        err "コピー先が通常ファイルではありません: $dest (上書き・自動削除とも行わないため中止します)"
        exit 1
      fi
      if [ "$COPY_OVERWRITE" != "true" ]; then
        err "コピー先に同名ファイルが既に存在します: $dest (--copy-file-no-overwrite が指定されているため中止します)"
        exit 1
      fi
      if [ "$DRY_RUN" = "true" ]; then
        # dry-run では実退避を行わないため、復元プレビュー用にマーカーだけ記録する
        backup="$COPY_BACKUP_DRY_RUN_MARK"
        log "[DRY-RUN] 既存ファイルを退避して強制上書き: $dest (処理後に退避したファイルを復元)"
      else
        ensure_copy_backup_dir || exit 1
        # 同名のコピー先が複数あっても衝突しないよう、記録順の連番を前置する
        backup="${COPY_BACKUP_DIR}/${#COPIED_FILES[@]}.$(basename "$dest")"
        # 復元時にパーミッション / タイムスタンプまで元へ戻すため -p を付ける
        if ! cp -p "$dest" "$backup"; then
          err "上書き前ファイルの退避に失敗しました: $dest -> $backup"
          exit 1
        fi
        warn "コピー先の既存ファイルを強制上書きします: $dest (退避先: $backup、処理終了時に復元します)"
      fi
    fi
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] cp $src -> $dest (処理後に自動削除)"
    else
      if ! cp "$src" "$dest"; then
        err "ファイルのコピーに失敗しました: $src -> $dest"
        # 退避済みなら、コピー先が壊れている可能性があるため EXIT トラップで復元させる
        if [ -n "$backup" ]; then
          COPIED_FILES+=("$dest")
          COPIED_BACKUPS+=("$backup")
        fi
        exit 1
      fi
      log "コピーしました: $src -> $dest"
    fi
    # dry-run でも記録し、削除プレビューを表示できるようにする
    COPIED_FILES+=("$dest")
    COPIED_BACKUPS+=("$backup")
  done
}

# コピーしたファイルのみ後始末する (EXIT トラップから呼び出す)。
# 強制上書きした分は削除せず、退避しておいた上書き前のファイルを復元する。
cleanup_copied_files() {
  [ ${#COPIED_FILES[@]} -eq 0 ] && return 0
  log "コピーした一時ファイルを後始末します (${#COPIED_FILES[@]} 件) ..."
  local i f backup
  # 同じコピー先を複数回上書きした場合に元へ戻せるよう、記録と逆順 (後入れ先出し) で
  # 巻き戻す。正順だと最後の復元で「上書き後の内容」が残ってしまう。
  for (( i = ${#COPIED_FILES[@]} - 1; i >= 0; i-- )); do
    f="${COPIED_FILES[$i]}"
    backup="${COPIED_BACKUPS[$i]:-}"
    if [ -n "$backup" ]; then
      if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] 上書き前のファイルを復元: $f"
      elif mv -f "$backup" "$f"; then
        log "上書き前のファイルを復元しました: $f"
      else
        warn "上書き前のファイルを復元できませんでした: $backup -> $f (手動で復元してください)"
      fi
      continue
    fi
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] rm -f $f"
    elif rm -f "$f"; then
      log "削除しました: $f"
    else
      warn "一時ファイルの削除に失敗しました: $f (手動で削除してください)"
    fi
  done
  COPIED_FILES=()
  COPIED_BACKUPS=()
  # 退避用ディレクトリは、復元し切れたときだけ (= 空のときだけ) 削除する。
  # 復元に失敗した分が残っている場合は、手動復旧できるよう消さずに知らせる。
  if [ -n "$COPY_BACKUP_DIR" ] && [ -d "$COPY_BACKUP_DIR" ]; then
    if rmdir "$COPY_BACKUP_DIR" 2>/dev/null; then
      COPY_BACKUP_DIR=""
    else
      warn "退避したファイルが残っています: $COPY_BACKUP_DIR (内容を確認し、手動で復元・削除してください)"
    fi
  fi
}

# ---- 起動確認 / URL 確認 用ヘルパ -------------------------------------------
STARTED_CONTAINER="false"          # コンテナを起動したか (teardown 判定用)
# compose up を実行したか。up に失敗してもコンテナは作られているため、今回の実行が
# 触れたコンテナかどうかの判定にはこちらを使う (終了ログ取得の対象判定)。
COMPOSE_UP_ATTEMPTED="false"
CONTAINER_LOG_SINCE=""             # 今回の起動より前のコンテナログを除外する基準時刻

# 対象コンテナの ID を取得する (引数でサービスを指定、未指定なら対象サービス全体)。
# ps -q は実行中のコンテナのみを返す。
compose_container_ids() {
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -q "$@" 2>/dev/null
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -q ${COMPOSE_TARGET_SERVICES[@]+"${COMPOSE_TARGET_SERVICES[@]}"} 2>/dev/null
  fi
}

# 停止済みを含む対象コンテナの ID を取得する。異常終了の検知には ps -q ではなく
# こちらを使う (ps -q は終了したコンテナを返さないため、消えた = 正常と誤判定する)。
compose_container_ids_all() {
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -aq "$@" 2>/dev/null
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -aq ${COMPOSE_TARGET_SERVICES[@]+"${COMPOSE_TARGET_SERVICES[@]}"} 2>/dev/null
  fi
}

# 環境変数一覧とディレクトリツリーで共通して使う対象コンテナ ID を取得する。
# 起動確認サービスが明示されている場合はその対象を優先し、それ以外はビルド・起動
# 対象の Compose サービス (未指定なら全サービス) を対象とする。
verification_target_container_ids() {
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    compose_container_ids "${STARTUP_SERVICES[@]}"
  elif [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
    compose_container_ids "${COMPOSE_TARGET_SERVICES[@]}"
  else
    compose_container_ids
  fi
}

# ログを取得する (スナップショット)。引数でサービスを指定、未指定なら対象サービス全体。
compose_logs() {
  local -a log_args=(-f "$COMPOSE_FILE" logs --no-color)
  if [ -n "$CONTAINER_LOG_SINCE" ]; then
    log_args+=(--since "$CONTAINER_LOG_SINCE")
  fi
  if [ $# -gt 0 ]; then
    "${COMPOSE_CMD[@]}" "${log_args[@]}" "$@" 2>&1
  else
    "${COMPOSE_CMD[@]}" "${log_args[@]}" ${COMPOSE_TARGET_SERVICES[@]+"${COMPOSE_TARGET_SERVICES[@]}"} 2>&1
  fi
}

# JBoss のコンソールカラーは compose logs --no-color では除去されないため、
# EAP のメッセージ解析前に ANSI SGR シーケンスを取り除く。
strip_ansi_codes() {
  LC_ALL=C sed $'s/\033\[[0-9;]*m//g'
}

# ログ文字列の行数を数える。空文字列は「1 行 (空行)」ではなく 0 行として扱う。
count_log_lines() {
  local logs="$1"
  if [ -z "$logs" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$logs" | awk 'END { print NR }'
}

# 端末への直接表示時だけ色を付ける。NO_COLOR を優先し、リダイレクトされたログへ
# ANSI シーケンスを混入させない。CLICOLOR_FORCE はテストや明示的な強制表示に使える。
startup_log_color_enabled() {
  [ -z "${NO_COLOR+x}" ] || return 1
  case "${CLICOLOR_FORCE:-0}" in
    0) ;;
    *) return 0 ;;
  esac
  [ -t 2 ] && [ "${TERM:-}" != "dumb" ]
}

# JBoss EAP の重要行を意味別に色分けし、その他の行はそのまま表示する。
print_startup_logs_with_highlights() {
  local logs="$1" line color
  local use_color="false"
  local error_level_pattern='[[:space:]](ERROR|FATAL)[[:space:]]'
  local warning_level_pattern='[[:space:]]WARN(ING)?[[:space:]]'
  local color_red=$'\033[1;31m' color_yellow=$'\033[1;33m'
  local color_green=$'\033[1;32m' color_cyan=$'\033[1;36m' color_reset=$'\033[0m'

  startup_log_color_enabled && use_color="true"
  while IFS= read -r line || [ -n "$line" ]; do
    color=""
    if [ "$use_color" = "true" ]; then
      if [[ "$line" =~ $error_level_pattern ]] || [[ "$line" =~ $STARTUP_FAILURE_LOG_PATTERN ]]; then
        color="$color_red"
      elif [[ "$line" =~ $warning_level_pattern ]]; then
        color="$color_yellow"
      elif [[ "$line" =~ $STARTUP_SUCCESS_LOG_PATTERN ]] || [[ "$line" =~ $STARTUP_LOG_PATTERN ]]; then
        color="$color_green"
      elif [[ "$line" =~ $STARTUP_IMPORTANT_LOG_PATTERN ]]; then
        color="$color_cyan"
      fi
    fi
    if [ -n "$color" ]; then
      printf '%s%s%s\n' "$color" "$line" "$color_reset" >&2
    else
      printf '%s\n' "$line" >&2
    fi
  done <<< "$logs"
}

show_startup_logs() {
  local logs="$1" target_desc="$2" allow_suppression="${3:-true}"
  local log_title="${4:-コンテナ起動ログ}"
  local selected normalized_logs total_count shown_count display_range

  if [ "$allow_suppression" = "true" ] && [ "$SUPPRESS_STARTUP_LOGS" = "true" ]; then
    log "コンテナ起動ログの表示を抑制しました (--suppress-startup-logs)。"
    return 0
  fi

  normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
  if [ -n "$normalized_logs" ]; then
    total_count="$(printf '%s\n' "$normalized_logs" | awk 'END { print NR }')"
  else
    total_count=0
  fi

  if [ "$STARTUP_LOG_LINES" = "all" ]; then
    selected="$normalized_logs"
    shown_count="$total_count"
    display_range="全 ${total_count} 行"
  else
    selected="$(printf '%s\n' "$normalized_logs" | tail -n "$STARTUP_LOG_LINES")"
    if [ -n "$selected" ]; then
      shown_count="$(printf '%s\n' "$selected" | awk 'END { print NR }')"
    else
      shown_count=0
    fi
    display_range="末尾 ${shown_count}/${total_count} 行 (指定上限: ${STARTUP_LOG_LINES})"
  fi

  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "${log_title} (${target_desc}, ${display_range}):"
  diag "───────────────────────────────────────────────────────────────────"
  if [ -n "$selected" ]; then
    if startup_log_color_enabled; then
      printf '色分け: \033[1;32m成功\033[0m / \033[1;36m重要\033[0m / \033[1;33m警告\033[0m / \033[1;31mエラー\033[0m\n' >&2
    fi
    print_startup_logs_with_highlights "$selected"
  else
    diag "表示対象のコンテナ起動ログはありません。"
  fi
  diag "───────────────────────────────────────────────────────────────────"
}

# 現在起動している Compose サービス名を、Compose が返す順序を保って列挙する。
# ps --services を利用できない旧実装では、明示された起動対象またはコンテナラベルへ
# フォールバックする。
compose_started_services() {
  local services cid service_name
  services="$("${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps --services 2>/dev/null || true)"
  if [ -n "$services" ]; then
    printf '%s\n' "$services" | awk 'NF && !seen[$0]++'
    return 0
  fi
  if [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
    printf '%s\n' "${COMPOSE_TARGET_SERVICES[@]}" | awk 'NF && !seen[$0]++'
    return 0
  fi
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] && printf '%s\n' "$service_name"
  done < <(compose_container_ids) | awk 'NF && !seen[$0]++'
}

# 起動確認対象以外で、同じ compose up により現在起動しているサービスのログを、
# 起動確認ログと同じ行数設定でサービス単位に順次表示する。
show_companion_service_logs() {
  local allow_suppression="${1:-true}"
  local svc logs normalized_logs selected total_count shown_count display_range
  local -a started_services=()
  local -A verification_services=()

  if [ "$allow_suppression" = "true" ] && [ "$SUPPRESS_STARTUP_LOGS" = "true" ]; then
    return 0
  fi

  mapfile -t started_services < <(compose_started_services)
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    for svc in "${STARTUP_SERVICES[@]}"; do
      verification_services["$svc"]=1
    done
  elif [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
    for svc in "${COMPOSE_TARGET_SERVICES[@]}"; do
      verification_services["$svc"]=1
    done
  else
    # 起動対象を限定していない場合、起動確認ログには全サービスが含まれている。
    for svc in "${started_services[@]}"; do
      verification_services["$svc"]=1
    done
  fi

  for svc in "${started_services[@]}"; do
    [ -n "$svc" ] || continue
    [ -z "${verification_services[$svc]+_}" ] || continue
    logs="$(compose_logs "$svc")"
    normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
    if [ -n "$normalized_logs" ]; then
      total_count="$(printf '%s\n' "$normalized_logs" | awk 'END { print NR }')"
    else
      total_count=0
    fi
    if [ "$STARTUP_LOG_LINES" = "all" ]; then
      selected="$normalized_logs"
      shown_count="$total_count"
      display_range="全 ${total_count} 行"
    else
      selected="$(printf '%s\n' "$normalized_logs" | tail -n "$STARTUP_LOG_LINES")"
      if [ -n "$selected" ]; then
        shown_count="$(printf '%s\n' "$selected" | awk 'END { print NR }')"
      else
        shown_count=0
      fi
      display_range="末尾 ${shown_count}/${total_count} 行 (指定上限: ${STARTUP_LOG_LINES})"
    fi

    diag ""
    diag "───────────────────────────────────────────────────────────────────"
    diag "同時起動 Compose サービスログ (サービス: ${svc}, ${display_range}):"
    diag "───────────────────────────────────────────────────────────────────"
    if [ -n "$selected" ]; then
      printf '%s\n' "$selected" >&2
    else
      diag "表示対象のサービスログはありません。"
    fi
    diag "───────────────────────────────────────────────────────────────────"
  done
}

# compose.yml に定義された全サービスと、停止済みを含むコンテナを持つ全サービスを
# 重複なく列挙する。失敗レポートへログを書き出す対象を決めるために使うので、
# 起動確認対象かどうか、サイドカー (adot collector 等) かどうかで絞り込まない。
# 定義順を優先し、profiles などで定義側に現れないサービスは ps の結果で補う。
compose_all_service_names() {
  {
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" config --services 2>/dev/null || true
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" ps -a --services 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

# レポートのサービス見出しへ添えるコンテナ名と状態を組み立てる。停止済みも対象に
# するため ps -aq を使い、サイドカーの異常終了をログ本文より先に示す。
compose_service_container_summary() {
  local service_name="$1" cid name state status exit_code entry summary=""
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    state="$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}' "$cid" 2>/dev/null || printf '|')"
    status="${state%%|*}"
    exit_code="${state##*|}"
    case "$status" in
      running) entry="${name} (状態: running)" ;;
      "")      entry="${name} (状態: 不明)" ;;
      *)       entry="${name} (状態: ${status}, 終了コード: ${exit_code:-不明})" ;;
    esac
    if [ -n "$summary" ]; then
      summary="${summary}, ${entry}"
    else
      summary="$entry"
    fi
  done < <(compose_container_ids_all "$service_name")
  [ -n "$summary" ] || summary="(コンテナなし)"
  printf '%s\n' "$summary"
}

normalize_container_name() {
  local name="$1"
  printf '%s\n' "${name#/}"
}

compose_file_dir() {
  local compose_dir
  compose_dir="$(cd "$(dirname "$COMPOSE_FILE")" 2>/dev/null && pwd -P)" || return 1
  printf '%s\n' "$compose_dir"
}

compose_dockerfiles() {
  local compose_dir dockerfile_path cleaned found="false"
  compose_dir="$(compose_file_dir)" || return 0
  while IFS= read -r dockerfile_path; do
    [ -n "$dockerfile_path" ] || continue
    cleaned="${dockerfile_path#\"}"
    cleaned="${cleaned%\"}"
    cleaned="${cleaned#\'}"
    cleaned="${cleaned%\'}"
    if [ "${cleaned#/}" = "$cleaned" ]; then
      cleaned="${compose_dir}/${cleaned}"
    fi
    printf '%s\n' "$cleaned"
    found="true"
  done < <(sed -n 's/^[[:space:]]*dockerfile:[[:space:]]*//p' "$COMPOSE_FILE")
  if [ "$found" != "true" ] && [ -f "${compose_dir}/Dockerfile" ]; then
    printf '%s\n' "${compose_dir}/Dockerfile"
  fi
}

collect_build_arg_env_names_from_dockerfile() {
  local dockerfile="$1"
  [ -f "$dockerfile" ] || return 0
  local physical_line logical_line="" trimmed env_body key value arg_name
  local -a env_tokens=()
  local -a arg_names=()
  local -A arg_name_set=()
  local -A env_name_set=()

  while IFS= read -r physical_line || [ -n "$physical_line" ]; do
    if [ -n "$logical_line" ]; then
      logical_line="${logical_line}${physical_line}"
    else
      logical_line="$physical_line"
    fi
    if [[ "$logical_line" == *\\ ]]; then
      logical_line="${logical_line%\\} "
      continue
    fi

    trimmed="${logical_line#"${logical_line%%[![:space:]]*}"}"
    logical_line=""
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      \#*) continue ;;
    esac

    if [[ "$trimmed" =~ ^ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
      arg_name="${BASH_REMATCH[1]}"
      arg_name_set["$arg_name"]=1
      continue
    fi

    if [[ "$trimmed" =~ ^ENV[[:space:]]+(.+)$ ]]; then
      env_body="${BASH_REMATCH[1]}"
      env_tokens=()
      read -r -a env_tokens <<< "$env_body"
      if [ ${#env_tokens[@]} -ge 2 ] && [[ "${env_tokens[0]}" != *=* ]]; then
        key="${env_tokens[0]}"
        value="${env_tokens[1]}"
        for arg_name in "${!arg_name_set[@]}"; do
          case "$value" in
            *"\${${arg_name}}"*|*"\$${arg_name}"*)
              env_name_set["$key"]=1
              break
            ;;
          esac
        done
      fi
      for value in "${env_tokens[@]}"; do
        case "$value" in
          *=*)
            key="${value%%=*}"
            value="${value#*=}"
            for arg_name in "${!arg_name_set[@]}"; do
              case "$value" in
                *"\${${arg_name}}"*|*"\$${arg_name}"*)
                  env_name_set["$key"]=1
                  break
                ;;
              esac
            done
          ;;
        esac
      done
    fi
  done < "$dockerfile"

  for key in "${!env_name_set[@]}"; do
    printf '%s\n' "$key"
  done | sort
}

load_build_arg_env_name_set() {
  [ "$BUILD_ARG_ENV_NAMES_LOADED" = "true" ] && return 0
  local dockerfile env_name
  while IFS= read -r dockerfile; do
    [ -f "$dockerfile" ] || continue
    while IFS= read -r env_name; do
      [ -n "$env_name" ] || continue
      BUILD_ARG_ENV_NAME_SET["$env_name"]=1
    done < <(collect_build_arg_env_names_from_dockerfile "$dockerfile")
  done < <(compose_dockerfiles)
  BUILD_ARG_ENV_NAMES_LOADED="true"
}

collect_container_pid1_env() {
  local cid="$1"
  if docker exec "$cid" /bin/sh -lc "tr '\\0' '\\n' </proc/1/environ" 2>/dev/null; then
    return 0
  fi
  docker exec "$cid" env 2>/dev/null || true
}

collect_container_config_env() {
  local cid="$1"
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null || true
}

collect_container_image_env() {
  local cid="$1" image_id
  image_id="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)" || return 0
  [ -n "$image_id" ] || return 0
  docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image_id" 2>/dev/null || true
}

# 画面表示と全量レポートへ認証情報を平文で残さないための判定。名前だけは分類・
# 設定漏れの確認に必要なため維持し、値の側を [REDACTED] へ置き換える。
# 環境変数名にも JVM パラメータ名 (-Dxxx.password 等) にも同じ規則を適用する。
# OTLP の *_HEADERS は認証ヘッダを載せる用途が多いため対象に含める。
is_sensitive_setting_name() {
  local upper="${1^^}"
  case "$upper" in
    *PASSWORD*|*PASSWD*|*TOKEN*|*SECRET*|*PRIVATE_KEY*|*ACCESS_KEY*|*API_KEY*|*CREDENTIAL*|*HEADERS*)
      return 0
      ;;
  esac
  return 1
}

append_env_names_by_type() {
  local report_file="$1" type_label="$2"
  shift 2
  local -a names=("$@")
  printf '[%s] %s 件\n' "$type_label" "${#names[@]}" >> "$report_file"
  if [ ${#names[@]} -eq 0 ]; then
    printf '  (なし)\n' >> "$report_file"
    return 0
  fi
  printf '%s\n' "${names[@]}" | sed 's/^/  /' >> "$report_file"
}

append_container_env_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local env_limit="${5:-$ENV_LIST_LIMIT}"
  local line key value kv type_label shown_count total_count
  local -a sorted_names=()
  local -a compose_names=() build_arg_names=() internal_names=() other_names=()
  declare -A process_env_values=()
  declare -A container_env_values=()
  declare -A image_env_values=()
  declare -A compose_runtime_name_set=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    process_env_values["$key"]="$value"
  done < <(collect_container_pid1_env "$cid")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    container_env_values["$key"]="$value"
  done < <(collect_container_config_env "$cid")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    image_env_values["$key"]="$value"
  done < <(collect_container_image_env "$cid")

  for key in "${!container_env_values[@]}"; do
    if [ -z "${image_env_values[$key]+_}" ] || [ "${container_env_values[$key]}" != "${image_env_values[$key]}" ]; then
      compose_runtime_name_set["$key"]=1
    fi
  done

  mapfile -t sorted_names < <(printf '%s\n' "${!process_env_values[@]}" | sort)
  total_count="${#sorted_names[@]}"
  shown_count="$total_count"
  if [ "$env_limit" != "all" ] && [ "$env_limit" -lt "$shown_count" ]; then
    shown_count="$env_limit"
  fi

  printf '\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  printf '環境変数一覧 (サービス: %s, コンテナ: %s, 表示件数: %s/%s)\n' "$service_name" "$container_name" "$shown_count" "$total_count" >> "$report_file"
  printf '種別: compose.yml environment / build引数 / コンテナ内部処理 / イメージ既定・その他\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"

  shown_count=0
  for key in "${sorted_names[@]}"; do
    if [ "$env_limit" != "all" ] && [ "$shown_count" -ge "$env_limit" ]; then
      break
    fi
    value="${process_env_values[$key]}"
    if is_sensitive_setting_name "$key" || [ "$key" = "$JBOSS_PASSWORD_ENV" ]; then
      value="[REDACTED]"
    fi
    kv="${key}=${value}"
    if [ -z "${container_env_values[$key]+_}" ]; then
      internal_names+=("$kv")
    elif [ -n "${compose_runtime_name_set[$key]+_}" ]; then
      compose_names+=("$kv")
    elif [ -n "${BUILD_ARG_ENV_NAME_SET[$key]+_}" ]; then
      build_arg_names+=("$kv")
    else
      other_names+=("$kv")
    fi
    shown_count=$((shown_count + 1))
  done

  append_env_names_by_type "$report_file" "compose.yml environment" "${compose_names[@]}"
  append_env_names_by_type "$report_file" "build引数" "${build_arg_names[@]}"
  append_env_names_by_type "$report_file" "コンテナ内部処理" "${internal_names[@]}"
  append_env_names_by_type "$report_file" "イメージ既定・その他" "${other_names[@]}"
}

show_verified_container_envs() {
  [ "$DRY_RUN" = "true" ] && {
    log "[DRY-RUN] 動作確認成功後の環境変数一覧出力をプレビューします。"
    return 0
  }

  local report_file cid service_name container_name env_report_tmp
  local -a target_container_ids=()

  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "環境変数一覧を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi

  load_build_arg_env_name_set
  env_report_tmp="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/env_report.$$")"
  : > "$env_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_env_report "$cid" "$service_name" "$container_name" "$env_report_tmp"
  done

  diag ""
  while IFS= read -r report_file; do
    diag "$report_file"
  done < "$env_report_tmp"

  if [ -n "$ENV_LIST_FILE" ]; then
    mkdir -p "$(dirname "$ENV_LIST_FILE")" 2>/dev/null || true
    if cp "$env_report_tmp" "$ENV_LIST_FILE" 2>/dev/null; then
      log "環境変数一覧をファイルへ出力しました: $ENV_LIST_FILE"
    else
      warn "環境変数一覧のファイル出力に失敗しました: $ENV_LIST_FILE"
    fi
  fi

  rm -f "$env_report_tmp"
}

# 1 コンテナ内の指定ルートを report_file へ追記する。コンテナ内に追加の
# スクリプトや tree コマンドを要求しないよう、find の NUL 区切り出力をホスト側の
# Bash で集計し、tree コマンドと同じ罫線記号で表示する。file_limit が none の
# 場合はディレクトリだけを取得する。
# それ以外は、直下のファイル数が file_limit 以下なら名前を、超える場合は
# 最終拡張子 (例: archive.tar.gz は .gz) ごとの件数を出力する。
append_container_directory_tree_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local root_path="${5:-/}" report_title="${6:-コンテナ内ディレクトリツリー}"
  local tree_depth="${7:-$DIRECTORY_TREE_DEPTH}" file_limit="${8:-$DIRECTORY_FILE_LIMIT}"
  local directory_list_tmp file_list_tmp directory_find_status=0 file_find_status=0
  local file_max_depth directory file_path parent filename suffix extension key count file_count
  local failure_message
  local display_name extension_list filename_list ancestor prefix connector is_last index
  local hidden_path hide_directory
  local -a directory_find_args=()
  local -a file_find_args=()
  local -a directory_paths=()
  local -a visible_directory_paths=()
  local -a ancestor_chain=()
  local -a leaf_entries=()
  local -A extension_counts=()
  local -A directory_extension_lists=()
  local -A directory_file_counts=()
  local -A directory_filename_lists=()
  local -A directory_child_counts=()
  local -A last_child_directory=()
  local -A directory_is_last=()

  # / 以外は末尾のスラッシュを除き、find の出力と親パスの比較を安定させる。
  if [ "$root_path" != "/" ]; then
    root_path="${root_path%/}"
  fi
  directory_find_args=(find "$root_path")
  if [ "$file_limit" != "none" ]; then
    file_find_args=(find "$root_path")
  fi

  if ! directory_list_tmp="$(mktemp 2>/dev/null)"; then
    warn "ディレクトリツリー集計用の一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi
  if ! file_list_tmp="$(mktemp 2>/dev/null)"; then
    rm -f -- "$directory_list_tmp"
    warn "ディレクトリツリー集計用の一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi

  if [ "$tree_depth" != "all" ]; then
    directory_find_args+=(-maxdepth "$tree_depth")
    if [ "$file_limit" != "none" ]; then
      file_max_depth="$((10#$tree_depth + 1))"
      file_find_args+=(-maxdepth "$file_max_depth")
    fi
  fi

  # コンテナ全体のツリーでは、巨大な仮想ファイルシステム等を find 自体で枝刈り
  # する。対象ディレクトリは 1 ノードとして出力し、その配下だけを探索しない。
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    directory_find_args+=("(")
    if [ "$file_limit" != "none" ]; then
      file_find_args+=("(")
    fi
    for index in "${!DIRECTORY_TREE_PRUNE_PATHS[@]}"; do
      if [ "$index" -gt 0 ]; then
        directory_find_args+=(-o)
        if [ "$file_limit" != "none" ]; then
          file_find_args+=(-o)
        fi
      fi
      directory_find_args+=(-path "${DIRECTORY_TREE_PRUNE_PATHS[$index]}")
      if [ "$file_limit" != "none" ]; then
        file_find_args+=(-path "${DIRECTORY_TREE_PRUNE_PATHS[$index]}")
      fi
    done
    directory_find_args+=(")" -prune -print0 -o)
    if [ "$file_limit" != "none" ]; then
      file_find_args+=(")" -prune -o)
    fi
  fi
  directory_find_args+=(-type d -print0)
  if [ "$file_limit" != "none" ]; then
    file_find_args+=(-type f -print0)
  fi

  docker exec "$cid" "${directory_find_args[@]}" > "$directory_list_tmp" 2>/dev/null || directory_find_status=$?
  if [ "$file_limit" != "none" ]; then
    docker exec "$cid" "${file_find_args[@]}" > "$file_list_tmp" 2>/dev/null || file_find_status=$?
  fi

  if [ ! -s "$directory_list_tmp" ]; then
    failure_message="${report_title}を取得できませんでした (サービス: ${service_name}, コンテナ: ${container_name}, ルート: ${root_path})。コンテナ内のパスと find コマンドを確認してください。"
    printf '\n[WARN] %s\n' "$failure_message" >> "$report_file"
    rm -f -- "$directory_list_tmp" "$file_list_tmp"
    return 0
  fi

  while IFS= read -r -d '' file_path; do
    parent="${file_path%/*}"
    [ -n "$parent" ] || parent="/"
    filename="${file_path##*/}"
    extension="(拡張子なし)"
    if [ -z "${directory_file_counts[$parent]+_}" ]; then
      directory_file_counts["$parent"]=1
      directory_filename_lists["$parent"]="$filename"
    else
      file_count="${directory_file_counts[$parent]}"
      directory_file_counts["$parent"]=$((file_count + 1))
      directory_filename_lists["$parent"]+=$'\n'"$filename"
    fi

    # 先頭のドットだけを持つファイル (.env など) と末尾がドットのファイルは
    # 拡張子なしとして扱う。.env.local のように後続のドットがあれば .local とする。
    case "$filename" in
      .*)
        suffix="${filename#.}"
        case "$suffix" in
          *.*)
            suffix="${filename##*.}"
            [ -n "$suffix" ] && extension=".${suffix}"
          ;;
        esac
      ;;
      *.*)
        suffix="${filename##*.}"
        [ -n "$suffix" ] && extension=".${suffix}"
      ;;
    esac

    key="${parent}"$'\x1f'"${extension}"
    if [ -z "${extension_counts[$key]+_}" ]; then
      extension_counts["$key"]=1
      if [ -z "${directory_extension_lists[$parent]+_}" ]; then
        directory_extension_lists["$parent"]="$extension"
      else
        directory_extension_lists["$parent"]+=$'\n'"$extension"
      fi
    else
      count="${extension_counts[$key]}"
      extension_counts["$key"]=$((count + 1))
    fi
  done < "$file_list_tmp"

  # 親ごとの最後の子ディレクトリを先に確定し、├── / └── と祖先の │ を
  # 正しく選択できるようにする。ファイル行は各親の先頭、ディレクトリ行は
  # その後に出すため、最後の子ディレクトリが親全体の最後のノードになる。
  mapfile -d '' -t directory_paths < <(LC_ALL=C sort -z "$directory_list_tmp")
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    for directory in "${directory_paths[@]}"; do
      hide_directory="false"
      for hidden_path in "${DIRECTORY_TREE_HIDDEN_PATHS[@]}"; do
        if [ "$directory" = "$hidden_path" ]; then
          hide_directory="true"
          break
        fi
      done
      [ "$hide_directory" = "true" ] || visible_directory_paths+=("$directory")
    done
    directory_paths=("${visible_directory_paths[@]}")
  fi
  for directory in "${directory_paths[@]}"; do
    [ "$directory" = "$root_path" ] && continue
    parent="${directory%/*}"
    [ -n "$parent" ] || parent="/"
    directory_child_counts["$parent"]=$((${directory_child_counts[$parent]:-0} + 1))
    last_child_directory["$parent"]="$directory"
  done
  for directory in "${directory_paths[@]}"; do
    if [ "$directory" = "$root_path" ]; then
      directory_is_last["$directory"]="true"
      continue
    fi
    parent="${directory%/*}"
    [ -n "$parent" ] || parent="/"
    if [ "${last_child_directory[$parent]:-}" = "$directory" ]; then
      directory_is_last["$directory"]="true"
    else
      directory_is_last["$directory"]="false"
    fi
  done

  printf '\n' >> "$report_file"
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  if [ "$root_path" = "/" ] && [ "$report_title" = "コンテナ内ディレクトリツリー" ]; then
    printf '%s (サービス: %s, コンテナ: %s, 最大深さ: %s)\n' \
        "$report_title" "$service_name" "$container_name" "$tree_depth" >> "$report_file"
  else
    printf '%s (サービス: %s, コンテナ: %s, ルート: %s, 最大深さ: %s)\n' \
        "$report_title" "$service_name" "$container_name" "$root_path" "$tree_depth" >> "$report_file"
  fi
  if [ "$file_limit" = "none" ]; then
    printf '通常ファイル: 表示しない\n' >> "$report_file"
  elif [ "$file_limit" = "all" ]; then
    printf '通常ファイル: 件数にかかわらず全ファイル名を表示\n' >> "$report_file"
  else
    printf '通常ファイル: 直下 %s 件以下は全ファイル名、超過時は拡張子別件数\n' \
        "$file_limit" >> "$report_file"
  fi
  printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
  if [ "$directory_find_status" -ne 0 ] || [ "$file_find_status" -ne 0 ]; then
    printf '[WARN] 読み取り不能または実行中に消滅したパスを除く、取得可能な範囲を表示します。\n' >> "$report_file"
  fi

  for directory in "${directory_paths[@]}"; do
    if [ "$directory" = "$root_path" ]; then
      if [ "$root_path" = "/" ]; then
        display_name="/"
      else
        display_name="${root_path##*/}/"
      fi
      printf '%s\n' "$display_name" >> "$report_file"
    else
      display_name="${directory##*/}/"
      parent="${directory%/*}"
      [ -n "$parent" ] || parent="/"
      ancestor_chain=()
      ancestor="$parent"
      while [ "$ancestor" != "$root_path" ]; do
        ancestor_chain=("$ancestor" "${ancestor_chain[@]}")
        ancestor="${ancestor%/*}"
        [ -n "$ancestor" ] || ancestor="/"
      done
      prefix=""
      for ancestor in "${ancestor_chain[@]}"; do
        if [ "${directory_is_last[$ancestor]:-false}" = "true" ]; then
          prefix+="    "
        else
          prefix+="│   "
        fi
      done
      is_last="${directory_is_last[$directory]:-false}"
      if [ "$is_last" = "true" ]; then
        connector="└── "
      else
        connector="├── "
      fi
      printf '%s%s%s\n' "$prefix" "$connector" "$display_name" >> "$report_file"
    fi

    leaf_entries=()
    file_count="${directory_file_counts[$directory]:-0}"
    if [ "$file_count" -gt 0 ] \
        && { [ "$file_limit" = "all" ] || [ "$file_count" -le "$file_limit" ]; }; then
      filename_list="${directory_filename_lists[$directory]}"
      while IFS= read -r filename; do
        leaf_entries+=("[ファイル] ${filename}")
      done < <(printf '%s\n' "$filename_list" | LC_ALL=C sort)
    elif [ "$file_count" -gt 0 ] && [ -n "${directory_extension_lists[$directory]+_}" ]; then
      extension_list="${directory_extension_lists[$directory]}"
      while IFS= read -r extension; do
        [ -n "$extension" ] || continue
        key="${directory}"$'\x1f'"${extension}"
        leaf_entries+=("[ファイル] ${extension}: ${extension_counts[$key]} 件")
      done < <(printf '%s\n' "$extension_list" | LC_ALL=C sort)
    fi

    for index in "${!leaf_entries[@]}"; do
      ancestor_chain=()
      ancestor="$directory"
      while [ "$ancestor" != "$root_path" ]; do
        ancestor_chain=("$ancestor" "${ancestor_chain[@]}")
        ancestor="${ancestor%/*}"
        [ -n "$ancestor" ] || ancestor="/"
      done
      prefix=""
      for ancestor in "${ancestor_chain[@]}"; do
        if [ "${directory_is_last[$ancestor]:-false}" = "true" ]; then
          prefix+="    "
        else
          prefix+="│   "
        fi
      done
      if [ "$index" -eq "$((${#leaf_entries[@]} - 1))" ] \
          && [ "${directory_child_counts[$directory]:-0}" -eq 0 ]; then
        connector="└── "
      else
        connector="├── "
      fi
      printf '%s%s%s\n' "$prefix" "$connector" "${leaf_entries[$index]}" >> "$report_file"
    done
  done

  rm -f -- "$directory_list_tmp" "$file_list_tmp"
}

show_verified_container_directory_trees() {
  [ "$DRY_RUN" = "true" ] && {
    if [ "$DIRECTORY_FILE_LIMIT" = "none" ]; then
      log "[DRY-RUN] 環境変数一覧後のコンテナ内ディレクトリツリー出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, 通常ファイル: 表示しない)。"
    else
      log "[DRY-RUN] 環境変数一覧後のコンテナ内ディレクトリツリー出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, ファイル表示上限: ${DIRECTORY_FILE_LIMIT})。"
    fi
    return 0
  }

  local report_line cid service_name container_name tree_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "コンテナ内ディレクトリツリーを出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi

  if ! tree_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "ディレクトリツリー出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$tree_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_directory_tree_report "$cid" "$service_name" "$container_name" "$tree_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$tree_report_tmp"

  rm -f -- "$tree_report_tmp"
}

# JBoss EAP のデプロイ先、展開済み Web ルート、Java クラスパスルート
# (WEB-INF/classes)、および指定環境変数のディレクトリを検出して表示する。
append_container_deployment_structure_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local tree_depth="${5:-$DIRECTORY_TREE_DEPTH}" file_limit="${6:-$DIRECTORY_FILE_LIMIT}"
  local scan_tmp scan_status=0 directory label root_path key entry line env_name value
  local deployment_found="false" web_root_found="false" class_root_found="false"
  local -a root_entries=() notices=()
  local -A seen_roots=() process_env_values=()

  if ! scan_tmp="$(mktemp 2>/dev/null)"; then
    warn "JBoss EAP デプロイ構造の検出用一時ファイルを作成できませんでした (サービス: ${service_name})。"
    return 0
  fi
  docker exec "$cid" find / -type d -print0 > "$scan_tmp" 2>/dev/null || scan_status=$?

  while IFS= read -r -d '' directory; do
    label=""
    root_path="$directory"
    case "$directory" in
      */standalone/deployments)
        label="JBoss EAP デプロイ先"
        deployment_found="true"
        ;;
      */WEB-INF/classes)
        label="Java クラスパスルート"
        class_root_found="true"
        ;;
      */WEB-INF)
        label="Web アプリケーションルート"
        root_path="${directory%/WEB-INF}"
        [ -n "$root_path" ] || root_path="/"
        web_root_found="true"
        ;;
    esac
    [ -n "$label" ] || continue
    key="${label}"$'\x1f'"${root_path}"
    if [ -z "${seen_roots[$key]+_}" ]; then
      seen_roots["$key"]=1
      root_entries+=("$key")
    fi
  done < "$scan_tmp"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    process_env_values["$key"]="$value"
  done < <(collect_container_pid1_env "$cid")

  for env_name in "${DEPLOYMENT_DIR_ENVS[@]}"; do
    if [ -z "${process_env_values[$env_name]+_}" ] || [ -z "${process_env_values[$env_name]}" ]; then
      notices+=("環境変数 ${env_name} は未設定または空です。")
      continue
    fi
    root_path="${process_env_values[$env_name]}"
    case "$root_path" in
      /*) ;;
      *)
        notices+=("環境変数 ${env_name} の値は絶対パスではありません: ${root_path}")
        continue
        ;;
    esac
    [ "$root_path" = "/" ] || root_path="${root_path%/}"
    label="環境変数 ${env_name}"
    key="${label}"$'\x1f'"${root_path}"
    if [ -z "${seen_roots[$key]+_}" ]; then
      seen_roots["$key"]=1
      root_entries+=("$key")
    fi
  done

  printf '\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"
  printf 'JBoss EAP デプロイ済み Web アプリケーションのディレクトリ構造\n' >> "$report_file"
  if [ "$file_limit" = "none" ]; then
    printf '(サービス: %s, コンテナ: %s, 最大深さ: %s, 通常ファイル: 表示しない)\n' \
        "$service_name" "$container_name" "$tree_depth" >> "$report_file"
  else
    printf '(サービス: %s, コンテナ: %s, 最大深さ: %s, ファイル表示上限: %s)\n' \
        "$service_name" "$container_name" "$tree_depth" "$file_limit" >> "$report_file"
  fi
  printf '===================================================================\n' >> "$report_file"
  if [ "$scan_status" -ne 0 ]; then
    printf '[WARN] 読み取り不能なパスを除く、検出可能な範囲を表示します。\n' >> "$report_file"
  fi
  [ "$deployment_found" = "true" ] || notices+=("JBoss EAP の standalone/deployments を検出できませんでした。")
  [ "$web_root_found" = "true" ] || notices+=("展開済み Web アプリケーションルート (WEB-INF の親) を検出できませんでした。")
  [ "$class_root_found" = "true" ] || notices+=("Java クラスパスルート (WEB-INF/classes) を検出できませんでした。")
  for line in "${notices[@]}"; do
    printf '[WARN] %s\n' "$line" >> "$report_file"
  done

  if [ ${#root_entries[@]} -eq 0 ]; then
    printf '表示対象のディレクトリはありません。\n' >> "$report_file"
  else
    for entry in "${root_entries[@]}"; do
      IFS=$'\x1f' read -r label root_path <<< "$entry"
      append_container_directory_tree_report "$cid" "$service_name" "$container_name" \
          "$report_file" "$root_path" "[${label}]" "$tree_depth" "$file_limit"
    done
  fi

  rm -f -- "$scan_tmp"
}

show_verified_container_deployment_structures() {
  [ "$DRY_RUN" = "true" ] && {
    if [ "$DIRECTORY_FILE_LIMIT" = "none" ]; then
      log "[DRY-RUN] コンテナ内ツリー後の JBoss EAP デプロイ構造出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, 通常ファイル: 表示しない)。"
    else
      log "[DRY-RUN] コンテナ内ツリー後の JBoss EAP デプロイ構造出力をプレビューします (最大深さ: ${DIRECTORY_TREE_DEPTH}, ファイル表示上限: ${DIRECTORY_FILE_LIMIT})。"
    fi
    return 0
  }

  local report_line cid service_name container_name deployment_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "JBoss EAP デプロイ構造を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi
  if ! deployment_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "JBoss EAP デプロイ構造出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$deployment_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_deployment_structure_report "$cid" "$service_name" "$container_name" \
        "$deployment_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$deployment_report_tmp"
  rm -f -- "$deployment_report_tmp"
}

# ---- Java JVM パラメータ / OpenTelemetry 設定の収集 ---------------------------
# コンテナ内の全プロセスのコマンドラインを "PID<US>arg0<US>arg1<US>..." で返す。
# ps / jcmd / jinfo をコンテナへ要求しないよう /proc/<pid>/cmdline を直接読み、
# NUL 区切りを US (0x1f) へ置き換えてホスト側の Bash で分解する。
# 引数中の空白をそのまま保てるため、-Dkey=値 に空白があっても壊れない。
collect_container_process_cmdlines() {
  local cid="$1"
  docker exec "$cid" /bin/sh -c '
for proc_dir in /proc/[0-9]*; do
  [ -r "$proc_dir/cmdline" ] || continue
  proc_cmdline=$(tr "\0" "\037" < "$proc_dir/cmdline" 2>/dev/null)
  [ -n "$proc_cmdline" ] || continue
  printf "%s\037%s\n" "${proc_dir#/proc/}" "$proc_cmdline"
done
' 2>/dev/null || true
}

# 上記のうち実行ファイル名が java のプロセス行だけを返す。
collect_container_java_processes() {
  local cid="$1" line rest first_arg
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rest="${line#*"$JVM_FIELD_SEPARATOR"}"
    [ "$rest" != "$line" ] || continue
    first_arg="${rest%%"$JVM_FIELD_SEPARATOR"*}"
    case "${first_arg##*/}" in
      java) printf '%s\n' "$line" ;;
    esac
  done < <(collect_container_process_cmdlines "$cid")
}

# java -version の出力 (stderr) を取得する。取得できない場合は空を返す。
container_java_version_text() {
  local cid="$1" java_bin="$2" version_output
  case "$java_bin" in
    /*|java) ;;
    *) return 0 ;;
  esac
  if ! version_output="$(docker exec "$cid" "$java_bin" -version 2>&1)"; then
    return 0
  fi
  printf '%s\n' "$version_output"
}

# JVM オプションを「名前」と「値」に分ける。-Dkey=value / -XX:key=value /
# -javaagent:path のように区切り文字が異なるため、書式ごとに分解する。
# 戻り値は関数呼び出しごとのフォークを避けるためグローバル変数へ格納する。
JVM_OPTION_NAME=""
JVM_OPTION_VALUE=""
JVM_OPTION_HAS_VALUE="false"
split_jvm_option_name_value() {
  local option="$1"
  JVM_OPTION_NAME="$option"
  JVM_OPTION_VALUE=""
  JVM_OPTION_HAS_VALUE="false"
  case "$option" in
    -javaagent:*|-agentlib:*|-agentpath:*|-Xbootclasspath*:*|-splash:*|-Xlog:*|-Xloggc:*)
      JVM_OPTION_NAME="${option%%:*}"
      JVM_OPTION_VALUE="${option#*:}"
      JVM_OPTION_HAS_VALUE="true"
      ;;
    -D*=*|-XX:*=*|--*=*)
      JVM_OPTION_NAME="${option%%=*}"
      JVM_OPTION_VALUE="${option#*=}"
      JVM_OPTION_HAS_VALUE="true"
      ;;
  esac
}

# JVM オプションを表示用の分類へ割り当てる。上から順に判定するため、
# 複数に当てはまるオプション (例: -javaagent の OpenTelemetry エージェント) は
# 先に一致した分類へ入る。OpenTelemetry の一覧は別途、全引数を横断して集める。
JVM_OPTION_CATEGORY=""
classify_jvm_option() {
  local option="$1"
  case "$option" in
    -javaagent:*|-agentlib:*|-agentpath:*)
      JVM_OPTION_CATEGORY="agent"; return 0 ;;
    -Dotel.*|-Dio.opentelemetry.*)
      JVM_OPTION_CATEGORY="otel"; return 0 ;;
    -cp|-classpath|--class-path*|-p|--module-path*|--add-opens*|--add-exports*|--add-modules*|--add-reads*|--patch-module*|--upgrade-module-path*|--limit-modules*|-Djava.class.path=*|-Djava.library.path=*|-Xbootclasspath*)
      JVM_OPTION_CATEGORY="module"; return 0 ;;
    -Xms*|-Xmx*|-Xss*|-Xmn*|-XX:*Metaspace*|-XX:*Heap*|-XX:*RAM*|-XX:MaxDirectMemorySize*|-XX:*CodeCache*|-XX:*ThreadStackSize*|-XX:*CompressedOops*|-XX:*CompressedClassSpaceSize*)
      JVM_OPTION_CATEGORY="memory"; return 0 ;;
    -Xlog:gc*|-Xloggc:*|-XX:*GC*|-XX:*SurvivorRatio*|-XX:*NewRatio*|-XX:*Tenuring*)
      JVM_OPTION_CATEGORY="gc"; return 0 ;;
    -Djboss.*|-Dorg.jboss.*|-Dwildfly.*|-Dorg.wildfly.*|-Dlogging.configuration=*|-Dmodule.path=*)
      JVM_OPTION_CATEGORY="jboss"; return 0 ;;
    -D*)
      JVM_OPTION_CATEGORY="sysprop"; return 0 ;;
    -*)
      JVM_OPTION_CATEGORY="other"; return 0 ;;
  esac
  JVM_OPTION_CATEGORY="other"
  return 0
}

# JVM オプションが OpenTelemetry の設定かどうかを判定する。
# 分類 (classify_jvm_option) と異なり、-javaagent の OpenTelemetry エージェントや
# 起動対象へ渡される引数側の -Dotel.* も対象にする。
is_otel_jvm_option() {
  local lower="${1,,}"
  case "$lower" in
    -dotel.*|-dio.opentelemetry.*) return 0 ;;
    *opentelemetry*) return 0 ;;
    -javaagent:*otel*|-agentpath:*otel*|-agentlib:*otel*) return 0 ;;
  esac
  return 1
}

# 環境変数名から OpenTelemetry Java エージェントが参照するシステムプロパティ名を
# 求める (OTEL_SERVICE_NAME → otel.service.name)。設定漏れ判定に使う。
otel_env_name_to_property() {
  local lower="${1,,}"
  printf '%s\n' "${lower//_/.}"
}

# 分類ごとの JVM パラメータを report_file へ追記する。件数 0 の分類は
# 読みにくくなるだけなので出力しない (OpenTelemetry 一覧側は未設定も表示する)。
# 字下げは append_env_names_by_type と同じく、この関数側で付ける。
append_jvm_option_entries() {
  local report_file="$1" label="$2"
  shift 2
  [ $# -gt 0 ] || return 0
  printf '[%s] %s 件\n' "$label" "$#" >> "$report_file"
  printf '%s\n' "$@" | sed 's/^/  /' >> "$report_file"
}

# 名前と値を桁揃えした 1 行を JVM_PARAM_ENTRY へ格納する。値を持たない
# オプション (-server, -XX:+UseG1GC 等) は名前だけを出力する。
JVM_PARAM_ENTRY=""
format_jvm_param_entry() {
  local name="$1" value="$2" has_value="$3"
  if is_sensitive_setting_name "$name"; then
    value="[REDACTED]"
  fi
  if [ "$has_value" = "true" ]; then
    printf -v JVM_PARAM_ENTRY '%-*s = %s' "$JVM_PARAM_NAME_WIDTH" "$name" "$value"
  else
    printf -v JVM_PARAM_ENTRY '%s' "$name"
  fi
}

# 1 コンテナ内の Java プロセスごとに、JVM パラメータを分類して report_file へ
# 追記する。JVM オプションは起動対象 (-jar / 主クラス / --module) の手前までで、
# それ以降は起動対象へ渡される引数として分けて表示する。
append_container_jvm_parameter_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local line option value name has_value pid java_bin main_target
  local version_text version_line version_printed process_index=0 option_total app_arg_total
  local arg_index arg_count parsing_jvm_options env_name env_value
  local -a process_lines=() args=() app_args=() jvm_env_entries=()
  local -a memory_entries=() gc_entries=() agent_entries=() otel_entries=()
  local -a jboss_entries=() sysprop_entries=() module_entries=() other_entries=()
  local -A process_env_values=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%=*}"
    [ -n "$name" ] || continue
    value=""
    [ "$name" != "$line" ] && value="${line#*=}"
    process_env_values["$name"]="$value"
  done < <(collect_container_pid1_env "$cid")

  mapfile -t process_lines < <(collect_container_java_processes "$cid")

  printf '\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"
  printf 'Java JVM パラメータ (サービス: %s, コンテナ: %s, Java プロセス: %s)\n' \
      "$service_name" "$container_name" "${#process_lines[@]}" >> "$report_file"
  printf '分類: ヒープ・メモリ / GC / Java エージェント / OpenTelemetry / JBoss / システムプロパティ / クラスパス・モジュール / その他\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"

  if [ ${#process_lines[@]} -eq 0 ]; then
    printf 'Java プロセスを検出できませんでした。\n' >> "$report_file"
    printf '  (このコンテナが JVM を実行していないか、/proc または /bin/sh を読み取れません)\n' >> "$report_file"
  fi

  for line in "${process_lines[@]}"; do
    process_index=$((process_index + 1))
    # コマンドライン末尾の NUL 由来の空フィールドを落としてから分解する。
    while [ "${line: -1}" = "$JVM_FIELD_SEPARATOR" ]; do
      line="${line%"$JVM_FIELD_SEPARATOR"}"
    done
    args=()
    IFS="$JVM_FIELD_SEPARATOR" read -r -a args <<< "$line"

    pid="${args[0]:-(不明)}"
    java_bin="${args[1]:-(不明)}"
    main_target=""
    app_args=()
    memory_entries=(); gc_entries=(); agent_entries=(); otel_entries=()
    jboss_entries=(); sysprop_entries=(); module_entries=(); other_entries=()
    option_total=0
    arg_count=${#args[@]}
    arg_index=2
    parsing_jvm_options="true"

    while [ "$arg_index" -lt "$arg_count" ]; do
      option="${args[$arg_index]}"
      arg_index=$((arg_index + 1))
      [ -n "$option" ] || continue

      if [ "$parsing_jvm_options" != "true" ]; then
        app_args+=("$option")
        continue
      fi

      has_value="false"
      value=""
      name="$option"
      case "$option" in
        -jar)
          main_target="-jar ${args[$arg_index]:-(不明)}"
          arg_index=$((arg_index + 1))
          parsing_jvm_options="false"
          continue
          ;;
        -m|--module)
          main_target="--module ${args[$arg_index]:-(不明)}"
          arg_index=$((arg_index + 1))
          parsing_jvm_options="false"
          continue
          ;;
        -cp|-classpath|--class-path|-p|--module-path|--add-opens|--add-exports|--add-modules|--add-reads|--patch-module|--upgrade-module-path|--limit-modules)
          # これらは次の引数を値として取る書式。値を巻き込んで表示する。
          value="${args[$arg_index]:-}"
          arg_index=$((arg_index + 1))
          has_value="true"
          ;;
        -*)
          split_jvm_option_name_value "$option"
          name="$JVM_OPTION_NAME"
          value="$JVM_OPTION_VALUE"
          has_value="$JVM_OPTION_HAS_VALUE"
          ;;
        *)
          # オプションでない最初の引数が起動する主クラス。以降は起動対象への引数。
          main_target="$option"
          parsing_jvm_options="false"
          continue
          ;;
      esac

      format_jvm_param_entry "$name" "$value" "$has_value"
      classify_jvm_option "$option"
      case "$JVM_OPTION_CATEGORY" in
        memory)  memory_entries+=("$JVM_PARAM_ENTRY") ;;
        gc)      gc_entries+=("$JVM_PARAM_ENTRY") ;;
        agent)   agent_entries+=("$JVM_PARAM_ENTRY") ;;
        otel)    otel_entries+=("$JVM_PARAM_ENTRY") ;;
        jboss)   jboss_entries+=("$JVM_PARAM_ENTRY") ;;
        module)  module_entries+=("$JVM_PARAM_ENTRY") ;;
        sysprop) sysprop_entries+=("$JVM_PARAM_ENTRY") ;;
        *)       other_entries+=("$JVM_PARAM_ENTRY") ;;
      esac
      option_total=$((option_total + 1))
    done

    app_arg_total=${#app_args[@]}
    printf '\n' >> "$report_file"
    printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
    printf '[Java プロセス %s] PID: %s\n' "$process_index" "$pid" >> "$report_file"
    printf '実行ファイル     : %s\n' "$java_bin" >> "$report_file"
    version_text="$(container_java_version_text "$cid" "$java_bin")"
    if [ -n "$version_text" ]; then
      # java -version は複数行を返す。2 行目以降は見出しの幅だけ字下げして続ける。
      version_printed="false"
      while IFS= read -r version_line; do
        [ -n "$version_line" ] || continue
        if [ "$version_printed" = "true" ]; then
          printf '                   %s\n' "$version_line" >> "$report_file"
        else
          printf 'バージョン       : %s\n' "$version_line" >> "$report_file"
          version_printed="true"
        fi
      done <<< "$version_text"
    else
      printf 'バージョン       : (取得できませんでした)\n' >> "$report_file"
    fi
    printf '起動対象         : %s\n' "${main_target:-(検出できませんでした)}" >> "$report_file"
    printf 'JVM パラメータ数 : %s 件\n' "$option_total" >> "$report_file"
    printf '起動対象への引数 : %s 件\n' "$app_arg_total" >> "$report_file"
    printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"

    if [ "$option_total" -eq 0 ]; then
      printf 'JVM パラメータの指定はありません。\n' >> "$report_file"
    else
      append_jvm_option_entries "$report_file" "ヒープ・メモリ" ${memory_entries[@]+"${memory_entries[@]}"}
      append_jvm_option_entries "$report_file" "GC (ガベージコレクション)" ${gc_entries[@]+"${gc_entries[@]}"}
      append_jvm_option_entries "$report_file" "Java エージェント" ${agent_entries[@]+"${agent_entries[@]}"}
      append_jvm_option_entries "$report_file" "OpenTelemetry" ${otel_entries[@]+"${otel_entries[@]}"}
      append_jvm_option_entries "$report_file" "JBoss / WildFly" ${jboss_entries[@]+"${jboss_entries[@]}"}
      append_jvm_option_entries "$report_file" "システムプロパティ (-D)" ${sysprop_entries[@]+"${sysprop_entries[@]}"}
      append_jvm_option_entries "$report_file" "クラスパス・モジュール" ${module_entries[@]+"${module_entries[@]}"}
      append_jvm_option_entries "$report_file" "その他 JVM オプション" ${other_entries[@]+"${other_entries[@]}"}
    fi
    append_jvm_option_entries "$report_file" "起動対象へ渡される引数" ${app_args[@]+"${app_args[@]}"}
  done

  # JAVA_OPTS などで渡した指定は JVM 起動時に追加されるため、
  # /proc/<pid>/cmdline には現れない。取りこぼさないよう別枠で表示する。
  for env_name in "${JVM_OPTION_ENV_NAMES[@]}"; do
    [ -n "${process_env_values[$env_name]+_}" ] || continue
    env_value="${process_env_values[$env_name]}"
    [ -n "$env_value" ] || continue
    format_jvm_param_entry "$env_name" "$env_value" "true"
    jvm_env_entries+=("$JVM_PARAM_ENTRY")
  done

  printf '\n' >> "$report_file"
  if [ ${#jvm_env_entries[@]} -eq 0 ]; then
    printf '[JVM オプションを渡す環境変数] 0 件\n' >> "$report_file"
    printf '  (なし)\n' >> "$report_file"
  else
    append_jvm_option_entries "$report_file" "JVM オプションを渡す環境変数" "${jvm_env_entries[@]}"
    printf '※ 環境変数経由の指定は JVM 起動時に追加されるため、上記のコマンドライン一覧には現れません。\n' >> "$report_file"
  fi
}

# 1 コンテナの OpenTelemetry 関連設定を、環境変数と JVM パラメータの双方から
# 集めて report_file へ追記する。Java を実行しないコンテナ (Collector 等) でも
# 環境変数側は同じ形式で確認できる。
append_container_otel_report() {
  local cid="$1" service_name="$2" container_name="$3" report_file="$4"
  local line key value env_name property_name option token otel_token_found total_found=0
  local -a process_lines=() args=() tokens=()
  local -a standard_entries=() related_entries=() cmdline_entries=()
  local -a env_option_entries=() missing_entries=()
  local -A process_env_values=() defined_properties=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    [ -n "$key" ] || continue
    value=""
    [ "$key" != "$line" ] && value="${line#*=}"
    process_env_values["$key"]="$value"
  done < <(collect_container_pid1_env "$cid")

  # (1) 接頭辞 OTEL_ を持つ標準環境変数
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in
      "$OTEL_ENV_NAME_PREFIX"*) ;;
      *) continue ;;
    esac
    format_jvm_param_entry "$key" "${process_env_values[$key]}" "true"
    standard_entries+=("$JVM_PARAM_ENTRY")
  done < <(printf '%s\n' "${!process_env_values[@]}" | sort)

  # (2) 接頭辞を持たない関連環境変数
  for env_name in "${OTEL_RELATED_ENV_NAMES[@]}"; do
    [ -n "${process_env_values[$env_name]+_}" ] || continue
    format_jvm_param_entry "$env_name" "${process_env_values[$env_name]}" "true"
    related_entries+=("$JVM_PARAM_ENTRY")
  done
  # JVM オプション用の環境変数は、OpenTelemetry を参照している場合だけ関連とみなす。
  # 値には複数のオプションが空白区切りで並ぶため、個々のオプションごとに判定する。
  for env_name in "${OTEL_JVM_OPTION_ENV_NAMES[@]}"; do
    [ -n "${process_env_values[$env_name]+_}" ] || continue
    value="${process_env_values[$env_name]}"
    [ -n "$value" ] || continue
    tokens=()
    read -r -a tokens <<< "$value"
    otel_token_found="false"
    for token in ${tokens[@]+"${tokens[@]}"}; do
      is_otel_jvm_option "$token" || continue
      otel_token_found="true"
      split_jvm_option_name_value "$token"
      format_jvm_param_entry "${env_name}: ${JVM_OPTION_NAME}" "$JVM_OPTION_VALUE" "$JVM_OPTION_HAS_VALUE"
      env_option_entries+=("$JVM_PARAM_ENTRY")
      case "$JVM_OPTION_NAME" in
        -D*) defined_properties["${JVM_OPTION_NAME#-D}"]=1 ;;
      esac
    done
    [ "$otel_token_found" = "true" ] || continue
    format_jvm_param_entry "$env_name" "$value" "true"
    related_entries+=("$JVM_PARAM_ENTRY")
  done

  # (3) Java プロセスのコマンドライン全体 (起動対象への引数も含む)
  mapfile -t process_lines < <(collect_container_java_processes "$cid")
  for line in "${process_lines[@]}"; do
    while [ "${line: -1}" = "$JVM_FIELD_SEPARATOR" ]; do
      line="${line%"$JVM_FIELD_SEPARATOR"}"
    done
    args=()
    IFS="$JVM_FIELD_SEPARATOR" read -r -a args <<< "$line"
    for option in "${args[@]:2}"; do
      [ -n "$option" ] || continue
      is_otel_jvm_option "$option" || continue
      split_jvm_option_name_value "$option"
      format_jvm_param_entry "$JVM_OPTION_NAME" "$JVM_OPTION_VALUE" "$JVM_OPTION_HAS_VALUE"
      cmdline_entries+=("$JVM_PARAM_ENTRY")
      case "$JVM_OPTION_NAME" in
        -D*) defined_properties["${JVM_OPTION_NAME#-D}"]=1 ;;
      esac
    done
  done

  total_found=$(( ${#standard_entries[@]} + ${#related_entries[@]} \
      + ${#cmdline_entries[@]} + ${#env_option_entries[@]} ))

  printf '\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"
  printf 'OpenTelemetry 環境変数・JVM パラメータ一覧 (サービス: %s, コンテナ: %s)\n' \
      "$service_name" "$container_name" >> "$report_file"
  printf '種別: OTEL_ 標準環境変数 / 関連環境変数 / JVM パラメータ (コマンドライン・環境変数由来)\n' >> "$report_file"
  printf '===================================================================\n' >> "$report_file"

  if [ "$total_found" -eq 0 ]; then
    printf 'OpenTelemetry 関連の環境変数・JVM パラメータは検出されませんでした。\n' >> "$report_file"
    return 0
  fi

  append_env_names_by_type "$report_file" "OpenTelemetry 標準環境変数 (${OTEL_ENV_NAME_PREFIX}*)" \
      ${standard_entries[@]+"${standard_entries[@]}"}
  append_env_names_by_type "$report_file" "OpenTelemetry 関連環境変数" \
      ${related_entries[@]+"${related_entries[@]}"}
  append_env_names_by_type "$report_file" "OpenTelemetry 関連 JVM パラメータ (コマンドライン)" \
      ${cmdline_entries[@]+"${cmdline_entries[@]}"}
  append_env_names_by_type "$report_file" "OpenTelemetry 関連 JVM パラメータ (環境変数由来)" \
      ${env_option_entries[@]+"${env_option_entries[@]}"}

  # 環境変数とシステムプロパティのどちらでも指定されていない主要設定を挙げ、
  # 送達不良時に「そもそも設定されていない」ケースを切り分けやすくする。
  for env_name in "${OTEL_KEY_ENV_NAMES[@]}"; do
    [ -z "${process_env_values[$env_name]+_}" ] || continue
    property_name="$(otel_env_name_to_property "$env_name")"
    [ -z "${defined_properties[$property_name]+_}" ] || continue
    missing_entries+=("${env_name} (システムプロパティ -D${property_name} も未設定)")
  done
  append_env_names_by_type "$report_file" "未設定の主要 OpenTelemetry 設定" \
      ${missing_entries[@]+"${missing_entries[@]}"}
}

# append_env_names_by_type / append_jvm_option_entries は既に整形済みの行を
# 受け取るため、画面表示用のラッパーは環境変数一覧・ツリーと同じ流れで書ける。
show_verified_container_jvm_parameters() {
  [ "$DRY_RUN" = "true" ] && {
    log "[DRY-RUN] JBoss EAP デプロイ構造の後に Java JVM パラメータ一覧をプレビューします。"
    return 0
  }

  local report_line cid service_name container_name jvm_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "Java JVM パラメータ一覧を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi
  if ! jvm_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "Java JVM パラメータ一覧出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$jvm_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_jvm_parameter_report "$cid" "$service_name" "$container_name" "$jvm_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$jvm_report_tmp"
  rm -f -- "$jvm_report_tmp"
}

show_verified_container_otel_settings() {
  [ "$DRY_RUN" = "true" ] && {
    log "[DRY-RUN] JVM パラメータの後に OpenTelemetry 環境変数・JVM パラメータ一覧をプレビューします。"
    return 0
  }

  local report_line cid service_name container_name otel_report_tmp
  local -a target_container_ids=()
  mapfile -t target_container_ids < <(verification_target_container_ids)

  if [ ${#target_container_ids[@]} -eq 0 ]; then
    warn "OpenTelemetry 設定一覧を出力できませんでした。対象コンテナが見つかりません。"
    return 0
  fi
  if ! otel_report_tmp="$(mktemp 2>/dev/null)"; then
    warn "OpenTelemetry 設定一覧出力用の一時ファイルを作成できませんでした。"
    return 0
  fi
  : > "$otel_report_tmp"

  for cid in "${target_container_ids[@]}"; do
    [ -n "$cid" ] || continue
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    append_container_otel_report "$cid" "$service_name" "$container_name" "$otel_report_tmp"
  done

  diag ""
  while IFS= read -r report_line; do
    diag "$report_line"
  done < "$otel_report_tmp"
  rm -f -- "$otel_report_tmp"
}

# 対象コンテナがすべて実行中か確認する (途中停止 = 起動失敗の早期検知用)。
# 停止しているコンテナがあれば 1 を返す。
# 一覧には ps -aq を使う。ps -q だと異常終了したコンテナが一覧から消えてループが
# 一度も回らず、「停止を検知できないまま成功」と誤判定してしまうため。
# 同じ理由で、1 件も返らない場合 (コンテナが作られていない / 削除された) も異常とする。
containers_all_running() {
  local cid running found="false"
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    found="true"
    running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)"
    if [ "$running" != "true" ]; then
      return 1
    fi
  done < <(compose_container_ids_all "$@")
  [ "$found" = "true" ] || return 1
  return 0
}

# 調査用の対話操作へ入れるコンテナが 1 つでも起動しているか。
# デプロイエラーでは AP サーバ以外のサイドカーが終了していることもあるため、
# 「全て起動中」ではなく「1 つでも起動中」を条件にする。
any_container_running() {
  local cid running
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)"
    [ "$running" = "true" ] && return 0
  done < <(compose_container_ids_all)
  return 1
}

# 起動確認中に停止した「起動対象サービス」を検出する。
# --startup-service で検証対象を絞っていると、それ以外のサービス (DB へ繋がらずに落ちた
# バックエンド等) の異常終了が見逃され、検証対象のタイムアウトまで待たされてしまうため、
# 起動対象サービス全体の生存を毎ポーリングで確認する。
# 初期化専用など、正常に終了しうるサービスは --allow-service-exit で除外できる。
STOPPED_TARGET_SERVICES=()
target_services_all_running() {
  STOPPED_TARGET_SERVICES=()
  [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ] || return 0
  local svc allowed_service allowed
  for svc in "${COMPOSE_TARGET_SERVICES[@]}"; do
    allowed="false"
    for allowed_service in ${ALLOW_SERVICE_EXIT[@]+"${ALLOW_SERVICE_EXIT[@]}"}; do
      if [ "$allowed_service" = "$svc" ]; then
        allowed="true"
        break
      fi
    done
    [ "$allowed" = "true" ] && continue
    containers_all_running "$svc" || STOPPED_TARGET_SERVICES+=("$svc")
  done
  [ ${#STOPPED_TARGET_SERVICES[@]} -eq 0 ]
}

# コンテナを起動する (バックグラウンド)。対象サービスは 1 回の compose up で
# 同時に起動される。
start_container() {
  if [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
    log "コンテナを同時に起動します (compose up -d, 対象サービス: ${COMPOSE_TARGET_SERVICES[*]}) ..."
    if [ ${#COMPOSE_TARGET_SERVICES[@]} -ne ${#COMPOSE_SERVICES[@]} ]; then
      log "  ベースサービス '${BASE_SERVICE}' はビルド専用のため起動対象から除外しました。"
    fi
  else
    log "コンテナを起動します (compose up -d, 全サービス) ..."
  fi
  # 既存コンテナを再利用した場合に前回起動の WFLYSRV0025 を誤検出しないよう、
  # compose up の直前を今回のログ取得開始時刻として記録する。
  # docker compose logs --since は RFC3339 を受け取る。表示・記録を JST に揃える
  # ため +09:00 付きで生成し、オフセットを組み立てられない環境では UTC 表記へ戻す。
  CONTAINER_LOG_SINCE="$(date '+%Y-%m-%dT%H:%M:%S.%N%:z' 2>/dev/null)"
  case "$CONTAINER_LOG_SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*[+-][0-9][0-9]:[0-9][0-9]) ;;
    *) CONTAINER_LOG_SINCE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" ;;
  esac
  local up_args=(-f "$COMPOSE_FILE" up -d --no-build)
  # --wait を付けると、compose が depends_on の条件に加えて対象サービス自身が
  # healthy (healthcheck 未定義なら running) になるまで待ってから戻る。
  # 依存先の healthcheck が未整備だと待てないため、compose.yml 側の整備が前提。
  if [ "$STARTUP_WAIT" = "true" ]; then
    up_args+=(--wait --wait-timeout "$STARTUP_WAIT_TIMEOUT")
    log "  compose の起動完了待ちを有効にしました (--wait, 最大 ${STARTUP_WAIT_TIMEOUT}s)。"
  fi
  up_args+=(${COMPOSE_TARGET_SERVICES[@]+"${COMPOSE_TARGET_SERVICES[@]}"})
  COMPOSE_UP_ATTEMPTED="true"
  if ! run "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} "${up_args[@]}"; then
    err "コンテナの起動に失敗しました (compose up)"
    return 1
  fi
  STARTED_CONTAINER="true"
  return 0
}

# コンテナを停止・削除する (EXIT トラップから呼び出す)。
teardown_container() {
  [ "$STARTED_CONTAINER" = "true" ] || return 0
  if [ "$KEEP_CONTAINER" = "true" ]; then
    log "コンテナを残します (--keep-container)。手動で停止する場合: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down"
    return 0
  fi
  log "コンテナを停止・削除します (compose down) ..."
  local down_ok=0
  if [ "$SUPPRESS_REMOVED_LOGS" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down > /dev/null 2>&1 || down_ok=$?
  else
    run "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down || down_ok=$?
  fi
  if [ "$down_ok" -ne 0 ]; then
    warn "コンテナの停止・削除に失敗しました。手動で確認してください: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down"
  fi
}

# ---- エラー終了時の終了 (SIGTERM) ログ取得 -----------------------------------
# ECS はタスク停止時に各コンテナへ SIGTERM を送るため、adot collector のような
# サイドカーは「シグナル受信 → パイプラインの graceful shutdown → 終了」までを
# ログへ出す。ローカル検証で compose down まで一気に実行すると、この終了ログは
# 誰にも取得されないままコンテナごと削除されてしまう。
# 特に adot collector の healthcheck が失敗し、depends_on の condition:
# service_healthy を満たせずバックエンドが起動しなかった場合、ECS 上でも同じく
# タスクが停止するため、終了処理まで含んだログが原因調査の手掛かりになる。
# そこでエラー終了時に限り、削除の前に SIGTERM による停止を挟み、そこで追加された
# ログを画面と全量レポートの双方へ残す。

# SIGTERM 送出前後のログ行数の差分を「終了処理で追加された行」として表示する。
# compose logs --since と同じ範囲で数えるため、ホストとコンテナの時刻差に
# 影響されない。
show_service_shutdown_logs() {
  local service_name="$1" before_count="$2"
  local logs total_count new_count new_lines containers

  logs="$(compose_logs "$service_name" | strip_ansi_codes)"
  total_count="$(count_log_lines "$logs")"
  new_count=$(( total_count - before_count ))
  [ "$new_count" -gt 0 ] || new_count=0
  containers="$(compose_service_container_summary "$service_name")"

  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "終了 (SIGTERM) 時のコンテナログ (サービス: ${service_name}, 追加 ${new_count} 行):"
  diag "コンテナ      : ${containers}"
  diag "───────────────────────────────────────────────────────────────────"
  if [ "$new_count" -gt 0 ]; then
    new_lines="$(printf '%s\n' "$logs" | tail -n "$new_count")"
    print_startup_logs_with_highlights "$new_lines"
  else
    diag "SIGTERM 受信後に追加されたログはありません。"
  fi
  diag "───────────────────────────────────────────────────────────────────"
}

# エラー終了時に SIGTERM でコンテナを終了させ、終了処理のログを取得する。
# 環境変数やディレクトリツリーは起動中のコンテナからしか取得できないため、
# 全量レポートではそれらの収集を終えた位置 (ログ本文の直前) から呼び出す。
# レポート出力が無効な場合は後始末から呼ばれるため、二重実行しないよう記録する。
capture_shutdown_logs() {
  local exit_status="$1"
  [ "$SHUTDOWN_LOGS_CAPTURED" = "true" ] && return 0
  [ "$CAPTURE_SHUTDOWN_LOGS" = "true" ] || return 0
  # 成功時は通常の後始末 (compose down) に任せ、終了ログの取得は行わない。
  [ "$exit_status" -ne 0 ] || return 0
  # 調査のためコンテナを残す指定では停止できないため、終了ログも取得しない。
  [ "$KEEP_CONTAINER" != "true" ] || return 0
  # 今回の実行が compose up まで進んでいない場合 (ビルド失敗など) は、
  # 前回の実行が残したコンテナを止めてしまわないよう対象外とする。
  [ "$COMPOSE_UP_ATTEMPTED" = "true" ] || return 0

  SHUTDOWN_LOGS_CAPTURED="true"
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] エラー終了時は SIGTERM (compose stop -t ${SHUTDOWN_LOG_TIMEOUT}) でコンテナを終了させ、終了処理のログまで取得します。"
    return 0
  fi

  local -a running_services=()
  mapfile -t running_services < <(compose_started_services)
  if [ ${#running_services[@]} -eq 0 ]; then
    return 0
  fi

  # 停止前のログ行数をサービスごとに控え、停止後の増分を終了ログとして扱う。
  local svc
  local -a before_counts=()
  for svc in "${running_services[@]}"; do
    before_counts+=("$(count_log_lines "$(compose_logs "$svc" | strip_ansi_codes)")")
  done

  log "エラー終了のため、ECS のタスク停止と同じく SIGTERM でコンテナを終了させ、終了処理のログを取得します (compose stop -t ${SHUTDOWN_LOG_TIMEOUT}, 対象: ${running_services[*]}) ..."
  SHUTDOWN_STOP_EXECUTED="true"
  local stop_status=0
  if [ "$SUPPRESS_REMOVED_LOGS" = "true" ]; then
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" stop -t "$SHUTDOWN_LOG_TIMEOUT" > /dev/null 2>&1 || stop_status=$?
  else
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" stop -t "$SHUTDOWN_LOG_TIMEOUT" || stop_status=$?
  fi
  if [ "$stop_status" -ne 0 ]; then
    warn "SIGTERM による停止に失敗しました (compose stop, exit=${stop_status})。終了処理のログが欠けている可能性があります。"
  fi

  local index=0
  for svc in "${running_services[@]}"; do
    show_service_shutdown_logs "$svc" "${before_counts[$index]}"
    index=$((index + 1))
  done
  return 0
}

# jbosseap サーバーの起動完了をログから待つ。
# --startup-service 指定時は各サービスのログを個別に確認し、全サービスの
# 起動完了をもって成功とする。未指定時は対象サービス全体のログをまとめて確認する。
wait_for_startup() {
  local -a pending=()
  if [ ${#STARTUP_SERVICES[@]} -gt 0 ]; then
    pending=("${STARTUP_SERVICES[@]}")
    log "jbosseap サーバーの起動完了を確認します (対象サービス: ${pending[*]}, 最大 ${STARTUP_TIMEOUT}s, パターン: /${STARTUP_LOG_PATTERN}/) ..."
  else
    log "jbosseap サーバーの起動完了を確認します (最大 ${STARTUP_TIMEOUT}s, パターン: /${STARTUP_LOG_PATTERN}/) ..."
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] compose logs を ${STARTUP_INTERVAL}s 間隔でポーリングし、上記パターンに一致するまで待ちます。"
    return 0
  fi
  local deadline now logs normalized_logs svc failure_line
  local -a remaining=()
  now="$(date +%s)"
  deadline=$(( now + STARTUP_TIMEOUT ))
  while :; do
    if [ ${#pending[@]} -gt 0 ]; then
      # サービスごとにログを確認し、起動完了したものを pending から外す。
      remaining=()
      for svc in "${pending[@]}"; do
        logs="$(compose_logs "$svc")"
        normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
        if grep -qE "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs"; then
          failure_line="$(grep -E "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs" | tail -n 1)"
          err "JBoss EAP 8.1 が正常起動しませんでした: サービス '${svc}'"
          err "  ${failure_line}"
          dump_startup_logs_from_snapshot "$normalized_logs" "対象サービス: ${svc}"
          # AP サーバ自体は起動しており、デプロイの失敗で異常終了しているケース。
          # コンテナ内を調査できるよう、呼び出し元で対話操作へ入れるよう記録する。
          STARTUP_DEPLOY_ERROR="true"
          return 1
        elif grep -qE "$STARTUP_LOG_PATTERN" <<< "$normalized_logs"; then
          log "jbosseap サーバーの起動完了を確認しました: サービス '${svc}'"
          show_startup_logs "$normalized_logs" "対象サービス: ${svc}"
        else
          remaining+=("$svc")
        fi
      done
      pending=(${remaining[@]+"${remaining[@]}"})
      if [ ${#pending[@]} -eq 0 ]; then
        show_companion_service_logs
        log "指定した全サービスの起動完了を確認しました。"
        return 0
      fi
    else
      logs="$(compose_logs)"
      normalized_logs="$(printf '%s\n' "$logs" | strip_ansi_codes)"
      if grep -qE "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs"; then
        failure_line="$(grep -E "$STARTUP_FAILURE_LOG_PATTERN" <<< "$normalized_logs" | tail -n 1)"
        err "JBoss EAP 8.1 が正常起動しませんでした。"
        err "  ${failure_line}"
        dump_startup_logs_from_snapshot "$normalized_logs" "全対象サービス"
        # 上と同じくデプロイエラー扱いとし、調査用の対話操作へ入れるようにする。
        STARTUP_DEPLOY_ERROR="true"
        return 1
      elif grep -qE "$STARTUP_LOG_PATTERN" <<< "$normalized_logs"; then
        log "jbosseap サーバーの起動完了を確認しました。"
        show_startup_logs "$normalized_logs" "全対象サービス"
        show_companion_service_logs
        return 0
      fi
    fi
    # コンテナが途中で停止していないか確認する (起動失敗の早期検知)。
    if ! containers_all_running ${pending[@]+"${pending[@]}"}; then
      err "コンテナが起動途中で停止しました。jbosseap の起動に失敗した可能性があります。"
      dump_startup_logs ${pending[@]+"${pending[@]}"}
      return 1
    fi
    # 検証対象以外の起動対象サービス (DB 接続に失敗して落ちたバックエンド等) の異常終了も
    # 検知する。見逃すと検証対象のタイムアウトまで原因不明のまま待たされるため。
    if ! target_services_all_running; then
      err "起動対象の Compose サービスが停止しました: ${STOPPED_TARGET_SERVICES[*]}"
      err "  依存サービスの準備完了を待てているか (compose.yml の healthcheck / depends_on) を確認してください。"
      err "  正常に終了しうるサービスは --allow-service-exit で除外できます。"
      dump_startup_logs "${STOPPED_TARGET_SERVICES[@]}"
      return 1
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      if [ ${#pending[@]} -gt 0 ]; then
        err "起動確認がタイムアウトしました (${STARTUP_TIMEOUT}s 以内に起動完了ログを検出できなかったサービス: ${pending[*]})。"
      else
        err "起動確認がタイムアウトしました (${STARTUP_TIMEOUT}s 以内に起動完了ログを検出できませんでした)。"
      fi
      dump_startup_logs ${pending[@]+"${pending[@]}"}
      return 1
    fi
    sleep "$STARTUP_INTERVAL"
  done
}

# 取得済みスナップショットを使い、失敗時の起動ログと同時起動サービスログを表示する。
# 失敗原因を隠さないよう、--suppress-startup-logs 指定時もログを表示する。
dump_startup_logs_from_snapshot() {
  local logs="$1" target_desc="$2"
  show_startup_logs "$logs" "$target_desc" "false"
  show_companion_service_logs "false"
}

# 失敗時に設定行数分のコンテナ起動ログを出力する (原因調査用)。
# 引数でサービスを指定した場合はそのサービスのログのみ出力する。
dump_startup_logs() {
  local logs target_desc
  logs="$(compose_logs "$@")"
  if [ $# -gt 0 ]; then
    target_desc="対象サービス: $*"
  else
    target_desc="全対象サービス"
  fi
  dump_startup_logs_from_snapshot "$logs" "$target_desc"
}

# 指定 URL へ HTTP リクエストを送り、期待するステータスコードを確認する。
verify_url() {
  local request_desc="[${URL_METHOD}] ${VERIFY_URL}"
  if [ -n "$URL_CONTENT_TYPE" ]; then
    request_desc="${request_desc} (Content-Type: ${URL_CONTENT_TYPE})"
  fi
  log "URL 応答を確認します: ${request_desc} (期待ステータス: ${EXPECT_STATUS}, 最大 ${URL_TIMEOUT}s) ..."
  if [ "$DRY_RUN" = "true" ]; then
    if [ -n "$URL_BODY_JSON" ]; then
      log "[DRY-RUN] JSON ボディ付きで curl を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    elif [ -n "$URL_BODY_FORM" ]; then
      log "[DRY-RUN] form ボディ付きで curl を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    else
      log "[DRY-RUN] curl で ${VERIFY_URL} を ${URL_INTERVAL}s 間隔で呼び出し、ステータス ${EXPECT_STATUS} を確認します。"
    fi
    return 0
  fi

  local curl_opts=(-s -S -m 30 -o "$URL_BODY_FILE" -w '%{http_code}' -X "$URL_METHOD")
  [ "$URL_INSECURE" = "true" ] && curl_opts+=(-k)
  [ -n "$URL_CONTENT_TYPE" ] && curl_opts+=(-H "Content-Type: ${URL_CONTENT_TYPE}")
  if [ -n "$URL_BODY_JSON" ]; then
    curl_opts+=(--data "$URL_BODY_JSON")
  elif [ -n "$URL_BODY_FORM" ]; then
    curl_opts+=(--data "$URL_BODY_FORM")
  fi

  local deadline now code last_code=""
  now="$(date +%s)"
  deadline=$(( now + URL_TIMEOUT ))
  while :; do
    # curl 失敗 (接続不可等) の場合は code が空/000 になるため、|| true で継続する。
    code="$(curl "${curl_opts[@]}" "$VERIFY_URL" 2>/dev/null || true)"
    [ -z "$code" ] && code="000"
    last_code="$code"
    if [ "$code" = "$EXPECT_STATUS" ]; then
      log "URL 応答を確認しました: HTTP ${code} (期待通り)。"
      show_url_body
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      err "URL 応答の確認に失敗しました: 最後の応答 HTTP ${last_code} (期待: ${EXPECT_STATUS})。"
      show_url_body
      return 1
    fi
    log "  HTTP ${code} (期待 ${EXPECT_STATUS} と不一致)。${URL_INTERVAL}s 後に再試行します ..."
    sleep "$URL_INTERVAL"
  done
}

# 直近の URL 応答本文を (先頭のみ) 表示する。
show_url_body() {
  [ -f "$URL_BODY_FILE" ] || return 0
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "URL 応答本文 (先頭 20 行):"
  diag "───────────────────────────────────────────────────────────────────"
  head -n 20 "$URL_BODY_FILE" >&2
  printf '\n' >&2
  diag "───────────────────────────────────────────────────────────────────"
}

# 起動維持後の対話操作で使う検証対象コンテナを一つ選択する。
# 検証対象が複数ある場合だけ番号入力を求め、単一の場合は自動選択する。
select_interaction_target() {
  local cid service_name container_name duplicate choice index _existing_cid _target_index
  local -a container_ids=() service_names=() container_names=()

  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    duplicate="false"
    for _existing_cid in "${container_ids[@]}"; do
      if [ "$cid" = "$_existing_cid" ]; then
        duplicate="true"
        break
      fi
    done
    [ "$duplicate" = "true" ] || container_ids+=("$cid")
  done < <(verification_target_container_ids)

  if [ ${#container_ids[@]} -eq 0 ]; then
    err "対話操作の対象となる実行中コンテナが見つかりません。"
    return 1
  fi

  for cid in "${container_ids[@]}"; do
    service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
    [ -n "$service_name" ] || service_name="(unknown)"
    container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
    service_names+=("$service_name")
    container_names+=("$container_name")
  done

  index=0
  if [ ${#container_ids[@]} -gt 1 ]; then
    diag ""
    diag "対話操作を行う検証対象コンテナを選択してください:"
    for _target_index in "${!container_ids[@]}"; do
      diag "  $(( _target_index + 1 ))) service=${service_names[$_target_index]}, container=${container_names[$_target_index]}"
    done
    while :; do
      printf '選択番号 [1-%s]: ' "${#container_ids[@]}" >&2
      if ! IFS= read -r choice; then
        err "コンテナ選択を読み取れませんでした。対話可能な端末から実行してください。"
        return 1
      fi
      INTERACTION_MENU_ENTERED="true"
      case "$choice" in
        ''|*[!0-9]*|0*)
          warn "1 から ${#container_ids[@]} の番号を入力してください。"
          ;;
        *)
          if [ "$choice" -ge 1 ] && [ "$choice" -le ${#container_ids[@]} ]; then
            index=$(( choice - 1 ))
            break
          fi
          warn "1 から ${#container_ids[@]} の番号を入力してください。"
          ;;
      esac
    done
  fi

  INTERACTION_CONTAINER_ID="${container_ids[$index]}"
  INTERACTION_SERVICE_NAME="${service_names[$index]}"
  INTERACTION_CONTAINER_NAME="${container_names[$index]}"
  return 0
}

normalize_context_root() {
  local context_root="$1"
  while [ "${context_root#/}" != "$context_root" ]; do
    context_root="${context_root#/}"
  done
  if [ -n "$context_root" ]; then
    context_root="/${context_root}"
  else
    context_root="/"
  fi
  while [ "$context_root" != "/" ] && [ "${context_root%/}" != "$context_root" ]; do
    context_root="${context_root%/}"
  done
  printf '%s\n' "$context_root"
}

# JBoss EAP の登録済み Web コンテキストを WFLYUT0021 から取得する。
# 明示値を優先し、複数検出時はリクエスト対象を番号で選択する。
select_jboss_context_root() {
  local logs="$1" context_root choice index=0 _context_index
  local -a context_roots=()

  if [ -n "$JBOSS_CONTEXT_ROOT" ]; then
    INTERACTION_CONTEXT_ROOT="$(normalize_context_root "$JBOSS_CONTEXT_ROOT")"
    log "指定された JBoss EAP コンテキストルートを使用します: ${INTERACTION_CONTEXT_ROOT}"
    return 0
  fi

  while IFS= read -r context_root; do
    [ -n "$context_root" ] && context_roots+=("$(normalize_context_root "$context_root")")
  done < <(
    printf '%s\n' "$logs" \
      | strip_ansi_codes \
      | sed -nE "s/.*WFLYUT0021:[[:space:]]*Registered web context:[[:space:]]*'?([^'[:space:]]+)'?.*/\1/p" \
      | awk '!seen[$0]++'
  )

  if [ ${#context_roots[@]} -eq 0 ]; then
    INTERACTION_CONTEXT_ROOT="/"
    warn "WFLYUT0021 ログからコンテキストルートを検出できないため、'/' を使用します。"
  elif [ ${#context_roots[@]} -eq 1 ]; then
    INTERACTION_CONTEXT_ROOT="${context_roots[0]}"
    log "JBoss EAP ログからコンテキストルートを検出しました: ${INTERACTION_CONTEXT_ROOT}"
  else
    diag ""
    diag "HTTP 通信に使用する JBoss EAP コンテキストルートを選択してください:"
    for _context_index in "${!context_roots[@]}"; do
      diag "  $(( _context_index + 1 ))) ${context_roots[$_context_index]}"
    done
    while :; do
      printf '選択番号 [1-%s]: ' "${#context_roots[@]}" >&2
      if ! IFS= read -r choice; then
        err "コンテキストルートの選択を読み取れませんでした。"
        return 1
      fi
      case "$choice" in
        ''|*[!0-9]*|0*)
          warn "1 から ${#context_roots[@]} の番号を入力してください。"
          ;;
        *)
          if [ "$choice" -ge 1 ] && [ "$choice" -le ${#context_roots[@]} ]; then
            index=$(( choice - 1 ))
            INTERACTION_CONTEXT_ROOT="${context_roots[$index]}"
            break
          fi
          warn "1 から ${#context_roots[@]} の番号を入力してください。"
          ;;
      esac
    done
  fi
  return 0
}

# JBoss EAP のコンテナ側 HTTP リスナーポートを WFLYUT0006 から検出する。
discover_jboss_http_port() {
  local logs="$1" detected_port=""
  if [ -n "$JBOSS_HTTP_PORT" ]; then
    INTERACTION_CONTAINER_PORT="$JBOSS_HTTP_PORT"
    log "指定された JBoss EAP HTTP リスナーポートを使用します: ${INTERACTION_CONTAINER_PORT}"
    return 0
  fi

  detected_port="$(
    printf '%s\n' "$logs" \
      | strip_ansi_codes \
      | sed -nE 's/.*WFLYUT0006:.*Undertow HTTP listener .* listening on .*:([0-9]+).*/\1/p' \
      | tail -n 1
  )"
  if [ -n "$detected_port" ]; then
    INTERACTION_CONTAINER_PORT="$detected_port"
    log "JBoss EAP ログから HTTP リスナーポートを検出しました: ${INTERACTION_CONTAINER_PORT}"
  else
    INTERACTION_CONTAINER_PORT="8080"
    warn "WFLYUT0006 ログから HTTP リスナーポートを検出できないため、8080 を使用します。"
  fi
}

# コンテナ側リスナーポートを、ホストから curl できるアドレスへ解決する。
# 公開ポートを優先し、未公開ならコンテナ IP、取得不能なら localhost を使う。
resolve_interaction_http_endpoint() {
  local mapping="" mapped_host="" mapped_port="" container_ip=""
  mapping="$(docker port "$INTERACTION_CONTAINER_ID" "${INTERACTION_CONTAINER_PORT}/tcp" 2>/dev/null | sed -n '1p' || true)"
  if [ -n "$mapping" ]; then
    mapped_port="${mapping##*:}"
    mapped_host="${mapping%:*}"
    mapped_host="${mapped_host#[}"
    mapped_host="${mapped_host%]}"
    case "$mapped_host" in
      ""|0.0.0.0|::) mapped_host="127.0.0.1" ;;
    esac
    if printf '%s' "$mapped_port" | grep -qE '^[0-9]+$'; then
      INTERACTION_HTTP_HOST="$mapped_host"
      INTERACTION_HTTP_PORT="$mapped_port"
      log "Docker 公開ポートを検出しました: ${INTERACTION_CONTAINER_PORT}/tcp -> ${INTERACTION_HTTP_HOST}:${INTERACTION_HTTP_PORT}"
      return 0
    fi
  fi

  container_ip="$(
    docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
      "$INTERACTION_CONTAINER_ID" 2>/dev/null | sed -n '/./{p;q;}' || true
  )"
  if [ -n "$container_ip" ]; then
    INTERACTION_HTTP_HOST="$container_ip"
    INTERACTION_HTTP_PORT="$INTERACTION_CONTAINER_PORT"
    warn "HTTP ポートが公開されていないため、コンテナ IP (${INTERACTION_HTTP_HOST}) へ直接接続します。"
  else
    INTERACTION_HTTP_HOST="127.0.0.1"
    INTERACTION_HTTP_PORT="$INTERACTION_CONTAINER_PORT"
    warn "公開ポートとコンテナ IP を取得できないため、localhost:${INTERACTION_HTTP_PORT} を使用します。"
  fi
  return 0
}

join_context_root_and_path() {
  local context_root="$1" request_path="$2"
  if [ -z "$request_path" ]; then
    printf '%s\n' "$context_root"
    return 0
  fi
  if [ "${request_path#\?}" != "$request_path" ]; then
    printf '%s%s\n' "$context_root" "$request_path"
    return 0
  fi
  while [ "${request_path#/}" != "$request_path" ]; do
    request_path="${request_path#/}"
  done
  if [ -z "$request_path" ]; then
    printf '%s\n' "$context_root"
  elif [ "$context_root" = "/" ]; then
    printf '/%s\n' "$request_path"
  else
    printf '%s/%s\n' "$context_root" "$request_path"
  fi
}

prompt_http_request_path() {
  local request_path
  while :; do
    printf 'コンテキストルート以降のパスを入力してください (空入力はルート): ' >&2
    if ! IFS= read -r request_path; then
      err "HTTP パスを読み取れませんでした。"
      return 1
    fi
    case "$request_path" in
      *://*)
        warn "完全な URL ではなく、コンテキストルート以降のパスだけを入力してください。"
        ;;
      *[[:space:]]*)
        warn "パス中の空白はパーセントエンコードして入力してください。"
        ;;
      *)
        HTTP_REQUEST_PATH="$request_path"
        return 0
        ;;
    esac
  done
}

prompt_http_method() {
  local choice
  diag ""
  diag "HTTP メソッドを選択してください:"
  diag "  1) GET"
  diag "  2) POST"
  while :; do
    printf '選択番号 [1-2]: ' >&2
    if ! IFS= read -r choice; then
      err "HTTP メソッドの選択を読み取れませんでした。"
      return 1
    fi
    case "$choice" in
      1|GET|get)
        HTTP_REQUEST_METHOD="GET"
        return 0
        ;;
      2|POST|post)
        HTTP_REQUEST_METHOD="POST"
        return 0
        ;;
      *) warn "1 (GET) または 2 (POST) を選択してください。" ;;
    esac
  done
}

prompt_http_post_body() {
  local choice
  HTTP_REQUEST_BODY=""
  HTTP_REQUEST_CONTENT_TYPE=""
  diag ""
  diag "POST ボディ形式を選択してください:"
  diag "  1) JSON (application/json)"
  diag "  2) form URL encoded (application/x-www-form-urlencoded)"
  while :; do
    printf '選択番号 [1-2]: ' >&2
    if ! IFS= read -r choice; then
      err "POST ボディ形式の選択を読み取れませんでした。"
      return 1
    fi
    case "$choice" in
      1|JSON|json)
        HTTP_REQUEST_CONTENT_TYPE="application/json"
        break
        ;;
      2|FORM|form)
        HTTP_REQUEST_CONTENT_TYPE="application/x-www-form-urlencoded"
        break
        ;;
      *) warn "1 (JSON) または 2 (form URL encoded) を選択してください。" ;;
    esac
  done

  if [ "$HTTP_REQUEST_CONTENT_TYPE" = "application/json" ]; then
    printf 'JSON ボディを 1 行で入力してください: ' >&2
  else
    printf 'form ボディを key=value&key2=value2 形式で入力してください: ' >&2
  fi
  if ! IFS= read -r HTTP_REQUEST_BODY; then
    err "POST ボディを読み取れませんでした。"
    return 1
  fi
  return 0
}

show_interactive_http_response() {
  local request_method="$1" request_url="$2" status_code="$3"
  diag ""
  diag "════════════════════════ HTTP 通信結果 ════════════════════════"
  diag "リクエスト             : [${request_method}] ${request_url}"
  diag "HTTP ステータスコード : ${status_code}"
  diag "────────────────────── レスポンスボディ ──────────────────────"
  if [ -s "$INTERACTIVE_HTTP_BODY_FILE" ]; then
    cat "$INTERACTIVE_HTTP_BODY_FILE" >&2
    printf '\n' >&2
  else
    diag "(空)"
  fi
  diag "═══════════════════════════════════════════════════════════════"
}

run_interactive_http_request() {
  local logs host_for_url request_path request_url status_code curl_status=0
  local -a curl_opts

  if [ "$INTERACTION_SERVICE_NAME" != "(unknown)" ]; then
    logs="$(compose_logs "$INTERACTION_SERVICE_NAME")"
  else
    logs="$(compose_logs)"
  fi
  select_jboss_context_root "$logs" || return 1
  discover_jboss_http_port "$logs" || return 1
  resolve_interaction_http_endpoint || return 1

  host_for_url="$INTERACTION_HTTP_HOST"
  case "$host_for_url" in
    *:*) host_for_url="[${host_for_url}]" ;;
  esac

  diag ""
  diag "対話式 HTTP 通信 (サービス: ${INTERACTION_SERVICE_NAME}, コンテナ: ${INTERACTION_CONTAINER_NAME})"
  diag "  接続先       : http://${host_for_url}:${INTERACTION_HTTP_PORT}"
  diag "  コンテキスト : ${INTERACTION_CONTEXT_ROOT}"
  prompt_http_request_path || return 1
  prompt_http_method || return 1
  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    prompt_http_post_body || return 1
  else
    HTTP_REQUEST_BODY=""
    HTTP_REQUEST_CONTENT_TYPE=""
  fi

  request_path="$(join_context_root_and_path "$INTERACTION_CONTEXT_ROOT" "$HTTP_REQUEST_PATH")"
  request_url="http://${host_for_url}:${INTERACTION_HTTP_PORT}${request_path}"
  if ! INTERACTIVE_HTTP_BODY_FILE="$(mktemp 2>/dev/null)"; then
    err "HTTP レスポンス保存用の一時ファイルを作成できませんでした。"
    return 1
  fi
  : > "$INTERACTIVE_HTTP_BODY_FILE"

  curl_opts=(-sS --noproxy '*' --max-time "$URL_TIMEOUT" --output "$INTERACTIVE_HTTP_BODY_FILE" \
    --write-out '%{http_code}' --request "$HTTP_REQUEST_METHOD")
  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    curl_opts+=(--header "Content-Type: ${HTTP_REQUEST_CONTENT_TYPE}")
    # 入力したボディをプロセス一覧へ露出させないよう、curl の標準入力から渡す。
    curl_opts+=(--data-binary @-)
  fi

  if [ "$HTTP_REQUEST_METHOD" = "POST" ]; then
    status_code="$(printf '%s' "$HTTP_REQUEST_BODY" | curl "${curl_opts[@]}" "$request_url")" || curl_status=$?
  else
    status_code="$(curl "${curl_opts[@]}" "$request_url")" || curl_status=$?
  fi
  [ -n "$status_code" ] || status_code="000"
  show_interactive_http_response "$HTTP_REQUEST_METHOD" "$request_url" "$status_code"
  rm -f -- "$INTERACTIVE_HTTP_BODY_FILE"
  INTERACTIVE_HTTP_BODY_FILE=""

  if [ "$curl_status" -ne 0 ]; then
    err "curl による HTTP 通信に失敗しました (exit=${curl_status}, HTTP=${status_code})。"
    return 1
  fi
  return 0
}

# 選択された Compose サービスについて、今回の compose up 以降のログを
# --startup-log-lines の表示件数で出力する。明示的な対話操作なので、
# --suppress-startup-logs が指定されていてもここでは抑制しない。
show_interactive_compose_service_logs() {
  local service_name="$1" logs

  if ! logs="$(compose_logs "$service_name")"; then
    err "Compose サービス '${service_name}' のログを取得できませんでした。"
    [ -n "$logs" ] && printf '%s\n' "$logs" >&2
    return 1
  fi
  show_startup_logs "$logs" "サービス: ${service_name}" "false" "Compose サービスログ"
}

# healthcheck の設定・履歴・応答には URL や認証関連パラメータが含まれ得るため、
# 画面や build_and_push.sh のログへ残す前に、明示的な機微値だけを伏せ字にする。
redact_healthcheck_text() {
  LC_ALL=C sed -E \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#([?&](password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)=)[^&[:space:]]*#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)[[:space:]]*=[[:space:]]*")[^"]*#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)[[:space:]]*=[[:space:]]*)[^[:space:];]+#\1[REDACTED]#Ig' \
    -e 's#((authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|x-auth-token)[[:space:]]*:[[:space:]]*).*#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)"?[[:space:]]*:[[:space:]]*")[^"]*#\1[REDACTED]#Ig' \
    -e 's#((password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)"?[[:space:]]*:[[:space:]]*"?)[^",}[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#(^|[[:space:]])(--(password|passwd|secret|token|authorization|cookie|api[_-]?key|credential))([=[:space:]]+)[^[:space:]]+#\1\2\4[REDACTED]#Ig' \
    -e 's#(^|[[:space:]])(-u|--user)([=[:space:]]*)[^[:space:]]+#\1\2\3[REDACTED]#g' \
    -e 's#(^|[[:space:]])-p[^$[:space:]][^[:space:]]*#\1-p[REDACTED]#g'
}

# healthcheck の手動再実行や HTTP 補助プローブの出力を、端末を圧迫しない範囲で表示する。
print_healthcheck_capture() {
  local capture_file="$1" empty_message="$2"
  local byte_count display_limit=32768

  if [ ! -s "$capture_file" ]; then
    diag "$empty_message"
    return 0
  fi
  byte_count="$(wc -c < "$capture_file" | tr -d '[:space:]')"
  case "$byte_count" in
    ''|*[!0-9]*) byte_count=0 ;;
  esac
  if [ "$byte_count" -gt "$display_limit" ]; then
    head -c "$display_limit" "$capture_file" | redact_healthcheck_text >&2
    printf '\n' >&2
    diag "... healthcheck 診断出力を ${display_limit}/${byte_count} bytes で省略しました。"
  else
    redact_healthcheck_text < "$capture_file" >&2
    printf '\n' >&2
  fi
}

# ---- healthcheck の実行手段解決 ---------------------------------------------
# adot-collector のような distroless イメージには /bin/sh が無く、CMD-SHELL 形式の
# healthcheck や補助スクリプトをそのまま実行できない。利用できるシェルを順に探し、
# 見つからない場合は呼び出し側でシェル不要の方式へ切り替える。
CONTAINER_SHELL_CACHE_ID=""
CONTAINER_SHELL_CACHE_PATH=""
detect_container_shell() {
  local container_id="$1" shell_candidate
  if [ "$CONTAINER_SHELL_CACHE_ID" != "$container_id" ]; then
    CONTAINER_SHELL_CACHE_ID="$container_id"
    CONTAINER_SHELL_CACHE_PATH=""
    for shell_candidate in /bin/sh /bin/bash /bin/ash /busybox/sh /usr/bin/sh /usr/bin/bash; do
      if docker exec "$container_id" "$shell_candidate" -c 'exit 0' >/dev/null 2>&1; then
        CONTAINER_SHELL_CACHE_PATH="$shell_candidate"
        break
      fi
    done
  fi
  [ -n "$CONTAINER_SHELL_CACHE_PATH" ] || return 1
  printf '%s\n' "$CONTAINER_SHELL_CACHE_PATH"
}

# Config.Healthcheck.Test を取得して配列へ格納する。healthcheck 未設定なら 1 を返す。
HEALTHCHECK_TEST_LINES=()
load_container_healthcheck_test() {
  local container_id="$1" test_text
  HEALTHCHECK_TEST_LINES=()
  test_text="$(
    docker inspect -f \
      '{{if .Config.Healthcheck}}{{range .Config.Healthcheck.Test}}{{println .}}{{end}}{{end}}' \
      "$container_id" 2>/dev/null
  )" || return 1
  [ -n "$test_text" ] || return 1
  mapfile -t HEALTHCHECK_TEST_LINES <<< "$test_text"
  case "${HEALTHCHECK_TEST_LINES[0]:-}" in
    ''|NONE)
      HEALTHCHECK_TEST_LINES=()
      return 1
      ;;
  esac
  return 0
}

# healthcheck 定義 (Test 配列) から、形式・表示用コマンド文字列・実行ファイルパスを
# 組み立てる。CMD / CMD-SHELL 以外は 1 を返す。
HEALTHCHECK_MODE=""
HEALTHCHECK_COMMAND_TEXT=""
HEALTHCHECK_EXECUTABLE_PATH=""
parse_healthcheck_test() {
  local -a test_lines=("$@")

  HEALTHCHECK_MODE="${test_lines[0]:-}"
  HEALTHCHECK_COMMAND_TEXT=""
  HEALTHCHECK_EXECUTABLE_PATH=""
  case "$HEALTHCHECK_MODE" in
    CMD-SHELL)
      HEALTHCHECK_COMMAND_TEXT="${test_lines[1]:-}"
      if [ ${#test_lines[@]} -gt 2 ]; then
        HEALTHCHECK_COMMAND_TEXT+=$'\n'
        HEALTHCHECK_COMMAND_TEXT+="$(printf '%s\n' "${test_lines[@]:2}")"
      fi
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_COMMAND_TEXT%%[[:space:]]*}"
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_EXECUTABLE_PATH#\"}"
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_EXECUTABLE_PATH%\"}"
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_EXECUTABLE_PATH#\'}"
      HEALTHCHECK_EXECUTABLE_PATH="${HEALTHCHECK_EXECUTABLE_PATH%\'}"
      ;;
    CMD)
      printf -v HEALTHCHECK_COMMAND_TEXT '%q ' "${test_lines[@]:1}"
      HEALTHCHECK_COMMAND_TEXT="${HEALTHCHECK_COMMAND_TEXT% }"
      HEALTHCHECK_EXECUTABLE_PATH="${test_lines[1]:-}"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# CMD-SHELL のコマンド文字列を、シェル無しで実行できる引数列へ分解する。
# healthcheck で定型的な `... || exit N` だけは取り除き、それ以外のシェル構文
# (パイプ・リダイレクト・変数展開・クォート) を含む場合は変換しない。
HEALTHCHECK_DIRECT_ARGV=()
build_healthcheck_direct_argv() {
  local command_text="$1" core="$1" trailer

  HEALTHCHECK_DIRECT_ARGV=()
  case "$core" in
    *'||'*)
      trailer="${core#*||}"
      core="${core%%||*}"
      printf '%s' "$trailer" \
        | grep -Eq '^[[:space:]]*exit[[:space:]]+[0-9]+[[:space:]]*$' || return 1
      ;;
  esac
  printf '%s' "$core" \
    | grep -Eq '^[[:space:]]*[A-Za-z0-9_./-]+([[:space:]]+[A-Za-z0-9_./:@=,%?&#+-]+)*[[:space:]]*$' \
    || return 1
  read -r -a HEALTHCHECK_DIRECT_ARGV <<< "$core"
  [ ${#HEALTHCHECK_DIRECT_ARGV[@]} -gt 0 ] || return 1
  return 0
}

# healthcheck コマンドをコンテナ内で実行する。実行手段を次の順に切り替える。
#   1) CMD 形式        : docker exec で直接実行 (シェル不要)
#   2) CMD-SHELL 形式  : コンテナ内シェル (/bin/sh または代替シェル) で実行
#   3) シェルが無い場合: シェル構文を含まなければ引数へ分解して直接実行
# どの手段も使えない場合は 125 を返し、呼び出し側で HTTP 等の別方式へ切り替える。
HEALTHCHECK_TIMEOUT_RUNNER=()
HEALTHCHECK_EXEC_METHOD=""
HEALTHCHECK_EXEC_AVAILABLE="false"
run_healthcheck_command_with_fallback() {
  local container_id="$1" health_mode="$2" health_command_text="$3" output_file="$4"
  shift 4
  local -a command_argv=("$@")
  local shell_path status=0

  HEALTHCHECK_EXEC_METHOD=""
  HEALTHCHECK_EXEC_AVAILABLE="false"

  if [ "$health_mode" = "CMD" ]; then
    HEALTHCHECK_EXEC_AVAILABLE="true"
    HEALTHCHECK_EXEC_METHOD="docker exec で直接実行 (コンテナ内シェル不要)"
    ${HEALTHCHECK_TIMEOUT_RUNNER[@]+"${HEALTHCHECK_TIMEOUT_RUNNER[@]}"} \
      docker exec "$container_id" "${command_argv[@]}" \
      >"$output_file" 2>&1 || status=$?
    return "$status"
  fi

  if shell_path="$(detect_container_shell "$container_id")"; then
    HEALTHCHECK_EXEC_AVAILABLE="true"
    HEALTHCHECK_EXEC_METHOD="コンテナ内シェル ${shell_path} で実行"
    ${HEALTHCHECK_TIMEOUT_RUNNER[@]+"${HEALTHCHECK_TIMEOUT_RUNNER[@]}"} \
      docker exec "$container_id" "$shell_path" -c "$health_command_text" \
      >"$output_file" 2>&1 || status=$?
    return "$status"
  fi

  if build_healthcheck_direct_argv "$health_command_text"; then
    HEALTHCHECK_EXEC_AVAILABLE="true"
    HEALTHCHECK_EXEC_METHOD="コンテナ内にシェルが無いため docker exec で直接実行: ${HEALTHCHECK_DIRECT_ARGV[*]}"
    ${HEALTHCHECK_TIMEOUT_RUNNER[@]+"${HEALTHCHECK_TIMEOUT_RUNNER[@]}"} \
      docker exec "$container_id" "${HEALTHCHECK_DIRECT_ARGV[@]}" \
      >"$output_file" 2>&1 || status=$?
    return "$status"
  fi

  HEALTHCHECK_EXEC_METHOD="コンテナ内にシェルが無く、シェル構文を含むコマンドのため実行不可"
  return 125
}

# healthcheck URL (コンテナ内から見たアドレス) を、ホストから到達できる URL へ変換する。
# 公開ポートを優先し、未公開ならコンテナ IP を使う。解決できない場合は 1 を返す。
resolve_healthcheck_url_for_host() {
  local container_id="$1" url="$2"
  local scheme rest hostport path port mapping mapped_host mapped_port container_ip host_for_url

  case "$url" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  scheme="${url%%://*}"
  rest="${url#*://}"
  case "$rest" in
    */*)
      hostport="${rest%%/*}"
      path="/${rest#*/}"
      ;;
    *)
      hostport="$rest"
      path="/"
      ;;
  esac
  case "$hostport" in
    \[*\]:*) port="${hostport##*:}" ;;
    \[*\])   port="" ;;
    *:*)     port="${hostport##*:}" ;;
    *)       port="" ;;
  esac
  if [ -z "$port" ]; then
    case "$scheme" in
      https) port="443" ;;
      *)     port="80" ;;
    esac
  fi
  printf '%s' "$port" | grep -qE '^[0-9]+$' || return 1

  mapping="$(docker port "$container_id" "${port}/tcp" 2>/dev/null | sed -n '1p' || true)"
  if [ -n "$mapping" ]; then
    mapped_port="${mapping##*:}"
    mapped_host="${mapping%:*}"
    mapped_host="${mapped_host#[}"
    mapped_host="${mapped_host%]}"
    case "$mapped_host" in
      ""|0.0.0.0|::) mapped_host="127.0.0.1" ;;
    esac
    if printf '%s' "$mapped_port" | grep -qE '^[0-9]+$'; then
      host_for_url="$mapped_host"
      case "$host_for_url" in
        *:*) host_for_url="[${host_for_url}]" ;;
      esac
      printf '%s://%s:%s%s\n' "$scheme" "$host_for_url" "$mapped_port" "$path"
      return 0
    fi
  fi

  container_ip="$(
    docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
      "$container_id" 2>/dev/null | sed -n '/./{p;q;}' || true
  )"
  [ -n "$container_ip" ] || return 1
  host_for_url="$container_ip"
  case "$host_for_url" in
    *:*) host_for_url="[${host_for_url}]" ;;
  esac
  printf '%s://%s:%s%s\n' "$scheme" "$host_for_url" "$port" "$path"
}

# 自動確認の手段が尽きた場合に、利用者が手元で実行できるコマンドを案内する。
# 認証情報の混入を避けるため、コマンド行は伏せ字処理を通して表示する。
print_healthcheck_manual_commands() {
  local service_name="$1" container_name="$2" health_mode="$3"
  local health_command_text="$4" http_url="$5" container_id="$6"
  local host_url=""

  diag ""
  diag "[手動で確認する場合のコマンド]"
  diag "  # Docker が記録した healthcheck の状態と履歴 (コンテナ内シェル不要)"
  diag "  docker inspect --format '{{json .State.Health}}' ${container_name}"
  diag "  # コンテナのログから稼働状況を確認"
  diag "  ${COMPOSE_CMD[*]} -f ${COMPOSE_FILE} logs ${service_name}"
  case "$health_mode" in
    CMD)
      diag "  # healthcheck と同じコマンドを直接実行 (シェル不要)"
      printf '  docker exec %s %s\n' "$container_name" "$health_command_text" \
        | redact_healthcheck_text >&2
      ;;
    CMD-SHELL)
      diag "  # シェルを持つイメージであれば同じコマンド文字列を実行"
      printf "  docker exec %s /bin/sh -c '%s'\n" "$container_name" "$health_command_text" \
        | redact_healthcheck_text >&2
      ;;
  esac
  if [ -n "$http_url" ]; then
    host_url="$(resolve_healthcheck_url_for_host "$container_id" "$http_url" || true)"
    diag "  # 対象コンテナのネットワークを借りた一時コンテナから HTTP 確認"
    diag "  # (対象イメージに curl/wget が無くても確認できる)"
    printf '  docker run --rm --network container:%s curlimages/curl:latest -sS -i %s\n' \
      "$container_name" "$http_url" | redact_healthcheck_text >&2
    if [ -n "$host_url" ]; then
      diag "  # ホストから公開ポート経由で HTTP 確認"
      printf '  curl -sS -i %s\n' "$host_url" | redact_healthcheck_text >&2
    fi
  fi
}

# CMD 形式で直接指定された /healthcheck 等について、実際に呼ばれるファイルの
# 存在・実行権限・内容識別用 SHA-256 をコンテナ内で確認する。
# シェルを持たないイメージでは確認できないため、その旨だけを表示する。
show_healthcheck_executable_file() {
  local container_id="$1" executable_path="$2" file_info file_status=0 shell_path

  case "$executable_path" in
    /*) ;;
    *) return 0 ;;
  esac

  if ! shell_path="$(detect_container_shell "$container_id")"; then
    diag ""
    diag "[healthcheck 実行ファイル]"
    diag "コンテナ内にシェルが無いため、ファイル情報を取得できません: ${executable_path}"
    diag "イメージ側から確認する場合: docker cp <コンテナ>:${executable_path} ./healthcheck-binary"
    return 0
  fi

  file_info="$(
    docker exec "$container_id" "$shell_path" -c '
      target=$1
      if [ ! -e "$target" ]; then
        printf "ファイル: %s (存在しません)\n" "$target"
        exit 66
      fi
      printf "ファイル: %s\n" "$target"
      ls -ld -- "$target" 2>/dev/null || ls -ld "$target"
      if [ -x "$target" ]; then
        printf "実行権限: あり\n"
      else
        printf "実行権限: なし\n"
      fi
      if [ -f "$target" ] && command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$target" 2>/dev/null || sha256sum "$target"
      elif [ -f "$target" ] && command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$target"
      else
        printf "SHA-256: 算出ツールなし、または通常ファイルではないため未取得\n"
      fi
    ' healthcheck-file "$executable_path" 2>&1
  )" || file_status=$?

  diag ""
  diag "[healthcheck 実行ファイル]"
  printf '%s\n' "$file_info" | redact_healthcheck_text >&2
  if [ "$file_status" -ne 0 ]; then
    warn "healthcheck 実行ファイルを完全には確認できませんでした (exit=${file_status})。"
  fi
}

# curl の通信メトリクス出力書式 (コンテナ側・ホスト側の補助リクエストで共用)。
HEALTHCHECK_CURL_METRICS_FORMAT='
[通信メトリクス]
http_status=%{http_code}
remote=%{remote_ip}:%{remote_port}
local=%{local_ip}:%{local_port}
time_connect=%{time_connect}s
time_starttransfer=%{time_starttransfer}s
time_total=%{time_total}s
size_download=%{size_download} bytes
'

# ホスト側にある HTTP クライアントを返す (curl 優先、無ければ wget)。
detect_host_http_tool() {
  local tool
  for tool in curl wget; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%s\n' "$tool"
      return 0
    fi
  done
  return 1
}

# ホストから URL へ補助リクエストを送る。コンテナ内にシェルや curl/wget が無い
# (distroless イメージ等) 場合のフォールバック経路。
run_healthcheck_http_probe_on_host() {
  local tool="$1" request_method="$2" request_url="$3" output_file="$4"
  local status=0
  local -a curl_args=()

  case "$tool" in
    curl)
      curl_args=(--silent --show-error --verbose --include --noproxy '*'
        --max-time "$URL_TIMEOUT" --max-filesize 1048576
        --write-out "$HEALTHCHECK_CURL_METRICS_FORMAT")
      if [ "$request_method" = "HEAD" ]; then
        curl_args+=(--head)
      fi
      curl "${curl_args[@]}" "$request_url" >"$output_file" 2>&1 || status=$?
      ;;
    wget)
      wget -S -O - -T "$URL_TIMEOUT" "$request_url" >"$output_file" 2>&1 || status=$?
      ;;
    *)
      return 125
      ;;
  esac
  return "$status"
}

# 単純な curl / wget の HTTP healthcheck について、元のチェックとは別のボディなし
# 補助リクエストを同じコンテナのネットワーク名前空間から送り、ヘッダー・本文・
# 接続メトリクスを表示する。認証ヘッダーやリクエストボディを伴う複雑な設定は扱わない。
# コンテナにシェルが無い、または curl/wget が無い場合は、公開ポート (無ければ
# コンテナ IP) へホスト側から送り直して確認する。
run_healthcheck_http_probe() {
  local container_id="$1" probe_kind="$2" request_method="$3" request_url="$4"
  local probe_status=0 probe_script shell_path="" probe_origin="" probe_url="$request_url"
  local container_probe_done="false" host_tool="" host_url=""

  case "$probe_kind" in
    curl|wget) ;;
    *) return 1 ;;
  esac
  if ! HEALTHCHECK_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
    warn "healthcheck HTTP 通信の保存用一時ファイルを作成できませんでした。"
    return 1
  fi
  : > "$HEALTHCHECK_DIAGNOSTIC_FILE"

  if shell_path="$(detect_container_shell "$container_id")"; then
    container_probe_done="true"
    probe_origin="選択したコンテナのネットワーク名前空間 (${shell_path})"
    case "$probe_kind" in
      curl)
        probe_script="$(cat <<HEALTHCHECK_CURL_PROBE
set -u
health_url=\$1
health_timeout=\$2
health_method=\$3
if ! command -v curl >/dev/null 2>&1; then
  printf "curl がコンテナ内にありません。\n" >&2
  exit 127
fi
set -- \\
  --silent \\
  --show-error \\
  --verbose \\
  --include \\
  --max-time "\$health_timeout" \\
  --max-filesize 1048576 \\
  --write-out '${HEALTHCHECK_CURL_METRICS_FORMAT}'
if [ "\$health_method" = "HEAD" ]; then
  set -- "\$@" --head
fi
exec curl "\$@" "\$health_url"
HEALTHCHECK_CURL_PROBE
)"
        docker exec "$container_id" "$shell_path" -c "$probe_script" \
          healthcheck-http-probe "$request_url" "$URL_TIMEOUT" "$request_method" \
          >"$HEALTHCHECK_DIAGNOSTIC_FILE" 2>&1 || probe_status=$?
        ;;
      wget)
        probe_script="$(cat <<'HEALTHCHECK_WGET_PROBE'
set -u
health_url=$1
health_timeout=$2
if ! command -v wget >/dev/null 2>&1; then
  printf "wget がコンテナ内にありません。\n" >&2
  exit 127
fi
exec wget -S -O - -T "$health_timeout" "$health_url"
HEALTHCHECK_WGET_PROBE
)"
        docker exec "$container_id" "$shell_path" -c "$probe_script" \
          healthcheck-http-probe "$request_url" "$URL_TIMEOUT" \
          >"$HEALTHCHECK_DIAGNOSTIC_FILE" 2>&1 || probe_status=$?
        ;;
    esac
  fi

  # コンテナ内で実行できない (シェル無し)、または curl/wget が無い (exit 127) 場合は、
  # ホストから到達できる URL へ切り替えて同じ確認を試みる。
  if [ "$container_probe_done" != "true" ] || [ "$probe_status" -eq 127 ]; then
    if [ "$container_probe_done" = "true" ]; then
      warn "コンテナ内に ${probe_kind} が無いため、ホストからの HTTP 確認へ切り替えます。"
    else
      warn "コンテナ内にシェルが無いため、ホストからの HTTP 確認へ切り替えます。"
    fi
    if host_url="$(resolve_healthcheck_url_for_host "$container_id" "$request_url")" \
        && host_tool="$(detect_host_http_tool)"; then
      probe_url="$host_url"
      probe_origin="ホスト (${host_tool}、コンテナへは公開ポート/コンテナ IP 経由)"
      probe_status=0
      : > "$HEALTHCHECK_DIAGNOSTIC_FILE"
      run_healthcheck_http_probe_on_host \
        "$host_tool" "$request_method" "$host_url" "$HEALTHCHECK_DIAGNOSTIC_FILE" \
        || probe_status=$?
    elif [ "$container_probe_done" != "true" ]; then
      rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
      HEALTHCHECK_DIAGNOSTIC_FILE=""
      warn "コンテナ内でもホストからも HTTP 確認を実行できませんでした。"
      return 125
    fi
  fi

  diag ""
  diag "[HTTP healthcheck 通信詳細（補助リクエスト）]"
  diag "送信元     : ${probe_origin}"
  printf 'リクエスト : [%s] %s\n' "$request_method" "$probe_url" \
    | redact_healthcheck_text >&2
  diag "追加ヘッダー/ボディ: なし（通信詳細取得用の補助リクエスト）"
  diag "終了コード : ${probe_status}"
  diag "レスポンス : ヘッダー、本文、または接続エラー（最大 32768 bytes）"
  diag "───────────────────────────────────────────────────────────────────"
  print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" \
    "(レスポンス本文・ヘッダー・接続エラー出力はありません)"
  rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
  HEALTHCHECK_DIAGNOSTIC_FILE=""
  if [ "$probe_status" -ne 0 ]; then
    warn "healthcheck の HTTP 補助リクエストに失敗しました (exit=${probe_status})。"
  fi
  # 呼び出し側が「別方式でも確認できなかった」を判断できるよう、実際の結果を返す。
  return "$probe_status"
}

# healthcheck コマンドから安全に再送できる単純な HTTP(S) URL を抽出し、
# curl / wget の補助プローブへ振り分ける。URL が無い、または補助リクエストを
# 自動生成できない場合は、手元で実行できるコマンドを案内する。
run_healthcheck_http_details() {
  local container_id="$1" health_command_text="$2"
  local service_name="${3:-}" container_name="${4:-}" health_mode="${5:-}"
  local http_url probe_kind="" request_method="GET" probe_status=0

  http_url="$(
    printf '%s\n' "$health_command_text" \
      | grep -Eo "https?://[^[:space:]\"'<>|;&)]+" \
      | head -n 1 || true
  )"
  if [ -z "$http_url" ]; then
    diag ""
    diag "[通信・リクエスト・レスポンス]"
    diag "HTTP(S) URL を含む healthcheck ではないため、HTTP 補助リクエストは対象外です。"
    diag "通信成否とコマンド出力は、Docker 実行履歴および手動再実行結果を確認してください。"
    if [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ] && [ -n "$container_name" ]; then
      print_healthcheck_manual_commands "$service_name" "$container_name" \
        "$health_mode" "$health_command_text" "" "$container_id"
    fi
    return 0
  fi
  if printf '%s\n' "$http_url" \
      | grep -qiE '://[^/@[:space:]]+:[^/@[:space:]]+@|[?&](password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)='; then
    warn "healthcheck URL に認証情報らしき値が含まれるため、コマンドライン露出を避けて HTTP 補助リクエストをスキップします。"
    return 0
  fi
  case "$http_url" in
    *'$'*|*'`'*)
      warn "healthcheck URL にシェル展開が必要なため、HTTP 補助リクエストをスキップします: ${http_url}"
      return 0
      ;;
  esac

  if printf '%s\n' "$health_command_text" \
      | grep -Eq '(^|[[:space:];|&()])curl([[:space:]]|$)'; then
    probe_kind="curl"
    if printf ' %s ' "$health_command_text" \
        | grep -Eq '(^|[[:space:]])(-X|--request|-d|--data[^[:space:]]*|-H|--header|-u|--user)([=[:space:]]|$)'; then
      warn "healthcheck にメソッド・ヘッダー・ボディ・認証の指定があるため、安全な HTTP 補助リクエストを自動生成できません。"
      diag "正確な実行結果は上の手動再実行結果を確認してください。"
      if [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ] && [ -n "$container_name" ]; then
        print_healthcheck_manual_commands "$service_name" "$container_name" \
          "$health_mode" "$health_command_text" "$http_url" "$container_id"
      fi
      return 0
    fi
    if printf ' %s ' "$health_command_text" \
        | grep -Eq '(^|[[:space:]])(-I|--head)([[:space:]]|$)'; then
      request_method="HEAD"
    fi
  elif printf '%s\n' "$health_command_text" \
      | grep -Eq '(^|[[:space:];|&()])wget([[:space:]]|$)'; then
    probe_kind="wget"
  elif [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ]; then
    # 専用バイナリ等でコマンドを再実行できない場合でも、URL が判明していれば
    # 同じ URL への HTTP 確認で代替できるため、curl 相当の補助リクエストを試みる。
    probe_kind="curl"
    diag ""
    diag "[通信・リクエスト・レスポンス]"
    diag "healthcheck コマンドを再実行できないため、検出した URL への HTTP 確認で代替します。"
  else
    diag ""
    diag "[通信・リクエスト・レスポンス]"
    diag "HTTP(S) URL は検出しましたが、curl / wget 以外のため補助リクエストは実行しません。"
    diag "正確な実行結果は上の手動再実行結果を確認してください。"
    return 0
  fi

  run_healthcheck_http_probe "$container_id" "$probe_kind" "$request_method" "$http_url" \
    || probe_status=$?
  if [ "$probe_status" -eq 0 ]; then
    diag "注意: 補助リクエストは単純な GET/HEAD の通信詳細取得用で、Docker の health 状態・履歴を更新しません。"
  fi
  if [ -n "$container_name" ] \
      && { [ "$probe_status" -ne 0 ] || [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ]; }; then
    print_healthcheck_manual_commands "$service_name" "$container_name" \
      "$health_mode" "$health_command_text" "$http_url" "$container_id"
  fi
  return 0
}

# 選択された Compose サービスの Docker healthcheck を診断する。
# Docker が実際に実行した直近履歴と、現在時点での同一コマンド手動再実行を分けて表示する。
run_interactive_compose_healthcheck() {
  local service_name="$1" container_id container_name health_test_text health_mode
  local health_config health_state health_status health_failing_streak health_history
  local health_state_loaded="true" health_history_loaded="true"
  local retained_count=0 health_command_text="" health_command_display=""
  local executable_path="" exact_started_at exact_finished_at exact_started_epoch exact_finished_epoch
  local exact_timeout_label exact_status=0
  local -a container_ids=() health_test=() exact_runner=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  if ! health_test_text="$(
    docker inspect -f \
      '{{if .Config.Healthcheck}}{{range .Config.Healthcheck.Test}}{{println .}}{{end}}{{end}}' \
      "$container_id"
  )"; then
    err "コンテナの healthcheck 設定を取得できませんでした: ${container_name}"
    return 1
  fi
  if [ -n "$health_test_text" ]; then
    mapfile -t health_test <<< "$health_test_text"
  fi
  health_mode="${health_test[0]:-}"

  diag ""
  diag "════════════════ Docker healthcheck 診断 ════════════════"
  diag "Compose サービス : ${service_name}"
  diag "コンテナ         : ${container_name}"
  if [ -z "$health_mode" ] || [ "$health_mode" = "NONE" ]; then
    diag "設定             : healthcheck は設定されていません。"
    diag "Docker 実行履歴  : 対象外"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi

  if parse_healthcheck_test "${health_test[@]}"; then
    health_command_text="$HEALTHCHECK_COMMAND_TEXT"
    health_command_display="$health_command_text"
    executable_path="$HEALTHCHECK_EXECUTABLE_PATH"
  else
    warn "未対応の healthcheck 形式です: ${health_mode}"
    diag "設定値:"
    printf '%s\n' "$health_test_text" | redact_healthcheck_text >&2
    diag "════════════════════════════════════════════════════════"
    return 0
  fi

  if ! health_config="$(
    docker inspect -f \
      '{{if .Config.Healthcheck}}interval={{.Config.Healthcheck.Interval}}{{"\n"}}timeout={{.Config.Healthcheck.Timeout}}{{"\n"}}retries={{.Config.Healthcheck.Retries}}{{"\n"}}start_period={{.Config.Healthcheck.StartPeriod}}{{end}}' \
      "$container_id"
  )"; then
    health_config="(取得失敗)"
  fi
  if ! health_state="$(
    docker inspect -f \
      '{{if .State.Health}}{{.State.Health.Status}}|{{.State.Health.FailingStreak}}{{end}}' \
      "$container_id" 2>/dev/null
  )"; then
    health_state=""
    health_state_loaded="false"
  fi
  if ! health_history="$(
    docker inspect -f \
      '{{if .State.Health}}{{range .State.Health.Log}}開始: {{.Start}}{{"\n"}}終了: {{.End}}{{"\n"}}終了コード: {{.ExitCode}}{{"\n"}}出力:{{"\n"}}{{.Output}}{{"\n"}}────────────────────{{"\n"}}{{end}}{{end}}' \
      "$container_id" 2>/dev/null
  )"; then
    health_history=""
    health_history_loaded="false"
  fi

  diag ""
  diag "[設定（Docker に反映された Config.Healthcheck）]"
  diag "形式:"
  diag "  ${health_mode}"
  diag "コマンド:"
  printf '%s\n' "$health_command_display" | redact_healthcheck_text >&2
  printf '%s\n' "$health_config" | sed 's/^/  /' >&2

  diag ""
  diag "[Docker が実際に実行した healthcheck]"
  if [ "$health_state_loaded" != "true" ]; then
    diag "現在状態       : Docker inspect に失敗したため未取得"
    diag "連続失敗回数   : 未取得"
  elif [ -n "$health_state" ]; then
    health_status="${health_state%%|*}"
    health_failing_streak="${health_state#*|}"
    diag "現在状態       : ${health_status}"
    diag "連続失敗回数   : ${health_failing_streak}"
  else
    diag "現在状態       : Docker の health 状態はまだ生成されていません。"
    diag "連続失敗回数   : 未取得"
  fi
  if [ "$health_history_loaded" != "true" ]; then
    diag "保持された履歴 : Docker inspect に失敗したため未取得"
  elif [ -n "$health_history" ]; then
    retained_count="$(printf '%s\n' "$health_history" | grep -c '^開始: ' || true)"
    diag "保持された履歴 : ${retained_count} 件 (時刻は JST 表記へ変換)"
    diag "───────────────────────────────────────────────────────────────────"
    printf '%s\n' "$health_history" | rewrite_health_history_time | redact_healthcheck_text >&2
  else
    diag "保持された履歴 : 0 件（まだ未実行、または Docker が履歴を保持していません）"
  fi

  case "$executable_path" in
    /*) show_healthcheck_executable_file "$container_id" "$executable_path" ;;
  esac

  if printf '%s\n' "$health_command_text" \
      | grep -qiE '://[^/@[:space:]]+:[^/@[:space:]]+@|[?&](password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)=|(^|[[:space:];])(password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)[[:space:]]*=|(^|[[:space:]])(-u[^[:space:]]*:[^[:space:]]+|(-u|--user)(=|[[:space:]])+[^[:space:]]*:[^[:space:]]+)|(^|[[:space:]])--(password|passwd|secret|token|authorization|cookie|api[_-]?key|credential)([=[:space:]]|$)|(^|[[:space:]])-p[^$[:space:]]|(authorization|proxy-authorization|cookie|x-api-key|api-key|x-auth-token)[[:space:]]*:'; then
    warn "healthcheck コマンドに認証情報らしき指定があるため、ホストのプロセス引数への露出を避けて手動再実行と HTTP 補助リクエストをスキップします。"
    diag "Docker が実際に実行した結果は、上の State.Health と実行履歴を確認してください。"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi

  if [ ${#health_test[@]} -lt 2 ] || [ -z "$health_command_text" ]; then
    warn "healthcheck の実行コマンドが空のため、手動再実行をスキップします。"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi
  if ! HEALTHCHECK_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
    warn "healthcheck 手動再実行の保存用一時ファイルを作成できませんでした。"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi
  : > "$HEALTHCHECK_DIAGNOSTIC_FILE"
  if command -v timeout >/dev/null 2>&1; then
    exact_runner=(timeout "${URL_TIMEOUT}s")
    exact_timeout_label="${URL_TIMEOUT} 秒 (--url-timeout)"
  else
    exact_timeout_label="未適用 (timeout コマンドなし)"
    warn "ホストに timeout コマンドがないため、healthcheck 手動再実行へ時間上限を適用できません。"
  fi
  HEALTHCHECK_TIMEOUT_RUNNER=(${exact_runner[@]+"${exact_runner[@]}"})
  exact_started_at="$(now_display_time)"
  exact_started_epoch="$(date +%s)"
  run_healthcheck_command_with_fallback \
    "$container_id" "$health_mode" "$health_command_text" "$HEALTHCHECK_DIAGNOSTIC_FILE" \
    "${health_test[@]:1}" || exact_status=$?
  exact_finished_epoch="$(date +%s)"
  exact_finished_at="$(now_display_time)"

  diag ""
  diag "[現在時点の healthcheck コマンド手動再実行]"
  diag "注意: この手動再実行は Docker の health 状態・履歴を更新しません。"
  diag "実行方式   : ${HEALTHCHECK_EXEC_METHOD}"
  if [ "$HEALTHCHECK_EXEC_AVAILABLE" != "true" ]; then
    # /bin/sh が無いイメージ (distroless 等) では、コマンドをそのまま再実行できない。
    # HTTP など別方式での確認と、手元で実行できるコマンドの案内へ切り替える。
    rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
    HEALTHCHECK_DIAGNOSTIC_FILE=""
    warn "コンテナ内で healthcheck コマンドを再実行できないため、別方式での確認へ切り替えます。"
    diag "Docker が実際に実行した結果は、上の State.Health と実行履歴を確認してください。"
    run_healthcheck_http_details \
      "$container_id" "$health_command_text" "$service_name" "$container_name" "$health_mode"
    diag "════════════════════════════════════════════════════════"
    return 0
  fi
  diag "開始       : ${exact_started_at}"
  diag "終了       : ${exact_finished_at}"
  diag "実行上限   : ${exact_timeout_label}"
  diag "所要時間   : $(( exact_finished_epoch - exact_started_epoch )) 秒"
  diag "終了コード : ${exact_status}"
  diag "stdout/stderr（最大 32768 bytes）:"
  diag "───────────────────────────────────────────────────────────────────"
  print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" \
    "(stdout/stderr 出力なし。終了コードで成否を確認してください)"
  rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
  HEALTHCHECK_DIAGNOSTIC_FILE=""
  if [ "$exact_status" -eq 0 ]; then
    diag "手動再実行結果 : OK"
  else
    diag "手動再実行結果 : NG (exit=${exact_status})"
  fi

  run_healthcheck_http_details \
    "$container_id" "$health_command_text" "$service_name" "$container_name" "$health_mode"
  diag "════════════════════════════════════════════════════════"
  return 0
}

# 選択された Compose サービスの実行中コンテナへ対話式 bash で接続する。
# 同じシェルセッションが続くため、cd で移動しながら任意のコマンドを実行できる。
run_interactive_compose_bash() {
  local service_name="$1" container_id container_name
  local -a container_ids=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  diag ""
  diag "Compose サービスの bash へ接続します (service=${service_name}, container=${container_name})。"
  diag "この bash セッション内では cd によるディレクトリ移動と任意のコマンド実行が可能です。"
  diag "bash を終了するとサービス操作の選択へ戻ります。コンテナは起動状態を維持します。"
  if ! docker exec -it "$container_id" /bin/bash; then
    err "Compose サービス '${service_name}' の /bin/bash へ接続できませんでした: ${container_name}"
    return 1
  fi
  log "コンテナの bash セッションを終了しました。サービス操作の選択へ戻ります。"
}

# 選択された Compose サービスが MySQL サーバーコンテナかを実行ファイルで判定する。
# サービス名やイメージタグへ依存せず、MySQL 8.0.42 と
# MySQL 8.4 / Aurora 8.4 互換系の双方を同じ経路で扱う。
compose_service_supports_mysql_client() {
  local service_name="$1" container_id
  local -a container_ids=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  [ ${#container_ids[@]} -gt 0 ] || return 1
  container_id="${container_ids[0]}"
  docker exec "$container_id" /bin/sh -c '
    command -v mysql >/dev/null 2>&1 \
      && command -v mysqld >/dev/null 2>&1
  ' >/dev/null 2>&1
}

# MySQL コンテナ内の mysql クライアントへ接続し、SQL を対話実行する。
# 認証情報は Docker のコマンドラインへ含めず、コンテナ内で MYSQL_* または
# MYSQL_*_FILE から解決して、一時的なクライアントオプションファイルへ格納する。
run_interactive_compose_mysql() {
  local service_name="$1" container_id container_name mysql_client_script
  local -a container_ids=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  mysql_client_script="$(cat <<'MYSQL_CLIENT_SCRIPT'
set -eu

read_mysql_setting() {
  _mysql_setting_value="$1"
  _mysql_setting_file="$2"
  _mysql_setting_name="$3"
  if [ -n "$_mysql_setting_value" ] && [ -n "$_mysql_setting_file" ]; then
    printf '%s と %s_FILE を同時には指定できません。\n' \
      "$_mysql_setting_name" "$_mysql_setting_name" >&2
    return 64
  fi
  if [ -n "$_mysql_setting_file" ]; then
    if [ ! -r "$_mysql_setting_file" ]; then
      printf '%s_FILE の参照先を読み取れません: %s\n' \
        "$_mysql_setting_name" "$_mysql_setting_file" >&2
      return 66
    fi
    cat -- "$_mysql_setting_file"
  else
    printf '%s' "$_mysql_setting_value"
  fi
}

# MySQL のオプションファイルで意味を持つバイトをエスケープする。
# LC_ALL=C と od を使い、改行を含む Docker secret も 1 行の値として安全に記録する。
escape_mysql_option_value() {
  LC_ALL=C od -An -v -t u1 | LC_ALL=C awk '
    {
      for (i = 1; i <= NF; i++) {
        byte = $i + 0
        if (byte == 8) {
          printf "\\b"
        } else if (byte == 9) {
          printf "\\t"
        } else if (byte == 10) {
          printf "\\n"
        } else if (byte == 13) {
          printf "\\r"
        } else if (byte == 34) {
          printf "\\\""
        } else if (byte == 92) {
          printf "\\\\"
        } else {
          printf "%c", byte
        }
      }
    }
  '
}

for mysql_required_command in mysql mktemp od awk cat rm; do
  if ! command -v "$mysql_required_command" >/dev/null 2>&1; then
    printf 'MySQL 接続に必要なコマンドがコンテナ内に見つかりません: %s\n' \
      "$mysql_required_command" >&2
    exit 127
  fi
done

mysql_configured_user="$(read_mysql_setting \
  "${MYSQL_USER:-}" "${MYSQL_USER_FILE:-}" MYSQL_USER)" || exit $?
mysql_database="$(read_mysql_setting \
  "${MYSQL_DATABASE:-}" "${MYSQL_DATABASE_FILE:-}" MYSQL_DATABASE)" || exit $?
mysql_password_known=false

if [ -n "$mysql_configured_user" ] && [ "$mysql_configured_user" != "root" ]; then
  mysql_user="$mysql_configured_user"
  mysql_password="$(read_mysql_setting \
    "${MYSQL_PASSWORD:-}" "${MYSQL_PASSWORD_FILE:-}" MYSQL_PASSWORD)" || exit $?
  if [ "${MYSQL_PASSWORD+x}" = "x" ] || [ -n "${MYSQL_PASSWORD_FILE:-}" ]; then
    mysql_password_known=true
  fi
else
  mysql_user=root
  mysql_password="$(read_mysql_setting \
    "${MYSQL_ROOT_PASSWORD:-}" "${MYSQL_ROOT_PASSWORD_FILE:-}" \
    MYSQL_ROOT_PASSWORD)" || exit $?
  if [ "${MYSQL_ROOT_PASSWORD+x}" = "x" ] \
      || [ -n "${MYSQL_ROOT_PASSWORD_FILE:-}" ] \
      || [ -n "${MYSQL_ALLOW_EMPTY_PASSWORD:-}" ]; then
    mysql_password_known=true
  fi
fi

umask 077
mysql_option_file="$(mktemp /tmp/build-and-verify-mysql-client.XXXXXX)"
cleanup_mysql_option_file() {
  rm -f -- "$mysql_option_file"
}
trap cleanup_mysql_option_file EXIT HUP INT TERM

{
  printf '[client]\n'
  if [ "$mysql_password_known" = "true" ]; then
    printf 'password="'
    printf '%s' "$mysql_password" | escape_mysql_option_value
    printf '"\n'
  fi
} > "$mysql_option_file"

set -- --defaults-extra-file="$mysql_option_file" --protocol=socket --user="$mysql_user"
if [ "$mysql_password_known" != "true" ]; then
  printf 'MYSQL_* からパスワードを解決できないため、ユーザー %s のパスワードを入力してください。\n' \
    "$mysql_user" >&2
  set -- "$@" --password
fi
if [ -n "$mysql_database" ]; then
  set -- "$@" --database="$mysql_database"
fi
mysql "$@"
MYSQL_CLIENT_SCRIPT
)"

  diag ""
  diag "MySQL クライアントへ接続します (service=${service_name}, container=${container_name})。"
  diag "SQL クエリを対話実行できます。終了するには exit または \\q を入力してください。"
  diag "MySQL クライアントを終了するとサービス操作の選択へ戻ります。"
  if ! docker exec -it "$container_id" /bin/sh -c "$mysql_client_script"; then
    err "Compose サービス '${service_name}' の MySQL クライアントへ接続できませんでした: ${container_name}"
    return 1
  fi
  log "MySQL セッションを終了しました。サービス操作の選択へ戻ります。"
}

# 選択された Compose サービスが「JVM トラストストアと HTTPS 接続先を持つ AP コンテナ」かを、
# サービス名やイメージタグではなくコンテナ内の設定だけで判定する。front / back のように
# 自己証明書 (cacert.crt) を取り込んだコンテナでのみ証明書チェックを表示することで、
# 選択後に接続先やトラストストアを入力させずに済ませる。
compose_service_supports_cert_check() {
  local service_name="$1" container_id
  local -a container_ids=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  [ ${#container_ids[@]} -gt 0 ] || return 1
  container_id="${container_ids[0]}"
  docker exec "$container_id" /bin/sh -c '
    # cert-check-probe: 証明書チェックに必要な道具と設定がそろっているか
    command -v curl >/dev/null 2>&1 || exit 1
    if ! command -v keytool >/dev/null 2>&1; then
      { [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/keytool" ]; } || exit 1
    fi
    cert_probe_env="$(env 2>/dev/null)" || exit 1
    printf "%s\n" "$cert_probe_env" \
      | grep -q "^[A-Za-z_][A-Za-z0-9_]*=https://" || exit 1
    # JAVA_TOOL_OPTIONS で渡した -D は argv に現れないため、cmdline だけでなく
    # 起動中プロセスの environ も見る (JBoss の standalone.sh がこの渡し方をする)。
    for cert_probe_proc in /proc/[0-9]*; do
      if [ -r "$cert_probe_proc/cmdline" ] \
          && tr "\0" "\n" < "$cert_probe_proc/cmdline" 2>/dev/null \
            | grep -q -- "-Djavax.net.ssl.trustStore="; then
        exit 0
      fi
      if [ -r "$cert_probe_proc/environ" ] \
          && tr "\0" "\n" < "$cert_probe_proc/environ" 2>/dev/null \
            | sed -n -e "s/^JAVA_TOOL_OPTIONS=//p" -e "s/^JAVA_OPTS=//p" \
                     -e "s/^JDK_JAVA_OPTIONS=//p" \
            | grep -q -- "-Djavax.net.ssl.trustStore="; then
        exit 0
      fi
    done
    printf "%s\n" "$cert_probe_env" \
      | grep -qE "^[A-Za-z_][A-Za-z0-9_]*(TRUSTSTORE|TRUST_STORE)[A-Za-z0-9_]*=/" || exit 1
    exit 0
  ' >/dev/null 2>&1
}

# front / back のように自己証明書を取り込んだコンテナで、そのコンテナ自身の curl から
# HTTPS の REST API (別 Compose サービスの secure-api / ALB 等) へ接続できるかを確認する。
# トラストストア・パスワード・接続先・CA 証明書はすべてコンテナ内の JVM 引数と環境変数から
# 検出するため、選択後の入力は不要。パスワードはコンテナ内でだけ解決し、
# docker exec のコマンドライン (ホストのプロセス引数) には一切載せない。
run_interactive_compose_cert_check() {
  local service_name="$1" container_id container_name cert_check_script
  local capture_file="" exec_status=0
  local -a container_ids=()

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  cert_check_script="$(cat <<'CERT_CHECK_SCRIPT'
set -u
# cert-check-report: トラストストアと HTTPS 接続先をコンテナ内の設定だけから検出し、
# そのコンテナ自身の curl で HTTPS 接続できるかを検証する。
# 追加のパラメータ入力を不要にするため、次の順で自動検出する。
#   トラストストア : 起動中 JVM の -Djavax.net.ssl.trustStore → *TRUSTSTORE* 環境変数
#   パスワード     : 同 -Djavax.net.ssl.trustStorePassword → *TRUSTSTORE*PASSWORD 環境変数
#                    → changeit → パスワード無し (整合性チェック省略)
#   接続先         : https:// で始まる値を持つ環境変数 (SECURE_API_URL 等)
#   CA 証明書      : ${PKI_TRUST_DIR}/*.crt → *CACERT* / *CA_BUNDLE* 環境変数
# 終了コード: 0 = 判定 OK / 1 = 判定 NG / 2 = 検出できず実行不能

CC_PASS=0
CC_FAIL=0
CC_WARN=0
CC_SKIP=0
CC_CONNECT_TIMEOUT=5
CC_MAX_TIME=15
CC_MAX_STORES=3
CC_MAX_TARGETS=4
CC_TAB="$(printf '\t')"

cc_section() { printf '\n=== %s ===\n' "$1"; }
cc_info()    { printf '     %s\n' "$1"; }
cc_pass()    { CC_PASS=$((CC_PASS + 1)); printf '[PASS] %s\n' "$1"; }
cc_fail()    { CC_FAIL=$((CC_FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
cc_warn()    { CC_WARN=$((CC_WARN + 1)); printf '[WARN] %s\n' "$1"; }
cc_skip()    { CC_SKIP=$((CC_SKIP + 1)); printf '[SKIP] %s\n' "$1"; }

if ! command -v curl >/dev/null 2>&1; then
  printf 'curl がコンテナ内に見つからないため証明書チェックを実行できません。\n'
  exit 2
fi

CC_KEYTOOL=""
if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/keytool" ]; then
  # AP サーバを動かしている JVM の keytool を優先する。PATH 上の keytool が
  # 古い Java だと PKCS12 のトラストストアを読めないことがあるため。
  CC_KEYTOOL="${JAVA_HOME}/bin/keytool"
elif command -v keytool >/dev/null 2>&1; then
  CC_KEYTOOL="$(command -v keytool)"
fi
if [ -z "$CC_KEYTOOL" ]; then
  printf 'keytool がコンテナ内に見つからないため証明書チェックを実行できません。\n'
  exit 2
fi

umask 077
if ! CC_DIR="$(mktemp -d 2>/dev/null)"; then
  printf '証明書チェック用の一時ディレクトリを作成できません。\n'
  exit 2
fi
cc_cleanup() { rm -rf -- "$CC_DIR"; }
trap cc_cleanup EXIT HUP INT TERM

# 環境変数はパスワードを含み得るため、ファイルへは書き出さずシェル変数だけで扱う。
CC_ENV="$(env 2>/dev/null || true)"

# 起動中 JVM のトラストストア指定を 1 プロセス分だけ拾う。
# JAVA_TOOL_OPTIONS / JAVA_OPTS で渡した -D は argv に現れない (JVM が起動時に
# 環境変数から読む) ため、cmdline に無ければ environ 側も見る。JBoss の
# standalone.sh 経由の起動はこちらに該当する。
# 値は 1 行 1 トークンへ正規化し、以降の -D 解析を cmdline と共通にする。
# 標準入力のトークン列から -D<名前>= の値を 1 つ取り出す。
# `sh -c "java -D..."` のように 1 トークンへ複数の -D が詰まっている場合があるため、
# 行頭固定にはせずマーカー以降を取り、最初の空白で切る。
cc_scan_dvalue() {
  sed -n "s/.*-D$1=//p" | sed 's/[[:space:]].*//' | head -n 1
}

CC_JVM_ARGS=""
CC_JVM_SOURCE=""
for cc_proc in /proc/[0-9]*; do
  if [ -r "$cc_proc/cmdline" ]; then
    cc_args="$(tr '\0' '\n' < "$cc_proc/cmdline" 2>/dev/null || true)"
    cc_try="$(printf '%s\n' "$cc_args" | cc_scan_dvalue 'javax\.net\.ssl\.trustStore')"
    if [ -n "$cc_try" ]; then
      CC_JVM_ARGS="$cc_args"
      CC_JVM_SOURCE='コマンドライン引数'
      break
    fi
  fi
  if [ -r "$cc_proc/environ" ]; then
    cc_args="$(tr '\0' '\n' < "$cc_proc/environ" 2>/dev/null \
      | sed -n -e 's/^JAVA_TOOL_OPTIONS=//p' -e 's/^JAVA_OPTS=//p' \
               -e 's/^JDK_JAVA_OPTIONS=//p' \
      | tr ' ' '\n' || true)"
    cc_try="$(printf '%s\n' "$cc_args" | cc_scan_dvalue 'javax\.net\.ssl\.trustStore')"
    if [ -n "$cc_try" ]; then
      CC_JVM_ARGS="$cc_args"
      CC_JVM_SOURCE='JAVA_TOOL_OPTIONS 等の環境変数'
      break
    fi
  fi
done

# パスワードは画面へ出さず、使用する瞬間だけ名前から値を解決する。
cc_password_of() {
  case "$1" in
    jvm)
      printf '%s\n' "$CC_JVM_ARGS" \
        | cc_scan_dvalue 'javax\.net\.ssl\.trustStorePassword'
      ;;
    default) printf 'changeit' ;;
    none) : ;;
    env:*)
      cc_pw_name="${1#env:}"
      if command -v printenv >/dev/null 2>&1; then
        printenv "$cc_pw_name" 2>/dev/null || :
      else
        eval "printf '%s' \"\${${cc_pw_name}:-}\""
      fi
      ;;
  esac
}

CC_STORES_FILE="$CC_DIR/stores.tsv"
: > "$CC_STORES_FILE"
cc_add_store() {
  [ -n "${1:-}" ] || return 0
  if cut -d"$CC_TAB" -f1 "$CC_STORES_FILE" | grep -qxF -- "$1"; then
    return 0
  fi
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CC_STORES_FILE"
}

if [ -n "$CC_JVM_ARGS" ]; then
  cc_jvm_store="$(printf '%s\n' "$CC_JVM_ARGS" \
    | cc_scan_dvalue 'javax\.net\.ssl\.trustStore')"
  cc_add_store "$cc_jvm_store" "起動中 JVM の -Djavax.net.ssl.trustStore (${CC_JVM_SOURCE})" 'jvm'
fi

# *TRUSTSTORE* / *TRUST_STORE* を名前に含み、絶対パスを値に持つ環境変数。
# パスワード・種別・別名の変数はストア本体ではないため除外する。
printf '%s\n' "$CC_ENV" \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*(TRUSTSTORE|TRUST_STORE)[A-Za-z0-9_]*=/' \
  | grep -Ev '^[^=]*(PASSWORD|PASSWD|PASS|TYPE|ALIAS)[^=]*=' \
  > "$CC_DIR/store-env.txt" 2>/dev/null || :
while IFS= read -r cc_line; do
  [ -n "$cc_line" ] || continue
  cc_name="${cc_line%%=*}"
  cc_value="${cc_line#*=}"
  case "$cc_name" in
    *_FILE) cc_pw_env="${cc_name%_FILE}_PASSWORD" ;;
    *_PATH) cc_pw_env="${cc_name%_PATH}_PASSWORD" ;;
    *)      cc_pw_env="${cc_name}_PASSWORD" ;;
  esac
  cc_add_store "$cc_value" "環境変数 ${cc_name}" "env:${cc_pw_env}"
done < "$CC_DIR/store-env.txt"

# https:// を値に持つ環境変数を接続先として使う (SECURE_API_URL 等)。
CC_TARGETS_FILE="$CC_DIR/targets.txt"
printf '%s\n' "$CC_ENV" \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*=https://[^[:space:]]+$' \
  | sort -u > "$CC_TARGETS_FILE" 2>/dev/null || : > "$CC_TARGETS_FILE"

CC_CACERTS_FILE="$CC_DIR/cacerts.txt"
: > "$CC_CACERTS_FILE"
cc_add_cacert() {
  { [ -n "${1:-}" ] && [ -r "$1" ]; } || return 0
  grep -qxF -- "$1" "$CC_CACERTS_FILE" && return 0
  printf '%s\n' "$1" >> "$CC_CACERTS_FILE"
}
if [ -n "${PKI_TRUST_DIR:-}" ] && [ -d "${PKI_TRUST_DIR}" ]; then
  for cc_crt in "${PKI_TRUST_DIR}"/*.crt; do
    cc_add_cacert "$cc_crt"
  done
fi
printf '%s\n' "$CC_ENV" \
  | grep -E '^[^=]*(CACERT|CA_CERT|CA_BUNDLE)[^=]*=/' \
  > "$CC_DIR/cacert-env.txt" 2>/dev/null || :
while IFS= read -r cc_line; do
  [ -n "$cc_line" ] || continue
  cc_add_cacert "${cc_line#*=}"
done < "$CC_DIR/cacert-env.txt"

cc_count_lines() {
  cc_lines="$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]')"
  case "${cc_lines:-}" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$cc_lines" ;;
  esac
}

# =====================================================================
# 診断用ヘルパー
#   curl の終了コードだけでは「何が足りないのか」まで分からない。
#   openssl があるときはサーバが実際に提示した証明書チェーンを取得し、
#   トラストストアの中身と突き合わせて原因まで出す。
#   openssl が無くても curl による合否判定は行う (診断の粒度が落ちるだけ)。
# =====================================================================
CC_OPENSSL=''
if command -v openssl >/dev/null 2>&1; then
  CC_OPENSSL="$(command -v openssl)"
fi
CC_TIMEOUT=''
if command -v timeout >/dev/null 2>&1; then
  CC_TIMEOUT="$(command -v timeout)"
fi

# 原因コードを溜めておき、最後の「次の一手」でまとめて対処を出す。
# 同じ原因を接続先・ストアの数だけ繰り返さないよう重複は落とす。
CC_HINTS_FILE="$CC_DIR/hints.txt"
: > "$CC_HINTS_FILE"
cc_hint() {
  grep -qxF -- "$1" "$CC_HINTS_FILE" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$CC_HINTS_FILE"
}
cc_has_hint() { grep -qxF -- "$1" "$CC_HINTS_FILE" 2>/dev/null; }

cc_x509() {  # $1=PEM ファイル, $2.. = openssl x509 のオプション
  [ -n "$CC_OPENSSL" ] || return 1
  cc_x509_file="$1"; shift
  "$CC_OPENSSL" x509 -in "$cc_x509_file" -noout "$@" 2>/dev/null
}
cc_subject_of()      { cc_x509 "$1" -subject | sed 's/^subject=[[:space:]]*//'; }
cc_issuer_of()       { cc_x509 "$1" -issuer  | sed 's/^issuer=[[:space:]]*//'; }
cc_fp_of()           { cc_x509 "$1" -fingerprint -sha256 | sed 's/^.*=//' | tr -d '\r'; }
cc_notbefore_of()    { cc_x509 "$1" -startdate | sed 's/^notBefore=//'; }
cc_notafter_of()     { cc_x509 "$1" -enddate   | sed 's/^notAfter=//'; }
# subject_hash / issuer_hash は DN の正規化ハッシュ。文字列表現の揺れ
# (CN = foo と CN=foo など) に左右されずに「発行者 = この CA か」を判定できる。
cc_subject_hash_of() { cc_x509 "$1" -subject_hash; }
cc_issuer_hash_of()  { cc_x509 "$1" -issuer_hash; }
cc_is_expired() {
  [ -n "$CC_OPENSSL" ] || return 1
  ! "$CC_OPENSSL" x509 -in "$1" -noout -checkend 0 >/dev/null 2>&1
}
cc_is_ca() { cc_x509 "$1" -text | grep -q 'CA:TRUE'; }
# SAN は「X509v3 Subject Alternative Name:」の次の行に入る
cc_san_of() {
  cc_x509 "$1" -text \
    | sed -n '/X509v3 Subject Alternative Name/{n;s/^[[:space:]]*//;p;}' \
    | head -n 1
}
# subject と issuer が同じで、かつ自分自身の公開鍵で署名を検証できる = 自己署名。
# 自己署名 CA はチェーンの最上位であり、クライアントが直接信頼している必要がある。
cc_is_selfsigned() {
  [ -n "$CC_OPENSSL" ] || return 1
  [ "$(cc_subject_hash_of "$1")" = "$(cc_issuer_hash_of "$1")" ] || return 1
  "$CC_OPENSSL" verify -CAfile "$1" "$1" >/dev/null 2>&1
}

# URL からホストとポートを取り出す (openssl s_client / 名前解決の確認で使う)。
# 認証情報付き (user:pass@host) と IPv6 リテラル ([::1]:8443) にも対応する。
cc_url_hostport() {
  cc_hp="${1#*://}"
  cc_hp="${cc_hp%%/*}"
  cc_hp="${cc_hp##*@}"
  case "$cc_hp" in
    '['*']:'*) cc_uh="${cc_hp%%]*}]" ; cc_up="${cc_hp##*]:}" ;;
    '['*']')   cc_uh="$cc_hp"        ; cc_up='443' ;;
    *:*)       cc_uh="${cc_hp%%:*}"  ; cc_up="${cc_hp##*:}" ;;
    *)         cc_uh="$cc_hp"        ; cc_up='443' ;;
  esac
  printf '%s\t%s\n' "$cc_uh" "$cc_up"
}

# 接続先ホスト名が証明書の SAN に含まれるか (ワイルドカードは 1 ラベルのみ)。
# パイプの while はサブシェルで走り return が呼び出し元へ伝わらないため、
# 一致はマーカーファイルの有無で受け渡す。
cc_host_matches_san() {  # $1=ホスト名 $2=SAN 文字列
  cc_hm_host="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  rm -f -- "$CC_DIR/hostmatch"
  printf '%s' "$2" | tr ',' '\n' | tr 'A-Z' 'a-z' | while IFS= read -r cc_hm_ent; do
    cc_hm_ent="$(printf '%s' "$cc_hm_ent" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$cc_hm_ent" in
      dns:*)          cc_hm_val="${cc_hm_ent#dns:}" ;;
      'ip address:'*) cc_hm_val="${cc_hm_ent#ip address:}" ;;
      *) continue ;;
    esac
    if [ "$cc_hm_val" = "$cc_hm_host" ]; then
      : > "$CC_DIR/hostmatch"
      continue
    fi
    case "$cc_hm_val" in
      '*.'*)
        cc_hm_suffix="${cc_hm_val#\*}"
        case "$cc_hm_host" in
          *"$cc_hm_suffix")
            cc_hm_prefix="${cc_hm_host%"$cc_hm_suffix"}"
            case "$cc_hm_prefix" in
              ''|*.*) ;;
              *) : > "$CC_DIR/hostmatch" ;;
            esac
            ;;
        esac
        ;;
    esac
  done
  [ -f "$CC_DIR/hostmatch" ]
}

# ストアを 1 枚ずつに分割したディレクトリから、subject_hash が一致する
# 証明書 (= 探している発行者 CA) のパスを返す。
cc_find_in_store() {  # $1=split ディレクトリ $2=探す subject_hash
  [ -d "$1" ] && [ -n "${2:-}" ] || return 1
  for cc_fis_pem in "$1"/cert-*.pem; do
    [ -r "$cc_fis_pem" ] || continue
    if [ "$(cc_subject_hash_of "$cc_fis_pem")" = "$2" ]; then
      printf '%s\n' "$cc_fis_pem"
      return 0
    fi
  done
  return 1
}

# JDK 同梱 cacerts に入っている証明書の SHA-256 一覧 (1 度だけ取得して使い回す)。
# 「このトラストストアが JDK 標準に対して何を足したものか」を出すために使う。
CC_JDK_FP_FILE="$CC_DIR/jdk-cacerts-fp.txt"
CC_JDK_CACERTS=''
cc_load_jdk_cacerts_fp() {
  [ -f "$CC_JDK_FP_FILE" ] && return 0
  : > "$CC_JDK_FP_FILE"
  # JDK 同梱 cacerts の既定パスワードもリテラルでは書かず、cc_password_of 経由で
  # 解決する (この文字列がホスト側のプロセス引数へ載らないようにするため)。
  cc_jdk_pw="$(cc_password_of default)"
  for cc_jc in "${JAVA_HOME:-}/lib/security/cacerts" \
               "${JAVA_HOME:-}/jre/lib/security/cacerts" \
               /etc/pki/ca-trust/extracted/java/cacerts; do
    [ -r "$cc_jc" ] || continue
    "$CC_KEYTOOL" -list -keystore "$cc_jc" -storepass "$cc_jdk_pw" \
      > "$CC_DIR/jdk-list.out" 2>/dev/null < /dev/null || continue
    # 指紋の 16 進表記だけを拾う。見出し行はロケール依存だが値は依存しない。
    # JDK 8 の keytool は既定が SHA-1 のため 0 件になる (その場合は差分表示を諦める)。
    grep -oE '([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}' "$CC_DIR/jdk-list.out" \
      | tr 'a-f' 'A-F' | sort -u > "$CC_JDK_FP_FILE"
    CC_JDK_CACERTS="$cc_jc"
    break
  done
  cc_jdk_pw=''
  return 0
}

CC_STORE_TOTAL="$(cc_count_lines "$CC_STORES_FILE")"
CC_TARGET_TOTAL="$(cc_count_lines "$CC_TARGETS_FILE")"
CC_CACERT_TOTAL="$(cc_count_lines "$CC_CACERTS_FILE")"

# 上限で打ち切ると未確認の対象が残るため、判定と同じ場所にその旨を出す。
# 結果欄だけを見て「全件 OK」と読み違えないようにする。
cc_truncation_note() {
  if [ "$CC_STORE_TOTAL" -gt "$CC_MAX_STORES" ]; then
    printf '  注意: 検出したトラストストア %s 件のうち先頭 %s 件のみ確認しました。\n' \
      "$CC_STORE_TOTAL" "$CC_MAX_STORES"
  fi
  if [ "$CC_TARGET_TOTAL" -gt "$CC_MAX_TARGETS" ]; then
    printf '  注意: 検出した接続先 %s 件のうち先頭 %s 件のみ確認しました。\n' \
      "$CC_TARGET_TOTAL" "$CC_MAX_TARGETS"
  fi
}

cc_section '0. コンテナ内から検出した設定'
cc_info "keytool         : $CC_KEYTOOL"
if [ -n "$CC_OPENSSL" ]; then
  cc_info "openssl         : $CC_OPENSSL (チェーン解析と原因の特定に使用)"
else
  cc_info 'openssl         : 見つからない (curl の合否のみ。失敗理由の特定はできない)'
fi
if [ -n "$CC_JVM_ARGS" ]; then
  cc_info "JVM             : -Djavax.net.ssl.trustStore を検出した (${CC_JVM_SOURCE})"
else
  cc_info 'JVM             : トラストストアを指定した起動中プロセスは見つからなかった'
fi

if [ "$CC_STORE_TOTAL" -eq 0 ]; then
  printf '\nトラストストアを検出できませんでした。\n'
  printf '  -Djavax.net.ssl.trustStore を付けて JVM を起動しているか、\n'
  printf '  トラストストアのパスを持つ *TRUSTSTORE* 環境変数があるか確認してください。\n'
  exit 2
fi
if [ "$CC_TARGET_TOTAL" -eq 0 ]; then
  printf '\nHTTPS の接続先を検出できませんでした。\n'
  printf '  https:// で始まる値を持つ環境変数 (SECURE_API_URL 等) を設定してください。\n'
  exit 2
fi

cc_info "トラストストア  : ${CC_STORE_TOTAL} 件"
while IFS="$CC_TAB" read -r cc_store cc_source cc_pwtoken; do
  [ -n "$cc_store" ] || continue
  cc_info "  - ${cc_store}  (${cc_source})"
done < "$CC_STORES_FILE"
cc_info "接続先          : ${CC_TARGET_TOTAL} 件"
while IFS= read -r cc_line; do
  [ -n "$cc_line" ] || continue
  cc_info "  - ${cc_line%%=*} = ${cc_line#*=}"
done < "$CC_TARGETS_FILE"
if [ "$CC_CACERT_TOTAL" -gt 0 ]; then
  cc_info "CA 証明書       : ${CC_CACERT_TOTAL} 件 (フィンガープリント照合に使用)"
  while IFS= read -r cc_line; do
    [ -n "$cc_line" ] || continue
    cc_info "  - ${cc_line}"
  done < "$CC_CACERTS_FILE"
else
  cc_info 'CA 証明書       : 検出なし (フィンガープリント照合は行わない)'
fi
if [ "$CC_STORE_TOTAL" -gt "$CC_MAX_STORES" ] || [ "$CC_TARGET_TOTAL" -gt "$CC_MAX_TARGETS" ]; then
  cc_info "確認件数の上限  : トラストストア ${CC_MAX_STORES} 件 / 接続先 ${CC_MAX_TARGETS} 件まで"
fi

# =====================================================================
# 1. トラストストアから PEM バンドルを書き出す
#    curl は JKS / PKCS12 を直接読めないため keytool -rfc で PEM へ変換する。
# =====================================================================
CC_READY_FILE="$CC_DIR/ready.tsv"
: > "$CC_READY_FILE"
cc_store_index=0
while IFS="$CC_TAB" read -r cc_store cc_source cc_pwtoken; do
  [ -n "$cc_store" ] || continue
  cc_store_index=$((cc_store_index + 1))
  [ "$cc_store_index" -le "$CC_MAX_STORES" ] || break

  cc_section "1-${cc_store_index}. トラストストア ${cc_store}"
  cc_info "検出元: ${cc_source}"
  if [ ! -r "$cc_store" ]; then
    cc_fail "トラストストアを読み取れない: ${cc_store}"
    continue
  fi
  cc_pass 'トラストストアを読み取れる'

  cc_bundle="$CC_DIR/bundle-${cc_store_index}.pem"
  cc_listing="$CC_DIR/keytool-${cc_store_index}.out"
  cc_keytool_err="$CC_DIR/keytool-${cc_store_index}.err"
  cc_listed='no'
  cc_used_token=''
  # -J-Duser.language=en は keytool の見出し (Alias name: 等) を英語へ固定する。
  # 後段で別名を拾うため、実行環境のロケールに左右されないようにしておく。
  for cc_token in "$cc_pwtoken" jvm default none; do
    [ -n "$cc_token" ] || continue
    cc_pw="$(cc_password_of "$cc_token")"
    if [ "$cc_token" = 'none' ] || [ -z "$cc_pw" ]; then
      "$CC_KEYTOOL" -J-Duser.language=en -J-Duser.country=US \
        -list -rfc -keystore "$cc_store" \
        > "$cc_listing" 2> "$cc_keytool_err" < /dev/null \
        && { cc_listed='yes'; cc_used_token='none'; }
    else
      "$CC_KEYTOOL" -J-Duser.language=en -J-Duser.country=US \
        -list -rfc -keystore "$cc_store" -storepass "$cc_pw" \
        > "$cc_listing" 2> "$cc_keytool_err" < /dev/null \
        && { cc_listed='yes'; cc_used_token="$cc_token"; }
    fi
    cc_pw=''
    [ "$cc_listed" = 'yes' ] && break
  done

  if [ "$cc_listed" != 'yes' ]; then
    cc_fail 'keytool でトラストストアを読み取れない (パスワード / ストア種別を確認する)'
    sed 's/^/       /' "$cc_keytool_err" 2>/dev/null | head -n 5
    continue
  fi
  # パスワードの値は出さず、どこから解決したかだけを示す。
  case "$cc_used_token" in
    jvm)     cc_info 'パスワード: JVM の -Djavax.net.ssl.trustStorePassword で整合性チェックまで成功' ;;
    env:*)   cc_info "パスワード: 環境変数 ${cc_used_token#env:} で整合性チェックまで成功" ;;
    default) cc_info 'パスワード: 既定値 changeit で整合性チェックまで成功' ;;
    *)       cc_warn 'トラストストアのパスワードを解決できないため、整合性チェック無しで内容だけを読み取った' ;;
  esac

  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "$cc_listing" > "$cc_bundle"
  # grep -c は不一致でも "0" を出力して終了コード 1 を返すため、
  # || で値を足さず、失敗時は代入し直して数値を 1 つに保つ。
  cc_certs="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$cc_bundle" 2>/dev/null)" || cc_certs=0
  case "${cc_certs:-}" in
    ''|*[!0-9]*) cc_certs=0 ;;
  esac
  if [ "$cc_certs" -gt 0 ]; then
    cc_pass "PEM バンドルを書き出した (証明書 ${cc_certs} 枚)"
  else
    cc_fail 'トラストストアから証明書を取り出せなかった'
    continue
  fi

  # 以降の照合・失敗診断で 1 枚ずつ扱えるよう、バンドルを証明書ごとに分割する。
  # 分割順は keytool の出力順なので、同じ順で拾った別名と添字で対応付けできる。
  cc_split_dir="$CC_DIR/split-${cc_store_index}"
  cc_alias_file="$CC_DIR/alias-${cc_store_index}.tsv"
  mkdir -p "$cc_split_dir"
  awk -v dir="$cc_split_dir" '
    /-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("%s/cert-%03d.pem", dir, n); w = 1 }
    w { print > out }
    /-----END CERTIFICATE-----/   { w = 0 }
  ' "$cc_bundle"
  # keytool -rfc は証明書の直前に "Alias name: <別名>" を出す。
  # 別名が分かると keytool -delete / -importcert の対象を迷わず示せる。
  awk '
    /^Alias name:/ { alias = $0; sub(/^Alias name:[ \t]*/, "", alias); next }
    /-----BEGIN CERTIFICATE-----/ { n++; printf "%03d\t%s\n", n, alias }
  ' "$cc_listing" > "$cc_alias_file" 2>/dev/null || : > "$cc_alias_file"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$cc_store" "$cc_source" "$cc_bundle" "$cc_split_dir" "$cc_alias_file" \
    >> "$CC_READY_FILE"

  # このストアが「JDK 標準 cacerts に何を足したものか」を示す。
  # 独自 CA を足したつもりで足りていない / 別物を足していた、という取り違えは
  # 100 件以上ある一覧の中では埋もれるため、差分だけを取り出して見せる。
  if [ -z "$CC_OPENSSL" ]; then
    cc_skip 'openssl が無いため、JDK 標準 cacerts との差分は表示しない'
  else
    cc_load_jdk_cacerts_fp
    if [ ! -s "$CC_JDK_FP_FILE" ]; then
      cc_info '独自に追加された CA: JDK 標準 cacerts を読めないため判定しない'
    else
      cc_extra_file="$CC_DIR/extra-${cc_store_index}.txt"
      : > "$cc_extra_file"
      for cc_pem in "$cc_split_dir"/cert-*.pem; do
        [ -r "$cc_pem" ] || continue
        cc_pem_fp="$(cc_fp_of "$cc_pem" | tr 'a-f' 'A-F')"
        [ -n "$cc_pem_fp" ] || continue
        grep -qxF -- "$cc_pem_fp" "$CC_JDK_FP_FILE" && continue
        printf '%s\n' "$cc_pem" >> "$cc_extra_file"
      done
      cc_extra_total="$(cc_count_lines "$cc_extra_file")"
      if [ "$cc_extra_total" -eq 0 ]; then
        cc_warn "独自に追加された CA: 0 件 (このストアは JDK 標準 ${CC_JDK_CACERTS} と同じ内容)"
        cc_info '  自己証明書を取り込んだつもりであれば、取り込み先のストアかビルド手順を確認する'
        cc_hint 'no-extra-ca'
      else
        cc_info "独自に追加された CA: ${cc_extra_total} 件 (JDK 標準 cacerts に無い証明書)"
        cc_extra_shown=0
        while IFS= read -r cc_pem; do
          [ -n "$cc_pem" ] || continue
          cc_extra_shown=$((cc_extra_shown + 1))
          if [ "$cc_extra_shown" -gt 10 ]; then
            cc_info "  ... 残り $((cc_extra_total - 10)) 件は省略"
            break
          fi
          cc_pem_idx="$(basename -- "$cc_pem" | sed 's/^cert-//; s/\.pem$//')"
          cc_pem_alias="$(awk -F"$CC_TAB" -v i="$cc_pem_idx" '$1 == i { print $2 }' \
            "$cc_alias_file" 2>/dev/null)"
          cc_info "  - alias=${cc_pem_alias:-(不明)}"
          cc_info "    subject : $(cc_subject_of "$cc_pem")"
          cc_info "    SHA-256 : $(cc_fp_of "$cc_pem")"
          cc_info "    有効期限: $(cc_notafter_of "$cc_pem")"
          if cc_is_expired "$cc_pem"; then
            cc_fail "追加された CA '${cc_pem_alias:-(不明)}' は有効期限が切れている"
            cc_hint 'expired-anchor'
          fi
          if ! cc_is_ca "$cc_pem"; then
            cc_info '    種別    : CA 証明書ではない (自己署名リーフ)。この 1 枚だけを信頼する形になる'
          fi
        done < "$cc_extra_file"
      fi
    fi
  fi

  # 検出した CA 証明書がこのストアに登録されているかを SHA-256 で照合する。
  if [ "$CC_CACERT_TOTAL" -eq 0 ]; then
    cc_skip 'CA 証明書を検出できないためフィンガープリント照合は行わない'
  elif [ -z "$CC_OPENSSL" ]; then
    cc_skip 'openssl が無いためフィンガープリント照合は行わない'
  else
    while IFS= read -r cc_cacert; do
      [ -n "$cc_cacert" ] || continue
      cc_want="$(cc_fp_of "$cc_cacert")"
      if [ -z "$cc_want" ]; then
        cc_warn "CA 証明書のフィンガープリントを取得できない (PEM / DER 形式を確認する): ${cc_cacert}"
        continue
      fi
      cc_found='no'
      for cc_pem in "$cc_split_dir"/cert-*.pem; do
        [ -r "$cc_pem" ] || continue
        if [ "$(cc_fp_of "$cc_pem")" = "$cc_want" ]; then
          cc_found='yes'
          break
        fi
      done
      if [ "$cc_found" = 'yes' ]; then
        cc_pass "$(basename -- "$cc_cacert") と同一の証明書がこのストアに登録されている"
      else
        cc_fail "$(basename -- "$cc_cacert") はこのストアに登録されていない"
        cc_info "対処: ${CC_KEYTOOL} -importcert -trustcacerts -noprompt -alias cacert \\"
        cc_info "        -file ${cc_cacert} -keystore ${cc_store} -storepass <password>"
        cc_hint 'cacert-not-imported'
      fi
    done < "$CC_CACERTS_FILE"
  fi
done < "$CC_STORES_FILE"

CC_READY_TOTAL="$(cc_count_lines "$CC_READY_FILE")"
if [ "$CC_READY_TOTAL" -eq 0 ]; then
  cc_section '結果'
  printf '  PASS=%d  FAIL=%d  WARN=%d  SKIP=%d\n' "$CC_PASS" "$CC_FAIL" "$CC_WARN" "$CC_SKIP"
  cc_truncation_note
  printf '判定: NG — PEM バンドルを用意できたトラストストアがありません。\n'
  exit 1
fi

# =====================================================================
# 2. 検出した接続先へ、各トラストストア由来の PEM で HTTPS 接続する
#    失敗したときは curl の終了コードで止めず、サーバが実際に提示した
#    証明書チェーンとトラストストアの中身を突き合わせ、
#    「どの CA が足りないのか」「取り込みは成功しているのか」まで出す。
# =====================================================================

# 接続に失敗したストアについて、原因を切り分けて表示する。
# 参照する chain 系の変数は接続先ループが設定したものを使う。
cc_diagnose_failure() {  # $1=curl exit $2=ストアパス $3=ストア PEM $4=split ディレクトリ $5=別名 TSV
  cc_df_rc="$1"; cc_df_store="$2"; cc_df_bundle="$3"
  cc_df_split="$4"; cc_df_alias_file="$5"

  # 名前解決・接続・タイムアウトは証明書以前の失敗。チェーン解析をしても
  # 何も出ないため、ここで切り上げて調べる先を示す。
  case "$cc_df_rc" in
    6|7|28)
      cc_info "  詳細診断: 証明書以前の失敗のため ${cc_df_store} の中身は原因ではない。"
      cc_info '            宛先の起動状態と Compose のネットワーク / ポートを先に確認する。'
      cc_hint 'dns'
      return 0
      ;;
  esac

  if [ -z "$CC_OPENSSL" ]; then
    cc_info '  詳細診断: openssl が無いためここまで。openssl があると原因まで特定できる。'
    return 0
  fi
  if [ "$cc_chain_n" -eq 0 ]; then
    cc_info '  詳細診断: サーバの証明書チェーンを取得できていないため原因を特定できない。'
    cc_info '            TLS ハンドシェイク以前 (経路 / ポート / 平文応答) を先に確認する。'
    return 0
  fi

  # (a) openssl verify の原文を出す。curl の終了コードより粒度が細かく、
  #     error 20 / 19 / 10 の区別がそのまま原因の切り分けになる。
  cc_df_verify="$CC_DIR/verify.out"
  if [ -s "$cc_chain_untrusted" ]; then
    "$CC_OPENSSL" verify -CAfile "$cc_df_bundle" -untrusted "$cc_chain_untrusted" \
      "$cc_chain_leaf" > "$cc_df_verify" 2>&1 || :
  else
    "$CC_OPENSSL" verify -CAfile "$cc_df_bundle" "$cc_chain_leaf" \
      > "$cc_df_verify" 2>&1 || :
  fi
  cc_info '  詳細診断 (openssl verify の出力):'
  sed 's/^/         /' "$cc_df_verify" 2>/dev/null | head -n 5
  if grep -q 'unable to get local issuer certificate' "$cc_df_verify" 2>/dev/null; then
    cc_info '         → error 20: 発行者 CA をこの CA 一式の中から見つけられない'
  fi
  if grep -q 'self.signed certificate in certificate chain' "$cc_df_verify" 2>/dev/null; then
    cc_info '         → error 19: チェーンの最上位が自己署名 CA で、それを信頼していない'
  fi
  if grep -q 'certificate has expired' "$cc_df_verify" 2>/dev/null; then
    cc_info '         → error 10: 期限切れの証明書がチェーンに含まれる'
  fi

  # (b) サーバ証明書の発行者が、このトラストストアに登録されているか。
  #     DN の文字列表現ではなく正規化ハッシュで突き合わせる。
  cc_df_issuer_hash="$(cc_issuer_hash_of "$cc_chain_leaf")"
  cc_df_issuer_dn="$(cc_issuer_of "$cc_chain_leaf")"
  if cc_df_anchor="$(cc_find_in_store "$cc_df_split" "$cc_df_issuer_hash")"; then
    cc_df_idx="$(basename -- "$cc_df_anchor" | sed 's/^cert-//; s/\.pem$//')"
    cc_df_alias="$(awk -F"$CC_TAB" -v i="$cc_df_idx" '$1 == i { print $2 }' \
      "$cc_df_alias_file" 2>/dev/null)"
    cc_info "  発行者 CA はこのストアに存在する: ${cc_df_issuer_dn}"
    cc_info "    alias=${cc_df_alias:-(不明)}  SHA-256=$(cc_fp_of "$cc_df_anchor")"
    if cc_is_expired "$cc_df_anchor"; then
      cc_info '    → ただし有効期限が切れている。CA 証明書を更新して入れ直す。'
      cc_hint 'expired-anchor'
    else
      cc_info '    → subject は一致するのに検証に失敗している。'
      cc_info '      同じ名前で鍵の違う CA (再発行された CA) を掴んでいる可能性が高い。'
      cc_info '      配布元の最新の CA 証明書と SHA-256 を突き合わせる。'
      cc_hint 'anchor-mismatch'
    fi
  else
    cc_info "  ★発行者 CA がこのトラストストアに無い: ${cc_df_issuer_dn}"
    cc_hint 'missing-anchor'
    # サーバが提示したチェーンの最上位 (= 足りていない CA の候補) を示す
    cc_df_top=''
    for cc_df_c in "$cc_chain_dir"/chain-*.pem; do
      [ -r "$cc_df_c" ] && cc_df_top="$cc_df_c"
    done
    if [ -n "$cc_df_top" ] && [ "$cc_df_top" != "$cc_chain_leaf" ]; then
      cc_info '  サーバが提示したチェーンの最上位 (これが不足している CA):'
      cc_info "    subject : $(cc_subject_of "$cc_df_top")"
      cc_info "    SHA-256 : $(cc_fp_of "$cc_df_top")"
      if cc_is_selfsigned "$cc_df_top"; then
        cc_info '    自己署名: YES → これを信頼していないことが exit 60 の直接原因。'
        cc_info '    curl の "self-signed certificate in certificate chain" はこの状態を指す'
        cc_info '    (サーバ証明書そのものが自己署名という意味ではない)。'
      fi
    else
      cc_info '  サーバは中間 / ルート CA を提示していない (リーフ 1 枚のみ)。'
      cc_info '  発行元 CA の証明書を配布元から入手してトラストストアへ入れる必要がある。'
    fi
  fi

  # (c) 受領 CA はストアに入っているのに接続できない、という状態かどうか。
  #     ここが「自己証明書だけがあり秘密鍵が無い」構成の典型的な見え方になる。
  if [ "$CC_CACERT_TOTAL" -gt 0 ]; then
    cc_df_cacert_in=0
    cc_df_cacert_name=''
    while IFS= read -r cc_df_ca; do
      [ -n "$cc_df_ca" ] || continue
      cc_df_ca_fp="$(cc_fp_of "$cc_df_ca")"
      [ -n "$cc_df_ca_fp" ] || continue
      for cc_df_p in "$cc_df_split"/cert-*.pem; do
        [ -r "$cc_df_p" ] || continue
        if [ "$(cc_fp_of "$cc_df_p")" = "$cc_df_ca_fp" ]; then
          cc_df_cacert_in=1
          cc_df_cacert_name="$(basename -- "$cc_df_ca")"
          break
        fi
      done
      [ "$cc_df_cacert_in" -eq 1 ] && break
    done < "$CC_CACERTS_FILE"
    if [ "$cc_df_cacert_in" -eq 1 ] && [ -z "${cc_df_anchor:-}" ]; then
      cc_info "  ★取り込み自体は成功している: ${cc_df_cacert_name} はこのストアに入っている。"
      cc_info '    それでも失敗するのは、サーバ証明書がその CA では発行されていないため'
      cc_info '    (発行者が別の CA になっている)。自己証明書 (CA 証明書) だけを受領し'
      cc_info '    秘密鍵が無い構成では、サーバ側は受領 CA 発行の証明書を提示できないため'
      cc_info '    必ずこの状態になる。'
      cc_hint 'cacert-present-other-issuer'
    fi
  fi

  # (d) 「サーバが提示したチェーンを信頼すれば通るのか」を実際に試す。
  #     通るなら不足は CA 1 点であり、経路・名前・期限は問題ないと確定できる。
  if curl --silent --show-error \
      --connect-timeout "$CC_CONNECT_TIMEOUT" --max-time "$CC_MAX_TIME" \
      --output /dev/null --cacert "$cc_chain_all" "$cc_target_url" \
      < /dev/null > /dev/null 2>&1; then
    cc_info '  検証: サーバが提示したチェーンを CA として渡すと接続できた。'
    cc_info '        → 不足しているのは上記の CA 証明書だけ。経路 / 名前 / 期限は問題ない。'
    cc_hint 'anchor-only'
  else
    cc_info '  検証: サーバが提示したチェーンを CA として渡しても接続できない。'
    cc_info '        → CA 不足以外の要因 (ホスト名不一致 / 有効期限 / プロトコル) も疑う。'
  fi
  cc_df_anchor=''
}

cc_target_index=0
while IFS= read -r cc_target_line <&3; do
  [ -n "$cc_target_line" ] || continue
  cc_target_index=$((cc_target_index + 1))
  [ "$cc_target_index" -le "$CC_MAX_TARGETS" ] || break
  cc_target_name="${cc_target_line%%=*}"
  cc_target_url="${cc_target_line#*=}"
  cc_host="$(cc_url_hostport "$cc_target_url" | cut -f1)"
  cc_port="$(cc_url_hostport "$cc_target_url" | cut -f2)"

  cc_section "2-${cc_target_index}. HTTPS 接続 ${cc_target_name}"
  cc_info "接続先: ${cc_target_url}"
  cc_info "ホスト: ${cc_host}   ポート: ${cc_port}"

  # 名前解決。ここで落ちていれば証明書の話にすらなっていない。
  if command -v getent >/dev/null 2>&1; then
    cc_addrs="$(getent hosts "$cc_host" 2>/dev/null | awk '{ print $1 }' | tr '\n' ' ')"
    if [ -n "$cc_addrs" ]; then
      cc_info "名前解決: ${cc_host} -> ${cc_addrs}"
    else
      cc_warn "名前解決: ${cc_host} を解決できない (Compose のサービス名とネットワークを確認する)"
      cc_hint 'dns'
    fi
  fi

  # --- サーバが実際に提示している証明書チェーン ------------------------
  cc_chain_dir="$CC_DIR/chain-${cc_target_index}"
  mkdir -p "$cc_chain_dir"
  cc_chain_n=0
  cc_chain_all="$cc_chain_dir/presented.pem"
  cc_chain_untrusted="$cc_chain_dir/untrusted.pem"
  cc_chain_leaf="$cc_chain_dir/chain-001.pem"
  cc_sclient_out="$cc_chain_dir/s_client.out"
  : > "$cc_chain_all"
  : > "$cc_chain_untrusted"
  if [ -z "$CC_OPENSSL" ]; then
    cc_skip 'openssl が無いため、サーバが提示する証明書チェーンは確認しない'
    cc_hint 'no-openssl'
  else
    # -servername は SNI。名前ベースで証明書を出し分けるサーバでは必須。
    if [ -n "$CC_TIMEOUT" ]; then
      "$CC_TIMEOUT" "$CC_MAX_TIME" "$CC_OPENSSL" s_client \
        -connect "${cc_host}:${cc_port}" -servername "$cc_host" -showcerts \
        < /dev/null > "$cc_sclient_out" 2>&1 || :
    else
      "$CC_OPENSSL" s_client \
        -connect "${cc_host}:${cc_port}" -servername "$cc_host" -showcerts \
        < /dev/null > "$cc_sclient_out" 2>&1 || :
    fi
    awk -v dir="$cc_chain_dir" '
      /-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("%s/chain-%03d.pem", dir, n); w = 1 }
      w { print > out }
      /-----END CERTIFICATE-----/   { w = 0 }
    ' "$cc_sclient_out"
    for cc_c in "$cc_chain_dir"/chain-*.pem; do
      [ -r "$cc_c" ] || continue
      cc_chain_n=$((cc_chain_n + 1))
      cat "$cc_c" >> "$cc_chain_all"
      [ "$cc_chain_n" -eq 1 ] || cat "$cc_c" >> "$cc_chain_untrusted"
    done
  fi

  if [ -n "$CC_OPENSSL" ] && [ "$cc_chain_n" -eq 0 ]; then
    cc_warn 'サーバから証明書チェーンを取得できなかった (TLS 以前で失敗している可能性)'
    sed 's/^/       /' "$cc_sclient_out" 2>/dev/null | head -n 5
    cc_hint 'no-chain'
  elif [ "$cc_chain_n" -gt 0 ]; then
    cc_info "サーバが提示した証明書: ${cc_chain_n} 枚 (openssl s_client -showcerts)"
    cc_ci=0
    for cc_c in "$cc_chain_dir"/chain-*.pem; do
      [ -r "$cc_c" ] || continue
      cc_ci=$((cc_ci + 1))
      if [ "$cc_ci" -eq 1 ]; then
        cc_info "  [${cc_ci}] サーバ証明書"
      else
        cc_info "  [${cc_ci}] チェーンに同梱された CA"
      fi
      cc_info "      subject : $(cc_subject_of "$cc_c")"
      cc_info "      issuer  : $(cc_issuer_of "$cc_c")"
      cc_info "      SHA-256 : $(cc_fp_of "$cc_c")"
      cc_info "      有効期間: $(cc_notbefore_of "$cc_c") 〜 $(cc_notafter_of "$cc_c")"
      if cc_is_selfsigned "$cc_c"; then
        cc_info '      自己署名: YES (チェーンの最上位。クライアントが直接信頼している必要がある)'
      fi
      if cc_is_expired "$cc_c"; then
        cc_fail "サーバが提示した証明書 [${cc_ci}] は有効期限が切れている"
        cc_hint 'expired-presented'
      fi
    done

    # ホスト名の一致 (SAN)。CA が正しくても SAN が合わなければ検証は通らない。
    cc_leaf_san="$(cc_san_of "$cc_chain_leaf")"
    if [ -n "$cc_leaf_san" ]; then
      cc_info "  サーバ証明書の SAN : ${cc_leaf_san}"
      if cc_host_matches_san "$cc_host" "$cc_leaf_san"; then
        cc_pass "接続先ホスト名 ${cc_host} はサーバ証明書の SAN に含まれている"
      else
        cc_fail "接続先ホスト名 ${cc_host} がサーバ証明書の SAN に含まれていない"
        cc_hint 'san'
      fi
    else
      cc_warn 'サーバ証明書に SAN が無い (最近の JVM / curl は CN だけでは名前検証に通らない)'
      cc_hint 'san'
    fi
  fi

  # --- トラストストアごとの接続確認 ------------------------------------
  cc_target_ok=0
  cc_target_fail=0
  while IFS="$CC_TAB" read -r cc_store cc_source cc_bundle cc_split cc_aliases; do
    [ -n "$cc_bundle" ] || continue
    cc_curl_err="$CC_DIR/curl.err"
    # このループは標準入力から $CC_READY_FILE を読んでいるため、curl には
    # /dev/null を渡して読み取り位置を進めさせない。
    cc_code="$(curl --silent --show-error \
      --connect-timeout "$CC_CONNECT_TIMEOUT" --max-time "$CC_MAX_TIME" \
      --output /dev/null --write-out '%{http_code}' \
      --cacert "$cc_bundle" "$cc_target_url" < /dev/null 2> "$cc_curl_err")"
    cc_rc=$?
    if [ "$cc_rc" -eq 0 ]; then
      cc_pass "${cc_store} 由来の PEM で接続成功 (HTTP ${cc_code})"
      cc_target_ok=$((cc_target_ok + 1))
    else
      cc_fail "${cc_store} 由来の PEM で接続失敗 (curl exit=${cc_rc})"
      cc_target_fail=$((cc_target_fail + 1))
      sed 's/^/       /' "$cc_curl_err" 2>/dev/null | head -n 3
      case "$cc_rc" in
        60) cc_info 'exit 60 = サーバ証明書をこの CA 一式では検証できない (信頼の連鎖がつながらない)。' ;;
        51) cc_info 'exit 51 = サーバ証明書の名前 (SAN / CN) が接続先ホスト名と一致しない。' ;;
        35) cc_info 'exit 35 = TLS ハンドシェイク失敗。プロトコル / 暗号スイートの不一致を確認する。' ;;
        7)  cc_info 'exit 7 = 接続不可。宛先ホスト・ポート・Compose ネットワークを確認する。' ;;
        6)  cc_info 'exit 6 = 名前解決に失敗。Compose のサービス名を確認する。' ;;
        28) cc_info "exit 28 = タイムアウト (最大 ${CC_MAX_TIME} 秒)。宛先の起動状態を確認する。" ;;
      esac
      cc_diagnose_failure "$cc_rc" "$cc_store" "$cc_bundle" "$cc_split" "$cc_aliases"
    fi
  done < "$CC_READY_FILE"

  # 対照テスト: CA を渡さないと失敗することで、上の成功がトラストストアの効果だと確認できる。
  curl --silent --show-error \
    --connect-timeout "$CC_CONNECT_TIMEOUT" --max-time "$CC_MAX_TIME" \
    --output /dev/null "$cc_target_url" \
    < /dev/null > /dev/null 2> "$CC_DIR/curl-control.err"
  cc_control_rc=$?
  if [ "$cc_control_rc" -eq 60 ]; then
    if [ "$cc_target_ok" -gt 0 ]; then
      cc_pass '対照テスト: --cacert 無しでは検証に失敗した (curl exit 60)'
    else
      # トラストストア経由も失敗している状況では、この結果は「ストアの効果」を
      # 何も示さない。PASS と数えると原因を取り違えるため情報として出す。
      cc_info '対照テスト: --cacert 無しでも検証に失敗した (curl exit 60)。'
      cc_info '  トラストストア経由も失敗しているため、この結果はストアの効果を示していない。'
      cc_info '  OS 標準 CA でもストアの CA でも検証できない = 発行元 CA をどこからも信頼できていない。'
    fi
  elif [ "$cc_control_rc" -eq 0 ]; then
    cc_warn '対照テスト: --cacert 無しでも接続できた。サーバ証明書が OS 標準の CA バンドルでも検証できるため、上の成功はトラストストアの効果を示していない。'
  else
    cc_warn "対照テスト: --cacert 無しの接続が exit=${cc_control_rc} で失敗した (証明書検証以外の理由の可能性)"
  fi
done 3< "$CC_TARGETS_FILE"

# =====================================================================
# 3. 次の一手 (検出した原因ごとの対処)
#    上のログを読み直さなくても、そのまま実行できる形で対処を出す。
# =====================================================================
if [ -s "$CC_HINTS_FILE" ]; then
  cc_section '3. 次の一手'
  if cc_has_hint 'cacert-present-other-issuer'; then
    printf '  ● 受領した自己証明書はストアに入っているのに接続できない\n'
    printf '     サーバ証明書の発行元が、その受領 CA ではありません。典型的には\n'
    printf '     「自己証明書 (CA 証明書) だけを受領し、秘密鍵が無い」構成です。\n'
    printf '     秘密鍵の無い CA では署名を作れないため、サーバ側は別の CA が発行した\n'
    printf '     証明書を提示するしかなく、受領 CA だけを信頼しても必ず失敗します。\n'
    printf '     対処は次のいずれかです。\n'
    printf '       (a) サーバ証明書を受領 CA が発行したものへ差し替える (本番相当)\n'
    printf '           CSR を作って CA 管理者へ提出し、発行された証明書をサーバへ入れる\n'
    printf '       (b) サーバ証明書を発行したローカル CA もトラストストアへ入れる (検証用)\n'
    printf '           Container_Compose_file なら PKI_TRUST_LOCAL_CA=1 で配布される\n'
    printf '       (c) 秘密鍵も受領できるなら配置し、受領 CA で発行し直す\n'
    printf '           Container_Compose_file なら compose/pki/provided/cacert.key\n'
  fi
  if cc_has_hint 'missing-anchor'; then
    printf '  ● サーバ証明書の発行元 CA がトラストストアに入っていない\n'
    printf '     1) 上に表示した「不足している CA」の SHA-256 を配布元と突き合わせる\n'
    printf '     2) その CA 証明書をトラストストアへ取り込む:\n'
    printf '        %s -importcert -trustcacerts -noprompt \\\n' "$CC_KEYTOOL"
    printf '          -alias <別名> -file <CA 証明書> \\\n'
    printf '          -keystore <トラストストア> -storepass <パスワード>\n'
    printf '     3) JVM を再起動する (トラストストアは起動時に読み込まれる)\n'
    printf '     イメージへ焼き込む構成なら、Dockerfile 側を直してビルドし直す\n'
  fi
  if cc_has_hint 'cacert-not-imported'; then
    printf '  ● 検出した CA 証明書がトラストストアに入っていない\n'
    printf '     取り込み手順そのものが効いていません。ビルド時に取り込む構成なら、\n'
    printf '     証明書の配置漏れ (空ファイル / パス違い) とビルドログを確認してください。\n'
  fi
  if cc_has_hint 'no-extra-ca'; then
    printf '  ● トラストストアが JDK 標準 cacerts と同じ内容\n'
    printf '     自己証明書が 1 枚も追加されていません。取り込み先のストアを\n'
    printf '     取り違えていないか (JDK の cacerts と AP 用ストアの混同) を確認してください。\n'
  fi
  if cc_has_hint 'anchor-mismatch'; then
    printf '  ● 同じ名前の CA はあるが署名を検証できない\n'
    printf '     CA が再発行され、配布された証明書が古いままの可能性があります。\n'
    printf '     配布元の最新 CA 証明書を取得し、古い別名を削除してから入れ直します:\n'
    printf '        %s -delete -alias <古い別名> -keystore <ストア> -storepass <パスワード>\n' "$CC_KEYTOOL"
  fi
  if cc_has_hint 'expired-anchor' || cc_has_hint 'expired-presented'; then
    printf '  ● 有効期限切れの証明書がある\n'
    printf '     期限切れは CA 側 / サーバ側のどちらでも検証を失敗させます。\n'
    printf '     上に表示した有効期間を確認し、更新された証明書へ差し替えてください。\n'
    printf '     コンテナの時刻がずれている場合も同じ症状になります (date で確認)。\n'
  fi
  if cc_has_hint 'san'; then
    printf '  ● ホスト名がサーバ証明書の SAN と一致しない\n'
    printf '     CA を信頼していても名前が合わなければ検証は通りません。\n'
    printf '     接続先 URL のホスト名を SAN に含まれる名前へ合わせるか、\n'
    printf '     その名前を SAN に含むサーバ証明書を発行し直してください。\n'
  fi
  if cc_has_hint 'dns' || cc_has_hint 'no-chain'; then
    printf '  ● 接続先に到達できていない\n'
    printf '     証明書以前の問題です。Compose のサービス名・ネットワーク・\n'
    printf '     公開ポート・宛先コンテナの起動状態を確認してください。\n'
  fi
  if cc_has_hint 'anchor-only'; then
    printf '  ● 不足しているのは CA 証明書 1 点だけ\n'
    printf '     サーバ提示チェーンを CA として渡すと接続できています。\n'
    printf '     上記の CA をトラストストアへ入れれば解消します。\n'
  fi
  if cc_has_hint 'no-openssl'; then
    printf '  ● コンテナに openssl が無い\n'
    printf '     チェーン解析ができないため原因の特定まで至りません。\n'
    printf '     調査用イメージに openssl を入れると、この診断が原因まで出せます。\n'
  fi
fi

cc_section '結果'
printf '  PASS=%d  FAIL=%d  WARN=%d  SKIP=%d\n' "$CC_PASS" "$CC_FAIL" "$CC_WARN" "$CC_SKIP"
cc_truncation_note
if [ "$CC_FAIL" -gt 0 ]; then
  printf '判定: NG — 上記 [FAIL] の内容を確認してください。\n'
  exit 1
fi
printf '判定: OK — 検出したトラストストアの証明書で HTTPS 接続できています。\n'
exit 0
CERT_CHECK_SCRIPT
)"

  diag ""
  diag "════════════════ 証明書チェック ════════════════"
  diag "Compose サービス : ${service_name}"
  diag "コンテナ         : ${container_name}"
  diag "コンテナ内の JVM 引数と環境変数からトラストストアと HTTPS 接続先を検出し、"
  diag "そのコンテナ自身の curl で接続できるかを確認します (追加の入力は不要)。"
  diag "接続待ちが入るため、完了まで数十秒かかることがあります。"

  if ! capture_file="$(mktemp 2>/dev/null)"; then
    err "証明書チェックの保存用一時ファイルを作成できませんでした。"
    return 1
  fi
  docker exec "$container_id" /bin/sh -c "$cert_check_script" \
    > "$capture_file" 2>&1 || exec_status=$?
  print_healthcheck_capture "$capture_file" "(証明書チェックの出力がありません)"
  rm -f -- "$capture_file"

  case "$exec_status" in
    0)
      diag "証明書チェック結果 : OK"
      ;;
    1)
      diag "証明書チェック結果 : NG (上記 [FAIL] を確認してください)"
      ;;
    2)
      warn "証明書チェックに必要な設定をコンテナ内から検出できませんでした。"
      diag "════════════════════════════════════════════════"
      return 1
      ;;
    *)
      err "Compose サービス '${service_name}' で証明書チェックを実行できませんでした (exit=${exec_status}): ${container_name}"
      diag "════════════════════════════════════════════════"
      return 1
      ;;
  esac
  diag "接続先やトラストストアの内容には機微情報が含まれ得るため、共有・ログ保存時の取り扱いに注意してください。"
  diag "════════════════════════════════════════════════"
  return 0
}

# 可観測性ヘルパーの JSON は認証ヘッダー等を含み得るため、生データを表示せず
# Python 3 で必要な項目だけを抽出する。logs モード全体の必須依存にはせず、
# 専用ヘルパーが選択された時点で利用可否を確認する。
resolve_observability_python() {
  local candidate

  [ -n "$OBSERVABILITY_PYTHON" ] && return 0
  for candidate in python3 python /usr/libexec/platform-python; do
    if command -v "$candidate" >/dev/null 2>&1 \
        && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)' \
          >/dev/null 2>&1; then
      OBSERVABILITY_PYTHON="$candidate"
      return 0
    fi
  done
  err "可観測性ヘルパーの JSON 解析に必要な Python 3 が見つかりません。"
  err "python3、python (Python 3)、または /usr/libexec/platform-python を利用可能にしてください。"
  return 1
}

require_observability_tools() {
  if ! command -v curl >/dev/null 2>&1; then
    err "可観測性ヘルパーの HTTP 確認に必要な curl が見つかりません。"
    return 1
  fi
  resolve_observability_python
}

# Compose サービスのコンテナ側 HTTP ポートをホストから到達できる URL へ解決する。
# 公開ポートを優先し、未公開の場合はコンテナ IP を使用する。
resolve_compose_service_http_endpoint() {
  local service_name="$1" container_port="$2"
  local container_id container_name mapping="" mapped_host="" mapped_port=""
  local container_ip="" host_for_url=""
  local -a container_ids=()

  OBSERVABILITY_HTTP_HOST=""
  OBSERVABILITY_HTTP_PORT=""
  OBSERVABILITY_HTTP_BASE_URL=""
  OBSERVABILITY_CONTAINER_NAME=""

  mapfile -t container_ids < <(compose_container_ids "$service_name")
  if [ ${#container_ids[@]} -eq 0 ]; then
    err "Compose サービス '${service_name}' の実行中コンテナが見つかりません。"
    return 1
  fi
  container_id="${container_ids[0]}"
  container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"
  if [ ${#container_ids[@]} -gt 1 ]; then
    warn "Compose サービス '${service_name}' は複数コンテナで実行中のため、先頭のコンテナを使用します: ${container_name}"
  fi

  mapping="$(docker port "$container_id" "${container_port}/tcp" 2>/dev/null | sed -n '1p' || true)"
  if [ -n "$mapping" ]; then
    mapped_port="${mapping##*:}"
    mapped_host="${mapping%:*}"
    mapped_host="${mapped_host#[}"
    mapped_host="${mapped_host%]}"
    case "$mapped_host" in
      ""|0.0.0.0|::) mapped_host="127.0.0.1" ;;
    esac
    if printf '%s' "$mapped_port" | grep -qE '^[0-9]+$'; then
      OBSERVABILITY_HTTP_HOST="$mapped_host"
      OBSERVABILITY_HTTP_PORT="$mapped_port"
    fi
  fi

  if [ -z "$OBSERVABILITY_HTTP_HOST" ]; then
    container_ip="$(
      docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' \
        "$container_id" 2>/dev/null | sed -n '/./{p;q;}' || true
    )"
    if [ -z "$container_ip" ]; then
      err "Compose サービス '${service_name}' の公開ポートまたはコンテナ IP を解決できませんでした。"
      return 1
    fi
    OBSERVABILITY_HTTP_HOST="$container_ip"
    OBSERVABILITY_HTTP_PORT="$container_port"
    warn "サービス '${service_name}' のポート ${container_port}/tcp は未公開のため、コンテナ IP (${container_ip}) へ接続します。"
  fi

  host_for_url="$OBSERVABILITY_HTTP_HOST"
  case "$host_for_url" in
    *:*) host_for_url="[${host_for_url}]" ;;
  esac
  OBSERVABILITY_HTTP_BASE_URL="http://${host_for_url}:${OBSERVABILITY_HTTP_PORT}"
  OBSERVABILITY_CONTAINER_NAME="$container_name"
  log "Compose サービスの確認 URL を解決しました: ${service_name} -> ${OBSERVABILITY_HTTP_BASE_URL}"
}

# Python ヘルパーへ JSON を渡す共通経路。
# プロセス置換と追加 fd (3< <(...)) は、Windows 版 Python を使う Git Bash のように
# 子プロセスが 0-2 以外の fd を継承できない環境で失敗するため、標準入力へ NUL 区切りで
# 渡す方式に統一する。JSON テキストに NUL バイトは現れないため区切りとして安全で、
# 機微情報を含み得る JSON を一時ファイルやコマンドライン引数へ出さずに渡せる。
# 使い方: run_observability_python "<プログラム>" <JSON 個数> [JSON...] [プログラム引数...]
run_observability_python() {
  local program="$1" document_count="$2"
  shift 2
  local index
  local -a documents=()

  while [ "$document_count" -gt 0 ]; do
    documents+=("$1")
    shift
    document_count=$((document_count - 1))
  done
  # レポートは日本語と罫線文字を含むため、ロケール既定の文字コード (Windows の cp932 等)
  # で出力が落ちないよう UTF-8 を明示する。
  {
    for index in "${!documents[@]}"; do
      [ "$index" -eq 0 ] || printf '\000'
      printf '%s' "${documents[$index]}"
    done
  } | PYTHONIOENCODING=utf-8 "$OBSERVABILITY_PYTHON" -c "$program" "$@"
}

# 各 Python ヘルパーの先頭へ連結する、入出力の共通定義。
# プログラム本文側にも同じ import があるが、二重 import は無害。
OBSERVABILITY_PYTHON_JSON_LOADER='
import json
import sys

# Windows の Python は既定でロケール文字コード変換と LF -> CRLF 変換を行う。
# レポートの罫線が化けたり、シェルが受け取る値へ CR が混入したりしないよう明示する。
try:
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")
except Exception:
    pass


def load_json_documents(labels):
    """標準入力の NUL 区切り JSON を、labels の順に解析して返す。"""
    chunks = sys.stdin.buffer.read().split(b"\0")
    documents = []
    for index, label in enumerate(labels):
        chunk = chunks[index] if index < len(chunks) else b""
        try:
            documents.append(json.loads(chunk.decode("utf-8")))
        except Exception as exc:
            print(f"[ERROR] {label} の JSON を解析できません: {exc}", file=sys.stderr)
            raise SystemExit(2)
    return documents
'

# WireMock の request journal を読む Python ヘルパーの共通定義。
# journal のリクエストはヘッダー表現がバージョンで揺れるため、取り出し方をここへ集約する。
OBSERVABILITY_PYTHON_WIREMOCK_LOADER='
import base64
import json


def header_value(request, name):
    headers = request.get("headers") or {}
    value = headers.get(name)
    if value is None:
        for key, candidate in headers.items():
            if str(key).lower() == name.lower():
                value = candidate
                break
    if isinstance(value, list):
        return str(value[0]) if value else ""
    if isinstance(value, dict):
        values = value.get("values")
        if isinstance(values, list):
            return str(values[0]) if values else ""
        return str(value.get("value") or "")
    return str(value or "")


def request_body(request):
    body = request.get("body")
    if isinstance(body, dict):
        return body
    if isinstance(body, str) and body:
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}
    encoded = request.get("bodyAsBase64")
    if encoded:
        try:
            return json.loads(base64.b64decode(encoded).decode("utf-8"))
        except Exception:
            return {}
    return {}


def put_log_events_requests(journal):
    """journal から PutLogEvents のリクエスト本文だけを取り出す。"""
    records = journal.get("requests", []) if isinstance(journal, dict) else []
    bodies = []
    for record in records if isinstance(records, list) else []:
        if not isinstance(record, dict):
            continue
        request = record.get("request") if isinstance(record.get("request"), dict) else record
        if header_value(request, "X-Amz-Target") != "Logs_20140328.PutLogEvents":
            continue
        bodies.append(request_body(request))
    return bodies
'

observability_http_get() {
  curl -sS --noproxy '*' --max-time "$URL_TIMEOUT" "$1"
}

observability_http_post_json() {
  local url="$1"
  curl -sS --noproxy '*' --max-time "$URL_TIMEOUT" \
    --request POST --header "Content-Type: application/json" \
    --data-binary @- "$url"
}

wiremock_request_count() {
  local base_url="$1" target="$2" payload response

  payload="$(printf '{"method":"POST","url":"/","headers":{"X-Amz-Target":{"equalTo":"%s"}}}' "$target")"
  if ! response="$(printf '%s' "$payload" | observability_http_post_json "${base_url}/__admin/requests/count")"; then
    return 1
  fi
  # 改行を書かずに返し、Windows の Python が付ける CR が値へ混ざらないようにする。
  printf '%s' "$response" | PYTHONIOENCODING=utf-8 "$OBSERVABILITY_PYTHON" -c \
    'import json,sys; value=json.load(sys.stdin).get("count"); sys.stdout.write(str(value) if isinstance(value, int) else "?")'
}

# 標準入力の 1 つ目に cwagent 設定、2 つ目に WireMock request journal を受け取る。
# Authorization 等のヘッダーは読み捨て、設定済み送信先と PutLogEvents 本文だけを表示する。
render_cloudwatch_delivery_report() {
  local config_json="$1" journal_json="$2"
  local create_group_count="$3" create_stream_count="$4" put_count="$5"
  local program

  program="$(cat <<'PY'
import datetime
import re
import sys


def clean_text(value, limit=500):
    text = str(value if value is not None else "")
    text = text.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")
    text = re.sub(
        r"(?i)\b(password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)"
        r"(\s*[:=]\s*)([^\s,;]+)",
        lambda match: f"{match.group(1)}{match.group(2)}[REDACTED]",
        text,
    )
    return text if len(text) <= limit else text[:limit] + "...(省略)"


# 表示時刻はスクリプト全体と揃えて JST 固定にする (ログイベントの元値は UTC epoch)。
JST = datetime.timezone(datetime.timedelta(hours=9), "JST")


def event_time(value):
    try:
        stamp = float(value) / 1000.0
        return datetime.datetime.fromtimestamp(
            stamp, JST
        ).isoformat(timespec="milliseconds").replace("+09:00", " JST")
    except Exception:
        return clean_text(value)


config, journal = load_json_documents(["cwagent 設定", "WireMock request journal"])
create_group_count, create_stream_count, put_count = sys.argv[1:4]
event_limit = int(sys.argv[4])
journal_limit = int(sys.argv[5])

collect_list = (
    config.get("logs", {})
    .get("logs_collected", {})
    .get("files", {})
    .get("collect_list", [])
)
expected = []
for entry in collect_list if isinstance(collect_list, list) else []:
    if not isinstance(entry, dict):
        continue
    expected.append(
        (
            str(entry.get("log_group_name") or ""),
            str(entry.get("log_stream_name") or ""),
            str(entry.get("file_path") or ""),
        )
    )

destination_stats = {}
events = []
recent_put_requests = 0
records = journal.get("requests", []) if isinstance(journal, dict) else []
for record in records if isinstance(records, list) else []:
    if not isinstance(record, dict):
        continue
    request = record.get("request") if isinstance(record.get("request"), dict) else record
    if header_value(request, "X-Amz-Target") != "Logs_20140328.PutLogEvents":
        continue
    recent_put_requests += 1
    body = request_body(request)
    group = str(body.get("logGroupName") or "")
    stream = str(body.get("logStreamName") or "")
    key = (group, stream)
    stat = destination_stats.setdefault(key, {"requests": 0, "events": 0})
    stat["requests"] += 1
    log_events = body.get("logEvents")
    if not isinstance(log_events, list):
        log_events = []
    stat["events"] += len(log_events)
    for event in log_events:
        if not isinstance(event, dict):
            continue
        events.append(
            {
                "timestamp": event.get("timestamp"),
                "group": group,
                "stream": stream,
                "message": event.get("message", ""),
            }
        )

print("")
print("════════════ CloudWatch Logs 偽装送達レポート ════════════")
print(f"WireMock API 受信総数: CreateLogGroup={create_group_count}, "
      f"CreateLogStream={create_stream_count}, PutLogEvents={put_count}")
print(f"直近 {journal_limit} リクエスト内で解析した PutLogEvents: {recent_put_requests} 件")
print("")
print("[cwagent 設定と受信先の照合]")
if expected:
    for group, stream, file_path in expected:
        stat = destination_stats.get((group, stream), {"requests": 0, "events": 0})
        state = "OK" if stat["requests"] > 0 and stat["events"] > 0 else "未確認"
        print(f"  [{state}] {file_path}")
        print(f"         log group : {clean_text(group)}")
        print(f"         log stream: {clean_text(stream)}")
        print(f"         requests={stat['requests']}, events={stat['events']}")
else:
    print("  [WARN] cwagent 設定から collect_list を取得できませんでした。")

expected_keys = {(group, stream) for group, stream, _ in expected}
unexpected = [key for key in destination_stats if key not in expected_keys]
if unexpected:
    print("")
    print("[設定外の受信先]")
    for group, stream in sorted(unexpected):
        stat = destination_stats[(group, stream)]
        print(f"  {clean_text(group)} / {clean_text(stream)} "
              f"(requests={stat['requests']}, events={stat['events']})")

print("")
print(f"[受信ログイベント（新しい順、最大 {event_limit} 件）]")
events.sort(key=lambda event: float(event["timestamp"] or 0), reverse=True)
if not events:
    print("  PutLogEvents のログイベント本文は確認できませんでした。")
else:
    for event in events[:event_limit]:
        print(f"  {event_time(event['timestamp'])} "
              f"{clean_text(event['group'], 160)} / {clean_text(event['stream'], 160)}")
        print(f"    {clean_text(event['message'])}")
print("═══════════════════════════════════════════════════════════")
PY
)"
  run_observability_python \
    "${OBSERVABILITY_PYTHON_JSON_LOADER}${OBSERVABILITY_PYTHON_WIREMOCK_LOADER}${program}" \
    2 "$config_json" "$journal_json" \
    "$create_group_count" "$create_stream_count" "$put_count" \
    "$OBSERVABILITY_EVENT_DISPLAY_LIMIT" "$OBSERVABILITY_WIREMOCK_REQUEST_LIMIT"
}

run_cloudwatch_logs_delivery_helper() {
  local selected_service="$1" cwagent_service="cwagent"
  local cwagent_id cwagent_config journal create_group_count create_stream_count put_count
  local agent_logs agent_diagnostics
  local -a cwagent_ids=()

  require_observability_tools || return 1
  mapfile -t cwagent_ids < <(compose_container_ids "$cwagent_service")
  if [ ${#cwagent_ids[@]} -eq 0 ]; then
    err "CloudWatch Logs 送信元の Compose サービス 'cwagent' が実行中ではありません。"
    return 1
  fi
  cwagent_id="${cwagent_ids[0]}"
  if ! cwagent_config="$(docker exec "$cwagent_id" cat /etc/cwagentconfig/cwagent-config.json 2>/dev/null)"; then
    warn "cwagent の設定ファイルを取得できないため、送信先との自動照合は限定されます。"
    cwagent_config='{}'
  fi

  resolve_compose_service_http_endpoint "cloudwatch-logs-mock" "8080" || return 1
  diag ""
  diag "CloudWatch Agent → CloudWatch Logs 偽装サービスの送達を確認します。"
  diag "選択サービス: ${selected_service} / mock: ${OBSERVABILITY_CONTAINER_NAME}"
  diag "WireMock request journal: ${OBSERVABILITY_HTTP_BASE_URL}"
  diag "注意: 実 AWS CloudWatch Logs ではなく、Compose 内 WireMock の受信記録を確認します。"

  create_group_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.CreateLogGroup" || printf '?')"
  create_stream_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.CreateLogStream" || printf '?')"
  put_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.PutLogEvents" || printf '?')"
  if ! journal="$(observability_http_get "${OBSERVABILITY_HTTP_BASE_URL}/__admin/requests?limit=${OBSERVABILITY_WIREMOCK_REQUEST_LIMIT}")"; then
    err "cloudwatch-logs-mock の request journal を取得できませんでした。"
    return 1
  fi

  if ! render_cloudwatch_delivery_report "$cwagent_config" "$journal" \
      "$create_group_count" "$create_stream_count" "$put_count" >&2; then
    err "CloudWatch Logs 偽装送達レポートを生成できませんでした。"
    return 1
  fi

  if agent_logs="$(compose_logs "$cwagent_service" 2>/dev/null)"; then
    agent_diagnostics="$(
      printf '%s\n' "$agent_logs" | strip_ansi_codes \
        | grep -Ei '(^|[[:space:]])(E!|W!|ERROR|WARN|failed|denied|timeout)' \
        | tail -n 20 || true
    )"
    diag ""
    diag "[cwagent の警告・エラー（最大 20 行）]"
    if [ -n "$agent_diagnostics" ]; then
      printf '%s\n' "$agent_diagnostics" >&2
    else
      diag "  今回の起動以降に該当する警告・エラーは見つかりませんでした。"
    fi
  fi
  diag ""
  diag "判定基準: 設定済み log group / log stream に PutLogEvents とイベント本文があれば送達確認済みです。"
  diag "未確認の場合は cwagent の force_flush_interval (対象構成は 5 秒) 以上待ってから再実行してください。"
  diag "メッセージには機微情報が含まれ得るため、共有・ログ保存時の取り扱いに注意してください。"
}

# =============================================================================
# CloudWatch Agent (cwagent) のログ送信検証
# -----------------------------------------------------------------------------
# ECS の taskdef と同じ CloudWatch Agent サイドカーを compose.yml から起動する構成は、
# 設定不備があってもエージェント自体は正常に起動してしまい、CloudWatch Logs へ 1 件も
# 届かないまま気付かないことが多い。ビルド時のチェックとして次の 2 段で検証する。
#
#   (A) verify_cwagent_config_definition : ビルド前の設定ファイルチェック
#       compose.yml の cwagent 定義と、マウントする設定 JSON をホスト側だけで突き合わせ、
#       送信先・収集対象・リージョン・認証の不備を起動前に検出する。
#   (B) verify_cwagent_log_delivery      : 起動確認後の送信状況チェック
#       起動した cwagent が実際に読み込んだ設定を取り出してホスト側と比較し、
#       設定済みのロググループ / ログストリームへログイベントが届くまで待って確認する。
# =============================================================================

cwagent_record_stage() {
  local label="$1" verdict="$2" note="${3:-}"
  CWAGENT_STAGE_RESULTS+=(
    "${label}${CWAGENT_STAGE_SEPARATOR}${verdict}${CWAGENT_STAGE_SEPARATOR}${note}"
  )
  case "$verdict" in
    NG*)     CWAGENT_NG="true" ;;
    未確認*) CWAGENT_UNKNOWN="true" ;;
  esac
}

# ログ本文には認証情報が混ざり得るため、画面へ出す前に代表的な名前の値を伏せる。
# Python ヘルパー側の clean_text と同じ観点を、シェル経路にも適用する。
cwagent_redact_text() {
  sed -E 's/(password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)([[:space:]]*[:=][[:space:]]*)[^[:space:],;]+/\1\2[REDACTED]/Ig'
}

# compose の短縮記法 volumes ("SOURCE:TARGET[:MODE]") を分解する。
# 出力: SOURCE<US>TARGET<US>MODE (SOURCE が空なら匿名ボリューム)
cwagent_split_volume_spec() {
  local spec="$1" source target mode="" rest
  case "$spec" in
    *:*) ;;
    *)
      printf '%s%s%s%s%s\n' "" "$COMPOSE_YAML_SEPARATOR" "$spec" "$COMPOSE_YAML_SEPARATOR" ""
      return 0
      ;;
  esac
  source="${spec%%:*}"
  rest="${spec#*:}"
  case "$rest" in
    *:*) target="${rest%%:*}"; mode="${rest#*:}" ;;
    *)   target="$rest" ;;
  esac
  printf '%s%s%s%s%s\n' "$source" "$COMPOSE_YAML_SEPARATOR" "$target" "$COMPOSE_YAML_SEPARATOR" "$mode"
}

# compose.yml からの相対パスを絶対パスへ直す (bind mount のホスト側実体を確認するため)。
cwagent_resolve_host_path() {
  local path="$1" compose_dir
  case "$path" in
    /*|~*) printf '%s\n' "$path"; return 0 ;;
  esac
  if ! compose_dir="$(compose_file_dir)"; then
    printf '%s\n' "$path"
    return 0
  fi
  path="${path#./}"
  printf '%s/%s\n' "${compose_dir%/}" "$path"
}

# compose.yml を 1 回走査し、cwagent の定義と全サービスの volumes を配列へ展開する。
cwagent_collect_compose_definition() {
  local kind entry_path value service rest env_name env_value dependency

  CWAGENT_ENV_VALUES=()
  CWAGENT_DEPENDS_ON=()
  COMPOSE_CONTAINER_NAMES=()
  COMPOSE_DEFINED_SERVICES=()
  CWAGENT_VOLUME_SPECS=()
  COMPOSE_VOLUME_SPECS=()
  CWAGENT_IMAGE=""
  CWAGENT_LONG_SYNTAX_VOLUMES="false"

  [ -f "$COMPOSE_FILE" ] || return 1

  while IFS="$COMPOSE_YAML_SEPARATOR" read -r kind entry_path value; do
    [ -n "$kind" ] || continue
    case "$entry_path" in
      services.*) ;;
      *) continue ;;
    esac
    rest="${entry_path#services.}"
    service="${rest%%.*}"
    [ -n "$service" ] || continue
    COMPOSE_DEFINED_SERVICES["$service"]="true"
    rest="${rest#"$service"}"
    rest="${rest#.}"

    case "$kind:$rest" in
      kv:container_name) COMPOSE_CONTAINER_NAMES["$service"]="$value" ;;
      list:volumes) COMPOSE_VOLUME_SPECS+=("${service}${COMPOSE_YAML_SEPARATOR}${value}") ;;
    esac

    [ "$service" = "$CWAGENT_SERVICE" ] || continue
    case "$kind:$rest" in
      kv:image) CWAGENT_IMAGE="$value" ;;
      kv:environment.*)
        env_name="${rest#environment.}"
        CWAGENT_ENV_VALUES["$env_name"]="$value"
        ;;
      list:environment)
        # リスト記法 (- NAME=VALUE) は = の前後で分ける。値なしは空文字とする。
        env_name="${value%%=*}"
        env_value="${value#*=}"
        [ "$env_value" = "$value" ] && env_value=""
        [ -n "$env_name" ] && CWAGENT_ENV_VALUES["$env_name"]="$env_value"
        ;;
      list:volumes)
        # 長記法 (- type: bind / source: ... ) はこの展開では分解できないため、
        # 検出だけ記録して volumes 依存の判定を「未確認」に落とす。
        case "$value" in
          type:*|source:*|target:*|read_only:*) CWAGENT_LONG_SYNTAX_VOLUMES="true" ;;
          *) CWAGENT_VOLUME_SPECS+=("$value") ;;
        esac
        ;;
      kv:depends_on.*.condition)
        dependency="${rest#depends_on.}"
        dependency="${dependency%.condition}"
        CWAGENT_DEPENDS_ON["$dependency"]="$value"
        ;;
      list:depends_on) CWAGENT_DEPENDS_ON["$value"]="(条件指定なし)" ;;
    esac
  done < <(compose_yaml_entries "$COMPOSE_FILE" "$COMPOSE_YAML_SEPARATOR")
  return 0
}

# compose.yml の定義に現れないサービス (extends / include 経由など) を補うため、
# YAML の走査で cwagent が見つからなかったときだけ compose 側の解決結果も確認する。
cwagent_service_is_defined() {
  local service
  [ -n "${COMPOSE_DEFINED_SERVICES[$CWAGENT_SERVICE]:-}" ] && return 0
  while IFS= read -r service; do
    [ -n "$service" ] || continue
    COMPOSE_DEFINED_SERVICES["$service"]="true"
  done < <("${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" config --services 2>/dev/null || true)
  [ -n "${COMPOSE_DEFINED_SERVICES[$CWAGENT_SERVICE]:-}" ]
}

# 設定 JSON から、照合に必要な項目だけを US 区切りのレコードとして取り出す。
# レコード種別:
#   agent_region / agent_debug / agent_credentials / endpoint_override
#   force_flush_interval / default_log_stream
#   collect <file_path> <group> <stream> <stream の由来> <timestamp_format> <timezone> <auto_removal>
#   ng <メッセージ> / warn <メッセージ> / info <メッセージ>
cwagent_config_facts() {
  local config_json="$1" program

  program="$(cat <<'PY'
import re
import sys

SEP = "\x1f"


def out(*fields):
    print(SEP.join("" if field is None else str(field) for field in fields))


config, = load_json_documents(["cwagent 設定ファイル"])
if not isinstance(config, dict):
    print("[ERROR] cwagent 設定ファイルの最上位が JSON オブジェクトではありません。", file=sys.stderr)
    raise SystemExit(2)

agent = config.get("agent") if isinstance(config.get("agent"), dict) else {}
logs = config.get("logs") if isinstance(config.get("logs"), dict) else {}

out("agent_region", agent.get("region") or "")
out("agent_debug", "true" if agent.get("debug") else "false")
credentials = agent.get("credentials")
if isinstance(credentials, dict) and credentials.get("role_arn"):
    out("agent_credentials", str(credentials.get("role_arn")))

if not logs:
    out("ng", "設定に logs セクションがありません。ログファイルの収集・送信は一切行われません。")

out("endpoint_override", str(logs.get("endpoint_override") or ""))

flush = logs.get("force_flush_interval")
if isinstance(flush, bool) or not isinstance(flush, (int, float)):
    if flush is not None:
        out("warn", f"logs.force_flush_interval が数値ではありません: {flush!r}")
    out("force_flush_interval", "")
else:
    out("force_flush_interval", int(flush))

default_stream = str(logs.get("log_stream_name") or "")
out("default_log_stream", default_stream)

collected = logs.get("logs_collected") if isinstance(logs.get("logs_collected"), dict) else {}
files = collected.get("files") if isinstance(collected.get("files"), dict) else {}
collect_list = files.get("collect_list")
if not isinstance(collect_list, list) or not collect_list:
    if logs:
        out("ng", "logs.logs_collected.files.collect_list が空です。収集対象のログファイルがありません。")
    collect_list = []

# CloudWatch Logs の命名規則 (ロググループ: 英数と _ / . - # のみ、1〜512 文字。
# ログストリーム: : と * を含められず、1〜512 文字)。
group_pattern = re.compile(r"^[A-Za-z0-9_./#-]{1,512}$")
stream_pattern = re.compile(r"^[^:*]{1,512}$")

for index, entry in enumerate(collect_list, start=1):
    if not isinstance(entry, dict):
        out("ng", f"collect_list[{index}] がオブジェクトではないため収集対象になりません。")
        continue
    file_path = str(entry.get("file_path") or "")
    group = str(entry.get("log_group_name") or "")
    stream_value = entry.get("log_stream_name")
    if stream_value:
        stream = str(stream_value)
        stream_source = "エントリ指定"
    elif default_stream:
        stream = default_stream
        stream_source = "logs.log_stream_name の既定値"
    else:
        stream = ""
        stream_source = "未指定 (エージェントがホスト名等から自動生成)"
    timestamp_format = str(entry.get("timestamp_format") or "")
    timezone = str(entry.get("timezone") or "")
    auto_removal = "true" if entry.get("auto_removal") else ""

    if not file_path:
        out("ng", f"collect_list[{index}] に file_path がありません。収集対象を特定できません。")
    if not group:
        out("ng", f"collect_list[{index}] ({file_path or '(file_path 未指定)'}) に log_group_name がありません。送信先ロググループを特定できません。")
    elif not group_pattern.match(group):
        out("ng", f"log_group_name が CloudWatch Logs の命名規則に反します (英数と _ . / # - のみ、1〜512 文字): {group}")
    if stream and not stream_pattern.match(stream):
        out("ng", f"log_stream_name が CloudWatch Logs の命名規則に反します (: と * は使用不可、1〜512 文字): {stream}")
    if not stream:
        out("warn", f"collect_list[{index}] ({file_path}) の log_stream_name が未指定です。送信先ストリーム名が実行環境で変わるため、送達確認では照合できません。")
    if entry.get("multi_line_start_pattern") and not timestamp_format:
        out("warn", f"collect_list[{index}] ({file_path}) は multi_line_start_pattern を使いますが timestamp_format がありません。イベントの区切りが想定とずれることがあります。")

    out("collect", file_path, group, stream, stream_source, timestamp_format, timezone, auto_removal)
PY
)"
  run_observability_python \
    "${OBSERVABILITY_PYTHON_JSON_LOADER}${program}" 1 "$config_json"
}

# --- (A) 設定ファイルのチェック (ビルド前) -----------------------------------

# 設定ファイルの注入経路を突き止める。
# 戻り値: 0 = 特定できた / 1 = 特定できない (段は関数内で記録済み)
cwagent_verify_config_injection() {
  local stage_label="設定ファイルの注入 (compose.yml volumes → ${CWAGENT_CONFIG_DIR})"
  local spec source target mode host_path matched_target="" matched_source="" matched_mode=""

  if [ -n "${CWAGENT_ENV_VALUES[CW_CONFIG_CONTENT]:-}" ]; then
    CWAGENT_HOST_CONFIG_FILE=""
    cwagent_record_stage "$stage_label" "未確認" \
        "環境変数 CW_CONFIG_CONTENT で設定を注入しています。設定本文はホスト側のファイルではないため、静的な内容チェックは行いません (起動後の送達チェックで確認します)"
    return 1
  fi

  for spec in ${CWAGENT_VOLUME_SPECS[@]+"${CWAGENT_VOLUME_SPECS[@]}"}; do
    IFS="$COMPOSE_YAML_SEPARATOR" read -r source target mode < <(cwagent_split_volume_spec "$spec")
    case "$target" in
      "$CWAGENT_CONFIG_DIR"|"$CWAGENT_CONFIG_DIR"/*|"$CWAGENT_CONFIG_FALLBACK_PATH")
        matched_target="$target"
        matched_source="$source"
        matched_mode="$mode"
        break
        ;;
    esac
  done

  if [ -z "$matched_target" ]; then
    if [ "$CWAGENT_LONG_SYNTAX_VOLUMES" = "true" ]; then
      cwagent_record_stage "$stage_label" "未確認" \
          "volumes が長記法 (type: bind ...) のため、このスクリプトでは注入先を判定できません。${CWAGENT_CONFIG_DIR} へ設定ファイルをマウントしているか手動で確認してください"
      return 1
    fi
    cwagent_record_stage "$stage_label" "NG" \
        "${CWAGENT_CONFIG_DIR} (または ${CWAGENT_CONFIG_FALLBACK_PATH}) へ設定ファイルをマウントする volumes がありません。CloudWatch Agent は既定設定で起動し、ログを 1 件も送信しません。現在の volumes: ${CWAGENT_VOLUME_SPECS[*]:-(なし)}"
    return 1
  fi

  case "$matched_source" in
    ./*|../*|/*|~*) ;;
    *)
      cwagent_record_stage "$stage_label" "NG" \
          "設定ファイルの注入元 '${matched_source}' が名前付きボリュームです。ホスト側の設定 JSON を bind mount してください (例: ./compose/cwagent/cwagent-config.json:${CWAGENT_CONFIG_DIR}/cwagent-config.json:ro)"
      return 1
      ;;
  esac

  host_path="$(cwagent_resolve_host_path "$matched_source")"
  if [ ! -e "$host_path" ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "マウント元のファイルがホストに存在しません: ${matched_source} (解決先: ${host_path})。存在しないパスを bind mount すると Docker が空のディレクトリを作るため、CloudWatch Agent へ設定は届きません"
    return 1
  fi
  if [ -d "$host_path" ]; then
    # ディレクトリごとマウントする構成。中の JSON を 1 つ選んで内容チェックへ回す。
    local candidate=""
    for candidate in "$host_path"/*.json; do
      [ -f "$candidate" ] || continue
      CWAGENT_HOST_CONFIG_FILE="$candidate"
      break
    done
    if [ -z "$CWAGENT_HOST_CONFIG_FILE" ]; then
      cwagent_record_stage "$stage_label" "NG" \
          "マウント元ディレクトリ ${host_path} に設定 JSON がありません。CloudWatch Agent は読み込む設定を見つけられません"
      return 1
    fi
    CWAGENT_CONTAINER_CONFIG_FILE="${matched_target%/}/$(basename "$CWAGENT_HOST_CONFIG_FILE")"
  else
    CWAGENT_HOST_CONFIG_FILE="$host_path"
    CWAGENT_CONTAINER_CONFIG_FILE="$matched_target"
  fi

  cwagent_record_stage "$stage_label" "OK" \
      "${matched_source} → ${matched_target}${matched_mode:+:${matched_mode}} (ホスト側実体: ${CWAGENT_HOST_CONFIG_FILE})"
  return 0
}

# 設定 JSON の内容 (収集定義・命名規則) を確認し、以降の照合に使う値を取り出す。
cwagent_verify_config_content() {
  local stage_label="設定ファイルの内容 (収集定義とロググループ)"
  local config_json kind field1 field2 field3 field4 field5 field6 field7
  local collect_count=0 ng_count=0 destinations=""

  [ -n "$CWAGENT_HOST_CONFIG_FILE" ] || return 1
  if ! config_json="$(cat "$CWAGENT_HOST_CONFIG_FILE" 2>/dev/null)"; then
    cwagent_record_stage "$stage_label" "NG" \
        "設定ファイルを読み取れません: ${CWAGENT_HOST_CONFIG_FILE}"
    return 1
  fi
  # 設定 JSON の解析には Python 3 が要る (curl はこの段では不要)。
  if ! resolve_observability_python; then
    cwagent_record_stage "$stage_label" "未確認" \
        "Python 3 が見つからないため、設定ファイルの内容を解析できません: ${CWAGENT_HOST_CONFIG_FILE}"
    return 1
  fi

  local facts detail
  if ! facts="$(cwagent_config_facts "$config_json" 2>/dev/null)"; then
    # 失敗時のみ、原因を示すために標準エラー出力を取り直す。
    detail="$(cwagent_config_facts "$config_json" 2>&1 >/dev/null | tr '\n' ' ' | cut -c1-200)"
    cwagent_record_stage "$stage_label" "NG" \
        "設定ファイルの JSON を解析できません: ${CWAGENT_HOST_CONFIG_FILE} (${detail:-詳細不明})。CloudWatch Agent は設定を読み込めず、ログを送信しません"
    return 1
  fi

  CWAGENT_CONFIG_PARSED="true"
  while IFS="$CWAGENT_STAGE_SEPARATOR" read -r kind field1 field2 field3 field4 field5 field6 field7; do
    [ -n "$kind" ] || continue
    case "$kind" in
      agent_region)   [ -n "$field1" ] && CWAGENT_CONFIG_REGION="$field1" ;;
      endpoint_override) CWAGENT_ENDPOINT_OVERRIDE="$field1" ;;
      force_flush_interval) CWAGENT_FORCE_FLUSH_INTERVAL="$field1" ;;
      collect)
        collect_count=$((collect_count + 1))
        CWAGENT_EXPECTED_DESTINATIONS+=(
          "${field2}${CWAGENT_STAGE_SEPARATOR}${field3}${CWAGENT_STAGE_SEPARATOR}${field1}"
        )
        destinations="${destinations}${destinations:+, }${field2}/${field3:-(自動生成)}"
        ;;
      ng)
        ng_count=$((ng_count + 1))
        cwagent_record_stage "設定ファイルの収集定義" "NG" "$field1"
        ;;
      warn)
        cwagent_record_stage "設定ファイルの収集定義" "注意" "$field1"
        ;;
      info)
        cwagent_record_stage "設定ファイルの収集定義" "情報" "$field1"
        ;;
    esac
  done <<< "$facts"

  if [ "$ng_count" -gt 0 ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "収集定義に ${ng_count} 件の問題があります (収集対象: ${collect_count} 件)"
    return 1
  fi
  cwagent_record_stage "$stage_label" "OK" \
      "収集対象 ${collect_count} 件 / 送信先: ${destinations:-(なし)}${CWAGENT_FORCE_FLUSH_INTERVAL:+ / force_flush_interval=${CWAGENT_FORCE_FLUSH_INTERVAL} 秒}"
  return 0
}

# logs.endpoint_override の送信先が、compose ネットワーク内で名前解決できるか確認する。
cwagent_verify_endpoint_override() {
  local stage_label="送信先 (logs.endpoint_override)"
  local endpoint host port="" hostport service matched=""

  if [ -z "$CWAGENT_ENDPOINT_OVERRIDE" ]; then
    cwagent_record_stage "$stage_label" "情報" \
        "endpoint_override が未設定のため、実 CloudWatch Logs (logs.<region>.amazonaws.com) へ送信します。コンテナからの HTTPS 経路と IAM 権限 (logs:CreateLogGroup / logs:CreateLogStream / logs:PutLogEvents) が必要です"
    return 0
  fi

  endpoint="$CWAGENT_ENDPOINT_OVERRIDE"
  hostport="${endpoint#*://}"
  hostport="${hostport%%/*}"
  host="${hostport%%:*}"
  case "$hostport" in
    *:*) port="${hostport##*:}" ;;
  esac
  CWAGENT_ENDPOINT_HOST="$host"
  CWAGENT_ENDPOINT_PORT="$port"

  if [ -z "$host" ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "endpoint_override のホスト名を解釈できません: ${endpoint}"
    return 1
  fi

  case "$host" in
    localhost|127.0.0.1|::1|0.0.0.0)
      cwagent_record_stage "$stage_label" "NG" \
          "endpoint_override が ${host} を指しています。cwagent コンテナ自身を指すため、別コンテナの CloudWatch Logs 偽装サービスへは届きません。Compose のサービス名を指定してください: ${endpoint}"
      return 1
      ;;
    *[0-9].[0-9]*)
      # IP アドレス直指定は名前解決の照合ができないため確認対象外とする。
      if printf '%s' "$host" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
        cwagent_record_stage "$stage_label" "未確認" \
            "endpoint_override が IP アドレス (${host}) を直接指しているため、compose.yml との照合はできません: ${endpoint}"
        return 0
      fi
      ;;
  esac

  if [ -n "${COMPOSE_DEFINED_SERVICES[$host]:-}" ]; then
    matched="Compose サービス '${host}'"
  else
    for service in "${!COMPOSE_CONTAINER_NAMES[@]}"; do
      if [ "${COMPOSE_CONTAINER_NAMES[$service]}" = "$host" ]; then
        matched="サービス '${service}' の container_name '${host}'"
        break
      fi
    done
  fi

  if [ -z "$matched" ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "endpoint_override のホスト '${host}' が compose.yml のサービス名・container_name のいずれとも一致しません。cwagent コンテナ内で名前解決できず、送信はすべて失敗します: ${endpoint}"
    return 1
  fi

  # 送信先が listen する前に送った分は捨てられるため、depends_on での待ち合わせも見る。
  local dependency_note=""
  local depends_key="$host"
  [ -n "${CWAGENT_DEPENDS_ON[$host]:-}" ] || depends_key=""
  if [ -z "$depends_key" ]; then
    for service in "${!CWAGENT_DEPENDS_ON[@]}"; do
      if [ "${COMPOSE_CONTAINER_NAMES[$service]:-}" = "$host" ]; then
        depends_key="$service"
        break
      fi
    done
  fi
  if [ -z "$depends_key" ]; then
    dependency_note=" / 注意: cwagent の depends_on に送信先がありません。送信先が listen する前に送ったログイベントは失われます"
  elif [ "${CWAGENT_DEPENDS_ON[$depends_key]}" != "service_healthy" ]; then
    dependency_note=" / 注意: depends_on の condition が '${CWAGENT_DEPENDS_ON[$depends_key]}' です。listen 完了を待つには service_healthy を指定してください"
  fi

  cwagent_record_stage "$stage_label" "OK" \
      "${endpoint} → ${matched}${dependency_note}"
  return 0
}

# collect_list の file_path が cwagent へマウントされているかを確認する。
# ここが抜けていると、設定も送信先も正しいのに tail 対象が存在せず何も送られない。
cwagent_verify_log_source_mounts() {
  local stage_label="収集対象ログファイルのマウント"
  local destination group stream file_path spec source target mode
  local matched_target matched_source entry writer_service writer_spec
  local writer_source writer_target writer_mode
  local unmounted="" mounted_count=0 writerless=""

  if [ ${#CWAGENT_EXPECTED_DESTINATIONS[@]} -eq 0 ]; then
    return 0
  fi
  if [ "$CWAGENT_LONG_SYNTAX_VOLUMES" = "true" ]; then
    cwagent_record_stage "$stage_label" "未確認" \
        "cwagent の volumes が長記法のため、収集対象パスのマウント有無を判定できません"
    return 0
  fi

  for destination in "${CWAGENT_EXPECTED_DESTINATIONS[@]}"; do
    IFS="$CWAGENT_STAGE_SEPARATOR" read -r group stream file_path <<< "$destination"
    [ -n "$file_path" ] || continue
    matched_target=""
    matched_source=""
    for spec in ${CWAGENT_VOLUME_SPECS[@]+"${CWAGENT_VOLUME_SPECS[@]}"}; do
      IFS="$COMPOSE_YAML_SEPARATOR" read -r source target mode < <(cwagent_split_volume_spec "$spec")
      [ -n "$target" ] || continue
      case "$file_path" in
        "$target"|"$target"/*)
          matched_target="$target"
          matched_source="$source"
          break
          ;;
      esac
    done

    if [ -z "$matched_target" ]; then
      unmounted="${unmounted}${unmounted:+, }${file_path}"
      continue
    fi
    mounted_count=$((mounted_count + 1))

    # 収集元へ実際に書き込むサービスがいるか (読み取り専用マウントだけなら誰も書かない)。
    writer_service=""
    for entry in ${COMPOSE_VOLUME_SPECS[@]+"${COMPOSE_VOLUME_SPECS[@]}"}; do
      IFS="$COMPOSE_YAML_SEPARATOR" read -r writer_spec writer_source <<< "$entry"
      [ "$writer_spec" = "$CWAGENT_SERVICE" ] && continue
      IFS="$COMPOSE_YAML_SEPARATOR" read -r writer_source writer_target writer_mode \
        < <(cwagent_split_volume_spec "$writer_source")
      [ "$writer_source" = "$matched_source" ] || continue
      case "$writer_mode" in
        ro|ro,*|*,ro) continue ;;
      esac
      writer_service="$writer_spec"
      break
    done
    if [ -z "$writer_service" ]; then
      writerless="${writerless}${writerless:+, }${file_path} (マウント元: ${matched_source})"
    fi
  done

  if [ -n "$unmounted" ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "収集対象パスが cwagent にマウントされていません: ${unmounted}。tail 対象のファイルが存在しないため、ログは 1 件も送信されません。現在の volumes: ${CWAGENT_VOLUME_SPECS[*]:-(なし)}"
    return 1
  fi
  if [ -n "$writerless" ]; then
    cwagent_record_stage "$stage_label" "注意" \
        "収集対象はマウントされていますが、書き込み可能なマウントを持つ他サービスが compose.yml にありません: ${writerless}。ログを出力するサービスが同じボリュームを書き込みモードでマウントしているか確認してください"
    return 0
  fi
  cwagent_record_stage "$stage_label" "OK" \
      "収集対象 ${mounted_count} 件すべてが cwagent の volumes へマウントされています"
  return 0
}

# リージョンと認証情報 (SigV4 署名に必要) の指定を確認する。
cwagent_verify_region_and_credentials() {
  local region_stage="リージョン (agent.region / AWS_REGION)"
  local credential_stage="認証情報 (SigV4 署名)"
  local region="" region_source="" spec source target mode host_path credential_note=""

  if [ -n "$CWAGENT_CONFIG_REGION" ]; then
    region="$CWAGENT_CONFIG_REGION"
    region_source="設定ファイルの agent.region"
  elif [ -n "${CWAGENT_ENV_VALUES[AWS_REGION]:-}" ]; then
    region="${CWAGENT_ENV_VALUES[AWS_REGION]}"
    region_source="cwagent の環境変数 AWS_REGION"
  elif [ -n "${CWAGENT_ENV_VALUES[AWS_DEFAULT_REGION]:-}" ]; then
    region="${CWAGENT_ENV_VALUES[AWS_DEFAULT_REGION]}"
    region_source="cwagent の環境変数 AWS_DEFAULT_REGION"
  fi
  CWAGENT_CONFIG_REGION="$region"

  if [ -z "$region" ]; then
    cwagent_record_stage "$region_stage" "NG" \
        "リージョンが設定ファイルにも cwagent の environment にもありません。CloudWatch Agent は送信先エンドポイントを決められません"
  else
    cwagent_record_stage "$region_stage" "OK" "${region} (${region_source})"
  fi

  # 共有クレデンシャルファイルのマウント、環境変数、ECS タスクロールのいずれか。
  for spec in ${CWAGENT_VOLUME_SPECS[@]+"${CWAGENT_VOLUME_SPECS[@]}"}; do
    IFS="$COMPOSE_YAML_SEPARATOR" read -r source target mode < <(cwagent_split_volume_spec "$spec")
    case "$target" in
      */.aws/credentials|*/.aws|*/.aws/config)
        host_path="$(cwagent_resolve_host_path "$source")"
        if [ -e "$host_path" ]; then
          credential_note="共有クレデンシャルファイル ${source} → ${target}"
        else
          cwagent_record_stage "$credential_stage" "NG" \
              "クレデンシャルのマウント元がホストに存在しません: ${source} (解決先: ${host_path})。空ディレクトリがマウントされ、署名に使う認証情報が読み込めません"
          return 1
        fi
        break
        ;;
    esac
  done
  if [ -z "$credential_note" ]; then
    if [ -n "${CWAGENT_ENV_VALUES[AWS_ACCESS_KEY_ID]:-}" ]; then
      credential_note="環境変数 AWS_ACCESS_KEY_ID"
    elif [ -n "${CWAGENT_ENV_VALUES[AWS_PROFILE]:-}" ]; then
      credential_note="環境変数 AWS_PROFILE=${CWAGENT_ENV_VALUES[AWS_PROFILE]}"
    elif [ -n "${CWAGENT_ENV_VALUES[AWS_CONTAINER_CREDENTIALS_RELATIVE_URI]:-}" ] \
        || [ -n "${CWAGENT_ENV_VALUES[AWS_CONTAINER_CREDENTIALS_FULL_URI]:-}" ]; then
      credential_note="コンテナクレデンシャルプロバイダ (ECS タスクロール相当)"
    fi
  fi

  if [ -z "$credential_note" ]; then
    cwagent_record_stage "$credential_stage" "注意" \
        "cwagent に認証情報の指定がありません。CloudWatch Logs への送信は SigV4 署名が必要なため、EC2 インスタンスプロファイルなどホスト側の認証情報に依存します。ローカル検証では ダミー値の共有クレデンシャルファイルをマウントしてください"
    return 0
  fi
  cwagent_record_stage "$credential_stage" "OK" "$credential_note"
  return 0
}

# (A) の入口。ビルド前に呼び出す。
verify_cwagent_config_definition() {
  [ "$VERIFY_CWAGENT" != "false" ] || return 0

  if [ ! -f "$COMPOSE_FILE" ]; then
    if [ "$VERIFY_CWAGENT" = "true" ]; then
      cwagent_record_stage "compose.yml の cwagent サービス定義" "NG" \
          "compose ファイルが見つかりません: ${COMPOSE_FILE}"
      CWAGENT_VERIFY_ACTIVE="true"
    fi
    return 0
  fi

  cwagent_collect_compose_definition
  if ! cwagent_service_is_defined; then
    if [ "$VERIFY_CWAGENT" = "true" ]; then
      CWAGENT_VERIFY_ACTIVE="true"
      cwagent_record_stage "compose.yml の cwagent サービス定義" "NG" \
          "サービス '${CWAGENT_SERVICE}' が ${COMPOSE_FILE} にありません。--cwagent-service でサービス名を指定してください"
      cwagent_show_stage_results
    fi
    return 0
  fi

  CWAGENT_VERIFY_ACTIVE="true"
  log "CloudWatch Agent のログ送信検証を開始します (サービス: ${CWAGENT_SERVICE}, compose: ${COMPOSE_FILE})。"

  cwagent_record_stage "compose.yml の cwagent サービス定義" "OK" \
      "image=${CWAGENT_IMAGE:-(未指定)}${CWAGENT_ENV_VALUES[AWS_REGION]:+ / AWS_REGION=${CWAGENT_ENV_VALUES[AWS_REGION]}}"

  if cwagent_verify_config_injection; then
    # 設定 JSON を解析できなかった場合、送信先も収集対象も読み取れていないため、
    # 「未設定」と誤って報告しないよう後続の照合は行わない。
    cwagent_verify_config_content
    if [ "$CWAGENT_CONFIG_PARSED" = "true" ]; then
      cwagent_verify_endpoint_override
      cwagent_verify_log_source_mounts
    fi
  fi
  cwagent_verify_region_and_credentials

  cwagent_show_stage_results "ビルド前の設定ファイルチェック"
}

# --- (B) 送信状況のチェック (起動確認後) -------------------------------------

# WireMock の request journal から、設定済み送信先ごとの受信件数を取り出す。
# 出力: dest<US>group<US>stream<US>requests<US>events
cwagent_delivery_stats() {
  local config_json="$1" journal_json="$2" program

  program="$(cat <<'PY'
SEP = "\x1f"

config, journal = load_json_documents(["cwagent 設定", "WireMock request journal"])

collect_list = (
    config.get("logs", {})
    .get("logs_collected", {})
    .get("files", {})
    .get("collect_list", [])
)
default_stream = str(config.get("logs", {}).get("log_stream_name") or "")

stats = {}
for body in put_log_events_requests(journal):
    key = (str(body.get("logGroupName") or ""), str(body.get("logStreamName") or ""))
    entry = stats.setdefault(key, {"requests": 0, "events": 0})
    entry["requests"] += 1
    events = body.get("logEvents")
    entry["events"] += len(events) if isinstance(events, list) else 0

for entry in collect_list if isinstance(collect_list, list) else []:
    if not isinstance(entry, dict):
        continue
    group = str(entry.get("log_group_name") or "")
    stream = str(entry.get("log_stream_name") or default_stream)
    stat = stats.get((group, stream), {"requests": 0, "events": 0})
    print(SEP.join(["dest", group, stream, str(stat["requests"]), str(stat["events"])]))
PY
)"
  run_observability_python \
    "${OBSERVABILITY_PYTHON_JSON_LOADER}${OBSERVABILITY_PYTHON_WIREMOCK_LOADER}${program}" \
    2 "$config_json" "$journal_json"
}

# 起動した cwagent が実際に読み込んでいる設定を取り出し、ホスト側の内容と比較する。
# マウントが効いていない場合はここで判明する (症状が「送信されない」だけになる典型例)。
cwagent_verify_container_config() {
  local container_id="$1"
  local stage_label="コンテナ内の設定ファイル (${CWAGENT_CONTAINER_CONFIG_FILE:-${CWAGENT_CONFIG_DIR}})"
  local container_config host_config listing

  if [ -z "$CWAGENT_CONTAINER_CONFIG_FILE" ]; then
    cwagent_record_stage "$stage_label" "未確認" \
        "静的チェックでコンテナ内の設定ファイルパスを特定できていないため比較できません"
    return 1
  fi
  if ! container_config="$(docker exec "$container_id" cat "$CWAGENT_CONTAINER_CONFIG_FILE" 2>/dev/null)"; then
    listing="$(docker exec "$container_id" ls -l "$CWAGENT_CONFIG_DIR" 2>&1 | tr '\n' ' ' | cut -c1-200 || true)"
    cwagent_record_stage "$stage_label" "NG" \
        "コンテナ内に設定ファイルがありません: ${CWAGENT_CONTAINER_CONFIG_FILE} (${CWAGENT_CONFIG_DIR} の内容: ${listing:-取得できませんでした})"
    return 1
  fi
  CWAGENT_CONTAINER_CONFIG_JSON="$container_config"

  if [ -z "$CWAGENT_HOST_CONFIG_FILE" ]; then
    cwagent_record_stage "$stage_label" "OK" \
        "コンテナ内の設定ファイルを取得しました (ホスト側に実体が無いため内容比較は行いません)"
    return 0
  fi
  host_config="$(cat "$CWAGENT_HOST_CONFIG_FILE" 2>/dev/null || true)"
  if [ "$container_config" != "$host_config" ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "ホスト側の ${CWAGENT_HOST_CONFIG_FILE} とコンテナ内の ${CWAGENT_CONTAINER_CONFIG_FILE} の内容が一致しません。編集した設定が反映されていない (コンテナの作り直しが必要) 可能性があります"
    return 1
  fi
  cwagent_record_stage "$stage_label" "OK" \
      "ホスト側の設定ファイルと一致しました: ${CWAGENT_CONTAINER_CONFIG_FILE}"
  return 0
}

# 偽装 CloudWatch Logs (WireMock) への送達を、設定済みの送信先ごとに待って確認する。
cwagent_verify_delivery_via_mock() {
  local config_json="$1"
  local stage_label="ログイベントの送達 (CloudWatch Logs 偽装サービス)"
  local mock_service="$CWAGENT_MOCK_SERVICE" mock_port="$CWAGENT_MOCK_PORT"
  local waited=0 journal stats line kind group stream requests events
  local pending pending_list satisfied_list
  local create_group_count create_stream_count put_count

  [ -n "$mock_service" ] || mock_service="$CWAGENT_ENDPOINT_HOST"
  [ -n "$mock_port" ] || mock_port="$CWAGENT_ENDPOINT_PORT"
  [ -n "$mock_port" ] || mock_port="8080"
  if [ -z "$mock_service" ]; then
    cwagent_record_stage "$stage_label" "未確認" \
        "送信先の Compose サービスを特定できません。--cwagent-mock-service で指定してください"
    return 1
  fi
  # endpoint_override が container_name を指す場合は Compose サービス名へ読み替える。
  if [ -z "${COMPOSE_DEFINED_SERVICES[$mock_service]:-}" ]; then
    local service
    for service in "${!COMPOSE_CONTAINER_NAMES[@]}"; do
      if [ "${COMPOSE_CONTAINER_NAMES[$service]}" = "$mock_service" ]; then
        mock_service="$service"
        break
      fi
    done
  fi

  if ! resolve_compose_service_http_endpoint "$mock_service" "$mock_port"; then
    cwagent_record_stage "$stage_label" "未確認" \
        "CloudWatch Logs 偽装サービス '${mock_service}' の確認 URL を解決できませんでした"
    return 1
  fi

  log "CloudWatch Logs への送達を確認します (最大 ${CWAGENT_DELIVERY_TIMEOUT} 秒, ${CWAGENT_DELIVERY_INTERVAL} 秒間隔) ..."
  while :; do
    pending=0
    pending_list=""
    satisfied_list=""
    if journal="$(observability_http_get "${OBSERVABILITY_HTTP_BASE_URL}/__admin/requests?limit=${OBSERVABILITY_WIREMOCK_REQUEST_LIMIT}")" \
        && stats="$(cwagent_delivery_stats "$config_json" "$journal" 2>/dev/null)"; then
      while IFS="$CWAGENT_STAGE_SEPARATOR" read -r kind group stream requests events; do
        [ "$kind" = "dest" ] || continue
        if [ "${events:-0}" -gt 0 ] 2>/dev/null; then
          satisfied_list="${satisfied_list}${satisfied_list:+, }${group}/${stream} (${events} events)"
        else
          pending=$((pending + 1))
          pending_list="${pending_list}${pending_list:+, }${group}/${stream:-(自動生成)}"
        fi
      done <<< "$stats"
    else
      pending=1
      pending_list="request journal を取得できませんでした"
    fi
    [ "$pending" -eq 0 ] && break
    [ "$waited" -ge "$CWAGENT_DELIVERY_TIMEOUT" ] && break
    sleep "$CWAGENT_DELIVERY_INTERVAL"
    waited=$((waited + CWAGENT_DELIVERY_INTERVAL))
  done

  create_group_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.CreateLogGroup" || printf '?')"
  create_stream_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.CreateLogStream" || printf '?')"
  put_count="$(wiremock_request_count "$OBSERVABILITY_HTTP_BASE_URL" "Logs_20140328.PutLogEvents" || printf '?')"

  diag ""
  diag "確認先: ${mock_service} (${OBSERVABILITY_HTTP_BASE_URL}) / 待機時間: ${waited} 秒"
  diag "注意: 実 AWS CloudWatch Logs ではなく、Compose 内 WireMock の受信記録を確認しています。"
  [ -n "${journal:-}" ] || journal='{"requests":[]}'
  if ! render_cloudwatch_delivery_report "$config_json" "$journal" \
      "$create_group_count" "$create_stream_count" "$put_count" >&2; then
    warn "CloudWatch Logs 偽装送達レポートを生成できませんでした。"
  fi

  if [ "$pending" -gt 0 ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "${waited} 秒待っても送達を確認できない送信先があります: ${pending_list}${satisfied_list:+ / 確認できた送信先: ${satisfied_list}}。cwagent のログと、収集対象ファイルへの書き込み有無を確認してください"
    return 1
  fi
  cwagent_record_stage "$stage_label" "OK" \
      "設定済みの全送信先へログイベントが届きました: ${satisfied_list} (待機 ${waited} 秒)"
  return 0
}

# 送達確認先を決める (auto は logs.endpoint_override の有無で判定する)。
# 起動前のロググループ準備と、起動後の送達チェックの双方で同じ判定を使う。
cwagent_resolve_delivery_target() {
  local target="$CWAGENT_DELIVERY_TARGET"

  if [ "$target" = "auto" ]; then
    if [ -n "$CWAGENT_ENDPOINT_OVERRIDE" ]; then
      target="mock"
    else
      target="aws"
    fi
  fi
  printf '%s\n' "$target"
}

# この実行で既に存在確認・作成を終えたロググループかどうか。
cwagent_log_group_ensured() {
  local group="$1" ensured
  for ensured in ${CWAGENT_ENSURED_LOG_GROUPS[@]+"${CWAGENT_ENSURED_LOG_GROUPS[@]}"}; do
    [ "$ensured" = "$group" ] && return 0
  done
  return 1
}

# この実行で新規作成したロググループかどうか (表示の出し分けに使う)。
cwagent_log_group_created() {
  local group="$1" created
  for created in ${CWAGENT_CREATED_LOG_GROUPS[@]+"${CWAGENT_CREATED_LOG_GROUPS[@]}"}; do
    [ "$created" = "$group" ] && return 0
  done
  return 1
}

# この実行で作成に失敗したロググループかどうか。権限不足などの原因は 1 回の実行中に
# 変わらないため、2 回目以降は再試行せず、同じ NG も重ねて記録しない。
cwagent_log_group_failed() {
  local group="$1" failed
  for failed in ${CWAGENT_FAILED_LOG_GROUPS[@]+"${CWAGENT_FAILED_LOG_GROUPS[@]}"}; do
    [ "$failed" = "$group" ] && return 0
  done
  return 1
}

# 設定ファイルの log_group_name が実 CloudWatch Logs に無ければ、その名前で作成する。
# ロググループが存在しないと PutLogEvents は ResourceNotFoundException となり、
# cwagent 側に logs:CreateLogGroup 権限が無ければ 1 件も残らないため、送達確認の前
# (可能ならコンテナ起動前) にここで用意する。確認済みのものは再問い合わせしない。
cwagent_ensure_log_groups() {
  local stage_label="ロググループの自動作成 (CloudWatch Logs)"
  local region="${CWAGENT_CONFIG_REGION:-$REGION}"
  local destination group stream file_path existing create_error queued duplicate
  local created_list="" existing_list="" failed_list=""
  local -a targets=()

  [ "$CWAGENT_CREATE_LOG_GROUP" = "true" ] || return 0
  [ ${#CWAGENT_EXPECTED_DESTINATIONS[@]} -gt 0 ] || return 0

  # 同じロググループを複数の収集対象が共有する構成があるため、重複を除いてから扱う。
  for destination in "${CWAGENT_EXPECTED_DESTINATIONS[@]}"; do
    IFS="$CWAGENT_STAGE_SEPARATOR" read -r group stream file_path <<< "$destination"
    [ -n "$group" ] || continue
    cwagent_log_group_ensured "$group" && continue
    cwagent_log_group_failed "$group" && continue
    duplicate="false"
    for queued in ${targets[@]+"${targets[@]}"}; do
      if [ "$queued" = "$group" ]; then
        duplicate="true"
        break
      fi
    done
    [ "$duplicate" = "true" ] && continue
    targets+=("$group")
  done
  [ ${#targets[@]} -gt 0 ] || return 0

  if ! command -v aws >/dev/null 2>&1; then
    if [ "$CWAGENT_LOG_GROUP_STAGE_RECORDED" != "true" ]; then
      CWAGENT_LOG_GROUP_STAGE_RECORDED="true"
      cwagent_record_stage "$stage_label" "未確認" \
          "aws コマンドが見つからないため、ロググループの有無を確認・作成できません: ${targets[*]}"
    fi
    return 1
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    if [ "$CWAGENT_LOG_GROUP_STAGE_RECORDED" != "true" ]; then
      CWAGENT_LOG_GROUP_STAGE_RECORDED="true"
      cwagent_record_stage "$stage_label" "未確認" \
          "AWS 認証が確認できないため、ロググループの有無を確認・作成できません ('aws login --remote' で認証してください): ${targets[*]}"
    fi
    return 1
  fi

  for group in "${targets[@]}"; do
    existing="$(aws logs describe-log-groups --region "$region" \
        --log-group-name-prefix "$group" \
        --query "logGroups[?logGroupName=='${group}'].logGroupName" --output text 2>/dev/null || printf '')"
    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
      CWAGENT_ENSURED_LOG_GROUPS+=("$group")
      existing_list="${existing_list}${existing_list:+, }${group}"
      continue
    fi
    log "CloudWatch Logs にロググループがないため、設定ファイルの名前で作成します: ${group} (region=${region})"
    if create_error="$(aws logs create-log-group --region "$region" \
        --log-group-name "$group" 2>&1)"; then
      CWAGENT_ENSURED_LOG_GROUPS+=("$group")
      CWAGENT_CREATED_LOG_GROUPS+=("$group")
      created_list="${created_list}${created_list:+, }${group}"
      continue
    fi
    case "$create_error" in
      *ResourceAlreadyExistsException*)
        # 直前に他の実行やエージェント自身が作成した場合。存在する扱いでよい。
        CWAGENT_ENSURED_LOG_GROUPS+=("$group")
        existing_list="${existing_list}${existing_list:+, }${group}"
        ;;
      *)
        CWAGENT_FAILED_LOG_GROUPS+=("$group")
        failed_list="${failed_list}${failed_list:+, }${group} ($(printf '%s' "$create_error" | tr '\n' ' ' | cut -c1-200))"
        ;;
    esac
  done

  CWAGENT_LOG_GROUP_STAGE_RECORDED="true"
  if [ -n "$failed_list" ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "ロググループを作成できませんでした: ${failed_list}。logs:CreateLogGroup 権限とリージョン (${region}) を確認してください${created_list:+ / 作成済み: ${created_list}}"
    return 1
  fi
  if [ -n "$created_list" ]; then
    cwagent_record_stage "$stage_label" "OK" \
        "設定ファイルのロググループ名で作成しました (region=${region}): ${created_list}${existing_list:+ / 既存: ${existing_list}}"
    return 0
  fi
  cwagent_record_stage "$stage_label" "情報" \
      "設定ファイルのロググループはすべて存在するため作成していません (region=${region}): ${existing_list}"
  return 0
}

# コンテナ起動前にロググループを用意する入口。cwagent の最初の送信を取りこぼさない
# よう、実 CloudWatch Logs 宛ての構成に限りビルド前のチェック直後に実行する。
prepare_cwagent_log_groups() {
  [ "$CWAGENT_VERIFY_ACTIVE" = "true" ] || return 0
  [ ${#CWAGENT_EXPECTED_DESTINATIONS[@]} -gt 0 ] || return 0
  # コンテナを起動しない実行では、送信自体が起きないため作成もしない。
  [ "$NEED_CONTAINER" = "true" ] || return 0
  [ "$(cwagent_resolve_delivery_target)" = "aws" ] || return 0
  # --dry-run では指定の有無にかかわらず作成しないため、先に判定する。
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] CloudWatch Logs のロググループ自動作成をスキップします。"
    return 0
  fi
  # 作成は AWS アカウントへ実体を残すため、明示指定した実行だけで行う。作成対象が
  # あり得る構成のときだけ、指定方法を 1 行案内する。
  if [ "$CWAGENT_CREATE_LOG_GROUP" != "true" ]; then
    log "CloudWatch Logs のロググループ自動作成は行いません (--cwagent-create-log-group を指定すると、設定ファイルの log_group_name で作成します)。"
    return 0
  fi
  cwagent_ensure_log_groups || true
  return 0
}

# 実 CloudWatch Logs のロググループ / ストリーム / 今回の実行以降のイベントを確認する。
cwagent_verify_delivery_via_aws() {
  local stage_label="ログイベントの送達 (CloudWatch Logs)"
  local region="${CWAGENT_CONFIG_REGION:-$REGION}"
  local waited=0 destination group stream file_path
  local pending pending_list satisfied_list group_result stream_result event_count messages
  local -a stream_args=()

  if ! command -v aws >/dev/null 2>&1; then
    cwagent_record_stage "$stage_label" "未確認" \
        "aws コマンドが見つからないため、実 CloudWatch Logs への送達を確認できません"
    return 1
  fi
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    cwagent_record_stage "$stage_label" "未確認" \
        "AWS 認証が確認できないため、実 CloudWatch Logs への送達を確認できません ('aws login --remote' で認証してください)"
    return 1
  fi

  # 起動前の準備を行えなかった場合 (静的チェックの後で送信先が判明した、--dry-run
  # から切り替わった等) に備え、待ち合わせを始める前にもう一度用意する。
  cwagent_ensure_log_groups || true

  log "実 CloudWatch Logs への送達を確認します (region=${region}, 最大 ${CWAGENT_DELIVERY_TIMEOUT} 秒) ..."
  diag ""
  diag "════════════ CloudWatch Logs 送達レポート (region=${region}) ════════════"
  while :; do
    pending=0
    pending_list=""
    satisfied_list=""
    for destination in ${CWAGENT_EXPECTED_DESTINATIONS[@]+"${CWAGENT_EXPECTED_DESTINATIONS[@]}"}; do
      IFS="$CWAGENT_STAGE_SEPARATOR" read -r group stream file_path <<< "$destination"
      [ -n "$group" ] || continue
      # ストリーム名が自動生成される設定では、ロググループ全体のイベントで判定する。
      stream_args=()
      [ -n "$stream" ] && stream_args=(--log-stream-names "$stream")
      event_count="$(aws logs filter-log-events --region "$region" \
          --log-group-name "$group" ${stream_args[@]+"${stream_args[@]}"} \
          --start-time "$RUN_STARTED_EPOCH_MS" \
          --limit 50 --query 'length(events)' --output text 2>/dev/null || printf '')"
      if printf '%s' "$event_count" | grep -qE '^[0-9]+$' && [ "$event_count" -gt 0 ]; then
        satisfied_list="${satisfied_list}${satisfied_list:+, }${group}/${stream:-(自動生成)} (${event_count} events)"
      else
        pending=$((pending + 1))
        pending_list="${pending_list}${pending_list:+, }${group}/${stream:-(自動生成)}"
      fi
    done
    [ "$pending" -eq 0 ] && break
    [ "$waited" -ge "$CWAGENT_DELIVERY_TIMEOUT" ] && break
    sleep "$CWAGENT_DELIVERY_INTERVAL"
    waited=$((waited + CWAGENT_DELIVERY_INTERVAL))
  done

  for destination in ${CWAGENT_EXPECTED_DESTINATIONS[@]+"${CWAGENT_EXPECTED_DESTINATIONS[@]}"}; do
    IFS="$CWAGENT_STAGE_SEPARATOR" read -r group stream file_path <<< "$destination"
    [ -n "$group" ] || continue
    group_result="$(aws logs describe-log-groups --region "$region" \
        --log-group-name-prefix "$group" \
        --query "logGroups[?logGroupName=='${group}'].logGroupName" --output text 2>/dev/null || printf '')"
    diag ""
    diag "収集対象: ${file_path:-(未指定)}"
    if [ -z "$group_result" ] || [ "$group_result" = "None" ]; then
      if [ "$CWAGENT_CREATE_LOG_GROUP" = "true" ]; then
        diag "  [NG] ロググループが存在せず、自動作成もできませんでした: ${group}"
        diag "       logs:CreateLogGroup 権限とリージョン (${region}) を確認してください。"
      else
        diag "  [NG] ロググループが存在しません: ${group}"
        diag "       --cwagent-create-log-group を指定すると、設定ファイルの名前で自動作成します。"
      fi
      continue
    fi
    if cwagent_log_group_created "$group"; then
      diag "  [OK] ロググループ: ${group} (存在しなかったため今回の実行で自動作成しました)"
    else
      diag "  [OK] ロググループ: ${group}"
    fi
    if [ -n "$stream" ]; then
      stream_result="$(aws logs describe-log-streams --region "$region" \
          --log-group-name "$group" --log-stream-name-prefix "$stream" \
          --query "logStreams[?logStreamName=='${stream}'].lastEventTimestamp" \
          --output text 2>/dev/null || printf '')"
      if [ -z "$stream_result" ] || [ "$stream_result" = "None" ]; then
        diag "  [NG] ログストリームが存在しないか、イベントがありません: ${stream}"
      else
        diag "  [OK] ログストリーム: ${stream} (最終イベント: $(to_jst_display_time "@$((stream_result / 1000))"))"
      fi
    fi
    stream_args=()
    [ -n "$stream" ] && stream_args=(--log-stream-names "$stream")
    messages="$(aws logs filter-log-events --region "$region" --log-group-name "$group" \
        ${stream_args[@]+"${stream_args[@]}"} --start-time "$RUN_STARTED_EPOCH_MS" \
        --limit "$OBSERVABILITY_EVENT_DISPLAY_LIMIT" \
        --query 'events[].message' --output text 2>/dev/null | cwagent_redact_text || true)"
    if [ -n "$messages" ]; then
      diag "  [今回の実行以降に届いたイベント (最大 ${OBSERVABILITY_EVENT_DISPLAY_LIMIT} 件)]"
      printf '%s\n' "$messages" | sed 's/^/    /' >&2
    else
      diag "  [NG] 今回の実行 (${RUN_STARTED_AT} 以降) に届いたイベントはありません。"
    fi
  done
  diag "═══════════════════════════════════════════════════════════"
  diag "メッセージには機微情報が含まれ得るため、共有・ログ保存時の取り扱いに注意してください。"

  if [ "$pending" -gt 0 ]; then
    cwagent_record_stage "$stage_label" "NG" \
        "${waited} 秒待っても送達を確認できない送信先があります: ${pending_list}${satisfied_list:+ / 確認できた送信先: ${satisfied_list}}"
    return 1
  fi
  cwagent_record_stage "$stage_label" "OK" \
      "設定済みの全送信先へログイベントが届きました: ${satisfied_list} (待機 ${waited} 秒)"
  return 0
}

# cwagent 自身が出した警告・エラーを抜き出して表示する (送達 NG の原因調査用)。
cwagent_show_agent_diagnostics() {
  local agent_logs agent_diagnostics
  agent_logs="$(compose_logs "$CWAGENT_SERVICE" 2>/dev/null)" || return 0
  agent_diagnostics="$(
    printf '%s\n' "$agent_logs" | strip_ansi_codes \
      | grep -Ei '(^|[[:space:]])(E!|W!|ERROR|WARN|failed|denied|timeout|no such file)' \
      | tail -n 20 || true
  )"
  diag ""
  diag "[cwagent の警告・エラー（最大 20 行）]"
  if [ -n "$agent_diagnostics" ]; then
    printf '%s\n' "$agent_diagnostics" | cwagent_redact_text >&2
    cwagent_record_stage "cwagent の警告・エラーログ" "注意" \
        "$(printf '%s' "$agent_diagnostics" | tail -n 3 | tr '\n' ' ' | cwagent_redact_text | cut -c1-300)"
  else
    diag "  今回の起動以降に該当する警告・エラーは見つかりませんでした。"
    cwagent_record_stage "cwagent の警告・エラーログ" "OK" "該当する警告・エラーはありません"
  fi
}

# (B) の入口。起動確認・URL 確認の後に呼び出す。
verify_cwagent_log_delivery() {
  local container_id config_json target
  local -a container_ids=() all_container_ids=()

  [ "$CWAGENT_VERIFY_ACTIVE" = "true" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] cwagent の送信状況チェックをスキップします (コンテナを起動していないため)。"
    return 0
  fi
  if [ "$STARTED_CONTAINER" != "true" ]; then
    if [ ${#CWAGENT_EXPECTED_DESTINATIONS[@]} -gt 0 ]; then
      cwagent_record_stage "cwagent コンテナの起動" "未確認" \
          "コンテナを起動していないため送信状況を確認していません。--verify-startup または --verify-url を併用してください"
    fi
    cwagent_show_stage_results "cwagent のログ送信検証"
    return 0
  fi
  # curl / Python 3 は送達レポートの問い合わせと JSON 整形にだけ使う。レポートを
  # 行わない既定の実行では、コンテナ内設定の照合 (docker のみ) は続行できる。
  if [ "$CWAGENT_DELIVERY_REPORT" = "true" ] && ! require_observability_tools; then
    cwagent_record_stage "送信状況チェックの前提ツール" "未確認" \
        "curl と Python 3 が利用できないため、送信状況を確認できません"
    cwagent_show_stage_results "cwagent のログ送信検証"
    return 0
  fi

  mapfile -t container_ids < <(compose_container_ids "$CWAGENT_SERVICE")
  if [ ${#container_ids[@]} -eq 0 ]; then
    mapfile -t all_container_ids < <(compose_container_ids_all "$CWAGENT_SERVICE")
    if [ ${#all_container_ids[@]} -eq 0 ]; then
      cwagent_record_stage "cwagent コンテナの起動" "NG" \
          "サービス '${CWAGENT_SERVICE}' のコンテナが作成されていません。--compose-service に ${CWAGENT_SERVICE} を含めてください"
    else
      cwagent_record_stage "cwagent コンテナの起動" "NG" \
          "サービス '${CWAGENT_SERVICE}' が実行中ではありません: $(compose_service_container_summary "$CWAGENT_SERVICE")"
      cwagent_show_agent_diagnostics
    fi
    cwagent_show_stage_results "cwagent のログ送信検証"
    return 0
  fi
  container_id="${container_ids[0]}"
  cwagent_record_stage "cwagent コンテナの起動" "OK" \
      "$(compose_service_container_summary "$CWAGENT_SERVICE")"

  diag ""
  diag "==================================================================="
  diag "CloudWatch Agent の送信状況チェック"
  diag "  サービス      : ${CWAGENT_SERVICE}"
  diag "  設定ファイル  : ${CWAGENT_CONTAINER_CONFIG_FILE:-(未特定)}"
  diag "  送信先        : ${CWAGENT_ENDPOINT_OVERRIDE:-実 CloudWatch Logs (region=${CWAGENT_CONFIG_REGION:-$REGION})}"
  diag "==================================================================="

  # 実際にエージェントが読み込んでいる設定を優先し、比較できない場合はホスト側を使う。
  CWAGENT_CONTAINER_CONFIG_JSON=""
  cwagent_verify_container_config "$container_id"
  config_json="$CWAGENT_CONTAINER_CONFIG_JSON"
  if [ -z "$config_json" ] && [ -n "$CWAGENT_HOST_CONFIG_FILE" ]; then
    config_json="$(cat "$CWAGENT_HOST_CONFIG_FILE" 2>/dev/null || printf '{}')"
  fi
  [ -n "$config_json" ] || config_json='{}'

  target="$(cwagent_resolve_delivery_target)"

  if [ "$CWAGENT_DELIVERY_REPORT" != "true" ]; then
    # 送達レポートは送信先への問い合わせと最大 CWAGENT_DELIVERY_TIMEOUT 秒の
    # 待ち合わせを伴うため、明示指定した実行だけで行う。「未確認」にすると総合判定が
    # 曇るので、実施していないことを「情報」として残すだけにする。
    cwagent_record_stage "ログイベントの送達" "情報" \
        "--cwagent-delivery-report が指定されていないため、送達レポートは実行していません (待ち合わせ 0 秒)"
  elif [ ${#CWAGENT_EXPECTED_DESTINATIONS[@]} -eq 0 ]; then
    # 送信先を 1 つも特定できていない状態で問い合わせても判定できないため、
    # 設定側の問題として扱う (静的チェックの NG が原因のことが多い)。
    cwagent_record_stage "ログイベントの送達" "未確認" \
        "設定ファイルから送信先 (log group / log stream) を特定できていないため、送達を確認できません"
  elif [ "$target" = "mock" ]; then
    cwagent_verify_delivery_via_mock "$config_json"
  else
    cwagent_verify_delivery_via_aws
  fi
  cwagent_show_agent_diagnostics

  cwagent_show_stage_results "cwagent のログ送信検証"
  return 0
}

# --- 検証結果の表示 -----------------------------------------------------------

# 記録済みの段をまとめて表示し、未表示の段だけを対象にする (静的 → 送達の 2 回表示)。
CWAGENT_STAGE_PRINTED_COUNT=0
cwagent_show_stage_results() {
  local title="${1:-cwagent のログ送信検証}"
  local index=0 entry label verdict note total="${#CWAGENT_STAGE_RESULTS[@]}"

  [ "$total" -gt "$CWAGENT_STAGE_PRINTED_COUNT" ] || return 0
  diag ""
  diag "==================================================================="
  diag "${title}"
  diag "==================================================================="
  for entry in "${CWAGENT_STAGE_RESULTS[@]}"; do
    index=$((index + 1))
    [ "$index" -gt "$CWAGENT_STAGE_PRINTED_COUNT" ] || continue
    IFS="$CWAGENT_STAGE_SEPARATOR" read -r label verdict note <<< "$entry"
    diag "  [${verdict}] ${label}"
    [ -n "$note" ] && diag "      ${note}"
  done
  CWAGENT_STAGE_PRINTED_COUNT="$total"
  diag "───────────────────────────────────────────────────────────────────"
  if [ "$CWAGENT_NG" = "true" ]; then
    diag "  総合判定: NG あり — 上記 [NG] の段が、CloudWatch Logs へ届かない直接の原因です。"
  elif [ "$CWAGENT_UNKNOWN" = "true" ]; then
    diag "  総合判定: 確認できた段はすべて OK (未確認の段あり)"
  else
    diag "  総合判定: 全段 OK"
  fi
  diag "───────────────────────────────────────────────────────────────────"
  diag ""
}

# 検証結果を終了コードへ反映する。既定では警告のみとし、ビルド成否の判定は変えない
# (JBoss マスターパスワードの伝搬検証と同じ扱い)。--cwagent-required 指定時のみ、
# NG があれば処理全体を失敗として終了する。
finish_cwagent_verification() {
  [ "$CWAGENT_VERIFY_ACTIVE" = "true" ] || return 0
  if [ "$CWAGENT_NG" != "true" ]; then
    if [ "$CWAGENT_UNKNOWN" = "true" ]; then
      warn "cwagent のログ送信検証: 未確認の段があります (詳細は上記の一覧を参照してください)。"
    else
      log "cwagent のログ送信検証: 全段 OK です。"
    fi
    return 0
  fi
  if [ "$CWAGENT_REQUIRED" = "true" ]; then
    err "cwagent のログ送信検証で NG を検出しました。--cwagent-required が指定されているため失敗として終了します。"
    exit 1
  fi
  warn "cwagent のログ送信検証で NG を検出しました。CloudWatch Logs へログが届いていません (上記 [NG] の段を確認してください)。"
  warn "  NG をビルドの失敗として扱う場合は --cwagent-required を指定してください。"
  return 0
}

# 全量レポートへ検証結果を書き出す。
append_cwagent_report() {
  local report_file="$1" entry label verdict note

  if [ "$VERIFY_CWAGENT" = "false" ]; then
    printf '--no-verify-cwagent が指定されたため実行していません。\n' >> "$report_file"
    return 0
  fi
  if [ "$CWAGENT_VERIFY_ACTIVE" != "true" ]; then
    printf 'compose ファイルに CloudWatch Agent のサービス (%s) が定義されていないため実行していません。\n' \
      "$CWAGENT_SERVICE" >> "$report_file"
    return 0
  fi
  {
    printf 'サービス        : %s\n' "$CWAGENT_SERVICE"
    printf '設定ファイル    : ホスト %s / コンテナ %s\n' \
      "${CWAGENT_HOST_CONFIG_FILE:-(未特定)}" "${CWAGENT_CONTAINER_CONFIG_FILE:-(未特定)}"
    printf '送信先          : %s\n' \
      "${CWAGENT_ENDPOINT_OVERRIDE:-実 CloudWatch Logs (region=${CWAGENT_CONFIG_REGION:-$REGION})}"
    if [ ${#CWAGENT_EXPECTED_DESTINATIONS[@]} -gt 0 ]; then
      printf '設定済み送信先  :\n'
      for entry in "${CWAGENT_EXPECTED_DESTINATIONS[@]}"; do
        IFS="$CWAGENT_STAGE_SEPARATOR" read -r label verdict note <<< "$entry"
        printf '  - log group=%s / log stream=%s / file=%s\n' \
          "$label" "${verdict:-(自動生成)}" "$note"
      done
    fi
    if [ ${#CWAGENT_CREATED_LOG_GROUPS[@]} -gt 0 ]; then
      printf '自動作成した log group: %s\n' "${CWAGENT_CREATED_LOG_GROUPS[*]}"
    fi
    printf '\n'
  } >> "$report_file"

  if [ ${#CWAGENT_STAGE_RESULTS[@]} -eq 0 ]; then
    printf '検証結果はありません。\n' >> "$report_file"
    return 0
  fi
  for entry in "${CWAGENT_STAGE_RESULTS[@]}"; do
    IFS="$CWAGENT_STAGE_SEPARATOR" read -r label verdict note <<< "$entry"
    printf '[%s] %s\n' "$verdict" "$label" >> "$report_file"
    [ -n "$note" ] && printf '    %s\n' "$note" >> "$report_file"
  done
  printf '\n' >> "$report_file"
  if [ "$CWAGENT_NG" = "true" ]; then
    printf '総合判定: NG あり\n' >> "$report_file"
  elif [ "$CWAGENT_UNKNOWN" = "true" ]; then
    printf '総合判定: 確認できた段はすべて OK (未確認の段あり)\n' >> "$report_file"
  else
    printf '総合判定: 全段 OK\n' >> "$report_file"
  fi
  return 0
}

find_first_running_compose_service() {
  local candidate
  local -a candidate_ids=()

  for candidate in "$@"; do
    candidate_ids=()
    mapfile -t candidate_ids < <(compose_container_ids "$candidate")
    if [ ${#candidate_ids[@]} -gt 0 ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

extract_jaeger_services() {
  local services_json="$1" program

  program="$(cat <<'PY'
import json
import sys

document, = load_json_documents(["Jaeger サービス一覧"])

services = document.get("data", []) if isinstance(document, dict) else []
if not isinstance(services, list):
    print("[ERROR] Jaeger サービス一覧の data が配列ではありません。", file=sys.stderr)
    raise SystemExit(2)
for service in services:
    if isinstance(service, str) and service:
        print(service)
PY
)"
  run_observability_python \
    "${OBSERVABILITY_PYTHON_JSON_LOADER}${program}" 1 "$services_json"
}

# Jaeger Query API の応答から、トレース、スパン、親子関係、リソース属性、
# スパン属性、イベントを人間が追いやすい形式へ整形する。
render_jaeger_trace_report() {
  local traces_json="$1" selected_trace_service="$2"
  local program

  program="$(cat <<'PY'
import datetime
import json
import re
import sys


SENSITIVE_KEY = re.compile(
    r"(?i)(password|passwd|pwd|secret|token|authorization|cookie|api[._-]?key|credential)"
)
SENSITIVE_TEXT = re.compile(
    r"(?i)\b(password|passwd|pwd|secret|token|authorization|cookie|api[_-]?key|credential)"
    r"(\s*[:=]\s*)([^\s,;]+)"
)


def clean_value(key, value, limit=300):
    if SENSITIVE_KEY.search(str(key)):
        return "[REDACTED]"
    if isinstance(value, (dict, list)):
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    elif value is None:
        text = ""
    else:
        text = str(value)
    text = text.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t")
    text = SENSITIVE_TEXT.sub(
        lambda match: f"{match.group(1)}{match.group(2)}[REDACTED]", text
    )
    return text if len(text) <= limit else text[:limit] + "...(省略)"


def tags_as_pairs(tags):
    pairs = []
    for tag in tags if isinstance(tags, list) else []:
        if not isinstance(tag, dict):
            continue
        pairs.append((str(tag.get("key") or ""), tag.get("value")))
    return pairs


# スパンの時刻も JST 表記へ統一する (Jaeger の元値は UTC のマイクロ秒 epoch)。
JST = datetime.timezone(datetime.timedelta(hours=9), "JST")


def micros_to_time(value):
    try:
        stamp = float(value) / 1_000_000.0
        return datetime.datetime.fromtimestamp(
            stamp, JST
        ).isoformat(timespec="milliseconds").replace("+09:00", " JST")
    except Exception:
        return clean_value("time", value)


def millis(value):
    try:
        return f"{float(value) / 1000.0:.3f} ms"
    except Exception:
        return clean_value("duration", value)


def span_is_error(span):
    values = {key: value for key, value in tags_as_pairs(span.get("tags"))}
    error_value = values.get("error")
    status = str(values.get("otel.status_code") or values.get("status.code") or "").upper()
    return error_value is True or str(error_value).lower() == "true" or status == "ERROR"


def trace_start(trace):
    starts = [
        span.get("startTime")
        for span in trace.get("spans", [])
        if isinstance(span, dict) and isinstance(span.get("startTime"), (int, float))
    ]
    return min(starts) if starts else 0


document, = load_json_documents(["Jaeger トレース"])
selected_service = sys.argv[1]
traces = document.get("data", []) if isinstance(document, dict) else []
if not isinstance(traces, list):
    print("[ERROR] Jaeger トレース応答の data が配列ではありません。", file=sys.stderr)
    raise SystemExit(2)
traces = [trace for trace in traces if isinstance(trace, dict)]
traces.sort(key=trace_start, reverse=True)

print("")
print("════════════ X-Ray 代替 Jaeger トレースレポート ════════════")
print(f"検索サービス: {clean_value('service', selected_service)}")
print(f"取得トレース: {len(traces)} 件")
if not traces:
    print("  Jaeger にトレースがありません。アプリへリクエストを送り、")
    print("  app → Collector → Jaeger の順にログと接続先を確認してください。")
    print("════════════════════════════════════════════════════════════")
    raise SystemExit(0)

for trace_index, trace in enumerate(traces, 1):
    trace_id = str(trace.get("traceID") or "(unknown)")
    spans = [span for span in trace.get("spans", []) if isinstance(span, dict)]
    spans.sort(key=lambda span: span.get("startTime") or 0)
    processes = trace.get("processes") if isinstance(trace.get("processes"), dict) else {}
    services = sorted(
        {
            str(process.get("serviceName"))
            for process in processes.values()
            if isinstance(process, dict) and process.get("serviceName")
        }
    )
    starts = [
        span.get("startTime")
        for span in spans
        if isinstance(span.get("startTime"), (int, float))
    ]
    ends = [
        span.get("startTime") + span.get("duration")
        for span in spans
        if isinstance(span.get("startTime"), (int, float))
        and isinstance(span.get("duration"), (int, float))
    ]
    start = min(starts) if starts else 0
    duration = max(ends) - start if start and ends else 0
    error_count = sum(1 for span in spans if span_is_error(span))

    print("")
    print(f"[Trace {trace_index}] traceID={clean_value('traceID', trace_id, 80)}")
    print(f"  開始={micros_to_time(start)}, 所要時間={millis(duration)}, "
          f"spans={len(spans)}, errorSpans={error_count}")
    print(f"  services={', '.join(clean_value('service', name, 120) for name in services) or '(unknown)'}")

    if processes:
        print("  [リソース]")
        for process_id, process in sorted(processes.items()):
            if not isinstance(process, dict):
                continue
            service_name = clean_value("service", process.get("serviceName") or "(unknown)", 120)
            print(f"    {clean_value('processID', process_id, 80)}: service.name={service_name}")
            process_tags = tags_as_pairs(process.get("tags"))
            for key, value in process_tags[:20]:
                print(f"      {clean_value('key', key, 120)}={clean_value(key, value)}")
            if len(process_tags) > 20:
                print(f"      ... {len(process_tags) - 20} 属性を省略")

    print("  [スパン]")
    for span_index, span in enumerate(spans[:50], 1):
        process = processes.get(span.get("processID"), {})
        service_name = (
            process.get("serviceName")
            if isinstance(process, dict)
            else "(unknown)"
        )
        references = span.get("references") if isinstance(span.get("references"), list) else []
        parent_refs = []
        for reference in references:
            if not isinstance(reference, dict):
                continue
            parent_refs.append(
                f"{reference.get('refType', 'REF')}:{reference.get('spanID', '?')}"
            )
        relative_start = 0
        if start and isinstance(span.get("startTime"), (int, float)):
            relative_start = span.get("startTime") - start
        error_marker = " ERROR" if span_is_error(span) else ""
        print(
            f"    {span_index}. [{clean_value('service', service_name, 100)}] "
            f"{clean_value('operationName', span.get('operationName') or '(unknown)', 180)}"
            f"{error_marker}"
        )
        print(
            f"       spanID={clean_value('spanID', span.get('spanID') or '?', 80)}, "
            f"parent={clean_value('parent', ','.join(parent_refs) or '(root)', 180)}, "
            f"offset={millis(relative_start)}, duration={millis(span.get('duration') or 0)}"
        )
        span_tags = tags_as_pairs(span.get("tags"))
        if span_tags:
            print("       attributes:")
            for key, value in span_tags[:30]:
                print(f"         {clean_value('key', key, 140)}={clean_value(key, value)}")
            if len(span_tags) > 30:
                print(f"         ... {len(span_tags) - 30} 属性を省略")

        span_logs = span.get("logs") if isinstance(span.get("logs"), list) else []
        if span_logs:
            print("       events:")
            for event in span_logs[:10]:
                if not isinstance(event, dict):
                    continue
                print(f"         - {micros_to_time(event.get('timestamp'))}")
                fields = tags_as_pairs(event.get("fields"))
                for key, value in fields[:20]:
                    print(f"             {clean_value('key', key, 140)}={clean_value(key, value)}")
                if len(fields) > 20:
                    print(f"             ... {len(fields) - 20} フィールドを省略")
            if len(span_logs) > 10:
                print(f"         ... {len(span_logs) - 10} イベントを省略")
    if len(spans) > 50:
        print(f"    ... {len(spans) - 50} スパンを省略")

print("")
print("════════════════════════════════════════════════════════════")
PY
)"
  run_observability_python \
    "${OBSERVABILITY_PYTHON_JSON_LOADER}${program}" 1 "$traces_json" \
    "$selected_trace_service"
}

# OTel Collector (adot-collector / otel) の稼働確認。
# compose サービスに設定された healthcheck 定義を最優先で実行し、/bin/sh を持たない
# distroless イメージでも確認できるよう、次の順にフォールバックする。
#   1) compose の healthcheck 定義 (CMD はそのまま、CMD-SHELL はシェル→直接実行)
#   2) ADOT Collector 同梱の /healthcheck バイナリを直接実行 (シェル不要)
#   3) health_check 拡張のエンドポイント (13133) へ HTTP 確認
#   4) Docker が記録した State.Health を参照
# いずれも使えない場合は、利用者が手元で実行できるコマンドを案内する。
verify_otel_collector_health() {
  local service_name="$1" container_id="$2"
  local container_name health_state health_status="" status=0
  local health_mode="" health_command_text="" http_url="" host_url="" host_tool=""
  local -a health_test=()

  container_name="$(normalize_container_name \
    "$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || printf '%s' "$container_id")")"

  # Docker が記録した health 状態は、コンテナ内へ一切立ち入らずに参照できる。
  health_state="$(
    docker inspect -f \
      '{{if .State.Health}}{{.State.Health.Status}}|{{.State.Health.FailingStreak}}{{end}}' \
      "$container_id" 2>/dev/null || true
  )"
  if [ -n "$health_state" ]; then
    health_status="${health_state%%|*} (連続失敗 ${health_state#*|} 回)"
  fi

  if ! HEALTHCHECK_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
    warn "OTel Collector ヘルスチェックの保存用一時ファイルを作成できませんでした。"
    return 1
  fi
  : > "$HEALTHCHECK_DIAGNOSTIC_FILE"

  # 1) compose に設定された healthcheck 定義を使う。
  if load_container_healthcheck_test "$container_id" \
      && parse_healthcheck_test "${HEALTHCHECK_TEST_LINES[@]}"; then
    health_test=("${HEALTHCHECK_TEST_LINES[@]}")
    health_mode="$HEALTHCHECK_MODE"
    health_command_text="$HEALTHCHECK_COMMAND_TEXT"
    HEALTHCHECK_TIMEOUT_RUNNER=()
    if command -v timeout >/dev/null 2>&1; then
      HEALTHCHECK_TIMEOUT_RUNNER=(timeout "${URL_TIMEOUT}s")
    fi
    status=0
    run_healthcheck_command_with_fallback \
      "$container_id" "$health_mode" "$health_command_text" "$HEALTHCHECK_DIAGNOSTIC_FILE" \
      "${health_test[@]:1}" || status=$?
    if [ "$HEALTHCHECK_EXEC_AVAILABLE" = "true" ] && [ "$status" -eq 0 ]; then
      log "OTel Collector ヘルスチェック: OK (service=${service_name})"
      diag "確認方式: compose の healthcheck 定義を ${HEALTHCHECK_EXEC_METHOD}"
      rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
      HEALTHCHECK_DIAGNOSTIC_FILE=""
      return 0
    fi
    # 125-127 はコマンド自体を起動できなかった場合 (シェル無し・コマンド未同梱)。
    # healthcheck の失敗ではないため、次の確認方式へ進む。
    if [ "$HEALTHCHECK_EXEC_AVAILABLE" = "true" ] \
        && [ "$status" -ne 125 ] && [ "$status" -ne 126 ] && [ "$status" -ne 127 ]; then
      warn "OTel Collector の healthcheck が失敗しました (service=${service_name}, exit=${status})。"
      diag "確認方式: compose の healthcheck 定義を ${HEALTHCHECK_EXEC_METHOD}"
      print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" "(healthcheck の出力はありません)"
      rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
      HEALTHCHECK_DIAGNOSTIC_FILE=""
      return 1
    fi
    warn "compose の healthcheck をコンテナ内で実行できません (${HEALTHCHECK_EXEC_METHOD}, exit=${status})。別方式で確認します。"
    http_url="$(
      printf '%s\n' "$health_command_text" \
        | grep -Eo "https?://[^[:space:]\"'<>|;&)]+" | head -n 1 || true
    )"
  else
    warn "compose サービス '${service_name}' に healthcheck が設定されていないため、既定の方式で確認します。"
  fi

  # 2) ADOT Collector 同梱の /healthcheck バイナリ (シェル不要)。
  status=0
  : > "$HEALTHCHECK_DIAGNOSTIC_FILE"
  if docker exec "$container_id" /healthcheck >"$HEALTHCHECK_DIAGNOSTIC_FILE" 2>&1; then
    log "OTel Collector ヘルスチェック: OK (service=${service_name})"
    diag "確認方式: コンテナ同梱の /healthcheck を docker exec で直接実行"
    rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
    HEALTHCHECK_DIAGNOSTIC_FILE=""
    return 0
  fi
  rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
  HEALTHCHECK_DIAGNOSTIC_FILE=""

  # 3) health_check 拡張のエンドポイントへ HTTP 確認 (コンテナ内ツール不要)。
  [ -n "$http_url" ] || http_url="http://127.0.0.1:${OTEL_HEALTH_CHECK_PORT}/"
  if host_url="$(resolve_healthcheck_url_for_host "$container_id" "$http_url")" \
      && host_tool="$(detect_host_http_tool)"; then
    if ! HEALTHCHECK_DIAGNOSTIC_FILE="$(mktemp 2>/dev/null)"; then
      warn "OTel Collector ヘルスチェックの保存用一時ファイルを作成できませんでした。"
      return 1
    fi
    status=0
    run_healthcheck_http_probe_on_host "$host_tool" "GET" "$host_url" "$HEALTHCHECK_DIAGNOSTIC_FILE" \
      || status=$?
    if [ "$status" -eq 0 ]; then
      log "OTel Collector ヘルスチェック: OK (service=${service_name})"
      diag "確認方式: ホストから health_check エンドポイントへ HTTP 確認 (${host_url})"
      print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" "(レスポンス本文はありません)"
      rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
      HEALTHCHECK_DIAGNOSTIC_FILE=""
      return 0
    fi
    warn "health_check エンドポイントへの HTTP 確認にも失敗しました (${host_url}, exit=${status})。"
    print_healthcheck_capture "$HEALTHCHECK_DIAGNOSTIC_FILE" "(レスポンス本文・接続エラー出力はありません)"
    rm -f -- "$HEALTHCHECK_DIAGNOSTIC_FILE"
    HEALTHCHECK_DIAGNOSTIC_FILE=""
  fi

  # 4) 実行系がすべて使えない場合は、Docker の記録と手動コマンドで補う。
  if [ -n "$health_status" ]; then
    warn "OTel Collector を能動的に確認できないため、Docker が記録した health 状態のみ表示します: ${health_status} (service=${service_name})"
  else
    warn "OTel Collector のヘルスチェックを確認できませんでした (service=${service_name})。"
  fi
  print_healthcheck_manual_commands "$service_name" "$container_name" \
    "$health_mode" "$health_command_text" "$http_url" "$container_id"
  return 1
}

run_otel_jaeger_trace_helper() {
  local selected_service="$1" collector_service="" collector_id=""
  local jaeger_service="jaeger" services_json services_text selected_trace_service traces_json
  local collector_logs collector_evidence choice index _service_index
  local -a collector_ids=() trace_services=()

  require_observability_tools || return 1
  case "$selected_service" in
    otel|adot-collector)
      collector_service="$selected_service"
      ;;
    jaeger)
      collector_service="$(find_first_running_compose_service adot-collector otel || true)"
      ;;
  esac

  if [ -n "$collector_service" ]; then
    mapfile -t collector_ids < <(compose_container_ids "$collector_service")
    if [ ${#collector_ids[@]} -gt 0 ]; then
      collector_id="${collector_ids[0]}"
      verify_otel_collector_health "$collector_service" "$collector_id" || true

      if collector_logs="$(compose_logs "$collector_service" 2>/dev/null)"; then
        collector_evidence="$(
          printf '%s\n' "$collector_logs" | strip_ansi_codes \
            | grep -Ei 'TracesExporter|resource spans|[[:space:]]spans([:=]|[[:space:]])' \
            | tail -n 10 || true
        )"
        diag ""
        diag "[Collector のスパン受信根拠（最大 10 行）]"
        if [ -n "$collector_evidence" ]; then
          printf '%s\n' "$collector_evidence" >&2
        else
          warn "今回の起動以降の Collector ログにスパン受信を示す行が見つかりません。"
        fi
      fi
    fi
  else
    warn "実行中の OTel Collector サービス (adot-collector / otel) を見つけられないため、Jaeger 側だけを確認します。"
  fi

  resolve_compose_service_http_endpoint "$jaeger_service" "16686" || return 1
  diag ""
  diag "OTel Collector → X-Ray 偽装 Jaeger のトレース送達を確認します。"
  diag "Jaeger Query API: ${OBSERVABILITY_HTTP_BASE_URL}"
  diag "注意: これは Compose 内 Jaeger への送達確認であり、実 AWS X-Ray への送信確認ではありません。"
  if ! services_json="$(observability_http_get "${OBSERVABILITY_HTTP_BASE_URL}/api/services")"; then
    err "Jaeger Query API からサービス一覧を取得できませんでした。"
    return 1
  fi
  if ! services_text="$(extract_jaeger_services "$services_json")"; then
    return 1
  fi
  while IFS= read -r selected_trace_service; do
    [ -n "$selected_trace_service" ] && trace_services+=("$selected_trace_service")
  done <<< "$services_text"
  if [ ${#trace_services[@]} -eq 0 ]; then
    warn "Jaeger にトレースサービスが登録されていません。アプリへリクエストを送ってから再確認してください。"
    return 0
  fi

  diag ""
  diag "Jaeger で確認するトレースサービスを選択してください:"
  for _service_index in "${!trace_services[@]}"; do
    diag "  $(( _service_index + 1 ))) ${trace_services[$_service_index]}"
  done
  diag "  0) トレース確認を中止"
  while :; do
    printf '選択番号 [0-%s]: ' "${#trace_services[@]}" >&2
    if ! IFS= read -r choice; then
      err "Jaeger トレースサービスの選択を読み取れませんでした。"
      return 1
    fi
    case "$choice" in
      0)
        log "Jaeger トレース確認を中止しました。"
        return 0
        ;;
      ''|*[!0-9]*|0*)
        warn "0 から ${#trace_services[@]} の番号を入力してください。"
        ;;
      *)
        if [ "$choice" -ge 1 ] 2>/dev/null \
            && [ "$choice" -le ${#trace_services[@]} ] 2>/dev/null; then
          index=$(( choice - 1 ))
          selected_trace_service="${trace_services[$index]}"
          break
        fi
        warn "0 から ${#trace_services[@]} の番号を入力してください。"
        ;;
    esac
  done

  if ! traces_json="$(
    curl -sS --noproxy '*' --max-time "$URL_TIMEOUT" --get \
      --data-urlencode "service=${selected_trace_service}" \
      --data-urlencode "limit=${OBSERVABILITY_TRACE_LIMIT}" \
      --data-urlencode "lookback=1h" \
      "${OBSERVABILITY_HTTP_BASE_URL}/api/traces"
  )"; then
    err "Jaeger Query API からトレースを取得できませんでした: ${selected_trace_service}"
    return 1
  fi
  if ! render_jaeger_trace_report "$traces_json" "$selected_trace_service" >&2; then
    err "Jaeger トレースレポートを生成できませんでした。"
    return 1
  fi
  diag "トレース属性・イベントには機微情報が含まれ得るため、共有・ログ保存時の取り扱いに注意してください。"
}

# 選択済み Compose サービスについて、ログ表示、対話式 bash / MySQL 接続、
# healthcheck 診断、対応サービスのローカル可観測性診断を繰り返す。
# 0 を選択すると、起動中 Compose サービスの選択へ戻る。
compose_service_observability_helper_kind() {
  case "$1" in
    cwagent|cloudwatch-logs-mock) printf 'cloudwatch\n' ;;
    otel|adot-collector|jaeger) printf 'xray\n' ;;
    *) return 1 ;;
  esac
}

pause_compose_service_actions() {
  printf 'Enter キーでサービス操作の選択へ戻ります: ' >&2
  if ! IFS= read -r; then
    err "サービス操作の選択へ戻るための入力を読み取れませんでした。"
    return 1
  fi
}

run_interactive_compose_service_actions() {
  local service_name="$1" action helper_kind="" max_action=3
  local mysql_action=0 observability_action=0 cert_check_action=0

  helper_kind="$(compose_service_observability_helper_kind "$service_name" || true)"
  if compose_service_supports_mysql_client "$service_name"; then
    max_action=$(( max_action + 1 ))
    mysql_action="$max_action"
  fi
  if [ -n "$helper_kind" ]; then
    max_action=$(( max_action + 1 ))
    observability_action="$max_action"
  fi
  # 証明書チェックは最後に採番し、既存操作の番号を変えない。
  if compose_service_supports_cert_check "$service_name"; then
    max_action=$(( max_action + 1 ))
    cert_check_action="$max_action"
  fi
  while :; do
    diag ""
    diag "Compose サービス '${service_name}' で実行する操作を選択してください:"
    diag "  1) ログを表示"
    diag "  2) bash へ接続 (cd・任意コマンドを実行可能)"
    diag "  3) healthcheck 設定・実行履歴・通信を確認"
    if [ "$mysql_action" -gt 0 ]; then
      diag "  ${mysql_action}) MySQL クライアントへ接続 (SQL クエリを対話実行)"
    fi
    case "$helper_kind" in
      cloudwatch)
        diag "  ${observability_action}) CloudWatch Logs 偽装送達を確認 (ロググループ / ストリーム / イベント)"
        ;;
      xray)
        diag "  ${observability_action}) X-Ray 偽装 Jaeger のトレースを確認 (サービス / トレース / スパン)"
        ;;
    esac
    if [ "$cert_check_action" -gt 0 ]; then
      diag "  ${cert_check_action}) 証明書チェック (トラストストアと HTTPS 接続先を自動検出して確認)"
    fi
    diag "  0) Compose サービスの選択へ戻る"
    printf '選択番号 [0-%s]: ' "$max_action" >&2
    if ! IFS= read -r action; then
      err "Compose サービス操作の選択を読み取れませんでした。対話可能な端末から実行してください。"
      return 1
    fi
    INTERACTION_MENU_ENTERED="true"

    case "$action" in
      1)
        if ! show_interactive_compose_service_logs "$service_name"; then
          warn "ログ表示に失敗しました。サービス操作の選択へ戻ります。"
        fi
        pause_compose_service_actions || return 1
        ;;
      2)
        if ! run_interactive_compose_bash "$service_name"; then
          warn "bash 接続に失敗しました。サービス操作の選択へ戻ります。"
        fi
        ;;
      3)
        if ! run_interactive_compose_healthcheck "$service_name"; then
          warn "healthcheck 診断に失敗しました。サービス操作の選択へ戻ります。"
        fi
        pause_compose_service_actions || return 1
        ;;
      0)
        log "Compose サービス '${service_name}' の操作を終了し、サービス選択へ戻ります。"
        return 0
        ;;
      *)
        if [ "$mysql_action" -gt 0 ] && [ "$action" = "$mysql_action" ]; then
          if ! run_interactive_compose_mysql "$service_name"; then
            warn "MySQL 接続に失敗しました。サービス操作の選択へ戻ります。"
          fi
        elif [ "$observability_action" -gt 0 ] && [ "$action" = "$observability_action" ]; then
          case "$helper_kind" in
            cloudwatch)
              if ! run_cloudwatch_logs_delivery_helper "$service_name"; then
                warn "CloudWatch Logs 偽装送達の確認に失敗しました。"
              fi
              ;;
            xray)
              if ! run_otel_jaeger_trace_helper "$service_name"; then
                warn "X-Ray 偽装 Jaeger のトレース確認に失敗しました。"
              fi
              ;;
          esac
          pause_compose_service_actions || return 1
        elif [ "$cert_check_action" -gt 0 ] && [ "$action" = "$cert_check_action" ]; then
          if ! run_interactive_compose_cert_check "$service_name"; then
            warn "証明書チェックに失敗しました。サービス操作の選択へ戻ります。"
          fi
          pause_compose_service_actions || return 1
        else
          warn "0 から ${max_action} の番号を入力してください。"
        fi
        ;;
    esac
  done
}

# 起動中の Compose サービスを番号で選択し、サービス操作メニューを表示する。
# サービス操作から戻るたびに最新の一覧を再取得し、0 が選択されるまで繰り返す。
run_interactive_compose_service_menu() {
  local choice index service_name _service_index
  local -a started_services=()

  while :; do
    started_services=()
    mapfile -t started_services < <(compose_started_services)
    if [ ${#started_services[@]} -eq 0 ]; then
      err "対話操作できる起動中の Compose サービスが見つかりません。"
      return 1
    fi

    diag ""
    diag "操作する起動中の Compose サービスを選択してください:"
    for _service_index in "${!started_services[@]}"; do
      diag "  $(( _service_index + 1 ))) ${started_services[$_service_index]}"
    done
    diag "  0) 対話操作を終了"

    while :; do
      printf '選択番号 [0-%s]: ' "${#started_services[@]}" >&2
      if ! IFS= read -r choice; then
        err "Compose サービスの選択を読み取れませんでした。対話可能な端末から実行してください。"
        return 1
      fi
      INTERACTION_MENU_ENTERED="true"
      case "$choice" in
        0)
          log "Compose サービスの対話操作を終了しました。"
          return 0
          ;;
        ''|*[!0-9]*|0*)
          warn "0 から ${#started_services[@]} の番号を入力してください。"
          ;;
        *)
          if [ "$choice" -ge 1 ] 2>/dev/null \
              && [ "$choice" -le ${#started_services[@]} ] 2>/dev/null; then
            index=$(( choice - 1 ))
            break
          fi
          warn "0 から ${#started_services[@]} の番号を入力してください。"
          ;;
      esac
    done

    service_name="${started_services[$index]}"
    run_interactive_compose_service_actions "$service_name" || return 1
  done
}

run_keep_container_interaction() {
  [ -n "$KEEP_CONTAINER_MODE" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    case "$KEEP_CONTAINER_MODE" in
      bash)
        log "[DRY-RUN] 検証対象コンテナを選択し、docker exec -it <container> /bin/bash で直接接続します。"
        ;;
      http)
        log "[DRY-RUN] JBoss EAP のコンテキストルートと HTTP ポートを解決し、パス・GET/POST・POST ボディ形式の対話入力後に curl を実行します。"
        ;;
      logs)
        log "[DRY-RUN] 起動中の Compose サービスを番号で選択し、ログ表示、対話式 bash / MySQL 接続、healthcheck 設定・実行履歴・通信確認、cwagent / OTel のローカル送達診断、トラストストア構成コンテナの証明書チェックを繰り返し実行します。"
        ;;
    esac
    return 0
  fi

  case "$KEEP_CONTAINER_MODE" in
    bash)
      select_interaction_target || return 1
      diag ""
      diag "検証対象コンテナの bash へ接続します (service=${INTERACTION_SERVICE_NAME}, container=${INTERACTION_CONTAINER_NAME})。"
      diag "bash を終了してもコンテナは起動状態のまま残ります。"
      if ! docker exec -it "$INTERACTION_CONTAINER_ID" /bin/bash; then
        err "検証対象コンテナの /bin/bash へ接続できませんでした: ${INTERACTION_CONTAINER_NAME}"
        return 1
      fi
      log "コンテナの bash セッションを終了しました。コンテナは起動状態を維持します。"
      ;;
    http)
      select_interaction_target || return 1
      run_interactive_http_request || return 1
      ;;
    logs)
      run_interactive_compose_service_menu || return 1
      ;;
  esac
  return 0
}

# ---- デプロイエラー時の調査モード -------------------------------------------
# AP サーバ (JBoss EAP 等) は起動したが、アプリのデプロイでエラーとなった場合、
# コンテナを落としてしまうとコンテナ内を調査できない。そこで既定では、
# コンテナと AP サーバを起動したまま、デプロイ成功後と同じ対話操作へ入り、
# 各 Compose サービスへの bash 接続やログ確認ができる状態にする。
# --exit-on-deploy-error 指定時は、従来どおりそのまま終了する。
#
# 戻り値は常に 0 (デプロイエラー自体の失敗は呼び出し元が exit 1 で扱う)。
handle_deploy_error_investigation() {
  # 起動失敗ログによるデプロイエラー以外 (タイムアウト、コンテナの途中停止など) は
  # 調査対象としない。コンテナが残っていないか、原因がデプロイ以外のためである。
  [ "$STARTUP_DEPLOY_ERROR" = "true" ] || return 0

  if [ "$KEEP_CONTAINER_ON_DEPLOY_ERROR" != "true" ]; then
    log "デプロイエラーを検出しましたが、--exit-on-deploy-error が指定されているため、そのまま終了します。"
    return 0
  fi

  # --keep-container-mode を明示していればその操作を、無指定なら logs を使う。
  local mode="${KEEP_CONTAINER_MODE:-$DEPLOY_ERROR_INTERACTION_MODE}"

  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] デプロイエラー時はコンテナと AP サーバを起動したまま、対話操作 (${mode}) でコンテナ内を調査できる状態にします。"
    log "[DRY-RUN] そのまま終了させる場合は --exit-on-deploy-error を指定します。"
    return 0
  fi

  # コンテナが残っていなければ調査できないため、従来どおりの終了処理へ任せる。
  if ! any_container_running; then
    warn "起動中のコンテナが無いため、デプロイエラーの調査用対話操作へは入りません。"
    return 0
  fi

  # デプロイ失敗の原因そのものである Java 例外の解析を、調査へ入る前に見せる。
  # (後始末からも呼ばれるが、二重実行は関数側で防いでいる)
  analyze_war_deploy_exceptions 1

  local previous_keep_container="$KEEP_CONTAINER"
  local previous_mode="$KEEP_CONTAINER_MODE"
  # 対話操作の最中と終了後にコンテナを止めないよう、後始末より先に維持を指定する。
  # (teardown_container と capture_shutdown_logs はいずれも KEEP_CONTAINER を見る)
  KEEP_CONTAINER="true"
  KEEP_CONTAINER_MODE="$mode"

  diag ""
  diag "==================================================================="
  diag "デプロイエラーを検出しました。コンテナと AP サーバは起動したまま残します。"
  diag "コンテナ内を調査できるよう、対話操作 (${mode}) を開始します。"
  diag "調査せずそのまま終了させたい場合は --exit-on-deploy-error を指定してください。"
  diag "==================================================================="

  local interaction_status=0
  run_keep_container_interaction || interaction_status=$?
  KEEP_CONTAINER_MODE="$previous_mode"

  if [ "$interaction_status" -eq 0 ] || [ "$INTERACTION_MENU_ENTERED" = "true" ]; then
    log "デプロイエラーの調査用対話操作を終了しました。コンテナは起動状態のまま残します。"
    log "  手動で停止・削除する場合: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down"
    return 0
  fi

  # 端末から入力できず調査に入れなかった場合 (CI など) は、コンテナを残したままに
  # せず、従来どおりのエラー終了 (終了ログ取得 → compose down) へ戻す。
  KEEP_CONTAINER="$previous_keep_container"
  warn "対話操作を開始できなかったため、通常のエラー終了として後始末します。"
  warn "  調査のためコンテナを残したい場合は --keep-container を併用してください。"
  return 0
}

# Docker CLI の人間可読サイズ (例: 1.5GB / 20MiB) をバイトへ変換する。
human_size_to_bytes() {
  local value="$1" number unit multiplier
  value="${value//[[:space:]]/}"
  if [ "$value" = "0" ]; then
    printf '0\n'
    return 0
  fi
  if [[ "$value" =~ ^([0-9]+([.][0-9]+)?)(B|kB|KB|MB|GB|TB|PB|KiB|MiB|GiB|TiB|PiB)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  case "$unit" in
    B)   multiplier=1 ;;
    kB|KB) multiplier=1000 ;;
    MB)  multiplier=1000000 ;;
    GB)  multiplier=1000000000 ;;
    TB)  multiplier=1000000000000 ;;
    PB)  multiplier=1000000000000000 ;;
    KiB) multiplier=1024 ;;
    MiB) multiplier=1048576 ;;
    GiB) multiplier=1073741824 ;;
    TiB) multiplier=1099511627776 ;;
    PiB) multiplier=1125899906842624 ;;
    *) return 1 ;;
  esac
  LC_ALL=C awk -v number="$number" -v multiplier="$multiplier" \
    'BEGIN { printf "%.0f\n", number * multiplier }'
}

# docker system df の全カテゴリを合計し、Docker 管理対象の使用量を返す。
docker_storage_bytes() {
  local summary type size bytes total=0 found="false"
  if ! summary="$(LC_ALL=C docker system df --format '{{.Type}}|{{.Size}}' 2>/dev/null)"; then
    return 1
  fi
  while IFS='|' read -r type size; do
    [ -n "$type" ] || continue
    if ! bytes="$(human_size_to_bytes "$size")"; then
      return 1
    fi
    total=$(( total + bytes ))
    found="true"
  done <<< "$summary"
  [ "$found" = "true" ] || return 1
  printf '%s\n' "$total"
}

format_bytes() {
  local bytes="$1"
  LC_ALL=C awk -v bytes="$bytes" '
    BEGIN {
      split("B KiB MiB GiB TiB PiB", units, " ")
      value = bytes + 0
      unit = 1
      while (value >= 1024 && unit < 6) {
        value /= 1024
        unit++
      }
      if (unit == 1) {
        printf "%.0f %s", value, units[unit]
      } else {
        printf "%.2f %s", value, units[unit]
      }
    }'
}

docker_object_count() {
  local output
  if ! output="$("$@" 2>/dev/null)"; then
    printf '取得不可'
    return 1
  fi
  if [ -z "$output" ]; then
    printf '0'
  else
    printf '%s\n' "$output" | awk 'NF { count++ } END { print count + 0 }'
  fi
}

current_docker_endpoint() {
  if [ -n "${DOCKER_CONTEXT:-}" ]; then
    docker context inspect "$DOCKER_CONTEXT" \
      --format '{{.Endpoints.docker.Host}}' 2>/dev/null
  elif [ -n "${DOCKER_HOST:-}" ]; then
    printf '%s\n' "$DOCKER_HOST"
  else
    docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null
  fi
}

# 確認表示後に別プロセスが既定 context を切り替えても削除先が変わらないよう、
# DOCKER_HOST 未指定時は現在の context 名をこのプロセスへ固定する。
freeze_current_docker_target() {
  [ -n "${DOCKER_CONTEXT:-}" ] && return 0
  [ -n "${DOCKER_HOST:-}" ] && return 0
  local context
  if ! context="$(docker context show 2>/dev/null)" || [ -z "$context" ]; then
    return 1
  fi
  export DOCKER_CONTEXT="$context"
}

docker_endpoint_description() {
  case "$1" in
    unix://*) printf 'ローカル Unix ソケット' ;;
    npipe://*) printf 'ローカル Windows named pipe' ;;
    ssh://*) printf 'リモート SSH 接続' ;;
    tcp://*|http://*|https://*) printf 'TCP 接続 (リモートの可能性あり)' ;;
    '') printf '取得不可' ;;
    *) printf 'その他の接続方式' ;;
  esac
}

show_docker_cleanup_notice() {
  local usage_before="$1" context endpoint
  local running_count container_count image_count volume_count network_count
  context="$(docker context show 2>/dev/null || true)"
  [ -n "$context" ] || context="取得不可"
  endpoint="$(current_docker_endpoint || true)"
  running_count="$(docker_object_count docker container ls -q || true)"
  container_count="$(docker_object_count docker container ls -aq || true)"
  image_count="$(docker_object_count docker image ls -aq || true)"
  volume_count="$(docker_object_count docker volume ls -q || true)"
  network_count="$(docker_object_count docker network ls --filter type=custom -q || true)"

  diag ""
  diag "╔══════════════════════════════════════════════════════════════════╗"
  diag "║ 警告: 現在の Docker context の全ローカルデータを削除します      ║"
  diag "╚══════════════════════════════════════════════════════════════════╝"
  diag "  Docker context: $context"
  diag "  Docker 接続方式: $(docker_endpoint_description "$endpoint")"
  diag "  Docker 管理対象の使用量: $usage_before"
  diag ""
  diag "削除・停止する対象:"
  diag "  1. 実行中の全 Docker コンテナ: $running_count 件"
  diag "     Compose を含め、一時停止中は解除後、通常の docker stop で停止します。"
  diag "  2. 全コンテナ (停止済みを含む): $container_count 件"
  diag "  3. 全ローカルイメージ / タグ: $image_count 件"
  diag "  4. 全ローカルボリュームと、その中の永続データ: $volume_count 件"
  diag "  5. 未使用のユーザー定義ネットワーク: $network_count 件"
  diag "  6. 現在の Docker daemon で削除可能な全ビルドキャッシュ"
  diag ""
  diag "この操作は同じ Docker daemon を使う他プロジェクトにも影響し、元に戻せません。"
  diag "Docker daemon / Docker Desktop、標準ネットワーク、Docker context、"
  diag "レジストリ認証情報、daemon 設定は削除・停止しません。"
}

filesystem_free_bytes() {
  local path="$1" free_kib
  free_kib="$(df -Pk -- "$path" 2>/dev/null | awk 'NR == 2 { print $4; exit }')"
  case "$free_kib" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$(( free_kib * 1024 ))"
}

run_docker_cleanup_step() {
  local description="$1"
  shift
  log "$description ..."
  if "$@"; then
    return 0
  fi
  warn "失敗しました: $description"
  return 1
}

verify_docker_list_empty() {
  local description="$1" remaining count
  shift
  if ! remaining="$("$@" 2>/dev/null)"; then
    warn "クリーンアップ後の確認に失敗しました: $description"
    return 1
  fi
  [ -z "$remaining" ] && return 0
  count="$(printf '%s\n' "$remaining" | awk 'NF { count++ } END { print count + 0 }')"
  warn "クリーンアップ後も $description が $count 件残っています。"
  return 1
}

# =============================================================================
# ディスク使用量の抑制
# -----------------------------------------------------------------------------
# 検証を繰り返すと、ローカルイメージの旧世代 (dangling) とビルドキャッシュが
# 実行のたびに積み上がる。--cleanup-all-docker-data は Docker 全体を空にするため
# 日常の検証には使えないので、増えた分だけを戻す細粒度の後始末をここへ置く。
# =============================================================================

# ---- 旧世代イメージの回収 ---------------------------------------------------
# ビルド直前のローカルイメージ ID を控える。ビルド後に ID が変わっていれば、
# 直前の世代はタグを失った dangling イメージとして残っている。
remember_current_image_id() {
  PREVIOUS_IMAGE_ID=""
  [ "$RECLAIM_OLD_IMAGE" = "true" ] || return 0
  [ "$DRY_RUN" = "true" ] && return 0
  PREVIOUS_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$LOCAL_IMAGE" 2>/dev/null || true)"
}

# ビルドで世代交代した旧イメージを削除する。docker image prune と違い、
# 今回のビルドで生じた 1 件だけを対象とするため、同じ Docker daemon を使う
# 他プロジェクトの dangling イメージには影響しない。
reclaim_previous_image() {
  [ "$RECLAIM_OLD_IMAGE" = "true" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] 世代交代した旧イメージの削除は行いません (docker image rm <旧 ID>)。"
    return 0
  fi
  [ -n "$PREVIOUS_IMAGE_ID" ] || return 0

  local current tags
  current="$(docker image inspect --format '{{.Id}}' "$LOCAL_IMAGE" 2>/dev/null || true)"
  # ID が変わっていなければ (キャッシュが完全にヒットした場合など) 対象は無い。
  [ -n "$current" ] || return 0
  if [ "$current" = "$PREVIOUS_IMAGE_ID" ]; then
    log "ローカルイメージは世代交代していないため、削除するイメージはありません: ${LOCAL_IMAGE}"
    return 0
  fi

  # 旧 ID が別のタグから参照されている場合は dangling ではないため触らない。
  tags="$(docker image inspect --format '{{len .RepoTags}}' "$PREVIOUS_IMAGE_ID" 2>/dev/null || printf '0')"
  if [ -n "$tags" ] && [ "$tags" != "0" ]; then
    log "旧世代イメージは別のタグから参照されているため残します: $PREVIOUS_IMAGE_ID"
    return 0
  fi

  log "世代交代した旧イメージを削除します: $PREVIOUS_IMAGE_ID"
  if ! docker image rm "$PREVIOUS_IMAGE_ID" >/dev/null 2>&1; then
    warn "旧イメージを削除できませんでした (他から使用中の可能性があります): $PREVIOUS_IMAGE_ID"
    warn "  手動で削除する場合: docker image rm $PREVIOUS_IMAGE_ID"
  fi
}

# ---- ビルドキャッシュの削除 -------------------------------------------------
# --no-cache は「既存のキャッシュを読まない」指定であって「書かない」指定では
# ないため、指定した実行でもキャッシュは毎回増える。終了時にまとめて片付ける。
prune_build_cache() {
  [ "$PRUNE_BUILD_CACHE" = "true" ] || return 0

  local -a prune_opts=(--force)
  if [ -n "$PRUNE_BUILD_CACHE_KEEP" ]; then
    # --keep-storage は buildx の版によって非推奨・改名されている
    # (0.17 以降は --max-used-space)。使えない環境では削除せず警告に留める。
    if ! docker builder prune --help 2>&1 | grep -q -- '--keep-storage'; then
      warn "この環境の docker builder prune は --keep-storage を持たないため、ビルドキャッシュを削除しません。"
      warn "  docker builder prune --help で使用できるオプションを確認してください (--max-used-space など)。"
      return 0
    fi
    prune_opts+=(--keep-storage "$PRUNE_BUILD_CACHE_KEEP")
  else
    prune_opts+=(--all)
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] docker builder prune ${prune_opts[*]}"
    return 0
  fi

  log "ビルドキャッシュを削除します (docker builder prune ${prune_opts[*]}) ..."
  if ! docker builder prune "${prune_opts[@]}"; then
    warn "ビルドキャッシュの削除に失敗しました。手動で確認してください: docker builder prune ${prune_opts[*]}"
  fi
}

# ---- 使用量の計測 -----------------------------------------------------------
# 最初の呼び出しを基準として控え、以降は基準からの増減を併せて表示する。
# 容量を削除する処理は行わない (何が効いたのかを判断するための計測のみ)。
report_disk_usage() {
  [ "$DISK_USAGE_REPORT" = "true" ] || return 0
  local label="$1" now delta sign="+" docker_root free

  if ! now="$(docker_storage_bytes)"; then
    warn "Docker 管理対象の使用量を取得できませんでした (${label})。"
    return 0
  fi

  if [ -z "$DISK_USAGE_BEFORE" ]; then
    DISK_USAGE_BEFORE="$now"
    log "Docker 使用量 (${label}): $(format_bytes "$now") (docker system df による概算)"
  else
    delta=$(( now - DISK_USAGE_BEFORE ))
    if [ "$delta" -lt 0 ]; then
      sign="-"
      delta=$(( -delta ))
    fi
    log "Docker 使用量 (${label}): $(format_bytes "$now") (docker system df による概算)"
    log "  実行前からの増減: ${sign}$(format_bytes "$delta")"
  fi

  # data root はローカル接続 (unix socket) のときだけ特定できる。
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [ -n "$docker_root" ] && free="$(filesystem_free_bytes "$docker_root")"; then
    log "  data root の空き容量: $(format_bytes "$free") (${docker_root})"
  fi
}

# 終了時の計測。--cleanup-all-docker-data は自前で削除前後の容量を表示するため、
# そちらが動いた場合は二重に出さない。
report_disk_usage_at_exit() {
  [ "$DISK_USAGE_REPORT" = "true" ] || return 0
  [ "$DISK_USAGE_REPORTED" = "true" ] && return 0
  DISK_USAGE_REPORTED="true"
  report_disk_usage "終了時"
}

# 明示指定された場合だけ、現在の Docker context のローカルデータを全削除する。
cleanup_all_docker_data() {
  [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ] || return 0

  local before_bytes="" after_bytes="" before_display="取得不可"
  local docker_endpoint="" docker_root="" host_before="" host_after=""
  local released host_released response paused_output running_output _container_id
  local cleanup_failed=0 measurement_reported="false"
  local -a paused_ids=() running_ids=()

  if ! freeze_current_docker_target; then
    if [ "$DRY_RUN" = "true" ]; then
      warn "Docker context を固定できませんでしたが、DRY-RUN のため削除せずに表示を続けます。"
    else
      err "Docker context を固定できないため、安全のため全体クリーンアップを中止します。"
      return 1
    fi
  fi

  if before_bytes="$(docker_storage_bytes)"; then
    before_display="$(format_bytes "$before_bytes") (docker system df による概算)"
  fi
  show_docker_cleanup_notice "$before_display"

  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] 確認入力と Docker データ削除は行いません。実行予定の処理:"
    log "[DRY-RUN] docker container unpause <一時停止中の全コンテナ ID>"
    log "[DRY-RUN] docker container stop <実行中の全コンテナ ID>"
    log "[DRY-RUN] docker container prune --force"
    log "[DRY-RUN] docker builder prune --all --force"
    log "[DRY-RUN] docker image prune --all --force"
    log "[DRY-RUN] docker volume prune --all --force"
    log "[DRY-RUN] docker network prune --force"
    log "[DRY-RUN] docker system prune --all --volumes --force"
    return 0
  fi

  printf "続行するには '%s' と正確に入力してください: " \
    "$DOCKER_CLEANUP_CONFIRM_PHRASE" >&2
  if ! IFS= read -r response; then
    warn "確認入力を読み取れなかったため、追加の Docker 全体クリーンアップは実行しません。"
    return 1
  fi
  if [ "$response" != "$DOCKER_CLEANUP_CONFIRM_PHRASE" ]; then
    warn "確認フレーズが一致しないため、追加の Docker 全体クリーンアップは実行しません。"
    return 1
  fi

  log "確認フレーズを受け付けました。Docker 完全クリーンアップを開始します。"
  docker_endpoint="$(current_docker_endpoint || true)"
  if [[ "$docker_endpoint" = unix://* ]]; then
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  fi
  if [ -n "$docker_root" ]; then
    host_before="$(filesystem_free_bytes "$docker_root" || true)"
  fi

  if paused_output="$(docker container ls -q --filter status=paused)"; then
    while IFS= read -r _container_id; do
      [ -n "$_container_id" ] && paused_ids+=("$_container_id")
    done <<< "$paused_output"
    if [ ${#paused_ids[@]} -gt 0 ]; then
      run_docker_cleanup_step \
        "一時停止中のコンテナを安全に停止できる状態へ戻します (${#paused_ids[@]} 件)" \
        docker container unpause "${paused_ids[@]}" || cleanup_failed=1
    fi
  else
    warn "一時停止中コンテナの一覧を取得できませんでした。"
    cleanup_failed=1
  fi

  if running_output="$(docker container ls -q)"; then
    while IFS= read -r _container_id; do
      [ -n "$_container_id" ] && running_ids+=("$_container_id")
    done <<< "$running_output"
    if [ ${#running_ids[@]} -gt 0 ]; then
      run_docker_cleanup_step \
        "Compose を含む全実行中コンテナを通常停止します (${#running_ids[@]} 件)" \
        docker container stop "${running_ids[@]}" || cleanup_failed=1
    else
      log "実行中の Docker コンテナはありません。"
    fi
  else
    warn "実行中コンテナの一覧を取得できませんでした。"
    cleanup_failed=1
  fi

  run_docker_cleanup_step "停止済みを含む全コンテナを削除します" \
    docker container prune --force || cleanup_failed=1
  run_docker_cleanup_step "削除可能な全 Docker ビルドキャッシュを削除します" \
    docker builder prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "全ローカルイメージを削除します" \
    docker image prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "全ローカルボリュームと永続データを削除します" \
    docker volume prune --all --force || cleanup_failed=1
  run_docker_cleanup_step "未使用のユーザー定義ネットワークを削除します" \
    docker network prune --force || cleanup_failed=1
  run_docker_cleanup_step "Docker の未使用データを最終確認・削除します" \
    docker system prune --all --volumes --force || cleanup_failed=1

  verify_docker_list_empty "コンテナ" docker container ls -aq || cleanup_failed=1
  verify_docker_list_empty "ローカルイメージ" docker image ls -aq || cleanup_failed=1
  verify_docker_list_empty "ローカルボリューム" docker volume ls -q || cleanup_failed=1
  verify_docker_list_empty "ユーザー定義ネットワーク" \
    docker network ls --filter type=custom -q || cleanup_failed=1

  if after_bytes="$(docker_storage_bytes)"; then
    if [ -n "$before_bytes" ]; then
      released=$(( before_bytes - after_bytes ))
      if [ "$released" -lt 0 ]; then
        warn "Docker 使用量が処理中に増加したため、削減量を 0 bytes として表示します。"
        released=0
      fi
      log "容量削減結果 (Docker 管理対象・概算): $(format_bytes "$released")"
      log "  削除前: $(format_bytes "$before_bytes")"
      log "  削除後: $(format_bytes "$after_bytes")"
      measurement_reported="true"
    fi
    if [ "$after_bytes" -ne 0 ]; then
      warn "クリーンアップ後も Docker 管理対象データが約 $(format_bytes "$after_bytes") 残っています。"
      cleanup_failed=1
    fi
  fi

  if [ -n "$docker_root" ]; then
    host_after="$(filesystem_free_bytes "$docker_root" || true)"
  fi
  if [ -n "$host_before" ] && [ -n "$host_after" ]; then
    host_released=$(( host_after - host_before ))
    if [ "$host_released" -ge 0 ]; then
      log "ホストファイルシステムの空き容量増加: $(format_bytes "$host_released")"
      measurement_reported="true"
    else
      warn "同時実行中の別処理の影響により、ホストの空き容量は $(format_bytes "$(( -host_released ))") 減少しました。"
    fi
  fi

  if [ "$measurement_reported" != "true" ]; then
    warn "容量削減結果を測定できませんでした。各 prune コマンドの出力を確認してください。"
    cleanup_failed=1
  fi

  if [ "$cleanup_failed" -ne 0 ]; then
    err "Docker 完全クリーンアップは一部未完了です。上記の警告を確認してください。"
    return 1
  fi
  log "Docker 完全クリーンアップが完了しました。"
  return 0
}

# =============================================================================
# ビルドの停滞検知・進捗表示
# -----------------------------------------------------------------------------
# BuildKit の "exporting to image" / "exporting layers" は、ビルドしたレイヤを
# Docker のイメージストアへ書き出す段。ここでは 1 レイヤずつ順に
#   tar 化 → DiffID (sha256) の再計算 → data root への展開・登録
# を行うため、ベースイメージのようにレイヤが大きいと数分〜数十分かかる。
# ところが --progress=plain は "#N exporting layers" の 1 行を出したあと、
# 完了して "#N exporting layers 45.2s done" を出すまで何も表示しない。
# その結果、
#   - 遅いだけで正常に進んでいる (最も多い)
#   - data root の空き容量・inode が尽きて書き込みが進まない
#   - ディスク I/O が枯渇している (EBS のバーストクレジット切れ等)
#   - 同じ daemon の別操作 (image rm / prune / 別ビルド) と競合している
#   - Docker daemon 自体が固まっている
#   - 端末のフロー制御 (Ctrl+S) で画面表示だけが止まっている
# のどれであっても、画面上は「exporting layers から動かない」という同じ見え方に
# なり、待つべきか打ち切るべきかを判断できない。
#
# そこで、ビルドを監視プロセス付きで実行し、
#   (1) 一定間隔で経過時間・BuildKit のフェーズ・data root の空き容量の増減を出す
#       (空き容量が減り続けていれば「遅いだけで進行中」と判断できる)
#   (2) 出力が一定時間途切れたら停滞と判断し、上記の原因を切り分ける診断を出す
#   (3) 上限時間を超えたらビルドを中断してプロンプトを返す
# の 3 段構えで「処理状況が分からないまま戻らない」状態を解消する。
# =============================================================================

# 現在のエポック秒の取得。ビルド出力は 1 行ごとに時刻を記録するため、
# command substitution による fork を避けられる printf '%(...)T' を優先する。
if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] \
    || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
  BUILD_EPOCH_PRINTF="true"
else
  BUILD_EPOCH_PRINTF="false"
fi

# 第 1 引数で指定した変数へ現在のエポック秒を格納する。
set_epoch_now() {
  if [ "$BUILD_EPOCH_PRINTF" = "true" ]; then
    printf -v "$1" '%(%s)T' -1
  else
    printf -v "$1" '%s' "$(date '+%s')"
  fi
}

epoch_now() {
  local value=""
  set_epoch_now value
  printf '%s\n' "$value"
}

# 秒数を「1時間2分3秒」形式へ整形する (経過時間の読み違えを防ぐ)。
format_duration() {
  local total="${1:-0}" hours minutes seconds
  case "$total" in
    ''|*[!0-9]*) total=0 ;;
  esac
  hours=$(( total / 3600 ))
  minutes=$(( (total % 3600) / 60 ))
  seconds=$(( total % 60 ))
  if [ "$hours" -gt 0 ]; then
    printf '%d時間%d分%d秒' "$hours" "$minutes" "$seconds"
  elif [ "$minutes" -gt 0 ]; then
    printf '%d分%d秒' "$minutes" "$seconds"
  else
    printf '%d秒' "$seconds"
  fi
}

# 診断コマンドが停滞の巻き添えで固まらないよう、timeout があれば必ず被せる。
# timeout が無い環境ではそのまま実行する (RHEL では coreutils に含まれる)。
build_diag_run() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@"
  else
    "$@"
  fi
}

# Docker data root。exporting layers の書き出し先であり、空き容量の増減が
# 「進んでいるか」の最も確実な判断材料になる。リモート daemon (tcp:// / ssh://)
# ではホスト側の df を見ても意味がないため、ローカル接続のときだけ特定する。
build_watchdog_data_root() {
  local endpoint
  if [ "$BUILD_WATCHDOG_DATA_ROOT_RESOLVED" != "true" ]; then
    BUILD_WATCHDOG_DATA_ROOT_RESOLVED="true"
    endpoint="$(current_docker_endpoint 2>/dev/null || true)"
    case "$endpoint" in
      unix://*|npipe://*|'')
        BUILD_WATCHDOG_DATA_ROOT="$(build_diag_run 10 docker info \
          --format '{{.DockerRootDir}}' 2>/dev/null || true)"
        ;;
      *)
        BUILD_WATCHDOG_DATA_ROOT=""
        ;;
    esac
  fi
  [ -n "$BUILD_WATCHDOG_DATA_ROOT" ] || return 1
  printf '%s' "$BUILD_WATCHDOG_DATA_ROOT"
}

# df 自体が固まっても監視ループが止まらないよう、timeout 付きで空き容量を取得する。
build_watchdog_free_bytes() {
  local path="$1" free_kib
  free_kib="$(build_diag_run 10 df -Pk -- "$path" 2>/dev/null \
    | awk 'NR == 2 { print $4; exit }')"
  case "$free_kib" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$(( free_kib * 1024 ))"
}

# 監視用ファイルから数値を読む。書き込みと重なって空・不正だった場合は
# 既定値を返し、監視ループが誤検知しないようにする。
build_watchdog_read_number() {
  local file="$1" fallback="$2" value=""
  if [ -f "$file" ]; then
    IFS= read -r value < "$file" 2>/dev/null || value=""
  fi
  case "${value:-}" in
    ''|*[!0-9]*) printf '%s' "$fallback" ;;
    *) printf '%s' "$value" ;;
  esac
}

# BuildKit (--progress=plain) の出力 1 行から、いま実行中のフェーズを判定して
# BUILD_PHASE_LABEL へ格納する。判定できなければ 1 を返す (フェーズ変化なし)。
#   例) "#12 exporting to image" / "#12 exporting layers"
#       "#12 writing image sha256:..." / "#12 naming to docker.io/library/j1/base.local"
BUILD_PHASE_LABEL=""
BUILD_PHASE_SINCE=""
build_phase_from_line() {
  BUILD_PHASE_LABEL=""
  case "$1" in
    *"exporting layers"*)
      BUILD_PHASE_LABEL='exporting layers (レイヤをイメージストアへ書き出し中)' ;;
    *"exporting manifest"*|*"exporting config"*|*"exporting attestation"*)
      BUILD_PHASE_LABEL='exporting manifest/config (メタデータの書き出し)' ;;
    *"writing image"*)
      BUILD_PHASE_LABEL='writing image (イメージ ID の確定)' ;;
    *"naming to"*)
      BUILD_PHASE_LABEL='naming to (ローカルイメージ名の付与)' ;;
    *"importing to docker"*|*"sending tarball"*|*"unpacking to docker"*)
      BUILD_PHASE_LABEL='importing to docker (docker イメージストアへの取り込み)' ;;
    *"exporting to image"*|*"exporting to docker image format"*|*"exporting to oci image format"*)
      BUILD_PHASE_LABEL='exporting to image (イメージ書き出しの開始)' ;;
    *"pushing layers"*|*"pushing manifest"*)
      BUILD_PHASE_LABEL='pushing (レジストリへの送信)' ;;
    *"transferring context"*|*"transferring dockerfile"*)
      BUILD_PHASE_LABEL='transferring context (ビルドコンテキストの転送)' ;;
    *)
      return 1 ;;
  esac
  return 0
}

# フェーズ記録ファイル (1 行目: フェーズ名 / 2 行目: 開始エポック秒) を読む。
build_watchdog_load_phase() {
  local state="$1" label="" since=""
  if [ -f "${state}/phase" ]; then
    { IFS= read -r label; IFS= read -r since; } < "${state}/phase" 2>/dev/null || true
  fi
  BUILD_PHASE_LABEL="${label:-}"
  case "${since:-}" in
    ''|*[!0-9]*) BUILD_PHASE_SINCE="" ;;
    *) BUILD_PHASE_SINCE="$since" ;;
  esac
}

# ビルド出力の読み手。受け取った行はそのまま流しつつ、「最後に出力があった時刻」と
# 「現在の BuildKit フェーズ」を監視プロセスへ渡すためファイルへ記録する。
# 大量出力でも負荷を増やさないよう、行ごとの処理は fork しない書き方に揃える。
#
# read には必ず時間制限を付ける。ビルド本体を停止させても、その子プロセスが
# 出力パイプの書き込み側を掴んだままだと read は EOF を受け取れず、
# 「中断したのにプロンプトが戻らない」という当初の症状に逆戻りしてしまう。
# 時間制限で定期的に目を覚まし、中断指示 (abort) が出ていれば読むのをやめる。
build_watchdog_reader() {
  local state="$1" chunk="" pending="" now="" last_stamp="" current_phase="" status
  while :; do
    if IFS= read -r -t "$BUILD_WATCHDOG_READ_TIMEOUT" chunk; then
      : # 1 行読めた (下で処理する)
    else
      status=$?
      if [ "$status" -gt 128 ]; then
        # 時間切れ。read は途中まで読んだ内容を chunk へ残すため、次に読める分と
        # つなげられるよう溜めておく (行の取りこぼしを防ぐ)。
        pending="${pending}${chunk}"
        [ -e "${state}/abort" ] && break
        continue
      fi
      # EOF。読み残しがあれば最後に 1 行として出す。
      if [ -n "${pending}${chunk}" ]; then
        printf '%s\n' "${pending}${chunk}"
      fi
      break
    fi

    chunk="${pending}${chunk}"
    pending=""
    printf '%s\n' "$chunk"
    set_epoch_now now
    if [ "$now" != "$last_stamp" ]; then
      printf '%s\n' "$now" > "${state}/last_output"
      last_stamp="$now"
    fi
    if build_phase_from_line "$chunk" && [ "$BUILD_PHASE_LABEL" != "$current_phase" ]; then
      current_phase="$BUILD_PHASE_LABEL"
      # 監視プロセスが書きかけの状態を読まないよう、別名で書いてから差し替える。
      if printf '%s\n%s\n' "$current_phase" "$now" > "${state}/phase.tmp" 2>/dev/null; then
        mv -f "${state}/phase.tmp" "${state}/phase" 2>/dev/null || true
      fi
    fi
    chunk=""
  done
}

# 上限時間を超えたビルドを終了させる。docker CLI を落とすと BuildKit 側の
# セッションも切れるため、daemon 側で走っているビルドもキャンセルされる。
build_watchdog_terminate() {
  local state="$1" pid waited=0
  pid="$(build_watchdog_read_number "${state}/build.pid" "")"
  if [ -z "$pid" ]; then
    warn "ビルドプロセスの PID を特定できないため中断できませんでした。手動で停止してください。"
    return 1
  fi
  log "ビルドプロセスへ SIGTERM を送ります (pid=${pid})。"
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$waited" -lt "$BUILD_TIMEOUT_KILL_GRACE" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
    waited=$(( waited + 1 ))
  done
  warn "SIGTERM で終了しなかったため SIGKILL を送ります (pid=${pid})。"
  kill -KILL "$pid" 2>/dev/null || true
  return 0
}

# 「exporting layers から進まない」ときに、遅いだけなのか本当に停止しているのかを
# 切り分けるための情報をまとめて出す。停滞中でも必ず戻るよう、外部コマンドには
# すべて timeout を被せる。
diagnose_build_stall() {
  local reason="$1" phase="$2" silence="$3" elapsed="$4" data_root="$5"
  local server_version free inode_usage df_output df_line

  diag ""
  diag "────────────────────────────────────────────────────────────────────"
  diag " ビルド停滞の診断 (${reason})"
  diag "────────────────────────────────────────────────────────────────────"
  diag "  経過時間             : $(format_duration "$elapsed")"
  diag "  直近の出力からの経過 : $(format_duration "$silence")"
  diag "  BuildKit のフェーズ  : ${phase:-(未検出)}"

  # (1) Docker daemon がそもそも応答するか。ここで返らない場合は exporting だけの
  #     問題ではなく、daemon 全体が固まっている。
  if server_version="$(build_diag_run 10 docker version \
      --format '{{.Server.Version}}' 2>/dev/null)" && [ -n "$server_version" ]; then
    diag "  Docker daemon        : 応答あり (Server ${server_version})"
  else
    diag "  Docker daemon        : 10 秒以内に応答しません (daemon 側で停止している可能性)"
  fi

  # (2) 書き出し先の残量。exporting layers は展開後のレイヤ全体分を書き込むため、
  #     ここが尽きると進まなくなる。inode 枯渇でも同じ症状になる。
  if [ -n "$data_root" ]; then
    diag "  Docker data root     : ${data_root}"
    if free="$(build_watchdog_free_bytes "$data_root")"; then
      diag "    空き容量           : $(format_bytes "$free")"
    else
      diag "    空き容量           : 取得できませんでした"
    fi
    inode_usage="$(build_diag_run 10 df -Pi -- "$data_root" 2>/dev/null \
      | awk 'NR == 2 { printf "使用 %s / 空き %s", $5, $4; exit }')"
    [ -n "$inode_usage" ] && diag "    inode              : ${inode_usage}"
  else
    diag "  Docker data root     : 特定できません (リモート daemon か docker info 失敗)"
  fi

  # (3) daemon 側の応答性。docker system df が返らない場合、daemon がイメージ
  #     ストアのロックを掴んだまま動けなくなっている疑いが強い。
  if df_output="$(build_diag_run 15 docker system df 2>/dev/null)" && [ -n "$df_output" ]; then
    diag "  docker system df     :"
    while IFS= read -r df_line; do
      [ -n "$df_line" ] && diag "    ${df_line}"
    done <<< "$df_output"
  else
    diag "  docker system df     : 15 秒以内に応答しません (daemon が busy の可能性)"
  fi

  diag ""
  diag "  exporting layers から進まないときの主な原因と確認方法:"
  diag "   1. 遅いだけで進んでいる (最も多い)"
  diag "      レイヤの tar 化と DiffID の再計算は 1 レイヤずつ直列に行われ、"
  diag "      --progress=plain では完了するまで追加の出力が出ない。"
  diag "      → 上の進捗表示で data root の空き容量が減り続けていれば進行中。"
  diag "        そのまま待つ (打ち切るなら --build-timeout SEC を指定して再実行)。"
  diag "   2. data root の空き容量・inode の不足"
  diag "      → 上の空き容量が数 GiB を切っていないか確認する。"
  diag "        docker builder prune --all --force / docker image prune --all --force"
  diag "        で空けてから再実行する (このスクリプトでは --prune-build-cache)。"
  diag "   3. ディスク I/O の枯渇 (EBS のバーストクレジット切れ、ネットワークストレージ)"
  diag "      → iostat -x 1 の %util と await、CloudWatch の BurstBalance を確認する。"
  diag "   4. 同じ Docker daemon の別操作との競合"
  diag "      → docker image rm / docker system prune / 別のビルドが同時に走って"
  diag "        いないか確認する。イメージストアのロックを取り合うと双方止まる。"
  diag "   5. Docker daemon 自体の停止"
  diag "      → 上の daemon 応答が「応答なし」なら journalctl -u docker -n 200 を確認する。"
  diag "        kill -USR1 <dockerd の pid> でゴルーチンのスタックダンプを採取できる。"
  diag "   6. 端末のフロー制御 (Ctrl+S) で画面表示だけが止まっている"
  diag "      → Ctrl+Q を押すと再開する。プロセスは動き続けている。"
  diag "   7. ウイルス対策 / EDR による data root のリアルタイムスキャン"
  diag "      → data root をスキャン対象から除外する。"
  diag ""
  diag "  別端末から確認する場合:"
  diag "    docker system df -v"
  [ -n "$data_root" ] && diag "    df -h ${data_root} ; df -i ${data_root}"
  diag "    ps -eo pid,stat,etime,args | grep -E 'dockerd|buildkitd|compose'"
  diag "────────────────────────────────────────────────────────────────────"
  diag ""
}

# 監視プロセス本体。ビルドとは別プロセスで動き、進捗表示・停滞検知・上限時間での
# 中断を行う。親シェルとは ${state} 配下のファイルだけでやり取りする。
build_watchdog_monitor() {
  local state="$1" desc="$2"
  local started now elapsed silence last_beat last_output slept tick _candidate
  local phase="" phase_since="" phase_elapsed detail
  local free_now free_prev="" data_root=""
  local stall_reported="false" max_silence=0 max_silence_phase=""

  # 点検間隔は判定の時間分解能そのものになるため、指定値がこれより短い場合は
  # そちらに合わせる (--build-progress-interval 2 なら 2 秒ごとに点検する)。
  tick="$BUILD_WATCHDOG_TICK"
  for _candidate in "$BUILD_PROGRESS_INTERVAL" "$BUILD_STALL_TIMEOUT" "$BUILD_TIMEOUT"; do
    [ "$_candidate" -gt 0 ] && [ "$_candidate" -lt "$tick" ] && tick="$_candidate"
  done
  [ "$tick" -lt 1 ] && tick=1

  set_epoch_now started
  last_beat="$started"
  data_root="$(build_watchdog_data_root 2>/dev/null || true)"

  while [ -e "${state}/running" ]; do
    # ビルド完了後すぐ抜けられるよう、点検間隔は 1 秒ずつ刻んで待つ。
    slept=0
    while [ "$slept" -lt "$tick" ] && [ -e "${state}/running" ]; do
      sleep 1
      slept=$(( slept + 1 ))
    done
    [ -e "${state}/running" ] || break

    set_epoch_now now
    elapsed=$(( now - started ))
    [ "$elapsed" -lt 0 ] && elapsed=0
    last_output="$(build_watchdog_read_number "${state}/last_output" "$started")"
    silence=$(( now - last_output ))
    [ "$silence" -lt 0 ] && silence=0
    build_watchdog_load_phase "$state"
    phase="$BUILD_PHASE_LABEL"
    phase_since="$BUILD_PHASE_SINCE"

    if [ "$silence" -gt "$max_silence" ]; then
      max_silence="$silence"
      max_silence_phase="$phase"
    fi

    # (1) 定期の進捗表示。ビルドが「生きているか」を空き容量の増減で示す。
    if [ "$BUILD_PROGRESS_INTERVAL" -gt 0 ] \
        && [ $(( now - last_beat )) -ge "$BUILD_PROGRESS_INTERVAL" ]; then
      last_beat="$now"
      detail="経過 $(format_duration "$elapsed") / 直近の出力から $(format_duration "$silence")"
      if [ -n "$phase" ]; then
        if [ -n "$phase_since" ]; then
          phase_elapsed=$(( now - phase_since ))
          [ "$phase_elapsed" -lt 0 ] && phase_elapsed=0
          detail="${detail} / フェーズ: ${phase} 継続 $(format_duration "$phase_elapsed")"
        else
          detail="${detail} / フェーズ: ${phase}"
        fi
      fi
      log "ビルド継続中 (${desc}): ${detail}"
      if [ -n "$data_root" ] && free_now="$(build_watchdog_free_bytes "$data_root")"; then
        if [ -z "$free_prev" ]; then
          log "  data root の空き容量: $(format_bytes "$free_now") (${data_root})"
        elif [ "$free_now" -lt "$free_prev" ]; then
          log "  data root の空き容量: $(format_bytes "$free_now") (前回から $(format_bytes "$(( free_prev - free_now ))") 減少 → 書き出しは進んでいます) ${data_root}"
        elif [ "$free_now" -gt "$free_prev" ]; then
          log "  data root の空き容量: $(format_bytes "$free_now") (前回から $(format_bytes "$(( free_now - free_prev ))") 増加) ${data_root}"
        else
          log "  data root の空き容量: $(format_bytes "$free_now") (前回から変化なし) ${data_root}"
        fi
        free_prev="$free_now"
      fi
    fi

    # (2) 停滞検知。出力が途切れている間に 1 度だけ診断を出し、出力が再開したら
    #     次の途切れで再び検知できるよう戻す。処理自体は中断しない。
    if [ "$BUILD_STALL_TIMEOUT" -gt 0 ]; then
      if [ "$silence" -ge "$BUILD_STALL_TIMEOUT" ]; then
        if [ "$stall_reported" != "true" ]; then
          stall_reported="true"
          warn "ビルド出力が $(format_duration "$silence") 途切れています (${desc})。停滞の可能性があるため診断します。"
          diagnose_build_stall "停滞検知" "$phase" "$silence" "$elapsed" "$data_root"
        fi
      else
        stall_reported="false"
      fi
    fi

    # (3) 上限時間での中断。プロンプトが戻らない状態を確実に打ち切る。
    if [ "$BUILD_TIMEOUT" -gt 0 ] && [ "$elapsed" -ge "$BUILD_TIMEOUT" ]; then
      err "ビルドが上限時間 ${BUILD_TIMEOUT} 秒を超えました (${desc}, 経過 $(format_duration "$elapsed"))。中断します。"
      diagnose_build_stall "上限時間超過" "$phase" "$silence" "$elapsed" "$data_root"
      printf 'timeout\n' > "${state}/outcome"
      build_watchdog_terminate "$state"
      # 中断処理が終わったことを読み手へ伝える。ビルドの子プロセスが出力パイプを
      # 掴んだままでも、読み手はここで読むのをやめてパイプラインが完了する。
      : > "${state}/abort"
      break
    fi
  done

  printf '%s\n%s\n' "$max_silence" "$max_silence_phase" > "${state}/max_silence" 2>/dev/null || true
}

# 監視を行うかどうか。0 を指定した項目は個別に無効化される。
build_watchdog_enabled() {
  [ "$BUILD_WATCHDOG" = "true" ] || return 1
  [ "$DRY_RUN" = "true" ] && return 1
  [ "$BUILD_PROGRESS_INTERVAL" -gt 0 ] && return 0
  [ "$BUILD_STALL_TIMEOUT" -gt 0 ] && return 0
  [ "$BUILD_TIMEOUT" -gt 0 ] && return 0
  return 1
}

# 監視設定を 1 行で表す (画面表示・全量レポート共通)。
build_watchdog_setting_label() {
  local timeout_label="なし (無制限)"
  [ "$BUILD_TIMEOUT" -gt 0 ] && timeout_label="${BUILD_TIMEOUT} 秒"
  printf '進捗表示 %s / 停滞判定 %s / 上限 %s' \
    "$([ "$BUILD_PROGRESS_INTERVAL" -gt 0 ] && printf '%s 秒間隔' "$BUILD_PROGRESS_INTERVAL" || printf 'なし')" \
    "$([ "$BUILD_STALL_TIMEOUT" -gt 0 ] && printf '%s 秒' "$BUILD_STALL_TIMEOUT" || printf 'なし')" \
    "$timeout_label"
}

# ビルド開始前に書き出し先の空き容量を確認する。exporting layers は展開後の
# レイヤ全体分を data root へ書き込むため、ここが少ないまま始めると
# 書き出しの途中で停滞・失敗する。最も多い原因を事前に潰すための確認。
check_build_disk_space() {
  [ "$DRY_RUN" = "true" ] && return 0
  local data_root free threshold
  data_root="$(build_watchdog_data_root 2>/dev/null || true)"
  [ -n "$data_root" ] || return 0
  free="$(build_watchdog_free_bytes "$data_root")" || return 0
  threshold=$(( BUILD_MIN_FREE_GIB * 1024 * 1024 * 1024 ))
  log "ビルド開始前の data root 空き容量: $(format_bytes "$free") (${data_root})"
  if [ "$free" -lt "$threshold" ]; then
    warn "data root の空き容量が ${BUILD_MIN_FREE_GIB} GiB を下回っています: $(format_bytes "$free")"
    warn "  BuildKit の exporting layers は展開後のレイヤ全体分をここへ書き込むため、"
    warn "  書き出しの途中で停滞または失敗する可能性があります。"
    warn "  空ける場合: docker builder prune --all --force / docker image prune --all --force"
  fi
  return 0
}

# 監視付きでビルドコマンドを実行する。
# DRY-RUN 時と監視無効時は run と同じ動作 (コマンドをそのまま実行する)。
run_build_with_watchdog() {
  local desc="$1"
  shift
  local state status=0 monitor_pid outcome="" max_silence="" max_silence_phase=""

  if [ "$DRY_RUN" = "true" ]; then
    printf '[%s] [DRY-RUN] %s\n' "$(now_display_time)" "$*"
    return 0
  fi
  if ! build_watchdog_enabled; then
    "$@"
    return $?
  fi
  if ! state="$(mktemp -d "${TMPDIR:-/tmp}/build-watchdog.XXXXXX" 2>/dev/null)" \
      || [ -z "$state" ]; then
    warn "ビルド監視用の一時ディレクトリを作成できないため、監視なしでビルドします。"
    "$@"
    return $?
  fi
  BUILD_WATCHDOG_DIR="$state"
  : > "${state}/running"
  epoch_now > "${state}/last_output"

  log "ビルドを監視します ($(build_watchdog_setting_label))。"
  build_watchdog_monitor "$state" "$desc" &
  monitor_pid=$!

  # $BASHPID を控えてから exec することで、パイプ左辺のプロセス = ビルド本体の
  # PID となる。上限時間を超えたとき、監視プロセスはこの PID を止める。
  {
    printf '%s\n' "$BASHPID" > "${state}/build.pid"
    exec "$@"
  } 2>&1 | build_watchdog_reader "$state"
  status="${PIPESTATUS[0]}"

  rm -f "${state}/running"
  wait "$monitor_pid" 2>/dev/null || true

  if [ -f "${state}/outcome" ]; then
    IFS= read -r outcome < "${state}/outcome" 2>/dev/null || outcome=""
  fi
  if [ -f "${state}/max_silence" ]; then
    { IFS= read -r max_silence; IFS= read -r max_silence_phase; } \
      < "${state}/max_silence" 2>/dev/null || true
  fi

  BUILD_WATCHDOG_SUMMARY="$(build_watchdog_setting_label)"
  case "${max_silence:-}" in
    ''|*[!0-9]*) ;;
    *)
      BUILD_WATCHDOG_SUMMARY="${BUILD_WATCHDOG_SUMMARY} / 最長の無出力 $(format_duration "$max_silence")"
      [ -n "${max_silence_phase:-}" ] \
        && BUILD_WATCHDOG_SUMMARY="${BUILD_WATCHDOG_SUMMARY} (フェーズ: ${max_silence_phase})"
      ;;
  esac

  if [ "${outcome:-}" = "timeout" ]; then
    BUILD_TIMED_OUT="true"
    BUILD_WATCHDOG_SUMMARY="${BUILD_WATCHDOG_SUMMARY} / 上限時間超過により中断"
    err "ビルドを上限時間 (${BUILD_TIMEOUT} 秒) で中断しました: ${desc}"
    err "  BuildKit のフェーズと診断結果は上の「ビルド停滞の診断」を確認してください。"
    [ "$status" -eq 0 ] && status=1
  fi

  case "$state" in
    */build-watchdog.*) rm -rf -- "$state" ;;
  esac
  BUILD_WATCHDOG_DIR=""
  return "$status"
}

# ---- 全量ビルドレポート ------------------------------------------------------
# 失敗時の一次調査をレポート 1 枚で完結させるため、Compose サービスごとのログ全文を
# 追記する。起動確認対象だけでなく adot collector などのサイドカーも含む全サービスを
# 対象とし、どこからどこまでが 1 サービスのログかを見出しと罫線で区切る。
# 画面表示用の行数上限 (--startup-log-lines) や抑制指定は適用しない。
# =============================================================================
# WAR デプロイ時 Java 例外解析
# -----------------------------------------------------------------------------
# JBoss EAP のデプロイ処理で投げられた Java 例外を、ログから機械的に切り出して
# 分析する。ログの読み手が持っていた前提知識 (例外クラスごとの意味、Caused by の
# たどり方、EAP のメッセージコードとの対応) をスクリプト側へ持たせ、
#   - どの例外が根本原因か (Caused by の最終段)
#   - なぜその例外になるのか (JVM / EAP の内部動作)
#   - 何を確認し、どう直すのか (具体的なコマンドと設定例)
# を出力する。解析ロジックとレポート生成は、複数行のスタックトレースを扱うため
# Python 3 のヘルパーへ委譲する。Excel ブックも同ヘルパーが標準ライブラリだけで
# 生成するため、openpyxl などの追加パッケージは不要。
# =============================================================================

# 解析ヘルパー本体。プログラムは標準入力から渡すため、コマンドライン長の制限
# (Windows の Git Bash など) を受けない。
read -r -d '' DEPLOY_EXCEPTION_ANALYZER_PY <<'DEPLOY_EXCEPTION_ANALYZER_PY_EOF' || true
import argparse
import datetime
import math
import os
import re
import sys
import zipfile

try:
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")
except Exception:
    pass

RULE = "-" * 67
HEAVY = "=" * 67
SERVICE_MARKER = "\x1f"

# =============================================================================
# ログ解析
# =============================================================================

# compose logs の行頭に付くコンテナ名。"app-1  | 09:18:00,000 INFO ..." の形。
CONTAINER_PREFIX_RE = re.compile(r"^(?P<container>[A-Za-z0-9][A-Za-z0-9_.-]*)\s+\|\s?(?P<body>.*)$")

# JBoss EAP / WildFly のログ行。日付は付く構成と付かない構成の双方がある。
LOG_LINE_RE = re.compile(
    r"^(?:(?P<date>\d{4}-\d{2}-\d{2})[ T])?"
    r"(?P<time>\d{2}:\d{2}:\d{2}[,.]\d{3})\s+"
    r"(?P<level>[A-Z]+)\s+"
    r"\[(?P<logger>[^\]]+)\]\s*"
    r"(?:\((?P<thread>[^)]*)\)\s*)?"
    r"(?P<message>.*)$"
)

# WFLYSRV0025 / WFLYCTL0080 のような EAP のメッセージコード。
MESSAGE_CODE_RE = re.compile(r"^(?P<code>[A-Z]{2,10}\d{3,6}):\s*(?P<rest>.*)$")

# スタックフレーム。"at java.base/java.lang.Class.forName(Class.java:398)" や
# 末尾の "~[jar:...]" が付く形にも合わせる。
FRAME_RE = re.compile(r"^\s*at\s+\S.*\(.*\)\s*(?:~?\[[^\]]*\])?\s*$")
MORE_RE = re.compile(r"^\s*\.\.\.\s+\d+\s+more\s*$")
CAUSED_BY_RE = re.compile(r"^\s*Caused by:\s*(?P<rest>.*)$")
SUPPRESSED_RE = re.compile(r"^\s*Suppressed:\s*(?P<rest>.*)$")

# 例外クラスとみなす完全修飾クラス名。内部クラス (Foo$Bar) も拾う。
THROWABLE_TOKEN_RE = re.compile(
    r"(?<![\w$.])((?:[a-zA-Z_$][\w$]*\.){1,}[A-Z][\w$]*"
    r"(?:Exception|Error|Throwable|Fault|Failure|Violation))(?![\w$])"
)
# 完全修飾でない例外クラス (先頭行が "NullPointerException: ..." の形)。
BARE_THROWABLE_RE = re.compile(r"(?<![\w$.])([A-Z][\w$]*(?:Exception|Error|Throwable))(?![\w$])")

# フレームからアプリケーション由来かを判定するための、基盤側パッケージ接頭辞。
PLATFORM_PACKAGE_PREFIXES = (
    "java.", "javax.", "jakarta.", "jdk.", "sun.", "com.sun.", "org.w3c.", "org.xml.",
    "org.jboss.", "org.wildfly.", "io.undertow.", "org.hibernate.", "org.infinispan.",
    "org.apache.", "io.smallrye.", "org.eclipse.", "com.oracle.", "org.glassfish.",
    "org.slf4j.", "ch.qos.", "org.jgroups.", "io.netty.", "org.picketlink.",
    "com.arjuna.", "org.omg.", "javassist.", "net.bytebuddy.", "org.objectweb.",
)

DEPLOY_START_RE = re.compile(r"WFLYSRV0027:\s*Starting deployment of\s*\"(?P<name>[^\"]+)\"")
DEPLOY_ROLLBACK_RE = re.compile(r"WFLYSRV0021:\s*Deploy of deployment\s*\"(?P<name>[^\"]+)\"")
DEPLOY_UNIT_RE = re.compile(r"jboss\.deployment\.(?:unit|subunit)\.\\?\"?(?P<name>[A-Za-z0-9_.\-]+\.(?:war|ear|jar|rar))")
ARCHIVE_NAME_RE = re.compile(r"\"(?P<name>[A-Za-z0-9_.\-]+\.(?:war|ear|jar|rar))\"")

BOOT_COMPLETE_RE = re.compile(r"WFLYSRV002[56]:")
DEPLOY_FAILURE_CODES = ("WFLYSRV0021", "WFLYCTL0080", "WFLYSRV0026", "WFLYSRV0153",
                        "WFLYCTL0412", "WFLYSRV0056", "WFLYDS0011")

# デプロイ処理に関係すると判断するログ本文・ロガーの手掛かり。
DEPLOY_CONTEXT_TOKENS = (
    "jboss.deployment.unit", "jboss.deployment.subunit", "undertow-deployment",
    "Starting deployment of", "Deploy of deployment", "Failed services",
    "DeploymentUnitProcessingException", "org.jboss.as.server.deployment",
    "WeldStartService", "persistenceunit", "PersistenceUnitService",
    "Failed to start service", "MSC service thread", "ServerService Thread Pool",
)


class LogLine(object):
    __slots__ = ("index", "service", "container", "raw", "body", "date", "time",
                 "level", "logger", "thread", "message", "code", "message_rest")

    def __init__(self, index, service, container, raw, body):
        self.index = index
        self.service = service
        self.container = container
        self.raw = raw
        self.body = body
        self.date = ""
        self.time = ""
        self.level = ""
        self.logger = ""
        self.thread = ""
        self.message = body
        self.code = ""
        self.message_rest = body

    def timestamp(self):
        if self.date and self.time:
            return "%s %s" % (self.date, self.time)
        return self.time


def read_log_lines(path):
    """サービス区切り (US + サービス名) 付きのログファイルを LogLine の列へ変換する。"""
    lines = []
    service = "(unknown)"
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            raw = raw.rstrip("\r\n")
            if raw.startswith(SERVICE_MARKER):
                service = raw[len(SERVICE_MARKER):].strip() or "(unknown)"
                continue
            body = raw
            container = ""
            matched = CONTAINER_PREFIX_RE.match(raw)
            if matched:
                container = matched.group("container")
                body = matched.group("body")
            line = LogLine(len(lines), service, container, raw, body)
            parsed = LOG_LINE_RE.match(body)
            if parsed:
                line.date = parsed.group("date") or ""
                line.time = (parsed.group("time") or "").replace(".", ",")
                line.level = parsed.group("level") or ""
                line.logger = parsed.group("logger") or ""
                line.thread = parsed.group("thread") or ""
                line.message = parsed.group("message") or ""
            coded = MESSAGE_CODE_RE.match(line.message)
            if coded:
                line.code = coded.group("code")
                line.message_rest = coded.group("rest")
            else:
                line.message_rest = line.message
            lines.append(line)
    return lines


def is_frame(line):
    return bool(FRAME_RE.match(line.body)) and not LOG_LINE_RE.match(line.body)


def is_more(line):
    return bool(MORE_RE.match(line.body))


def split_class_and_message(text):
    """"<例外クラス>: <メッセージ>" 形式の文字列を分解する。

    JBoss のログは "WFLYCTL0080: ... : java.lang.ClassNotFoundException: com.foo.Bar"
    のように前置きが付くため、最後に現れた例外クラスを起点にする。
    """
    text = (text or "").strip()
    if not text:
        return "", ""
    found = list(THROWABLE_TOKEN_RE.finditer(text))
    if not found:
        found = list(BARE_THROWABLE_RE.finditer(text))
    if not found:
        return "", text
    last = found[-1]
    klass = last.group(1)
    rest = text[last.end():]
    if rest.startswith(":"):
        rest = rest[1:]
    return klass, rest.strip()


class ChainElement(object):
    def __init__(self, kind, klass, message, header_text):
        self.kind = kind          # "top" / "caused-by" / "suppressed"
        self.klass = klass
        self.message = message
        self.header_text = header_text
        self.frames = []
        self.more = 0

    def simple_name(self):
        return self.klass.rsplit(".", 1)[-1] if self.klass else "(不明)"


class ExceptionEvent(object):
    def __init__(self, header_line):
        self.header_line = header_line
        # 例外がログ本文とは別行 ("...\njava.lang.X: msg" の形) に出る場合、
        # 発生時刻やロガーは直前のログ行が持っている。表示用にそれを引き継ぐ。
        self.origin_line = header_line
        self.chain = []
        self.block_lines = []
        self.deployment = ""
        self.deploy_related = False
        self.deploy_reasons = []
        self.verdict = ""
        self.knowledge = None
        self.facts = []
        self.related_codes = []

    def top(self):
        return self.chain[0] if self.chain else None

    def root(self):
        for element in reversed(self.chain):
            if element.kind != "suppressed":
                return element
        return self.chain[-1] if self.chain else None

    def all_frames(self):
        frames = []
        for element in self.chain:
            frames.extend(element.frames)
        return frames

    def app_frame(self, platform_prefixes):
        for element in reversed(self.chain):
            for frame in element.frames:
                target = frame_target(frame)
                if target and not target.startswith(platform_prefixes):
                    return frame.strip()
        return ""

    def frame_count(self):
        return sum(len(element.frames) for element in self.chain)


def event_text(event):
    """例外ブロック本文に、その例外を導いたログ行 (別行に出る場合) を足した文字列。

    "WFLYSRV0177: parse error in .../web.xml" のように、対象ファイル名や接続先が
    例外ブロックではなくログ行側に書かれていることが多いため、両方を対象にする。
    """
    parts = [line.body for line in event.block_lines]
    if event.origin_line is not event.header_line:
        parts.insert(0, event.origin_line.body)
    return "\n".join(parts)


def frame_target(frame):
    """"at java.base/java.lang.Class.forName(Class.java:398)" からクラス名部分を取り出す。"""
    text = frame.strip()
    if text.startswith("at "):
        text = text[3:].strip()
    text = text.split("(", 1)[0].strip()
    if "/" in text:
        # モジュール名付き (java.base/java.lang.Class.forName)
        text = text.split("/", 1)[1]
    return text


def collect_exception_events(lines):
    """スタックフレームの並びを手掛かりに、例外ブロックを切り出す。"""
    events = []
    index = 0
    total = len(lines)
    while index < total:
        if not is_frame(lines[index]):
            index += 1
            continue
        # フレームの直前行がヘッダー (例外クラス + メッセージ) になる。
        header_index = index - 1
        while header_index >= 0 and not lines[header_index].body.strip():
            header_index -= 1
        if header_index < 0:
            index += 1
            continue
        header_line = lines[header_index]
        klass, message = split_class_and_message(header_line.body)
        event = ExceptionEvent(header_line)
        element = ChainElement("top", klass, message, header_line.body)
        event.chain.append(element)
        event.block_lines.append(header_line)

        cursor = index
        while cursor < total:
            line = lines[cursor]
            if is_frame(line):
                element.frames.append(line.body.strip())
                event.block_lines.append(line)
                cursor += 1
                continue
            if is_more(line):
                digits = re.findall(r"\d+", line.body)
                element.more = int(digits[0]) if digits else 0
                event.block_lines.append(line)
                cursor += 1
                continue
            caused = CAUSED_BY_RE.match(line.body)
            suppressed = SUPPRESSED_RE.match(line.body)
            if caused or suppressed:
                rest = (caused or suppressed).group("rest")
                sub_class, sub_message = split_class_and_message(rest)
                element = ChainElement("caused-by" if caused else "suppressed",
                                       sub_class, sub_message, line.body.strip())
                event.chain.append(element)
                event.block_lines.append(line)
                cursor += 1
                continue
            break
        event.origin_line = resolve_origin_line(lines, header_line)
        events.append(event)
        index = cursor if cursor > index else index + 1
    return events


def resolve_origin_line(lines, header_line, lookback=20):
    """例外のヘッダー行が素の Java 出力の場合、直前のログ行から発生時刻等を引き継ぐ。"""
    if header_line.time:
        return header_line
    cursor = header_line.index - 1
    limit = max(0, header_line.index - lookback)
    while cursor >= limit:
        candidate = lines[cursor]
        if candidate.service != header_line.service:
            break
        if candidate.time:
            return candidate
        cursor -= 1
    return header_line


def resolve_deployment_names(lines):
    """行番号ごとに「その時点で処理中のデプロイ対象」を割り当てる。

    Compose のログはサービスごとに独立しているため、あるサービスのデプロイ名が
    別サービスの例外へ引き継がれないよう、サービス単位に状態を持つ。
    """
    current = {}
    per_line = []
    for line in lines:
        started = DEPLOY_START_RE.search(line.message)
        if started:
            current[line.service] = started.group("name")
        else:
            rolled = DEPLOY_ROLLBACK_RE.search(line.message)
            if rolled:
                current[line.service] = rolled.group("name")
        per_line.append(current.get(line.service, ""))
    return per_line


def deploy_phase_bounds(lines):
    """サービスごとに、デプロイ開始行と起動完了 (WFLYSRV0025/0026) 行を求める。"""
    bounds = {}
    for line in lines:
        start, end = bounds.get(line.service, (-1, -1))
        if start < 0 and DEPLOY_START_RE.search(line.message):
            start = line.index
        if end < 0 and BOOT_COMPLETE_RE.search(line.message):
            end = line.index
        bounds[line.service] = (start, end)
    for service, (start, end) in list(bounds.items()):
        if end < 0:
            # 起動完了ログが無い場合は、そのサービスの最終行までをデプロイ区間とする。
            last = max(line.index for line in lines if line.service == service)
            bounds[service] = (start, last)
    return bounds


def classify_deploy_relation(event, lines, deployment_names, phase_bounds):
    reasons = []
    name = ""
    block_text = event_text(event)
    phase_start, phase_end = phase_bounds.get(event.header_line.service, (-1, -1))

    unit = DEPLOY_UNIT_RE.search(block_text)
    if unit:
        name = unit.group("name")
        reasons.append("スタックトレース中に MSC サービス名 jboss.deployment.unit.\"%s\" を含む" % name)
    if not name:
        archive = ARCHIVE_NAME_RE.search(event.header_line.message)
        if archive:
            name = archive.group("name")
            reasons.append("例外を出したログ行がアーカイブ \"%s\" を指している" % name)
    header_index = event.header_line.index
    in_phase = phase_start >= 0 and phase_start <= header_index <= phase_end
    if not name and in_phase:
        candidate = deployment_names[header_index] if deployment_names else ""
        if candidate:
            name = candidate
            reasons.append("直前の WFLYSRV0027 (Starting deployment of \"%s\") 以降に発生している" % candidate)

    if in_phase:
        reasons.append("デプロイ開始から起動完了までの区間 (行 %d〜%d) で発生している"
                       % (phase_start + 1, phase_end + 1))
    logger = event.origin_line.logger or event.header_line.logger or ""
    for token in DEPLOY_CONTEXT_TOKENS:
        if token in block_text or token in logger:
            reasons.append("デプロイ処理を示す文字列 \"%s\" を含む" % token)
            break
    if logger.startswith("org.jboss.as.server.deployment"):
        reasons.append("ロガーがデプロイヤ (%s)" % logger)

    event.deployment = name
    event.deploy_reasons = reasons
    event.deploy_related = bool(reasons)
    return event


def collect_related_codes(event, lines, window=8, limit=8):
    """例外ブロックの前後にある EAP メッセージコードを、関連情報として集める。"""
    service = event.header_line.service
    start = max(0, event.header_line.index - window)
    end = min(len(lines), event.block_lines[-1].index + window + 1)
    seen = []
    for line in lines[start:end]:
        if line.service != service or not line.code or line.code in seen:
            continue
        seen.append(line.code)
        if len(seen) >= limit:
            break
    return seen


# =============================================================================
# 例外クラス知識ベース
# =============================================================================

SEVERITY_ORDER = {"致命的": 0, "重大": 1, "警告": 2, "情報": 3}

GENERIC_ERROR = {
    "category": "その他 (JVM エラー)",
    "severity": "致命的",
    "headline": "JVM が回復不能と判断した Error 系の例外です。アプリケーションコードでは捕捉せず、原因そのものを取り除く必要があります。",
    "mechanism": (
        "java.lang.Error のサブクラスは、クラスのリンク・メモリ確保・ネイティブ連携など JVM 自身の前提が"
        "崩れたときに投げられます。JBoss EAP はデプロイユニットの起動を担う MSC サービスの中でこれを受け取ると、"
        "当該サービスを failed 状態にし、依存する全サービスを起動できないまま巻き戻します"
        "(WFLYCTL0080 / WFLYSRV0021)。"
    ),
    "causes": [
        "WAR に同梱したライブラリと EAP のモジュールでバージョンが食い違っている",
        "コンテナへ割り当てたメモリやファイルディスクリプタが不足している",
        "ビルド時とランタイムで JDK のバージョンが異なる",
    ],
    "checks": [
        "起動ログで最初に出た Error を特定する (後続の Error は連鎖であることが多い)",
        "docker exec <container> java -version でランタイムの JDK を確認する",
        "docker exec <container> ls -l <デプロイ先>/<アーカイブ>/WEB-INF/lib で同梱ライブラリを確認する",
    ],
    "fixes": [
        "根本原因 (Caused by の最終段) の例外に対応する。Error 自体を握り潰さない",
        "ライブラリの重複がある場合は WAR 側の同梱を外すか、jboss-deployment-structure.xml で除外する",
    ],
    "prevention": [
        "ビルドとランタイムで同じ JDK メジャーバージョンを使う",
        "依存ライブラリの一覧 (mvn dependency:tree) を CI で固定・監視する",
    ],
    "refs": ["JBoss EAP 8.1 Configuration Guide - Class Loading and Modules"],
}

GENERIC_EXCEPTION = {
    "category": "その他 (アプリケーション例外)",
    "severity": "重大",
    "headline": "アプリケーションまたはフレームワークが投げた例外です。根本原因 (Caused by の最終段) を辿って原因を特定します。",
    "mechanism": (
        "デプロイ中に投げられた例外は、JBoss EAP のデプロイヤ (MSC サービス) が捕捉して"
        "org.jboss.msc.service.StartException で包み直し、該当デプロイユニットを失敗させます。"
        "失敗したサービスに依存する全サービスも起動できず、WFLYCTL0080 の Failed services として一覧に出ます。"
    ),
    "causes": [
        "初期化処理 (ServletContextListener / @PostConstruct / static 初期化子) の前提条件が満たされていない",
        "外部リソース (DB・API・ファイル) へ接続できない、または権限が足りない",
        "設定値 (環境変数・システムプロパティ・設定ファイル) が未設定か不正",
    ],
    "checks": [
        "Caused by の最終段のクラスとメッセージを確認する",
        "スタックトレースからアプリケーション自身のクラス (最初の自社パッケージ) を特定する",
        "同時刻の他サービス (DB・キャッシュ等) のログに接続拒否が出ていないか確認する",
    ],
    "fixes": [
        "根本原因の例外に応じた対処を行う",
        "初期化処理へ、前提条件が満たされない場合に何が足りないかを示すログを追加する",
    ],
    "prevention": [
        "起動時に必要な設定値をチェックし、欠落時は具体的な名前を出して失敗させる",
        "外部依存の接続確認を healthcheck / depends_on の condition: service_healthy で担保する",
    ],
    "refs": ["JBoss EAP 8.1 Development Guide"],
}


def entry(category, severity, headline, mechanism, causes, checks, fixes, prevention, refs):
    return {
        "category": category,
        "severity": severity,
        "headline": headline,
        "mechanism": mechanism,
        "causes": causes,
        "checks": checks,
        "fixes": fixes,
        "prevention": prevention,
        "refs": refs,
    }


KNOWLEDGE = {}


def register(names, data):
    for name in names:
        KNOWLEDGE[name] = data


register(["java.lang.ClassNotFoundException"], entry(
    "クラスロード・依存関係", "致命的",
    "実行時にクラスを名前で探しましたが、そのデプロイユニットから見えるクラスローダー上に存在しませんでした。",
    "Class.forName() や ServiceLoader、フレームワークのリフレクション呼び出しがクラス名の文字列からクラスを解決しようとして失敗した状態です。"
    "JBoss EAP は WAR ごとに独立したモジュールクラスローダーを作り、参照できる範囲を "
    "(1) WEB-INF/classes、(2) WEB-INF/lib の JAR、(3) EAP のグローバルモジュール、"
    "(4) jboss-deployment-structure.xml / MANIFEST.MF の Dependencies で明示した module、"
    "の 4 つに限定します。この 4 つのいずれにも該当クラスが無い場合に発生します。"
    "「コンパイルは通るのに実行時だけ失敗する」場合は、ビルド時のスコープ (provided / test) と"
    "ランタイムに配置されるものが食い違っている典型例です。",
    [
        "依存ライブラリの JAR が WEB-INF/lib に含まれていない (Maven の scope が provided / test のまま)",
        "EAP のモジュールとして提供される想定だが、jboss-deployment-structure.xml に依存を宣言していない",
        "JAR は存在するがバージョンが古く、そのクラスがまだ存在しない",
        "サブデプロイ (EAR 内の WAR) から、別サブデプロイのクラスを参照している",
        "Dockerfile の COPY 対象漏れ・マルチステージビルドでの成果物の取りこぼし",
    ],
    [
        "docker exec <container> ls <デプロイ先>/<アーカイブ>/WEB-INF/lib で JAR の有無を確認する",
        "docker exec <container> sh -c 'cd <デプロイ先>/<アーカイブ>/WEB-INF/lib && for f in *.jar; do unzip -l \"$f\" | grep -q \"<クラスのパス>.class\" && echo \"$f\"; done'",
        "mvn dependency:tree -Dincludes=<groupId>:<artifactId> でスコープと到達経路を確認する",
        "docker exec <container> ls /opt/jboss-eap/modules/ で EAP 側モジュールの有無を確認する",
    ],
    [
        "必要な JAR を WEB-INF/lib へ含める (Maven なら scope を compile / runtime に変更して再ビルド)",
        "EAP のモジュールを使う場合は WEB-INF/jboss-deployment-structure.xml へ依存を追加する:\n"
        "  <jboss-deployment-structure>\n"
        "    <deployment>\n"
        "      <dependencies>\n"
        "        <module name=\"<モジュール名>\" services=\"import\"/>\n"
        "      </dependencies>\n"
        "    </deployment>\n"
        "  </jboss-deployment-structure>",
        "MANIFEST.MF へ Dependencies: <モジュール名> を書く方法でも同じ効果が得られる",
        "自前の共有ライブラリは module.xml を作って EAP のモジュールとして登録し、複数 WAR から参照する",
        "ビルド成果物 (target/*.war) を展開し、意図した JAR が入っているかを CI で検証する",
    ],
    [
        "WAR の中身 (WEB-INF/lib の一覧) をビルド成果物として保存し、差分を追跡する",
        "provided スコープにするのは EAP が確実に提供するもの (Jakarta EE API など) だけに限定する",
    ],
    ["JBoss EAP 8.1 Development Guide - Class Loading in Deployments",
     "JBoss EAP 8.1 - jboss-deployment-structure.xml"],
))

register(["java.lang.NoClassDefFoundError"], entry(
    "クラスロード・依存関係", "致命的",
    "一度は解決できたはずのクラス定義が、実際にロードしようとした時点で見つかりませんでした。ClassNotFoundException と似ていますが、原因は別のことが多いです。",
    "NoClassDefFoundError には 2 つの発生経路があります。"
    "(A) コンパイル時には存在したクラスが実行時のクラスパスに無い。"
    "(B) そのクラスの static 初期化子 (static ブロック / static フィールドの初期化) が例外を投げて"
    "クラスの初期化に失敗し、以後そのクラスを参照するたびに NoClassDefFoundError が投げられる。"
    "(B) の場合、最初の 1 回目だけは ExceptionInInitializerError が出ており、2 回目以降が "
    "NoClassDefFoundError になります。したがってログを時系列で遡り、"
    "「そのクラスに関する最初のエラー」を見ることが決め手になります。",
    [
        "依存 JAR がランタイムに存在しない (ClassNotFoundException と同じ原因)",
        "static 初期化子が例外を投げてクラス初期化に失敗している (直前に ExceptionInInitializerError がある)",
        "同じクラスが複数のクラスローダーに存在し、リンクに失敗している",
        "ライブラリのバージョン差で、参照先クラスが別パッケージへ移動した (javax → jakarta の移行漏れなど)",
    ],
    [
        "同じクラス名で ExceptionInInitializerError がログの上方に出ていないか検索する",
        "docker exec <container> grep -R \"<クラス名>\" <デプロイ先>/<アーカイブ>/WEB-INF/lib で JAR を特定する",
        "javax.* / jakarta.* の混在がないか、WEB-INF/lib の JAR 名を確認する (EAP 8.1 は Jakarta EE 10 = jakarta.* が正)",
    ],
    [
        "直前に ExceptionInInitializerError がある場合は、そちらの Caused by を根本原因として対処する (このエラーは結果に過ぎない)",
        "クラスパス不足の場合は ClassNotFoundException と同じ対処 (WEB-INF/lib へ JAR を追加 / モジュール依存を宣言)",
        "javax.* を参照している古いライブラリは、Jakarta EE 10 対応版へ差し替えるか、Eclipse Transformer で変換する",
    ],
    [
        "static 初期化子では外部リソースへアクセスしない (初期化失敗が後段で原因不明のエラーになるため)",
        "EAP 8.1 では jakarta.* 系ライブラリで揃える方針を依存管理 (BOM) で固定する",
    ],
    ["JBoss EAP 8.1 Migration Guide - Jakarta EE 10"],
))

register(["java.lang.ExceptionInInitializerError"], entry(
    "クラスロード・依存関係", "致命的",
    "クラスの static 初期化子 (static ブロック / static フィールド初期化) が例外を投げ、クラスの初期化に失敗しました。",
    "JVM はクラスを初めて使うときに一度だけ static 初期化子を実行します。ここで未検査例外が投げられると、"
    "JVM はその例外を ExceptionInInitializerError で包み、当該クラスを「初期化失敗」として記録します。"
    "以後、同じクラスに触れるたびに NoClassDefFoundError が投げられ続けます。"
    "本当の原因は必ず Caused by の側にあります。",
    [
        "static 初期化子から設定ファイル・環境変数を読んでおり、値が無い/不正",
        "static 初期化子で DB や外部 API へ接続しており、デプロイ時点ではまだ到達できない",
        "ロガーや暗号プロバイダの初期化に失敗している",
    ],
    [
        "Caused by に出ている本来の例外を確認する (これが唯一の手掛かり)",
        "対象クラスの static ブロック / static final フィールドの初期化処理を読む",
        "参照している環境変数がコンテナに設定されているか docker exec <container> env で確認する",
    ],
    [
        "Caused by の例外に応じて対処する (未設定の環境変数を設定する、接続先を healthcheck 待ちにする など)",
        "static 初期化子から外部依存を外し、@PostConstruct や遅延初期化へ移す",
        "設定値が必須なら、欠落時に「どの設定が無いか」を明示するメッセージで失敗させる",
    ],
    [
        "static 初期化子は定数の組み立てだけに留める",
        "外部リソースへの接続はコンテナのライフサイクル (@PostConstruct / ServletContextListener) に載せる",
    ],
    ["Java Language Specification - Class Initialization"],
))

register(["java.lang.NoSuchMethodError", "java.lang.NoSuchFieldError",
          "java.lang.IncompatibleClassChangeError"], entry(
    "クラスロード・依存関係", "致命的",
    "クラスは見つかりましたが、期待したメソッド/フィールドがそのクラスにありませんでした。ライブラリのバージョン不整合を示す決定的な証拠です。",
    "コンパイル時に見えていたクラス定義と、実行時にロードされたクラス定義が違う場合に発生します。"
    "JBoss EAP では、WAR 内の WEB-INF/lib に同梱した JAR と、EAP がモジュールとして提供する同名ライブラリの"
    "どちらが優先されるかで、実行時にロードされるクラスが変わります。既定では WAR 内が優先されますが、"
    "EAP のサブシステムが暗黙で追加するモジュール依存 (Jakarta EE API、Hibernate、Jackson など) が"
    "先に効くケースがあり、そこで版が入れ替わります。メッセージに出るシグネチャが、"
    "どの版のライブラリのものかを突き合わせるのが最短の切り分けです。",
    [
        "同じライブラリの複数バージョンが WAR 内と EAP モジュールの双方に存在する",
        "推移的依存で、意図しないバージョンへ収束している (Maven の dependency mediation)",
        "EAP が提供する Hibernate / Jackson / JAX-RS 実装と、WAR 同梱版が競合している",
    ],
    [
        "mvn dependency:tree -Dverbose で同一 artifact の複数バージョンを洗い出す",
        "docker exec <container> ls <デプロイ先>/<アーカイブ>/WEB-INF/lib | sort で同名ライブラリの重複を確認する",
        "エラーになったシグネチャを含むクラスがどの JAR にあるか、unzip -l で特定する",
        "-verbose:class を JVM 引数に加えて起動し、どの JAR からロードされたかを確認する",
    ],
    [
        "バージョンを揃える。Maven なら <dependencyManagement> か BOM でバージョンを固定する",
        "EAP 提供モジュールを使う場合は WAR 同梱を除外する (Maven の <scope>provided</scope>)",
        "WAR 同梱版を使う場合は jboss-deployment-structure.xml で EAP のモジュールを除外する:\n"
        "  <jboss-deployment-structure>\n"
        "    <deployment>\n"
        "      <exclusions>\n"
        "        <module name=\"<除外するモジュール名>\"/>\n"
        "      </exclusions>\n"
        "    </deployment>\n"
        "  </jboss-deployment-structure>",
        "クラスローダーの優先順位を変える場合は <local-last value=\"true\"/> を検討する",
    ],
    [
        "BOM でライブラリ群のバージョンを一括管理する",
        "mvn enforcer-plugin の dependencyConvergence ルールでバージョン衝突を CI で検出する",
    ],
    ["JBoss EAP 8.1 Development Guide - Class Loading and Subdeployment Isolation"],
))

register(["java.lang.UnsupportedClassVersionError"], entry(
    "クラスロード・依存関係", "致命的",
    "クラスファイルのバージョンが、実行中の JVM が読める上限を超えています。ビルドに使った JDK が、実行に使う JDK より新しい状態です。",
    "class ファイルの先頭にはメジャーバージョン番号が入っており、JVM は自分が対応する範囲を超えるものを拒否します。"
    "対応表は Java 8=52、11=55、17=61、21=65 です。JBoss EAP 8.1 は Java 11/17/21 をサポートしますが、"
    "コンテナイメージに入っている JDK と、CI でコンパイルした JDK が食い違うとこのエラーになります。"
    "WAR 同梱のサードパーティ JAR が新しい JDK 向けにビルドされている場合も同じです。",
    [
        "Maven の maven.compiler.release とコンテナの JDK が一致していない",
        "マルチステージ Dockerfile のビルドステージとランタイムステージで JDK が違う",
        "依存ライブラリが、実行環境より新しい Java 向けにビルドされている",
    ],
    [
        "docker exec <container> java -version でランタイムの JDK を確認する",
        "Dockerfile のビルドステージで使っている JDK イメージのタグを確認する",
        "エラーメッセージの class file version から、必要な JDK を割り出す (61.0=Java 17 / 65.0=Java 21)",
    ],
    [
        "コンテナの JDK をビルドと同じメジャーバージョンへ揃える",
        "またはコンパイル側を下げる: Maven なら <maven.compiler.release>17</maven.compiler.release>",
        "ライブラリ側が原因なら、実行環境の Java バージョンに対応した版へ差し替える",
    ],
    [
        "Dockerfile のビルド/ランタイム双方の JDK タグを同じ変数から与える",
        "maven-enforcer-plugin の requireJavaVersion でビルド JDK を固定する",
    ],
    ["JBoss EAP 8.1 Supported Configurations - Java Virtual Machines"],
))

register(["org.jboss.modules.ModuleNotFoundException",
          "org.jboss.modules.ModuleLoadException"], entry(
    "クラスロード・依存関係", "致命的",
    "jboss-deployment-structure.xml や MANIFEST.MF で宣言したモジュールが、EAP のモジュールリポジトリに存在しません。",
    "JBoss Modules は $JBOSS_HOME/modules 配下のディレクトリ構造と module.xml でモジュールを解決します。"
    "モジュール名 com.example.foo は modules/com/example/foo/main/module.xml へ対応します。"
    "宣言した名前が 1 文字でも違う、slot 名 (既定は main) が違う、module.xml の resource-root が"
    "実 JAR を指していない、のいずれでもこの例外になります。",
    [
        "モジュール名のタイプミス、または slot の指定漏れ",
        "カスタムモジュールをイメージへ COPY し忘れている",
        "module.xml の <resource-root path=\"...\"/> が実際の JAR 名と一致していない",
        "EAP 8.1 で名前が変わった/廃止されたモジュールを参照している",
    ],
    [
        "docker exec <container> ls -R /opt/jboss-eap/modules/<モジュールをパスにしたディレクトリ>",
        "docker exec <container> cat /opt/jboss-eap/modules/.../main/module.xml",
        "宣言側 (WEB-INF/jboss-deployment-structure.xml) の module name を確認する",
    ],
    [
        "モジュール名を正しい値へ修正する",
        "カスタムモジュールを Dockerfile で配置する:\n"
        "  COPY modules/ /opt/jboss-eap/modules/\n"
        "  または jboss-cli の module add --name=... --resources=... を使う",
        "module.xml の resource-root の path を実 JAR 名へ合わせる",
        "任意依存で良ければ <module name=\"...\" optional=\"true\"/> にする",
    ],
    [
        "カスタムモジュールの配置をイメージビルドのテストで検証する",
        "EAP のバージョンアップ時はモジュール名の変更点を Migration Guide で確認する",
    ],
    ["JBoss EAP 8.1 Configuration Guide - Modules"],
))

register(["javax.naming.NameNotFoundException", "javax.naming.NamingException",
          "javax.naming.NoInitialContextException"], entry(
    "JNDI・リソース参照", "致命的",
    "JNDI 名前空間から目的のリソース (データソース・JMS・EJB など) を引けませんでした。名前の綴りか、リソースの定義漏れが原因です。",
    "JBoss EAP は起動時にサブシステムが JNDI へリソースをバインドし (WFLYJCA0001 / WFLYJCA0098 などのログ)、"
    "アプリケーションはその名前で lookup または @Resource で注入を受けます。"
    "バインドが行われていない、または名前空間が違う (java:/ と java:jboss/ と java:comp/env/ は別物) と、"
    "この例外になります。EAP は MSC サービス jboss.naming.context.java.* として管理するため、"
    "WFLYCTL0412 の \"Required services that are not installed\" にも同じ名前が現れます。",
    [
        "standalone.xml / compose 環境変数で定義したデータソースの JNDI 名と、アプリの参照名が一致していない",
        "データソース自体の起動に失敗している (直前に WFLYJCA0031 などが出ていないか)",
        "java:comp/env/ を使うのに web.xml / @Resource の name 定義が無い",
        "EAP 8.1 でグローバル JNDI を参照するのに java:jboss/exported/ の付与を誤っている",
    ],
    [
        "起動ログで \"Bound data source\" (WFLYJCA0001) の行を探し、実際にバインドされた名前を確認する",
        "docker exec <container> /opt/jboss-eap/bin/jboss-cli.sh --connect --command=\"/subsystem=naming:jndi-view\"",
        "docker exec <container> grep -n \"jndi-name\" /opt/jboss-eap/standalone/configuration/standalone.xml",
    ],
    [
        "アプリ側の lookup 名を、起動ログに出ている実際の JNDI 名へ合わせる",
        "データソースが未定義なら standalone.xml か jboss-cli で追加する:\n"
        "  data-source add --name=<名前> --jndi-name=java:jboss/datasources/<名前> \\\n"
        "    --driver-name=<ドライバ> --connection-url=<URL> --user-name=<ユーザ> --password=<パスワード>",
        "データソースの起動失敗が原因なら、そちらのエラー (接続不可・認証失敗) を先に解消する",
        "@Resource(lookup = \"java:jboss/datasources/...\") のように lookup 属性で完全名を指定する",
    ],
    [
        "JNDI 名を環境変数から与え、compose.yml とアプリで同じ値を共有する",
        "起動確認で jndi-view を取得し、期待する名前がバインドされていることを検証する",
    ],
    ["JBoss EAP 8.1 Configuration Guide - Java Naming and Directory Interface"],
))

register(["java.sql.SQLException", "java.sql.SQLNonTransientConnectionException",
          "java.sql.SQLTransientConnectionException", "java.sql.SQLTimeoutException",
          "java.sql.SQLInvalidAuthorizationSpecException",
          "org.postgresql.util.PSQLException",
          "com.mysql.cj.jdbc.exceptions.CommunicationsException",
          "com.mysql.cj.exceptions.CJCommunicationsException"], entry(
    "データソース・JDBC", "致命的",
    "JDBC ドライバが DB へ接続できない、または DB がエラーを返しました。デプロイ時は接続プールの初期化で発生することが多いです。",
    "EAP のデータソースは、min-pool-size やバリデーション設定に応じてデプロイ時に接続を張ります。"
    "接続 URL のホスト名解決、TCP 到達性、認証、DB 側の起動完了のいずれかが欠けると、"
    "IronJacamar が WFLYJCA0031 (unable to validate and deploy ds or xads) を出し、"
    "そのデータソースに依存する WAR のデプロイも巻き戻されます。"
    "Compose 構成では「DB コンテナはまだ初期化中なのにアプリが先に起動した」ケースが最も多い原因です。",
    [
        "DB コンテナがまだ受付可能になっていない (depends_on の condition: service_healthy が未設定)",
        "接続 URL のホスト名が Compose のサービス名と一致していない",
        "ユーザ名/パスワードが違う (パスワードに $ や \" が含まれ、展開・エスケープで壊れている)",
        "DB 側でデータベース/スキーマがまだ作られていない",
        "ネットワーク分離により、アプリと DB が別ネットワークに属している",
    ],
    [
        "docker exec <container> sh -c 'getent hosts <DBホスト名>' で名前解決を確認する",
        "docker compose logs <DBサービス> で DB 側が受付可能になった時刻を確認する",
        "docker exec <container> grep -n \"connection-url\" /opt/jboss-eap/standalone/configuration/standalone.xml",
        "docker exec <container> /opt/jboss-eap/bin/jboss-cli.sh --connect --command=\"/subsystem=datasources/data-source=<名前>:test-connection-in-pool\"",
    ],
    [
        "compose.yml で DB に healthcheck を定義し、アプリ側へ depends_on: { <DB>: { condition: service_healthy } } を設定する",
        "接続 URL のホスト名を Compose のサービス名 (または container_name) へ合わせる",
        "認証情報を環境変数経由に統一し、パスワードの特殊文字は $ を $$ にエスケープする (compose.yml の変数展開対策)",
        "初期接続の失敗を許容する場合は、データソースへ <initial-pool-size>0</initial-pool-size> と "
        "validate-on-match / background-validation を設定して遅延接続にする",
        "本スクリプトの --wait-healthy を付け、依存サービスが healthy になってから起動確認へ進める",
    ],
    [
        "DB の healthcheck を compose.yml に必ず定義する",
        "接続情報を 1 か所 (環境変数) に集約し、アプリと DB の双方から同じ値を参照する",
    ],
    ["JBoss EAP 8.1 Configuration Guide - Datasource Management"],
))

register(["java.net.ConnectException", "java.net.NoRouteToHostException"], entry(
    "ネットワーク接続", "致命的",
    "TCP 接続が拒否されました。相手が起動していないか、ポートが違うか、ネットワークが繋がっていません。",
    "Connection refused は「名前解決には成功したが、そのポートで待ち受けているプロセスが無い」状態です。"
    "Compose 構成では、依存コンテナがまだ起動途中、あるいはコンテナ内のプロセスが 127.0.0.1 のみで"
    "listen していて他コンテナから到達できない、というのが典型です。"
    "また、ホスト側の localhost をコンテナ内から参照している場合も必ず失敗します。",
    [
        "接続先コンテナがまだ listen していない (起動順序の問題)",
        "接続先プロセスが 0.0.0.0 ではなく 127.0.0.1 で listen している",
        "ポート番号が違う (ホスト側の公開ポートとコンテナ側ポートを取り違えている)",
        "コンテナ間で同じ Docker ネットワークに属していない",
    ],
    [
        "docker compose ps で接続先サービスの状態と公開ポートを確認する",
        "docker exec <container> sh -c 'command -v nc >/dev/null && nc -z -v <ホスト> <ポート>'",
        "docker exec <接続先container> sh -c 'ss -ltn || netstat -ltn' で listen アドレスを確認する",
        "docker network inspect <ネットワーク名> で両コンテナが同じネットワークにいるか確認する",
    ],
    [
        "compose.yml で healthcheck + depends_on: condition: service_healthy を設定し、起動順序を保証する",
        "接続先プロセスの bind アドレスを 0.0.0.0 にする",
        "コンテナ間通信では、公開ポートではなくコンテナ側のポートを使う",
        "接続先ホスト名は Compose のサービス名を使う (localhost は自コンテナを指す)",
    ],
    [
        "起動時のリトライ (指数バックオフ) を接続処理へ入れる",
        "本スクリプトの --wait-healthy を常用し、依存サービスの準備完了を待つ",
    ],
    ["Docker Compose - Control startup order"],
))

register(["java.net.UnknownHostException"], entry(
    "ネットワーク接続", "致命的",
    "ホスト名を IP アドレスへ解決できませんでした。接続先の名前が間違っているか、そのサービスが Compose に存在しません。",
    "コンテナ内の名前解決は Docker の内蔵 DNS が担当し、同じネットワークに属する Compose サービス名と "
    "container_name、および network の alias を解決できます。ここに無い名前は解決できません。"
    "AWS のエンドポイント (例: logs.ap-northeast-1.amazonaws.com) を引けない場合は、"
    "コンテナに外部 DNS が届いていないか、プロキシ設定が必要な環境である可能性があります。",
    [
        "接続先名が compose.yml のサービス名・container_name のいずれとも一致していない",
        "接続先が別の Docker ネットワークに属している",
        "外部ホストへの名前解決に失敗している (DNS 未到達・プロキシ環境)",
        "環境変数の値が空で、URL が \"http://:8080/\" のように壊れている",
    ],
    [
        "docker exec <container> sh -c 'getent hosts <ホスト名>' で解決可否を確認する",
        "docker exec <container> cat /etc/resolv.conf で DNS 設定を確認する",
        "docker compose config --services で定義済みサービス名の一覧を確認する",
        "docker exec <container> env | grep -i <該当の環境変数名> で値が空でないか確認する",
    ],
    [
        "接続先ホスト名を compose.yml のサービス名へ合わせる",
        "同じ networks に所属させる、または networks の aliases で別名を付ける",
        "外部ホストが必要な場合は、DNS / プロキシ設定 (HTTP_PROXY, NO_PROXY) をコンテナへ渡す",
        "URL を組み立てる環境変数が未設定でないか確認し、既定値を用意する",
    ],
    [
        "接続先ホスト名を環境変数化し、compose.yml のサービス名と同じ値を一元管理する",
    ],
    ["Docker Compose - Networking"],
))

register(["java.net.BindException"], entry(
    "ネットワーク接続", "致命的",
    "指定したポートを確保できませんでした。すでに他のプロセスが同じポートを使っています。",
    "JBoss EAP は起動時に HTTP リスナー (既定 8080)、管理ポート (9990) などを bind します。"
    "コンテナ内で同じポートを使う別プロセスがある、あるいは port-offset を付けた複数インスタンスが"
    "同一ネットワーク名前空間に同居していると、この例外で起動が止まります。"
    "ホスト側の公開ポート衝突は Compose 側のエラーになるため、この例外はコンテナ内部での衝突を示します。",
    [
        "同じコンテナ内で 2 つ目の EAP インスタンスを起動しようとしている",
        "network_mode: host でホスト側のポートと衝突している",
        "アプリケーションが独自に同じポートで listen している",
    ],
    [
        "docker exec <container> sh -c 'ss -ltnp || netstat -ltnp' で使用中ポートを確認する",
        "起動ログの WFLYUT0006 (Undertow HTTP listener listening on ...) を確認する",
        "compose.yml の ports / network_mode を確認する",
    ],
    [
        "重複して起動しているプロセスを止める",
        "jboss.socket.binding.port-offset を指定してポートをずらす:\n"
        "  JAVA_OPTS_APPEND=\"-Djboss.socket.binding.port-offset=100\"",
        "アプリ側の listen ポートを変更する",
    ],
    [
        "1 コンテナ 1 プロセスの構成を守る",
    ],
    ["JBoss EAP 8.1 Configuration Guide - Socket Bindings"],
))

register(["javax.net.ssl.SSLHandshakeException", "javax.net.ssl.SSLException",
          "sun.security.provider.certpath.SunCertPathBuilderException",
          "java.security.cert.CertificateException",
          "javax.net.ssl.SSLPeerUnverifiedException"], entry(
    "TLS・証明書", "致命的",
    "TLS ハンドシェイクに失敗しました。サーバ証明書を信頼できないか、プロトコル/暗号スイートが噛み合っていません。",
    "JVM は接続先のサーバ証明書を、トラストストア ($JAVA_HOME/lib/security/cacerts または "
    "-Djavax.net.ssl.trustStore で指定したファイル) 内の CA 証明書で検証します。"
    "社内 CA や自己署名証明書はここに無いため、\"unable to find valid certification path to requested target\" となります。"
    "また EAP 8.1 / JDK 17 以降は TLS 1.0/1.1 と弱い暗号スイートが既定で無効のため、"
    "古い相手とは \"no appropriate protocol\" や handshake_failure になります。",
    [
        "社内 CA / 自己署名証明書がトラストストアに登録されていない",
        "証明書の有効期限切れ、またはホスト名 (SAN) の不一致",
        "接続先が TLS 1.0/1.1 しか対応しておらず、JDK 側で無効化されている",
        "中間 CA 証明書がサーバ側で配信されていない",
    ],
    [
        "docker exec <container> sh -c 'command -v openssl >/dev/null && openssl s_client -connect <ホスト>:<ポート> -showcerts </dev/null'",
        "docker exec <container> keytool -list -cacerts -storepass changeit | head で登録済み CA を確認する",
        "JVM 引数へ -Djavax.net.debug=ssl:handshake を一時的に足して詳細ログを取る",
    ],
    [
        "CA 証明書をイメージのトラストストアへ登録する:\n"
        "  RUN keytool -importcert -noprompt -cacerts -storepass changeit \\\n"
        "      -alias corp-ca -file /tmp/corp-ca.crt",
        "OS のトラストストアへ入れる場合: COPY corp-ca.crt /etc/pki/ca-trust/source/anchors/ && RUN update-ca-trust extract",
        "本スクリプトの --copy-file で CA 証明書をビルドコンテキストへ一時配置してから COPY する",
        "プロトコル不一致の場合は、接続先を TLS 1.2 以上へ更新する (JDK 側の無効化解除は最終手段)",
    ],
    [
        "CA 証明書の配置をイメージビルドの手順として固定し、期限管理を行う",
    ],
    ["JBoss EAP 8.1 Security Architecture - Truststore"],
))

register(["org.jboss.weld.exceptions.DeploymentException",
          "org.jboss.weld.exceptions.DefinitionException",
          "jakarta.enterprise.inject.UnsatisfiedResolutionException",
          "jakarta.enterprise.inject.AmbiguousResolutionException",
          "jakarta.enterprise.inject.spi.DefinitionException",
          "jakarta.enterprise.inject.CreationException"], entry(
    "CDI (Weld)", "致命的",
    "CDI コンテナ (Weld) が Bean の依存関係を解決できませんでした。注入先に対して候補が 0 個か、2 個以上あります。",
    "Weld はデプロイ時に全 Bean アーカイブを走査し、@Inject の注入点ごとに型と修飾子から候補 Bean を決定します。"
    "候補が 0 個なら WELD-001408 (Unsatisfied dependencies)、2 個以上なら WELD-001409 (Ambiguous dependencies) となり、"
    "いずれもデプロイ時点で失敗させます (実行時まで持ち越しません)。"
    "beans.xml の bean-discovery-mode が annotated の場合、Bean 定義アノテーションの無いクラスは"
    "そもそも候補になりません。EAP 8.1 (Jakarta EE 10) では既定が annotated です。",
    [
        "実装クラスに @ApplicationScoped 等の Bean 定義アノテーションが無い (discovery-mode=annotated のため候補外)",
        "実装クラスを含む JAR に beans.xml が無く、Bean アーカイブとして認識されていない",
        "同じインタフェースの実装が複数あり、@Qualifier や @Default/@Alternative で絞れていない",
        "javax.* と jakarta.* のアノテーションが混在している",
        "@Produces メソッドの戻り型が注入点の型と一致していない",
    ],
    [
        "ログの WELD-XXXXXX 番号と \"Unsatisfied/Ambiguous dependencies for type ... with qualifiers ...\" 行を読む",
        "docker exec <container> sh -c 'ls <デプロイ先>/<アーカイブ>/WEB-INF/beans.xml <デプロイ先>/<アーカイブ>/WEB-INF/classes/META-INF/beans.xml'",
        "実装クラスの import が jakarta.enterprise.* になっているか確認する",
    ],
    [
        "実装クラスへスコープアノテーションを付ける (@ApplicationScoped / @RequestScoped / @Dependent)",
        "beans.xml を WEB-INF/ (または JAR の META-INF/) へ置き、必要なら bean-discovery-mode=\"all\" にする:\n"
        "  <beans xmlns=\"https://jakarta.ee/xml/ns/jakartaee\" version=\"4.0\" bean-discovery-mode=\"all\"/>",
        "候補が複数ある場合は片方へ @Alternative を付けるか、独自 @Qualifier で注入点を特定する",
        "javax.inject.* / javax.enterprise.* の import を jakarta.* へ置換する",
    ],
    [
        "CDI の Bean 定義アノテーションを必須とするコーディング規約にする",
        "Arquillian などでデプロイ検証を CI に組み込む",
    ],
    ["JBoss EAP 8.1 Development Guide - Contexts and Dependency Injection",
     "Weld Reference Guide - WELD-001408 / WELD-001409"],
))

register(["jakarta.persistence.PersistenceException",
          "org.hibernate.HibernateException",
          "org.hibernate.exception.JDBCConnectionException",
          "org.hibernate.tool.schema.spi.SchemaManagementException",
          "org.hibernate.MappingException",
          "org.hibernate.AnnotationException",
          "org.hibernate.service.spi.ServiceException"], entry(
    "JPA・Hibernate", "致命的",
    "永続化ユニット (persistence unit) の初期化に失敗しました。DB 接続・マッピング・スキーマ検証のいずれかで止まっています。",
    "EAP は persistence.xml ごとに PersistenceUnitService を作り、デプロイの一部として起動します。"
    "この中で Hibernate は (1) データソースの取得、(2) エンティティのマッピング構築、"
    "(3) hibernate.hbm2ddl.auto の設定に応じたスキーマ処理、を順に行います。"
    "どこで失敗しても永続化ユニットのサービスが failed になり、それに依存する WAR 全体のデプロイが巻き戻ります。"
    "特に validate 設定では、テーブル/カラムが 1 つでも欠けるとデプロイが失敗します。",
    [
        "persistence.xml の jta-data-source が指す JNDI 名が存在しない",
        "DB へ接続できない (Caused by に SQLException / ConnectException がある)",
        "hibernate.hbm2ddl.auto=validate でスキーマが一致していない",
        "エンティティのアノテーション不備 (@Id 無し、関連の mappedBy 誤り)",
        "方言 (dialect) が DB 製品と合っていない",
    ],
    [
        "Caused by を最後まで辿り、DB 接続系かマッピング系かを切り分ける",
        "docker exec <container> cat <デプロイ先>/<アーカイブ>/WEB-INF/classes/META-INF/persistence.xml",
        "起動ログで WFLYJPA / HHH で始まるメッセージを確認する",
        "DB 側で対象テーブルの定義を確認する",
    ],
    [
        "jta-data-source の JNDI 名を、起動ログでバインドされた実際の名前へ合わせる",
        "DB 接続が原因なら、データソース側の対処 (healthcheck 待ち・認証情報) を先に行う",
        "スキーマ不一致なら、マイグレーション (Flyway / Liquibase) を適用してから起動する",
        "開発中に限り hibernate.hbm2ddl.auto を update / none へ変更して切り分ける",
        "方言を明示する: <property name=\"hibernate.dialect\" value=\"org.hibernate.dialect.PostgreSQLDialect\"/>",
    ],
    [
        "スキーマ変更はマイグレーションツールで管理し、起動前に適用する",
        "本番相当のスキーマに対する validate を CI で実行する",
    ],
    ["JBoss EAP 8.1 Development Guide - Jakarta Persistence"],
))

register(["org.jboss.msc.service.StartException",
          "org.jboss.msc.service.DuplicateServiceException",
          "org.jboss.msc.service.ServiceNotFoundException"], entry(
    "MSC サービス起動", "致命的",
    "JBoss の内部サービスコンテナ (MSC) がサービスを起動できませんでした。包まれている実際の原因は Caused by 側にあります。",
    "JBoss EAP のデプロイは、デプロイユニットを構成する多数の MSC サービス "
    "(クラスローダー、Undertow デプロイメント、Weld、永続化ユニット等) の起動として実行されます。"
    "いずれかの start() が例外を投げると StartException で包まれ、"
    "そのサービスに依存するサービス群がすべて起動できないまま WFLYCTL0080 (Failed services) として報告され、"
    "WFLYSRV0021 でデプロイ全体が巻き戻されます。"
    "したがって StartException 自体は「入れ物」であり、対処すべきは Caused by の最終段です。",
    [
        "包まれている例外 (Caused by) が示す原因そのもの",
        "同名のサービスを二重登録している (DuplicateServiceException)",
        "依存サービスが先に失敗している (連鎖的な失敗)",
    ],
    [
        "Failed services のサービス名から、どのデプロイユニットのどの機能かを読み取る",
        "Caused by の最終段まで辿る",
        "docker exec <container> /opt/jboss-eap/bin/jboss-cli.sh --connect --command=\"/core-service=management:read-boot-errors\"",
        "docker exec <container> /opt/jboss-eap/bin/jboss-cli.sh --connect --command=\"/deployment=<アーカイブ名>:read-resource(include-runtime=true)\"",
    ],
    [
        "Caused by の根本原因に応じた対処を行う",
        "二重登録なら、重複しているデプロイ (同じ WAR が deployments 配下と CLI の両方で登録されていないか) を解消する",
    ],
    [
        "デプロイ前に read-boot-errors を確認する運用にする",
    ],
    ["JBoss EAP 8.1 - Managing Deployments"],
))

register(["org.jboss.as.server.deployment.DeploymentUnitProcessingException",
          "org.jboss.as.controller.OperationFailedException"], entry(
    "デプロイ処理", "致命的",
    "デプロイユニットの処理チェーン (アーカイブ解析・記述子読み込み・アノテーション走査など) で失敗しました。",
    "EAP はデプロイを複数フェーズの DeploymentUnitProcessor の連鎖として処理します。"
    "STRUCTURE (アーカイブ構造の把握) → PARSE (web.xml 等の記述子解析) → DEPENDENCIES (モジュール依存の解決) → "
    "CONFIGURE_MODULE → POST_MODULE (アノテーション走査) → INSTALL (MSC サービス登録) の順です。"
    "どのフェーズで落ちたかは、スタックトレース中の Processor クラス名から読み取れます。",
    [
        "web.xml / beans.xml / persistence.xml など記述子の構文エラー・スキーマ違反",
        "WAR の構造が不正 (WEB-INF が無い、壊れた ZIP)",
        "アノテーション走査中に参照クラスを解決できない",
        "jboss-deployment-structure.xml の記述誤り",
    ],
    [
        "スタックトレース中の *Processor クラス名から、失敗したフェーズを特定する",
        "docker exec <container> ls -l <デプロイ先>/ でアーカイブの配置とサイズを確認する",
        "記述子を取り出して XML の妥当性を確認する (xmllint --noout <ファイル>)",
    ],
    [
        "記述子の構文・名前空間・スキーマバージョンを修正する (EAP 8.1 は Jakarta EE 10 の名前空間 https://jakarta.ee/xml/ns/jakartaee)",
        "アーカイブが壊れている場合はビルドをやり直し、転送経路 (COPY / volume) を見直す",
        "jboss-deployment-structure.xml のモジュール名・除外指定を見直す",
    ],
    [
        "記述子を CI で XML スキーマ検証する",
    ],
    ["JBoss EAP 8.1 Development Guide - Deployment Descriptors"],
))

register(["org.xml.sax.SAXParseException", "javax.xml.stream.XMLStreamException",
          "org.xml.sax.SAXException"], entry(
    "デプロイメント記述子 (XML)", "致命的",
    "XML の解析に失敗しました。記述子ファイルの構文エラーか、スキーマ/名前空間の不一致です。",
    "メッセージには通常 lineNumber と columnNumber が含まれ、該当ファイルの何行目で失敗したかが分かります。"
    "EAP 8.1 は Jakarta EE 10 のスキーマを使うため、Java EE 8 時代の "
    "http://xmlns.jcp.org/xml/ns/javaee 名前空間や version=\"4.0\" の web-app は受け付けません。"
    "BOM 付き UTF-8 や、コンテナへコピーする際の CRLF 変換で壊れる例もあります。",
    [
        "タグの閉じ忘れ・属性のクォート漏れなどの構文エラー",
        "名前空間が Jakarta EE 10 (https://jakarta.ee/xml/ns/jakartaee) になっていない",
        "スキーマバージョンの指定が EAP のサポート範囲外",
        "ファイル先頭に BOM が付いている / 文字コードが宣言と違う",
    ],
    [
        "エラーメッセージの行番号・列番号を確認する",
        "docker exec <container> cat -A <記述子のパス> | head で BOM や CR を確認する",
        "xmllint --noout <記述子> でローカル検証する",
    ],
    [
        "指摘された行を修正する",
        "web.xml を Jakarta EE 10 の形式へ更新する:\n"
        "  <web-app xmlns=\"https://jakarta.ee/xml/ns/jakartaee\"\n"
        "           xsi:schemaLocation=\"https://jakarta.ee/xml/ns/jakartaee https://jakarta.ee/xml/ns/jakartaee/web-app_6_0.xsd\"\n"
        "           version=\"6.0\">",
        "BOM を除去し、ファイルを UTF-8 (BOM 無し) / LF で保存する",
    ],
    [
        "記述子を CI で XML スキーマ検証する",
        ".gitattributes で XML ファイルの改行コードを LF に固定する",
    ],
    ["Jakarta EE 10 Schemas"],
))

register(["jakarta.servlet.ServletException", "jakarta.servlet.UnavailableException",
          "javax.servlet.ServletException"], entry(
    "Servlet・Web 層", "重大",
    "サーブレット/フィルタ/リスナーの初期化または処理で例外が発生しました。デプロイ時なら init() 系の失敗です。",
    "Undertow はデプロイの最終段でサーブレットコンテキストを起動し、"
    "load-on-startup 指定のサーブレットや ServletContextListener の contextInitialized() を実行します。"
    "ここで例外が出ると Web デプロイメントの MSC サービスが failed となり、"
    "WFLYUT0021 (Registered web context) が出ないまま巻き戻されます。"
    "起動ログに WFLYUT0021 が無いことが、Web 層で止まった証拠になります。",
    [
        "ServletContextListener / @WebListener の初期化処理が例外を投げた",
        "load-on-startup サーブレットの init() が失敗した",
        "フレームワーク (JSF / JAX-RS) の初期化で設定不足がある",
        "javax.servlet.* と jakarta.servlet.* の混在",
    ],
    [
        "起動ログに WFLYUT0021 (Registered web context) が出ているか確認する",
        "Caused by の最終段を確認する",
        "docker exec <container> cat <デプロイ先>/<アーカイブ>/WEB-INF/web.xml",
    ],
    [
        "Caused by の根本原因に応じて対処する",
        "javax.servlet.* の import を jakarta.servlet.* へ置換する (EAP 8.1 は Jakarta EE 10)",
        "初期化順序に依存する処理は、@WebListener の代わりに CDI の @Observes @Initialized(ApplicationScoped.class) を使う",
    ],
    [
        "初期化処理は失敗時に原因を明示するログを出す",
    ],
    ["JBoss EAP 8.1 Development Guide - Jakarta Servlet"],
))

register(["java.lang.OutOfMemoryError"], entry(
    "メモリ・リソース", "致命的",
    "JVM がメモリを確保できませんでした。ヒープ・Metaspace・ネイティブスレッドのどれが枯渇したかで対処が変わります。",
    "メッセージの後半が枯渇した領域を示します。"
    "\"Java heap space\" はヒープ、\"Metaspace\" はクラスメタデータ領域、"
    "\"unable to create native thread\" はスレッド数/メモリ上限、"
    "\"Direct buffer memory\" は NIO のダイレクトバッファです。"
    "コンテナでは、コンテナのメモリ上限 (compose の deploy.resources.limits.memory / mem_limit) と"
    "JVM の最大ヒープの関係が重要で、JVM は既定でコンテナ上限の 25% しかヒープに使いません。"
    "デプロイ時の OOM は、多数のクラスをロードする Metaspace 枯渇が典型です。",
    [
        "コンテナのメモリ上限が小さすぎる",
        "-Xmx / -XX:MaxMetaspaceSize が実態に合っていない",
        "大量のクラスを持つライブラリを同梱しており Metaspace が不足",
        "スレッドプールの設定が過大で native thread を作れない",
    ],
    [
        "docker stats <container> でメモリ使用量と上限を確認する",
        "docker exec <container> sh -c 'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes'",
        "本スクリプトの JVM パラメータ一覧で -Xmx / -XX:MaxMetaspaceSize / -XX:MaxRAMPercentage を確認する",
        "docker exec <container> sh -c 'jcmd 1 GC.heap_info'",
    ],
    [
        "compose.yml のメモリ上限を引き上げる",
        "コンテナ上限に追随させる: JAVA_OPTS_APPEND=\"-XX:MaxRAMPercentage=75.0\"",
        "Metaspace 枯渇なら: JAVA_OPTS_APPEND=\"-XX:MaxMetaspaceSize=512m\"",
        "ヒープダンプを取得して原因を特定する: -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp",
        "不要な同梱ライブラリを削り、ロードするクラス数を減らす",
    ],
    [
        "コンテナのメモリ上限と JVM 設定を必ずセットで管理する",
        "起動時の JVM パラメータをレポートで確認する運用にする",
    ],
    ["JBoss EAP 8.1 Performance Tuning Guide"],
))

register(["java.lang.StackOverflowError"], entry(
    "メモリ・リソース", "致命的",
    "スタックが溢れました。無限再帰か、極端に深い呼び出しが起きています。",
    "同じメソッド群がスタックトレース中で繰り返し現れていれば再帰、"
    "そうでなければスレッドスタックサイズ (-Xss) の不足です。"
    "デプロイ時は、相互参照する CDI Bean の初期化や、循環する JPA 関連の解決で起きることがあります。",
    [
        "循環参照によるコンストラクタ/初期化の無限再帰",
        "toString() / equals() の相互呼び出し",
        "-Xss が小さすぎる",
    ],
    [
        "スタックトレース中で繰り返されているメソッドの並びを特定する",
        "本スクリプトの JVM パラメータ一覧で -Xss の値を確認する",
    ],
    [
        "循環参照を解消する (遅延注入 Provider<T> / @Inject Instance<T> を使う)",
        "再帰の終了条件を修正する",
        "深い呼び出しが正当なら JAVA_OPTS_APPEND=\"-Xss1m\" などで拡張する",
    ],
    [
        "循環依存を検出する静的解析を CI に入れる",
    ],
    ["Java Troubleshooting Guide - StackOverflowError"],
))

register(["java.io.FileNotFoundException", "java.nio.file.NoSuchFileException"], entry(
    "ファイル・権限", "重大",
    "ファイルを開けませんでした。パスが存在しないか、読み書きの権限がありません。",
    "メッセージ末尾の括弧内が決め手です。\"(No such file or directory)\" はパスの誤りかコピー漏れ、"
    "\"(Permission denied)\" は権限不足です。"
    "コンテナでは、Dockerfile の COPY 漏れ、bind mount 先の不一致、"
    "および OpenShift/EAP イメージが非 root (jboss ユーザ、任意 UID) で動くことによる権限不足が典型です。"
    "存在しないホストパスを bind mount すると Docker が空ディレクトリを作るため、"
    "「ディレクトリはあるがファイルが無い」状態にもなります。",
    [
        "Dockerfile の COPY 対象漏れ・パスの綴り違い",
        "compose.yml の volumes で指定したホスト側パスが存在しない",
        "非 root ユーザで動作しており、対象ファイル/ディレクトリに権限が無い",
        "相対パスで開いており、作業ディレクトリが想定と違う",
    ],
    [
        "docker exec <container> ls -l <対象パス> で存在と権限を確認する",
        "docker exec <container> id で実行ユーザを確認する",
        "docker inspect -f '{{ json .Mounts }}' <container> でマウント状況を確認する",
        "docker exec <container> pwd -P で作業ディレクトリを確認する",
    ],
    [
        "Dockerfile へ COPY を追加する、または compose.yml のホスト側パスを実在するものへ直す",
        "権限を付与する: RUN chown -R jboss:root <パス> && chmod -R g+rw <パス>",
        "任意 UID で動く前提なら、グループ root へ書き込み権限を付ける (OpenShift の慣例)",
        "ファイルパスは絶対パスか、環境変数で明示的に与える",
        "本スクリプトの --copy-file で、ビルド時だけ必要なファイルを一時配置する",
    ],
    [
        "必要なファイルの存在確認をイメージビルド時 (RUN test -f ...) に入れる",
        "本スクリプトのコンテナ内ディレクトリツリー出力で配置を確認する",
    ],
    ["JBoss EAP 8.1 - Running as a non-root user"],
))

register(["java.nio.file.AccessDeniedException", "java.security.AccessControlException"], entry(
    "ファイル・権限", "重大",
    "アクセスが拒否されました。OS の権限、または Java のセキュリティポリシーで拒否されています。",
    "コンテナ内の EAP は通常 jboss ユーザ (UID 185) で動作します。"
    "root で作成したファイルや、ホストからマウントしたディレクトリの所有者が合わないと書き込めません。"
    "SELinux 有効ホストでは、bind mount に :z / :Z を付けないとアクセスを拒否されることがあります。",
    [
        "対象ディレクトリの所有者/パーミッションが実行ユーザと合っていない",
        "SELinux のラベル不一致 (RHEL ホストで頻出)",
        "読み取り専用マウント (:ro) へ書き込もうとしている",
    ],
    [
        "docker exec <container> id と ls -ln <対象パス> を突き合わせる",
        "compose.yml の volumes に :z / :Z / :ro が付いているか確認する",
        "ホスト側で ls -lZ <パス> を実行し SELinux ラベルを確認する",
    ],
    [
        "Dockerfile で所有権を合わせる: RUN chown -R jboss:root <パス> && chmod -R g+rwX <パス>",
        "SELinux 環境では volumes へ :z (共有) または :Z (専有) を付ける",
        "書き込みが必要なパスを :ro でマウントしない",
    ],
    [
        "書き込み先はコンテナ内の専用ディレクトリか名前付きボリュームにする",
    ],
    ["Docker - Configure the SELinux label"],
))

register(["java.lang.NullPointerException"], entry(
    "アプリケーション実装", "重大",
    "null の参照に対して操作を行いました。デプロイ時なら、初期化前の値や未設定の設定値を使っている可能性が高いです。",
    "Java 14 以降の Helpful NullPointerException により、メッセージには "
    "\"Cannot invoke \\\"X.y()\\\" because \\\"z\\\" is null\" のように、どの参照が null かが具体的に記載されます。"
    "EAP 8.1 のサポート JDK ではこの機能が既定で有効なので、メッセージをそのまま読むのが最短です。"
    "デプロイ時の NPE は、注入がまだ完了していないフィールドをコンストラクタで使う、"
    "環境変数から取得した値が null のまま使われる、というパターンが大半です。",
    [
        "@Inject / @Resource のフィールドをコンストラクタや static 初期化子で使っている",
        "System.getenv(...) / getProperty(...) の戻り値が null のまま使われている",
        "設定ファイルの読み込みに失敗し、戻り値が null になっている",
        "外部呼び出しの結果 (Optional にしていない) が null",
    ],
    [
        "メッセージの \"because ... is null\" 部分で null の対象を特定する",
        "スタックトレースの最上位にあるアプリケーションのクラス/行番号を見る",
        "docker exec <container> env | sort で参照している環境変数の有無を確認する",
    ],
    [
        "注入されたフィールドを使う処理は @PostConstruct へ移す (コンストラクタでは未注入)",
        "環境変数の既定値を用意し、必須なら起動時に検証して明示的なメッセージで失敗させる",
        "null を返しうる API は Optional で受けるか、null チェックを入れる",
    ],
    [
        "必須設定値のバリデーションを起動処理の先頭に置く",
        "静的解析 (SpotBugs / ErrorProne) で null 到達を検出する",
    ],
    ["Java - Helpful NullPointerExceptions (JEP 358)"],
))

register(["java.lang.IllegalStateException", "java.lang.IllegalArgumentException",
          "java.lang.UnsupportedOperationException"], entry(
    "アプリケーション実装", "重大",
    "呼び出しの前提条件が満たされていません。設定値の不正か、ライフサイクルに合わない呼び出しです。",
    "フレームワークは前提条件違反をこれらの例外で通知します。デプロイ時に出る場合は、"
    "設定値のフォーマット不正 (数値のはずが文字列、URL の書式違反)、"
    "またはコンテナのライフサイクル上まだ利用できない機能を呼び出している状態です。"
    "メッセージ本文が最も具体的な手掛かりになります。",
    [
        "環境変数/システムプロパティの値が想定の書式でない",
        "初期化前のコンポーネントを呼び出している",
        "同じリソースを二重に登録している",
    ],
    [
        "例外メッセージ本文をそのまま読む (対象の設定名が書かれていることが多い)",
        "スタックトレースの最上位のアプリケーションクラスを特定する",
        "docker exec <container> env | sort と本スクリプトの JVM パラメータ一覧で値を確認する",
    ],
    [
        "設定値を正しい書式へ修正する",
        "初期化順序に依存する処理を @PostConstruct や起動イベントへ移す",
        "重複登録している定義 (web.xml とアノテーションの二重定義など) を一方に寄せる",
    ],
    [
        "設定値のバリデーションを起動時に行う",
    ],
    ["JBoss EAP 8.1 Development Guide"],
))

register(["java.lang.NumberFormatException"], entry(
    "設定値", "重大",
    "数値として解釈できない文字列を数値へ変換しようとしました。設定値の未設定・書式違いが原因です。",
    "Integer.parseInt(null) は NumberFormatException: null となるため、"
    "「環境変数が未設定」がそのままこの例外として現れます。"
    "compose.yml で ${VAR} を使いつつホスト側に定義が無い場合、空文字が渡って同じ結果になります。"
    "単位付きの値 (\"30s\"、\"512m\") をそのまま parseInt している場合も該当します。",
    [
        "環境変数が未設定で null / 空文字が渡っている",
        "単位付きの文字列を数値として解釈しようとしている",
        "全角数字・空白・カンマ区切りが混ざっている",
    ],
    [
        "例外メッセージの入力値 (For input string: \"...\") を確認する",
        "docker exec <container> env | grep <該当の環境変数名>",
        "compose.yml の environment で既定値付き展開 ${VAR:-既定値} になっているか確認する",
    ],
    [
        "compose.yml で既定値を与える: MY_TIMEOUT: \"${MY_TIMEOUT:-30}\"",
        "アプリ側で未設定時の既定値と、書式チェックを実装する",
        "単位付きの値は専用のパーサ (Duration.parse など) で扱う",
    ],
    [
        "必須の環境変数を一覧化し、起動時に検証する",
    ],
    ["Docker Compose - Environment variables"],
))

register(["java.lang.ClassCastException"], entry(
    "クラスロード・依存関係", "重大",
    "型変換に失敗しました。同じ名前のクラスが別のクラスローダーから 2 つロードされている可能性があります。",
    "メッセージが \"class X cannot be cast to class X\" のように同じクラス名で出る場合は、"
    "クラスローダーが異なる 2 つの同名クラスが存在する状態です。"
    "JBoss EAP では、同じ JAR が WAR 内 (WEB-INF/lib) と EAP モジュールの双方にあるとこれが起きます。"
    "メッセージ末尾に括弧でクラスローダー名が併記されるため、そこで判別できます。",
    [
        "同一クラスが複数のクラスローダーからロードされている",
        "実装クラスの取り違え (設定で指定したクラス名が想定の型でない)",
        "ジェネリクスの型消去により、実行時に想定外の型が入っている",
    ],
    [
        "メッセージ末尾の括弧内のクラスローダー名を比較する",
        "docker exec <container> ls <デプロイ先>/<アーカイブ>/WEB-INF/lib で重複 JAR を探す",
        "-verbose:class を付けて起動し、ロード元を確認する",
    ],
    [
        "WAR 同梱と EAP モジュールの重複を解消する (どちらか一方にする)",
        "jboss-deployment-structure.xml で該当モジュールを除外する、または <local-last value=\"true\"/> を設定する",
        "設定で指定するクラス名を正しい実装へ修正する",
    ],
    [
        "WEB-INF/lib の内容を CI で検証し、EAP 提供ライブラリの重複を禁止する",
    ],
    ["JBoss EAP 8.1 Development Guide - Class Loading"],
))

register(["java.lang.UnsatisfiedLinkError"], entry(
    "ネイティブライブラリ", "致命的",
    "ネイティブライブラリ (.so) をロードできませんでした。ファイルが無いか、アーキテクチャが合っていません。",
    "System.loadLibrary は java.library.path とシステムのライブラリ検索パスから .so を探します。"
    "コンテナでは、ベースイメージに必要な OS パッケージが入っていない、"
    "あるいはビルドホスト (arm64 の Apple Silicon 等) と実行環境 (amd64) でアーキテクチャが異なるのが典型です。",
    [
        "必要な OS パッケージ (glibc 以外の共有ライブラリ) がイメージに入っていない",
        "イメージのアーキテクチャが実行環境と異なる",
        "java.library.path に配置先が含まれていない",
    ],
    [
        "docker exec <container> sh -c 'ldd <ライブラリのパス>' で不足している依存を確認する",
        "docker image inspect --format '{{.Architecture}}' <イメージ> を確認する",
        "docker exec <container> sh -c 'echo $LD_LIBRARY_PATH'",
    ],
    [
        "Dockerfile へ必要なパッケージを追加する (RUN dnf install -y <パッケージ>)",
        "マルチアーキテクチャでビルドする、または --platform linux/amd64 を指定する",
        "JAVA_OPTS_APPEND=\"-Djava.library.path=/usr/lib64:/opt/native\" で検索パスを追加する",
    ],
    [
        "イメージのアーキテクチャをビルドパイプラインで固定する",
    ],
    ["Docker - Multi-platform images"],
))

register(["org.wildfly.security.credential.store.CredentialStoreException",
          "org.wildfly.security.auth.server.RealmUnavailableException",
          "java.security.UnrecoverableKeyException"], entry(
    "セキュリティ・認証情報", "致命的",
    "Elytron の資格情報ストアやセキュリティレルムを利用できませんでした。マスターパスワードやキーストアの不一致が原因です。",
    "EAP 8.1 は Elytron の CredentialStore にパスワード等を保管し、standalone.xml からは "
    "credential-reference で参照します。ストアを開くにはマスターパスワードが必要で、"
    "ビルド時に注入した値と実行時に渡される値が 1 バイトでも違うと開けません。"
    "$ や \" を含むパスワードは、compose の変数展開 / XML エスケープ / WildFly の式解決 (${...}) の"
    "いずれかで壊れることがあります。",
    [
        "マスターパスワードがビルド時と実行時で一致していない",
        "パスワードに $ が含まれ、WildFly の式として解決されてしまっている",
        "資格情報ストアのファイルがイメージに含まれていない、または権限不足",
        "キーストアのパスワード/別名が違う",
    ],
    [
        "本スクリプトの --verify-jboss-password を付けて、各段での値の一致を確認する",
        "docker exec <container> ls -l <資格情報ストアのパス>",
        "docker exec <container> grep -n \"credential-reference\" /opt/jboss-eap/standalone/configuration/standalone.xml",
    ],
    [
        "本スクリプトの --verify-jboss-password で不一致の段を特定し、その段の受け渡しを修正する",
        "パスワード中の $ は jboss-cli 登録時に $$ へエスケープする",
        "資格情報ストアのファイルをイメージへ含め、jboss ユーザから読める権限にする",
    ],
    [
        "--verify-jboss-password をビルド検証の標準手順に組み込む",
    ],
    ["JBoss EAP 8.1 Security Architecture - Credential Stores"],
))

register(["java.util.MissingResourceException"], entry(
    "設定値", "重大",
    "リソースバンドル (プロパティファイル) が見つかりませんでした。配置場所かロケールの指定が原因です。",
    "ResourceBundle.getBundle(\"messages\") は、クラスパス直下の messages.properties や "
    "messages_ja.properties を探します。Maven なら src/main/resources 配下に置くと "
    "WEB-INF/classes へ入ります。ビルド設定で resources が除外されていると欠落します。",
    [
        "プロパティファイルが WEB-INF/classes に含まれていない",
        "バンドル名・パッケージ階層の指定誤り",
        "既定ロケール用のファイル (サフィックス無し) が無い",
    ],
    [
        "docker exec <container> ls <デプロイ先>/<アーカイブ>/WEB-INF/classes",
        "Maven の <resources> 設定と src/main/resources の内容を確認する",
    ],
    [
        "プロパティファイルを src/main/resources へ配置して再ビルドする",
        "既定ロケール用のファイル (例: messages.properties) を必ず用意する",
    ],
    [
        "リソースの存在確認をビルド後の検証に入れる",
    ],
    ["Java - ResourceBundle"],
))

register(["java.util.concurrent.TimeoutException", "java.net.SocketTimeoutException"], entry(
    "タイムアウト", "重大",
    "処理が制限時間内に完了しませんでした。接続先の遅延か、タイムアウト値が短すぎます。",
    "デプロイ時のタイムアウトは、外部サービスへの初期化リクエストや、"
    "DB の接続確立待ちで発生します。Compose 環境では依存サービスの初期化 (DB のスキーマ作成など) が"
    "想定より長引くと、アプリ側が先にタイムアウトします。",
    [
        "依存サービスの初期化が完了していない",
        "タイムアウト値が環境に対して短い",
        "ネットワーク経路の遅延 (プロキシ経由など)",
    ],
    [
        "docker compose logs <依存サービス> で準備完了までの所要時間を確認する",
        "本スクリプトの --startup-timeout を伸ばして再現するか確認する",
    ],
    [
        "compose.yml の healthcheck の start_period / interval を実態に合わせる",
        "アプリ側のタイムアウト値を環境変数で調整可能にする",
        "本スクリプトの --wait-healthy と --startup-timeout を併用する",
    ],
    [
        "依存サービスの起動所要時間を計測し、余裕を持った設定値にする",
    ],
    ["Docker Compose - healthcheck"],
))


# メッセージ本文で追加の具体策が言えるケース。
MESSAGE_HINTS = [
    (r"Metaspace",
     "枯渇したのは Metaspace (クラスメタデータ領域) です。ヒープではなくクラスの多さが原因です。",
     ["JAVA_OPTS_APPEND=\"-XX:MaxMetaspaceSize=512m\" を設定し、コンテナのメモリ上限もあわせて引き上げる",
      "同梱ライブラリを削減し、ロードするクラス数を減らす"]),
    (r"Java heap space",
     "枯渇したのは Java ヒープです。デプロイ時にヒープを大量に使う処理 (大きなデータの読み込み等) を疑います。",
     ["JAVA_OPTS_APPEND=\"-XX:MaxRAMPercentage=75.0\" でコンテナ上限に追随させる",
      "compose.yml のメモリ上限を引き上げる",
      "-XX:+HeapDumpOnOutOfMemoryError でヒープダンプを取得して原因を特定する"]),
    (r"unable to create (?:new )?native thread",
     "スレッドを新規作成できませんでした。スレッド数上限かメモリ上限に達しています。",
     ["compose.yml の pids_limit / メモリ上限を引き上げる",
      "スレッドプールの最大数を見直す"]),
    (r"Direct buffer memory",
     "NIO のダイレクトバッファが枯渇しました。",
     ["JAVA_OPTS_APPEND=\"-XX:MaxDirectMemorySize=256m\" を設定する"]),
    (r"Connection refused",
     "TCP 接続が明確に拒否されました (名前解決までは成功しています)。相手プロセスがそのポートで待ち受けていません。",
     ["接続先サービスのログで、待ち受け開始の時刻と例外の発生時刻を突き合わせる"]),
    (r"Access denied for user|password authentication failed|invalid authorization|"
     r"ORA-01017|28P01|1045",
     "DB の認証に失敗しています。ユーザ名/パスワードが届いていないか、値が壊れています。",
     ["環境変数の値を docker exec <container> env で確認する",
      "パスワードに $ が含まれる場合、compose.yml では $$ にエスケープする",
      "本スクリプトの --verify-jboss-password で受け渡し経路の各段を検証する"]),
    (r"database .* does not exist|Unknown database",
     "接続先の DB (スキーマ) がまだ作成されていません。",
     ["DB コンテナの初期化スクリプト (docker-entrypoint-initdb.d) で作成する",
      "DB の healthcheck を「対象 DB へ接続できること」まで含めて定義する"]),
    (r"Permission denied",
     "OS の権限で拒否されています。コンテナの実行ユーザと対象パスの所有者を突き合わせます。",
     ["docker exec <container> id と ls -l <対象パス> を比較する",
      "Dockerfile で chown -R jboss:root <パス> && chmod -R g+rwX <パス> を行う"]),
    (r"No space left on device",
     "ディスク容量が不足しています。",
     ["docker system df で使用量を確認し、不要なイメージ/ボリュームを削除する",
      "本スクリプトの --cleanup-all-docker-data で環境をリセットする (削除対象を確認のうえ実行)"]),
    (r"class file version (\d+)\.\d+",
     "クラスファイルのバージョンが実行 JVM の対応範囲を超えています。",
     ["ランタイムの JDK をビルドと同じメジャーバージョンへ揃える",
      "または Maven の <maven.compiler.release> を実行環境の JDK に合わせる"]),
    (r"WELD-001408|Unsatisfied dependencies",
     "CDI の注入候補が 1 つも見つかりませんでした (WELD-001408)。ログ中の \"for type ... with qualifiers ...\" が、"
     "解決できなかった型と修飾子そのものです。",
     ["ログに出ている型名で WAR 内を検索し、実装クラスが同梱されているかを確かめる"]),
    (r"WELD-001409|Ambiguous dependencies",
     "CDI の注入候補が複数見つかりました (WELD-001409)。ログに候補 Bean が列挙されています。",
     ["ログに列挙された候補のうち、どれを使うかを決めてから @Alternative / @Qualifier で選別する"]),
    (r"Address already in use",
     "そのポートはすでに使用中です。",
     ["JAVA_OPTS_APPEND=\"-Djboss.socket.binding.port-offset=100\" でポートをずらす",
      "重複起動しているプロセスを停止する"]),
    (r"unable to find valid certification path",
     "サーバ証明書を検証できるルート CA がトラストストアにありません。",
     ["CA 証明書を keytool -importcert -cacerts でイメージへ登録する",
      "OS のトラストストアへ入れる場合は update-ca-trust extract も実行する"]),
    (r"javax\.(servlet|inject|enterprise|persistence|ws\.rs|annotation)",
     "javax.* 名前空間を参照しています。JBoss EAP 8.1 は Jakarta EE 10 のため jakarta.* が正です。",
     ["import と依存ライブラリを jakarta.* 対応版へ移行する",
      "移行できないライブラリは Eclipse Transformer で変換する"]),
]


def lookup_knowledge(chain_classes):
    """例外クラス群 (根本原因を優先) から知識ベースの項目を選ぶ。"""
    for klass in chain_classes:
        if not klass:
            continue
        if klass in KNOWLEDGE:
            return klass, KNOWLEDGE[klass]
    # 単純名での一致 (パッケージが異なる同名例外)
    for klass in chain_classes:
        if not klass:
            continue
        simple = klass.rsplit(".", 1)[-1]
        for known, data in KNOWLEDGE.items():
            if known.rsplit(".", 1)[-1] == simple:
                return klass, data
    for klass in chain_classes:
        if klass and klass.endswith("Error"):
            return klass, GENERIC_ERROR
    for klass in chain_classes:
        if klass:
            return klass, GENERIC_EXCEPTION
    return "", GENERIC_EXCEPTION


JAVA_CLASS_FILE_VERSIONS = {
    "45": "1.1", "46": "1.2", "47": "1.3", "48": "1.4", "49": "5", "50": "6",
    "51": "7", "52": "8", "53": "9", "54": "10", "55": "11", "56": "12",
    "57": "13", "58": "14", "59": "15", "60": "16", "61": "17", "62": "18",
    "63": "19", "64": "20", "65": "21", "66": "22", "67": "23", "68": "24",
}


def extract_facts(event):
    """例外の種類に応じて、ログから具体的な値を取り出す。"""
    facts = []
    root = event.root()
    root_class = root.klass if root else ""
    root_message = root.message if root else ""
    simple = root_class.rsplit(".", 1)[-1] if root_class else ""
    block_text = event_text(event)

    if simple in ("ClassNotFoundException", "NoClassDefFoundError"):
        candidate = root_message.strip().split()[0] if root_message.strip() else ""
        candidate = candidate.replace("/", ".").strip(":;")
        if candidate:
            facts.append(("見つからないクラス", candidate))
            package = candidate.rsplit(".", 1)[0] if "." in candidate else ""
            if package:
                facts.append(("所属パッケージ", package))
                facts.append(("推定される提供元",
                              "自社パッケージであれば WAR への同梱漏れ、外部パッケージであれば依存 JAR の不足"
                              if not package.startswith(PLATFORM_PACKAGE_PREFIXES)
                              else "基盤側 (Jakarta EE / EAP) のクラス。モジュール依存の宣言漏れが疑わしい"))
    if simple in ("NoSuchMethodError", "NoSuchFieldError"):
        if root_message:
            facts.append(("解決できなかったシグネチャ", root_message.strip()))
            owner = root_message.strip().split(".")
            if len(owner) > 1:
                facts.append(("対象クラス", ".".join(owner[:-1]).split("(")[0]))
    if simple == "UnsupportedClassVersionError":
        found = re.search(r"class file version (\d+)\.", root_message)
        if found:
            major = found.group(1)
            facts.append(("クラスファイルのバージョン",
                          "%s (Java %s 相当)" % (major, JAVA_CLASS_FILE_VERSIONS.get(major, "不明"))))
        supported = re.search(r"up to (\d+)\.", root_message)
        if supported:
            major = supported.group(1)
            facts.append(("実行中 JVM の上限",
                          "%s (Java %s 相当)" % (major, JAVA_CLASS_FILE_VERSIONS.get(major, "不明"))))
    if simple in ("NameNotFoundException", "NamingException"):
        found = re.search(r"([\w:./$-]*java:[\w:./$-]+)", root_message + " " + block_text)
        if found:
            facts.append(("引けなかった JNDI 名", found.group(1)))
    if simple in ("ModuleNotFoundException", "ModuleLoadException"):
        found = re.search(r"([\w.\-]+):([\w.\-]+)", root_message)
        if found:
            facts.append(("見つからないモジュール", found.group(0)))
        elif root_message:
            facts.append(("見つからないモジュール", root_message.strip()))
    if simple in ("UnknownHostException",):
        if root_message:
            facts.append(("解決できないホスト名", root_message.strip().split(":")[0]))
    if simple in ("ConnectException", "SocketTimeoutException", "NoRouteToHostException"):
        target = find_connect_target(block_text)
        if target:
            facts.append(("接続先", target))
    if simple == "OutOfMemoryError":
        facts.append(("枯渇した領域", root_message.strip() or "(メッセージなし)"))
    if "SQL" in simple or simple.endswith("PSQLException"):
        state = re.search(r"SQLState:?\s*[:=]?\s*\"?([0-9A-Za-z]{5})\"?", block_text)
        if state:
            facts.append(("SQLState", state.group(1)))
        code = re.search(r"ErrorCode:?\s*[:=]?\s*(-?\d+)", block_text)
        if code and code.group(1) != "0":
            facts.append(("ベンダーエラーコード", code.group(1)))
    if simple in ("SAXParseException", "SAXException", "XMLStreamException"):
        position = re.search(r"lineNumber:\s*(\d+);\s*columnNumber:\s*(\d+)", block_text)
        if not position:
            position = re.search(r"\[row,col[^\]]*\]:\s*\[(\d+),(\d+)\]", block_text)
        if position:
            facts.append(("XML の該当位置", "%s 行 %s 列" % (position.group(1), position.group(2))))
        descriptor = find_descriptor_file(block_text)
        if descriptor:
            facts.append(("対象ファイル (推定)", descriptor))
    if simple == "BindException":
        found = re.search(r"(\d{2,5})", block_text)
        if found:
            facts.append(("確保できなかったポート (推定)", found.group(1)))

    if event.deployment:
        facts.append(("対象デプロイユニット", event.deployment))
    return facts


def merge_fixes(base_fixes, hints):
    """知識ベースの対処と、ログ固有の追加所見の対処を、重複を除いて連結する。"""
    merged = list(base_fixes)
    seen = set(normalize_fix(item) for item in merged)
    for _summary, extra in hints:
        for item in extra:
            key = normalize_fix(item)
            if key in seen:
                continue
            seen.add(key)
            merged.append(item)
    return merged


def normalize_fix(text):
    return re.sub(r"[\s　]+", "", str(text))[:24]


# "ホスト:ポート" の誤検出を避けるために除外する拡張子。スタックフレームの
# "(Pool.java:88)" や記述子名がホスト名として拾われるのを防ぐ。
NON_HOST_SUFFIXES = (".java", ".kt", ".scala", ".groovy", ".jsp", ".xml", ".class")
HOST_PORT_RE = re.compile(r"(?<![\w.:\-])([A-Za-z][\w.\-]*)[:/](\d{1,5})(?![\d.:])")


def find_connect_target(text):
    """接続エラーの本文から "ホスト:ポート" を取り出す。

    ログ行の時刻 (09:17:41) やスタックフレームの行番号 (Pool.java:88) を
    接続先と取り違えないよう、ホスト側の形と後続文字で絞り込む。
    """
    for match in HOST_PORT_RE.finditer(text):
        host, port = match.group(1), match.group(2)
        if host.lower().endswith(NON_HOST_SUFFIXES):
            continue
        if text[match.end():match.end() + 1] == ")":
            continue
        if not 1 <= int(port) <= 65535:
            continue
        return "%s:%s" % (host, port)
    return ""


# デプロイメント記述子として扱う既知のファイル名。org.xml.sax.SAXParseException の
# ようなクラス名を「.xml のファイル」と誤検出しないよう、名前で絞り込む。
KNOWN_DESCRIPTOR_NAMES = (
    "web.xml", "beans.xml", "persistence.xml", "ejb-jar.xml", "application.xml",
    "jboss-web.xml", "jboss-ejb3.xml", "jboss-deployment-structure.xml",
    "jboss-app.xml", "faces-config.xml", "webservices.xml", "ra.xml",
    "standalone.xml", "module.xml", "pom.xml", "validation.xml",
)


def find_descriptor_file(text):
    """XML 解析エラーの本文から、対象となった記述子ファイル名を取り出す。"""
    for candidate in re.findall(r"[\w.\-/]+\.xml", text):
        basename = candidate.rsplit("/", 1)[-1]
        if basename in KNOWN_DESCRIPTOR_NAMES:
            return candidate
    # 既知の名前に一致しなくても、パス表記であればファイルとみなす。
    for candidate in re.findall(r"/[\w.\-/]+\.xml", text):
        return candidate
    return ""


def matched_hints(event):
    block_text = event_text(event)
    hints = []
    for pattern, summary, fixes in MESSAGE_HINTS:
        if re.search(pattern, block_text, re.IGNORECASE):
            hints.append((summary, fixes))
    return hints


WFLY_CODE_NOTES = {
    "WFLYSRV0025": "サーバーが正常に起動しました。",
    "WFLYSRV0026": "サーバーは起動しましたがエラーがあります。デプロイの一部が失敗しています。",
    "WFLYSRV0027": "デプロイの開始。この直後の例外はそのアーカイブの処理中に発生しています。",
    "WFLYSRV0010": "デプロイが正常に完了しました。",
    "WFLYSRV0021": "デプロイが巻き戻されました。同じ行の failure message が直接の理由です。",
    "WFLYSRV0056": "起動処理でエラーが発生しました。",
    "WFLYSRV0153": "デプロイの起動に失敗しました。",
    "WFLYCTL0080": "起動できなかったサービス (Failed services) の一覧です。サービス名からどの機能かが分かります。",
    "WFLYCTL0412": "必要なサービスが未インストールです。参照先の名前 (JNDI 名等) の綴りを確認します。",
    "WFLYJCA0031": "データソースの検証・デプロイに失敗しました。DB への接続を確認します。",
    "WFLYJCA0018": "JDBC ドライバが登録されました。",
    "WFLYJCA0001": "データソースが JNDI へバインドされました。ここに出る名前がアプリの参照名と一致する必要があります。",
    "WFLYJCA0098": "非トランザクションのデータソースがバインドされました。",
    "WFLYUT0006": "Undertow の HTTP リスナーが待ち受けを開始しました。",
    "WFLYUT0021": "Web コンテキストが登録されました。これが出ていない場合、Web 層の起動前に失敗しています。",
    "WFLYDS0013": "デプロイスキャナが起動しました。監視対象ディレクトリが表示されます。",
    "WFLYSRV0049": "サーバーの起動を開始しました。",
    "WELD-001408": "CDI の注入候補が 0 件です。",
    "WELD-001409": "CDI の注入候補が複数あります。",
    "MSC000001": "MSC サービスの起動に失敗しました。サービス名から失敗した機能を特定できます。",
    "WFLYDR0001": "デプロイ内容がリポジトリへ登録されました。",
    "WFLYSRV0009": "デプロイが解除されました。",
    "WFLYJPA0002": "永続化ユニットの処理を開始しました。",
    "WFLYWELD0003": "CDI のデプロイ処理を開始しました。",
}


def determine_verdict(event, deploy_failed):
    level = (event.origin_line.level or "").upper()
    if event.deploy_related and level in ("ERROR", "FATAL", "SEVERE"):
        return "デプロイ失敗の原因" if deploy_failed else "デプロイ中のエラー (要対処)"
    if event.deploy_related and level in ("WARN", "WARNING"):
        return "デプロイ中の警告 (要確認)"
    if event.deploy_related:
        return "デプロイ中の例外 (要確認)"
    if level in ("ERROR", "FATAL", "SEVERE"):
        return "デプロイ外のエラー"
    return "参考 (デプロイ外)"


def one_line_summary(event):
    root = event.root()
    knowledge = event.knowledge or GENERIC_EXCEPTION
    simple = root.simple_name() if root else "(不明)"
    message = (root.message if root else "").strip()
    if len(message) > 80:
        message = message[:77] + "..."
    if message:
        return "%s: %s (%s)" % (simple, message, knowledge["category"])
    return "%s (%s)" % (simple, knowledge["category"])


# =============================================================================
# テキストレポート
# =============================================================================

def bullet_lines(items, indent="  ", marker="- "):
    out = []
    for item in items:
        parts = str(item).split("\n")
        out.append("%s%s%s" % (indent, marker, parts[0]))
        for extra in parts[1:]:
            out.append("%s%s%s" % (indent, " " * len(marker), extra))
    return out


def numbered_lines(items, indent="  "):
    out = []
    for number, item in enumerate(items, 1):
        head = "%s%d) " % (indent, number)
        parts = str(item).split("\n")
        out.append("%s%s" % (head, parts[0]))
        for extra in parts[1:]:
            out.append("%s%s" % (" " * len(head), extra))
    return out


def build_text_report(meta, events, stats, scanned_services, line_count, truncated,
                      lines=None, full=False, max_log_rows=3000):
    """解析結果のテキストを組み立てる。

    full=False : 画面と全量レポート向け。スタックトレースは先頭だけに省略する。
    full=True  : 独立したテキストファイル向け。Excel と同じ情報量にするため、
                 全スタックフレームとデプロイログまで含める。
    """
    out = []
    add = out.append
    add(HEAVY)
    add("WAR デプロイ時 Java 例外解析")
    add(HEAVY)
    add("解析日時      : %s" % meta.get("analyzed_at", ""))
    add("処理開始日時  : %s" % meta.get("run_started_at", ""))
    add("Compose 定義  : %s" % meta.get("compose_file", ""))
    add("解析対象      : %s (%d サービス)" % (" ".join(scanned_services) or "(なし)", len(scanned_services)))
    add("解析ログ行数  : %d 行" % line_count)
    if meta.get("log_status"):
        add("ログ取得状況  : %s" % meta.get("log_status", ""))
    add("検出した例外  : %d 件 (デプロイ処理中: %d 件 / デプロイ外: %d 件)"
        % (stats["total"], stats["deploy"], stats["other"]))
    if stats["by_severity"]:
        add("深刻度の内訳  : %s"
            % " / ".join("%s %d 件" % (name, count) for name, count in stats["by_severity"]))
    if stats["by_category"]:
        add("分類の内訳    : %s"
            % " / ".join("%s %d 件" % (name, count) for name, count in stats["by_category"]))
    add("総合判定      : %s" % stats["verdict"])
    if truncated:
        add("注意          : 詳細分析は上限の %d 件までです。残りは件数のみ集計しています"
            % truncated)
        add("                (--deploy-exception-limit で上限を変更できます)。")

    if not events:
        add("")
        if line_count == 0:
            # ログが無い = 解析していないことを、0 件検出と読み違えられないようにする。
            add("解析対象のログが 1 行も無いため、Java 例外の有無を判定できていません。")
            add("コンテナの起動 (compose up) に失敗した場合は、デプロイ結果ファイルの")
            add("[9] Compose サービス別ログと、compose up 自体のエラー出力を確認してください。")
        else:
            add("Java の例外スタックトレースは検出されませんでした。")
            add("デプロイ処理でスローされた例外が無いか、対象サービスのログに出力されていません。")
        # 例外が無くても、Excel の「デプロイログ」シートと内容を揃える。
        if full and lines:
            out.extend(build_log_section(lines, events, max_log_rows))
        add("")
        add(HEAVY)
        return "\n".join(out) + "\n"

    add("")
    add("読み方        : 「根本原因」= Caused by の最終段。ここが実際に直すべき対象です。")
    add("                各例外の [対処方法] は上から順に効果の高い順で並べています。")

    for number, event in enumerate(events, 1):
        knowledge = event.knowledge
        top = event.top()
        root = event.root()
        add("")
        add(RULE)
        add("[例外 %d/%d] %s" % (number, len(events), top.klass or "(クラス不明)"))
        add("  判定: %s / 深刻度: %s / 分類: %s"
            % (event.verdict, knowledge["severity"], knowledge["category"]))
        add(RULE)
        origin = event.origin_line
        add("発生日時      : %s" % (origin.timestamp() or "(不明)"))
        add("サービス      : %s%s" % (origin.service,
                                      " (コンテナ: %s)" % origin.container
                                      if origin.container else ""))
        add("デプロイ対象  : %s" % (event.deployment or "(特定できず)"))
        add("ログレベル    : %s" % (origin.level or "(不明)"))
        add("ロガー        : %s" % (origin.logger or "(不明)"))
        add("スレッド      : %s" % (origin.thread or "(不明)"))
        if origin.code:
            note = WFLY_CODE_NOTES.get(origin.code, "")
            add("EAP コード    : %s%s" % (origin.code, " - %s" % note if note else ""))
        add("例外クラス    : %s" % (top.klass or "(不明)"))
        add("例外メッセージ: %s" % (top.message or "(なし)"))
        if root is not top:
            add("根本原因      : %s" % (root.klass or "(不明)"))
            add("  メッセージ  : %s" % (root.message or "(なし)"))
        app_frame = event.app_frame(PLATFORM_PACKAGE_PREFIXES)
        add("アプリ内発生点: %s" % (app_frame or "(アプリケーション由来のフレームなし)"))
        add("連鎖の段数    : %d 段 / スタックフレーム %d 行"
            % (len(event.chain), event.frame_count()))

        add("")
        add("■ 何が起きたか")
        for line in wrap_text(knowledge["headline"], 63):
            add("  " + line)

        add("")
        add("■ 発生の仕組み (なぜこの例外になるのか)")
        for line in wrap_text(knowledge["mechanism"], 63):
            add("  " + line)

        if event.facts:
            add("")
            add("■ ログから読み取れる事実")
            width = max(display_width(label) for label, _ in event.facts)
            for label, value in event.facts:
                padding = " " * (width - display_width(label))
                add("  - %s%s : %s" % (label, padding, value))

        hints = matched_hints(event)
        if hints:
            add("")
            add("■ このログ特有の追加所見")
            for summary, _fixes in hints:
                for index, line in enumerate(wrap_text(summary, 61)):
                    add("  %s%s" % ("- " if index == 0 else "  ", line))

        if event.deploy_reasons:
            add("")
            add("■ デプロイ処理との関連 (この判定の根拠)")
            out.extend(bullet_lines(event.deploy_reasons))

        if event.related_codes:
            add("")
            add("■ 前後に出ている EAP メッセージ")
            for code in event.related_codes:
                add("  - %s: %s" % (code, WFLY_CODE_NOTES.get(code, "(説明なし)")))

        add("")
        add("■ 想定される原因 (可能性の高い順)")
        out.extend(numbered_lines(knowledge["causes"]))

        add("")
        add("■ 確認手順")
        out.extend(numbered_lines(knowledge["checks"]))

        add("")
        add("■ 対処方法")
        out.extend(numbered_lines(merge_fixes(knowledge["fixes"], hints)))

        add("")
        add("■ 再発防止")
        out.extend(bullet_lines(knowledge["prevention"]))

        if knowledge["refs"]:
            add("")
            add("■ 参考情報")
            out.extend(bullet_lines(knowledge["refs"]))

        add("")
        add("■ 例外の連鎖とスタックトレース")
        for depth, element in enumerate(event.chain):
            label = chain_label(depth, element)
            add("  [%s] %s%s" % (label, element.klass or "(不明)",
                                 ": %s" % element.message if element.message else ""))
            shown = element.frames if full else element.frames[:12]
            for frame in shown:
                add("      %s" % frame)
            if len(element.frames) > len(shown):
                add("      ... 他 %d フレーム (全文は Excel の「スタックトレース」シート、"
                    "または Java 例外解析テキストを参照)"
                    % (len(element.frames) - len(shown)))
            if element.more:
                add("      ... %d more (呼び出し元は上位の段と共通)" % element.more)

    if full and lines:
        out.extend(build_log_section(lines, events, max_log_rows))

    add("")
    add(HEAVY)
    return "\n".join(out) + "\n"


def build_log_section(lines, events, max_log_rows):
    """Excel の「デプロイログ」シートと同じ内容をテキストで出力する。"""
    out = ["", RULE, "デプロイログ (行番号 / サービス / 区分 / 本文)", RULE]
    exception_indexes, frame_indexes = exception_line_indexes(events)
    rows = []
    for line in lines:
        if len(rows) >= max_log_rows:
            break
        rows.append((line, classify_log_line(line, exception_indexes, frame_indexes)))

    if not rows:
        out.append("ログを取得できませんでした。")
        return out

    # 区分・サービス名は全角を含むため、桁揃えは表示幅で計算する。
    service_width = max(display_width(line.service) for line, _kind in rows)
    kind_width = max(display_width(kind) for _line, kind in rows)
    for line, kind in rows:
        out.append("%6d  %s%s  %s%s  %s" % (
            line.index + 1,
            line.service, " " * (service_width - display_width(line.service)),
            kind, " " * (kind_width - display_width(kind)),
            line.body,
        ))
    if len(rows) >= max_log_rows and len(lines) > len(rows):
        out.append("... 出力上限 (%d 行) に達したため、残り %d 行は省略しました。"
                   "全文はデプロイ結果ファイルを参照してください。"
                   % (max_log_rows, len(lines) - len(rows)))
    return out


def exception_line_indexes(events):
    """例外ヘッダー行と、それに続くスタックフレーム行の行番号を集める。"""
    exception_indexes = set()
    frame_indexes = set()
    for event in events:
        exception_indexes.add(event.header_line.index)
        for line in event.block_lines[1:]:
            frame_indexes.add(line.index)
    return exception_indexes, frame_indexes


def wrap_text(text, width):
    """全角を 2 幅として折り返す。ASCII の語は途中で切らない。"""
    lines = []
    for paragraph in str(text).split("\n"):
        current = ""
        current_width = 0
        for token in tokenize_for_wrap(paragraph):
            token_width = display_width(token)
            if current_width + token_width > width and current:
                lines.append(current.rstrip())
                # 行頭に空白だけのトークンが残らないようにする。
                if not token.strip():
                    current = ""
                    current_width = 0
                    continue
                current = token
                current_width = token_width
                continue
            current += token
            current_width += token_width
        lines.append(current.rstrip())
    return lines or [""]


def tokenize_for_wrap(text):
    """ASCII の語・空白はひとまとまり、全角文字は 1 文字ずつのトークンにする。"""
    tokens = []
    buffer = ""
    for char in text:
        if east_asian_wide(char):
            if buffer:
                tokens.append(buffer)
                buffer = ""
            tokens.append(char)
        elif char == " ":
            if buffer:
                tokens.append(buffer)
                buffer = ""
            tokens.append(char)
        else:
            buffer += char
    if buffer:
        tokens.append(buffer)
    return tokens


def display_width(text):
    return sum(2 if east_asian_wide(char) else 1 for char in text)


def east_asian_wide(char):
    code = ord(char)
    return (
        0x1100 <= code <= 0x115F or 0x2E80 <= code <= 0xA4CF or
        0xAC00 <= code <= 0xD7A3 or 0xF900 <= code <= 0xFAFF or
        0xFE30 <= code <= 0xFE6F or 0xFF00 <= code <= 0xFF60 or
        0xFFE0 <= code <= 0xFFE6 or 0x20000 <= code <= 0x3FFFD
    )


# =============================================================================
# xlsx 出力 (標準ライブラリのみ)
# =============================================================================

XML_INVALID_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
CELL_LIMIT = 32000


def xml_escape(text):
    text = XML_INVALID_RE.sub("", str(text))
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return text.replace("\"", "&quot;")


def column_name(index):
    """0 起点の列番号を A, B, ... AA へ変換する。"""
    name = ""
    index += 1
    while index > 0:
        index, remainder = divmod(index - 1, 26)
        name = chr(ord("A") + remainder) + name
    return name


class Cell(object):
    __slots__ = ("value", "style", "numeric")

    def __init__(self, value, style=0, numeric=False):
        self.value = value
        self.style = style
        self.numeric = numeric


class Sheet(object):
    def __init__(self, name, widths=None, freeze_rows=0, autofilter_row=0, autofilter_cols=0):
        self.name = name
        self.widths = widths or []
        self.freeze_rows = freeze_rows
        self.autofilter_row = autofilter_row
        self.autofilter_cols = autofilter_cols
        self.rows = []
        self.merges = []          # (行番号, 開始列, 終了列)

    def add(self, cells):
        self.rows.append(cells)

    def add_notice(self, message, style=None):
        """全列を結合した 1 行のお知らせを追加する (狭い列で縦長にならないように)。"""
        span = max(len(self.widths), 1)
        self.add([Cell(message, S_BODY if style is None else style)]
                 + [Cell("", S_BODY) for _ in range(span - 1)])
        self.merges.append((len(self.rows), 0, span - 1))

    def merged_width(self, row_number):
        """結合行の実効的な列幅 (結合した列の幅の合計) を返す。結合が無ければ None。"""
        for number, start, end in self.merges:
            if number == row_number:
                return sum(float(self.widths[index])
                           for index in range(start, min(end + 1, len(self.widths))))
        return None


# スタイル番号 (styles.xml の cellXfs の並びと一致させる)
S_DEFAULT = 0
S_TITLE = 1
S_HEADER = 2
S_BODY = 3
S_LABEL = 4
S_FATAL = 5
S_MAJOR = 6
S_WARN = 7
S_MONO = 8
S_CENTER = 9
S_SECTION = 10
S_OK = 11

SEVERITY_STYLE = {"致命的": S_FATAL, "重大": S_MAJOR, "警告": S_WARN, "情報": S_BODY}

STYLES_XML = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="0"/>
<fonts count="8">
<font><sz val="11"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="16"/><color rgb="FF1F3864"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FF9C0006"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FF9C5700"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><sz val="10"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="12"/><color rgb="FF1F3864"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FF006100"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
</fonts>
<fills count="8">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF1F3864"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFFC7CE"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFFEB9C"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFC6EFCE"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="2">
<border><left/><right/><top/><bottom/><diagonal/></border>
<border>
<left style="thin"><color rgb="FFBFBFBF"/></left>
<right style="thin"><color rgb="FFBFBFBF"/></right>
<top style="thin"><color rgb="FFBFBFBF"/></top>
<bottom style="thin"><color rgb="FFBFBFBF"/></bottom>
<diagonal/></border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="12">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="6" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="3" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="4" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="5" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="6" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="7" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top" wrapText="1"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
<dxfs count="0"/>
<tableStyles count="0"/>
</styleSheet>
"""


# 行の高さは Excel の自動調整に任せず、内容と列幅から計算して明示する。
# 自動調整は環境によって働かず、折り返した本文が既定の高さで切れて読めなくなるため。
# Meiryo UI 11pt の 1 行は約 15.0pt。折り返し計算の誤差を吸収できるよう余裕を持たせる。
ROW_LINE_HEIGHT = 16.5
ROW_HEIGHT_MIN = 19.5
# Excel の行高の上限 (409.5pt)。これを超える内容は 1 セルに詰め込まないよう、
# 長文のシートは「項目ごとに 1 行」の縦持ちにして 1 セルあたりの分量を抑えている。
ROW_HEIGHT_MAX = 409.0
HEADER_ROW_HEIGHT = 33.0


def wrapped_line_count(text, column_width):
    """列幅 (Excel の文字数単位) で折り返したときに必要な行数を求める。"""
    if text is None or text == "":
        return 1
    # 左右の余白とグリッド線のぶん、実際に使える幅は列幅よりわずかに狭い。
    usable = max(float(column_width) - 1.0, 4.0)
    total = 0
    for line in str(text).split("\n"):
        width = display_width(line)
        total += 1 if width <= 0 else int(math.ceil(width / usable))
    return max(total, 1)


def calculate_row_height(cells, widths):
    """行内で最も背の高いセルに合わせた行高 (pt) を返す。"""
    lines = 1
    for index, cell in enumerate(cells):
        if cell is None or cell.numeric:
            continue
        width = widths[index] if index < len(widths) else 20
        lines = max(lines, wrapped_line_count(cell.value, width))
    return min(max(lines * ROW_LINE_HEIGHT, ROW_HEIGHT_MIN), ROW_HEIGHT_MAX)


def sheet_xml(sheet):
    out = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
           "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"]
    if sheet.freeze_rows:
        out.append(
            "<sheetViews><sheetView workbookViewId=\"0\">"
            "<pane ySplit=\"%d\" topLeftCell=\"A%d\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            "</sheetView></sheetViews>" % (sheet.freeze_rows, sheet.freeze_rows + 1)
        )
    out.append("<sheetFormatPr defaultRowHeight=\"%s\"/>" % ROW_HEIGHT_MIN)
    if sheet.widths:
        cols = ["<cols>"]
        for index, width in enumerate(sheet.widths):
            cols.append("<col min=\"%d\" max=\"%d\" width=\"%s\" customWidth=\"1\"/>"
                        % (index + 1, index + 1, width))
        cols.append("</cols>")
        out.append("".join(cols))
    out.append("<sheetData>")
    for row_index, cells in enumerate(sheet.rows, 1):
        merged_width = sheet.merged_width(row_index)
        if sheet.freeze_rows and row_index <= sheet.freeze_rows:
            height = HEADER_ROW_HEIGHT
        elif merged_width is not None:
            # 結合セルは Excel の自動調整が効かないため、結合後の幅で計算する。
            height = calculate_row_height(cells[:1], [merged_width])
        else:
            height = calculate_row_height(cells, sheet.widths)
        parts = ["<row r=\"%d\" ht=\"%.1f\" customHeight=\"1\">" % (row_index, height)]
        for col_index, cell in enumerate(cells):
            if cell is None:
                continue
            ref = "%s%d" % (column_name(col_index), row_index)
            if cell.numeric:
                parts.append("<c r=\"%s\" s=\"%d\"><v>%s</v></c>" % (ref, cell.style, cell.value))
                continue
            value = "" if cell.value is None else str(cell.value)
            if len(value) > CELL_LIMIT:
                value = value[:CELL_LIMIT] + "\n... (以降は省略)"
            if not value:
                parts.append("<c r=\"%s\" s=\"%d\"/>" % (ref, cell.style))
                continue
            parts.append("<c r=\"%s\" s=\"%d\" t=\"inlineStr\"><is><t xml:space=\"preserve\">%s</t></is></c>"
                         % (ref, cell.style, xml_escape(value)))
        parts.append("</row>")
        out.append("".join(parts))
    out.append("</sheetData>")
    if sheet.autofilter_row and sheet.autofilter_cols:
        out.append("<autoFilter ref=\"A%d:%s%d\"/>"
                   % (sheet.autofilter_row, column_name(sheet.autofilter_cols - 1),
                      max(len(sheet.rows), sheet.autofilter_row)))
    # mergeCells は OOXML のスキーマ上 autoFilter の後に置く。
    if sheet.merges:
        merges = ["<mergeCells count=\"%d\">" % len(sheet.merges)]
        for row_number, start, end in sheet.merges:
            merges.append("<mergeCell ref=\"%s%d:%s%d\"/>"
                          % (column_name(start), row_number, column_name(end), row_number))
        merges.append("</mergeCells>")
        out.append("".join(merges))
    out.append("</worksheet>")
    return "".join(out)


def write_xlsx(path, sheets, title, creator):
    content_types = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
                     "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">",
                     "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>",
                     "<Default Extension=\"xml\" ContentType=\"application/xml\"/>",
                     "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>",
                     "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>",
                     "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>",
                     "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"]
    for index in range(len(sheets)):
        content_types.append("<Override PartName=\"/xl/worksheets/sheet%d.xml\" "
                             "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
                             % (index + 1))
    content_types.append("</Types>")

    root_rels = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        "</Relationships>"
    )

    sheet_entries = "".join(
        "<sheet name=\"%s\" sheetId=\"%d\" r:id=\"rId%d\"/>" % (xml_escape(sheet.name), index + 1, index + 1)
        for index, sheet in enumerate(sheets)
    )
    workbook = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        "<sheets>%s</sheets></workbook>" % sheet_entries
    )

    workbook_rels = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
                     "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"]
    for index in range(len(sheets)):
        workbook_rels.append(
            "<Relationship Id=\"rId%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" "
            "Target=\"worksheets/sheet%d.xml\"/>" % (index + 1, index + 1)
        )
    workbook_rels.append(
        "<Relationship Id=\"rId%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" "
        "Target=\"styles.xml\"/>" % (len(sheets) + 1)
    )
    workbook_rels.append("</Relationships>")

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    core = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
        "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
        "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        "<dc:title>%s</dc:title><dc:creator>%s</dc:creator><cp:lastModifiedBy>%s</cp:lastModifiedBy>"
        "<dcterms:created xsi:type=\"dcterms:W3CDTF\">%s</dcterms:created>"
        "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">%s</dcterms:modified>"
        "</cp:coreProperties>" % (xml_escape(title), xml_escape(creator), xml_escape(creator), now, now)
    )
    app = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" "
        "xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
        "<Application>%s</Application></Properties>" % xml_escape(creator)
    )

    directory = os.path.dirname(os.path.abspath(path))
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as book:
        book.writestr("[Content_Types].xml", "".join(content_types))
        book.writestr("_rels/.rels", root_rels)
        book.writestr("docProps/core.xml", core)
        book.writestr("docProps/app.xml", app)
        book.writestr("xl/workbook.xml", workbook)
        book.writestr("xl/_rels/workbook.xml.rels", "".join(workbook_rels))
        book.writestr("xl/styles.xml", STYLES_XML)
        for index, sheet in enumerate(sheets):
            book.writestr("xl/worksheets/sheet%d.xml" % (index + 1), sheet_xml(sheet))


def header_row(labels):
    return [Cell(label, S_HEADER) for label in labels]


def build_summary_sheet(meta, events, stats, scanned_services, line_count, truncated):
    sheet = Sheet("概要", widths=[26, 92, 46], freeze_rows=0)
    sheet.add([Cell("WAR デプロイ時 Java 例外エラー解析レポート", S_TITLE)])
    sheet.add([])

    def kv(label, value):
        sheet.add([Cell(label, S_LABEL), Cell(value, S_BODY)])

    sheet.add([Cell("1. 実行情報", S_SECTION)])
    kv("解析日時", meta.get("analyzed_at", ""))
    kv("処理開始日時", meta.get("run_started_at", ""))
    kv("スクリプト", meta.get("script", "build_and_verify.sh"))
    kv("Compose 定義", meta.get("compose_file", ""))
    kv("ビルド対象サービス", meta.get("build_services", ""))
    kv("起動対象サービス", meta.get("target_services", ""))
    kv("全体結果", meta.get("overall_status", ""))
    kv("デプロイ結果ファイル", meta.get("report_file", "") or "(未出力)")
    kv("解析対象サービス", " ".join(scanned_services) or "(なし)")
    kv("解析ログ行数", "%d 行" % line_count)
    kv("ログ取得範囲", meta.get("log_scope", ""))
    kv("ログ取得状況", meta.get("log_status", ""))
    sheet.add([])

    sheet.add([Cell("2. 検出サマリ", S_SECTION)])
    kv("検出した例外", "%d 件" % stats["total"])
    kv("デプロイ処理中の例外", "%d 件" % stats["deploy"])
    kv("デプロイ外の例外", "%d 件" % stats["other"])
    kv("深刻度の内訳",
       " / ".join("%s %d 件" % (name, count) for name, count in stats["by_severity"]) or "(なし)")
    kv("分類の内訳",
       " / ".join("%s %d 件" % (name, count) for name, count in stats["by_category"]) or "(なし)")
    if stats["total"] == 0:
        # 解析対象のログが無い場合は「未評価」のため、OK と同じ色にはしない。
        verdict_style = S_OK if line_count else S_WARN
    else:
        verdict_style = SEVERITY_STYLE.get(stats["worst"], S_BODY)
    sheet.add([Cell("総合判定", S_LABEL), Cell(stats["verdict"], verdict_style)])
    if truncated:
        kv("注意", "詳細分析は上限の %d 件までです。残りは件数のみ集計しています "
                  "(--deploy-exception-limit で上限を変更できます)。" % truncated)
    sheet.add([])

    sheet.add([Cell("3. 優先して対応すべき例外", S_SECTION)])
    if not events and line_count == 0:
        sheet.add([Cell("(未評価)", S_BODY),
                   Cell("解析対象のログが 1 行も無いため、Java 例外の有無を判定できていません。", S_BODY)])
    elif not events:
        sheet.add([Cell("(なし)", S_BODY), Cell("Java の例外スタックトレースは検出されませんでした。", S_BODY)])
    else:
        sheet.add(header_row(["No", "例外クラス (根本原因)", "対応の要点"]))
        for number, event in enumerate(events[:10], 1):
            root = event.root()
            knowledge = event.knowledge
            top_fix = knowledge["fixes"][0] if knowledge["fixes"] else ""
            sheet.add([
                Cell(number, S_CENTER, numeric=True),
                Cell("%s\n%s" % (root.klass or "(不明)", root.message or ""), S_BODY),
                Cell(top_fix, S_BODY),
            ])
    sheet.add([])

    sheet.add([Cell("4. このブックの読み方", S_SECTION)])
    sheet.add(header_row(["シート", "内容", "使いどころ"]))
    for name, content, usage in (
        ("例外一覧", "検出した例外を 1 行 1 件で一覧化 (発生時刻・サービス・デプロイ対象・例外クラス・根本原因)",
         "まず全体像を掴む。オートフィルタで深刻度やデプロイ関連を絞り込む"),
        ("原因分析", "例外ごとの「何が起きたか」「発生の仕組み」「想定される原因」「読み取れる事実」",
         "なぜ失敗したのかを理解する"),
        ("対処方法", "例外ごとの確認手順・対処方法・設定例・再発防止",
         "実際に直すときの手順書として使う"),
        ("スタックトレース", "例外の連鎖 (Caused by) ごとの全スタックフレーム",
         "コードのどこで失敗したかを特定する"),
        ("デプロイログ", "デプロイ処理に関係するログ行と、その区分",
         "時系列で前後関係を確認する"),
    ):
        sheet.add([Cell(name, S_LABEL), Cell(content, S_BODY), Cell(usage, S_BODY)])
    return sheet


LIST_COLUMNS = [
    ("No", 6), ("判定", 20), ("深刻度", 10), ("分類", 20), ("デプロイ関連", 12),
    ("デプロイ対象", 18), ("サービス", 14), ("コンテナ", 18), ("発生時刻", 22),
    ("レベル", 8), ("ロガー", 34), ("スレッド", 26), ("EAP コード", 12),
    ("例外クラス (最上位)", 40), ("例外メッセージ", 52), ("根本原因クラス", 40),
    ("根本原因メッセージ", 52), ("アプリ内発生点", 46), ("連鎖段数", 10),
    ("フレーム数", 10), ("一言サマリ", 60),
]


def build_list_sheet(events):
    sheet = Sheet("例外一覧", widths=[width for _label, width in LIST_COLUMNS],
                  freeze_rows=1, autofilter_row=1, autofilter_cols=len(LIST_COLUMNS))
    sheet.add(header_row([label for label, _width in LIST_COLUMNS]))
    for number, event in enumerate(events, 1):
        top = event.top()
        root = event.root()
        knowledge = event.knowledge
        line = event.origin_line
        sheet.add([
            Cell(number, S_CENTER, numeric=True),
            Cell(event.verdict, S_CENTER),
            Cell(knowledge["severity"], SEVERITY_STYLE.get(knowledge["severity"], S_BODY)),
            Cell(knowledge["category"], S_BODY),
            Cell("はい" if event.deploy_related else "いいえ", S_CENTER),
            Cell(event.deployment or "(特定できず)", S_BODY),
            Cell(line.service, S_BODY),
            Cell(line.container or "(不明)", S_BODY),
            Cell(line.timestamp() or "(不明)", S_BODY),
            Cell(line.level or "", S_CENTER),
            Cell(line.logger or "", S_BODY),
            Cell(line.thread or "", S_BODY),
            Cell(line.code or "", S_CENTER),
            Cell(top.klass or "(不明)", S_BODY),
            Cell(top.message or "", S_BODY),
            Cell(root.klass or "(不明)", S_BODY),
            Cell(root.message or "", S_BODY),
            Cell(event.app_frame(PLATFORM_PACKAGE_PREFIXES) or "(なし)", S_BODY),
            Cell(len(event.chain), S_CENTER, numeric=True),
            Cell(event.frame_count(), S_CENTER, numeric=True),
            Cell(one_line_summary(event), S_BODY),
        ])
    if not events:
        sheet.add_notice("例外は検出されませんでした。")
    return sheet


def chain_label(depth, element):
    if depth == 0:
        return "最上位"
    if element.kind == "suppressed":
        return "Suppressed"
    return "Caused by (%d 段目)" % depth


def build_analysis_sheet(events):
    """原因分析は「1 例外 × 1 項目 = 1 行」の縦持ちにする。

    横持ちで 1 セルへ長文を詰めると、Excel の行高上限 (409.5pt) を超えた分が
    表示されず読めなくなる。項目ごとに行を分けることで、どの内容も必ず収まる。
    """
    columns = [("No", 6), ("例外クラス (根本原因)", 42), ("分類", 22), ("深刻度", 10),
               ("項目", 26), ("内容", 104)]
    sheet = Sheet("原因分析", widths=[width for _label, width in columns],
                  freeze_rows=1, autofilter_row=1, autofilter_cols=len(columns))
    sheet.add(header_row([label for label, _width in columns]))

    for number, event in enumerate(events, 1):
        knowledge = event.knowledge
        root = event.root()
        entries = [("何が起きたか", knowledge["headline"]),
                   ("発生の仕組み", knowledge["mechanism"])]
        for index, cause in enumerate(knowledge["causes"], 1):
            entries.append(("想定される原因 %d" % index, cause))
        for label, value in event.facts:
            entries.append(("ログから読み取れる事実", "%s: %s" % (label, value)))
        for summary, _fixes in matched_hints(event):
            entries.append(("このログ特有の所見", summary))
        for reason in event.deploy_reasons:
            entries.append(("デプロイとの関連 (判定根拠)", reason))
        for code in event.related_codes:
            entries.append(("前後の EAP メッセージ",
                            "%s: %s" % (code, WFLY_CODE_NOTES.get(code, "(説明なし)"))))

        for label, value in entries:
            sheet.add([
                Cell(number, S_CENTER, numeric=True),
                Cell(root.klass or "(不明)", S_BODY),
                Cell(knowledge["category"], S_BODY),
                Cell(knowledge["severity"], SEVERITY_STYLE.get(knowledge["severity"], S_BODY)),
                Cell(label, S_LABEL),
                Cell(value, S_BODY),
            ])
    if not events:
        sheet.add_notice("例外は検出されませんでした。")
    return sheet


def build_fix_sheet(events):
    """対処方法も「1 手順 = 1 行」の縦持ちにし、設定例が切れないようにする。"""
    columns = [("No", 6), ("例外クラス (根本原因)", 42), ("優先度", 10),
               ("区分", 16), ("順番", 8), ("内容", 116)]
    sheet = Sheet("対処方法", widths=[width for _label, width in columns],
                  freeze_rows=1, autofilter_row=1, autofilter_cols=len(columns))
    sheet.add(header_row([label for label, _width in columns]))

    for number, event in enumerate(events, 1):
        knowledge = event.knowledge
        root = event.root()
        groups = [
            ("確認手順", knowledge["checks"]),
            ("対処方法", merge_fixes(knowledge["fixes"], matched_hints(event))),
            ("再発防止", knowledge["prevention"]),
            ("参考情報", knowledge["refs"]),
        ]
        for kind, items in groups:
            for index, item in enumerate(items, 1):
                sheet.add([
                    Cell(number, S_CENTER, numeric=True),
                    Cell(root.klass or "(不明)", S_BODY),
                    Cell(knowledge["severity"], SEVERITY_STYLE.get(knowledge["severity"], S_BODY)),
                    Cell(kind, S_LABEL),
                    Cell(index, S_CENTER, numeric=True),
                    Cell(item, S_BODY),
                ])
    if not events:
        sheet.add_notice("例外は検出されませんでした。")
    return sheet


def build_stacktrace_sheet(events):
    """スタックトレースは 1 フレーム 1 行に展開する (長いトレースでも切れない)。"""
    columns = [("No", 6), ("連鎖", 18), ("例外クラス", 44), ("例外メッセージ", 56),
               ("フレーム", 8), ("スタックフレーム", 116)]
    sheet = Sheet("スタックトレース", widths=[width for _label, width in columns],
                  freeze_rows=1, autofilter_row=1, autofilter_cols=len(columns))
    sheet.add(header_row([label for label, _width in columns]))

    for number, event in enumerate(events, 1):
        for depth, element in enumerate(event.chain):
            label = chain_label(depth, element)
            rows = [(str(index), frame) for index, frame in enumerate(element.frames, 1)]
            if element.more:
                rows.append(("…", "... %d more (呼び出し元は上位の段と共通)" % element.more))
            if not rows:
                rows.append(("-", "(フレームなし)"))
            for position, frame in rows:
                sheet.add([
                    Cell(number, S_CENTER, numeric=True),
                    Cell(label, S_CENTER),
                    Cell(element.klass or "(不明)", S_BODY),
                    Cell(element.message or "", S_BODY),
                    Cell(position, S_CENTER),
                    Cell(frame, S_MONO),
                ])
    if not events:
        sheet.add_notice("例外は検出されませんでした。")
    return sheet


LOG_KIND_STYLES = {
    "デプロイ失敗": S_FATAL,
    "エラー": S_FATAL,
    "警告": S_WARN,
    "デプロイ完了": S_OK,
    "起動完了": S_OK,
}


def classify_log_line(line, exception_indexes, frame_indexes):
    if line.index in frame_indexes:
        return "スタックフレーム"
    if line.index in exception_indexes:
        return "例外"
    if line.code in DEPLOY_FAILURE_CODES:
        return "デプロイ失敗"
    if line.code == "WFLYSRV0027":
        return "デプロイ開始"
    if line.code == "WFLYSRV0010":
        return "デプロイ完了"
    if line.code == "WFLYSRV0025":
        return "起動完了"
    if line.code in ("WFLYUT0021", "WFLYUT0006", "WFLYJCA0001", "WFLYJCA0018", "WFLYJCA0098"):
        return "デプロイ関連"
    level = (line.level or "").upper()
    if level in ("ERROR", "FATAL", "SEVERE"):
        return "エラー"
    if level in ("WARN", "WARNING"):
        return "警告"
    return "通常"


def build_log_sheet(lines, events, max_rows):
    columns = [("行番号", 8), ("サービス", 14), ("コンテナ", 18), ("時刻", 18),
               ("レベル", 8), ("区分", 14), ("EAP コード", 12), ("ログ本文", 150)]
    sheet = Sheet("デプロイログ", widths=[width for _label, width in columns],
                  freeze_rows=1, autofilter_row=1, autofilter_cols=len(columns))
    sheet.add(header_row([label for label, _width in columns]))

    exception_indexes, frame_indexes = exception_line_indexes(events)

    written = 0
    for line in lines:
        kind = classify_log_line(line, exception_indexes, frame_indexes)
        if written >= max_rows:
            sheet.add([Cell("", S_BODY), Cell("", S_BODY), Cell("", S_BODY), Cell("", S_BODY),
                       Cell("", S_BODY), Cell("", S_BODY), Cell("", S_BODY),
                       Cell("... 出力上限 (%d 行) に達したため以降は省略しました。全文はデプロイ結果ファイルを参照してください。"
                            % max_rows, S_BODY)])
            break
        style = LOG_KIND_STYLES.get(kind, S_BODY)
        sheet.add([
            Cell(line.index + 1, S_CENTER, numeric=True),
            Cell(line.service, S_BODY),
            Cell(line.container or "", S_BODY),
            Cell(line.timestamp() or "", S_BODY),
            Cell(line.level or "", S_CENTER),
            Cell(kind, style if kind in LOG_KIND_STYLES else S_CENTER),
            Cell(line.code or "", S_CENTER),
            Cell(line.body, S_MONO),
        ])
        written += 1
    if not lines:
        sheet.add_notice("ログを取得できませんでした。")
    return sheet


# =============================================================================
# エントリポイント
# =============================================================================

def write_text_file(path, text):
    """UTF-8 / LF でテキストを書き出す (Windows でも CRLF へ変換させない)。"""
    directory = os.path.dirname(os.path.abspath(path))
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def read_meta(path):
    meta = {}
    if not path or not os.path.exists(path):
        return meta
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            raw = raw.rstrip("\r\n")
            if not raw or "\t" not in raw:
                continue
            key, value = raw.split("\t", 1)
            meta[key] = value
    return meta


def compute_stats(events, log_available=True):
    severity_counts = {}
    category_counts = {}
    deploy = 0
    for event in events:
        severity = event.knowledge["severity"]
        category = event.knowledge["category"]
        severity_counts[severity] = severity_counts.get(severity, 0) + 1
        category_counts[category] = category_counts.get(category, 0) + 1
        if event.deploy_related:
            deploy += 1
    by_severity = sorted(severity_counts.items(),
                         key=lambda item: SEVERITY_ORDER.get(item[0], 9))
    by_category = sorted(category_counts.items(), key=lambda item: (-item[1], item[0]))
    worst = by_severity[0][0] if by_severity else ""
    total = len(events)
    if total == 0 and not log_available:
        # 解析対象のログが 1 行も無い場合、0 件は「例外が無かった」ことを意味しない。
        # コンテナの起動に失敗した実行を OK と誤読させないため、判定を分ける。
        verdict = "未評価 (解析対象のログが無いため判定できません)"
    elif total == 0:
        verdict = "OK (Java 例外は検出されませんでした)"
    elif deploy and worst == "致命的":
        verdict = "NG (デプロイ処理中に致命的な例外が発生しています)"
    elif deploy:
        verdict = "要確認 (デプロイ処理中に例外が発生しています)"
    else:
        verdict = "要確認 (デプロイ処理外で例外が発生しています)"
    return {
        "total": total,
        "deploy": deploy,
        "other": total - deploy,
        "by_severity": by_severity,
        "by_category": by_category,
        "worst": worst,
        "verdict": verdict,
    }


def main(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--meta-file", default="")
    parser.add_argument("--text-out", default="")
    parser.add_argument("--full-text-out", default="")
    parser.add_argument("--excel-out", default="")
    parser.add_argument("--max-exceptions", type=int, default=50)
    parser.add_argument("--max-log-rows", type=int, default=3000)
    args = parser.parse_args(argv)

    meta = read_meta(args.meta_file)
    meta.setdefault("analyzed_at", datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    lines = read_log_lines(args.log_file)

    scanned = []
    for line in lines:
        if line.service not in scanned:
            scanned.append(line.service)

    events = collect_exception_events(lines)
    deployment_names = resolve_deployment_names(lines)
    phase_bounds = deploy_phase_bounds(lines)
    deploy_failed = any(line.code in DEPLOY_FAILURE_CODES for line in lines)

    for event in events:
        classify_deploy_relation(event, lines, deployment_names, phase_bounds)
        chain_classes = [element.klass for element in reversed(event.chain)]
        _matched, knowledge = lookup_knowledge(chain_classes)
        event.knowledge = knowledge
        event.facts = extract_facts(event)
        event.related_codes = collect_related_codes(event, lines)
        event.verdict = determine_verdict(event, deploy_failed)

    # デプロイ関連・深刻度の高いものを先に並べ、同順位は発生順に保つ。
    events.sort(key=lambda item: (
        0 if item.deploy_related else 1,
        SEVERITY_ORDER.get(item.knowledge["severity"], 9),
        item.header_line.index,
    ))
    # 集計は検出した全件から求め、詳細分析だけを上限までに絞る。
    # (件数そのものを取りこぼすと、レポートの総合判定が実態とずれるため)
    stats = compute_stats(events, bool(lines))
    truncated = 0
    if len(events) > args.max_exceptions:
        truncated = args.max_exceptions
        events = events[:args.max_exceptions]
    text = build_text_report(meta, events, stats, scanned, len(lines), truncated)

    if args.text_out:
        write_text_file(args.text_out, text)
    elif not args.full_text_out:
        sys.stdout.write(text)

    # Excel と同じ情報量 (全スタックフレーム + デプロイログ) のテキストを別に出す。
    if args.full_text_out:
        full_text = build_text_report(meta, events, stats, scanned, len(lines), truncated,
                                      lines=lines, full=True, max_log_rows=args.max_log_rows)
        write_text_file(args.full_text_out, full_text)

    if args.excel_out:
        sheets = [
            build_summary_sheet(meta, events, stats, scanned, len(lines), truncated),
            build_list_sheet(events),
            build_analysis_sheet(events),
            build_fix_sheet(events),
            build_stacktrace_sheet(events),
            build_log_sheet(lines, events, args.max_log_rows),
        ]
        write_xlsx(args.excel_out, sheets,
                   "WAR デプロイ時 Java 例外エラー解析", "build_and_verify.sh")

    # 検出件数を呼び出し元 (シェル) へ返す。
    sys.stderr.write("DEPLOY_EXCEPTION_TOTAL=%d\n" % stats["total"])
    sys.stderr.write("DEPLOY_EXCEPTION_DEPLOY=%d\n" % stats["deploy"])
    sys.stderr.write("DEPLOY_EXCEPTION_WORST=%s\n" % (stats["worst"] or "-"))
    sys.stderr.write("DEPLOY_EXCEPTION_VERDICT=%s\n" % stats["verdict"])
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:  # 解析の失敗でビルド全体を止めない
        sys.stderr.write("[ERROR] Java 例外解析に失敗しました: %s\n" % exc)
        raise SystemExit(3)
DEPLOY_EXCEPTION_ANALYZER_PY_EOF

# 解析に使う Python 3 を探す。可観測性ヘルパーと同じ候補・同じ変数を使うが、
# 見つからない場合もビルドは止めず、解析だけを省略する。
resolve_deploy_exception_python() {
  local candidate

  [ -n "$OBSERVABILITY_PYTHON" ] && return 0
  for candidate in python3 python /usr/libexec/platform-python; do
    if command -v "$candidate" >/dev/null 2>&1 \
        && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)' \
          >/dev/null 2>&1; then
      OBSERVABILITY_PYTHON="$candidate"
      return 0
    fi
  done
  return 1
}

# メタ情報 1 行分を "キー<TAB>値" で書き出す。値に含まれるタブ・改行は、
# ヘルパー側の行単位パースを壊すため空白へ置き換える。
deploy_exception_meta_entry() {
  local key="$1" value="$2"
  value="$(printf '%s' "$value" | tr '\t\n\r' '   ')"
  printf '%s\t%s\n' "$key" "$value"
}

# 解析ヘルパーへ渡すメタ情報を書き出す。Excel の「概要」シートに載る。
write_deploy_exception_meta() {
  local meta_file="$1" exit_status="$2" overall_status log_scope report_file

  # 解析は全量レポートを書く直前に走るため、この時点ではレポートのファイル名が
  # まだ確定していない。対で参照できるよう、確定前は予定のパスを記載する。
  if [ -n "$BUILD_REPORT_FILE" ]; then
    report_file="$BUILD_REPORT_FILE"
  elif [ -n "$BUILD_REPORT_DIR" ]; then
    report_file="${BUILD_REPORT_DIR%/}/build_and_verify_${RUN_TIMESTAMP}.txt (出力予定)"
  else
    report_file=""
  fi

  if [ "$exit_status" -eq 0 ]; then
    overall_status="成功"
  else
    overall_status="失敗 (exit=${exit_status})"
  fi
  if [ "$DEPLOY_EXCEPTION_LOG_COLLECTED" != "true" ]; then
    log_scope="(解析対象のログを取得できていません)"
  elif [ -n "$CONTAINER_LOG_SINCE" ]; then
    log_scope="今回の compose up 以降 (--since ${CONTAINER_LOG_SINCE})"
  else
    log_scope="コンテナ作成時からの全期間"
  fi

  {
    deploy_exception_meta_entry "analyzed_at" "$(now_display_time)"
    deploy_exception_meta_entry "run_started_at" "$RUN_STARTED_AT"
    deploy_exception_meta_entry "script" "build_and_verify.sh"
    deploy_exception_meta_entry "compose_file" "$COMPOSE_FILE"
    if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
      deploy_exception_meta_entry "build_services" "${COMPOSE_SERVICES[*]}"
    else
      deploy_exception_meta_entry "build_services" "全サービス"
    fi
    if [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
      deploy_exception_meta_entry "target_services" "${COMPOSE_TARGET_SERVICES[*]}"
    else
      deploy_exception_meta_entry "target_services" "全サービス"
    fi
    deploy_exception_meta_entry "overall_status" "$overall_status"
    deploy_exception_meta_entry "report_file" "$report_file"
    deploy_exception_meta_entry "log_scope" "$log_scope"
    deploy_exception_meta_entry "log_status" "$DEPLOY_EXCEPTION_LOG_STATUS"
  } > "$meta_file"
}

# 解析対象のログを、サービス区切り付きの 1 ファイルへ書き出す。
# サービスをまたいでデプロイ対象や起動完了ログを取り違えないよう、
# サービス単位に取得して区切り行を挟む。
# 戻り値は「ログ本文を 1 行でも取得できたか」。コンテナの起動に失敗した場合でも
# 途中まで出たログは残っているため、取得できた分だけを解析対象とする。
collect_deploy_exception_logs() {
  local output_file="$1" service_name service_logs collected="false"
  local -a services=()

  : > "$output_file" || return 1
  mapfile -t services < <(compose_all_service_names)
  [ ${#services[@]} -gt 0 ] || return 1
  for service_name in "${services[@]}"; do
    [ -n "$service_name" ] || continue
    service_logs="$(compose_logs "$service_name" | strip_ansi_codes)"
    # ログが 1 行も無いサービスは区切りだけが残っても意味が無いため書き出さない。
    [ -n "$service_logs" ] || continue
    printf '%s%s\n' "$DEPLOY_EXCEPTION_SERVICE_MARKER" "$service_name" >> "$output_file"
    printf '%s\n' "$service_logs" >> "$output_file"
    collected="true"
  done
  [ "$collected" = "true" ]
}

# 解析結果ファイル (Excel / テキスト) の出力先を決める。明示指定が最優先で、
# 次に全量レポートと同じディレクトリ。どちらも無い場合は出力しない
# (その場合も解析結果は画面と全量レポートへ出る)。
resolve_deploy_exception_output_path() {
  local explicit="$1" explicit_set="$2" extension="$3"
  local report_dir base candidate counter=1

  if [ "$explicit_set" = "true" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  [ -n "$BUILD_REPORT_DIR" ] || return 1
  report_dir="${BUILD_REPORT_DIR%/}"
  [ -n "$report_dir" ] || report_dir="/"
  # 全量レポート (build_and_verify_<日時>.txt) と対で並ぶ名前にする。
  base="build_and_verify_${RUN_TIMESTAMP}_java_exceptions"
  candidate="${report_dir}/${base}.${extension}"
  while [ -e "$candidate" ]; do
    candidate="${report_dir}/${base}_${counter}.${extension}"
    counter=$((counter + 1))
  done
  printf '%s\n' "$candidate"
  return 0
}

# 出力先を解決し、親ディレクトリまで作成する。作成できない場合は空を返して
# その形式の出力だけを諦める (解析そのものは継続する)。
prepare_deploy_exception_output() {
  local explicit="$1" explicit_set="$2" extension="$3" label="$4" path=""

  if path="$(resolve_deploy_exception_output_path "$explicit" "$explicit_set" "$extension")" \
      && [ -n "$path" ]; then
    if ! mkdir -p -- "$(dirname -- "$path")" 2>/dev/null; then
      warn "Java 例外解析${label}の出力先を作成できませんでした: $(dirname -- "$path")"
      path=""
    fi
  else
    path=""
  fi
  printf '%s\n' "$path"
}

# ヘルパーが標準エラーへ返す集計値を読み取る。
read_deploy_exception_summary() {
  local summary_file="$1" line

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      DEPLOY_EXCEPTION_TOTAL=*)   DEPLOY_EXCEPTION_TOTAL="${line#*=}" ;;
      DEPLOY_EXCEPTION_DEPLOY=*)  DEPLOY_EXCEPTION_DEPLOY_TOTAL="${line#*=}" ;;
      DEPLOY_EXCEPTION_WORST=*)   DEPLOY_EXCEPTION_WORST="${line#*=}" ;;
      DEPLOY_EXCEPTION_VERDICT=*) DEPLOY_EXCEPTION_VERDICT="${line#*=}" ;;
    esac
  done < "$summary_file"
}

# デプロイ処理のログから Java 例外を解析し、画面表示・Excel 出力を行う。
# 成功経路 (主処理の末尾) と失敗経路 (EXIT トラップ) の双方から呼ばれるため、
# 二重に実行しないよう DEPLOY_EXCEPTION_ANALYZED で守る。コンテナを削除する前に
# 呼ぶ必要がある (compose logs が取得できなくなるため)。
#
# コンテナの起動 (compose up) に失敗した場合でも解析は必ず実行する。
# 起動に失敗する原因そのものがデプロイ処理中の Java 例外であることが多く、
# 「全量レポートしか出ず、例外解析だけ無い」状態では原因調査ができないため。
# 解析対象のログを 1 行も取得できなかった場合も、その事実を結果として出力する
# (0 件検出ではなく「未評価」として扱い、理由を三方へ残す)。
analyze_war_deploy_exceptions() {
  local exit_status="${1:-0}"
  local log_file="" meta_file="" summary_file="" excel_path="" text_path="" line=""
  local analyzer_status=0
  local -a analyzer_args=()

  [ "$DEPLOY_EXCEPTION_ANALYZED" = "true" ] && return 0

  if [ "$DEPLOY_EXCEPTION_ANALYSIS" != "true" ]; then
    DEPLOY_EXCEPTION_ANALYZED="true"
    DEPLOY_EXCEPTION_SKIP_REASON="--no-deploy-exception-analysis が指定されたため解析していません。"
    return 0
  fi
  if [ "$DRY_RUN" = "true" ]; then
    DEPLOY_EXCEPTION_ANALYZED="true"
    DEPLOY_EXCEPTION_SKIP_REASON="DRY-RUN のため解析していません。"
    log "[DRY-RUN] WAR デプロイ時 Java 例外解析をスキップします。"
    return 0
  fi
  if ! resolve_deploy_exception_python; then
    DEPLOY_EXCEPTION_ANALYZED="true"
    DEPLOY_EXCEPTION_SKIP_REASON="解析に必要な Python 3 が見つかりませんでした (python3 / python / /usr/libexec/platform-python)。"
    warn "WAR デプロイ時 Java 例外解析をスキップしました: Python 3 が見つかりません。"
    return 0
  fi
  DEPLOY_EXCEPTION_ANALYZED="true"

  if ! log_file="$(mktemp 2>/dev/null)" \
      || ! meta_file="$(mktemp 2>/dev/null)" \
      || ! summary_file="$(mktemp 2>/dev/null)" \
      || ! DEPLOY_EXCEPTION_TEXT_FILE="$(mktemp 2>/dev/null)"; then
    rm -f -- "$log_file" "$meta_file" "$summary_file" "$DEPLOY_EXCEPTION_TEXT_FILE"
    DEPLOY_EXCEPTION_TEXT_FILE=""
    DEPLOY_EXCEPTION_SKIP_REASON="解析用の一時ファイルを作成できませんでした。"
    warn "WAR デプロイ時 Java 例外解析用の一時ファイルを作成できませんでした。"
    return 1
  fi

  # 解析対象ログの収集。取得できなかった場合も解析自体は続け、その理由を結果へ残す。
  # compose up まで到達していない実行では、前回の実行が残したコンテナのログを
  # 今回の結果として解析してしまわないよう、収集そのものを行わない。
  if [ "$COMPOSE_UP_ATTEMPTED" != "true" ]; then
    : > "$log_file"
    DEPLOY_EXCEPTION_LOG_COLLECTED="false"
    DEPLOY_EXCEPTION_LOG_STATUS="コンテナ起動 (compose up) まで到達しなかったため、解析対象のログがありません (ビルド失敗、または起動確認を伴わない実行)。"
  elif collect_deploy_exception_logs "$log_file"; then
    DEPLOY_EXCEPTION_LOG_COLLECTED="true"
    if [ "$STARTED_CONTAINER" = "true" ]; then
      DEPLOY_EXCEPTION_LOG_STATUS="コンテナ起動後のデプロイ処理ログを解析しました。"
    else
      DEPLOY_EXCEPTION_LOG_STATUS="コンテナの起動 (compose up) に失敗したため、失敗するまでに出力されたログを解析しました。"
    fi
  else
    : > "$log_file"
    DEPLOY_EXCEPTION_LOG_COLLECTED="false"
    # 取得できなかったことは show_war_deploy_exception_analysis が結果として示すため、
    # ここでは警告を重ねない。
    DEPLOY_EXCEPTION_LOG_STATUS="Compose サービスのログを 1 行も取得できませんでした (コンテナが作成されていない可能性があります)。"
  fi
  write_deploy_exception_meta "$meta_file" "$exit_status"

  excel_path="$(prepare_deploy_exception_output \
      "$DEPLOY_EXCEPTION_EXCEL" "$DEPLOY_EXCEPTION_EXCEL_SET" "xlsx" " Excel")"
  text_path="$(prepare_deploy_exception_output \
      "$DEPLOY_EXCEPTION_TEXT" "$DEPLOY_EXCEPTION_TEXT_SET" "txt" "テキスト")"

  analyzer_args=(
    --log-file "$log_file"
    --meta-file "$meta_file"
    --text-out "$DEPLOY_EXCEPTION_TEXT_FILE"
    --max-exceptions "$DEPLOY_EXCEPTION_MAX"
    --max-log-rows "$DEPLOY_EXCEPTION_LOG_ROWS"
  )
  [ -n "$excel_path" ] && analyzer_args+=(--excel-out "$excel_path")
  [ -n "$text_path" ] && analyzer_args+=(--full-text-out "$text_path")

  # レポートは日本語と罫線文字を含むため、ロケール既定の文字コード (Windows の
  # cp932 等) で出力が落ちないよう UTF-8 を明示する。
  printf '%s' "$DEPLOY_EXCEPTION_ANALYZER_PY" \
    | PYTHONIOENCODING=utf-8 "$OBSERVABILITY_PYTHON" - "${analyzer_args[@]}" 2> "$summary_file"
  analyzer_status=$?
  if [ "$analyzer_status" -ne 0 ]; then
    warn "WAR デプロイ時 Java 例外解析に失敗しました (exit=${analyzer_status})。"
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] && diag "  $line"
    done < "$summary_file"
    DEPLOY_EXCEPTION_SKIP_REASON="解析ヘルパーの実行に失敗しました (exit=${analyzer_status})。"
    rm -f -- "$log_file" "$meta_file" "$summary_file" "$DEPLOY_EXCEPTION_TEXT_FILE"
    DEPLOY_EXCEPTION_TEXT_FILE=""
    return 1
  fi
  read_deploy_exception_summary "$summary_file"
  rm -f -- "$log_file" "$meta_file" "$summary_file"

  if [ -n "$excel_path" ] && [ -s "$excel_path" ]; then
    DEPLOY_EXCEPTION_EXCEL_FILE="$excel_path"
  fi
  if [ -n "$text_path" ] && [ -s "$text_path" ]; then
    DEPLOY_EXCEPTION_TEXT_OUTPUT="$text_path"
  fi

  show_war_deploy_exception_analysis
  return 0
}

# 解析結果を画面へ出す。例外を検出した場合のみ全文を表示し、
# 0 件のときは 1 行の結果表示に留める (成功時のログを埋もれさせないため)。
show_war_deploy_exception_analysis() {
  # 検出件数は解析ヘルパーの集計をそのまま伝える。本文が空でも件数は隠さない。
  if [ "${DEPLOY_EXCEPTION_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
    if [ -s "$DEPLOY_EXCEPTION_TEXT_FILE" ]; then
      diag ""
      cat -- "$DEPLOY_EXCEPTION_TEXT_FILE" >&2
    fi
    err "WAR デプロイ時に Java の例外を ${DEPLOY_EXCEPTION_TOTAL} 件検出しました (デプロイ処理中: ${DEPLOY_EXCEPTION_DEPLOY_TOTAL} 件)。"
    err "  判定: ${DEPLOY_EXCEPTION_VERDICT}"
  elif [ "$DEPLOY_EXCEPTION_LOG_COLLECTED" = "true" ]; then
    log "WAR デプロイ時の Java 例外は検出されませんでした。"
  elif [ "$COMPOSE_UP_ATTEMPTED" = "true" ]; then
    # ログが出ているはずの実行で 1 行も取得できなかった場合の 0 件は、
    # 「例外が無かった」ことを意味しないため、検出結果ではなく理由を示す。
    warn "WAR デプロイ時 Java 例外解析: ${DEPLOY_EXCEPTION_LOG_STATUS}"
    warn "  判定: ${DEPLOY_EXCEPTION_VERDICT}"
  else
    # コンテナを起動しない実行 (ビルドのみ / ビルド失敗) は想定内のため通常表示。
    log "WAR デプロイ時 Java 例外解析: ${DEPLOY_EXCEPTION_LOG_STATUS}"
    log "  判定: ${DEPLOY_EXCEPTION_VERDICT}"
  fi
  # コンテナの起動に失敗した実行では、解析できた範囲を明示する。
  if [ "$DEPLOY_EXCEPTION_LOG_COLLECTED" = "true" ] && [ "$STARTED_CONTAINER" != "true" ]; then
    log "  解析範囲: ${DEPLOY_EXCEPTION_LOG_STATUS}"
  fi
  if [ -n "$DEPLOY_EXCEPTION_EXCEL_FILE" ]; then
    log "Java 例外解析の Excel ブックを出力しました: $DEPLOY_EXCEPTION_EXCEL_FILE"
  fi
  if [ -n "$DEPLOY_EXCEPTION_TEXT_OUTPUT" ]; then
    log "Java 例外解析のテキストを出力しました: $DEPLOY_EXCEPTION_TEXT_OUTPUT"
  fi
  if [ -z "$DEPLOY_EXCEPTION_EXCEL_FILE" ] && [ -z "$DEPLOY_EXCEPTION_TEXT_OUTPUT" ] \
      && [ -z "$BUILD_REPORT_DIR" ]; then
    log "Java 例外解析のファイル出力は、--report-dir または --deploy-exception-excel / --deploy-exception-text の指定時に行います。"
  fi
  return 0
}

# 全量レポートへ Java 例外解析の結果を追記する。
append_deploy_exception_report() {
  local report_file="$1"

  if [ -z "$DEPLOY_EXCEPTION_TEXT_FILE" ] || [ ! -s "$DEPLOY_EXCEPTION_TEXT_FILE" ]; then
    printf '%s\n' "${DEPLOY_EXCEPTION_SKIP_REASON:-解析結果を取得できなかったため記載できません。}" \
        >> "$report_file"
    return 0
  fi
  if [ -n "$DEPLOY_EXCEPTION_EXCEL_FILE" ]; then
    printf 'Excel ブック  : %s\n' "$DEPLOY_EXCEPTION_EXCEL_FILE" >> "$report_file"
  else
    printf 'Excel ブック  : (未出力)\n' >> "$report_file"
  fi
  if [ -n "$DEPLOY_EXCEPTION_TEXT_OUTPUT" ]; then
    printf 'テキスト      : %s (Excel と同じ内容。全スタックフレームとデプロイログを含む)\n' \
        "$DEPLOY_EXCEPTION_TEXT_OUTPUT" >> "$report_file"
  else
    printf 'テキスト      : (未出力)\n' >> "$report_file"
  fi
  printf 'ログ取得状況  : %s\n' "${DEPLOY_EXCEPTION_LOG_STATUS:-(不明)}" >> "$report_file"
  printf '取得範囲      : 終了ログ (SIGTERM 後) を取得する前のデプロイ処理ログ\n' >> "$report_file"
  printf '\n' >> "$report_file"
  cat -- "$DEPLOY_EXCEPTION_TEXT_FILE" >> "$report_file"
  return 0
}

append_compose_service_logs_report() {
  local report_file="$1"
  local service_name index=0 normalized_logs line_count containers log_scope
  local -a services=()

  if [ -n "$CONTAINER_LOG_SINCE" ]; then
    log_scope="今回の compose up 以降 (--since ${CONTAINER_LOG_SINCE})"
  else
    log_scope="コンテナ作成時からの全期間 (compose up 到達前に終了)"
  fi
  printf '取得範囲      : %s\n' "$log_scope" >> "$report_file"
  printf '出力方針      : サービス単位に全行を出力 (画面表示の行数制限は適用しない)\n' >> "$report_file"
  if [ "$SHUTDOWN_STOP_EXECUTED" = "true" ]; then
    printf '終了処理      : SIGTERM (compose stop -t %s) 送出後の終了ログまで含む\n' \
        "$SHUTDOWN_LOG_TIMEOUT" >> "$report_file"
  fi

  mapfile -t services < <(compose_all_service_names)
  if [ ${#services[@]} -eq 0 ]; then
    printf '対象サービス  : (なし)\n' >> "$report_file"
    printf 'Compose サービスを特定できなかったため、ログを取得していません。\n' >> "$report_file"
    return 0
  fi
  printf '対象サービス  : %s (%s サービス)\n' "${services[*]}" "${#services[@]}" >> "$report_file"

  for service_name in "${services[@]}"; do
    index=$((index + 1))
    containers="$(compose_service_container_summary "$service_name")"
    normalized_logs="$(compose_logs "$service_name" | strip_ansi_codes)"
    if [ -n "$normalized_logs" ]; then
      line_count="$(printf '%s\n' "$normalized_logs" | awk 'END { print NR }')"
    else
      line_count=0
    fi

    printf '\n' >> "$report_file"
    printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
    printf '[9-%s] Compose サービス: %s\n' "$index" "$service_name" >> "$report_file"
    printf 'コンテナ      : %s\n' "$containers" >> "$report_file"
    printf 'ログ行数      : %s 行\n' "$line_count" >> "$report_file"
    printf '───────────────────────────────────────────────────────────────────\n' >> "$report_file"
    if [ "$line_count" -gt 0 ]; then
      printf '%s\n' "$normalized_logs" >> "$report_file"
    else
      printf '(このサービスのログはありません)\n' >> "$report_file"
    fi
  done
  return 0
}

# JBoss マスターパスワードの伝搬検証結果を全量レポートへ追記する。
# 画面と同じ内容 (一致した文字列 / 不一致時の原本と実際の双方) を残し、
# 後から 16 進ダンプ同士を突き合わせられるようにする。
append_jboss_password_report() {
  local report_file="$1"
  local entry label verdict note actual_b64 has_value actual index=0

  if [ "$VERIFY_JBOSS_PASSWORD" != "true" ]; then
    # 先頭が "--" の文字列を書式に置くと printf がオプションとして解釈するため、
    # 書式は '%s\n' に固定して本文は引数として渡す。
    printf '%s\n' '--verify-jboss-password が指定されていないため検証していません。' >> "$report_file"
    return 0
  fi
  if [ ${#JBOSS_PASSWORD_STAGE_RESULTS[@]} -eq 0 ]; then
    printf '検証結果がありません (原本のマスターパスワードを取得できなかった可能性があります)。\n' >> "$report_file"
    return 0
  fi

  {
    printf '取得元        : %s\n' "${JBOSS_PASSWORD_SOURCE_LABEL:-不明}"
    printf '環境変数      : %s\n' "$JBOSS_PASSWORD_ENV"
    printf 'シークレット id: %s (ビルド中のマウント先: /run/secrets/%s)\n' "$JBOSS_SECRET_ID" "$JBOSS_SECRET_ID"
    printf '検証した段数  : %s\n' "${#JBOSS_PASSWORD_STAGE_RESULTS[@]}"
    if [ "$JBOSS_PASSWORD_MISMATCH" = "true" ]; then
      printf '総合判定      : 不一致あり\n'
    elif [ "$JBOSS_PASSWORD_UNKNOWN" = "true" ]; then
      printf '総合判定      : 確認できた段はすべて一致 (未確認の段あり)\n'
    else
      printf '総合判定      : 全段一致\n'
    fi
    printf '原本の文字列  : %s\n' "$(jboss_password_display "$JBOSS_PASSWORD_ORIGIN")"
    printf '  可視化表記  : %s\n' "$(jboss_password_visible "$JBOSS_PASSWORD_ORIGIN")"
    printf '  16 進ダンプ : %s\n' "$(jboss_password_hex "$JBOSS_PASSWORD_ORIGIN")"
    printf '  バイト長    : %s バイト\n' "$(jboss_password_byte_length "$JBOSS_PASSWORD_ORIGIN")"
  } >> "$report_file"

  for entry in "${JBOSS_PASSWORD_STAGE_RESULTS[@]}"; do
    index=$((index + 1))
    IFS="$JBOSS_STAGE_SEPARATOR" read -r label verdict note actual_b64 has_value <<< "$entry"
    {
      printf '\n'
      printf '───────────────────────────────────────────────────────────────────\n'
      printf '[%s] %s\n' "$index" "$label"
      printf '判定          : %s\n' "$verdict"
      printf '補足          : %s\n' "${note:-(なし)}"
      printf '───────────────────────────────────────────────────────────────────\n'
    } >> "$report_file"
    [ "$has_value" = "true" ] || continue
    jboss_read_exact actual jboss_b64_decode "$actual_b64"
    case "$verdict" in
      '不一致 (式が未解決)')
        {
          printf '原本 (取得元) : %s\n' "$(jboss_password_display "$JBOSS_PASSWORD_ORIGIN")"
          printf '  16 進ダンプ : %s\n' "$(jboss_password_hex "$JBOSS_PASSWORD_ORIGIN")"
          printf 'ファイル上の値: %s\n' "$(jboss_password_display "$actual")"
          printf '  16 進ダンプ : %s\n' "$(jboss_password_hex "$actual")"
          printf '実行時の値    : ${...} の解決結果となるため、この文字列のままでは使われません\n'
          printf '対処          : jboss-cli への登録時に $ を $$ へエスケープしてください\n'
        } >> "$report_file"
        ;;
      不一致*)
        {
          printf '原本 (取得元) : %s\n' "$(jboss_password_display "$JBOSS_PASSWORD_ORIGIN")"
          printf '  16 進ダンプ : %s\n' "$(jboss_password_hex "$JBOSS_PASSWORD_ORIGIN")"
          printf '実際の文字列  : %s\n' "$(jboss_password_display "$actual")"
          printf '  可視化表記  : %s\n' "$(jboss_password_visible "$actual")"
          printf '  16 進ダンプ : %s\n' "$(jboss_password_hex "$actual")"
          printf '  バイト長    : %s バイト\n' "$(jboss_password_byte_length "$actual")"
          printf '相違位置      : %s\n' "$(jboss_password_first_diff "$JBOSS_PASSWORD_ORIGIN" "$actual")"
        } >> "$report_file"
        ;;
      *)
        {
          printf '文字列        : %s\n' "$(jboss_password_display "$actual")"
          printf '  可視化表記  : %s\n' "$(jboss_password_visible "$actual")"
          printf '  16 進ダンプ : %s\n' "$(jboss_password_hex "$actual")"
          printf '  バイト長    : %s バイト\n' "$(jboss_password_byte_length "$actual")"
        } >> "$report_file"
        ;;
    esac
  done
  return 0
}

# EXIT トラップからコンテナ停止前に呼び、画面表示の制限にかかわらず環境変数は
# 全件、各ディレクトリは全深度・全ファイル名で保存する。
write_build_report() {
  local exit_status="$1" overall_status build_status report_dir report_base candidate
  local counter=1 report_tmp report_finished_at cid service_name container_name
  local -a target_container_ids=()

  [ -n "$BUILD_REPORT_DIR" ] || return 0
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] 全量ビルドレポートのファイル出力をスキップします: ${BUILD_REPORT_DIR}/build_and_verify_${RUN_TIMESTAMP}.txt"
    return 0
  fi
  if ! mkdir -p -- "$BUILD_REPORT_DIR"; then
    warn "全量ビルドレポートの出力先を作成できませんでした: $BUILD_REPORT_DIR"
    return 1
  fi

  report_dir="${BUILD_REPORT_DIR%/}"
  [ -n "$report_dir" ] || report_dir="/"
  report_base="build_and_verify_${RUN_TIMESTAMP}"
  candidate="${report_dir%/}/${report_base}.txt"
  while [ -e "$candidate" ]; do
    candidate="${report_dir%/}/${report_base}_${counter}.txt"
    counter=$((counter + 1))
  done
  if ! report_tmp="$(mktemp "${report_dir%/}/.${report_base}.tmp.XXXXXX" 2>/dev/null)"; then
    warn "全量ビルドレポート用の一時ファイルを作成できませんでした: $report_dir"
    return 1
  fi

  if [ "$exit_status" -eq 0 ]; then
    overall_status="成功"
  else
    overall_status="失敗 (exit=${exit_status})"
  fi
  build_status="$BUILD_RESULT_STATUS"
  if [ "$exit_status" -ne 0 ] && [ "$build_status" = "実行中" ]; then
    build_status="失敗 (ビルド処理中に中断)"
  fi
  report_finished_at="$(now_display_time)"

  if ! {
    printf '===================================================================\n'
    printf 'build_and_verify.sh 全量ビルドレポート\n'
    printf '===================================================================\n'
    printf '処理開始日時 : %s\n' "$RUN_STARTED_AT"
    printf 'レポート日時 : %s\n' "$report_finished_at"
    printf '全体結果     : %s\n' "$overall_status"
    printf 'Compose 定義 : %s\n' "$COMPOSE_FILE"
    if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
      printf 'ビルド対象   : %s\n' "${COMPOSE_SERVICES[*]}"
    else
      printf 'ビルド対象   : 全サービス\n'
    fi
    if [ ${#COMPOSE_TARGET_SERVICES[@]} -gt 0 ]; then
      printf '起動対象     : %s\n' "${COMPOSE_TARGET_SERVICES[*]}"
    else
      printf '起動対象     : 全サービス\n'
    fi
    printf '\n[1] ビルド結果\n'
    printf '結果          : %s\n' "$build_status"
    printf '詳細          : %s\n' "${BUILD_RESULT_DETAIL:-(なし)}"
    printf 'イメージ      : %s\n' "${BUILD_IMAGE_INFO:-(未確認)}"
    printf 'ビルド監視    : %s\n' "${BUILD_WATCHDOG_SUMMARY:-(未実行)}"
    printf '保存ポリシー  : 環境変数は全件、ツリーは全深度・全ファイル名\n'
    printf '                JVM パラメータと OpenTelemetry 設定は検出した全件\n'
    printf '                失敗時は全 Compose サービスのログをサービス単位に全行保存\n'
    printf '                (SIGTERM で終了させたうえで、終了処理のログまで含める)\n'
    printf '                デプロイ処理の Java 例外解析は [10] に記載 (Excel も併せて出力)\n'
    printf '                Java 例外解析はコンテナの起動に失敗した場合でも必ず実行する\n'
  } > "$report_tmp"; then
    rm -f -- "$report_tmp"
    warn "全量ビルドレポートのヘッダーを書き込めませんでした: $candidate"
    return 1
  fi

  if [ "$STARTED_CONTAINER" = "true" ]; then
    mapfile -t target_container_ids < <(verification_target_container_ids)
  fi
  if [ ${#target_container_ids[@]} -eq 0 ]; then
    {
      printf '\n[2] 環境変数一覧 (全件)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[5] Java JVM パラメータ (全件)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
      printf '\n[6] OpenTelemetry 環境変数・JVM パラメータ (全件)\n'
      printf '対象コンテナが起動していないため取得していません。\n'
    } >> "$report_tmp"
  else
    load_build_arg_env_name_set
    printf '\n[2] 環境変数一覧 (全件)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_env_report "$cid" "$service_name" "$container_name" "$report_tmp" "all"
    done

    printf '\n[3] コンテナ内ディレクトリツリー (全深度・全ファイル名)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_directory_tree_report "$cid" "$service_name" "$container_name" \
          "$report_tmp" "/" "コンテナ内ディレクトリツリー" "all" "all"
    done

    printf '\n[4] JBoss EAP デプロイ構造 (全深度・全ファイル名)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_deployment_structure_report "$cid" "$service_name" "$container_name" \
          "$report_tmp" "all" "all"
    done

    printf '\n[5] Java JVM パラメータ (全件)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_jvm_parameter_report "$cid" "$service_name" "$container_name" "$report_tmp"
    done

    printf '\n[6] OpenTelemetry 環境変数・JVM パラメータ (全件)\n' >> "$report_tmp"
    for cid in "${target_container_ids[@]}"; do
      [ -n "$cid" ] || continue
      service_name="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$cid" 2>/dev/null || true)"
      [ -n "$service_name" ] || service_name="(unknown)"
      container_name="$(normalize_container_name "$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || printf '%s' "$cid")")"
      append_container_otel_report "$cid" "$service_name" "$container_name" "$report_tmp"
    done
  fi

  # JBoss マスターパスワードの伝搬検証は、コンテナを停止する前 ([2]〜[6] と同じ
  # タイミング) までに集め終えた結果を書き出す。
  printf '\n[7] JBoss マスターパスワードの伝搬検証\n' >> "$report_tmp"
  append_jboss_password_report "$report_tmp"

  # cwagent の設定・送達検証も、コンテナを停止する前の結果を書き出す。
  printf '\n[8] CloudWatch Logs 送信検証 (cwagent)\n' >> "$report_tmp"
  append_cwagent_report "$report_tmp"

  # 失敗時は、ログ本文を集める前に SIGTERM でコンテナを終了させ、adot collector
  # などの終了処理ログまでレポートへ含める。環境変数・ツリー・JVM パラメータは
  # 起動中のコンテナからしか取得できないため、[2]〜[8] を集め終えたこの位置で停止する。
  capture_shutdown_logs "$exit_status"

  # 失敗時は原因調査に必要なため全サービスのログ全文を残す。成功時は同じ内容が
  # 画面へ出ており、レポートを不必要に肥大化させるだけなので省略する。
  printf '\n[9] Compose サービス別ログ (全サービス・全行)\n' >> "$report_tmp"
  if [ "$exit_status" -eq 0 ]; then
    printf '処理が成功したため、Compose サービス別ログの全文出力は省略しました。\n' >> "$report_tmp"
  else
    append_compose_service_logs_report "$report_tmp"
  fi

  # WAR デプロイ時の Java 例外解析。解析自体はコンテナを停止する前 (cleanup_all が
  # この関数を呼ぶ直前) に済ませてあり、ここではその結果を書き出すだけとする。
  printf '\n[10] WAR デプロイ時 Java 例外解析\n' >> "$report_tmp"
  append_deploy_exception_report "$report_tmp"

  if ! mv -- "$report_tmp" "$candidate"; then
    rm -f -- "$report_tmp"
    warn "全量ビルドレポートを確定できませんでした: $candidate"
    return 1
  fi
  BUILD_REPORT_FILE="$candidate"
  log "全量ビルドレポートを出力しました: $BUILD_REPORT_FILE"
  return 0
}

# ---- 後始末 (任意の Docker 完全クリーンアップ → 通常後始末) ----------------
URL_BODY_FILE=""
cleanup_all() {
  local original_status=$? cleanup_status=0
  # この関数内の exit で EXIT トラップが再帰しないよう、先に解除する。
  trap - EXIT

  # コンテナの停止・Docker 全体削除より前に、取得可能な全量情報を保存する。
  # (エラー時の終了ログ取得は、レポート内でログ本文を集める直前に実行される)
  #
  # WAR デプロイ時の Java 例外解析は、全量レポートへ結果を載せるため、
  # レポート出力より先に実行する。成功経路では主処理の末尾で実行済みのため、
  # ここでの呼び出しは何もしない (二重実行の防止は関数側で行う)。
  analyze_war_deploy_exceptions "$original_status"
  if ! write_build_report "$original_status"; then
    cleanup_status=1
  fi
  # レポート出力が無効な場合でも、エラー時は SIGTERM で終了させて終了ログを
  # 画面へ残す。レポート側で実行済みならここでは何もしない。
  capture_shutdown_logs "$original_status"

  # 全体クリーンアップを先に実行し、削除前容量へ今回の Compose コンテナも含める。
  # 未承認・失敗時は、その後に従来どおり今回起動したコンテナだけを後始末する。
  if [ "$CLEANUP_ALL_DOCKER_DATA" = "true" ]; then
    if cleanup_all_docker_data; then
      [ "$DRY_RUN" = "true" ] || STARTED_CONTAINER="false"
      # 全体クリーンアップが削除前後の容量を表示済みのため、重複させない。
      DISK_USAGE_REPORTED="true"
    else
      cleanup_status=1
    fi
  fi
  teardown_container
  # コンテナを削除した後に、今回増えたビルドキャッシュを片付けて容量を測る。
  prune_build_cache
  report_disk_usage_at_exit
  cleanup_copied_files
  # 解析結果の一時ファイルは、全量レポートへ転記し終えたここで削除する。
  [ -n "$DEPLOY_EXCEPTION_TEXT_FILE" ] && rm -f "$DEPLOY_EXCEPTION_TEXT_FILE"
  [ -n "$URL_BODY_FILE" ] && rm -f "$URL_BODY_FILE"
  [ -n "$INTERACTIVE_HTTP_BODY_FILE" ] && rm -f "$INTERACTIVE_HTTP_BODY_FILE"
  [ -n "$HEALTHCHECK_DIAGNOSTIC_FILE" ] && rm -f "$HEALTHCHECK_DIAGNOSTIC_FILE"
  # ビルド中に中断した場合、監視用の一時ディレクトリが残るためここで片付ける。
  case "${BUILD_WATCHDOG_DIR:-}" in
    */build-watchdog.*) rm -rf -- "$BUILD_WATCHDOG_DIR" ;;
  esac

  # 本処理が既に失敗している場合は元の終了コードを優先する。
  if [ "$original_status" -ne 0 ]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
}
# ビルド成功・失敗いずれの経路 (途中の exit を含む) でも確実に後始末する
trap cleanup_all EXIT

# URL 応答本文の一時ファイル (URL 確認時のみ使用)
if [ -n "$VERIFY_URL" ]; then
  URL_BODY_FILE="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/url_body.$$")"
fi

# ---- JBoss マスターパスワードの取得 / シークレット注入準備 -------------------
prepare_jboss_password

# compose.yml の environment 型シークレット (既定: JBOSS_MASTER_PASSWORD) は、
# 環境変数が未定義だと compose build が失敗するため、シークレットを使わない
# 場合でも空文字で定義しておく (既に値が入っていればそのまま維持する)。
export JBOSS_MASTER_PASSWORD="${JBOSS_MASTER_PASSWORD:-}"

# ---- JBoss マスターパスワードの伝搬検証 (ビルド前に確認できる段) -------------
# 取得元 → 環境変数 → compose.yml の secrets 定義までは、ビルドを始める前に
# 突き合わせられる。ここで不一致が出た場合、ビルドしても正しい値は届かない。
verify_jboss_password_host_stages

# ---- CloudWatch Agent の設定ファイルチェック (ビルド前に確認できる段) ---------
# compose.yml の cwagent 定義とマウントする設定 JSON は、コンテナを起動する前に
# 突き合わせられる。ここで NG が出た場合、起動しても CloudWatch Logs には届かない。
verify_cwagent_config_definition

# ---- CloudWatch Logs のロググループ準備 (コンテナ起動前) ---------------------
# 実 CloudWatch Logs 宛ての構成で、設定ファイルの log_group_name のロググループが
# 存在しない場合はここで作成する。存在しないままだと PutLogEvents は
# ResourceNotFoundException となり、cwagent の送信が最初から捨てられる。
prepare_cwagent_log_groups

# ---- ビルド前の一時ファイルコピー -------------------------------------------
# ここでコピーしたファイルは EXIT トラップ (cleanup_all) により
# 処理終了後 / 途中終了時のいずれでも自動削除される。
prepare_copy_files

# ---- ビルド -----------------------------------------------------------------
# tty の上書き表示でビルドステップの出力が欠落しないよう、BuildKit の進捗形式を
# 明示する。BUILDKIT_PROGRESS が事前定義されている場合は利用者の指定を維持する。
# 監視は BuildKit の出力を行単位で読むため、行末が改行にならない tty 形式とは
# 併用できない (画面が空のまま溜まってしまう)。監視を優先して plain へ切り替える。
if build_watchdog_enabled && [ "$BUILD_PROGRESS" = "tty" ]; then
  warn "BUILDKIT_PROGRESS=tty はビルド監視と併用できないため plain へ切り替えます。"
  warn "  tty 形式のまま実行する場合は --no-build-watchdog を指定してください。"
  BUILD_PROGRESS="plain"
fi
export BUILDKIT_PROGRESS="$BUILD_PROGRESS"
log "BuildKit のビルドログ表示形式: ${BUILD_PROGRESS}"
if build_watchdog_enabled; then
  log "ビルドの停滞検知: $(build_watchdog_setting_label)"
elif [ "$DRY_RUN" = "true" ]; then
  log "ビルドの停滞検知: DRY-RUN のため行いません。"
else
  log "ビルドの停滞検知: 無効 (--no-build-watchdog または各値に 0 を指定)"
fi
BUILD_OPTS=()
if [ "$NO_CACHE" = "true" ]; then
  BUILD_OPTS+=(--no-cache)
  log "キャッシュを破棄して (--no-cache) ビルドします。"
  if [ "$PRUNE_BUILD_CACHE" != "true" ]; then
    log "  ※ --no-cache は既存キャッシュを読まない指定で、書き込みは行われます。"
    log "     終了時にキャッシュを片付けるには --prune-build-cache を併用してください。"
  fi
fi

# ビルド前の使用量と、世代交代の判定に使う現在のイメージ ID を控える。
report_disk_usage "ビルド前"
# exporting layers の書き出し先が足りているかを、ビルドを始める前に確認する。
check_build_disk_space
remember_current_image_id

# ローカルベースイメージが生成されたか確認する。
# 複数サービス指定時は base の先行ビルド直後に確認し、問題があれば他サービスを
# ビルドする前に中止する。dry-run では実際にビルドしていないため確認をスキップする。
verify_local_image() {
  local image_info image_id image_created image_size
  if [ "$DRY_RUN" = "true" ]; then
    BUILD_IMAGE_INFO="ローカルイメージ確認は DRY-RUN のため未実行: ${LOCAL_IMAGE}"
    log "[DRY-RUN] ローカルベースイメージの存在確認をスキップします: $LOCAL_IMAGE"
  elif ! image_info="$(docker image inspect --format '{{.Id}}|{{.Created}}|{{.Size}}' "$LOCAL_IMAGE" 2>/dev/null)"; then
    BUILD_RESULT_STATUS="失敗"
    BUILD_RESULT_DETAIL="compose build 後にローカルベースイメージを確認できませんでした。"
    err "ローカルベースイメージが見つかりません: $LOCAL_IMAGE (compose.yml の image 指定を確認してください)"
    return 1
  else
    IFS='|' read -r image_id image_created image_size <<< "$image_info"
    # docker が返す作成日時は UTC 固定のため、表示前に JST へ変換する。
    image_created="$(to_jst_display_time "$image_created")"
    BUILD_IMAGE_INFO="image=${LOCAL_IMAGE}, id=${image_id}, created=${image_created}, size=${image_size} bytes"
    log "ビルド結果: image=${LOCAL_IMAGE}, id=${image_id}, created=${image_created}, size=${image_size} bytes"
  fi
  return 0
}

BUILD_RESULT_STATUS="実行中"
BUILD_RESULT_DETAIL="docker compose build を開始しました。"
if [ ${#COMPOSE_SERVICES[@]} -gt 1 ]; then
  # ベースイメージを参照するサービス群と base を同時にビルドすると、base の
  # 完成前に他サービスのビルドが始まる可能性がある。そこで base を第 1 フェーズで
  # 必ず単独ビルドし、成功確認後に残りを 1 回の compose build で並列ビルドする。
  log "複数の compose サービスが指定されました。ベースサービス '${BASE_SERVICE}' を先行ビルドします ..."
  if ! run_build_with_watchdog "ベースサービス ${BASE_SERVICE}" "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} "$BASE_SERVICE"; then
    BUILD_RESULT_STATUS="失敗"
    if [ "$BUILD_TIMED_OUT" = "true" ]; then
      BUILD_RESULT_DETAIL="ベースサービス '${BASE_SERVICE}' のビルドが上限時間 (${BUILD_TIMEOUT} 秒) を超えたため中断しました。"
    else
      BUILD_RESULT_DETAIL="ベースサービス '${BASE_SERVICE}' の先行ビルドに失敗しました。"
    fi
    err "ベースサービス '${BASE_SERVICE}' の先行ビルドに失敗しました"
    exit 1
  fi
  [ "$DRY_RUN" = "true" ] || log "compose build に成功しました (対象サービス: ${BASE_SERVICE})。"
  if ! verify_local_image; then
    exit 1
  fi
  reclaim_previous_image

  # base が明示的な指定に含まれていても再ビルドしない。含まれていない場合も
  # base はビルド専用の前提サービスとして扱い、起動対象には追加しない。
  REMAINING_SERVICES=()
  for _service in "${COMPOSE_SERVICES[@]}"; do
    [ "$_service" = "$BASE_SERVICE" ] || REMAINING_SERVICES+=("$_service")
  done

  if [ ${#REMAINING_SERVICES[@]} -gt 0 ]; then
    log "ベースサービス以外をまとめて並列ビルドします (${COMPOSE_FILE}, 対象サービス: ${REMAINING_SERVICES[*]}) ..."
    if ! run_build_with_watchdog "サービス ${REMAINING_SERVICES[*]}" "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} "${REMAINING_SERVICES[@]}"; then
      BUILD_RESULT_STATUS="失敗"
      if [ "$BUILD_TIMED_OUT" = "true" ]; then
        BUILD_RESULT_DETAIL="ベースサービス以外のビルドが上限時間 (${BUILD_TIMEOUT} 秒) を超えたため中断しました: ${REMAINING_SERVICES[*]}"
      else
        BUILD_RESULT_DETAIL="ベースサービス以外の compose build に失敗しました: ${REMAINING_SERVICES[*]}"
      fi
      err "ベースサービス以外の compose build に失敗しました (対象サービス: ${REMAINING_SERVICES[*]})"
      exit 1
    fi
    [ "$DRY_RUN" = "true" ] || log "compose build に成功しました (対象サービス: ${REMAINING_SERVICES[*]})。"
  else
    log "ベースサービス以外のビルド対象はありません。"
  fi
else
  if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
    log "docker compose build を実行します (${COMPOSE_FILE}, 対象サービス: ${COMPOSE_SERVICES[*]}) ..."
    _build_watchdog_desc="サービス ${COMPOSE_SERVICES[*]}"
  else
    log "docker compose build を実行します (${COMPOSE_FILE}, 全サービス) ..."
    _build_watchdog_desc="全サービス"
  fi
  if ! run_build_with_watchdog "${_build_watchdog_desc}" "${COMPOSE_CMD[@]}" ${COMPOSE_PARALLEL_OPTS[@]+"${COMPOSE_PARALLEL_OPTS[@]}"} -f "$COMPOSE_FILE" build ${COMPOSE_BUILD_PARALLEL_OPTS[@]+"${COMPOSE_BUILD_PARALLEL_OPTS[@]}"} ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} ${COMPOSE_SERVICES[@]+"${COMPOSE_SERVICES[@]}"}; then
    BUILD_RESULT_STATUS="失敗"
    if [ "$BUILD_TIMED_OUT" = "true" ]; then
      BUILD_RESULT_DETAIL="compose build が上限時間 (${BUILD_TIMEOUT} 秒) を超えたため中断しました。"
    else
      BUILD_RESULT_DETAIL="compose build に失敗しました。"
    fi
    err "compose build に失敗しました"
    exit 1
  fi
  if [ "$DRY_RUN" != "true" ]; then
    if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
      log "compose build に成功しました (対象サービス: ${COMPOSE_SERVICES[*]})。"
    else
      log "compose build に成功しました (全サービス)。"
    fi
  fi
  if ! verify_local_image; then
    exit 1
  fi
  reclaim_previous_image
fi

if [ "$DRY_RUN" = "true" ]; then
  BUILD_RESULT_STATUS="DRY-RUN (未実行)"
  BUILD_RESULT_DETAIL="ビルドコマンドのプレビューが完了しました。"
else
  BUILD_RESULT_STATUS="成功"
  BUILD_RESULT_DETAIL="docker compose build とローカルイメージ確認が完了しました。"
fi

# ---- BuildKit シークレットがビルド中コンテナへ届いた値の検証 ------------------
# ビルド済みイメージをベースにしたプローブビルドで /run/secrets の内容を取り出す。
verify_jboss_password_build_secret

# ---- 起動確認が不要ならここで終了 -------------------------------------------
if [ "$NEED_CONTAINER" != "true" ]; then
  if [ "$VERIFY_JBOSS_PASSWORD" = "true" ]; then
    jboss_record_stage "standalone.xml / Elytron CredentialStore の検証" "未確認" \
        "コンテナを起動していないため確認していません。--verify-startup または --verify-url を併用すると、jboss-cli が生成した standalone.xml と CredentialStore まで検証します"
    show_verified_jboss_password_stages
  fi
  if [ "$ENV_LIST_LIMIT" != "all" ] || [ -n "$ENV_LIST_FILE" ]; then
    warn "環境変数一覧はコンテナ起動を伴う動作確認時のみ出力されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$DIRECTORY_TREE_DEPTH_SET" = "true" ]; then
    warn "コンテナ内ディレクトリツリーはコンテナ起動を伴う動作確認時のみ出力されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$DIRECTORY_FILE_LIMIT_SET" = "true" ] || [ ${#DEPLOYMENT_DIR_ENVS[@]} -gt 0 ]; then
    warn "ファイル表示切替と JBoss EAP デプロイ構造はコンテナ起動を伴う動作確認時のみ画面表示されます。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$BUILD_REPORT_DIR_SET" = "true" ]; then
    warn "全量レポートの環境変数・ツリー・JBoss EAP デプロイ構造・JVM パラメータ・OpenTelemetry 設定は、コンテナ未起動のため未取得として記録します。"
  fi
  if [ "$DEPLOY_EXCEPTION_EXCEL_SET" = "true" ] || [ "$DEPLOY_EXCEPTION_TEXT_SET" = "true" ]; then
    warn "WAR デプロイ時 Java 例外解析は、コンテナを起動していないため解析対象のログがありません (結果は「未評価」として出力します)。--verify-startup または --verify-url を併用してください。"
  fi
  if [ "$CWAGENT_VERIFY_ACTIVE" = "true" ]; then
    # 送信先を特定できている場合のみ、送達が未確認であることを明示する。
    if [ ${#CWAGENT_EXPECTED_DESTINATIONS[@]} -gt 0 ]; then
      cwagent_record_stage "ログイベントの送達" "未確認" \
          "コンテナを起動していないため送信状況を確認していません。--verify-startup または --verify-url を併用すると、設定済みのロググループへ実際にログが届くまで確認します"
    fi
    cwagent_show_stage_results "cwagent のログ送信検証"
    finish_cwagent_verification
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY-RUN] ビルドのみが完了しました (実際のビルドは行われていません)。"
  else
    log "ビルドのみが完了しました。"
  fi
  exit 0
fi

# ---- コンテナ起動 -----------------------------------------------------------
if ! start_container; then
  exit 1
fi

# ---- jbosseap 起動確認 ------------------------------------------------------
# --verify-startup 指定時はログから起動完了を確認する。
# (--verify-url のみの場合は起動ログ確認をスキップし、URL のリトライで readiness を担保する)
if [ "$VERIFY_STARTUP" = "true" ]; then
  if ! wait_for_startup; then
    err "起動確認に失敗しました。"
    # デプロイエラー (AP サーバは起動済み) の場合は、既定でコンテナを起動したまま
    # 調査用の対話操作へ入る。--exit-on-deploy-error 指定時は何もせず終了する。
    handle_deploy_error_investigation
    exit 1
  fi
fi

# ---- URL 応答確認 -----------------------------------------------------------
if [ -n "$VERIFY_URL" ]; then
  if ! verify_url; then
    err "URL 応答確認に失敗しました。"
    exit 1
  fi
fi

# ---- CloudWatch Agent の送信状況チェック ------------------------------------
# 起動確認と URL 応答確認を終えた時点 (アプリがログを書き終えた後) に、設定済みの
# ロググループ / ログストリームへ実際にログイベントが届いたかを確認する。
verify_cwagent_log_delivery

# ---- 起動維持後の対話操作 ---------------------------------------------------
if ! run_keep_container_interaction; then
  err "起動維持後の対話操作に失敗しました。コンテナは起動状態のまま残します。"
  exit 1
fi

show_verified_container_envs
show_verified_container_directory_trees
show_verified_container_deployment_structures
show_verified_container_jvm_parameters
show_verified_container_otel_settings

# WAR のデプロイ処理で Java の例外が投げられていないかを解析する。
# 起動確認が成功していても、デプロイ済みアプリの初期化で例外が出ている
# ことがあるため、成功経路でも必ず実行する。
analyze_war_deploy_exceptions 0

# jboss-cli が生成した standalone.xml と Elytron CredentialStore まで確認し、
# ビルド前の段と合わせて伝搬検証の結果をまとめて出力する。
verify_jboss_password_container_stages
show_verified_jboss_password_stages

# cwagent の検証結果を終了コードへ反映する (--cwagent-required 指定時のみ)。
finish_cwagent_verification

if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (実際の変更は行われていません)。"
else
  log "ビルドおよび確認が完了しました。"
fi
exit 0
