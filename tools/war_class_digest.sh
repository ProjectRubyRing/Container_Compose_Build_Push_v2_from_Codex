#!/bin/sh
# war_class_digest.sh
#   WAR / 展開済みディレクトリ / JBoss EAP の vfs temp ディレクトリに含まれる
#   ファイルの MD5 ハッシュ値とパスを「ダイジェストリスト」として書き出し、
#   2 つのリストを突き合わせて差分レポートを出すためのスクリプト。
#
#   build_and_verify.sh から
#     リスト1 : デプロイ実行前の WAR の中身
#     リスト2 : デプロイ後に JBoss EAP が展開した vfs/temp 配下の中身
#   を同じ書式で作り、差分が無いことをもって「正しい成果物で動いている」と
#   判定するために使う。単体でも動くよう、依存は find / awk / sort / md5sum
#   (無ければ openssl / md5) と、WAR を読む場合の unzip (無ければ jar / python3)
#   だけに絞ってある。
#
#   使い方の例:
#     ./war_class_digest.sh --war app.war --output list1.txt
#     ./war_class_digest.sh --vfs-dir auto --output list2.txt
#     ./war_class_digest.sh --dir /opt/app/exploded --ext class,jar,xml
#     ./war_class_digest.sh --compare list1.txt list2.txt --output diff.txt
#     ./war_class_digest.sh --war app.war --simulate extra --output list1.txt
#     ./war_class_digest.sh --show-commands
#
#   終了コード:
#     0   正常終了 (--compare では「差分なし」)
#     1   --compare で差分を検出した
#     2   使い方の誤り (不正なオプション、入力の指定漏れ)
#     3   対象が見つからない (WAR が無い / vfs temp が無い / デプロイルートが特定不能)
#     4   実行環境が足りない (MD5 を計算するコマンドが無い、WAR を展開できない)
#
#   動作環境:
#     POSIX sh (dash / busybox ash / bash) で動作する。コンテナ内へ配って
#     実行することを前提にしているため、bash 固有の機能は使っていない。

set -u

WCD_VERSION="1.0.0"
WCD_PROGRAM="${0##*/}"

# ---- 既定値 -----------------------------------------------------------------
WCD_MODE=""                  # list (一覧の生成) / compare (差分の突き合わせ)
WCD_SOURCE_TYPE=""           # war / dir / vfs
WCD_SOURCE=""                # 入力 (WAR ファイル、ディレクトリ、vfs temp ディレクトリ)
WCD_EXT_SPEC="class"         # 対象拡張子。カンマ区切り。all / '*' ですべて
WCD_OUTPUT=""                # 出力先 (空なら標準出力)
WCD_LABEL=""                 # ヘッダへ載せる名前 (例: リスト1 (デプロイ前の WAR))
WCD_HEADER="true"            # false: 先頭の # ヘッダを出力しない
WCD_ROOT_MARKER="WEB-INF"    # --vfs-dir でデプロイルートを見分ける目印
WCD_DEPLOYMENT=""            # デプロイルートの絞り込み (パスに含まれる文字列)
WCD_EXCLUDES=""              # 除外 glob (改行区切り)
WCD_DEFAULT_EXCLUDE="true"   # --vfs-dir の既定除外 (入れ子 jar の展開結果) を使うか
WCD_MD5_COMMAND=""           # MD5 を計算するコマンドの明示指定
WCD_COMPARE_1=""             # --compare の 1 つめ
WCD_COMPARE_2=""             # --compare の 2 つめ
WCD_LIST1_LABEL="リスト1"    # 差分レポートでの呼び名
WCD_LIST2_LABEL="リスト2"

# 差分の偽装 (動作確認用)。none 以外を指定すると、実際の中身に手を加えた
# リストを出力する。偽装したことはヘッダと差分レポートへ必ず明記する。
#   none   偽装しない (既定)
#   extra  実在しない項目を足す  → そのリストに「だけ」ある差分を作る
#   drop   先頭から項目を落とす  → もう一方のリストに「だけ」ある差分を作る
#   modify 先頭から MD5 を書き換える → 同じパスで中身が違う差分を作る
#   all    extra / drop / modify をすべて行う
WCD_SIMULATE="none"
WCD_SIMULATE_COUNT="1"
WCD_SIMULATE_TAG="SIMULATED"

# 偽装で使う MD5 値の前置き。実在の MD5 と紛れないよう、目で見て分かる値にする。
WCD_SIMULATE_EXTRA_PREFIX="feedface"
WCD_SIMULATE_MODIFY_PREFIX="deadbeef"

# --vfs-dir auto で JBOSS_HOME を探す既定の候補 (build_and_verify.sh と同じ並び)。
WCD_JBOSS_HOME_CANDIDATES="/opt/jboss-eap
/opt/eap
/opt/jboss/jboss-eap
/opt/jboss
/opt/wildfly
/usr/local/jboss-eap
/usr/local/wildfly"

WCD_TMPDIR=""                # 作業用の一時ディレクトリ (終了時に削除)
WCD_MD5_MODE=""              # md5sum / openssl / md5 / digest
WCD_RESOLVED_ROOT=""         # 実際に一覧を取ったディレクトリ
WCD_RESOLVED_ROOT_LABEL=""   # ヘッダへ載せる基準パスの説明

# ---- 後始末 -----------------------------------------------------------------
wcd_cleanup() {
  if [ -n "$WCD_TMPDIR" ] && [ -d "$WCD_TMPDIR" ]; then
    case "$WCD_TMPDIR" in
      */war-class-digest.*) rm -rf -- "$WCD_TMPDIR" ;;
      *) printf '%s: 想定外の一時ディレクトリのため削除しません: %s\n' \
           "$WCD_PROGRAM" "$WCD_TMPDIR" >&2 ;;
    esac
  fi
}
trap wcd_cleanup EXIT HUP INT TERM

wcd_err() {
  printf '%s: %s\n' "$WCD_PROGRAM" "$*" >&2
}

wcd_die() {
  wcd_exit_code="$1"
  shift
  wcd_err "$*"
  exit "$wcd_exit_code"
}

# ---- 使い方 -----------------------------------------------------------------
wcd_usage() {
  cat <<'WCD_USAGE_END'
使い方: war_class_digest.sh [オプション]

WAR / 展開済みディレクトリ / JBoss EAP の vfs temp から、含まれるファイルの
MD5 ハッシュ値とパスの一覧 (ダイジェストリスト) を作る。--compare を使うと、
2 つのリストを突き合わせて差分レポートを出す。

一覧を作る (いずれか 1 つを指定):
  --war FILE               WAR / JAR / ZIP を対象にする。一時ディレクトリへ
                           展開してから MD5 を計算する (元のファイルは変更しない)
  --dir DIR                展開済みディレクトリを対象にする。DIR 直下を基準に
                           相対パスへ直す
  --vfs-dir DIR            JBoss EAP の vfs temp ディレクトリを対象にする。
                           配下から WEB-INF を持つディレクトリ (展開済みデプロイ
                           ルート) を探し、そこを基準に相対パスへ直す。
                           'auto' を指定すると JBOSS_HOME から自動で探す

差分を突き合わせる:
  --compare LIST1 LIST2    2 つのリストを突き合わせ、差分レポートを出力する。
                           差分があれば終了コード 1 を返す
  --list1-label TEXT       差分レポートでのリスト1 の呼び名 (既定: リスト1)
  --list2-label TEXT       差分レポートでのリスト2 の呼び名 (既定: リスト2)

対象の絞り込み:
  --ext LIST               対象拡張子をカンマ区切りで指定する (既定: class)。
                           all または '*' を指定するとすべてのファイルを対象にする
                           例: --ext class / --ext class,jar,xml / --ext all
  --exclude GLOB           除外する相対パスの glob (繰り返し可)
                           例: --exclude 'WEB-INF/lib/*'
  --no-default-exclude     --vfs-dir の既定除外 (入れ子 jar の展開結果
                           '*.jar/*') を使わない
  --deployment NAME        --vfs-dir で候補が複数あるとき、パスに NAME を
                           含むデプロイルートだけを対象にする
  --root-marker NAME       --vfs-dir でデプロイルートを見分ける目印
                           (既定: WEB-INF)

出力:
  --output FILE            出力先 (既定: 標準出力)
  --label TEXT             ヘッダへ載せる名前
  --no-header              先頭の # で始まるヘッダ行を出力しない

差分の偽装 (動作確認用):
  --simulate MODE          none (既定) / extra / drop / modify / all
                             extra  実在しない項目を足す
                                    → このリストに「だけ」ある差分を作る
                             drop   先頭から項目を落とす
                                    → もう一方に「だけ」ある差分を作る
                             modify 先頭から MD5 を書き換える
                                    → 同じパスで中身が違う差分を作る
                             all    上記すべて
  --simulate-count N       偽装する件数 (既定: 1)
  --simulate-tag TEXT      偽装で作るパスへ入れる目印 (既定: SIMULATED)

その他:
  --md5-command CMD        MD5 の計算に使うコマンドを明示する
                           (md5sum / openssl / md5 / digest)
  --show-commands          同じ一覧を手作業で作るための手順を表示する
  -h, --help               このヘルプを表示する
  --version                版数を表示する

終了コード:
  0  正常終了 (--compare では差分なし)
  1  --compare で差分を検出した
  2  使い方の誤り
  3  対象が見つからない
  4  実行環境が足りない
WCD_USAGE_END
}

# 同じ一覧を手作業で作る手順。スクリプトが使えない環境で、同じ確認を
# 手で行いたいときのために残す。
wcd_show_commands() {
  cat <<'WCD_COMMANDS_END'
=== war_class_digest.sh が行っていることを手作業で行う手順 ===

[1] デプロイ前の WAR から一覧を作る (リスト1)
    mkdir -p /tmp/war-expand
    unzip -q -o app.war -d /tmp/war-expand
    cd /tmp/war-expand
    find . -type f -name '*.class' -print | sed 's|^\./||' | LC_ALL=C sort > /tmp/list1.paths
    ( cd /tmp/war-expand && tr '\n' '\0' < /tmp/list1.paths | xargs -0 md5sum ) \
      | awk '{ h=substr($0,1,32); p=substr($0,35); printf "%s\t%s\n", h, p }' \
      | LC_ALL=C sort -t "$(printf '\t')" -k2,2 > /tmp/list1.txt

[2] デプロイ後の vfs/temp から一覧を作る (リスト2)
    # 展開済みデプロイルート (WEB-INF を持つディレクトリ) を探す
    docker exec <container> sh -c 'find "$JBOSS_HOME/standalone/tmp/vfs/temp" -type d -name WEB-INF'
    # 見つかった WEB-INF の親ディレクトリが基準になる
    docker exec <container> sh -c '
      cd /opt/jboss-eap/standalone/tmp/vfs/temp/tempXXXX/content-YYYY &&
      find . -type f -name "*.class" -print | sed "s|^\./||" | LC_ALL=C sort > /tmp/list2.paths &&
      tr "\n" "\0" < /tmp/list2.paths | xargs -0 md5sum' \
      | awk '{ h=substr($0,1,32); p=substr($0,35); printf "%s\t%s\n", h, p }' \
      | LC_ALL=C sort -t "$(printf '\t')" -k2,2 > /tmp/list2.txt

[3] 差分を見る
    # パスの集合の差
    LC_ALL=C comm -3 <(cut -f2 /tmp/list1.txt) <(cut -f2 /tmp/list2.txt)
    # MD5 まで含めた差 (左が list1 のみ、右が list2 のみ)
    LC_ALL=C diff /tmp/list1.txt /tmp/list2.txt

    差分が 1 行も出なければ、WAR の中身がそのままデプロイされている。

[4] 注意点
    - JBoss EAP は入れ子の jar を vfs/temp 配下へ展開することがある。
      その分は WAR 側に相当するファイルが無く「リスト2のみ」として出るため、
      既定では '*.jar/*' を除外している (--no-default-exclude で無効化できる)。
    - vfs/temp には過去の実行が残したディレクトリが残っていることがある。
      WEB-INF を持つディレクトリが複数見つかる場合は --deployment で絞る。
WCD_COMMANDS_END
}

# ---- 引数パース -------------------------------------------------------------
wcd_need_value() {
  # $1=オプション名 $2=残りの引数の数
  if [ "$2" -lt 2 ]; then
    wcd_die 2 "オプションに値が指定されていません: $1"
  fi
}

wcd_set_source() {
  # $1=種別 $2=値。入力の指定は 1 つだけに絞る (取り違えを防ぐため)。
  if [ -n "$WCD_SOURCE_TYPE" ]; then
    wcd_die 2 "入力の指定は 1 つだけにしてください (--war / --dir / --vfs-dir)。"
  fi
  WCD_SOURCE_TYPE="$1"
  WCD_SOURCE="$2"
  WCD_MODE="list"
}

wcd_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --war)      wcd_need_value "$1" $#; wcd_set_source war "$2"; shift 2 ;;
      --dir)      wcd_need_value "$1" $#; wcd_set_source dir "$2"; shift 2 ;;
      --vfs-dir)  wcd_need_value "$1" $#; wcd_set_source vfs "$2"; shift 2 ;;
      --compare)
        if [ $# -lt 3 ]; then
          wcd_die 2 "--compare には 2 つのリストを指定してください。"
        fi
        if [ -n "$WCD_MODE" ] && [ "$WCD_MODE" != "compare" ]; then
          wcd_die 2 "--compare と一覧の生成 (--war / --dir / --vfs-dir) は同時に指定できません。"
        fi
        WCD_MODE="compare"
        WCD_COMPARE_1="$2"
        WCD_COMPARE_2="$3"
        shift 3
        ;;
      --list1-label) wcd_need_value "$1" $#; WCD_LIST1_LABEL="$2"; shift 2 ;;
      --list2-label) wcd_need_value "$1" $#; WCD_LIST2_LABEL="$2"; shift 2 ;;
      --ext)         wcd_need_value "$1" $#; WCD_EXT_SPEC="$2"; shift 2 ;;
      --exclude)
        wcd_need_value "$1" $#
        if [ -n "$WCD_EXCLUDES" ]; then
          WCD_EXCLUDES="${WCD_EXCLUDES}
$2"
        else
          WCD_EXCLUDES="$2"
        fi
        shift 2
        ;;
      --no-default-exclude) WCD_DEFAULT_EXCLUDE="false"; shift ;;
      --deployment)  wcd_need_value "$1" $#; WCD_DEPLOYMENT="$2"; shift 2 ;;
      --root-marker) wcd_need_value "$1" $#; WCD_ROOT_MARKER="$2"; shift 2 ;;
      --output)      wcd_need_value "$1" $#; WCD_OUTPUT="$2"; shift 2 ;;
      --label)       wcd_need_value "$1" $#; WCD_LABEL="$2"; shift 2 ;;
      --no-header)   WCD_HEADER="false"; shift ;;
      --simulate)    wcd_need_value "$1" $#; WCD_SIMULATE="$2"; shift 2 ;;
      --simulate-count) wcd_need_value "$1" $#; WCD_SIMULATE_COUNT="$2"; shift 2 ;;
      --simulate-tag)   wcd_need_value "$1" $#; WCD_SIMULATE_TAG="$2"; shift 2 ;;
      --md5-command) wcd_need_value "$1" $#; WCD_MD5_COMMAND="$2"; shift 2 ;;
      --show-commands) wcd_show_commands; exit 0 ;;
      -h|--help)     wcd_usage; exit 0 ;;
      --version)     printf 'war_class_digest.sh %s\n' "$WCD_VERSION"; exit 0 ;;
      --)            shift; break ;;
      -*)            wcd_die 2 "不明なオプションです: $1 (--help を参照してください)" ;;
      *)             wcd_die 2 "余分な引数です: $1 (--help を参照してください)" ;;
    esac
  done

  [ -n "$WCD_MODE" ] || wcd_die 2 "入力を指定してください (--war / --dir / --vfs-dir / --compare)。"

  case "$WCD_SIMULATE" in
    none|extra|drop|modify|all) ;;
    *) wcd_die 2 "--simulate には none / extra / drop / modify / all のいずれかを指定してください: $WCD_SIMULATE" ;;
  esac
  case "$WCD_SIMULATE_COUNT" in
    ''|*[!0-9]*) wcd_die 2 "--simulate-count には 0 以上の整数を指定してください: $WCD_SIMULATE_COUNT" ;;
  esac
  [ -n "$WCD_ROOT_MARKER" ] || wcd_die 2 "--root-marker には名前を指定してください。"
}

# ---- 一時ディレクトリ -------------------------------------------------------
wcd_make_tmpdir() {
  [ -n "$WCD_TMPDIR" ] && return 0
  WCD_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/war-class-digest.XXXXXX" 2>/dev/null)" \
    || wcd_die 4 "一時ディレクトリを作成できませんでした (TMPDIR=${TMPDIR:-/tmp})。"
  return 0
}

# ---- MD5 を計算する手段の決定 -----------------------------------------------
# md5sum があれば xargs でまとめて計算する (ファイル数が多くても速い)。
# 無い場合は openssl / md5 / digest へ落とし、1 ファイルずつ計算する。
wcd_resolve_md5_mode() {
  if [ -n "$WCD_MD5_COMMAND" ]; then
    case "${WCD_MD5_COMMAND##*/}" in
      md5sum)  WCD_MD5_MODE="md5sum" ;;
      openssl) WCD_MD5_MODE="openssl" ;;
      md5)     WCD_MD5_MODE="md5" ;;
      digest)  WCD_MD5_MODE="digest" ;;
      *) wcd_die 2 "--md5-command には md5sum / openssl / md5 / digest のいずれかを指定してください: $WCD_MD5_COMMAND" ;;
    esac
    command -v "$WCD_MD5_COMMAND" >/dev/null 2>&1 \
      || wcd_die 4 "指定された MD5 コマンドが見つかりません: $WCD_MD5_COMMAND"
    return 0
  fi
  if command -v md5sum >/dev/null 2>&1; then
    WCD_MD5_MODE="md5sum"; WCD_MD5_COMMAND="md5sum"; return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    WCD_MD5_MODE="openssl"; WCD_MD5_COMMAND="openssl"; return 0
  fi
  if command -v md5 >/dev/null 2>&1; then
    WCD_MD5_MODE="md5"; WCD_MD5_COMMAND="md5"; return 0
  fi
  if command -v digest >/dev/null 2>&1; then
    WCD_MD5_MODE="digest"; WCD_MD5_COMMAND="digest"; return 0
  fi
  wcd_die 4 "MD5 を計算できるコマンドが見つかりません (md5sum / openssl / md5 / digest のいずれかが必要です)。"
}

# 1 ファイルの MD5 を標準出力へ返す (32 桁の 16 進数のみ)。
wcd_md5_one() {
  wcd_md5_target="$1"
  case "$WCD_MD5_MODE" in
    md5sum)  md5sum -- "$wcd_md5_target" 2>/dev/null | cut -c1-32 ;;
    openssl) openssl md5 < "$wcd_md5_target" 2>/dev/null | sed -n 's/^.*[= ]\([0-9a-fA-F]\{32\}\)$/\1/p' ;;
    md5)     md5 -q -- "$wcd_md5_target" 2>/dev/null | cut -c1-32 ;;
    digest)  digest -a md5 -- "$wcd_md5_target" 2>/dev/null | cut -c1-32 ;;
  esac
}

# ---- 拡張子 / 除外の判定 ----------------------------------------------------
# 対象拡張子を改行区切り・小文字・先頭の '.' なしへ正規化する。
# all / '*' のときは空を返し、呼び出し側が「すべて対象」と判断する。
WCD_EXT_LIST=""      # 改行区切り (ヘッダ表示・偽装の既定拡張子に使う)
WCD_EXT_MATCH=""     # "|class|jar|" 形式。case の部分一致で判定する
WCD_EXT_ALL="false"
wcd_normalize_ext_spec() {
  case "$WCD_EXT_SPEC" in
    all|ALL|'*'|'')
      WCD_EXT_ALL="true"
      WCD_EXT_LIST=""
      WCD_EXT_MATCH=""
      return 0
      ;;
  esac
  WCD_EXT_ALL="false"
  WCD_EXT_LIST="$(printf '%s\n' "$WCD_EXT_SPEC" \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\.//' \
    | tr 'A-Z' 'a-z' \
    | awk 'NF && !seen[$0]++')"
  [ -n "$WCD_EXT_LIST" ] \
    || wcd_die 2 "--ext に有効な拡張子がありません: $WCD_EXT_SPEC"
  # サブシェルを作らずに判定できるよう、'|' で挟んだ 1 行の文字列にしておく
  # (拡張子に '|' は使えないため、部分一致で取り違えることはない)。
  WCD_EXT_MATCH="|$(printf '%s' "$WCD_EXT_LIST" | tr '\n' '|')|"
  return 0
}

# 相対パスが対象拡張子かを判定する。
wcd_match_ext() {
  [ "$WCD_EXT_ALL" = "true" ] && return 0
  wcd_me_path="$1"
  wcd_me_base="${wcd_me_path##*/}"
  case "$wcd_me_base" in
    *.*) wcd_me_ext="${wcd_me_base##*.}" ;;
    *)   return 1 ;;
  esac
  # まず、そのままの綴りで判定する。拡張子はほぼ小文字のため、ここでほとんどが
  # 決まり、1 ファイルごとに tr のプロセスを起こさずに済む
  # (クラス数の多い WAR では、この差がそのまま所要時間の差になる)。
  case "$WCD_EXT_MATCH" in
    *"|${wcd_me_ext}|"*) return 0 ;;
  esac
  # 大文字混じり (.CLASS など) のときだけ、小文字へ直して判定し直す。
  case "$wcd_me_ext" in
    *[A-Z]*)
      wcd_me_ext="$(printf '%s' "$wcd_me_ext" | tr 'A-Z' 'a-z')"
      case "$WCD_EXT_MATCH" in
        *"|${wcd_me_ext}|"*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# 相対パスが除外 glob に当たるかを判定する (当たれば 0)。
# glob をそのままパターンとして使うため、ループ中はファイル名展開を止める。
wcd_match_exclude() {
  [ -n "$WCD_EXCLUDES" ] || return 1
  wcd_mx_path="$1"
  wcd_mx_oldifs="$IFS"
  wcd_mx_hit="false"
  set -f
  IFS='
'
  for wcd_mx_glob in $WCD_EXCLUDES; do
    [ -n "$wcd_mx_glob" ] || continue
    # shellcheck disable=SC2254
    case "$wcd_mx_path" in
      $wcd_mx_glob) wcd_mx_hit="true"; break ;;
    esac
  done
  IFS="$wcd_mx_oldifs"
  set +f
  [ "$wcd_mx_hit" = "true" ]
}

# ---- 入力の解決 -------------------------------------------------------------
# WAR を一時ディレクトリへ展開し、その展開先を基準ディレクトリとして返す。
wcd_prepare_war_root() {
  wcd_war="$1"
  [ -f "$wcd_war" ] || wcd_die 3 "WAR ファイルが見つかりません: $wcd_war"
  [ -r "$wcd_war" ] || wcd_die 3 "WAR ファイルを読み取れません: $wcd_war"
  wcd_make_tmpdir
  wcd_war_root="$WCD_TMPDIR/war"
  mkdir -p -- "$wcd_war_root" || wcd_die 4 "WAR の展開先を作成できませんでした: $wcd_war_root"

  if command -v unzip >/dev/null 2>&1; then
    # 展開できない壊れた WAR と、警告 (exit 1) で済むものを区別する。
    unzip -q -o -- "$wcd_war" -d "$wcd_war_root" >/dev/null 2>&1
    wcd_unzip_status=$?
    if [ "$wcd_unzip_status" -gt 1 ]; then
      wcd_die 3 "WAR を展開できませんでした (unzip exit=${wcd_unzip_status}): $wcd_war"
    fi
  elif command -v jar >/dev/null 2>&1; then
    wcd_war_abs="$(wcd_abspath "$wcd_war")"
    ( cd "$wcd_war_root" && jar xf "$wcd_war_abs" ) >/dev/null 2>&1 \
      || wcd_die 3 "WAR を展開できませんでした (jar xf): $wcd_war"
  elif command -v python3 >/dev/null 2>&1; then
    wcd_war_abs="$(wcd_abspath "$wcd_war")"
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
      "$wcd_war_abs" "$wcd_war_root" >/dev/null 2>&1 \
      || wcd_die 3 "WAR を展開できませんでした (python3 zipfile): $wcd_war"
  else
    wcd_die 4 "WAR を展開できるコマンドがありません (unzip / jar / python3 のいずれかが必要です)。"
  fi

  WCD_RESOLVED_ROOT="$wcd_war_root"
  WCD_RESOLVED_ROOT_LABEL="WAR のルート (一時展開: ${wcd_war_root})"
  return 0
}

wcd_abspath() {
  wcd_ap_path="$1"
  case "$wcd_ap_path" in
    /*) printf '%s\n' "$wcd_ap_path" ;;
    *)  printf '%s/%s\n' "$(pwd -P)" "$wcd_ap_path" ;;
  esac
}

# JBOSS_HOME を推定する。環境変数 → 既定候補の順で、standalone/tmp/vfs/temp を
# 持つものを選ぶ。
wcd_detect_vfs_temp() {
  wcd_dv_candidates="${JBOSS_HOME:-}
${JBOSS_EAP_HOME:-}
$WCD_JBOSS_HOME_CANDIDATES"
  printf '%s\n' "$wcd_dv_candidates" | while IFS= read -r wcd_dv_home; do
    [ -n "$wcd_dv_home" ] || continue
    if [ -d "$wcd_dv_home/standalone/tmp/vfs/temp" ]; then
      printf '%s\n' "$wcd_dv_home/standalone/tmp/vfs/temp"
      exit 0
    fi
  done
}

# vfs temp 配下から「展開済みデプロイルート」を探す。
# WEB-INF (--root-marker) を持つディレクトリの親がデプロイルートになる。
wcd_resolve_vfs_root() {
  wcd_rv_dir="$1"
  if [ "$wcd_rv_dir" = "auto" ]; then
    wcd_rv_dir="$(wcd_detect_vfs_temp | head -n 1)"
    [ -n "$wcd_rv_dir" ] \
      || wcd_die 3 "JBoss EAP の vfs temp ディレクトリを特定できませんでした (JBOSS_HOME を設定するか --vfs-dir でパスを指定してください)。"
  fi
  [ -d "$wcd_rv_dir" ] || wcd_die 3 "vfs temp ディレクトリが見つかりません: $wcd_rv_dir"

  wcd_make_tmpdir
  wcd_rv_roots="$WCD_TMPDIR/vfs_roots"
  find "$wcd_rv_dir" -type d -name "$WCD_ROOT_MARKER" -print 2>/dev/null \
    | sed "s|/${WCD_ROOT_MARKER}\$||" \
    | awk 'NF && !seen[$0]++' \
    | LC_ALL=C sort > "$wcd_rv_roots"

  if [ -n "$WCD_DEPLOYMENT" ]; then
    wcd_rv_filtered="$WCD_TMPDIR/vfs_roots_filtered"
    grep -F -- "$WCD_DEPLOYMENT" "$wcd_rv_roots" > "$wcd_rv_filtered" 2>/dev/null || :
    if [ -s "$wcd_rv_filtered" ]; then
      mv -- "$wcd_rv_filtered" "$wcd_rv_roots"
    else
      wcd_die 3 "指定したデプロイ名に一致する展開済みデプロイルートがありません: ${WCD_DEPLOYMENT} (対象: ${wcd_rv_dir})"
    fi
  fi

  wcd_rv_count="$(awk 'END { print NR }' "$wcd_rv_roots")"
  if [ "${wcd_rv_count:-0}" -eq 0 ]; then
    wcd_die 3 "vfs temp 配下に展開済みデプロイルート (${WCD_ROOT_MARKER} を持つディレクトリ) がありません: ${wcd_rv_dir}"
  fi
  if [ "$wcd_rv_count" -gt 1 ]; then
    wcd_err "展開済みデプロイルートが複数見つかりました (${wcd_rv_count} 件)。--deployment で 1 つに絞ってください:"
    while IFS= read -r wcd_rv_line; do
      wcd_err "  ${wcd_rv_line}"
    done < "$wcd_rv_roots"
    exit 3
  fi

  WCD_RESOLVED_ROOT="$(head -n 1 "$wcd_rv_roots")"
  WCD_RESOLVED_ROOT_LABEL="展開済みデプロイルート (${WCD_RESOLVED_ROOT})"

  # JBoss EAP は入れ子の jar を vfs/temp 配下へ展開することがある。WAR 側には
  # 対応するファイルが無く「リスト2のみ」として一斉に出てしまうため、既定で除外する。
  if [ "$WCD_DEFAULT_EXCLUDE" = "true" ]; then
    if [ -n "$WCD_EXCLUDES" ]; then
      WCD_EXCLUDES="${WCD_EXCLUDES}
*.jar/*"
    else
      WCD_EXCLUDES="*.jar/*"
    fi
  fi
  return 0
}

wcd_resolve_dir_root() {
  wcd_rd_dir="$1"
  [ -d "$wcd_rd_dir" ] || wcd_die 3 "ディレクトリが見つかりません: $wcd_rd_dir"
  WCD_RESOLVED_ROOT="$wcd_rd_dir"
  WCD_RESOLVED_ROOT_LABEL="ディレクトリ (${wcd_rd_dir})"
  return 0
}

# ---- 一覧の生成 -------------------------------------------------------------
# 基準ディレクトリ配下の通常ファイルを、拡張子と除外 glob で絞って
# 相対パスの一覧 (改行区切り) にする。
wcd_collect_paths() {
  wcd_cp_root="$1"
  wcd_cp_out="$2"
  wcd_cp_raw="$WCD_TMPDIR/raw_paths"

  ( cd "$wcd_cp_root" 2>/dev/null && find . -type f -print ) > "$wcd_cp_raw" 2>/dev/null \
    || wcd_die 3 "対象ディレクトリを走査できませんでした: $wcd_cp_root"

  : > "$wcd_cp_out"
  while IFS= read -r wcd_cp_path; do
    wcd_cp_path="${wcd_cp_path#./}"
    [ -n "$wcd_cp_path" ] || continue
    # 改行やバックスラッシュを含むパスは md5sum の出力書式が変わり、
    # 一覧の 1 行 = 1 ファイルという前提が崩れるため対象外とする。
    case "$wcd_cp_path" in
      *\\*) wcd_err "パスにバックスラッシュを含むため対象外にしました: $wcd_cp_path"; continue ;;
    esac
    wcd_match_ext "$wcd_cp_path" || continue
    wcd_match_exclude "$wcd_cp_path" && continue
    printf '%s\n' "$wcd_cp_path" >> "$wcd_cp_out"
  done < "$wcd_cp_raw"

  LC_ALL=C sort -o "$wcd_cp_out" "$wcd_cp_out"
  return 0
}

# 相対パスの一覧から "MD5<TAB>相対パス" を作る。
wcd_hash_paths() {
  wcd_hp_root="$1"
  wcd_hp_paths="$2"
  wcd_hp_out="$3"

  : > "$wcd_hp_out"
  [ -s "$wcd_hp_paths" ] || return 0

  if [ "$WCD_MD5_MODE" = "md5sum" ]; then
    # md5sum の出力は "<32 桁>␣␣<パス>" (バイナリ時は "␣*<パス>")。
    # パスに空白が含まれても壊れないよう、位置で切り出す。
    ( cd "$wcd_hp_root" && tr '\n' '\0' < "$wcd_hp_paths" | xargs -0 md5sum ) 2>/dev/null \
      | awk -v OFS='\t' '
          length($0) > 34 {
            hash = substr($0, 1, 32)
            path = substr($0, 35)
            sub(/^\.\//, "", path)
            print hash, path
          }' > "$wcd_hp_out"
  else
    while IFS= read -r wcd_hp_path; do
      [ -n "$wcd_hp_path" ] || continue
      wcd_hp_hash="$( cd "$wcd_hp_root" && wcd_md5_one "./$wcd_hp_path" )"
      [ -n "$wcd_hp_hash" ] || continue
      printf '%s\t%s\n' "$wcd_hp_hash" "$wcd_hp_path" >> "$wcd_hp_out"
    done < "$wcd_hp_paths"
  fi

  LC_ALL=C sort -t "$(printf '\t')" -k2,2 -o "$wcd_hp_out" "$wcd_hp_out"
  return 0
}

# 差分の偽装を一覧へ適用する。偽装の内容はヘッダと差分レポートへ必ず残す。
WCD_SIMULATE_NOTE=""
wcd_apply_simulation() {
  wcd_as_file="$1"
  WCD_SIMULATE_NOTE="none"
  [ "$WCD_SIMULATE" = "none" ] && return 0
  [ "$WCD_SIMULATE_COUNT" -gt 0 ] || { WCD_SIMULATE_NOTE="none (件数 0)"; return 0; }

  wcd_as_ext="class"
  [ "$WCD_EXT_ALL" = "true" ] || wcd_as_ext="$(printf '%s\n' "$WCD_EXT_LIST" | head -n 1)"
  wcd_as_applied=""
  wcd_as_tmp="$WCD_TMPDIR/simulated"

  case "$WCD_SIMULATE" in
    drop|all)
      # 先頭から N 件を落とす。もう一方のリストにだけ残る差分になる。
      awk -v skip="$WCD_SIMULATE_COUNT" 'NR > skip' "$wcd_as_file" > "$wcd_as_tmp"
      mv -- "$wcd_as_tmp" "$wcd_as_file"
      wcd_as_applied="drop(${WCD_SIMULATE_COUNT})"
      ;;
  esac
  case "$WCD_SIMULATE" in
    modify|all)
      # 先頭から N 件の MD5 だけを書き換える。同じパスで中身が違う差分になる。
      awk -v n="$WCD_SIMULATE_COUNT" -v pre="$WCD_SIMULATE_MODIFY_PREFIX" -v OFS='\t' -F'\t' '
        NR <= n { printf "%s%024x\t%s\n", pre, NR, $2; next }
        { print $1, $2 }' "$wcd_as_file" > "$wcd_as_tmp"
      mv -- "$wcd_as_tmp" "$wcd_as_file"
      if [ -n "$wcd_as_applied" ]; then
        wcd_as_applied="${wcd_as_applied} + modify(${WCD_SIMULATE_COUNT})"
      else
        wcd_as_applied="modify(${WCD_SIMULATE_COUNT})"
      fi
      ;;
  esac
  case "$WCD_SIMULATE" in
    extra|all)
      # 実在しない項目を足す。このリストにだけある差分になる。
      wcd_as_i=1
      while [ "$wcd_as_i" -le "$WCD_SIMULATE_COUNT" ]; do
        printf '%s%024x\tWEB-INF/classes/%s/SimulatedOnly%s.%s\n' \
          "$WCD_SIMULATE_EXTRA_PREFIX" "$wcd_as_i" \
          "$WCD_SIMULATE_TAG" "$wcd_as_i" "$wcd_as_ext" >> "$wcd_as_file"
        wcd_as_i=$((wcd_as_i + 1))
      done
      LC_ALL=C sort -t "$(printf '\t')" -k2,2 -o "$wcd_as_file" "$wcd_as_file"
      if [ -n "$wcd_as_applied" ]; then
        wcd_as_applied="${wcd_as_applied} + extra(${WCD_SIMULATE_COUNT})"
      else
        wcd_as_applied="extra(${WCD_SIMULATE_COUNT})"
      fi
      ;;
  esac

  case "$wcd_as_applied" in
    *extra*) WCD_SIMULATE_NOTE="$wcd_as_applied (目印: ${WCD_SIMULATE_TAG})" ;;
    *)       WCD_SIMULATE_NOTE="$wcd_as_applied" ;;
  esac
  wcd_err "差分の偽装を有効にして一覧を作りました: ${WCD_SIMULATE_NOTE}"
  return 0
}

wcd_write_output() {
  # $1=中身のファイル。--output があればそこへ、無ければ標準出力へ出す。
  wcd_wo_body="$1"
  if [ -n "$WCD_OUTPUT" ]; then
    wcd_wo_dir="$(dirname -- "$WCD_OUTPUT")"
    [ -d "$wcd_wo_dir" ] || mkdir -p -- "$wcd_wo_dir" 2>/dev/null \
      || wcd_die 3 "出力先ディレクトリを作成できませんでした: $wcd_wo_dir"
    cat -- "$wcd_wo_body" > "$WCD_OUTPUT" \
      || wcd_die 3 "出力先へ書き込めませんでした: $WCD_OUTPUT"
  else
    cat -- "$wcd_wo_body"
  fi
  return 0
}

wcd_now() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '(不明)\n'
}

wcd_run_list() {
  wcd_resolve_md5_mode
  wcd_normalize_ext_spec
  wcd_make_tmpdir

  case "$WCD_SOURCE_TYPE" in
    war) wcd_prepare_war_root "$WCD_SOURCE" ;;
    dir) wcd_resolve_dir_root "$WCD_SOURCE" ;;
    vfs) wcd_resolve_vfs_root "$WCD_SOURCE" ;;
    *)   wcd_die 2 "入力の種別を特定できません。" ;;
  esac

  wcd_rl_paths="$WCD_TMPDIR/paths"
  wcd_rl_list="$WCD_TMPDIR/list"
  wcd_collect_paths "$WCD_RESOLVED_ROOT" "$wcd_rl_paths"
  wcd_hash_paths "$WCD_RESOLVED_ROOT" "$wcd_rl_paths" "$wcd_rl_list"
  wcd_apply_simulation "$wcd_rl_list"

  wcd_rl_count="$(awk 'END { print NR + 0 }' "$wcd_rl_list")"
  wcd_rl_ext_label="$WCD_EXT_SPEC"
  [ "$WCD_EXT_ALL" = "true" ] && wcd_rl_ext_label="all (すべてのファイル)"

  wcd_rl_body="$WCD_TMPDIR/body"
  {
    if [ "$WCD_HEADER" = "true" ]; then
      printf '# war_class_digest.sh %s\n' "$WCD_VERSION"
      printf '# label        : %s\n' "${WCD_LABEL:-(名前なし)}"
      printf '# generated_at : %s\n' "$(wcd_now)"
      printf '# source_type  : %s\n' "$WCD_SOURCE_TYPE"
      printf '# source       : %s\n' "$WCD_SOURCE"
      printf '# root         : %s\n' "$WCD_RESOLVED_ROOT_LABEL"
      printf '# extensions   : %s\n' "$wcd_rl_ext_label"
      printf '# excludes     : %s\n' "$(printf '%s' "$WCD_EXCLUDES" | tr '\n' ' ')"
      printf '# entries      : %s\n' "$wcd_rl_count"
      printf '# simulate     : %s\n' "$WCD_SIMULATE_NOTE"
      printf '# format       : MD5<TAB>相対パス (相対パスで昇順)\n'
    fi
    cat -- "$wcd_rl_list"
  } > "$wcd_rl_body"

  wcd_write_output "$wcd_rl_body"

  # 呼び出し元が件数を機械的に読めるよう、標準エラーへ KEY=VALUE でも出す
  # (標準出力は --output 未指定時に一覧そのものが流れるため使えない)。
  printf 'WCD_LIST_ENTRIES=%s\n' "$wcd_rl_count" >&2
  printf 'WCD_LIST_ROOT=%s\n' "$WCD_RESOLVED_ROOT" >&2
  printf 'WCD_LIST_SIMULATE=%s\n' "$WCD_SIMULATE_NOTE" >&2
  return 0
}

# ---- 差分の突き合わせ -------------------------------------------------------
# リストのヘッダから項目を読み出す (差分レポートへ載せるため)。
wcd_header_value() {
  wcd_hv_file="$1"
  wcd_hv_key="$2"
  sed -n "s/^# *${wcd_hv_key} *: *//p" "$wcd_hv_file" 2>/dev/null | head -n 1
}

wcd_run_compare() {
  [ -f "$WCD_COMPARE_1" ] || wcd_die 3 "リスト1 のファイルが見つかりません: $WCD_COMPARE_1"
  [ -f "$WCD_COMPARE_2" ] || wcd_die 3 "リスト2 のファイルが見つかりません: $WCD_COMPARE_2"
  wcd_make_tmpdir

  wcd_rc_class="$WCD_TMPDIR/classified"
  # 1 回のパスで分類する。出力は
  #   only1<TAB>パス<TAB>MD5
  #   only2<TAB>パス<TAB>MD5
  #   diff <TAB>パス<TAB>MD5(リスト1)<TAB>MD5(リスト2)
  #   same <TAB>パス
  # の 4 種類。並べ替えは後段の sort で行う。
  awk -F'\t' -v OFS='\t' '
    FNR == NR {
      if (substr($0, 1, 1) == "#") next
      if (NF < 2) next
      l1[$2] = $1
      n1++
      next
    }
    {
      if (substr($0, 1, 1) == "#") next
      if (NF < 2) next
      l2[$2] = $1
      n2++
    }
    END {
      for (p in l2) {
        if (p in l1) {
          if (l1[p] == l2[p]) { print "same", p; same++ }
          else { print "diff", p, l1[p], l2[p]; diff++ }
        } else {
          print "only2", p, l2[p]; only2++
        }
      }
      for (p in l1) {
        if (!(p in l2)) { print "only1", p, l1[p]; only1++ }
      }
      printf "count\t%d\t%d\t%d\t%d\t%d\t%d\n", \
        n1 + 0, n2 + 0, same + 0, only1 + 0, only2 + 0, diff + 0
    }
  ' "$WCD_COMPARE_1" "$WCD_COMPARE_2" > "$wcd_rc_class" \
    || wcd_die 3 "リストを読み取れませんでした。"

  wcd_rc_counts="$(grep '^count	' "$wcd_rc_class" | head -n 1)"
  wcd_rc_n1="$(printf '%s' "$wcd_rc_counts" | cut -f2)"
  wcd_rc_n2="$(printf '%s' "$wcd_rc_counts" | cut -f3)"
  wcd_rc_same="$(printf '%s' "$wcd_rc_counts" | cut -f4)"
  wcd_rc_only1="$(printf '%s' "$wcd_rc_counts" | cut -f5)"
  wcd_rc_only2="$(printf '%s' "$wcd_rc_counts" | cut -f6)"
  wcd_rc_diff="$(printf '%s' "$wcd_rc_counts" | cut -f7)"
  wcd_rc_total=$((wcd_rc_only1 + wcd_rc_only2 + wcd_rc_diff))

  if [ "$wcd_rc_total" -eq 0 ]; then
    wcd_rc_verdict="差分なし (問題ありません)"
  else
    wcd_rc_verdict="差分あり (${wcd_rc_total} 件)"
  fi

  wcd_rc_sim1="$(wcd_header_value "$WCD_COMPARE_1" simulate)"
  wcd_rc_sim2="$(wcd_header_value "$WCD_COMPARE_2" simulate)"
  [ -n "$wcd_rc_sim1" ] || wcd_rc_sim1="(不明)"
  [ -n "$wcd_rc_sim2" ] || wcd_rc_sim2="(不明)"

  wcd_rc_body="$WCD_TMPDIR/compare_body"
  {
    printf '===================================================================\n'
    printf 'MD5 ダイジェストリストの差分レポート\n'
    printf '===================================================================\n'
    printf '作成日時     : %s\n' "$(wcd_now)"
    printf '判定         : %s\n' "$wcd_rc_verdict"
    printf '\n'
    printf '%s : %s\n' "$WCD_LIST1_LABEL" "$WCD_COMPARE_1"
    printf '  名前       : %s\n' "$(wcd_header_value "$WCD_COMPARE_1" label)"
    printf '  対象       : %s\n' "$(wcd_header_value "$WCD_COMPARE_1" root)"
    printf '  対象拡張子 : %s\n' "$(wcd_header_value "$WCD_COMPARE_1" extensions)"
    printf '  件数       : %s 件\n' "$wcd_rc_n1"
    printf '  偽装       : %s\n' "$wcd_rc_sim1"
    printf '%s : %s\n' "$WCD_LIST2_LABEL" "$WCD_COMPARE_2"
    printf '  名前       : %s\n' "$(wcd_header_value "$WCD_COMPARE_2" label)"
    printf '  対象       : %s\n' "$(wcd_header_value "$WCD_COMPARE_2" root)"
    printf '  対象拡張子 : %s\n' "$(wcd_header_value "$WCD_COMPARE_2" extensions)"
    printf '  件数       : %s 件\n' "$wcd_rc_n2"
    printf '  偽装       : %s\n' "$wcd_rc_sim2"
    printf '\n'
    printf '%s\n' '--- 内訳 ---------------------------------------------------------'
    printf '一致                 : %s 件\n' "$wcd_rc_same"
    printf '%s のみに存在   : %s 件  (%s にあるのに %s に無い)\n' \
      "$WCD_LIST1_LABEL" "$wcd_rc_only1" "$WCD_LIST1_LABEL" "$WCD_LIST2_LABEL"
    printf '%s のみに存在   : %s 件  (%s に無いのに %s にある)\n' \
      "$WCD_LIST2_LABEL" "$wcd_rc_only2" "$WCD_LIST1_LABEL" "$WCD_LIST2_LABEL"
    printf 'MD5 不一致           : %s 件  (同じパスだが中身が違う)\n' "$wcd_rc_diff"
    printf '\n'

    printf '[A] %s 側の差分: %s にのみ存在するファイル (%s 件)\n' \
      "$WCD_LIST1_LABEL" "$WCD_LIST1_LABEL" "$wcd_rc_only1"
    if [ "$wcd_rc_only1" -eq 0 ]; then
      printf '    (なし)\n'
    else
      grep '^only1	' "$wcd_rc_class" | LC_ALL=C sort -t "$(printf '\t')" -k2,2 \
        | awk -F'\t' -v l1="$WCD_LIST1_LABEL" '{ printf "    [%sのみ] %s  MD5=%s\n", l1, $2, $3 }'
    fi
    printf '\n'

    printf '[B] %s 側の差分: %s にのみ存在するファイル (%s 件)\n' \
      "$WCD_LIST2_LABEL" "$WCD_LIST2_LABEL" "$wcd_rc_only2"
    if [ "$wcd_rc_only2" -eq 0 ]; then
      printf '    (なし)\n'
    else
      grep '^only2	' "$wcd_rc_class" | LC_ALL=C sort -t "$(printf '\t')" -k2,2 \
        | awk -F'\t' -v l2="$WCD_LIST2_LABEL" '{ printf "    [%sのみ] %s  MD5=%s\n", l2, $2, $3 }'
    fi
    printf '\n'

    printf '[C] 両方に存在するが MD5 が一致しないファイル (%s 件)\n' "$wcd_rc_diff"
    if [ "$wcd_rc_diff" -eq 0 ]; then
      printf '    (なし)\n'
    else
      grep '^diff	' "$wcd_rc_class" | LC_ALL=C sort -t "$(printf '\t')" -k2,2 \
        | awk -F'\t' -v l1="$WCD_LIST1_LABEL" -v l2="$WCD_LIST2_LABEL" '
            {
              printf "    [MD5不一致] %s\n", $2
              printf "        %s MD5: %s\n", l1, $3
              printf "        %s MD5: %s\n", l2, $4
            }'
    fi
    printf '\n'

    printf '%s\n' '--- 読み方 -------------------------------------------------------'
    printf '[A] が出る   : ビルドした成果物にあるファイルがデプロイ先へ届いていない。\n'
    printf '               デプロイ先がボリューム / バインドマウントで覆われている、\n'
    printf '               デプロイが途中で失敗している、などを疑う。\n'
    printf '[B] が出る   : デプロイ先にしか無いファイルがある。前回の成果物が残って\n'
    printf '               いる、別のビルドの成果物が混ざっている、などを疑う。\n'
    printf '[C] が出る   : 同じパスで中身が違う。古い成果物のまま動いている可能性が\n'
    printf '               高い。ビルドの取り込み漏れとキャッシュを疑う。\n'
    printf '差分なし     : WAR の中身がそのままデプロイされている。問題なし。\n'
  } > "$wcd_rc_body"

  wcd_write_output "$wcd_rc_body"

  # 呼び出し元が件数を機械的に読めるよう、標準エラーへ KEY=VALUE でも出す。
  printf 'WCD_COMPARE_LIST1=%s\n' "$wcd_rc_n1" >&2
  printf 'WCD_COMPARE_LIST2=%s\n' "$wcd_rc_n2" >&2
  printf 'WCD_COMPARE_SAME=%s\n' "$wcd_rc_same" >&2
  printf 'WCD_COMPARE_ONLY1=%s\n' "$wcd_rc_only1" >&2
  printf 'WCD_COMPARE_ONLY2=%s\n' "$wcd_rc_only2" >&2
  printf 'WCD_COMPARE_DIFF=%s\n' "$wcd_rc_diff" >&2
  printf 'WCD_COMPARE_TOTAL=%s\n' "$wcd_rc_total" >&2

  [ "$wcd_rc_total" -eq 0 ] && return 0
  return 1
}

# ---- 実行 -------------------------------------------------------------------
wcd_parse_args "$@"

case "$WCD_MODE" in
  list)    wcd_run_list ;;
  compare) wcd_run_compare ;;
  *)       wcd_die 2 "処理を特定できません (--help を参照してください)。" ;;
esac
