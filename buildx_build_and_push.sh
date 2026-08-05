#!/usr/bin/env bash
#
# buildx_build_and_push.sh
# -----------------------------------------------------------------------------
# 想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。
#
# compose.yml を使う build_and_push.sh とは別に、docker buildx コマンドで
# ローカルベースイメージ (既定: j1/base.local) をビルドし、
#   aws ecr get-login-password | docker login  (ECR ログイン)
#   docker image tag                           (ECR 用タグ付け)
#   docker image push                          (ECR へプッシュ)
# を実行して、結果として imagedefinition.json を出力する。
#
# 権限まわりの前提 (build_and_push.sh と同じ):
#   - スクリプト開始時に、事前に aws login --remote による認証操作が実行されて
#     いるかをチェックし、未認証の場合は認証を促す警告を出して終了する (exit 1)。
#   - このステージでは CodeCommit の操作は不要。ECR の操作権限のみが必要。
#   - 現在の操作権限で ECR を操作できない場合の挙動を 2 通りから選べる:
#       (A) 既定 (--warn-only)  : スイッチバックを促す警告を出して終了 (exit 1)
#       (B)     (--auto-switchback): 別チーム提供のスイッチバック用シェルを
#                                    source で呼び出し、自動的にスイッチバック
#                                    してから処理を継続する。
#   - スイッチバック用シェルの配置場所は --switchback-shell で指定可能。
#
# JBoss マスターパスワード (BuildKit シークレット):
#   - buildx build の前に、パラメータストアの指定キー (--jboss-password-param)
#     から JBoss のマスターパスワードを取得できる。パラメータストアから取得せず
#     直接渡す (--jboss-password) ことも可能。
#   - 取得したマスターパスワードは環境変数 (--jboss-password-env, 既定:
#     JBOSS_MASTER_PASSWORD) へ export し、buildx の
#     --secret id=<id>,env=<環境変数名> (environment 型シークレット) として
#     安全にビルドへ注入する (イメージのレイヤや履歴には残らない)。
#
# 使い方:
#   ./buildx_build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
#       --jboss-password-param /j1/jboss/master-password \
#       --auto-switchback --switchback-shell /opt/team/switchback.sh
# -----------------------------------------------------------------------------

set -uo pipefail

# ---- 表示タイムゾーン (JST 固定) --------------------------------------------
# ホストや CI が UTC でも、ログ・イメージタグ・ログファイル名の時刻を JST に揃える。
# tzdata を持たない環境でも +09:00 になるよう、Asia/Tokyo が使えない場合は tzdata
# 不要の POSIX 形式 (JST-9) へフォールバックする。
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
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
REGISTRY="${ECR_REGISTRY:-}"      # ECR レジストリ名(URL)。未指定なら <account>.dkr.ecr.<region>.amazonaws.com を組み立てる
REPOSITORY="baseimage"            # ECR 側リポジトリ名 (= プッシュするイメージ名)。ECR / Docker の規則により小文字のみ
TAG_PREFIX="BaseImage"            # イメージタグの接頭辞。タグは <TAG_PREFIX>-<YYYYMMDDHHMMSS> となる (リポジトリ名とは独立。タグは大文字可)
LOCAL_IMAGE="j1/base.local"       # buildx build で生成するローカルベースイメージ名
CONTAINER_NAME=""                 # imagedefinition.json の name。未指定なら REPOSITORY を使用
DOCKERFILE="Dockerfile"           # buildx build に渡す Dockerfile
BUILD_CONTEXT="."                 # buildx build のビルドコンテキスト
PLATFORM=""                       # 例: linux/amd64 (--load のため単一プラットフォームのみ)
BUILDER=""                        # 使用する buildx ビルダー名 (未指定なら現在のビルダー)
BUILD_ARGS=()                     # --build-arg KEY=VALUE (繰り返し指定可)
BUILD_CONTEXTS=()                 # --build-context NAME=VALUE (追加のビルドコンテキスト, 繰り返し指定可)
SECRETS=()                        # --secret id=...,src=... 等 (ビルドシークレット, 繰り返し指定可)
PROGRESS=""                       # buildx の進捗表示形式 (auto/plain/tty/rawjson)。未指定なら buildx 既定
NO_CACHE="false"                  # true: キャッシュを破棄してビルド (--no-cache)

# ---- ビルドの停滞検知・進捗表示 ---------------------------------------------
# BuildKit の "exporting to image" / "exporting layers" は、ビルドしたレイヤを
# Docker のイメージストアへ書き出す段 (buildx --load ではさらに importing to
# docker が続く)。--progress=plain では開始の 1 行を出したあと、完了するまで
# 追加の出力が一切出ない。ベースイメージのように 1 レイヤが大きいとこの段だけで
# 数分〜数十分かかることがあり、画面が止まったままプロンプトが戻らないように
# 見える (実際には書き出しが進んでいることが多い)。
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
BUILD_MIN_FREE_GIB="5"            # 開始前に警告する data root 空き容量のしきい値 (GiB)
BUILD_WATCHDOG_DIR=""             # 監視用の一時ディレクトリ
BUILD_WATCHDOG_DATA_ROOT=""       # docker data root (ローカル接続時のみ特定できる)
BUILD_WATCHDOG_DATA_ROOT_RESOLVED="false"
BUILD_TIMED_OUT="false"           # 上限時間で中断したか
OUTPUT_FILE="imagedefinition.json"
ECR_USERNAME="AWS"                # ECR ログイン時の固定ユーザー名
DRY_RUN="false"                   # true: 実際の変更は行わず、実行内容のプレビューのみ表示
LOG_DIR=""                        # 指定時: コンソール出力をこのディレクトリのログファイルにも保存する
LOG_FILE=""                       # --log-dir 指定時に組み立てる実際のログファイルパス
TEE_PID=""                        # ログ複製用 tee (プロセス置換) の PID

# 一時ファイル (SSM のエラー出力 / push ログ)。途中終了時も残さないよう EXIT トラップで削除する。
TEMP_FILES=()

# ビルド前に一時コピーし、ビルド後に自動削除するファイル群
# COPY_SPECS: "SRC:DEST_DIR" の配列 (--copy-file で繰り返し指定)
# COPIED_FILES: 実際にコピーしたコピー先ファイルパス (削除対象として記録)
COPY_SPECS=()
COPIED_FILES=()

# スイッチバック関連
SWITCHBACK_SHELL="${SWITCHBACK_SHELL:-}"
AUTO_SWITCHBACK="false"           # false: 警告して終了 / true: 自動スイッチバック

# JBoss マスターパスワード (BuildKit シークレット) 関連
JBOSS_PASSWORD_PARAM=""           # パラメータストアのキー名 (--jboss-password-param)
JBOSS_PASSWORD_VALUE=""           # 直接指定されたマスターパスワード (--jboss-password)
JBOSS_PASSWORD_ENV="JBOSS_MASTER_PASSWORD"  # シークレット受け渡しに使う環境変数名
JBOSS_PASSWORD_ENV_SET="false"    # --jboss-password-env が明示指定されたか
JBOSS_SECRET_ID="jboss_master_password"     # buildx --secret の id (Dockerfile から参照する名前)
JBOSS_SECRET_ENABLED="false"      # マスターパスワードをビルドシークレットとして注入するか

# ---- ログ用ヘルパ -----------------------------------------------------------
# スクリプト開始時刻 (処理実行時間の算出に使用)
START_EPOCH="$(date +%s)"
# 表示する時刻はすべて JST。UTC と読み違えないよう、必ずタイムゾーン名を併記する。
now_display_time() { printf '%s %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$DISPLAY_TZ_LABEL"; }
log()  { printf '[%s] %s\n'  "$(now_display_time)" "$*"; }
warn() { printf '[%s] [WARN] %s\n'  "$(now_display_time)" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(now_display_time)" "$*" >&2; }
# 診断ガイド出力用 (タイムスタンプ等の接頭辞を付けず、そのまま整形表示する)
diag() { printf '%s\n' "$*" >&2; }
# dry-run 時は実行内容を表示するだけ、通常時はそのままコマンドを実行する。
run()  {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[%s] [DRY-RUN] %s\n' "$(now_display_time)" "$*"
    return 0
  fi
  "$@"
}

# 開始時刻からの経過時間 (処理実行時間) を人間可読な形式でログ出力する。
# EXIT トラップから呼ばれるため、成功・失敗いずれの経路でも記録される。
log_elapsed() {
  local end_epoch elapsed
  end_epoch="$(date +%s)"
  elapsed=$(( end_epoch - START_EPOCH ))
  log "処理実行時間: ${elapsed} 秒 ($(printf '%02d:%02d:%02d' \
      "$(( elapsed / 3600 ))" "$(( (elapsed % 3600) / 60 ))" "$(( elapsed % 60 ))"))"
}

# ログ複製 (tee) への書き込み側を閉じて EOF を通知し、tee が書き切るまで待つ。
# これを行わないとシェルの終了と tee の書き込みが競合し、ログファイル末尾の行
# (処理実行時間など) が欠けることがある。出力先を閉じるため EXIT トラップの最後で呼ぶ。
finish_logging() {
  [ -n "$TEE_PID" ] || return 0
  exec 1>&- 2>&-
  wait "$TEE_PID" 2>/dev/null
  TEE_PID=""
}

# 一時ファイルを作成してパスを返す。mktemp が使えない環境で予測可能なパス
# (/tmp/xxx.$$) へフォールバックすると、シンボリックリンク経由の上書きや
# 他プロセスとの衝突を招くため、その場で失敗させる。
new_temp_file() {
  local f
  f="$(mktemp 2>/dev/null)" || f=""
  if [ -z "$f" ]; then
    err "一時ファイルを作成できませんでした (mktemp が利用できません)。TMPDIR を確認してください。"
    return 1
  fi
  printf '%s' "$f"
}

# EXIT トラップから呼び出す一時ファイルの削除処理 (途中終了・中断時も残さない)。
cleanup_temp_files() {
  [ ${#TEMP_FILES[@]} -eq 0 ] && return 0
  local f
  for f in "${TEMP_FILES[@]}"; do
    [ -n "$f" ] && rm -f "$f"
  done
  TEMP_FILES=()
  return 0
}

# imagedefinition.json へ埋め込む値を JSON 文字列としてエスケープする。
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

usage() {
  cat <<'EOF'
Usage: buildx_build_and_push.sh [OPTIONS]

docker buildx でビルドし、ECR ログイン / docker image tag / docker image push を
実行するスクリプト (compose.yml を使う build_and_push.sh の buildx 版)。

Options:
  --account-id ID          ECR レジストリの AWS アカウント ID (env: AWS_ACCOUNT_ID)
  --region REGION          AWS リージョン (既定: ap-northeast-1 / env: AWS_REGION)
  --registry URL           ECR レジストリ名(URL) を明示指定 (env: ECR_REGISTRY)
                           例: 123456789012.dkr.ecr.ap-northeast-1.amazonaws.com
                           (未指定時は <account-id>.dkr.ecr.<region>.amazonaws.com を組み立て)
  --repository NAME        ECR リポジトリ名 = プッシュするイメージ名 (既定: baseimage)
                           ECR / Docker の規則により小文字英数字と . _ - / のみ使用できる
  --tag-prefix PREFIX      イメージタグの接頭辞 (既定: BaseImage)。リポジトリ名とは独立に
                           指定でき、タグは <PREFIX>-<YYYYMMDDHHMMSS> となる
                           例: BaseImage-20260702153000
                           (タグは大文字も使用できる。使用可能文字: 英数字 . _ -)
  --local-image NAME       buildx build で生成するローカルイメージ名 (既定: j1/base.local)
  --container-name NAME    imagedefinition.json の name (既定: --repository の値)

  --dockerfile FILE        Dockerfile のパス (既定: Dockerfile)
  --context DIR            ビルドコンテキスト (既定: .)
  --platform PLATFORM      ターゲットプラットフォーム (例: linux/amd64)。
                           ローカルに --load するため単一プラットフォームのみ指定可
  --builder NAME           使用する buildx ビルダー名 (未指定なら現在のビルダー)
  --build-arg KEY=VALUE    ビルド引数 (繰り返し指定可)
  --build-context NAME=VALUE
                           追加のビルドコンテキスト (繰り返し指定可)。
                           Dockerfile の FROM / COPY --from= で名前参照できる。
                           VALUE にはローカルディレクトリ / Git URL / イメージ
                           (docker-image://...) / URL 等を指定できる。
                           例: --build-context libs=./libs \
                               --build-context alpine=docker-image://alpine:3.20
  --secret SPEC            ビルドシークレット (繰り返し指定可)。Dockerfile の
                           RUN --mount=type=secret,id=... から参照できる。
                           SPEC は buildx の --secret と同一書式。
                           例: --secret id=npmrc,src=./.npmrc \
                               --secret id=token,env=GITHUB_TOKEN
  --progress MODE          進捗表示形式 (auto/plain/tty/rawjson)。未指定なら buildx 既定。
                           CI ログには plain が読みやすい。
                           ※ ビルド監視が有効な間は tty を plain へ切り替える
                             (監視は行単位でビルド出力を読むため)。
  --no-cache               キャッシュを破棄して buildx build する
  --build-progress-interval SEC
                           ビルド中に進捗を表示する間隔 (既定: 30)。0 で行わない。
                           BuildKit の "exporting to image" / "exporting layers"
                           は、開始の 1 行を出したあと完了するまで追加の出力が
                           出ない。ベースイメージのようにレイヤが大きいとこの段
                           だけで数分〜数十分かかり、停止したのか進んでいるのか
                           画面から判断できなくなる。そこで一定間隔で「経過時間 /
                           直近の出力からの経過 / BuildKit のフェーズ / Docker
                           data root の空き容量の増減」を表示する。空き容量が
                           減り続けていれば遅いだけで進行中、変化がなければ停滞と
                           判断できる。
  --build-stall-timeout SEC
                           ビルド出力がこの秒数途切れたら停滞と判断し、Docker
                           daemon の応答・空き容量・inode を調べて想定原因と
                           対処方法を表示する (既定: 300)。0 で行わない。
                           検知しても処理は継続する (中断はしない)。
  --build-timeout SEC      ビルド全体の上限秒数 (既定: 0 = 無制限)。超えた場合は
                           診断を表示したうえで SIGTERM でビルドを中断し
                           (20 秒後に SIGKILL)、終了コード 1 で終了する。
  --no-build-watchdog      上記の監視をすべて行わず、ビルド出力をそのまま流す。

  --output FILE            imagedefinition の出力先 (既定: imagedefinition.json)
  --log-dir DIR            コンソールに出力されるログを、DIR 配下のログファイルにも
                           保存する (画面表示は従来どおり継続)。ログ末尾には処理実行
                           時間 (経過秒数) も記録される。
                           - DIR が存在しない場合は自動作成する (mkdir -p)
                           - ファイル名は buildx_build_and_push_<YYYYMMDDHHMMSS>.log
  --dry-run                実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は
                           行わず、実行される内容のプレビューのみ表示する

  --copy-file SRC:DEST_DIR ビルド前に SRC を DEST_DIR ディレクトリへコピーし、
                           ビルド終了後 (成功・失敗を問わず) に自動削除する。
                           複数ファイルに対応するため繰り返し指定できる。
                           例: --copy-file .npmrc:./app --copy-file cert.pem:./app/certs
                           - DEST_DIR は既存ディレクトリである必要がある
                           - コピー先に同名ファイルが既存の場合は事故防止のため中止する

  --jboss-password-param NAME
                           JBoss のマスターパスワードを AWS パラメータストア
                           (SSM Parameter Store) の指定キー NAME から取得する
                           (aws ssm get-parameter --with-decryption)。
                           取得した値は --jboss-password-env の環境変数へ export され、
                           buildx の --secret id=<id>,env=<環境変数名> として
                           BuildKit シークレット注入される。Dockerfile からは
                           RUN --mount=type=secret,id=<id> で参照できる。
  --jboss-password VALUE   JBoss のマスターパスワードを直接指定する
                           (パラメータストアから取得しない場合)。
                           --jboss-password-param とは同時に指定できない。
                           ※ コマンドライン (ps / シェル履歴) に平文が残るため、
                             可能なら --jboss-password-param か、事前 export +
                             --jboss-password-env の利用を推奨。
  --jboss-password-env NAME
                           シークレットの受け渡しに使う環境変数名
                           (既定: JBOSS_MASTER_PASSWORD)。
                           このオプションのみを指定した場合は、事前に export
                           済みの環境変数の値をそのままパスワードとして使う。
  --jboss-secret-id ID     BuildKit シークレットの id (既定: jboss_master_password)。
                           Dockerfile の RUN --mount=type=secret,id=... と一致させる。

  --switchback-shell PATH  別チーム提供のスイッチバック用シェルのパス (source で呼び出し)
  --auto-switchback        ECR 権限が無い場合に自動でスイッチバックして継続する
  --warn-only              ECR 権限が無い場合に警告して終了する (既定)

  -h, --help               このヘルプを表示

備考:
  スクリプト開始時に AWS 認証 (aws login --remote 実施済みか) を確認し、
  未認証の場合は認証を促す警告を表示して終了する (exit 1)。
EOF
}

# ---- ログファイル出力の準備 (引数パースより前に行う) ------------------------
# --log-dir を先に解釈し、以降のコンソール出力 (stdout/stderr) を tee でログファイルへ
# 複製する。画面表示はそのまま継続し、時系列の順序を保つため stdout/stderr を
# 同一の tee にまとめる。パースエラー (不明オプション等) もログへ残すため、本パース
# より前のこの位置で設定する (--log-dir は後段の本パースでも受理する)。
# 走査では「オプションの値」をオプション名と取り違えないよう、値を取るオプションの
# 次の引数を読み飛ばす。ここに無いオプションは値なしとして扱う。
arg_takes_value() {
  case "$1" in
    --account-id|--region|--registry|--repository|--tag-prefix|--local-image) return 0 ;;
    --container-name|--dockerfile|--context|--platform|--builder|--build-arg) return 0 ;;
    --build-context|--secret|--progress|--output|--log-dir|--copy-file) return 0 ;;
    --jboss-password-param|--jboss-password|--jboss-password-env|--jboss-secret-id) return 0 ;;
    --switchback-shell) return 0 ;;
  esac
  return 1
}

_scan_args=("$@")
_scan_i=0
while [ "$_scan_i" -lt "${#_scan_args[@]}" ]; do
  _arg="${_scan_args[$_scan_i]}"
  _scan_i=$(( _scan_i + 1 ))
  if arg_takes_value "$_arg"; then
    if [ "$_scan_i" -lt "${#_scan_args[@]}" ]; then
      [ "$_arg" = "--log-dir" ] && LOG_DIR="${_scan_args[$_scan_i]}"
      _scan_i=$(( _scan_i + 1 ))
    fi
  fi
done

if [ -n "$LOG_DIR" ]; then
  if ! mkdir -p "$LOG_DIR"; then
    err "ログ出力先ディレクトリを作成できませんでした: $LOG_DIR"
    exit 1
  fi
  LOG_FILE="${LOG_DIR%/}/buildx_build_and_push_$(date '+%Y%m%d%H%M%S').log"
  # 以降の全出力を tee で LOG_FILE にも書き込む (画面にも出力)
  exec > >(tee -a "$LOG_FILE") 2>&1
  TEE_PID=$!
  # このパス以降のどの経路 (パースエラー等の途中 exit 含む) でも処理実行時間を残す。
  # 後段で一時ファイル削除も伴うトラップに差し替える。
  trap 'log_elapsed; finish_logging' EXIT
  log "コンソール出力をログファイルにも保存します: $LOG_FILE"
fi

# ---- 引数パース -------------------------------------------------------------
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
    --account-id)       need_value "$1" $#; ACCOUNT_ID="$2"; shift 2 ;;
    --region)           need_value "$1" $#; REGION="$2"; shift 2 ;;
    --registry)         need_value "$1" $#; REGISTRY="$2"; shift 2 ;;
    --repository)       need_value "$1" $#; REPOSITORY="$2"; shift 2 ;;
    --tag-prefix)       need_value "$1" $#; TAG_PREFIX="$2"; shift 2 ;;
    --local-image)      need_value "$1" $#; LOCAL_IMAGE="$2"; shift 2 ;;
    --container-name)   need_value "$1" $#; CONTAINER_NAME="$2"; shift 2 ;;
    --dockerfile)       need_value "$1" $#; DOCKERFILE="$2"; shift 2 ;;
    --context)          need_value "$1" $#; BUILD_CONTEXT="$2"; shift 2 ;;
    --platform)         need_value "$1" $#; PLATFORM="$2"; shift 2 ;;
    --builder)          need_value "$1" $#; BUILDER="$2"; shift 2 ;;
    --build-arg)        need_value "$1" $#; BUILD_ARGS+=("$2"); shift 2 ;;
    --build-context)    need_value "$1" $#; BUILD_CONTEXTS+=("$2"); shift 2 ;;
    --secret)           need_value "$1" $#; SECRETS+=("$2"); shift 2 ;;
    --progress)         need_value "$1" $#; PROGRESS="$2"; shift 2 ;;
    --no-cache)         NO_CACHE="true"; shift ;;
    --build-progress-interval) need_value "$1" $#; BUILD_PROGRESS_INTERVAL="$2"; shift 2 ;;
    --build-stall-timeout)     need_value "$1" $#; BUILD_STALL_TIMEOUT="$2"; shift 2 ;;
    --build-timeout)           need_value "$1" $#; BUILD_TIMEOUT="$2"; shift 2 ;;
    --no-build-watchdog)       BUILD_WATCHDOG="false"; shift ;;
    --output)           need_value "$1" $#; OUTPUT_FILE="$2"; shift 2 ;;
    --log-dir)          need_value "$1" $#; LOG_DIR="$2"; shift 2 ;;  # 冒頭でログ複製を設定済み (値の再取得のみ)
    --dry-run)          DRY_RUN="true"; shift ;;
    --copy-file)        need_value "$1" $#; COPY_SPECS+=("$2"); shift 2 ;;
    --jboss-password-param) need_value "$1" $#; JBOSS_PASSWORD_PARAM="$2"; shift 2 ;;
    --jboss-password)       need_value "$1" $#; JBOSS_PASSWORD_VALUE="$2"; shift 2 ;;
    --jboss-password-env)   need_value "$1" $#; JBOSS_PASSWORD_ENV="$2"; JBOSS_PASSWORD_ENV_SET="true"; shift 2 ;;
    --jboss-secret-id)      need_value "$1" $#; JBOSS_SECRET_ID="$2"; shift 2 ;;
    --switchback-shell) need_value "$1" $#; SWITCHBACK_SHELL="$2"; shift 2 ;;
    --auto-switchback)  AUTO_SWITCHBACK="true"; shift ;;
    --warn-only)        AUTO_SWITCHBACK="false"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) err "不明なオプション: $1"; usage; exit 2 ;;
  esac
done

# 引数パース以降のどの経路 (途中の exit を含む) でも処理実行時間を記録する。
# 後段で一時ファイル削除も伴うトラップに差し替えるが、それより前の early-exit
# (依存コマンド不足など) でも経過時間が残るよう、ここで先に仕掛けておく。
trap 'cleanup_temp_files; log_elapsed; finish_logging' EXIT

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
if [ -z "$JBOSS_SECRET_ID" ]; then
  err "--jboss-secret-id に空の値は指定できません"
  exit 2
fi

# ---- 依存コマンド確認 -------------------------------------------------------
for cmd in aws docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "必須コマンドが見つかりません: $cmd"
    exit 1
  fi
done

# docker buildx プラグインの確認
if ! docker buildx version >/dev/null 2>&1; then
  err "docker buildx が利用できません。docker-buildx-plugin をインストールしてください。"
  err "  例) dnf install docker-buildx-plugin"
  exit 1
fi

# ---- Docker デーモンへの接続確認 --------------------------------------------
# デーモン停止や権限不足はビルド開始まで気づけないため、ここで先に確認する。
if docker info >/dev/null 2>&1; then
  :
elif [ "$DRY_RUN" = "true" ]; then
  warn "Docker デーモンへ接続できませんが、DRY-RUN のため中止せずにプレビューを継続します。"
else
  err "Docker デーモンへ接続できません (docker info に失敗)。"
  err "  デーモンの起動状態 (systemctl status docker) と、実行ユーザーが docker グループに"
  err "  所属しているかを確認してください。"
  exit 1
fi

# ---- AWS 認証 (aws login --remote) 済みかのチェック --------------------------
# スクリプト実行開始時に、事前に aws login --remote による認証操作が実行されて
# いるかを sts get-caller-identity で確認する。未認証なら認証を促して終了する。
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

# --load で docker イメージストアに取り込むため、単一プラットフォームのみ許可する
if [ -n "$PLATFORM" ] && [ "${PLATFORM#*,}" != "$PLATFORM" ]; then
  err "--platform に複数プラットフォームは指定できません: $PLATFORM"
  err "  (docker image tag / docker image push を使うため --load で単一イメージとして取り込む必要があります)"
  exit 2
fi

# --progress は buildx が受け付ける形式のみ許可する
if [ -n "$PROGRESS" ]; then
  case "$PROGRESS" in
    auto|plain|tty|rawjson|quiet) ;;
    *)
      err "--progress に不正な値が指定されました: $PROGRESS"
      err "  指定可能な値: auto / plain / tty / rawjson / quiet"
      exit 2 ;;
  esac
fi

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
validate_non_negative_integer "$BUILD_PROGRESS_INTERVAL" "--build-progress-interval" || exit 2
validate_non_negative_integer "$BUILD_STALL_TIMEOUT" "--build-stall-timeout" || exit 2
validate_non_negative_integer "$BUILD_TIMEOUT" "--build-timeout" || exit 2

# ---- レジストリ URL の組み立て ---------------------------------------------
if [ -z "$REGISTRY" ]; then
  if [ -z "$ACCOUNT_ID" ]; then
    err "--account-id もしくは --registry を指定してください (レジストリ URL を決定できません)"
    exit 2
  fi
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi
# 末尾のスラッシュが残ると <registry>//<repository> となり参照が壊れる
REGISTRY="${REGISTRY%/}"

[ -n "$CONTAINER_NAME" ] || CONTAINER_NAME="$REPOSITORY"

# ---- イメージ参照の事前検証 -------------------------------------------------
# ECR / Docker のリポジトリ名は小文字英数字と . _ - / のみ。検証しないと、時間の
# かかるビルドが完了した後の docker image tag で
# 'invalid reference format: repository name must be lowercase' となって失敗する。
if ! printf '%s' "$REPOSITORY" \
    | grep -qE '^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$'; then
  err "--repository には小文字英数字と . _ - / のみ指定できます: ${REPOSITORY}"
  err "  ECR / Docker のリポジトリ名は大文字を含められません (例: baseimage, j1/base)。"
  exit 2
fi
# タグは <TAG_PREFIX>-<YYYYMMDDHHMMSS> (接尾辞 15 文字)。タグ全体は 128 文字以内で、
# 先頭は英数字か _、以降は英数字と . _ - のみ (タグは大文字も使用できる)。
if ! printf '%s' "$TAG_PREFIX" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9._-]{0,112}$'; then
  err "--tag-prefix には英数字と . _ - のみ (先頭は英数字か _、113 文字以内) を指定してください: ${TAG_PREFIX}"
  exit 2
fi

if [ "$DRY_RUN" = "true" ]; then
  log "*** DRY-RUN モードです。実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は行いません。 ***"
fi

# ---- ECR 操作権限チェック ---------------------------------------------------
# ecr:GetAuthorizationToken を要求する get-login-password を叩けるかどうかで判定する。
# 成功すればパスワードを取得できるので、そのまま docker login に流用する。
# 失敗理由 (権限不足 / 認証切れ / ネットワーク不通 / リージョン誤り) を区別できるよう、
# aws の標準エラー出力は捨てずに ECR_AUTH_ERROR へ保持して失敗時に表示する。
ECR_PASSWORD=""
ECR_AUTH_ERROR=""
check_ecr_permission() {
  local errfile status
  ECR_AUTH_ERROR=""
  errfile="$(new_temp_file)" || return 1
  TEMP_FILES+=("$errfile")
  ECR_PASSWORD="$(aws ecr get-login-password --region "$REGION" 2>"$errfile")"
  status=$?
  ECR_AUTH_ERROR="$(cat "$errfile")"
  rm -f "$errfile"
  if [ "$status" -ne 0 ] || [ -z "$ECR_PASSWORD" ]; then
    return 1
  fi
  return 0
}

# ECR 権限チェック失敗時に、aws が返したエラー本文を警告として表示する。
warn_ecr_auth_error() {
  [ -n "$ECR_AUTH_ERROR" ] || return 0
  warn "aws ecr get-login-password のエラー内容:"
  printf '%s\n' "$ECR_AUTH_ERROR" | sed 's/^/    /' >&2
}

# ---- スイッチバック処理 -----------------------------------------------------
do_switchback() {
  if [ -z "$SWITCHBACK_SHELL" ]; then
    err "スイッチバック用シェルのパスが未指定です。--switchback-shell で指定してください。"
    return 1
  fi
  if [ ! -f "$SWITCHBACK_SHELL" ]; then
    err "スイッチバック用シェルが見つかりません: $SWITCHBACK_SHELL"
    return 1
  fi
  log "スイッチバック用シェルを source で呼び出します: $SWITCHBACK_SHELL"
  # 別チーム提供のシェルを現在のシェルに source して認証情報 / ロールを切り替える。
  # shellcheck disable=SC1090
  source "$SWITCHBACK_SHELL"
  return 0
}

# ---- JBoss マスターパスワードの取得 / BuildKit シークレット注入準備 ----------
# --jboss-password-param / --jboss-password / --jboss-password-env のいずれかが
# 指定された場合に、マスターパスワードを取得して環境変数へ export する。
# buildx build には --secret id=<JBOSS_SECRET_ID>,env=<環境変数名> として渡し、
# Dockerfile からは RUN --mount=type=secret,id=<JBOSS_SECRET_ID> で参照する。
# パスワードの値そのものは、ログにもコマンドラインにも出力しない。
prepare_jboss_password() {
  [ "$JBOSS_SECRET_ENABLED" = "true" ] || return 0
  local password=""
  if [ -n "$JBOSS_PASSWORD_PARAM" ]; then
    log "パラメータストアから JBoss マスターパスワードを取得します: ${JBOSS_PASSWORD_PARAM} (region=${REGION}) ..."
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] aws ssm get-parameter --name ${JBOSS_PASSWORD_PARAM} --with-decryption --region ${REGION} (値の取得・表示は行いません)"
    else
      local ssm_errfile
      ssm_errfile="$(new_temp_file)" || exit 1
      TEMP_FILES+=("$ssm_errfile")
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
    log "直接指定された JBoss マスターパスワードを使用します (値はログに出力しません)。"
    password="$JBOSS_PASSWORD_VALUE"
  else
    # --jboss-password-env のみ指定: 事前に export 済みの環境変数の値をそのまま使う
    password="${!JBOSS_PASSWORD_ENV:-}"
    if [ -z "$password" ] && [ "$DRY_RUN" != "true" ]; then
      err "環境変数 ${JBOSS_PASSWORD_ENV} が未設定または空です。"
      err "  --jboss-password-param / --jboss-password で渡すか、事前に export してから再実行してください。"
      exit 1
    fi
    log "既存の環境変数 ${JBOSS_PASSWORD_ENV} の値を JBoss マスターパスワードとして使用します。"
  fi
  export "${JBOSS_PASSWORD_ENV}=${password}"
  log "JBoss マスターパスワードを環境変数 ${JBOSS_PASSWORD_ENV} 経由で BuildKit シークレット (id=${JBOSS_SECRET_ID}) として注入します。"
}

# ---- ビルド前後の一時ファイルコピー / 自動削除 ------------------------------
# --copy-file で指定した SRC:DEST_DIR を検証し、SRC を DEST_DIR へコピーする。
# コピーしたコピー先パスは COPIED_FILES に記録し、EXIT トラップで自動削除する。
prepare_copy_files() {
  [ ${#COPY_SPECS[@]} -eq 0 ] && return 0
  log "ビルド前の一時ファイルコピーを実行します (${#COPY_SPECS[@]} 件) ..."
  local spec src dest_dir dest
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
    # 既存ファイルを上書き→後で削除すると元ファイルを消してしまうため中止する
    if [ -e "$dest" ]; then
      err "コピー先に同名ファイルが既に存在します: $dest (自動削除による事故防止のため中止します)"
      exit 1
    fi
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] cp $src -> $dest (ビルド後に自動削除)"
    else
      if ! cp "$src" "$dest"; then
        err "ファイルのコピーに失敗しました: $src -> $dest"
        exit 1
      fi
      log "コピーしました: $src -> $dest"
    fi
    # dry-run でも記録し、削除プレビューを表示できるようにする
    COPIED_FILES+=("$dest")
  done
}

# EXIT トラップから呼び出す削除処理。コピーしたファイルのみ削除する。
cleanup_copied_files() {
  [ ${#COPIED_FILES[@]} -eq 0 ] && return 0
  log "コピーした一時ファイルを削除します (${#COPIED_FILES[@]} 件) ..."
  local f
  for f in "${COPIED_FILES[@]}"; do
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY-RUN] rm -f $f"
    elif rm -f "$f"; then
      log "削除しました: $f"
    else
      warn "一時ファイルの削除に失敗しました: $f (手動で削除してください)"
    fi
  done
  COPIED_FILES=()
}
# ビルド成功・失敗いずれの経路 (途中の exit を含む) でも確実に削除する。
# 併せて一時ファイルの削除と処理実行時間 (経過秒数) の記録を行い、最後にログ複製を
# 閉じる。SIGINT / SIGTERM で中断した場合も EXIT トラップが実行されるため、
# コピーしたファイルは残らない。
trap 'cleanup_copied_files; cleanup_temp_files; log_elapsed; finish_logging' EXIT

# ---- docker push 失敗時の原因診断 / 調査ガイド ------------------------------
# 各原因カテゴリごとの詳細な説明・AWS CLI 調査コマンド・AWS コンソール確認箇所を出力する。
# ${ACCOUNT_ID:-<account-id>} 等でアカウント ID 未指定時も雛形として読める形にする。
_repo_arn() { printf 'arn:aws:ecr:%s:%s:repository/%s' "$REGION" "${ACCOUNT_ID:-<account-id>}" "$REPOSITORY"; }

guide_iam() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 A】IAM 権限エラー (ecr:* アクションの許可不足)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  docker push は内部で以下の ECR API を順に呼び出します。いずれかの"
  diag "  権限が不足すると 'denied' / 'not authorized to perform' になります:"
  diag "    - ecr:GetAuthorizationToken       (ログイン)"
  diag "    - ecr:BatchCheckLayerAvailability (レイヤ存在確認)"
  diag "    - ecr:InitiateLayerUpload         (アップロード開始)"
  diag "    - ecr:UploadLayerPart             (レイヤ送信)"
  diag "    - ecr:CompleteLayerUpload         (アップロード完了)"
  diag "    - ecr:PutImage                    (マニフェスト登録)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    # 1) 今どの IAM プリンシパルとして実行しているか"
  diag "    aws sts get-caller-identity"
  diag "    # 2) トークン取得可否 (= ecr:GetAuthorizationToken の可否)"
  diag "    aws ecr get-login-password --region ${REGION} >/dev/null && echo OK"
  diag "    # 3) 実際に拒否されているアクションをポリシーシミュレータで特定"
  diag "    aws iam simulate-principal-policy \\"
  diag "      --policy-source-arn <上記 get-caller-identity の Arn> \\"
  diag "      --action-names ecr:InitiateLayerUpload ecr:UploadLayerPart \\"
  diag "                     ecr:CompleteLayerUpload ecr:PutImage \\"
  diag "                     ecr:BatchCheckLayerAvailability \\"
  diag "      --resource-arns $(_repo_arn)"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - IAM > ユーザー/ロール > (get-caller-identity のプリンシパル) >"
  diag "      「アクセス許可」で ECR 系ポリシーがアタッチされているか"
  diag "    - CloudTrail > イベント履歴 で errorCode=AccessDenied を検索し、"
  diag "      eventName (どの ecr:* が拒否されたか) と userIdentity を確認"
}

guide_endpoint_policy() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 B】ECR エンドポイント権限設定エラー (ポリシーによる拒否)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  IAM 権限があっても、次のポリシーが拒否していると 'denied' になります:"
  diag "    (1) ECR リポジトリポリシー (リポジトリ単位のリソースベースポリシー)"
  diag "    (2) VPC エンドポイントポリシー (com.amazonaws.${REGION}.ecr.api /"
  diag "        .ecr.dkr のインターフェース型, および S3 ゲートウェイ型)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    # リポジトリポリシー (拒否ステートメントが無いか)"
  diag "    aws ecr get-repository-policy --repository-name ${REPOSITORY} --region ${REGION}"
  diag "    # ECR インターフェース型エンドポイントのポリシー/状態"
  diag "    aws ec2 describe-vpc-endpoints --region ${REGION} \\"
  diag "      --filters Name=service-name,Values=com.amazonaws.${REGION}.ecr.dkr \\"
  diag "      --query 'VpcEndpoints[].{Id:VpcEndpointId,State:State,PrivateDns:PrivateDnsEnabled,Policy:PolicyDocument}'"
  diag "    # ecr.api / s3 についても Values を差し替えて同様に確認"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - ECR > リポジトリ > ${REPOSITORY} > 「アクセス許可」タブ (リポジトリポリシー)"
  diag "    - VPC > エンドポイント > ecr.api / ecr.dkr / s3 の「ポリシー」タブが"
  diag "      当該操作/プリンシパルを許可しているか (フルアクセスまたは明示 Allow)"
}

guide_endpoint_missing() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 C】ECR エンドポイント不存在疑い (ネットワーク到達不可)"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'no such host' / 'timeout' / 'dial tcp' / 'connection refused' 等は"
  diag "  DNS 解決失敗または TCP 到達失敗です。インターネットに出られない"
  diag "  プライベートサブネットでは、ECR 用の VPC エンドポイントが必須です:"
  diag "    - com.amazonaws.${REGION}.ecr.api  (インターフェース型)"
  diag "    - com.amazonaws.${REGION}.ecr.dkr  (インターフェース型, レイヤ転送)"
  diag "    - com.amazonaws.${REGION}.s3       (ゲートウェイ型, レイヤ実体は S3)"
  diag "  これらが未作成 / PrivateDNS 無効 / SG・ルートテーブル不備だと失敗します。"
  diag ""
  diag "  ▼ 到達性・DNS の調査 (EC2 上で実行):"
  diag "    getent hosts ${REGISTRY}          # 名前解決できるか"
  diag "    curl -v https://${REGISTRY}/v2/   # 443 で到達できるか (401 なら到達OK)"
  diag ""
  diag "  ▼ AWS CLI での調査:"
  diag "    aws ec2 describe-vpc-endpoints --region ${REGION} \\"
  diag "      --filters Name=service-name,Values=com.amazonaws.${REGION}.ecr.dkr \\"
  diag "      --query 'VpcEndpoints[].{Id:VpcEndpointId,State:State,PrivateDns:PrivateDnsEnabled,Subnets:SubnetIds,SG:Groups}'"
  diag "    # ecr.api / s3 についても Values を差し替えて存在と State=available を確認"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - VPC > エンドポイント: ecr.api / ecr.dkr が『available』かつ"
  diag "      『プライベート DNS 名を有効化』が ON、s3 ゲートウェイ型が存在するか"
  diag "    - EC2 のサブネットのルートテーブル (s3 ゲートウェイへの経路)"
  diag "    - エンドポイントの SG / EC2 の SG のアウトバウンドで 443/tcp が許可か"
}

guide_repo_not_found() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 D】ECR リポジトリが存在しない"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'name unknown' / 'does not exist in the registry' は、プッシュ先の"
  diag "  リポジトリ '${REPOSITORY}' が (このリージョン/アカウントに) 未作成です。"
  diag "  ECR は push 時に自動作成しません。リージョン取り違えも多い原因です。"
  diag ""
  diag "  ▼ AWS CLI での調査 / 対処:"
  diag "    # 一覧して存在とリージョンを確認"
  diag "    aws ecr describe-repositories --region ${REGION} \\"
  diag "      --query 'repositories[].repositoryName'"
  diag "    # 無ければ作成"
  diag "    aws ecr create-repository --repository-name ${REPOSITORY} --region ${REGION}"
  diag ""
  diag "  ▼ AWS コンソールでの確認:"
  diag "    - 画面右上のリージョンが ${REGION} になっているか"
  diag "    - ECR > リポジトリ 一覧に ${REPOSITORY} が存在するか"
}

guide_token_expired() {
  diag ""
  diag "───────────────────────────────────────────────────────────────────"
  diag "【原因候補 E】認証トークンの期限切れ / 未ログイン"
  diag "───────────────────────────────────────────────────────────────────"
  diag "  'authorization token has expired' / 'no basic auth credentials' /"
  diag "  '401 Unauthorized' は、ECR ログインが無効化 (トークン有効期限 12h) 済み。"
  diag ""
  diag "  ▼ 再ログイン:"
  diag "    aws ecr get-login-password --region ${REGION} \\"
  diag "      | docker login --username AWS --password-stdin ${REGISTRY}"
}

# docker push の出力 (push_log) を解析し、該当する原因ガイドを出力する。
diagnose_push_failure() {
  local push_log="$1"
  local out=""
  [ -f "$push_log" ] && out="$(cat "$push_log")"

  err "==================================================================="
  err "docker image push に失敗しました: ${TARGET_IMAGE}"
  err "AWS API の応答を確認し、原因の切り分けと詳細な調査方法を表示します。"
  err "==================================================================="

  # --- AWS API を実際に呼び出して事実確認する (読み取り専用) ---
  diag ""
  diag "▼ 現在の認証情報 (aws sts get-caller-identity):"
  local identity
  if identity="$(aws sts get-caller-identity --output text 2>&1)"; then
    diag "  ${identity}"
  else
    diag "  取得に失敗: ${identity}"
    diag "  → 認証情報が無効/期限切れの可能性大 (スイッチバックが必要かもしれません)。"
  fi

  diag ""
  diag "▼ ECR リポジトリの実在確認 (aws ecr describe-repositories):"
  local repo_out repo_exists="unknown"
  if repo_out="$(aws ecr describe-repositories --repository-names "$REPOSITORY" --region "$REGION" --output text 2>&1)"; then
    diag "  リポジトリ '${REPOSITORY}' は ${REGION} に存在します。"
    repo_exists="yes"
  else
    diag "  確認できませんでした:"
    diag "    ${repo_out}"
    if printf '%s' "$repo_out" | grep -qiE 'RepositoryNotFoundException|does not exist'; then
      repo_exists="no"
    elif printf '%s' "$repo_out" | grep -qiE 'AccessDenied|not authorized'; then
      diag "  → describe すら AccessDenied。IAM 権限不足の可能性が高いです。"
    fi
  fi

  # --- push 出力のパターンから原因カテゴリを判定 ---
  diag ""
  diag "▼ docker image push の出力から推定される原因:"
  local matched=0

  if [ "$repo_exists" = "no" ] || printf '%s' "$out" | grep -qiE 'name unknown|does not exist in the registry|repositorynotfoundexception|repository .* does not exist'; then
    guide_repo_not_found; matched=1
  fi

  if printf '%s' "$out" | grep -qiE 'no such host|server misbehaving|dial tcp|i/o timeout|deadline exceeded|connection refused|tls handshake|could not resolve|temporary failure in name resolution|network is unreachable|no route to host'; then
    guide_endpoint_missing; matched=1
  fi

  if printf '%s' "$out" | grep -qiE 'authorization token has expired|no basic auth credentials|401 unauthorized|authentication required'; then
    guide_token_expired; matched=1
  fi

  # 'denied' 系は IAM 権限とエンドポイント/リポジトリポリシーの双方が候補
  if printf '%s' "$out" | grep -qiE 'not authorized to perform|access ?denied|is not authorized|denied: |ecr:(initiatelayerupload|uploadlayerpart|completelayerupload|putimage|batchchecklayeravailability|getauthorizationtoken)'; then
    guide_iam; guide_endpoint_policy; matched=1
  fi

  if [ "$matched" -eq 0 ]; then
    diag "  出力から自動判定できるパターンに一致しませんでした。"
    diag "  以下の全観点で切り分けてください。"
    guide_iam
    guide_endpoint_policy
    guide_endpoint_missing
    guide_repo_not_found
    guide_token_expired
  fi

  diag ""
  err "==================================================================="
  err "上記の調査コマンド/コンソール確認で原因を特定してください。"
  err "==================================================================="
}

log "ECR 操作権限を確認します (region=${REGION}) ..."
if ! check_ecr_permission; then
  warn "現在の操作権限では ECR を操作できません。"
  warn_ecr_auth_error
  if [ "$AUTO_SWITCHBACK" = "true" ]; then
    # (B) 終了せず、自動的にスイッチバックして継続する
    log "自動スイッチバックモードです。スイッチバックを実行します。"
    if ! do_switchback; then
      err "スイッチバックに失敗しました。処理を中止します。"
      exit 1
    fi
    log "スイッチバック後に再度 ECR 操作権限を確認します ..."
    if ! check_ecr_permission; then
      err "スイッチバック後も ECR を操作できません。権限設定を確認してください。"
      warn_ecr_auth_error
      exit 1
    fi
    log "スイッチバックにより ECR 操作が可能になりました。処理を継続します。"
  elif [ "$DRY_RUN" = "true" ]; then
    # dry-run では中止せず、権限が無い旨を警告してプレビューを継続する
    warn "ECR 操作権限がありませんが、DRY-RUN のため中止せずにプレビューを継続します。"
    warn "  実際に実行する場合はスイッチバック (--auto-switchback など) が必要です。"
  else
    # (A) 警告して終了する
    err "ECR への操作権限がありません。スイッチバックしてから再実行してください。"
    if [ -n "$SWITCHBACK_SHELL" ]; then
      err "  例) source \"$SWITCHBACK_SHELL\" を実行してスイッチバックしてください。"
    else
      err "  スイッチバック用シェル (別チーム提供) を source で読み込んでスイッチバックしてください。"
    fi
    err "  自動でスイッチバックする場合は --auto-switchback を付けて再実行してください。"
    exit 1
  fi
fi

# ---- JBoss マスターパスワードの取得 / シークレット注入準備 -------------------
# パラメータストアへのアクセスに AWS 権限が必要なため、スイッチバック確定後に行う。
prepare_jboss_password

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

# バイト数を人間可読な単位へ整形する。
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

# 現在の Docker 接続先。リモート daemon ではホスト側の df を見ても意味がないため、
# data root を見るかどうかの判断に使う。
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
  diag "        で空けてから再実行する。"
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

# 監視設定を 1 行で表す。
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

  if [ "${outcome:-}" = "timeout" ]; then
    BUILD_TIMED_OUT="true"
    err "ビルドを上限時間 (${BUILD_TIMEOUT} 秒) で中断しました: ${desc}"
    err "  BuildKit のフェーズと診断結果は上の「ビルド停滞の診断」を確認してください。"
    [ "$status" -eq 0 ] && status=1
  elif [ -n "${max_silence:-}" ]; then
    log "ビルド監視の結果: $(build_watchdog_setting_label) / 最長の無出力 $(format_duration "$max_silence")"
  fi

  case "$state" in
    */build-watchdog.*) rm -rf -- "$state" ;;
  esac
  BUILD_WATCHDOG_DIR=""
  return "$status"
}

# ---- ビルド前の一時ファイルコピー -------------------------------------------
# ここでコピーしたファイルは EXIT トラップ (cleanup_copied_files) により
# ビルド終了後 / 途中終了時のいずれでも自動削除される。
prepare_copy_files

# ---- ビルド (docker buildx build) -------------------------------------------
if [ ! -f "$DOCKERFILE" ]; then
  err "Dockerfile が見つかりません: $DOCKERFILE"
  exit 1
fi
if [ ! -d "$BUILD_CONTEXT" ]; then
  err "ビルドコンテキストが存在しません: $BUILD_CONTEXT"
  exit 1
fi

# docker image tag / docker image push を別コマンドとして使うため、
# --load でビルド結果をローカルの docker イメージストアへ取り込む。
BUILDX_OPTS=(--load -t "$LOCAL_IMAGE" -f "$DOCKERFILE")
if [ -n "$BUILDER" ]; then
  BUILDX_OPTS+=(--builder "$BUILDER")
fi
if [ -n "$PLATFORM" ]; then
  BUILDX_OPTS+=(--platform "$PLATFORM")
fi
# 監視は BuildKit の出力を行単位で読むため、行末が改行にならない tty 形式とは
# 併用できない (画面が空のまま溜まってしまう)。監視を優先して plain へ切り替える。
if build_watchdog_enabled && [ "$PROGRESS" = "tty" ]; then
  warn "--progress tty はビルド監視と併用できないため plain へ切り替えます。"
  warn "  tty 形式のまま実行する場合は --no-build-watchdog を指定してください。"
  PROGRESS="plain"
fi
if [ -n "$PROGRESS" ]; then
  BUILDX_OPTS+=(--progress "$PROGRESS")
fi
if build_watchdog_enabled; then
  log "ビルドの停滞検知: $(build_watchdog_setting_label)"
elif [ "$DRY_RUN" = "true" ]; then
  log "ビルドの停滞検知: DRY-RUN のため行いません。"
else
  log "ビルドの停滞検知: 無効 (--no-build-watchdog または各値に 0 を指定)"
fi
if [ "$NO_CACHE" = "true" ]; then
  BUILDX_OPTS+=(--no-cache)
  log "キャッシュを破棄して (--no-cache) ビルドします。"
fi
for build_arg in ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}; do
  BUILDX_OPTS+=(--build-arg "$build_arg")
done
for build_context in ${BUILD_CONTEXTS[@]+"${BUILD_CONTEXTS[@]}"}; do
  BUILDX_OPTS+=(--build-context "$build_context")
done
for secret in ${SECRETS[@]+"${SECRETS[@]}"}; do
  BUILDX_OPTS+=(--secret "$secret")
done
# JBoss マスターパスワードを environment 型シークレットとして注入する。
# --secret の引数に含まれるのは id と環境変数名のみで、値そのものは含まれない
# (dry-run のコマンドプレビューにも値は表示されない)。
if [ "$JBOSS_SECRET_ENABLED" = "true" ]; then
  BUILDX_OPTS+=(--secret "id=${JBOSS_SECRET_ID},env=${JBOSS_PASSWORD_ENV}")
fi

# exporting layers / importing to docker の書き出し先が足りているかを、
# ビルドを始める前に確認する。
check_build_disk_space

log "docker buildx build を実行します (dockerfile=${DOCKERFILE}, context=${BUILD_CONTEXT}) ..."
if ! run_build_with_watchdog "buildx ${LOCAL_IMAGE}" docker buildx build "${BUILDX_OPTS[@]}" "$BUILD_CONTEXT"; then
  if [ "$BUILD_TIMED_OUT" = "true" ]; then
    err "docker buildx build を上限時間 (${BUILD_TIMEOUT} 秒) で中断しました"
  else
    err "docker buildx build に失敗しました"
  fi
  exit 1
fi

# ローカルベースイメージが生成されたか確認 (dry-run ではビルドしていないためスキップ)
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] ローカルベースイメージの存在確認をスキップします: $LOCAL_IMAGE"
elif ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
  err "ローカルベースイメージが見つかりません: $LOCAL_IMAGE (buildx の --load 取り込みを確認してください)"
  exit 1
else
  log "ローカルベースイメージを確認しました: $LOCAL_IMAGE"
fi

# ---- タグ (<接頭辞>-<処理年月日時分秒>) -------------------------------------
# タグの接頭辞 (TAG_PREFIX) はリポジトリ名とは独立に --tag-prefix で指定できる。
# 例: TAG_PREFIX=BaseImage のとき BaseImage-20260702153000
IMAGE_TAG="${TAG_PREFIX}-$(date '+%Y%m%d%H%M%S')"
TARGET_IMAGE="${REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"

# ---- ECR ログイン (get-login-password | docker login --password-stdin) -----
log "ECR にログインします: $REGISTRY (user=${ECR_USERNAME}) ..."
# ECR_PASSWORD は権限チェック時に取得済み。--password-stdin で安全に渡す。
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] docker login --username ${ECR_USERNAME} --password-stdin ${REGISTRY} (password は非表示)"
elif ! printf '%s' "$ECR_PASSWORD" | docker login --username "$ECR_USERNAME" --password-stdin "$REGISTRY"; then
  err "docker login に失敗しました: $REGISTRY"
  exit 1
fi

# ---- タグ付け & プッシュ ----------------------------------------------------
log "docker image tag ${LOCAL_IMAGE} -> ${TARGET_IMAGE}"
if ! run docker image tag "$LOCAL_IMAGE" "$TARGET_IMAGE"; then
  err "docker image tag に失敗しました"
  exit 1
fi

log "docker image push ${TARGET_IMAGE} ..."
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] docker image push ${TARGET_IMAGE}"
else
  # push の出力を画面に流しつつ (tee) ログへ保存し、失敗時に原因解析へ回す。
  # pipefail 有効のため、docker image push 失敗時はパイプライン全体も失敗扱いになる。
  PUSH_LOG="$(new_temp_file)" || exit 1
  TEMP_FILES+=("$PUSH_LOG")
  if docker image push "$TARGET_IMAGE" 2>&1 | tee "$PUSH_LOG"; then
    log "docker image push に成功しました。"
  else
    diagnose_push_failure "$PUSH_LOG"
    exit 1
  fi
  rm -f "$PUSH_LOG"
fi

# ---- imagedefinition.json 出力 ---------------------------------------------
# CodePipeline の ECS デプロイ等で使われる標準フォーマット。
# name / imageUri に " や \ が含まれても壊れた JSON にならないようエスケープする。
IMAGEDEF_CONTENT="$(cat <<EOF
[
  {
    "name": "$(json_escape "$CONTAINER_NAME")",
    "imageUri": "$(json_escape "$TARGET_IMAGE")"
  }
]
EOF
)"

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] ${OUTPUT_FILE} に以下を出力します (実際には書き込みません):"
  printf '%s\n' "$IMAGEDEF_CONTENT"
else
  # 書き込み失敗 (権限不足・容量不足など) を見逃すと、後続の CodePipeline が
  # 古い imagedefinition を参照してしまうため、必ず結果を確認する。
  if ! printf '%s\n' "$IMAGEDEF_CONTENT" > "$OUTPUT_FILE"; then
    err "imagedefinition の書き込みに失敗しました: ${OUTPUT_FILE}"
    exit 1
  fi
  log "imagedefinition を出力しました: ${OUTPUT_FILE}"
fi

log "  name     = ${CONTAINER_NAME}"
log "  imageUri = ${TARGET_IMAGE}"
if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (実際の変更は行われていません)。"
else
  log "完了しました。"
fi
