#!/usr/bin/env bash
# valkey_shell_cli.sh
#   valkey-cli が使えない環境で、valkey (Redis 互換) サーバーへ接続して操作・確認を
#   行うための代替シェル。openssl (TLS) と bash の /dev/tcp (平文) だけで RESP
#   プロトコルを喋るため、コンテナへパッケージを追加インストールする必要がない。
#
#   UBI9 系のアプリコンテナ (frontend / backend) には valkey-cli が同梱されておらず、
#   dnf で入れるとテスト対象のコンテナそのものを書き換えてしまう。このスクリプトは
#   「コンテナに元から入っている bash と openssl だけ」で同じ確認を行えるようにして、
#   valkey-cli が無い状態でもキーの登録内容や TTL、型を確認できるようにする。
#
#   使い方の例:
#     ./valkey_shell_cli.sh -h valkey -p 6379                 # 対話モード
#     ./valkey_shell_cli.sh -h valkey -p 6379 GET mykey       # 1 コマンド実行
#     ./valkey_shell_cli.sh -h valkey --scan-dump 'session:*' # 登録内容の一覧
#     ./valkey_shell_cli.sh -h valkey --tls --cacert ca.crt PING
#     ./valkey_shell_cli.sh --show-commands                   # 手動での代替手順
#
#   終了コード:
#     0   正常終了 (対話モードの終了、コマンドが成功)
#     1   サーバーがエラー応答を返した (-ERR ... など)
#     2   使い方の誤り (不正なオプションなど)
#     3   接続できない / 応答が無い / TLS ハンドシェイクに失敗した
#     4   実行環境が足りない (bash 4 未満、TLS 指定時に openssl が無い など)

set -u

VSC_VERSION="1.0.0"
VSC_PROGRAM="${0##*/}"

# ---- 実行環境の確認 ---------------------------------------------------------
# /dev/tcp、read -N、連想配列を使うため bash 4 以上が必要。sh や dash で起動された
# 場合はここで気付けるよう、はっきりしたメッセージで止める。
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s: bash で実行してください (sh や dash では動作しません)。\n' "$VSC_PROGRAM" >&2
  exit 4
fi
case "${BASH_VERSINFO[0]:-0}" in
  ''|*[!0-9]*) vsc_bash_major=0 ;;
  *) vsc_bash_major="${BASH_VERSINFO[0]}" ;;
esac
if [ "$vsc_bash_major" -lt 4 ]; then
  printf '%s: bash 4 以上が必要です (現在: %s)。\n' "$VSC_PROGRAM" "${BASH_VERSION}" >&2
  exit 4
fi
unset vsc_bash_major

# バイト単位で読み書きするため、ロケールに依存しないようにする。
# (read -N は文字数で数えるため、UTF-8 ロケールのままだとマルチバイト値の
#  バルク長 (バイト数) と食い違い、応答の読み取り位置がずれる)
export LC_ALL=C

# ---- 既定値 -----------------------------------------------------------------
VSC_HOST="${VALKEY_HOST:-127.0.0.1}"
VSC_PORT="${VALKEY_PORT:-6379}"
VSC_PASSWORD="${VALKEY_PASSWORD:-}"
VSC_PASSWORD_SET="false"
[ -n "$VSC_PASSWORD" ] && VSC_PASSWORD_SET="true"
VSC_USER="${VALKEY_USER:-}"
VSC_DB="0"
VSC_TLS="auto"                 # auto / true / false
VSC_TLS_INSECURE="false"
VSC_TLS_CACERT=""
VSC_TLS_CAPATH=""
VSC_TLS_CERT=""
VSC_TLS_KEY=""
VSC_TLS_SNI=""
VSC_TIMEOUT="5"
VSC_RAW="false"                # true なら値を引用符なしで出す (valkey-cli --raw 相当)
VSC_SHOW_COMMANDS="false"
VSC_SCAN_DUMP="false"
VSC_SCAN_PATTERN="*"
VSC_SCAN_COUNT="100"
VSC_SCAN_VALUE_LIMIT="20"      # 1 キーあたりに表示する要素数の上限
VSC_CONFIG_FILE="${VALKEY_SHELL_CLI_CONFIG:-}"

# ---- 実行中の状態 -----------------------------------------------------------
VSC_FD_IN=""                   # 応答を読む fd
VSC_FD_OUT=""                  # 要求を書く fd
VSC_TRANSPORT=""               # plain / tls
VSC_TLS_ACTIVE="false"
VSC_TMPDIR=""
VSC_OPENSSL_PID=""
VSC_CONNECTED="false"
VSC_LINE=""
VSC_PAYLOAD=""
VSC_SCALAR=""
VSC_SCALAR_KIND=""
VSC_EXIT_STATUS=0
declare -a VSC_ARR=()
declare -a VSC_ARGS=()

vsc_err() { printf '%s\n' "$*" >&2; }

vsc_usage() {
  cat <<'VSC_USAGE_END'
使い方: valkey_shell_cli.sh [オプション] [--] [コマンド [引数...]]

valkey-cli が無い環境で、bash と openssl だけで valkey (Redis 互換) を操作する。
コマンドを与えると 1 回だけ実行し、与えなければ対話モードに入る。

接続オプション:
  -h, --host HOST        接続先ホスト名 / IP (既定: 127.0.0.1、環境変数 VALKEY_HOST)
  -p, --port PORT        接続先ポート (既定: 6379、環境変数 VALKEY_PORT)
  -a, --auth PASSWORD    AUTH に使うパスワード (環境変数 VALKEY_PASSWORD)
      --auth-file FILE   パスワードをファイルから読む (ps へ出したくない場合)
      --user USER        ACL のユーザー名 (指定時は AUTH <user> <password>)
  -n, --db INDEX         接続後に SELECT するデータベース番号 (既定: 0)
  -t, --timeout SEC      接続と応答の待ち時間 (既定: 5)
      --config FILE      既定値を書いた設定ファイル (key=value 形式)
                         使えるキー: host port password user db tls insecure
                                     cacert capath cert key sni timeout

TLS オプション:
      --tls              TLS で接続する (openssl s_client を使う)
      --no-tls           平文で接続する (bash の /dev/tcp を使う)
                         いずれも未指定なら、平文で試してから TLS を試す
      --cacert FILE      サーバー証明書の検証に使う CA 証明書
      --capath DIR       同上 (ディレクトリ形式)
      --cert FILE        クライアント証明書 (相互 TLS)
      --key FILE         クライアント秘密鍵 (相互 TLS)
      --sni NAME         SNI として送るサーバー名 (既定: --host の値)
      --insecure         サーバー証明書を検証しない

動作オプション:
      --scan-dump [PATTERN]  SCAN でキーを列挙し、型・TTL・値まで表示する
                             (PATTERN 省略時は * / valkey-cli の --scan 相当)
      --scan                 --scan-dump と同じ (valkey-cli 互換の綴り)
      --pattern PATTERN      --scan と組み合わせて対象パターンを指定する
      --count N              SCAN の COUNT (既定: 100)
      --value-limit N        1 キーあたりに表示する要素数の上限 (既定: 20、0 で無制限)
      --raw                  値を引用符なしでそのまま出す
      --show-commands        openssl / bash だけで同じことを行う手順を表示して終了
      --version              バージョンを表示して終了
      --help                 この使い方を表示して終了

対話モードの組み込みコマンド:
  help                   使えるコマンドの説明を表示する
  quit / exit            対話モードを終了する
  :scan [PATTERN]        --scan-dump と同じ一覧をその場で表示する
  :raw on|off            値の引用符表示を切り替える
  :info                  接続情報 (ホスト・ポート・TLS・DB) を表示する
  :commands              openssl / bash による代替手順を表示する
VSC_USAGE_END
}

# valkey-cli も、このスクリプトすら無い状況で「素の道具だけ」で確認する手順。
# valkey は RESP の inline command (コマンド文字列 + CRLF) を受け付けるため、
# openssl s_client や bash の /dev/tcp へ文字列を流し込むだけで応答を読める。
vsc_show_commands() {
  local host="$VSC_HOST" port="$VSC_PORT" cacert_opt=""
  [ -n "$VSC_TLS_CACERT" ] && cacert_opt=" -CAfile ${VSC_TLS_CACERT}"
  cat <<VSC_COMMANDS_END
=== valkey-cli が無いときの代替手順 (接続先: ${host}:${port}) ===

valkey / Redis は「inline command」(コマンド行 + CRLF) を受け付けるため、
TCP へ文字列を流し込めるものなら何でもクライアントの代わりになる。
応答は RESP 形式 (+OK / -ERR / :数値 / \$長さ+本文 / *要素数) のテキストで返る。

[1] openssl s_client を使う (TLS 有効な valkey / ElastiCache Serverless など)
    # PING して疎通を見る (-quiet で証明書情報の表示を抑える)
    printf 'PING\r\n' | openssl s_client -quiet -connect ${host}:${port}${cacert_opt}

    # 認証・DB 選択・値の取得をまとめて送る (パイプラインで順に応答が返る)
    printf 'AUTH <password>\r\nSELECT 0\r\nKEYS *\r\n' \\
      | openssl s_client -quiet -connect ${host}:${port}${cacert_opt}

    # 証明書を検証したい場合 (検証に失敗したら接続を切る)
    printf 'PING\r\n' | openssl s_client -quiet -verify_return_error -verify 8 \\
      -CAfile /path/to/ca.crt -servername ${host} -connect ${host}:${port}

[2] openssl s_client を平文の TCP クライアントとして使えない点に注意
    openssl s_client は必ず TLS ハンドシェイクを行うため、TLS 無効の valkey には
    使えない (「wrong version number」になる)。平文の場合は [3] を使う。

[3] bash の /dev/tcp を使う (平文。追加コマンドが一切要らない)
    exec 3<>/dev/tcp/${host}/${port}
    printf 'PING\r\n' >&3
    head -c 7 <&3            # +PONG\r\n が返る
    printf 'KEYS *\r\n' >&3
    timeout 2 cat <&3        # 応答を読み切る (RESP の配列が返る)
    exec 3<&-; exec 3>&-

[4] 値にスペースや改行が含まれる場合は RESP の multibulk で送る
    # SET greeting "hello world" を multibulk で表した例
    printf '*3\r\n\$3\r\nSET\r\n\$8\r\ngreeting\r\n\$11\r\nhello world\r\n' >&3

[5] 登録内容をまとめて確認したいとき
    # キーの一覧 (本番規模では KEYS ではなく SCAN を使う)
    printf 'SCAN 0 MATCH * COUNT 100\r\n' >&3
    # 型・TTL・値
    printf 'TYPE mykey\r\nTTL mykey\r\nGET mykey\r\n' >&3
    # 全体像
    printf 'INFO keyspace\r\nDBSIZE\r\n' >&3

[6] nc / socat があれば、そのまま使える
    printf 'PING\r\n' | nc ${host} ${port}
    printf 'PING\r\n' | socat - TCP:${host}:${port}
    # TLS の場合
    printf 'PING\r\n' | socat - OPENSSL:${host}:${port},verify=0

このスクリプト (valkey_shell_cli.sh) は [1] と [3] を自動で使い分け、
RESP の応答を valkey-cli と同じ形に整形して表示している。
VSC_COMMANDS_END
}

# 設定ファイル (key=value) を読み込む。パスワードを argv へ出さずに渡すために使う。
# 値はそのまま (引用符の解釈はしない)。未知のキーは無視せず警告する。
vsc_load_config() {
  local path="$1" line key value
  if [ ! -r "$path" ]; then
    vsc_err "${VSC_PROGRAM}: 設定ファイルを読み取れません: ${path}"
    exit 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) vsc_err "${VSC_PROGRAM}: 設定ファイルの書式が key=value ではありません: ${line}"; continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    # 前後の空白を落とす
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in
      host) VSC_HOST="$value" ;;
      port) VSC_PORT="$value" ;;
      password) VSC_PASSWORD="$value"; VSC_PASSWORD_SET="true" ;;
      user) VSC_USER="$value" ;;
      db) VSC_DB="$value" ;;
      timeout) VSC_TIMEOUT="$value" ;;
      tls)
        case "$value" in
          true|yes|1|on) VSC_TLS="true" ;;
          false|no|0|off) VSC_TLS="false" ;;
          auto|'') VSC_TLS="auto" ;;
          *) vsc_err "${VSC_PROGRAM}: 設定 tls には true / false / auto を指定してください: ${value}" ;;
        esac
        ;;
      insecure)
        case "$value" in
          true|yes|1|on) VSC_TLS_INSECURE="true" ;;
          *) VSC_TLS_INSECURE="false" ;;
        esac
        ;;
      cacert) VSC_TLS_CACERT="$value" ;;
      capath) VSC_TLS_CAPATH="$value" ;;
      cert) VSC_TLS_CERT="$value" ;;
      key) VSC_TLS_KEY="$value" ;;
      sni) VSC_TLS_SNI="$value" ;;
      *) vsc_err "${VSC_PROGRAM}: 設定ファイルの未知のキーを無視します: ${key}" ;;
    esac
  done < "$path"
}

vsc_need_value() {
  if [ "$2" -lt 2 ]; then
    vsc_err "${VSC_PROGRAM}: ${1} には値を指定してください。"
    exit 2
  fi
}

vsc_check_number() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*)
      vsc_err "${VSC_PROGRAM}: ${name} には 0 以上の数値を指定してください: ${value}"
      exit 2
      ;;
  esac
}

# 設定ファイルは argv より先に読み、argv の指定で上書きできるようにする。
# (build_and_verify.sh はパスワードをファイル経由で渡し、利用者が -h などで
#  その場の指定を上書きできる、という関係にする)
if [ -n "$VSC_CONFIG_FILE" ]; then
  vsc_load_config "$VSC_CONFIG_FILE"
fi

declare -a VSC_COMMAND=()
while [ $# -gt 0 ]; do
  # 最初の非オプション引数から先は、valkey へ渡すコマンドとして扱う。
  # LRANGE key 0 -1 の -1 のように、負数をオプションと取り違えないため。
  if [ ${#VSC_COMMAND[@]} -gt 0 ]; then
    VSC_COMMAND+=("$1")
    shift
    continue
  fi
  case "$1" in
    -h|--host) vsc_need_value "$1" $#; VSC_HOST="$2"; shift 2 ;;
    -p|--port) vsc_need_value "$1" $#; VSC_PORT="$2"; shift 2 ;;
    -a|--auth|--pass|--password)
      vsc_need_value "$1" $#; VSC_PASSWORD="$2"; VSC_PASSWORD_SET="true"; shift 2 ;;
    --auth-file|--password-file)
      vsc_need_value "$1" $#
      if [ ! -r "$2" ]; then
        vsc_err "${VSC_PROGRAM}: パスワードファイルを読み取れません: ${2}"
        exit 2
      fi
      # 末尾の改行だけを落とす (パスワードそのものに前後の空白がある場合を壊さない)
      VSC_PASSWORD="$(cat -- "$2")"
      VSC_PASSWORD_SET="true"
      shift 2
      ;;
    --user) vsc_need_value "$1" $#; VSC_USER="$2"; shift 2 ;;
    -n|--db) vsc_need_value "$1" $#; vsc_check_number "$1" "$2"; VSC_DB="$2"; shift 2 ;;
    -t|--timeout) vsc_need_value "$1" $#; vsc_check_number "$1" "$2"; VSC_TIMEOUT="$2"; shift 2 ;;
    --config) vsc_need_value "$1" $#; vsc_load_config "$2"; shift 2 ;;
    --tls) VSC_TLS="true"; shift ;;
    --no-tls) VSC_TLS="false"; shift ;;
    --insecure|--no-verify) VSC_TLS_INSECURE="true"; shift ;;
    --cacert|--cafile) vsc_need_value "$1" $#; VSC_TLS_CACERT="$2"; shift 2 ;;
    --capath) vsc_need_value "$1" $#; VSC_TLS_CAPATH="$2"; shift 2 ;;
    --cert) vsc_need_value "$1" $#; VSC_TLS_CERT="$2"; shift 2 ;;
    --key) vsc_need_value "$1" $#; VSC_TLS_KEY="$2"; shift 2 ;;
    --sni|--servername) vsc_need_value "$1" $#; VSC_TLS_SNI="$2"; shift 2 ;;
    --scan-dump)
      VSC_SCAN_DUMP="true"
      # 直後の引数がオプションでなければパターンとして受け取る
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
        VSC_SCAN_PATTERN="$2"
        shift 2
      else
        shift
      fi
      ;;
    --scan) VSC_SCAN_DUMP="true"; shift ;;
    --pattern) vsc_need_value "$1" $#; VSC_SCAN_PATTERN="$2"; VSC_SCAN_DUMP="true"; shift 2 ;;
    --count) vsc_need_value "$1" $#; vsc_check_number "$1" "$2"; VSC_SCAN_COUNT="$2"; shift 2 ;;
    --value-limit) vsc_need_value "$1" $#; vsc_check_number "$1" "$2"; VSC_SCAN_VALUE_LIMIT="$2"; shift 2 ;;
    --raw) VSC_RAW="true"; shift ;;
    --no-raw) VSC_RAW="false"; shift ;;
    --show-commands) VSC_SHOW_COMMANDS="true"; shift ;;
    --version) printf 'valkey_shell_cli.sh %s\n' "$VSC_VERSION"; exit 0 ;;
    --help) vsc_usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do VSC_COMMAND+=("$1"); shift; done ;;
    -*)
      vsc_err "${VSC_PROGRAM}: 未対応のオプションです: ${1} (--help で使い方を表示します)"
      exit 2
      ;;
    *) VSC_COMMAND+=("$1"); shift ;;
  esac
done

case "$VSC_PORT" in
  ''|*[!0-9]*) vsc_err "${VSC_PROGRAM}: --port には 1 から 65535 の数値を指定してください: ${VSC_PORT}"; exit 2 ;;
esac
if [ "$VSC_PORT" -lt 1 ] || [ "$VSC_PORT" -gt 65535 ]; then
  vsc_err "${VSC_PROGRAM}: --port には 1 から 65535 の数値を指定してください: ${VSC_PORT}"
  exit 2
fi
[ "$VSC_TIMEOUT" -ge 1 ] 2>/dev/null || VSC_TIMEOUT=5
[ -n "$VSC_HOST" ] || { vsc_err "${VSC_PROGRAM}: --host が空です。"; exit 2; }

if [ "$VSC_SHOW_COMMANDS" = "true" ]; then
  vsc_show_commands
  exit 0
fi

# ---- 通信路 (平文 = bash の /dev/tcp、TLS = openssl s_client) ----------------
VSC_CRLF=$'\r\n'
VSC_TLS_LAST_ERROR=""

vsc_cleanup() {
  { exec 3<&-; } 2>/dev/null
  { exec 3>&-; } 2>/dev/null
  { exec 4<&-; } 2>/dev/null
  { exec 4>&-; } 2>/dev/null
  if [ -n "$VSC_OPENSSL_PID" ]; then
    kill "$VSC_OPENSSL_PID" 2>/dev/null
    wait "$VSC_OPENSSL_PID" 2>/dev/null
    VSC_OPENSSL_PID=""
  fi
  if [ -n "$VSC_TMPDIR" ] && [ -d "$VSC_TMPDIR" ]; then
    rm -rf -- "$VSC_TMPDIR" 2>/dev/null
    VSC_TMPDIR=""
  fi
  VSC_CONNECTED="false"
  VSC_FD_IN=""
  VSC_FD_OUT=""
}
trap vsc_cleanup EXIT HUP INT TERM

# TCP へ到達できるかを先に確かめる。/dev/tcp 自体には時間上限が無く、パケットが
# 捨てられる経路 (セキュリティグループ違い等) では数分固まるため、timeout があれば
# それを使って短い時間で見切る。
vsc_probe_tcp() {
  command -v timeout >/dev/null 2>&1 || return 0
  timeout "$VSC_TIMEOUT" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$VSC_HOST" "$VSC_PORT" 2>/dev/null
}

vsc_connect_plain() {
  vsc_probe_tcp || return 1
  { exec 3<>"/dev/tcp/${VSC_HOST}/${VSC_PORT}"; } 2>/dev/null || return 1
  VSC_FD_IN=3
  VSC_FD_OUT=3
  VSC_TRANSPORT="plain"
  VSC_TLS_ACTIVE="false"
  VSC_CONNECTED="true"
  return 0
}

vsc_connect_tls() {
  local sni
  local -a openssl_args=()
  VSC_TLS_LAST_ERROR=""
  if ! command -v openssl >/dev/null 2>&1; then
    VSC_TLS_LAST_ERROR="openssl コマンドが見つかりません。"
    return 1
  fi
  if ! command -v mkfifo >/dev/null 2>&1; then
    VSC_TLS_LAST_ERROR="mkfifo コマンドが見つかりません (TLS 接続には名前付きパイプが必要です)。"
    return 1
  fi
  VSC_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/valkey-shell-cli.XXXXXX" 2>/dev/null)" || {
    VSC_TMPDIR=""
    VSC_TLS_LAST_ERROR="一時ディレクトリを作成できません。"
    return 1
  }
  if ! mkfifo -m 600 "${VSC_TMPDIR}/req" "${VSC_TMPDIR}/resp" 2>/dev/null; then
    VSC_TLS_LAST_ERROR="名前付きパイプを作成できません: ${VSC_TMPDIR}"
    return 1
  fi

  openssl_args=(s_client -quiet -connect "${VSC_HOST}:${VSC_PORT}")
  if [ "$VSC_TLS_INSECURE" != "true" ]; then
    # 既定では検証する。openssl s_client は既定だと検証結果を無視して接続を続けるため、
    # -verify_return_error を付けて「検証に失敗したら切る」挙動にそろえる。
    openssl_args+=(-verify_return_error -verify 8)
  fi
  [ -n "$VSC_TLS_CACERT" ] && openssl_args+=(-CAfile "$VSC_TLS_CACERT")
  [ -n "$VSC_TLS_CAPATH" ] && openssl_args+=(-CApath "$VSC_TLS_CAPATH")
  [ -n "$VSC_TLS_CERT" ] && openssl_args+=(-cert "$VSC_TLS_CERT")
  [ -n "$VSC_TLS_KEY" ] && openssl_args+=(-key "$VSC_TLS_KEY")
  # SNI はホスト名のときだけ送る (IP アドレスを SNI に入れると RFC 違反で弾かれる)
  sni="$VSC_TLS_SNI"
  if [ -z "$sni" ]; then
    case "$VSC_HOST" in
      *[!0-9.]*) sni="$VSC_HOST" ;;
      *) sni="" ;;
    esac
  fi
  [ -n "$sni" ] && openssl_args+=(-servername "$sni")

  openssl "${openssl_args[@]}" \
    < "${VSC_TMPDIR}/req" > "${VSC_TMPDIR}/resp" 2> "${VSC_TMPDIR}/err" &
  VSC_OPENSSL_PID=$!
  # 先に書き込み側 (openssl の stdin) を開き、次に読み取り側を開く。
  # 名前付きパイプは読み書き両用で開けばブロックしないため、この順で固まらない。
  if ! { exec 4<>"${VSC_TMPDIR}/req"; } 2>/dev/null; then
    VSC_TLS_LAST_ERROR="openssl への書き込み口を開けません。"
    return 1
  fi
  if ! { exec 3<>"${VSC_TMPDIR}/resp"; } 2>/dev/null; then
    VSC_TLS_LAST_ERROR="openssl からの読み取り口を開けません。"
    return 1
  fi
  VSC_FD_IN=3
  VSC_FD_OUT=4
  VSC_TRANSPORT="tls"
  VSC_TLS_ACTIVE="true"
  VSC_CONNECTED="true"
  return 0
}

vsc_tls_error_detail() {
  local err_file="${VSC_TMPDIR}/err"
  [ -n "$VSC_TMPDIR" ] && [ -r "$err_file" ] || return 0
  # openssl のエラーは複数行になるため、内容のある行だけを数行に絞って出す。
  awk 'NF { print "  openssl: " $0 }' "$err_file" 2>/dev/null | head -n 5
}

# ---- RESP の送信 ------------------------------------------------------------
# コマンドは multibulk ($ の長さ付き) で送る。空白や改行を含む値でもそのまま
# 渡せるため、inline command (コマンド行 + CRLF) より確実。
vsc_send() {
  local out arg
  [ "$VSC_CONNECTED" = "true" ] || return 1
  out="*$#${VSC_CRLF}"
  for arg in "$@"; do
    out+="\$${#arg}${VSC_CRLF}${arg}${VSC_CRLF}"
  done
  printf '%s' "$out" >&"$VSC_FD_OUT" 2>/dev/null || return 1
  return 0
}

# ---- RESP の受信 ------------------------------------------------------------
vsc_read_line() {
  # 接続が切れているときの read のエラー文言は握りつぶし、呼び出し元の判断に任せる。
  IFS= read -r -t "$VSC_TIMEOUT" -u "$VSC_FD_IN" VSC_LINE 2>/dev/null || return 1
  VSC_LINE="${VSC_LINE%$'\r'}"
  return 0
}

# バルク本文を「長さ分きっちり」読む。read -N は要求数に満たないまま返ることが
# あるため、足りない分を繰り返し読む。進まなくなったら諦める (NUL を含む値など)。
vsc_read_bulk() {
  local want="$1" chunk stalled=0
  VSC_PAYLOAD=""
  while [ "${#VSC_PAYLOAD}" -lt "$want" ]; do
    chunk=""
    if ! IFS= read -r -N $(( want - ${#VSC_PAYLOAD} )) -t "$VSC_TIMEOUT" -u "$VSC_FD_IN" chunk 2>/dev/null; then
      [ -n "$chunk" ] || return 1
    fi
    if [ -z "$chunk" ]; then
      stalled=$(( stalled + 1 ))
      [ "$stalled" -ge 3 ] && return 1
      continue
    fi
    stalled=0
    VSC_PAYLOAD+="$chunk"
  done
  # 本文の後ろの CRLF を捨てる
  IFS= read -r -N 2 -t "$VSC_TIMEOUT" -u "$VSC_FD_IN" chunk 2>/dev/null || return 1
  return 0
}

# 表示用の引用。valkey-cli と同じく制御文字はエスケープして 1 行に収める。
vsc_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

vsc_spaces() {
  local n="$1" out=""
  while [ "$n" -gt 0 ]; do
    out+=" "
    n=$(( n - 1 ))
  done
  printf '%s' "$out"
}

# 応答を 1 つ読み、valkey-cli 風に整形して表示する。
#   $1: 2 行目以降に付ける字下げ
#   $2: 1 行目の行頭 (配列要素では "1) " などの見出しが入る)
# 戻り値: 0 = 正常、1 = サーバーのエラー応答、3 = 受信できない / 解釈できない
vsc_print_reply() {
  local indent="$1" head="$2"
  local type body count index child_head child_indent label status=0 element_status

  if ! vsc_read_line; then
    printf '%s(応答を受信できませんでした: %s 秒待機)\n' "$head" "$VSC_TIMEOUT"
    return 3
  fi
  type="${VSC_LINE:0:1}"
  body="${VSC_LINE:1}"
  case "$type" in
    '+')
      printf '%s%s\n' "$head" "$body"
      ;;
    '-'|'!')
      if [ "$type" = "!" ]; then
        if ! vsc_read_bulk "$body"; then
          printf '%s(エラー本文を受信できませんでした)\n' "$head"
          return 3
        fi
        body="$VSC_PAYLOAD"
      fi
      printf '%s(error) %s\n' "$head" "$body"
      status=1
      ;;
    ':'|'(')
      printf '%s(integer) %s\n' "$head" "$body"
      ;;
    ',')
      printf '%s(double) %s\n' "$head" "$body"
      ;;
    '#')
      if [ "$body" = "t" ]; then
        printf '%s(true)\n' "$head"
      else
        printf '%s(false)\n' "$head"
      fi
      ;;
    '_')
      printf '%s(nil)\n' "$head"
      ;;
    '$'|'=')
      case "$body" in
        -*)
          printf '%s(nil)\n' "$head"
          ;;
        ''|*[!0-9]*)
          printf '%s(解釈できない応答: %s)\n' "$head" "$VSC_LINE"
          return 3
          ;;
        *)
          if ! vsc_read_bulk "$body"; then
            printf '%s(本文を受信できませんでした: %s バイト)\n' "$head" "$body"
            return 3
          fi
          if [ "$VSC_RAW" = "true" ]; then
            printf '%s%s\n' "$head" "$VSC_PAYLOAD"
          else
            printf '%s%s\n' "$head" "$(vsc_quote "$VSC_PAYLOAD")"
          fi
          ;;
      esac
      ;;
    '*'|'~'|'>'|'%')
      case "$body" in
        -*)
          printf '%s(nil)\n' "$head"
          return 0
          ;;
        ''|*[!0-9]*)
          printf '%s(解釈できない応答: %s)\n' "$head" "$VSC_LINE"
          return 3
          ;;
      esac
      count="$body"
      # マップ (%) は「キーと値」で 2 要素ずつ返るため、要素数を 2 倍にして読む。
      [ "$type" = "%" ] && count=$(( count * 2 ))
      if [ "$count" -eq 0 ]; then
        printf '%s(empty array)\n' "$head"
        return 0
      fi
      index=1
      while [ "$index" -le "$count" ]; do
        label="${index})"
        child_indent="${indent}$(vsc_spaces $(( ${#label} + 1 )))"
        if [ "$index" -eq 1 ]; then
          child_head="${head}${label} "
        else
          child_head="${indent}${label} "
        fi
        element_status=0
        vsc_print_reply "$child_indent" "$child_head" || element_status=$?
        if [ "$element_status" -eq 3 ]; then
          return 3
        fi
        [ "$element_status" -eq 1 ] && status=1
        index=$(( index + 1 ))
      done
      ;;
    *)
      printf '%s(解釈できない応答: %s)\n' "$head" "$VSC_LINE"
      return 3
      ;;
  esac
  return "$status"
}

# 応答を 1 つ読み、値を VSC_SCALAR / VSC_SCALAR_KIND (配列なら VSC_ARR) へ入れる。
# kind: status / error / int / double / bool / bulk / nil / array / timeout / unknown
vsc_read_scalar() {
  local type body count index
  VSC_SCALAR=""
  VSC_SCALAR_KIND=""
  VSC_ARR=()
  if ! vsc_read_line; then
    VSC_SCALAR_KIND="timeout"
    return 3
  fi
  type="${VSC_LINE:0:1}"
  body="${VSC_LINE:1}"
  case "$type" in
    '+') VSC_SCALAR_KIND="status"; VSC_SCALAR="$body" ;;
    '-') VSC_SCALAR_KIND="error"; VSC_SCALAR="$body"; return 1 ;;
    ':'|'(') VSC_SCALAR_KIND="int"; VSC_SCALAR="$body" ;;
    ',') VSC_SCALAR_KIND="double"; VSC_SCALAR="$body" ;;
    '#') VSC_SCALAR_KIND="bool"; VSC_SCALAR="$body" ;;
    '_') VSC_SCALAR_KIND="nil" ;;
    '!')
      if ! vsc_read_bulk "$body"; then
        VSC_SCALAR_KIND="timeout"
        return 3
      fi
      VSC_SCALAR_KIND="error"
      VSC_SCALAR="$VSC_PAYLOAD"
      return 1
      ;;
    '$'|'=')
      case "$body" in
        -*) VSC_SCALAR_KIND="nil" ;;
        ''|*[!0-9]*) VSC_SCALAR_KIND="unknown"; VSC_SCALAR="$VSC_LINE"; return 3 ;;
        *)
          if ! vsc_read_bulk "$body"; then
            VSC_SCALAR_KIND="timeout"
            return 3
          fi
          VSC_SCALAR_KIND="bulk"
          VSC_SCALAR="$VSC_PAYLOAD"
          ;;
      esac
      ;;
    '*'|'~'|'>'|'%')
      case "$body" in
        -*) VSC_SCALAR_KIND="nil"; return 0 ;;
        ''|*[!0-9]*) VSC_SCALAR_KIND="unknown"; VSC_SCALAR="$VSC_LINE"; return 3 ;;
      esac
      count="$body"
      [ "$type" = "%" ] && count=$(( count * 2 ))
      index=1
      local -a collected=()
      while [ "$index" -le "$count" ]; do
        # SCAN / LRANGE / HGETALL などの「入れ子でない配列」を想定して読む。
        # 入れ子 (SCAN の第 2 要素など) は呼び出し側が個別に読むこと。
        if ! vsc_read_scalar; then
          case "$VSC_SCALAR_KIND" in
            error) ;;
            *) return 3 ;;
          esac
        fi
        collected+=("$VSC_SCALAR")
        index=$(( index + 1 ))
      done
      VSC_ARR=(${collected[@]+"${collected[@]}"})
      VSC_SCALAR_KIND="array"
      VSC_SCALAR=""
      ;;
    *) VSC_SCALAR_KIND="unknown"; VSC_SCALAR="$VSC_LINE"; return 3 ;;
  esac
  return 0
}

# コマンドを送り、スカラー応答を読む (画面へは出さない)。
vsc_exec_scalar() {
  vsc_send "$@" || return 3
  vsc_read_scalar
}

# SCAN の応答は「[カーソル, [キー...]]」という入れ子の配列になる。
# vsc_read_scalar は入れ子を畳んでしまうため、SCAN 専用に読み分ける。
VSC_SCAN_CURSOR=""
declare -a VSC_SCAN_KEYS=()
vsc_read_scan_reply() {
  VSC_SCAN_CURSOR=""
  VSC_SCAN_KEYS=()
  vsc_read_line || return 3
  case "${VSC_LINE:0:1}" in
    '-') VSC_SCALAR="${VSC_LINE:1}"; VSC_SCALAR_KIND="error"; return 1 ;;
    '*'|'~') ;;
    *) VSC_SCALAR="$VSC_LINE"; VSC_SCALAR_KIND="unknown"; return 3 ;;
  esac
  [ "${VSC_LINE:1}" = "2" ] || { VSC_SCALAR="$VSC_LINE"; VSC_SCALAR_KIND="unknown"; return 3; }
  vsc_read_scalar || return 3
  VSC_SCAN_CURSOR="$VSC_SCALAR"
  vsc_read_scalar || return 3
  VSC_SCAN_KEYS=(${VSC_ARR[@]+"${VSC_ARR[@]}"})
  return 0
}

# ---- 接続 -------------------------------------------------------------------
# 接続直後に PING を投げ、RESP として解釈できる応答が返るかどうかで
# 「その通信路で喋れているか」を判定する。TLS 必須のサーバーへ平文でつなぐと
# ここで応答が壊れる (または切断される) ため、auto では TLS へ切り替える。
vsc_verify_protocol() {
  vsc_send PING || return 1
  vsc_read_scalar
  case "$VSC_SCALAR_KIND" in
    status|bulk) return 0 ;;
    error)
      # NOAUTH / ACL のエラーは「RESP は喋れている」ので接続としては成功。
      return 0
      ;;
    *) return 1 ;;
  esac
}

vsc_connect() {
  local tried_plain="false"
  case "$VSC_TLS" in
    false)
      if vsc_connect_plain && vsc_verify_protocol; then
        return 0
      fi
      vsc_cleanup
      vsc_err "valkey へ平文で接続できませんでした: ${VSC_HOST}:${VSC_PORT}"
      vsc_err "  → ポート番号と、サーバーが TLS を必須にしていないかを確認してください (--tls)。"
      return 3
      ;;
    true)
      if vsc_connect_tls && vsc_verify_protocol; then
        return 0
      fi
      [ -n "$VSC_TLS_LAST_ERROR" ] && vsc_err "  ${VSC_TLS_LAST_ERROR}"
      vsc_tls_error_detail >&2
      vsc_cleanup
      vsc_err "valkey へ TLS で接続できませんでした: ${VSC_HOST}:${VSC_PORT}"
      vsc_err "  → 証明書の検証を外して試す場合は --insecure、CA を渡す場合は --cacert を指定してください。"
      return 3
      ;;
    *)
      # auto: まず平文、駄目なら TLS。TLS 用のオプションが指定されていれば TLS を先に試す。
      if [ -n "$VSC_TLS_CACERT" ] || [ -n "$VSC_TLS_CAPATH" ] || [ -n "$VSC_TLS_CERT" ]; then
        if vsc_connect_tls && vsc_verify_protocol; then
          return 0
        fi
        vsc_cleanup
      else
        tried_plain="true"
        if vsc_connect_plain && vsc_verify_protocol; then
          return 0
        fi
        vsc_cleanup
      fi
      if [ "$tried_plain" = "true" ]; then
        if vsc_connect_tls && vsc_verify_protocol; then
          vsc_err "平文では応答が得られなかったため、TLS で接続しました (--tls 相当)。"
          return 0
        fi
        vsc_cleanup
      else
        if vsc_connect_plain && vsc_verify_protocol; then
          vsc_err "TLS では接続できなかったため、平文で接続しました (--no-tls 相当)。"
          return 0
        fi
        vsc_cleanup
      fi
      vsc_err "valkey へ接続できませんでした: ${VSC_HOST}:${VSC_PORT} (平文・TLS のどちらも失敗)"
      vsc_err "  → ホスト名の解決、ポート、ネットワーク到達性を確認してください。"
      vsc_err "  → 手動で確かめる手順は --show-commands で表示できます。"
      return 3
      ;;
  esac
}

# AUTH と SELECT を済ませる。パスワード未指定で NOAUTH が返る場合は、その旨を伝える。
vsc_handshake() {
  local status=0
  if [ "$VSC_PASSWORD_SET" = "true" ]; then
    if [ -n "$VSC_USER" ]; then
      vsc_exec_scalar AUTH "$VSC_USER" "$VSC_PASSWORD" || status=$?
    else
      vsc_exec_scalar AUTH "$VSC_PASSWORD" || status=$?
    fi
    if [ "$status" -ne 0 ]; then
      vsc_err "AUTH に失敗しました: ${VSC_SCALAR}"
      return 1
    fi
  fi
  if [ "$VSC_DB" != "0" ]; then
    status=0
    vsc_exec_scalar SELECT "$VSC_DB" || status=$?
    if [ "$status" -ne 0 ]; then
      vsc_err "SELECT ${VSC_DB} に失敗しました: ${VSC_SCALAR}"
      return 1
    fi
  fi
  # 認証が必要かどうかをここで確かめる (PING は認証前でも通る実装があるため ECHO を使う)
  status=0
  vsc_exec_scalar ECHO "valkey_shell_cli" || status=$?
  if [ "$status" -eq 1 ]; then
    case "$VSC_SCALAR" in
      NOAUTH*|*"Authentication required"*)
        vsc_err "このサーバーは認証が必要です。-a / --auth-file / --user を指定してください。"
        return 1
        ;;
    esac
  fi
  return 0
}

vsc_connection_summary() {
  local tls_label="平文 (bash /dev/tcp)"
  if [ "$VSC_TLS_ACTIVE" = "true" ]; then
    if [ "$VSC_TLS_INSECURE" = "true" ]; then
      tls_label="TLS (openssl s_client、サーバー証明書の検証なし)"
    else
      tls_label="TLS (openssl s_client、サーバー証明書を検証)"
    fi
  fi
  printf '接続先 : %s:%s (DB %s)\n' "$VSC_HOST" "$VSC_PORT" "$VSC_DB"
  printf '通信   : %s\n' "$tls_label"
  if [ "$VSC_PASSWORD_SET" = "true" ]; then
    if [ -n "$VSC_USER" ]; then
      printf '認証   : AUTH %s <password> 済み\n' "$VSC_USER"
    else
      printf '認証   : AUTH <password> 済み\n'
    fi
  else
    printf '認証   : なし\n'
  fi
}

# ---- 登録内容の一覧 (SCAN) --------------------------------------------------
# KEYS * は要素数に比例して本体をブロックするため、valkey-cli の --scan と同じく
# SCAN でカーソルを回して列挙する。各キーの型・TTL・値まで出して「何がどう入って
# いるか」をその場で確認できるようにする。
vsc_scan_dump() {
  local pattern="${1:-$VSC_SCAN_PATTERN}"
  local cursor="0" key key_type ttl total=0 value_status
  local -a keys=()

  printf '\n=== 登録内容の一覧 (SCAN MATCH %s COUNT %s) ===\n' "$pattern" "$VSC_SCAN_COUNT"
  if vsc_exec_scalar DBSIZE && [ "$VSC_SCALAR_KIND" = "int" ]; then
    printf 'DB %s のキー総数 : %s\n' "$VSC_DB" "$VSC_SCALAR"
  fi
  while :; do
    if ! vsc_send SCAN "$cursor" MATCH "$pattern" COUNT "$VSC_SCAN_COUNT"; then
      vsc_err "SCAN を送信できませんでした。"
      return 3
    fi
    if ! vsc_read_scan_reply; then
      if [ "$VSC_SCALAR_KIND" = "error" ]; then
        vsc_err "SCAN がエラーを返しました: ${VSC_SCALAR}"
        return 1
      fi
      vsc_err "SCAN の応答を解釈できませんでした。"
      return 3
    fi
    cursor="$VSC_SCAN_CURSOR"
    keys=(${VSC_SCAN_KEYS[@]+"${VSC_SCAN_KEYS[@]}"})
    for key in ${keys[@]+"${keys[@]}"}; do
      total=$(( total + 1 ))
      key_type="?"
      vsc_exec_scalar TYPE "$key" >/dev/null 2>&1
      [ -n "$VSC_SCALAR" ] && key_type="$VSC_SCALAR"
      ttl="?"
      vsc_exec_scalar TTL "$key" >/dev/null 2>&1
      if [ "$VSC_SCALAR_KIND" = "int" ]; then
        case "$VSC_SCALAR" in
          -1) ttl="無期限" ;;
          -2) ttl="キーなし" ;;
          *) ttl="${VSC_SCALAR} 秒" ;;
        esac
      fi
      # キー名に改行やタブが含まれていても 1 行に収まるよう、表示だけ引用する。
      printf '\n[%s] type=%s ttl=%s\n' "$(vsc_quote "$key")" "$key_type" "$ttl"
      value_status=0
      case "$key_type" in
        string)
          vsc_send GET "$key" && vsc_print_reply "    " "    " || value_status=$?
          ;;
        list)
          if [ "$VSC_SCAN_VALUE_LIMIT" -gt 0 ]; then
            vsc_send LRANGE "$key" 0 $(( VSC_SCAN_VALUE_LIMIT - 1 )) && vsc_print_reply "    " "    " || value_status=$?
          else
            vsc_send LRANGE "$key" 0 -1 && vsc_print_reply "    " "    " || value_status=$?
          fi
          ;;
        hash)
          vsc_send HGETALL "$key" && vsc_print_reply "    " "    " || value_status=$?
          ;;
        set)
          vsc_send SMEMBERS "$key" && vsc_print_reply "    " "    " || value_status=$?
          ;;
        zset)
          if [ "$VSC_SCAN_VALUE_LIMIT" -gt 0 ]; then
            vsc_send ZRANGE "$key" 0 $(( VSC_SCAN_VALUE_LIMIT - 1 )) WITHSCORES && vsc_print_reply "    " "    " || value_status=$?
          else
            vsc_send ZRANGE "$key" 0 -1 WITHSCORES && vsc_print_reply "    " "    " || value_status=$?
          fi
          ;;
        stream)
          vsc_send XLEN "$key" && vsc_print_reply "    " "    (長さ) " || value_status=$?
          ;;
        *)
          printf '    (この型の値の表示には対応していません。TYPE=%s)\n' "$key_type"
          ;;
      esac
      [ "$value_status" -eq 3 ] && return 3
    done
    [ "$cursor" = "0" ] && break
  done
  printf '\n列挙したキー : %s 件 (パターン: %s)\n' "$total" "$pattern"
  if [ "$VSC_SCAN_VALUE_LIMIT" -gt 0 ]; then
    printf '※ list / zset は先頭 %s 件までを表示しています (--value-limit で変更、0 で無制限)。\n' \
      "$VSC_SCAN_VALUE_LIMIT"
  fi
  return 0
}

# ---- 対話モード -------------------------------------------------------------
# 入力行をコマンドと引数へ分解する。valkey-cli と同じく、シングル / ダブル
# クォートで囲んだ範囲は 1 つの引数として扱う。
vsc_split_line() {
  local line="$1" index=0 length="${#line}" ch quote="" current="" started="false"
  VSC_ARGS=()
  while [ "$index" -lt "$length" ]; do
    ch="${line:$index:1}"
    index=$(( index + 1 ))
    if [ -n "$quote" ]; then
      if [ "$ch" = "$quote" ]; then
        quote=""
        continue
      fi
      if [ "$ch" = "\\" ] && [ "$quote" = '"' ] && [ "$index" -lt "$length" ]; then
        current+="${line:$index:1}"
        index=$(( index + 1 ))
        continue
      fi
      current+="$ch"
      continue
    fi
    case "$ch" in
      ' '|$'\t')
        if [ "$started" = "true" ]; then
          VSC_ARGS+=("$current")
          current=""
          started="false"
        fi
        ;;
      "'"|'"')
        quote="$ch"
        started="true"
        ;;
      *)
        current+="$ch"
        started="true"
        ;;
    esac
  done
  if [ -n "$quote" ]; then
    vsc_err "引用符が閉じていません。"
    VSC_ARGS=()
    return 1
  fi
  [ "$started" = "true" ] && VSC_ARGS+=("$current")
  [ ${#VSC_ARGS[@]} -gt 0 ]
}

vsc_repl_help() {
  cat <<'VSC_REPL_HELP_END'
valkey のコマンドをそのまま入力すると実行して応答を表示する。
  例: PING / SET key value / GET key / TYPE key / TTL key
      KEYS '*' / SCAN 0 MATCH 'session:*' COUNT 100
      HGETALL hash / LRANGE list 0 -1 / SMEMBERS set / ZRANGE z 0 -1 WITHSCORES
      INFO keyspace / DBSIZE / CONFIG GET maxmemory / CLIENT LIST

組み込みコマンド:
  help            この説明を表示する
  quit / exit     対話モードを終了する
  :scan [PATTERN] キーを SCAN で列挙し、型・TTL・値まで表示する (既定: *)
  :raw on|off     値を引用符なしで出すかどうかを切り替える
  :info           現在の接続情報を表示する
  :commands       valkey-cli も本スクリプトも無い場合の代替手順を表示する
VSC_REPL_HELP_END
}

vsc_repl() {
  local line first lowered status
  printf '\n'
  vsc_connection_summary
  printf "コマンドを入力してください (help で説明、quit で終了)。\n"
  while :; do
    printf '%s:%s> ' "$VSC_HOST" "$VSC_PORT" >&2
    if ! IFS= read -r line; then
      printf '\n'
      break
    fi
    line="${line%$'\r'}"
    # 空行 (空白だけの行) は読み飛ばす
    if [ -z "${line//[[:space:]]/}" ]; then
      continue
    fi
    if ! vsc_split_line "$line"; then
      continue
    fi
    first="${VSC_ARGS[0]}"
    lowered="$(printf '%s' "$first" | tr 'A-Z' 'a-z')"
    case "$lowered" in
      quit|exit)
        break
        ;;
      help|'?')
        vsc_repl_help
        continue
        ;;
      :info)
        vsc_connection_summary
        continue
        ;;
      :commands)
        vsc_show_commands
        continue
        ;;
      :raw)
        case "${VSC_ARGS[1]:-}" in
          on|true|1) VSC_RAW="true"; printf '値を引用符なしで表示します。\n' ;;
          off|false|0) VSC_RAW="false"; printf '値を引用符付きで表示します。\n' ;;
          *) printf '使い方: :raw on|off (現在: %s)\n' "$VSC_RAW" ;;
        esac
        continue
        ;;
      :scan)
        status=0
        vsc_scan_dump "${VSC_ARGS[1]:-*}" || status=$?
        [ "$status" -eq 3 ] && break
        continue
        ;;
    esac
    status=0
    if ! vsc_send "${VSC_ARGS[@]}"; then
      vsc_err "コマンドを送信できませんでした (接続が切れている可能性があります)。"
      break
    fi
    vsc_print_reply "" "" || status=$?
    if [ "$status" -eq 3 ]; then
      vsc_err "応答を受信できませんでした。接続が切れている可能性があります。"
      break
    fi
  done
  return 0
}

# ---- 実行 -------------------------------------------------------------------
vsc_connect || exit $?
vsc_handshake || { vsc_cleanup; exit 1; }

if [ "$VSC_SCAN_DUMP" = "true" ]; then
  vsc_scan_dump "$VSC_SCAN_PATTERN" || VSC_EXIT_STATUS=$?
  vsc_cleanup
  exit "$VSC_EXIT_STATUS"
fi

if [ ${#VSC_COMMAND[@]} -gt 0 ]; then
  if ! vsc_send "${VSC_COMMAND[@]}"; then
    vsc_err "コマンドを送信できませんでした: ${VSC_COMMAND[*]}"
    vsc_cleanup
    exit 3
  fi
  vsc_print_reply "" "" || VSC_EXIT_STATUS=$?
  vsc_cleanup
  exit "$VSC_EXIT_STATUS"
fi

vsc_repl
vsc_cleanup
exit 0
