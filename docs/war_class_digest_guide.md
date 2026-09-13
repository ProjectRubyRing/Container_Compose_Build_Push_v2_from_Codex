# war_class_digest.sh 詳細ガイド

WAR / 展開済みディレクトリ / JBoss EAP の vfs temp から、含まれるファイルの
**MD5 ハッシュ値とパスの一覧 (ダイジェストリスト)** を作り、2 つの一覧を
突き合わせて差分レポートを出すスクリプトの完全リファレンスです。

- 対象ファイル: `tools/war_class_digest.sh`
- 想定実行環境: POSIX sh (dash / busybox ash / bash)。RHEL 9.6 のホストでも、
  UBI9 系のアプリコンテナ内でも同じものが動きます
- 呼び出し元: `build_and_verify.sh` の「デプロイ済みファイルの MD5 差分検証」
  (`--verify-deployed-classes`)
- 関連ドキュメント: [ビルド・動作確認ガイド](build_and_verify_guide.md) /
  [パラメータ早見表](parameters_cheatsheet.md)

---

## 目次

1. [このスクリプトの役割](#1-このスクリプトの役割)
2. [なぜ必要か](#2-なぜ必要か)
3. [全体構成](#3-全体構成)
4. [処理の流れ](#4-処理の流れ)
5. [パラメータ一覧](#5-パラメータ一覧)
6. [パラメータ詳細解説](#6-パラメータ詳細解説)
7. [出力書式](#7-出力書式)
8. [終了コード](#8-終了コード)
9. [差分の偽装 (動作確認用)](#9-差分の偽装-動作確認用)
10. [build_and_verify.sh からの使われ方](#10-build_and_verifysh-からの使われ方)
11. [実行例](#11-実行例)
12. [制約と注意点](#12-制約と注意点)
13. [エラーと対処](#13-エラーと対処)

---

## 1. このスクリプトの役割

大きく 2 つのことをします。

| モード | 指定 | やること |
| --- | --- | --- |
| 一覧の生成 | `--war` / `--dir` / `--vfs-dir` | 対象に含まれるファイルの MD5 とパスを一覧にする |
| 差分の突き合わせ | `--compare LIST1 LIST2` | 2 つの一覧を比べ、差分レポートを出す |

同じスクリプト・同じ書式で「デプロイ前の WAR」と「デプロイ後の展開結果」の
両方を扱えるため、比較の前提 (拡張子の絞り込み・相対パスの起点・並び順) が
食い違うことがありません。

```
デプロイ前の WAR                       デプロイ後の vfs/temp
  app.war                                /opt/jboss-eap/standalone/tmp/vfs/temp/
     │                                     tempXXXX/content-YYYY/
     │ --war                                    │ --vfs-dir
     ▼                                          ▼
  リスト1 (MD5 + パス)                     リスト2 (MD5 + パス)
     └───────────────┬──────────────────────────┘
                     │ --compare
                     ▼
             差分レポート (差分なし = 問題なし)
```

---

## 2. なぜ必要か

JBoss EAP は `standalone/deployments` 配下の WAR を **VFS の一時ディレクトリ
(`standalone/tmp/vfs/temp`) へ展開して**動かします。つまり実際にクラスロードされて
いるのは「WAR そのもの」ではなく「展開された中身」です。

このため、次のような状態でも **ビルドも起動もデプロイも成功して見えます**。

- デプロイ先が名前付きボリューム / バインドマウントで覆われていて、
  イメージへ焼いた新しい WAR がコンテナから一切見えていない
- 差分ビルドの取り込み漏れで、一部のクラスだけ古いまま
- 前回の成果物が展開先に残っていて、余分なクラスが混ざっている
- デプロイの途中で失敗し、一部しか展開されていない

`build_and_verify.sh` の取り込み検証 (`--verify-copy-artifact`) は
「WAR ファイル 1 個の SHA-256 が一致するか」を見ます。それに対してこちらは
**WAR の中身すべて (既定では `.class`) をファイル単位で突き合わせる**ため、
上のような「一部だけ古い」状態まで検出できます。

---

## 3. 全体構成

```
tools/war_class_digest.sh
  ├─ 引数パース (wcd_parse_args)
  ├─ 一覧の生成 (wcd_run_list)
  │    ├─ MD5 コマンドの決定        wcd_resolve_md5_mode
  │    ├─ 拡張子の正規化            wcd_normalize_ext_spec
  │    ├─ 入力の解決
  │    │    ├─ WAR を一時展開       wcd_prepare_war_root
  │    │    ├─ ディレクトリ         wcd_resolve_dir_root
  │    │    └─ vfs temp から探索    wcd_resolve_vfs_root
  │    ├─ 対象ファイルの収集        wcd_collect_paths
  │    ├─ MD5 の算出                wcd_hash_paths
  │    └─ 差分の偽装                wcd_apply_simulation
  └─ 差分の突き合わせ (wcd_run_compare)
```

依存コマンドは次だけです。パッケージの追加インストールは要りません。

| 用途 | 使うコマンド | 代替 |
| --- | --- | --- |
| MD5 の算出 | `md5sum` | `openssl` / `md5` / `digest` |
| WAR の展開 | `unzip` | `jar` / `python3` |
| その他 | `find` / `awk` / `sed` / `sort` / `tr` / `xargs` | — |

`md5sum` があるときは `xargs` でまとめて計算するため、ファイル数が多くても
プロセス起動が数回で済みます。無い場合は 1 ファイルずつ計算します
(結果は同じですが遅くなります)。

---

## 4. 処理の流れ

### 4.1 一覧の生成

1. MD5 の計算手段を決める (`--md5-command` > `md5sum` > `openssl` > `md5` > `digest`)
2. `--ext` を正規化する (小文字化・先頭の `.` を落とす・重複排除)
3. 入力を「基準ディレクトリ」へ解決する
   - `--war` … 一時ディレクトリへ展開し、その展開先を基準にする
   - `--dir` … 指定ディレクトリをそのまま基準にする
   - `--vfs-dir` … 配下から `WEB-INF` (`--root-marker`) を持つディレクトリを探し、
     その**親**を基準にする。`auto` なら `JBOSS_HOME` などから
     `standalone/tmp/vfs/temp` を自動で探す
4. 基準ディレクトリ配下の通常ファイルを `find` で集め、拡張子と除外 glob で絞る
5. 相対パスごとに MD5 を計算する
6. `--simulate` が指定されていれば、この一覧へ偽装を適用する
7. ヘッダ (`#` 行) を付けて `--output` (または標準出力) へ書き出す
8. 件数などを標準エラーへ `KEY=VALUE` 形式でも出す (呼び出し元が読むため)

### 4.2 差分の突き合わせ

1. 2 つの一覧を `awk` で 1 回だけ読み、パスをキーに分類する
   - 両方にあり MD5 も同じ → 一致
   - 両方にあるが MD5 が違う → **MD5 不一致**
   - リスト1 にしかない → **リスト1のみ**
   - リスト2 にしかない → **リスト2のみ**
2. 件数と明細を差分レポートとして書き出す
3. 差分が 1 件も無ければ終了コード 0、あれば 1 を返す

---

## 5. パラメータ一覧

### 5.1 入力 (いずれか 1 つ必須)

| パラメータ | 値 | 説明 |
| --- | --- | --- |
| `--war FILE` | パス | WAR / JAR / ZIP を対象にする (一時展開して算出) |
| `--dir DIR` | パス | 展開済みディレクトリを対象にする |
| `--vfs-dir DIR` | パス / `auto` | JBoss EAP の vfs temp を対象にする |
| `--compare LIST1 LIST2` | パス 2 つ | 2 つの一覧を突き合わせる |

### 5.2 対象の絞り込み

| パラメータ | 既定 | 説明 |
| --- | --- | --- |
| `--ext LIST` | `class` | 対象拡張子 (カンマ区切り)。`all` / `*` ですべて |
| `--exclude GLOB` | なし | 除外する相対パスの glob (繰り返し可) |
| `--no-default-exclude` | — | `--vfs-dir` の既定除外 (`*.jar/*`) を使わない |
| `--deployment NAME` | なし | `--vfs-dir` でデプロイルートを絞る |
| `--root-marker NAME` | `WEB-INF` | デプロイルートを見分ける目印 |

### 5.3 出力

| パラメータ | 既定 | 説明 |
| --- | --- | --- |
| `--output FILE` | 標準出力 | 出力先 (親ディレクトリは自動作成) |
| `--label TEXT` | なし | ヘッダへ載せる名前 |
| `--no-header` | — | `#` で始まるヘッダ行を出さない |
| `--list1-label TEXT` | `リスト1` | 差分レポートでの呼び名 |
| `--list2-label TEXT` | `リスト2` | 差分レポートでの呼び名 |

### 5.4 差分の偽装 (動作確認用)

| パラメータ | 既定 | 説明 |
| --- | --- | --- |
| `--simulate MODE` | `none` | `none` / `extra` / `drop` / `modify` / `all` |
| `--simulate-count N` | `1` | 偽装する件数 |
| `--simulate-tag TEXT` | `SIMULATED` | 偽装で作るパスへ入れる目印 |

### 5.5 その他

| パラメータ | 説明 |
| --- | --- |
| `--md5-command CMD` | MD5 の計算に使うコマンドを明示する |
| `--show-commands` | 同じ一覧を手作業で作る手順を表示する |
| `-h`, `--help` | ヘルプを表示する |
| `--version` | 版数を表示する |

---

## 6. パラメータ詳細解説

### `--ext LIST` (既定: `class`)

一覧へ載せるファイルを拡張子で絞ります。カンマ区切りで複数指定でき、
大文字・小文字と先頭の `.` は無視されます。

```sh
--ext class          # 既定。class ファイルだけ
--ext class,jar,xml  # 複数
--ext .class         # 先頭の '.' は付けても付けなくてもよい
--ext all            # すべてのファイル ('*' でも同じ)
```

**既定を `class` にしている理由**: デプロイの取り違えで実害が出るのは
ほぼ Java クラスであり、`WEB-INF/lib` の jar や静的ファイルまで含めると
一覧が大きくなるうえ、JBoss EAP 側の都合で差が出て判定がぼやけるためです。

### `--vfs-dir DIR` / `auto`

JBoss EAP の vfs temp ディレクトリを対象にします。配下から `WEB-INF` を持つ
ディレクトリを探し、その**親** (= 展開済みデプロイルート) を基準に相対パス化
するため、WAR 側の相対パスとそのまま比較できます。

```
/opt/jboss-eap/standalone/tmp/vfs/temp/      ← --vfs-dir にはここを渡す
  └── tempXXXXXXXX/
        └── content-YYYYYYYY/                ← ここが基準 (デプロイルート)
              ├── WEB-INF/
              │     ├── classes/com/example/Alpha.class   → 相対パスはここから
              │     └── lib/
              └── index.html
```

`auto` を指定すると、`JBOSS_HOME` → `JBOSS_EAP_HOME` → 既定候補
(`/opt/jboss-eap`, `/opt/eap`, `/opt/jboss/jboss-eap`, `/opt/jboss`,
`/opt/wildfly`, `/usr/local/jboss-eap`, `/usr/local/wildfly`) の順に
`standalone/tmp/vfs/temp` を持つものを探します。

**デプロイルートが複数見つかった場合**は、取り違えを防ぐため一覧を出して
終了コード 3 で止まります。`--deployment NAME` でパスに `NAME` を含むものへ
絞ってください。

### `--no-default-exclude`

`--vfs-dir` では、既定で `*.jar/*` を除外しています。JBoss EAP は入れ子の jar を
vfs/temp 配下へ展開することがあり、その分は WAR 側に対応するファイルが無いため、
除外しないと「リスト2のみ」が大量に出て判定が読めなくなるためです。
入れ子 jar まで含めて確認したい場合にだけ指定します。

### `--md5-command CMD`

`md5sum` / `openssl` / `md5` / `digest` のいずれかを明示します。
コンテナによっては `md5sum` が無く `openssl` しか無いことがあるため、
通常は自動判定に任せて構いません。

---

## 7. 出力書式

### 7.1 一覧 (ダイジェストリスト)

```
# war_class_digest.sh 1.0.0
# label        : リスト1 (デプロイ前の WAR: orders.war)
# generated_at : 2026-09-13 11:37:01
# source_type  : war
# source       : /tmp/build/orders.war
# root         : WAR のルート (一時展開: /tmp/war-class-digest.Vei2Yx/war)
# extensions   : class
# excludes     :
# entries      : 3
# simulate     : none
# format       : MD5<TAB>相対パス (相対パスで昇順)
bf072e9119077b4e76437a93986787ef	WEB-INF/classes/com/example/Alpha.class
30cf3d7d133b08543cb6c8933c29dfd7	WEB-INF/classes/com/example/Beta.class
b39bfc0e26a30024c76e4dcb8a1eae87	WEB-INF/classes/com/example/Gamma.class
```

- `#` で始まる行がヘッダ、それ以外が明細です
- 明細は **`MD5` + タブ + 相対パス** の 1 行 1 ファイル。相対パスで昇順に並びます
- パスに空白が含まれても壊れないよう、区切りはタブ固定です
- `--no-header` を付けるとヘッダ行を出しません (`diff` でそのまま比べたいとき用)

標準エラーへは、呼び出し元が読むための `KEY=VALUE` も出ます。

```
WCD_LIST_ENTRIES=3
WCD_LIST_ROOT=/opt/jboss-eap/standalone/tmp/vfs/temp/tempaaa/content-bbb
WCD_LIST_SIMULATE=none
```

### 7.2 差分レポート

```
===================================================================
MD5 ダイジェストリストの差分レポート
===================================================================
作成日時     : 2026-09-13 11:37:05
判定         : 差分あり (2 件)

リスト1 : /var/reports/build_and_verify_20260913113700_deployed_class_list1_war.txt
  名前       : リスト1 (デプロイ前の WAR: orders.war)
  対象       : WAR のルート (一時展開: /tmp/war-class-digest.Vei2Yx/war)
  対象拡張子 : class
  件数       : 4 件
  偽装       : extra(1) (目印: SIMULATED)
リスト2 : /var/reports/build_and_verify_20260913113700_deployed_class_list2_vfs.txt
  ...

--- 内訳 ---------------------------------------------------------
一致                 : 2 件
リスト1 のみに存在   : 1 件  (リスト1 にあるのに リスト2 に無い)
リスト2 のみに存在   : 0 件  (リスト1 に無いのに リスト2 にある)
MD5 不一致           : 1 件  (同じパスだが中身が違う)

[A] リスト1 側の差分: リスト1 にのみ存在するファイル (1 件)
    [リスト1のみ] WEB-INF/classes/SIMULATED/SimulatedOnly1.class  MD5=feedface000000000000000000000001

[B] リスト2 側の差分: リスト2 にのみ存在するファイル (0 件)
    (なし)

[C] 両方に存在するが MD5 が一致しないファイル (1 件)
    [MD5不一致] WEB-INF/classes/com/example/Alpha.class
        リスト1 MD5: bf072e9119077b4e76437a93986787ef
        リスト2 MD5: deadbeef000000000000000000000001

--- 読み方 -------------------------------------------------------
[A] が出る   : ビルドした成果物にあるファイルがデプロイ先へ届いていない。
               ...
```

**どちら側の差分なのかを、節の見出しと行頭の目印の両方で示します。**

| 節 | 意味 | 主な原因 |
| --- | --- | --- |
| `[A] リスト1 側の差分` | WAR にあるのにデプロイ先に無い | マウントによる隠蔽 / デプロイの失敗 |
| `[B] リスト2 側の差分` | デプロイ先にしか無い | 前回の成果物の残り / 別ビルドの混入 |
| `[C] MD5 不一致` | 同じパスで中身が違う | 取り込み漏れ / キャッシュ |

標準エラーへは件数の `KEY=VALUE` も出ます。

```
WCD_COMPARE_LIST1=4
WCD_COMPARE_LIST2=3
WCD_COMPARE_SAME=2
WCD_COMPARE_ONLY1=1
WCD_COMPARE_ONLY2=0
WCD_COMPARE_DIFF=1
WCD_COMPARE_TOTAL=2
```

---

## 8. 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 正常終了 (`--compare` では **差分なし**) |
| 1 | `--compare` で差分を検出した |
| 2 | 使い方の誤り (不正なオプション、入力の指定漏れ) |
| 3 | 対象が見つからない (WAR が無い / vfs temp が無い / デプロイルートが特定不能・複数) |
| 4 | 実行環境が足りない (MD5 を計算できない / WAR を展開できない) |

`--compare` の 0 と 1 だけが「判定結果」で、2 以上は「判定できなかった」です。
呼び出し元はこの区別で扱いを分けてください。

---

## 9. 差分の偽装 (動作確認用)

差分がある状態を意図的に作り、レポートの見え方と終了コードを確認するための
仕組みです。**生成した一覧へ後から手を加えるだけ**で、実ファイルには一切触れません。

| `--simulate` | やること | 突き合わせでどう見えるか |
| --- | --- | --- |
| `none` | 何もしない (既定) | — |
| `extra` | 実在しない項目を N 件足す | **そのリストにだけ**ある差分になる |
| `drop` | 先頭から N 件を落とす | **もう一方のリストにだけ**ある差分になる |
| `modify` | 先頭から N 件の MD5 を書き換える | 同じパスで**中身が違う**差分になる |
| `all` | `drop` → `modify` → `extra` をこの順で適用 | 上記すべて |

偽装であることが一目で分かるよう、次のようにしてあります。

- 偽装で足す MD5 は `feedface...`、書き換える MD5 は `deadbeef...` で始まる
  (実在の MD5 と紛れない)
- 偽装で足すパスは `WEB-INF/classes/<目印>/SimulatedOnlyN.<拡張子>`
  (目印は `--simulate-tag`、既定 `SIMULATED`)
- 一覧のヘッダ `# simulate :` に適用した内容が残る
- 差分レポートにも各リストの `偽装 :` 欄として出る
- 偽装を適用したことは標準エラーへ警告として出る

> **両方のリストへ `extra` を足すときは `--simulate-tag` を分けてください。**
> 目印が同じだとパスも偽装 MD5 も一致してしまい、互いに打ち消し合って
> 差分として現れません。`build_and_verify.sh` から使う場合は、リスト1 へ
> `SIMULATED_LIST1`、リスト2 へ `SIMULATED_LIST2` が自動で割り当てられます。

---

## 10. build_and_verify.sh からの使われ方

`build_and_verify.sh` は、このスクリプトと**同一の内容**を自身に埋め込んでいます
(`--print-war-class-digest` で取り出せます)。ホスト側は一時ファイルへ書き出して
実行し、コンテナ内へは `docker exec` の標準入力経由で配ってから実行するため、
コマンドライン長の上限に掛かりません。

```
build_and_verify.sh
  │
  ├─ [ビルド前] --copy-file のコピー直後
  │     sh war_class_digest.sh --war <WAR> --ext class --output <...list1_war.txt>
  │     → リスト1
  │
  ├─ [デプロイ成功後] 起動確認と healthcheck を通過した時点
  │     cat war_class_digest.sh | docker exec -i <cid> sh -c '... --vfs-dir auto ...'
  │     → リスト2
  │
  └─ [突き合わせ]
        sh war_class_digest.sh --compare <list1> <list2> --output <...diff.txt>
        → 差分レポート + 全量レポートの [15] へ記載
```

### 対応するパラメータ

| build_and_verify.sh | war_class_digest.sh | 備考 |
| --- | --- | --- |
| `--verify-deployed-classes` | — | 機能の有効化 (既定は無効) |
| `--deployed-class-ext LIST` | `--ext LIST` | 既定 `class` |
| `--deployed-class-war PATH` | `--war PATH` | 未指定なら `--copy-file` の `.war` |
| `--deployed-class-vfs-dir PATH` | `--vfs-dir PATH` | 既定 `auto` |
| `--deployed-class-deployment NAME` | `--deployment NAME` | — |
| `--deployed-class-nested-jar` | `--no-default-exclude` | — |
| `--deployed-class-dir DIR` | `--output DIR/...` | 既定は `--report-dir` と同じ |
| `--deployed-class-simulate MODE` | `--simulate ...` | 下表のとおり読み替える |
| `--deployed-class-simulate-count N` | `--simulate-count N` | — |
| `--deployed-class-required` | — | 差分・未実施をエラー終了にする |

`--deployed-class-*` を 1 つでも指定すると、差分検証は自動で有効になります
(`--verify-deployed-classes` を書く必要はありません)。
`--no-verify-deployed-classes` との併用は指定の取り違えとみなし、その場で中止します。
出力先が決まらない実行 (`--report-dir` も `--deployed-class-dir` も無い) も、
リストの書き出し先が無いため起動前に中止します。

### 偽装モードの読み替え

`build_and_verify.sh` 側は「どちらのリストに差分があるのか」で指定し、
内部でリストごとの `--simulate` へ読み替えます。

| `--deployed-class-simulate` | リスト1 へ | リスト2 へ | 見え方 |
| --- | --- | --- | --- |
| `none` | `none` | `none` | 差分なし |
| `list1` | `extra` | `none` | `[A]` にだけ出る |
| `list2` | `none` | `extra` | `[B]` にだけ出る |
| `both` | `extra` | `extra` | `[A]` と `[B]` の両方 |
| `modify` | `none` | `modify` | `[C]` にだけ出る |
| `all` | `extra` | `all` | `[A]` `[B]` `[C]` すべて |

`--simulate-tag` はリストごとに `SIMULATED_LIST1` / `SIMULATED_LIST2` が
自動で割り当てられます。同じ目印にすると、両方へ足した項目が互いに一致して
しまい差分として現れないためです。

### 出力ファイル

既定では `--report-dir` と同じディレクトリへ、全量レポートと対で並ぶ名前で出ます。

| ファイル | 内容 |
| --- | --- |
| `build_and_verify_<日時>_deployed_class_list1_war.txt` | リスト1 |
| `build_and_verify_<日時>_deployed_class_list2_vfs.txt` | リスト2 |
| `build_and_verify_<日時>_deployed_class_diff.txt` | 差分レポート |
| `build_and_verify_<日時>.txt` の `[15]` | 上の要約と差分レポートの全文 |

---

## 11. 実行例

```sh
# デプロイ前の WAR から class の一覧を作る (リスト1)
tools/war_class_digest.sh --war target/orders.war \
    --label 'リスト1 (デプロイ前の WAR)' --output /var/reports/list1.txt

# 動いているコンテナの中で、展開結果の一覧を作る (リスト2)
docker exec -i orders-app sh -c 'cat > /tmp/wcd.sh && sh /tmp/wcd.sh "$@"' _ \
    --vfs-dir auto --label 'リスト2 (デプロイ後の vfs/temp)' \
    < tools/war_class_digest.sh > /var/reports/list2.txt

# 突き合わせる (差分があれば終了コード 1)
tools/war_class_digest.sh --compare /var/reports/list1.txt /var/reports/list2.txt \
    --output /var/reports/diff.txt
echo "exit=$?"

# jar と xml も対象にする
tools/war_class_digest.sh --war target/orders.war --ext class,jar,xml

# 展開済みディレクトリ同士を比べる
tools/war_class_digest.sh --dir /opt/app/expected --output /tmp/a.txt
tools/war_class_digest.sh --dir /opt/app/actual   --output /tmp/b.txt
tools/war_class_digest.sh --compare /tmp/a.txt /tmp/b.txt

# 差分がある状態を偽装して、レポートの見え方を確かめる
tools/war_class_digest.sh --war target/orders.war --simulate extra --output /tmp/l1.txt
tools/war_class_digest.sh --dir /opt/app/actual   --simulate modify --output /tmp/l2.txt
tools/war_class_digest.sh --compare /tmp/l1.txt /tmp/l2.txt

# 手作業で同じことをする手順を見る
tools/war_class_digest.sh --show-commands
```

`build_and_verify.sh` から使う場合は次のようになります。

```sh
# 既定 (class のみ) で差分検証まで行う
./build_and_verify.sh --verify-startup --report-dir /var/reports \
    --copy-file target/orders.war:./app \
    --verify-deployed-classes

# 対象拡張子を広げ、差分があればエラー終了させる
./build_and_verify.sh --verify-startup --report-dir /var/reports \
    --copy-file target/orders.war:./app \
    --deployed-class-ext class,jar --deployed-class-required

# 差分がある状態を偽装して、レポートの見え方を確認する
./build_and_verify.sh --verify-startup --report-dir /var/reports \
    --copy-file target/orders.war:./app \
    --deployed-class-simulate both --deployed-class-simulate-count 3

# スクリプト本体を取り出す
./build_and_verify.sh --print-war-class-digest > /tmp/war_class_digest.sh
```

---

## 12. 制約と注意点

- **入れ子 jar の中身は展開しません。** WAR に含まれる `WEB-INF/lib/*.jar` は
  1 ファイルとして扱います (`--ext jar` を指定したときのみ一覧に載ります)。
  vfs/temp 側で JBoss EAP が入れ子 jar を展開していた場合は、既定で
  `*.jar/*` を除外します。
- **パスに改行やバックスラッシュを含むファイルは対象外**にします
  (1 行 1 ファイルという前提が崩れるため。除外したことは標準エラーへ出ます)。
- **MD5 は改ざん検知には使いません。** ここでの用途は「同じビルド成果物か」の
  照合であり、暗号学的な強度は要求されません (速度を優先しています)。
- **WAR は一時ディレクトリへ展開します。** 展開先は終了時に必ず削除しますが、
  `TMPDIR` に WAR と同程度の空き容量が必要です。
- **vfs/temp には過去の実行が残したディレクトリが残ることがあります。**
  デプロイルートが複数見つかった場合はエラーで止まるので、`--deployment` で
  絞ってください。
- **タイムスタンプやパーミッションは見ません。** 中身 (MD5) とパスだけを比べます。

---

## 13. エラーと対処

| メッセージ | 終了コード | 対処 |
| --- | --- | --- |
| `WAR ファイルが見つかりません: ...` | 3 | `--war` のパスを確認する |
| `WAR を展開できませんでした (unzip exit=N)` | 3 | WAR が壊れていないか確認する |
| `WAR を展開できるコマンドがありません` | 4 | `unzip` / `jar` / `python3` のいずれかを入れる |
| `MD5 を計算できるコマンドが見つかりません` | 4 | `md5sum` / `openssl` / `md5` / `digest` のいずれかを入れる |
| `vfs temp ディレクトリが見つかりません: ...` | 3 | `--vfs-dir` にパスを渡す。`auto` なら `JBOSS_HOME` を設定する |
| `vfs temp 配下に展開済みデプロイルート ... がありません` | 3 | まだ展開されていない (デプロイ前 / デプロイ失敗) 可能性がある |
| `展開済みデプロイルートが複数見つかりました (N 件)` | 3 | `--deployment` で 1 つに絞る |
| `指定したデプロイ名に一致する展開済みデプロイルートがありません` | 3 | `--deployment` の値を見直す |
| `--ext に有効な拡張子がありません` | 2 | カンマ区切りで拡張子を指定する (`all` ですべて) |
| `--simulate には none / extra / drop / modify / all ...` | 2 | 値を見直す |
| `入力の指定は 1 つだけにしてください` | 2 | `--war` / `--dir` / `--vfs-dir` のどれか 1 つにする |

`build_and_verify.sh` 側では、これらはいずれも **既定では警告どまり**で処理を続け、
全量レポートの `[15]` へ「未実施」として理由が残ります。エラー終了させたい場合は
`--deployed-class-required` を指定してください。
