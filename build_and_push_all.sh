#!/usr/bin/env bash
#
# build_and_push_all.sh
# -----------------------------------------------------------------------------
# 想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。
#
# ベース → フロント → バックの順にイメージをビルドして ECR へプッシュし、
# フロントとバックのイメージタグをコピーしやすい形式で表示する。
#
# 各イメージのビルド・プッシュは、build_and_push.sh へイメージごとの引数
# (--repository / --tag-prefix / --compose-file / --local-image など) を渡して
# 起動するラッパーシェルスクリプト経由で行う。このスクリプトはラッパーを順に
# 呼び出し、次の引数を追加で渡す:
#   ベース   : --image-uri-file <受け取りファイル>
#   フロント : --image-uri-file <受け取りファイル> --base-image-tag <ベースのタグ>
#   バック   : --image-uri-file <受け取りファイル> --base-image-tag <ベースのタグ>
# そのため、ラッパーは受け取った引数 ("$@") を build_and_push.sh へそのまま渡すこと:
#   #!/usr/bin/env bash
#   ./build_and_push.sh --account-id 123456789012 \
#       --repository frontimage --tag-prefix FrontImage ... "$@"
#
# 処理の流れ:
#   1. ベース用ラッパーでベースイメージをビルド・プッシュする。ベースイメージ自体の
#      ビルドにはベースイメージタグが不要なため、--base-image-tag は渡さない。
#      プッシュしたイメージの参照 (<registry>/<repository>:<tag>) を
#      --image-uri-file で受け取り、タグの部分だけを取り出して変数に保持する。
#   2. フロント用ラッパーへベースイメージのタグを --base-image-tag で渡し、
#      フロントイメージをビルド・プッシュする (ビルド引数 BASE_IMAGE_TAG になる)。
#   3. バック用ラッパーも同様にビルド・プッシュする。
#   4. フロント / バックのイメージタグを、ログの接頭辞を付けずに表示する。
# 途中で失敗した場合はその時点で中止し、プッシュ済みのタグと再実行の方法を表示する。
#
# 使い方:
#   ./build_and_push_all.sh
#   ./build_and_push_all.sh --base-script ./push_base.sh \
#       --front-script ./push_front.sh --back-script ./push_back.sh
#   ./build_and_push_all.sh --dry-run
#   ./build_and_push_all.sh -- --no-cache    # -- 以降は 3 つのラッパーすべてへ渡す
# -----------------------------------------------------------------------------

set -uo pipefail

# ---- 表示タイムゾーン (JST 固定) --------------------------------------------
# build_and_push.sh と同じく、ホストや CI が UTC でも表示時刻を JST に揃える。
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
  printf '[%s %s] [WARN] JST へ切り替えられないため、ホストのタイムゾーンで表示します。\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$DISPLAY_TZ_LABEL" >&2
fi

# ---- 既定値 -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_SCRIPT="${SCRIPT_DIR}/build_and_push_base.sh"    # ベースイメージ用ラッパー
FRONT_SCRIPT="${SCRIPT_DIR}/build_and_push_front.sh"  # フロントイメージ用ラッパー
BACK_SCRIPT="${SCRIPT_DIR}/build_and_push_back.sh"    # バックイメージ用ラッパー
DRY_RUN="false"                   # true: 各ラッパーへ --dry-run を渡す
COMMON_ARGS=()                    # -- 以降の引数。3 つのラッパーすべてへそのまま渡す

WORK_DIR=""                       # プッシュ結果の受け取りファイルを置く一時ディレクトリ

# 各イメージのプッシュ結果。*_IMAGE_URI はプッシュしたイメージの参照全体、
# *_IMAGE_TAG はそこから取り出したタグの部分。
BASE_IMAGE_URI=""
BASE_IMAGE_TAG=""
FRONT_IMAGE_URI=""
FRONT_IMAGE_TAG=""
BACK_IMAGE_URI=""
BACK_IMAGE_TAG=""

# ---- ログ用ヘルパ -----------------------------------------------------------
START_EPOCH="$(date +%s)"
now_display_time() { printf '%s %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$DISPLAY_TZ_LABEL"; }
log()  { printf '[%s] %s\n'  "$(now_display_time)" "$*"; }
warn() { printf '[%s] [WARN] %s\n'  "$(now_display_time)" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(now_display_time)" "$*" >&2; }

log_elapsed() {
  local elapsed=$(( $(date +%s) - START_EPOCH ))
  log "全体の処理実行時間: ${elapsed} 秒 ($(printf '%02d:%02d:%02d' \
      "$(( elapsed / 3600 ))" "$(( (elapsed % 3600) / 60 ))" "$(( elapsed % 60 ))"))"
}

# 引数をシェルへそのまま貼り付けられる形 (空白などを引用) へ整形する。
# 再実行の案内をコピーして使えるようにするため。
quote_args() {
  local out="" arg
  for arg in "$@"; do
    out="${out:+${out} }$(printf '%q' "$arg")"
  done
  printf '%s' "$out"
}

usage() {
  cat <<'EOF'
Usage: build_and_push_all.sh [OPTIONS] [-- ARGS...]

ベース → フロント → バックの順に、各イメージ用のラッパーシェルスクリプト
(build_and_push.sh へイメージごとの引数を渡して起動するもの) を呼び出し、
イメージをビルドして ECR へプッシュする。ベースイメージのタグはフロント /
バックへ --base-image-tag で渡し、最後にフロント / バックのイメージタグを
コピーしやすい形式で表示する。

Options:
  --base-script PATH       ベースイメージ用ラッパー
                           (既定: <このスクリプトの場所>/build_and_push_base.sh)
  --front-script PATH      フロントイメージ用ラッパー
                           (既定: <このスクリプトの場所>/build_and_push_front.sh)
  --back-script PATH       バックイメージ用ラッパー
                           (既定: <このスクリプトの場所>/build_and_push_back.sh)
  --dry-run                各ラッパーへ --dry-run を渡し、実行内容のプレビューだけを
                           行う。フロント / バックへはプレビュー上のベースイメージタグ
                           (プッシュしていない値) を渡す
  -- ARGS...               -- 以降の引数を 3 つのラッパーすべてへそのまま渡す
                           (例: -- --no-cache --log-dir ./logs)
  -h, --help               このヘルプを表示

各ラッパーへ追加で渡す引数:
  ベース   : --image-uri-file <受け取りファイル>
  フロント : --image-uri-file <受け取りファイル> --base-image-tag <ベースのタグ>
  バック   : --image-uri-file <受け取りファイル> --base-image-tag <ベースのタグ>

ラッパー側の要件:
  受け取った引数 ("$@") を build_and_push.sh へそのまま渡すこと。
    例) ./build_and_push.sh --repository frontimage --tag-prefix FrontImage ... "$@"
  --image-uri-file はプッシュしたイメージの参照をこのスクリプトへ返すため、
  --base-image-tag はビルド引数 BASE_IMAGE_TAG としてビルドへ渡すために使う。
  フロント / バックの Dockerfile では次のようにベースイメージを参照する:
    ARG BASE_IMAGE_TAG
    FROM <registry>/<ベースのリポジトリ>:${BASE_IMAGE_TAG}

終了コード:
  0  3 イメージのビルド・プッシュが完了した (--dry-run ではプレビューが完了した)
  1  ラッパーが見つからない / プッシュしたイメージの参照を受け取れなかった
  2  引数エラー
  上記以外  失敗したラッパーの終了コードをそのまま返す
EOF
}

# ---- 引数パース -------------------------------------------------------------
need_value() {
  if [ "$2" -lt 2 ]; then
    err "オプションに値が指定されていません: $1"
    err "  使い方は --help を参照してください。"
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-script)   need_value "$1" $#; BASE_SCRIPT="$2"; shift 2 ;;
    --front-script)  need_value "$1" $#; FRONT_SCRIPT="$2"; shift 2 ;;
    --back-script)   need_value "$1" $#; BACK_SCRIPT="$2"; shift 2 ;;
    --dry-run)       DRY_RUN="true"; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; COMMON_ARGS=("$@"); break ;;
    *)
      err "不明なオプション: $1"
      err "  ラッパーへ渡す引数は -- の後ろに指定してください (例: -- --no-cache)。"
      exit 2
      ;;
  esac
done

# -- 以降の共通引数の検証。このスクリプトが受け渡しに使う引数や、プッシュまで
# 進まなくなる引数が混ざると、タグを受け取れずに後続が止まるため先に弾く。
# --dry-run だけは、このスクリプト自身の --dry-run と同じ意味として受け付ける。
_filtered_args=()
for _arg in ${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"}; do
  case "$_arg" in
    --dry-run)
      DRY_RUN="true"
      ;;
    --image-uri-file|--base-image-tag)
      err "${_arg} はこのスクリプトが各ラッパーへ渡すため、-- の後ろには指定できません。"
      exit 2
      ;;
    --build-only)
      err "--build-only ではプッシュが行われず、ベースイメージのタグを受け取れないため指定できません。"
      exit 2
      ;;
    -h|--help)
      err "${_arg} を渡すとラッパーがヘルプを表示して終了し、ビルドが行われないため指定できません。"
      exit 2
      ;;
    *)
      _filtered_args+=("$_arg")
      ;;
  esac
done
COMMON_ARGS=(${_filtered_args[@]+"${_filtered_args[@]}"})
unset _filtered_args _arg

# ---- ラッパーの存在確認 -----------------------------------------------------
# ベースのビルドは時間がかかるため、フロント / バックのラッパーが無いことに
# ベースのプッシュ後に気付かないよう、3 つとも開始前に確かめる。
_missing="false"
for _script in "$BASE_SCRIPT" "$FRONT_SCRIPT" "$BACK_SCRIPT"; do
  if [ ! -f "$_script" ]; then
    err "ラッパーシェルスクリプトが見つかりません: ${_script}"
    _missing="true"
  elif [ ! -r "$_script" ]; then
    err "ラッパーシェルスクリプトを読み取れません: ${_script}"
    _missing="true"
  fi
done
if [ "$_missing" = "true" ]; then
  err "  --base-script / --front-script / --back-script でラッパーのパスを指定してください。"
  exit 1
fi
unset _missing _script

# ---- 一時ディレクトリ (プッシュ結果の受け取りファイル) ----------------------
if ! WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/build-and-push-all.XXXXXX" 2>/dev/null)" \
    || [ -z "$WORK_DIR" ]; then
  err "一時ディレクトリを作成できませんでした。TMPDIR を確認してください。"
  exit 1
fi
cleanup_work_dir() {
  # mktemp -d で作った自分のディレクトリ以外を消さないよう、名前を確認してから消す。
  case "${WORK_DIR:-}" in
    */build-and-push-all.*) rm -rf -- "$WORK_DIR" ;;
  esac
  WORK_DIR=""
}
trap 'cleanup_work_dir; log_elapsed' EXIT

BASE_URI_FILE="${WORK_DIR}/base.image-uri"
FRONT_URI_FILE="${WORK_DIR}/front.image-uri"
BACK_URI_FILE="${WORK_DIR}/back.image-uri"

# ---- ラッパーの呼び出し -----------------------------------------------------
# $1: 表示名 / $2: ラッパーのパス / $3: プッシュ結果の受け取りファイル
# $4 以降: このイメージだけに追加で渡す引数 (--base-image-tag など)
# 戻り値はラッパーの終了コード。
run_wrapper() {
  local label="$1" script="$2" uri_file="$3" status=0
  shift 3
  local -a args=()
  args=(${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"})
  [ "$DRY_RUN" = "true" ] && args+=(--dry-run)
  args+=(--image-uri-file "$uri_file" "$@")

  # 前の実行の値を読んでしまわないよう、呼び出し前に空にしておく。
  : > "$uri_file"
  log "================================================================"
  log "${label}のビルド・プッシュを開始します: ${script}"
  log "  追加で渡す引数: $(quote_args "${args[@]}")"
  log "================================================================"
  bash "$script" "${args[@]}" || status=$?
  return "$status"
}

# プッシュしたイメージの参照 (<registry>/<repository>:<tag>) を受け取りファイルから
# 読み、PUSHED_IMAGE_URI と PUSHED_IMAGE_TAG (タグの部分だけ) へ格納する。
# $1: 表示名 / $2: ラッパーのパス / $3: 受け取りファイル
PUSHED_IMAGE_URI=""
PUSHED_IMAGE_TAG=""
read_pushed_image() {
  local label="$1" script="$2" uri_file="$3" uri="" tag=""
  PUSHED_IMAGE_URI=""
  PUSHED_IMAGE_TAG=""
  if [ -s "$uri_file" ]; then
    IFS= read -r uri < "$uri_file" || true
  fi
  uri="${uri%$'\r'}"
  if [ -z "$uri" ]; then
    err "${label}のラッパーは正常終了しましたが、プッシュしたイメージの参照を受け取れませんでした: ${script}"
    err "  ラッパーが受け取った引数を build_and_push.sh へ渡していない可能性があります。"
    err "  ラッパー内の build_and_push.sh の呼び出しの末尾に \"\$@\" を付けてください。"
    err "    例) ./build_and_push.sh --repository ... --tag-prefix ... \"\$@\""
    err "  ラッパーが --build-only を指定している場合もプッシュされないため受け取れません。"
    return 1
  fi
  # タグは最後の ':' より後ろ。レジストリにポート (host:5000) が付いていても、
  # リポジトリ名には ':' が入らないため最後の ':' で切れば正しく取り出せる。
  # タグの無い参照 (host:5000/repo) では '/' を含む値になるため誤りとして弾く。
  tag="${uri##*:}"
  if [ "$tag" = "$uri" ] || [[ "$tag" == */* ]] \
      || ! printf '%s' "$tag" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'; then
    err "${label}の参照からイメージタグを取り出せませんでした: ${uri}"
    return 1
  fi
  PUSHED_IMAGE_URI="$uri"
  PUSHED_IMAGE_TAG="$tag"
  log "${label}のイメージタグを取得しました: ${tag} (${uri})"
  return 0
}

# ---- 途中で失敗したときの案内 -----------------------------------------------
# プッシュ済みのものを示し、ベースを作り直さずに残りだけやり直せるようにする。
# $1: 失敗した段 (front / back) 以降の、やり直しが必要なラッパーを表す文字列
print_rerun_hint() {
  local from="$1"
  [ -n "$BASE_IMAGE_TAG" ] || return 0
  # DRY-RUN ではプッシュしていないため、やり直しの案内は意味を持たない。
  [ "$DRY_RUN" = "true" ] && return 0
  err "  ベースイメージはプッシュ済みです: ${BASE_IMAGE_URI}"
  [ -n "$FRONT_IMAGE_TAG" ] && err "  フロントイメージはプッシュ済みです: ${FRONT_IMAGE_URI}"
  err "  ベースを作り直さずに残りだけやり直す場合は、次のラッパーを実行してください:"
  if [ "$from" = "front" ]; then
    err "    bash $(quote_args "$FRONT_SCRIPT" ${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"} --base-image-tag "$BASE_IMAGE_TAG")"
  fi
  err "    bash $(quote_args "$BACK_SCRIPT" ${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"} --base-image-tag "$BASE_IMAGE_TAG")"
}

# $1: 表示名 / $2: 終了コード / $3: やり直しの起点 (base / front / back)
abort_stage() {
  local label="$1" status="$2" from="$3"
  err "${label}のビルド・プッシュに失敗しました (終了コード ${status})。以降の処理を中止します。"
  [ "$from" != "base" ] && print_rerun_hint "$from"
  exit "$status"
}

# ---- フロント / バックのイメージタグの表示 ---------------------------------
# ログの時刻などの接頭辞を付けず、1 行に 1 つずつ値だけを置く (行ごと選択して
# そのままコピーできるようにする)。シェルの変数へ代入する形も併せて出す。
print_tag_summary() {
  local rule='=================================================================='
  printf '\n%s\n' "$rule"
  if [ "$DRY_RUN" = "true" ]; then
    printf ' フロント / バックのイメージタグ (DRY-RUN: プレビュー上の値。プッシュはしていません)\n'
  else
    printf ' プッシュしたフロント / バックのイメージタグ\n'
  fi
  printf '%s\n\n' "$rule"
  printf 'フロントイメージタグ:\n%s\n\n' "$FRONT_IMAGE_TAG"
  printf 'バックイメージタグ:\n%s\n\n' "$BACK_IMAGE_TAG"
  printf 'シェルへ貼り付ける場合:\n'
  printf 'FRONT_IMAGE_TAG=%s\n' "$FRONT_IMAGE_TAG"
  printf 'BACK_IMAGE_TAG=%s\n' "$BACK_IMAGE_TAG"
  printf '%s\n\n' "$rule"
}

# ---- メイン処理 -------------------------------------------------------------
log "ベース → フロント → バックの順にイメージをビルドして ECR へプッシュします。"
log "  ベース用ラッパー   : ${BASE_SCRIPT}"
log "  フロント用ラッパー : ${FRONT_SCRIPT}"
log "  バック用ラッパー   : ${BACK_SCRIPT}"
if [ ${#COMMON_ARGS[@]} -gt 0 ]; then
  log "  全ラッパー共通の引数: $(quote_args "${COMMON_ARGS[@]}")"
fi
if [ "$DRY_RUN" = "true" ]; then
  log "*** DRY-RUN モードです。各ラッパーへ --dry-run を渡し、プレビューだけを行います。 ***"
fi

# 1. ベースイメージ。ベースイメージタグは不要なため --base-image-tag は渡さない。
status=0
run_wrapper "ベースイメージ" "$BASE_SCRIPT" "$BASE_URI_FILE" || status=$?
[ "$status" -eq 0 ] || abort_stage "ベースイメージ" "$status" "base"
read_pushed_image "ベースイメージ" "$BASE_SCRIPT" "$BASE_URI_FILE" || exit 1
BASE_IMAGE_URI="$PUSHED_IMAGE_URI"
BASE_IMAGE_TAG="$PUSHED_IMAGE_TAG"

# 2. フロントイメージ。取得したベースイメージタグをビルド引数として渡す。
run_wrapper "フロントイメージ" "$FRONT_SCRIPT" "$FRONT_URI_FILE" \
  --base-image-tag "$BASE_IMAGE_TAG" || status=$?
[ "$status" -eq 0 ] || abort_stage "フロントイメージ" "$status" "front"
if ! read_pushed_image "フロントイメージ" "$FRONT_SCRIPT" "$FRONT_URI_FILE"; then
  print_rerun_hint "front"
  exit 1
fi
FRONT_IMAGE_URI="$PUSHED_IMAGE_URI"
FRONT_IMAGE_TAG="$PUSHED_IMAGE_TAG"

# 3. バックイメージ。フロントと同じベースイメージタグを渡す。
run_wrapper "バックイメージ" "$BACK_SCRIPT" "$BACK_URI_FILE" \
  --base-image-tag "$BASE_IMAGE_TAG" || status=$?
[ "$status" -eq 0 ] || abort_stage "バックイメージ" "$status" "back"
if ! read_pushed_image "バックイメージ" "$BACK_SCRIPT" "$BACK_URI_FILE"; then
  print_rerun_hint "back"
  exit 1
fi
BACK_IMAGE_URI="$PUSHED_IMAGE_URI"
BACK_IMAGE_TAG="$PUSHED_IMAGE_TAG"

# 4. 結果の表示。
if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (3 イメージともビルド・プッシュはしていません)。"
else
  log "3 イメージのビルド・プッシュが完了しました。"
fi
log "  ベース   : ${BASE_IMAGE_URI}"
log "  フロント : ${FRONT_IMAGE_URI}"
log "  バック   : ${BACK_IMAGE_URI}"
print_tag_summary
exit 0
