# Container Compose Build & Push

ローカルベースイメージをビルドし、ECR へタグ付けしてプッシュ、
`imagedefinition.json` を出力するためのスクリプトです。ビルド方法の異なる
2 つのスクリプトを提供します (ビルド以降の処理・オプションは共通)。

> **スクリプト別の詳細資料** — パラメータ、全体構成、処理フローを網羅した資料を
> `docs/` に用意しています。
>
> | スクリプト | Markdown 版 | Excel 版 |
> | --- | --- | --- |
> | `build_and_push.sh` | [詳細ガイド](docs/build_and_push_guide.md) | [build_and_push_guide.xlsx](docs/build_and_push_guide.xlsx) |
> | `buildx_build_and_push.sh` | [詳細ガイド](docs/buildx_build_and_push_guide.md) | [buildx_build_and_push_guide.xlsx](docs/buildx_build_and_push_guide.xlsx) |
> | `build_and_verify.sh` | [詳細ガイド](docs/build_and_verify_guide.md) | [build_and_verify_guide.xlsx](docs/build_and_verify_guide.xlsx) |
>
> - Excel 版は各ガイドと同じ内容を 5 シート構成へ組み直したものです (後述)。
> - [scripts_reference.xlsx](docs/scripts_reference.xlsx) — 3 スクリプトを横断して一覧化した
>   Excel 資料 (全 9 シート。`08_JVM_OTel設定` に JVM パラメータの分類と
>   OpenTelemetry 環境変数の特定条件をまとめています)。こちらも同じ md から生成します

### Excel 版ガイド (`docs/*_guide.xlsx`)

md ガイドと同じ内容を、Excel で読みやすい 5 シート構成へ組み直したものです。
フォントは全シート **Meiryo UI**、列幅と行高は内容から計算して明示しているため、
折り返した本文が既定の行高で切れることがありません。

| シート | 記載内容 |
| --- | --- |
| `00_目次` | 対象スクリプト・役割・生成日時・シート索引 |
| `01_スクリプト仕様` | 役割 / できること / 全体構成 / 処理の流れ / 入出力ファイル / 終了コード / 環境変数 |
| `02_パラメータ一覧` | **指定可能なパラメータ**の全件 (分類・値の形式・既定値・複数指定の可否・説明)。オートフィルタとウィンドウ枠固定つき。既定値が効いている行は色を変えて強調 |
| `03_既定で有効な動作` | **オプションを指定しなくても有効な動作**。「オプション不要で動く機能」「既定値を持つパラメータ」「その他の既定挙動」の 3 部構成 |
| `04_設定例` | 用途別の**設定例**。コマンド列はそのままコピーして使えます |

### 3 スクリプト横断リファレンス (`docs/scripts_reference.xlsx`)

3 本のガイドを横断して 1 冊にまとめた資料です。同じ生成スクリプトで作られます。

| シート | 記載内容 |
| --- | --- |
| `00_概要` | 3 スクリプトの比較 (役割・パラメータ数・終了コード数・環境変数数)、前提条件の突き合わせ、使い分け |
| `01_build_and_push` / `02_buildx_build_and_push` / `03_build_and_verify` | スクリプト別のパラメータ一覧 (オートフィルタ付き) |
| `04_処理フロー` | スクリプト別の処理フェーズ。元ガイドの見出しと列構成をそのまま保持 |
| `05_終了コード` | スクリプト別の終了コードと発生条件 |
| `06_環境変数` | 入力として参照する環境変数 / スクリプトが設定する環境変数 |
| `07_実行例` | スクリプト別の実行例 |
| `08_JVM_OTel設定` | `build_and_verify.sh` の JVM パラメータ分類と OpenTelemetry 設定の検出条件 |

### 再生成

内容は `docs/*_guide.md` から機械的に抽出しているため、二重管理は発生しません。
**md を更新したら次のコマンドで Excel 版を再生成してください。**

```bash
# ガイド 3 本 + scripts_reference.xlsx をまとめて再生成
python3 docs/generate_guide_xlsx.py

# 特定のガイドだけ変換 (3 本揃わないため scripts_reference.xlsx はスキップされる)
python3 docs/generate_guide_xlsx.py docs/build_and_verify_guide.md

# 横断リファレンスだけ再生成
python3 docs/generate_guide_xlsx.py --reference-only
```

生成には Python 3 だけが必要です (`openpyxl` などの追加パッケージは不要。
xlsx は標準ライブラリだけで組み立てます)。

| スクリプト | ビルド方法 |
| --- | --- |
| `build_and_push.sh` | `compose.yml` を使った `docker compose build` |
| `buildx_build_and_push.sh` | `docker buildx build` (compose 不使用)。ECR ログイン (`aws ecr get-login-password \| docker login`)、`docker image tag`、`docker image push` を個別コマンドで実行 |

さらに、**ビルドのみを行う** (ECR へはプッシュしない) 専用スクリプトとして
`build_and_verify.sh` を提供します。ビルドに加えて、コンテナを起動して
**jbosseap (WildFly/JBoss EAP) サーバーの起動確認**や、**指定 URL への HTTP 応答確認**、
**同時に起動した Compose サービスのログ表示**、**コンテナ内ディレクトリツリーの表示**、
**デプロイ済み Web アプリケーションの各ルート表示**、
**Java の JVM パラメータ一覧表示**、**OpenTelemetry 環境変数・JVM パラメータ一覧表示**、
**全量テキストレポートの保存**、
**WAR デプロイ時 Java 例外エラー解析** (スタックトレースと例外クラスから原因分析と
対処提案を生成し、Excel ブックとテキストファイルにも出力)、
**JBoss マスターパスワードの伝搬検証** (取得元から実行時に利用される値までの一致確認)、
**CloudWatch Agent (cwagent) のログ送信検証** (設定ファイルのチェックと、
`--cwagent-delivery-report` 指定時の設定済みロググループへの送達確認)、
起動状態を維持した検証対象コンテナへの **bash 直接接続 / 対話式 HTTP 通信**と、
**起動中 Compose サービスを選択したログ閲覧・bash・healthcheck・MySQL 操作**、および
**cwagent / OTel のローカル送達診断**を任意で行えます。
`build_and_push.sh --build-only` はこのスクリプトへ委譲されます
(後述の「ビルドのみの実行 / 起動・URL 確認」を参照)。

想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。

### 時刻表示について

3 スクリプトが表示・保存する時刻はすべて **JST (日本標準時)** に統一しています。
ホストや CI のタイムゾーンが UTC でも、ログ行の先頭時刻、レポートの日時、イメージタグ・
ログファイル名の `YYYYMMDDHHMMSS`、healthcheck 履歴、`docker image inspect` の作成日時、
CloudWatch Logs / Jaeger 診断のイベント時刻は JST で表示されます。ログ行の時刻には
`2026-07-25 17:31:26 JST` のようにタイムゾーン名を併記します
(`Asia/Tokyo` を解決できない環境では tzdata 不要の `JST-9` を使用します)。
なお、コンテナ内アプリケーションが自身で出力するログ行の時刻は、
そのコンテナのタイムゾーン設定に従います。

## 使い方

```bash
# compose 版
./build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
    --auto-switchback --switchback-shell /opt/team/switchback.sh

# buildx 版
./buildx_build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
    --auto-switchback --switchback-shell /opt/team/switchback.sh
```

## イメージタグについて

イメージタグは `<TAG_PREFIX>-<YYYYMMDDHHMMSS>` の形式で生成されます。
接頭辞 (`--tag-prefix`) は **ECR リポジトリ名 (`--repository`) とは独立** して指定でき、
既定値は `BaseImage` です。

- 例 (既定): `BaseImage-20260702153000`
- リポジトリ名を変更してもタグ接頭辞は影響を受けません。

### 命名規則の制約

ECR / Docker の規則により、**リポジトリ名 (`--repository`) には大文字を使えません**
(使用可能: 小文字英数字と `.` `_` `-` `/`)。**タグ (`--tag-prefix`) は大文字も使えます**
(使用可能: 英数字と `.` `_` `-`、先頭は英数字か `_`、タグ全体で 128 文字以内)。

両スクリプトはビルド開始前にこれらを検証し、違反していれば `exit 2` で終了します
(ビルド完了後の `docker image tag` で
`invalid reference format: repository name must be lowercase` となって
ビルド時間を無駄にしないため)。

```bash
# リポジトリ名は my-repo、タグ接頭辞は BaseImage
./build_and_push.sh --repository my-repo --tag-prefix BaseImage
#  => my-repo:BaseImage-20260702153000
```

## オプション

2 スクリプトで共通のオプション (ビルド関連のみ異なります。後述の「buildx 版のみのオプション」参照)。

| オプション | 説明 | 既定値 / 環境変数 |
| --- | --- | --- |
| `--account-id ID` | ECR レジストリの AWS アカウント ID | env: `AWS_ACCOUNT_ID` |
| `--region REGION` | AWS リージョン | `ap-northeast-1` / env: `AWS_REGION` |
| `--registry URL` | ECR レジストリ名(URL) を明示指定 | env: `ECR_REGISTRY`<br>未指定時は `<account-id>.dkr.ecr.<region>.amazonaws.com` を組み立て |
| `--repository NAME` | ECR リポジトリ名 = プッシュするイメージ名。ECR / Docker の規則により**小文字**英数字と `.` `_` `-` `/` のみ | `baseimage` |
| `--tag-prefix PREFIX` | イメージタグの接頭辞。リポジトリ名とは独立に指定でき、タグは `<PREFIX>-<YYYYMMDDHHMMSS>` となる (タグは大文字可) | `BaseImage` |
| `--local-image NAME` | ビルドで生成されるローカルイメージ名 | `j1/base.local` |
| `--container-name NAME` | `imagedefinition.json` の name | `--repository` の値 |
| `--compose-file FILE` | compose ファイル (**compose 版のみ**) | `compose.yml` |
| `--compose-service NAME` | ビルド対象サービス名 (未指定なら全サービス) (**compose 版のみ**)。`build_and_verify.sh` / `--build-only` では繰り返し指定またはカンマ区切りで複数指定できる。複数指定時は `base` を先行ビルドする。`base` はビルド専用のため、指定に含めても**起動対象にはならない** | (全サービス) |
| `--no-cache` | キャッシュを破棄してビルドする | `false` |
| `--output FILE` | imagedefinition の出力先 | `imagedefinition.json` |
| `--dry-run` | 実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は行わず、実行内容のプレビューのみ表示する | `false` |
| `--cleanup-all-docker-data` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。処理終了時に確認ダイアログを表示し、承認後、現在の Docker context の全コンテナ・全イメージ・全ローカルボリューム・未使用ネットワーク・現在の daemon で削除可能な全ビルドキャッシュを削除する | `false` |
| `--no-reclaim-old-image` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。既定で有効な「世代交代した旧イメージ (dangling) の回収」を行わない。既定ではビルド前後の image ID を突き合わせ、タグを失った旧世代だけを削除する | `false` (= 回収する) |
| `--prune-build-cache` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。処理終了時に `docker builder prune --all --force` でビルドキャッシュを削除する | `false` |
| `--prune-build-cache-keep SIZE` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。処理終了時に `docker builder prune --force --keep-storage SIZE` を実行し、`SIZE` (例: `10GB`) だけ残してビルドキャッシュを削除する | (なし) |
| `--disk-usage-report` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。ビルド前と処理終了時に `docker system df` の合計を測定し、実行前からの増減を表示する (削除は行わない) | `false` |
| `--wait-healthy` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。`docker compose up` に `--wait` を付け、起動対象サービスが healthy (healthcheck 未定義なら running) になるまで compose 側で待ってから起動確認へ進む。依存サービスの準備完了前にアプリが起動して失敗するのを防ぐ | `false` |
| `--wait-timeout SEC` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。`--wait` の最大待機秒数。指定すると `--wait-healthy` も暗黙に有効化する | `600` |
| `--allow-service-exit NAME` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。起動確認中に停止していても失敗扱いにしないサービス名。繰り返し指定またはカンマ区切りで複数指定できる | (なし) |
| `--startup-log-lines N\|all` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。検証対象のコンテナ起動ログ、同時に起動した他 Compose サービスのログ、`--keep-container-mode logs` で選択したログについて、サービスごとの画面表示行数を指定する。`N` は末尾 `N` 行、`all` は全行を表示する | `50` |
| `--shutdown-timeout SEC` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。エラー終了時に ECS のタスク停止と同じく SIGTERM でコンテナを終了させる際、SIGKILL へ切り替えるまでの猶予秒数。この停止を挟むことで、adot collector などサイドカーの終了処理ログまで画面と全量レポートへ残す | `30` |
| `--no-shutdown-logs` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。エラー終了時の SIGTERM 停止と終了ログ取得を行わず、従来どおり `docker compose down` でまとめて削除する | `false` |
| `--keep-container-mode bash\|http\|logs` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。JBoss EAP の起動確認後もコンテナを残し、検証対象へ `/bin/bash` で直接接続するか、対話式 HTTP 通信、起動中 Compose サービスを選択したログ閲覧・bash・healthcheck・MySQL 操作を行う。`logs` では cwagent / CloudWatch Logs モックおよび OTel / Jaeger の送達診断も選択できる。`--verify-startup` と `--keep-container` を暗黙に有効化する | (なし) |
| `--exit-on-deploy-error` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。デプロイエラー (AP サーバは起動したがアプリのデプロイに失敗) を検出しても調査用の対話操作へ入らず、従来どおりログを出力して終了する。既定ではコンテナと AP サーバを起動したまま残し、各 Compose サービスへ接続して調査できる状態にする | `false` |
| `--jboss-context-root ROOT` | 対話式 HTTP モードの JBoss EAP コンテキストルートを明示する。未指定時は起動ログから検出する | (自動検出、検出不能時は `/`) |
| `--jboss-http-port PORT` | 対話式 HTTP モードのコンテナ側 HTTP リスナーポートを明示する。Docker の公開ポートがあれば接続先へ自動変換する | (自動検出、検出不能時は `8080`) |
| `--log-dir DIR` | コンソールに出力されるログを `DIR` 配下のログファイルにも保存する。画面表示は従来どおり継続し、ログ末尾には処理実行時間 (経過秒数) も記録される。`DIR` が無ければ自動作成する。ファイル名は compose 版が `build_and_push_<YYYYMMDDHHMMSS>.log`、buildx 版が `buildx_build_and_push_<YYYYMMDDHHMMSS>.log`。compose 版で `--build-only` 委譲時も、委譲先 (`build_and_verify.sh`) の出力を含めて記録する | (なし。指定時のみログファイル出力) |
| `--build-only` | ビルドのみを実行する (**compose 版のみ**。処理は `build_and_verify.sh` に委譲)。ECR 権限チェック/ログイン/タグ付け/プッシュ/`imagedefinition.json` の出力は行わない。`--copy-file` 指定時は事前コピー → ビルド → 自動削除を行う。`--verify-startup` / `--verify-url` 等の追加オプションも委譲される (後述)。ECR 関連オプション (`--account-id` / `--registry` / `--repository` / `--tag-prefix` / `--container-name` / `--output` / `--switchback-shell` / `--auto-switchback` / `--warn-only`) は委譲先が解釈できないため、**警告のうえ無視される** | `false` |
| `--copy-file SRC:DEST_DIR` | ビルド前に `SRC` を `DEST_DIR` へコピーし、ビルド終了後に自動削除する。繰り返し指定で複数ファイルに対応。コピー先に同名ファイルがある場合の動作はスクリプトごとに異なる (後述) | (なし) |
| `--copy-file-no-overwrite` | **`build_and_verify.sh` / `--build-only` 委譲時のみ**。`--copy-file` のコピー先に同名ファイルがある場合、強制上書きせずに処理を中止する (`exit 1`) | `false` |
| `--env-list-limit N\|all` | **`build_and_verify.sh` / `--build-only` 委譲時**。動作確認成功後に表示する環境変数一覧の件数。各対象コンテナごとに先頭 `N` 件を表示し、既定は `all` | `all` |
| `--env-list-file FILE` | **`build_and_verify.sh` / `--build-only` 委譲時**。動作確認成功後の環境変数一覧を `FILE` にも出力する。画面表示も継続 | (なし) |
| `--directory-tree-depth N\|all` | **`build_and_verify.sh` / `--build-only` 委譲時**。環境変数一覧後のコンテナ内ツリーと JBoss EAP デプロイ構造の最大深さ。各表示ルート直下を深さ `1` とする | `all` (最下層まで) |
| `--directory-file-limit N\|all` | **`build_and_verify.sh` / `--build-only` 委譲時**。通常ファイルの画面表示を有効にする。各ディレクトリ直下が `N` ファイル以下なら全ファイル名、超過時は拡張子別件数へ切り替える。`all` は常に全ファイル名を表示する | 未指定時はファイル非表示 |
| `--deployment-dir-env NAME` | **`build_and_verify.sh` / `--build-only` 委譲時**。ディレクトリの絶対パスを値に持つコンテナ環境変数名。繰り返しまたはカンマ区切りで複数指定でき、その配下を JBoss EAP デプロイ構造と併せて表示する | (なし) |
| `--report-dir DIR` | **`build_and_verify.sh` / `--build-only` 委譲時**。ビルド結果、環境変数全件、コンテナ内ツリー、JBoss EAP デプロイ構造、Java の JVM パラメータ、OpenTelemetry 環境変数・JVM パラメータ、WAR デプロイ時 Java 例外解析を、画面の制限にかかわらず全深度・全ファイル名で日時付きテキストへ保存する。失敗時は全 Compose サービスのログ全文もサービス単位で追記する。あわせて Java 例外解析を `build_and_verify_<日時>_java_exceptions.xlsx` と `..._java_exceptions.txt` (同じ内容) として同じディレクトリへ追加出力する | (なし) |
| `--deploy-exception-excel FILE` | **`build_and_verify.sh` / `--build-only` 委譲時**。WAR デプロイ時 Java 例外解析の Excel ブックの出力先を明示する (`.xlsx`) | (`--report-dir` 配下へ自動命名) |
| `--deploy-exception-text FILE` | **`build_and_verify.sh` / `--build-only` 委譲時**。Excel と同じ内容のテキストの出力先を明示する | (`--report-dir` 配下へ自動命名) |
| `--deploy-exception-limit N` | **`build_and_verify.sh` / `--build-only` 委譲時**。詳細分析を行う例外の最大件数 | `50` |
| `--no-deploy-exception-analysis` | **`build_and_verify.sh` / `--build-only` 委譲時**。WAR デプロイ時 Java 例外の解析と Excel 出力を行わない | `false` |
| `--jboss-password-param NAME` | JBoss のマスターパスワードを AWS パラメータストア (SSM Parameter Store) の指定キー `NAME` から取得し、環境変数経由の BuildKit シークレットとしてビルドに注入する (後述) | (なし) |
| `--jboss-password VALUE` | JBoss のマスターパスワードを直接指定する (パラメータストアから取得しない場合)。`--jboss-password-param` とは同時指定不可 | (なし) |
| `--jboss-password-env NAME` | シークレットの受け渡しに使う環境変数名。このオプションのみを指定した場合は、事前に export 済みの環境変数の値をそのまま使う | `JBOSS_MASTER_PASSWORD` |
| `--jboss-secret-id ID` | BuildKit シークレットの id。**buildx 版** は `--secret id=...` に使う。**`build_and_verify.sh` / `--build-only` 委譲時**は `--verify-jboss-password` のプローブビルドで参照する (compose 版のビルド自体は `compose.yml` の secrets 名で決まる) | `jboss_master_password` |
| `--verify-jboss-password` | **`build_and_verify.sh` / `--build-only` 委譲時**。マスターパスワードが取得元から実行時に利用される値まで一致しているかを段ごとに検証し、結果をビルド時に出力する (後述) | `false` |
| `--jboss-password-mask` | **`build_and_verify.sh` / `--build-only` 委譲時**。伝搬検証の出力でパスワード文字列を伏字にする (判定・バイト長・16 進ダンプは表示) | `false` |
| `--jboss-config-file PATH` | **`build_and_verify.sh` / `--build-only` 委譲時**。コンテナ内の `standalone.xml` のパス | (自動探索) |
| `--jboss-cli-path PATH` | **`build_and_verify.sh` / `--build-only` 委譲時**。コンテナ内の `jboss-cli.sh` のパス | (自動探索) |
| `--jboss-elytron-tool PATH` | **`build_and_verify.sh` / `--build-only` 委譲時**。コンテナ内の `elytron-tool.sh` のパス | (自動探索) |
| `--jboss-credential-store PATH` | **`build_and_verify.sh` / `--build-only` 委譲時**。コンテナ内の CredentialStore ファイルのパス | (`standalone.xml` から特定) |
| `--switchback-shell PATH` | 別チーム提供のスイッチバック用シェルのパス (source で呼び出し) | env: `SWITCHBACK_SHELL` |
| `--auto-switchback` | ECR 権限が無い場合に自動でスイッチバックして継続する | `false` |
| `--warn-only` | ECR 権限が無い場合に警告して終了する (既定) | (既定) |
| `-h`, `--help` | ヘルプを表示 | |

### buildx 版のみのオプション

`buildx_build_and_push.sh` は compose を使わず `docker buildx build` でビルドします。
`docker image tag` / `docker image push` を個別コマンドとして使うため、ビルド結果は
`--load` でローカルの docker イメージストアへ取り込みます (このため単一プラットフォームのみ対応)。

| オプション | 説明 | 既定値 |
| --- | --- | --- |
| `--dockerfile FILE` | Dockerfile のパス | `Dockerfile` |
| `--context DIR` | ビルドコンテキスト | `.` |
| `--platform PLATFORM` | ターゲットプラットフォーム (例: `linux/amd64`)。複数指定は不可 | (現在のプラットフォーム) |
| `--builder NAME` | 使用する buildx ビルダー名 | (現在のビルダー) |
| `--build-arg KEY=VALUE` | ビルド引数 (繰り返し指定可) | (なし) |

buildx 版が実行するコマンドの流れ:

```bash
docker buildx build --load -t j1/base.local -f Dockerfile .
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <registry>
docker image tag j1/base.local <registry>/<repository>:<tag>
docker image push <registry>/<repository>:<tag>
```

## ビルド前後の一時ファイルコピー (`--copy-file`)

ビルドコンテキストに一時的に必要なファイル (例: `.npmrc`、証明書、資格情報ファイルなど) を
ビルド直前にコピーし、**ビルド終了後 (成功・失敗・途中終了のいずれでも) に自動削除**します。
`--copy-file` を繰り返し指定することで複数ファイルに対応できます。

```bash
./build_and_push.sh --account-id 123456789012 \
    --copy-file .npmrc:./app \
    --copy-file certs/ca.pem:./app/certs
```

- 書式は `SRC:DEST_DIR`。`SRC` はコピー元ファイル、`DEST_DIR` は**既存の**コピー先ディレクトリ。
- コピー先ファイル名は `SRC` のベース名になります (例: `.npmrc` → `./app/.npmrc`)。
- `--dry-run` 併用時は、実際のコピー/削除は行わず実行内容のみ表示します。

### コピー先に同名ファイルがある場合

スクリプトによって既定の動作が異なります。

| スクリプト | 既定の動作 |
| --- | --- |
| `build_and_verify.sh` (`build_and_push.sh --build-only` の委譲先を含む) | **強制上書き**する |
| `build_and_push.sh` (`--build-only` なし) / `buildx_build_and_push.sh` | 中止する (`exit 1`) |

`build_and_verify.sh` では、上書き前のファイルを一時退避しておき、処理終了時に
**削除ではなく復元**します。そのためコピー先は実行前の状態へ戻り、自動削除で
既存ファイルを失うことはありません。

```bash
# 既存の ./app/.npmrc を強制上書きしてビルドし、終了時に元の .npmrc へ戻す
./build_and_verify.sh --copy-file .npmrc:./app

# 既存ファイルには一切触れず、あればその時点で中止する
./build_and_verify.sh --copy-file-no-overwrite --copy-file .npmrc:./app
```

- `--copy-file-no-overwrite` は `build_and_verify.sh` のオプションです
  (`build_and_push.sh --build-only` からもそのまま委譲されます)。
- **安全策**: コピー先が通常ファイル以外 (ディレクトリ・シンボリックリンク等) の場合は、
  `--copy-file-no-overwrite` の有無にかかわらず、上書き・自動削除のいずれも行わず中止します。

## ログファイル出力 (`--log-dir`)

`--log-dir DIR` を指定すると、コンソールに出力されるログ (標準出力・標準エラー出力) を
`DIR` 配下のログファイルにも保存します。画面表示は従来どおり継続するため、対話実行でも
CI でもそのまま利用できます。compose 版 (`build_and_push.sh`) / buildx 版
(`buildx_build_and_push.sh`) の両方で使えます。

```bash
# compose 版
./build_and_push.sh --account-id 123456789012 \
    --log-dir ./build-logs
#  => ./build-logs/build_and_push_20260702153000.log にログを保存

# buildx 版
./buildx_build_and_push.sh --account-id 123456789012 \
    --log-dir ./build-logs
#  => ./build-logs/buildx_build_and_push_20260702153000.log にログを保存
```

- ファイル名は `<スクリプト名>_<YYYYMMDDHHMMSS>.log` (実行開始時刻、JST) です。
- `DIR` が存在しない場合は `mkdir -p` で自動作成します。
- 標準出力と標準エラー出力を同一の `tee` にまとめるため、ログの時系列順が保たれます。
- ログの末尾には、ビルド成功・失敗・途中終了のいずれの場合でも **処理実行時間**
  (経過秒数と `HH:MM:SS` 形式) が記録されます。
- `--dry-run` 併用時も、プレビュー出力がそのままログファイルへ保存されます。
- compose 版で `--build-only` を併用した場合も、委譲先 (`build_and_verify.sh`) の
  出力を含めてログファイルへ記録します。

## ビルドのみの実行 / 起動・URL 確認 (`build_and_verify.sh`)

イメージのビルドだけを行い ECR へのプッシュは行わない処理は、専用スクリプト
`build_and_verify.sh` に切り出しています。ローカルでの動作確認や CI でのビルド
検証などに利用できます。`build_and_push.sh --build-only` を指定した場合も、
このスクリプトへ委譲されます (`--build-only`、`--log-dir` (委譲元で処理済み)、および
ECR 関連オプションを除いた引数がそのまま渡されます。ECR 関連オプションを併せて
指定した場合は、無視した旨を警告してからビルドを実行します)。

- ECR 権限チェック / ログイン / タグ付け / プッシュ / `imagedefinition.json` の
  出力はいずれも行いません。
- ECR を操作しないため、`--account-id` / `--registry` や AWS 認証情報は不要です
  (`aws` コマンドが無くても実行できます)。
- **`--copy-file` が指定されている場合は、ビルド前に事前ファイルコピーを行った
  うえでビルドし、処理後に自動削除します**。コピー先に同名ファイルがある場合は
  強制上書きし、処理終了時に上書き前のファイルへ復元します
  (`--copy-file-no-overwrite` を付けると、上書きせず中止します)。
- BuildKit の進捗形式は既定で `plain` とし、各ビルドステップを保存可能なログとして
  出力します。必要な場合は `BUILDKIT_PROGRESS` 環境変数で変更できます。
- ビルド完了後は対象イメージを検査し、イメージ ID・作成日時・サイズを
  `ビルド結果` として出力します。対象イメージが存在しない場合は失敗終了します。

```bash
# ビルドのみ (事前ファイルコピーあり)
./build_and_verify.sh \
    --copy-file .npmrc:./app \
    --copy-file certs/ca.pem:./app/certs

# build_and_push.sh 経由でも同じ (委譲される)
./build_and_push.sh --build-only --copy-file .npmrc:./app

# 何が実行されるかだけ確認 (ビルドも行わない)
./build_and_verify.sh --dry-run
```

### 終了時の Docker 完全クリーンアップ

`--cleanup-all-docker-data` を指定すると、ビルド・動作確認の終了時に、現在の
Docker context を対象とした確認ダイアログを表示します。これはディスク容量を
確実に空けたい一時的なビルド環境向けの、明示的な破壊オプションです。

```bash
./build_and_verify.sh --cleanup-all-docker-data

# build_and_push.sh の build-only 委譲でも利用可能
./build_and_push.sh --build-only --cleanup-all-docker-data
```

確認画面には Docker context、Docker 管理対象の使用量、コンテナ・イメージ・
ボリュームの件数と、次の処理対象を表示します。

1. Compose プロジェクトを含む、実行中の全 Docker コンテナ (一時停止中の
   コンテナは解除) を通常の `docker stop` で停止
2. 停止済みを含む全コンテナ
3. 全ローカルイメージとタグ
4. 全ローカルボリュームと、その中の永続データ
5. 未使用のユーザー定義ネットワーク
6. 現在の Docker daemon で削除可能な全ビルドキャッシュ

削除を開始するには、表示されたプロンプトへ
`DELETE ALL DOCKER DATA` と正確に入力する必要があります。入力できない場合や
一致しない場合は、通常の `build_and_verify.sh` の後始末以外の Docker 全体
クリーンアップを行わず、終了コード `1` で終了します。処理後は
`docker system df` の削除前後を比較した **Docker 管理対象の概算削減容量**を表示し、
Docker data root のファイルシステムを参照できる場合は、ホスト側の空き容量増加も
併記します。

- 同じ Docker daemon を使う他プロジェクトのデータも対象になり、元に戻せません。
- Docker daemon / Docker Desktop 自体、標準ネットワーク、Docker context、
  レジストリ認証情報、daemon 設定は停止・削除しません。
- `--keep-container` とは同時に指定できません。
- `--dry-run` との併用時は、対象と予定コマンドだけを表示し、確認入力も削除も
  行いません。
- ビルドまたは動作確認が失敗した場合も、実処理開始後であれば終了時に同じ確認を
  行います。元の処理が失敗していた場合、その終了コードを優先します。

### 実行のたびに増えるディスク使用量を抑える

検証を繰り返すと、`--cleanup-all-docker-data` を使わない限り次の 2 つが積み上がります。

| 対象 | 増える理由 |
| --- | --- |
| 旧世代のローカルイメージ | `docker compose build` は `j1/base.local` のタグを新しいイメージへ付け替えるだけで、直前の世代はタグを失った `<none>:<none>` (dangling) として残ります。`--no-cache` では全レイヤが作り直され、直前世代と共有するレイヤが 1 つも無いため、**実行のたびにイメージ 1 個分がまるごと**積み上がります |
| BuildKit のビルドキャッシュ | `--no-cache` は「既存のキャッシュを**読まない**」指定であって「**書かない**」指定ではありません。実行のたびに全レイヤ分の新しいキャッシュレコードが書き足されます |

`docker compose down` が削除するのはコンテナと Compose が作ったネットワークだけで、
イメージ・ボリューム・ビルドキャッシュには触れません。

**旧世代イメージの回収は既定で有効**です。ビルドの前後で image ID を突き合わせ、
世代交代した旧 ID がどのタグからも参照されていない (= dangling である) 場合だけ削除します。
`docker image prune` と違い、今回のビルドで生じた 1 件だけを対象とするため、
同じ Docker daemon を使う他プロジェクトの dangling イメージには影響しません。

```bash
# 推奨: 増えた分をその実行のうちに戻す
./build_and_verify.sh --no-cache --verify-startup \
    --disk-usage-report --prune-build-cache-keep 10GB

# 使用量の増減だけ先に測る (削除は行わない)
./build_and_verify.sh --no-cache --disk-usage-report

# 世代を比較したいので旧イメージを残す (調査用)
./build_and_verify.sh --no-cache --no-reclaim-old-image
```

`--disk-usage-report` は `docker system df` の合計をビルド前と終了時に測り、
実行前からの増減を表示します。

```
[... JST] Docker 使用量 (ビルド前): 2.79 GiB (docker system df による概算)
[... JST] Docker 使用量 (終了時): 3.17 GiB (docker system df による概算)
[... JST]   実行前からの増減: +381.47 MiB
```

- `--prune-build-cache` / `--prune-build-cache-keep` は、**同じ Docker daemon を使う
  他プロジェクトのビルドキャッシュも削除します**。常設したいだけなら、
  `/etc/docker/daemon.json` の `builder.gc` で上限を決める方が安全です。
- `--keep-storage` を持たない buildx (0.17 以降は `--max-used-space` へ改名) では、
  削除を行わず警告のみを表示します。
- `compose.yml` 側の対策 (イメージを作らないビルド検証、キャッシュのレジストリ退避、
  ログ上限など) を含む詳細は、補足資料
  [docs/build_and_verify_disk_usage.xlsx](docs/build_and_verify_disk_usage.xlsx)
  にまとめています。

### 複数 Compose サービスのビルド・起動

`--compose-service` は繰り返し指定とカンマ区切りの両方に対応しています。複数の
サービスを指定すると、ベースイメージを提供する **`base` サービスを必ず最初に
単独でビルド**し、`--local-image` のイメージが生成されたことを確認してから、
残りのサービスを 1 回の `docker compose build` にまとめて並列ビルドします。
Compose v2 では `--parallel <指定サービス数>`、Compose v1 では
`docker-compose build --parallel` を使用して並列実行を明示します。

```bash
# 繰り返し指定
./build_and_verify.sh \
    --compose-service app \
    --compose-service batch \
    --compose-service db

# カンマ区切り (上と同じ)
./build_and_verify.sh --compose-service app,batch,db
```

上の例で実行されるビルド順は次のとおりです。

```text
1. docker compose --parallel 3 -f compose.yml build base
2. docker compose --parallel 3 -f compose.yml build app batch db
```

- `base` が `--compose-service` に含まれている場合も、第2フェーズでは除外されるため
  二重にはビルドしません。
- `base` はベースイメージを提供するビルド専用サービスとして扱い、**指定に含めても
  含めなくても起動対象には追加しません**。`base` だけを指定して起動確認を要求した
  場合は、起動対象が無いためエラー終了します (exit 2)。
- 起動確認またはURL確認を有効にした場合、`base` を除く指定サービスは1回の
  `docker compose up -d --no-build` にまとめて同時に起動します。
- `--wait-healthy` を付けると `docker compose up` に `--wait` が加わり、起動対象
  サービスが healthy になるまで compose 側で待ってから起動確認へ進みます。
  依存サービス側に `healthcheck` と `depends_on` の `condition: service_healthy`
  を定義しておくことが前提です。
- 起動確認のポーリング中は、検証対象だけでなく **`--compose-service` で指定した
  全サービスの生存**を確認します。いずれかが停止した時点でそのサービスのログを
  表示して失敗終了するため、検証対象のタイムアウトを待つ必要がありません。
  正常に終了しうるサービスは `--allow-service-exit NAME` で除外できます。
- 1サービスだけを指定した場合と、`--compose-service` を省略した場合は、従来どおり
  1回の `docker compose build` を実行します。

### 起動確認 (`--verify-startup`)

ビルドしたイメージをコンテナとして起動し、**jbosseap (WildFly/JBoss EAP)
サーバーの起動完了**をログから確認します。確認後はコンテナを自動的に停止・削除
します (`--keep-container` を付けると残せます)。

- JBoss EAP 8.1 の正常起動は既定で `WFLYSRV0025` のみを成功とします。
  `WFLYSRV0026` (エラー付き起動) または `WFLYSRV0056` (boot failure) を検出した場合は、
  正常起動ログの有無にかかわらず失敗扱いとします。別の正常起動メッセージを
  使う場合は `--startup-log-pattern` (拡張正規表現) で上書きできます。
  この 2 つは「AP サーバは起動したがアプリのデプロイでエラーになった」状態のため、
  既定ではコンテナを落とさず調査モードへ入ります (後述)。
- `compose up` の直前時刻をログ取得開始時刻として `compose logs --since` に渡し、
  再利用したコンテナに残る過去の起動ログを今回の結果として扱わないようにします。
- `--startup-service NAME` で **JBoss EAP の起動確認を行う Compose サービス**を
  指定できます。繰り返し指定またはカンマ区切りで複数指定でき、指定した全サービスの
  ログを個別に確認します。このオプションだけでも `--verify-startup` が暗黙に有効に
  なります。`--compose-service` と併用する場合は、その起動対象に含まれるサービスを
  指定してください。
- `--startup-timeout` (既定 120 秒) 以内に起動完了ログを検出できない場合、または
  コンテナが起動途中で停止した場合は、コンテナ起動ログを表示して失敗終了します。
- 起動確認の成功時・失敗時とも、検証対象のコンテナ起動ログは既定で末尾 50 行を
  画面表示します。`--startup-log-lines N` で末尾 `N` 行へ変更でき、
  `--startup-log-lines all` で全行表示を明示できます。
- `--startup-service` で検証対象を限定した場合は、同じ `compose up` で現在起動している
  他の Compose サービスも列挙し、検証対象の起動ログ領域の直後へサービス単位で
  順次ログを表示します。各サービスにも `--startup-log-lines` の同じ上限を適用します。
- 対話端末では JBoss EAP ログを、成功系は緑、重要なライフサイクルはシアン、
  warning は黄、error / 起動失敗は赤で表示します。リダイレクト時は ANSI 色コードを
  出力しません。`NO_COLOR` が設定されている場合は色を無効化し、必要な場合は
  `CLICOLOR_FORCE=1` で明示的に有効化できます。
- 動作確認が成功した場合は、**対象コンテナで参照可能な環境変数一覧**も表示します。
  種別は `compose.yml environment` / `build引数` / `コンテナ内部処理` /
  `イメージ既定・その他` を出し分けます。
- 環境変数一覧の表示件数は `--env-list-limit` で制御できます。既定は `all`
  (全件表示) です。
- `--env-list-file FILE` を指定すると、同じ一覧をファイルにも保存できます。
- 環境変数名に `PASSWORD`、`TOKEN`、`SECRET`、`ACCESS_KEY`、`HEADERS` などを含む値は、
  画面とファイルの双方で `[REDACTED]` とし、秘密情報を平文で残しません。
  この置き換えは環境変数一覧だけでなく、後述の JVM パラメータ一覧・
  OpenTelemetry 一覧 (`-Djboss.password=...`、`OTEL_EXPORTER_OTLP_HEADERS` など) にも
  同じ規則で適用します。
- 環境変数一覧の後に、同じ対象コンテナの `/` を起点とした**ディレクトリツリー**を
  `├──`、`└──`、`│` の罫線記号を使ったツリー表記で表示します。画面の既定表示は
  ディレクトリのみで、通常ファイルは表示しません。
  ファイル表示を有効にする場合は `--directory-file-limit N` を指定すると、各ディレクトリ
  直下が `N` 件以下なら全ファイル名、超過時は最終拡張子ごとの件数へ切り替えます
  (`archive.tar.gz` は `.gz`、`.env` と末尾がドットの名前は `(拡張子なし)`)。
  件数にかかわらず全ファイル名を出す場合は `--directory-file-limit all` を指定します。
- コンテナ全体ツリーでは、`/afs`、`/aws`、`/etc`、`/local/aws-cli`、
  `/opt/jboss-eap/.galleon`、`/opt/jboss-eap/modules/system/layers/base`、`/proc`、`/usr/share`、
  `/sys`、`/usr/lib`、`/usr/lib64`、`/usr/local` 自体は表示しますが、その配下は
  探索・表示しません。
  この除外は画面表示と全量レポートの両方へ適用します。
- コンテナ全体のツリーに続けて、`*/standalone/deployments`、
  展開済み Web アプリケーションの `WEB-INF` の親、Java クラスパスルートの
  `WEB-INF/classes` を検出し、**JBoss EAP デプロイ構造**として表示します。
  `--deployment-dir-env NAME` で、絶対ディレクトリパスを値に持つ環境変数も
  同じ表示へ追加できます。複数の Web アプリケーションや環境変数指定にも対応します。
- `--directory-tree-depth N` では各表示ルート直下を深さ `1` として最大深度を
  制限できます。既定の `all` は末端まで探索します。空ディレクトリも表示しますが、
  ファイル表示を有効にした場合も通常ファイル以外の特殊ファイルは集計せず、
  シンボリックリンクは循環を避けるため追跡しません。コンテナ内で `find` を
  実行できない場合は警告し、
  ビルド・動作確認の成功状態は維持します。
- JBoss EAP デプロイ構造の後に、対象コンテナ内の **Java プロセスの JVM パラメータ**を
  表示します。`ps` や `jcmd` をコンテナへ要求せず、`/proc/<pid>/cmdline` を読み取って
  検出するため、JDK のツール類を含まないランタイム専用イメージでも取得できます。
  詳細は後述の [JVM パラメータと OpenTelemetry 設定の表示](#jvm-パラメータと-opentelemetry-設定の表示) を参照してください。
- JVM パラメータの後に、**OpenTelemetry 関連の環境変数と JVM パラメータ**を
  1 つの一覧にまとめて表示します。Java を実行しない Collector コンテナでも
  環境変数側は同じ形式で確認できます。
- `--report-dir DIR` を指定すると、
  `DIR/build_and_verify_<YYYYMMDDHHMMSS>.txt` へ全量レポートを保存します。
  ビルドまたは動作確認が失敗した場合も、コンテナ停止前に取得できた情報を保存します。
  レポートだけは画面用の件数・深度制限を適用せず、環境変数全件、除外対象を除く
  全ディレクトリ深度、全ファイル名、および検出した JVM パラメータ・OpenTelemetry 設定の
  全件を出力します。起動確認を伴わないビルドのみの場合、コンテナ由来の 5 セクションは
  「未取得」と記録します。`--dry-run` ではファイルを作成せず、出力予定だけを表示します。
  レポートの構成は `[1] ビルド結果` / `[2] 環境変数一覧` / `[3] コンテナ内ディレクトリツリー` /
  `[4] JBoss EAP デプロイ構造` / `[5] Java JVM パラメータ` /
  `[6] OpenTelemetry 環境変数・JVM パラメータ` / `[7] JBoss マスターパスワードの伝搬検証` /
  `[8] CloudWatch Logs 送信検証 (cwagent)` / `[9] Compose サービス別ログ` /
  `[10] WAR デプロイ時 Java 例外解析` です。
- `--report-dir DIR` を指定すると、デプロイ結果ファイルとは**別に**
  `DIR/build_and_verify_<YYYYMMDDHHMMSS>_java_exceptions.xlsx` と、同じ内容の
  `DIR/build_and_verify_<YYYYMMDDHHMMSS>_java_exceptions.txt` を追加出力します。
  WAR のデプロイ処理で発生した Java 例外の解析結果をまとめたもので、
  **コンテナの起動に失敗した場合でも必ず出力します** (デプロイ結果ファイルだけが
  残る状態にはなりません)。解析対象のログを取得できなかった場合は、その理由と
  `未評価` の判定を記録したうえで同じ 2 ファイルを出力します。詳細は後述の
  [WAR デプロイ時の Java 例外エラー解析](#war-デプロイ時の-java-例外エラー解析) を参照してください。
- ビルドや動作確認が失敗した場合、レポート末尾の
  **`[9] Compose サービス別ログ`** へ全 Compose サービスのログ全文を追記します。
  起動確認対象だけでなく、adot collector などのサイドカーを含む
  `compose.yml` 定義の全サービス (コンテナを持つが定義に現れないサービスも含む) が対象で、
  サービスごとに見出し・コンテナ名・状態 (異常終了時は終了コード)・ログ行数を付けて
  区切ります。`--startup-log-lines` や `--suppress-startup-logs` の画面向け制限は
  適用せず全行を残します。ログの取得範囲は今回の `compose up` 以降で、
  `compose up` に到達せずビルドが失敗した場合はコンテナ作成時からの全期間です。
  処理が成功した場合は同じ内容が画面に出ているため、このセクションは省略と記録します。
- **エラー終了時は、コンテナを削除する前に SIGTERM で終了させ、終了処理のログまで
  取得します**。ECS はタスク停止時に各コンテナへ SIGTERM を送るため、
  adot collector のようなサイドカーは「シグナル受信 → パイプラインの
  graceful shutdown → 終了」までをログへ出しますが、`compose down` まで一気に
  実行するとこの終了ログは取得されないまま削除されてしまいます。
  そこでエラー終了時に限り、削除の前に `docker compose stop -t <--shutdown-timeout>`
  (既定 30 秒。ECS の StopTimeout 既定と同じ) を挟み、そこで追加されたログを
  `終了 (SIGTERM) 時のコンテナログ` として画面へ表示し、`[9] Compose サービス別ログ`
  にも終了処理込みの全文を残します。対象は稼働中の全サービスで、表示行は停止前後の
  ログ行数の差分から求めるためホストとコンテナの時刻差に影響されません。
  adot collector の healthcheck 失敗で `depends_on` の `condition: service_healthy`
  を満たせず、バックエンドが起動しないまま `compose up` が失敗した場合も同様です。
  `--keep-container` / `--keep-container-mode` 指定時はコンテナを残すため実行せず、
  `--no-shutdown-logs` を指定すると無効化できます。
  デプロイエラーで調査モードへ入った場合もコンテナを残すため実行しません (後述)。

#### デプロイエラー時の調査モード (既定) / `--exit-on-deploy-error`

AP サーバ (JBoss EAP など) は起動したものの、**アプリのデプロイでエラーになった場合**
(`WFLYSRV0026` / `WFLYSRV0056` を検出)、既定では**コンテナと AP サーバを起動したまま残し、
デプロイ成功後と同じ対話操作を開始**します。コンテナを落とさずに中を調査できます。

- 開始する対話操作は、`--keep-container-mode` を指定していればそのモード、
  未指定なら `logs` です。`logs` では起動中の各 Compose サービスを番号で選び、
  ログ表示・bash 接続・healthcheck 調査・MySQL 実行・送達診断を繰り返し行えます。
- 対話操作に入る前に、失敗した起動ログと **WAR デプロイ時 Java 例外解析**の結果を
  表示するため、原因を見てから調査に入れます。
- 対話操作を終えてもコンテナは起動状態のまま残ります。不要になったら
  `docker compose -f compose.yml down` で削除してください。
- デプロイエラーは失敗のままなので、終了コードは `1` です。
- **起動確認のタイムアウト・コンテナの途中停止・`compose up` の失敗**は
  デプロイエラーではないため、従来どおりそのまま終了します。
- **端末から入力できない場合 (CI など)** は対話操作を開始できないため、コンテナを
  残さず従来どおりの終了処理へ自動的に切り替わります。CI でもコンテナを残したい
  場合は `--keep-container` を併用してください。
- `--exit-on-deploy-error` を指定すると、デプロイエラーでも対話操作へ入らず、
  従来どおりログを出力して終了します。

```bash
# 既定: デプロイエラーでもコンテナを残し、そのまま調査へ入る
./build_and_verify.sh --verify-startup

# デプロイエラー時は bash 接続で調査する
./build_and_verify.sh --verify-startup --keep-container-mode bash

# 従来どおり、デプロイエラーならそのまま終了する
./build_and_verify.sh --verify-startup --exit-on-deploy-error
```

```bash
# ビルド + jbosseap 起動確認
./build_and_verify.sh --verify-startup

# 起動ログのパターン・待機時間を指定
./build_and_verify.sh --verify-startup \
    --startup-log-pattern 'WFLYSRV0025' --startup-timeout 180

# 検証対象と同時起動 Compose サービスのログを、それぞれ末尾 30 行に制限
./build_and_verify.sh --verify-startup \
    --startup-log-lines 30

# 環境変数一覧を 10 件に制限し、ファイルにも保存
./build_and_verify.sh --verify-startup \
    --env-list-limit 10 \
    --env-list-file ./logs/container_envs.txt

# コンテナ内ディレクトリツリーをディレクトリだけ / 直下から 3 階層まで表示
./build_and_verify.sh --verify-startup \
    --directory-tree-depth 3

# デプロイ構造へ APP_CONFIG_DIR 配下を追加し、5 件超のディレクトリは拡張子集計
./build_and_verify.sh --verify-startup \
    --deployment-dir-env APP_CONFIG_DIR \
    --directory-tree-depth 4 --directory-file-limit 5

# 画面は深さ 2・5 件で制限し、レポートは ./build-reports へ全量保存
./build_and_verify.sh --verify-startup \
    --directory-tree-depth 2 --directory-file-limit 5 \
    --report-dir ./build-reports

# app / batch / db をまとめてビルド・起動し、JBoss EAP の app だけを確認
./build_and_verify.sh --compose-service app,batch,db \
    --startup-service app

# app と batch の両方で JBoss EAP の起動完了を個別に確認
./build_and_verify.sh --compose-service app,batch,db \
    --startup-service app --startup-service batch

# adot collector の healthcheck 待ちで失敗した場合に、
# SIGTERM の猶予を 60 秒へ広げて終了処理のログまで確実に取得する
./build_and_verify.sh --compose-service app,adot-collector \
    --startup-service app --wait-healthy \
    --shutdown-timeout 60 --report-dir ./build-reports
```

EAP 8.1の起動ログ解析、同時起動サービスログ、対話操作、healthcheck 診断、ディレクトリツリー集計、
CloudWatch Logs偽装送達レポート、ロググループの自動作成、Jaegerトレースレポートは、
Docker / curl / aws CLIのモックとWireMock / JaegerのJSONフィクスチャを使う
回帰テストで確認できます。

```bash
bash tests/build_and_verify_test.sh
```

### JVM パラメータと OpenTelemetry 設定の表示

起動確認 (`--verify-startup` / `--verify-url`) を伴う実行では、環境変数一覧・
ディレクトリツリー・JBoss EAP デプロイ構造に続けて、**Java の JVM パラメータ**と
**OpenTelemetry 関連設定**を自動で表示します。専用のオプション指定は不要です。
`--report-dir` を指定した場合は、同じ内容が全量レポートの
`[5] Java JVM パラメータ` / `[6] OpenTelemetry 環境変数・JVM パラメータ` へ保存されます。

#### JVM パラメータ一覧

対象コンテナ内の `/proc/<pid>/cmdline` を走査し、実行ファイル名が `java` の
プロセスを検出します。コンテナ側に `ps` / `jcmd` / `jinfo` を要求しないため、
JDK ツールを含まないランタイム専用イメージでも取得できます。
Java プロセスごとに実行ファイル・`java -version` の出力・起動対象 (`-jar` /
主クラス / `--module`) を示したうえで、JVM パラメータを次の分類で表示します。

| 分類 | 対象となるパラメータの例 |
| --- | --- |
| ヒープ・メモリ | `-Xms` / `-Xmx` / `-Xss` / `-XX:MetaspaceSize` / `-XX:MaxDirectMemorySize` / `-XX:+UseCompressedOops` |
| GC (ガベージコレクション) | `-XX:+UseG1GC` / `-XX:MaxGCPauseMillis` / `-Xlog:gc*` / `-XX:NewRatio` |
| Java エージェント | `-javaagent:` / `-agentlib:` / `-agentpath:` |
| OpenTelemetry | `-Dotel.*` / `-Dio.opentelemetry.*` |
| JBoss / WildFly | `-Djboss.*` / `-Dorg.jboss.*` / `-Dwildfly.*` / `-Dlogging.configuration` |
| システムプロパティ (-D) | 上記以外の `-D` 指定 |
| クラスパス・モジュール | `-cp` / `-classpath` / `--module-path` / `--add-opens` / `--add-exports` |
| その他 JVM オプション | `-server` など上記に当てはまらない JVM オプション |
| 起動対象へ渡される引数 | `-jar` / 主クラス より後ろの引数 (JBoss の `-mp` や `org.jboss.as.standalone` など) |

- `-Dkey=value` / `-XX:key=value` / `-javaagent:path` のように書式ごとに名前と値を
  分けて桁揃えするため、長いコマンドラインでも指定内容を読み取れます。
- 該当が 0 件の分類は表示しません。
- `JAVA_OPTS`、`JAVA_OPTS_APPEND`、`JAVA_TOOL_OPTIONS`、`JDK_JAVA_OPTIONS`、
  `_JAVA_OPTIONS`、`JBOSS_JAVA_OPTS`、`JBOSS_JAVA_SIZING`、`JAVA_ARGS` は、
  指定内容が起動コマンドラインに現れないため
  **`[JVM オプションを渡す環境変数]`** として別枠で表示します。
- Java プロセスが見つからないコンテナ (DB、Collector など) では、その旨を表示して
  次のコンテナへ進みます。

#### OpenTelemetry 環境変数・JVM パラメータ一覧

OpenTelemetry の設定は「環境変数」と「JVM システムプロパティ」の 2 経路で
与えられ、どちらか一方だけを見ても実際の構成が分かりません。そこで両方を
1 つの一覧へまとめ、次の種別で表示します。

| 種別 | 判定条件 |
| --- | --- |
| OpenTelemetry 標準環境変数 (`OTEL_*`) | 名前が `OTEL_` で始まる環境変数すべて (`OTEL_SERVICE_NAME`、`OTEL_EXPORTER_OTLP_ENDPOINT`、`OTEL_TRACES_EXPORTER`、`OTEL_RESOURCE_ATTRIBUTES`、`OTEL_PROPAGATORS`、`OTEL_INSTRUMENTATION_*` など) |
| OpenTelemetry 関連環境変数 | `AWS_XRAY_DAEMON_ADDRESS` / `AWS_XRAY_CONTEXT_MISSING` / `AWS_XRAY_TRACING_NAME` / `AWS_LAMBDA_EXEC_WRAPPER` / `AOT_CONFIG_CONTENT`、および値が OpenTelemetry を参照している `JAVA_TOOL_OPTIONS` などの JVM オプション用変数 |
| OpenTelemetry 関連 JVM パラメータ (コマンドライン) | `-Dotel.*` / `-Dio.opentelemetry.*` / OpenTelemetry の `-javaagent:` など |
| OpenTelemetry 関連 JVM パラメータ (環境変数由来) | `JAVA_TOOL_OPTIONS` などの値に含まれる上記のパラメータ |
| 未設定の主要 OpenTelemetry 設定 | 主要設定のうち、環境変数と対応するシステムプロパティ (`OTEL_SERVICE_NAME` ⇔ `-Dotel.service.name`) のどちらにも指定が無いもの |

- `OTEL_` は OpenTelemetry 仕様が定める設定名の接頭辞です。接頭辞で判定するため、
  仕様追加で増えた設定名も列挙を更新せずに検出できます。
- 「未設定」の判定対象は `OTEL_SERVICE_NAME`、`OTEL_RESOURCE_ATTRIBUTES`、
  `OTEL_TRACES_EXPORTER`、`OTEL_METRICS_EXPORTER`、`OTEL_LOGS_EXPORTER`、
  `OTEL_EXPORTER_OTLP_ENDPOINT`、`OTEL_EXPORTER_OTLP_PROTOCOL`、`OTEL_PROPAGATORS`、
  `OTEL_TRACES_SAMPLER`、`OTEL_SDK_DISABLED` です。トレースが届かないときに
  「そもそも設定されていない」ケースを切り分けられます。
- `OTEL_EXPORTER_OTLP_HEADERS` のように認証情報を載せやすい名前の値は
  `[REDACTED]` で表示します。
- 関連する `--keep-container-mode logs` の送達診断 (OTel Collector のヘルスチェックと
  X-Ray 偽装 Jaeger のトレース確認) は
  [起動状態を維持した対話操作](#起動状態を維持した対話操作---keep-container-mode) を参照してください。

```
===================================================================
OpenTelemetry 環境変数・JVM パラメータ一覧 (サービス: app, コンテナ: app-1)
種別: OTEL_ 標準環境変数 / 関連環境変数 / JVM パラメータ (コマンドライン・環境変数由来)
===================================================================
[OpenTelemetry 標準環境変数 (OTEL_*)] 4 件
  OTEL_EXPORTER_OTLP_ENDPOINT                  = http://adot-collector:4317
  OTEL_EXPORTER_OTLP_HEADERS                   = [REDACTED]
  OTEL_SERVICE_NAME                            = orders-app
  OTEL_TRACES_EXPORTER                         = otlp
[OpenTelemetry 関連環境変数] 1 件
  JAVA_TOOL_OPTIONS                            = -javaagent:/opt/otel/opentelemetry-javaagent.jar
[OpenTelemetry 関連 JVM パラメータ (コマンドライン)] 2 件
  -javaagent                                   = /opt/otel/opentelemetry-javaagent.jar
  -Dotel.service.name                          = orders-app
[OpenTelemetry 関連 JVM パラメータ (環境変数由来)] 1 件
  JAVA_TOOL_OPTIONS: -javaagent                = /opt/otel/opentelemetry-javaagent.jar
[未設定の主要 OpenTelemetry 設定] 2 件
  OTEL_PROPAGATORS (システムプロパティ -Dotel.propagators も未設定)
  OTEL_RESOURCE_ATTRIBUTES (システムプロパティ -Dotel.resource.attributes も未設定)
```

### WAR デプロイ時の Java 例外エラー解析

JBoss EAP のデプロイ処理 (WAR の展開 → デプロイメント記述子の解析 → モジュール依存の
解決 → CDI / JPA / Servlet の初期化) で Java の例外が投げられると、そのデプロイユニットは
`failed` となり、`WFLYCTL0080` (Failed services) と `WFLYSRV0021` (rolled back) を伴って
巻き戻されます。ログにはスタックトレースがそのまま出ますが、**どの例外が根本原因で、
なぜそうなり、何を直せばよいのか**はログを読む側の知識に依存していました。

`build_and_verify.sh` は**専用オプションなしに**この解析を自動実行します。
例外を検出した場合は画面へ詳細な分析と対処提案を出力し、
全量レポートの `[10]` へ同じ内容を残し、さらに**デプロイ結果ファイルとは別に
Excel ブックと、同じ内容のテキストファイルを追加出力**します。

**コンテナの起動 (`compose up`) に失敗した実行でも解析は必ず行います。**
起動できない原因そのものがデプロイ処理中の Java 例外であることが多いため、
失敗するまでに出力されたログを対象に、成功時と同じ内容の解析結果
(画面 / `[10]` / Excel / テキスト) を出力します。デプロイ結果ファイル
(`build_and_verify_<日時>.txt`) だけが残る状態にはなりません。

#### 解析の内容

| 段階 | 内容 |
| --- | --- |
| 例外ブロックの切り出し | `at ...` のスタックフレームの並びを手掛かりに、ヘッダー行・フレーム・`Caused by:` / `Suppressed:` / `... N more` をひとまとまりとして抽出します。ログ本文とは別行に出た例外 (`APP000009: initialization failed` の次行に `java.lang.ClassNotFoundException: ...` が続く形) も、直前のログ行から発生時刻・ログレベル・ロガー・スレッドを引き継ぎます |
| 根本原因の特定 | `Caused by` の連鎖をたどり、**最終段**を根本原因として扱います。`org.jboss.msc.service.StartException` のような「入れ物」の例外に惑わされないためです |
| 発生箇所の特定 | スタックフレームのうち `java.` / `jakarta.` / `org.jboss.` などの基盤パッケージに属さない、**最初のアプリケーションフレーム**を抜き出します |
| 例外クラスの分類 | クラスロード・依存関係 / JNDI・リソース参照 / データソース・JDBC / ネットワーク接続 / TLS・証明書 / CDI (Weld) / JPA・Hibernate / MSC サービス起動 / デプロイ処理 / デプロイメント記述子 (XML) / Servlet・Web 層 / メモリ・リソース / ファイル・権限 / セキュリティ・認証情報 / アプリケーション実装 / 設定値 / タイムアウト / ネイティブライブラリ の 18 分類・72 クラスを収録しています |
| ログ固有の追加解析 | `Metaspace` / `Java heap space` / `Connection refused` / `Access denied` / `class file version` / `WELD-001408` / `unable to find valid certification path` など、メッセージ本文から具体策が言えるパターンを追加所見として付けます |
| 事実の抽出 | 見つからないクラス名、引けなかった JNDI 名、接続先ホスト:ポート、枯渇したメモリ領域、`SQLState`、クラスファイルのバージョン (`61.0` → Java 17) などをログから取り出します |
| デプロイ関連の判定 | `jboss.deployment.unit."<アーカイブ>"` の有無、`WFLYSRV0027` (Starting deployment) 以降かどうか、ロガーがデプロイヤかどうかで判定し、**判定の根拠も併記**します |

例外 1 件ごとに、次の見出しで出力します。

```
■ 何が起きたか                          … 1〜2 文で結論
■ 発生の仕組み (なぜこの例外になるのか) … JVM / JBoss EAP の内部動作
■ ログから読み取れる事実                … 見つからないクラス名・JNDI 名・接続先など
■ このログ特有の追加所見                … メッセージ本文から言える具体策
■ デプロイ処理との関連 (この判定の根拠)
■ 前後に出ている EAP メッセージ         … WFLYSRV0021 などの意味
■ 想定される原因 (可能性の高い順)
■ 確認手順                              … 実行できる docker exec / jboss-cli コマンド
■ 対処方法                              … 効果の高い順。設定ファイルの記述例つき
■ 再発防止
■ 参考情報
■ 例外の連鎖とスタックトレース
```

例外が 1 件も無い場合、画面へは
`WAR デプロイ時の Java 例外は検出されませんでした。` の 1 行だけを出します。

#### 解析対象ログの状況 (`ログ取得状況`)

解析はどの経路でも実行するため、「どこまでのログを解析できたのか」を
画面・全量レポート `[10]`・Excel の「概要」シートへ同じ文言で残します。

| 状況 | `ログ取得状況` | 総合判定 |
| --- | --- | --- |
| コンテナ起動後 (通常) | `コンテナ起動後のデプロイ処理ログを解析しました。` | 検出結果どおり |
| `compose up` に失敗 | `コンテナの起動 (compose up) に失敗したため、失敗するまでに出力されたログを解析しました。` | 検出結果どおり |
| `compose up` は試みたがログが 0 行 | `Compose サービスのログを 1 行も取得できませんでした (…)。` | `未評価 (解析対象のログが無いため判定できません)` |
| `compose up` まで未到達 (ビルド失敗 / ビルドのみ) | `コンテナ起動 (compose up) まで到達しなかったため、解析対象のログがありません (…)。` | `未評価 (解析対象のログが無いため判定できません)` |

解析対象のログが 1 行も無いときの 0 件は「例外が無かった」ことを意味しないため、
`OK` ではなく **`未評価`** として区別します。なお `compose up` まで到達していない
実行では、前回の実行が残したコンテナのログを今回の結果として解析してしまわないよう、
ログ収集そのものを行いません。

#### 出力ファイル (Excel とテキスト)

`--report-dir DIR` を指定していれば、デプロイ結果ファイル
`DIR/build_and_verify_<日時>.txt` と**同じディレクトリへ追加で**次の 2 つを出力します。
出力先は `--deploy-exception-excel FILE` / `--deploy-exception-text FILE` で
個別に明示することもできます。

| ファイル | 内容 |
| --- | --- |
| `build_and_verify_<日時>_java_exceptions.xlsx` | 下表の 6 シート構成の Excel ブック |
| `build_and_verify_<日時>_java_exceptions.txt` | **同じ内容のテキスト版**。Excel を開けない環境や、`grep` / `diff` で追跡したい場合に使う |

テキスト版は画面表示と違い、**全スタックフレーム**と**区分付きデプロイログ**まで
含むため、Excel と同じ情報量になります (画面と全量レポート `[10]` は、
スタックトレースを各段 12 フレームまでに要約します)。

| シート | 内容 |
| --- | --- |
| 概要 | 実行情報、検出サマリ (深刻度別・分類別)、総合判定、優先対応すべき例外、ブックの読み方 |
| 例外一覧 | 1 行 1 例外。判定 / 深刻度 / 分類 / デプロイ関連 / デプロイ対象 / サービス / 発生時刻 / ロガー / 例外クラス / 根本原因 / アプリ内発生点 など 21 列 |
| 原因分析 | 何が起きたか / 発生の仕組み / 想定される原因 / 読み取れる事実 / 判定根拠 / 関連 EAP メッセージ (1 項目 = 1 行) |
| 対処方法 | 確認手順 / 対処方法 / 再発防止 / 参考情報 (1 手順 = 1 行) |
| スタックトレース | 連鎖 (`Caused by`) の段ごとに全フレーム (1 フレーム = 1 行) |
| デプロイログ | 解析対象ログを区分 (デプロイ開始 / 例外 / スタックフレーム / エラー / 警告 …) 付きで時系列に |

**表示の作り**

- フォントはすべて **Meiryo UI**。
- **行高は内容と列幅から計算して行ごとに明示**しています。Excel の自動調整に頼らないため、
  開いた直後から折り返した本文が切れません。
- 長文は 1 セルへ詰め込まず、「原因分析」「対処方法」は 1 項目 = 1 行の縦持ち、
  「スタックトレース」は 1 フレーム = 1 行に展開しています。1 セルが Excel の
  行高上限 (409.5pt) を超えて末尾が読めなくなるのを避けるためです。
- 見出し行の固定・オートフィルタ・列幅・折り返し・深刻度の色分けを設定済みです。

例外が 0 件でも Excel とテキストは出力し、「概要」へ
`OK (Java 例外は検出されませんでした)` と記録します。コンテナの起動に失敗した場合や
解析対象のログが無い場合も同じ 2 ファイルを出力し、「概要」の `ログ取得状況` と
`未評価 (解析対象のログが無いため判定できません)` で理由が分かるようにします。

```bash
# デプロイ結果ファイルと Java 例外解析 (Excel + テキスト) をまとめて保存
./build_and_verify.sh --verify-startup \
    --compose-service app --startup-service app \
    --report-dir ./reports

# Excel / テキストの出力先を明示する
./build_and_verify.sh --verify-startup \
    --deploy-exception-excel ./reports/deploy-errors.xlsx \
    --deploy-exception-text ./reports/deploy-errors.txt

# 解析を行わない
./build_and_verify.sh --verify-startup --no-deploy-exception-analysis
```

#### 前提と影響範囲

- 解析には **Python 3** (`python3` / `python` / `/usr/libexec/platform-python` の
  いずれか) が必要です。Excel は Python の標準ライブラリだけで生成するため、
  `openpyxl` などの追加パッケージは不要です。Python 3 が無い場合は解析を
  スキップして `[WARN]` を出し、ビルドの成否は変えません。
- 解析は成功時は主処理の末尾、失敗時は `EXIT` の後始末で全量レポートを書く直前に
  実行します。いずれも**コンテナを削除する前**なので、起動確認に失敗した実行でも
  解析結果が残ります。
- **例外を検出しても終了コードは変わりません**。終了コードは従来どおり、
  起動確認や URL 応答確認の結果で決まります。
- `--dry-run` および起動確認を伴わないビルドのみの実行では解析しません
  (全量レポートの `[10]` へ理由を記録します)。

### CloudWatch Logs 送信検証 (cwagent)

ECS の taskdef と同じ **CloudWatch Agent サイドカー (`cwagent`)** を `compose.yml` で
起動する構成では、設定に不備があってもエージェント自体は正常に起動してしまい、
CloudWatch Logs へ 1 件も届かないまま気付かないことがよくあります。起動ログにも
明確なエラーが出ないため、`build_and_verify.sh` はビルド時のチェックとして
**設定ファイルのチェック**と**送信状況のチェック**を自動で実行します。

`compose.yml` に `cwagent` サービスが定義されていれば追加のオプション指定は不要です。
定義されていない場合は何も出力せずに読み飛ばします。

#### (A) 設定ファイルのチェック (ビルド前)

コンテナを起動する前に、`compose.yml` の `cwagent` 定義とマウントする設定 JSON を
ホスト側だけで突き合わせます。ここで `[NG]` が出た場合、起動しても
CloudWatch Logs には届きません。

| 段 | 検出する不備 |
| --- | --- |
| `compose.yml` の cwagent サービス定義 | サービスが存在しない (`--verify-cwagent` 指定時のみ NG) |
| 設定ファイルの注入 | `/etc/cwagentconfig` (または CloudWatch Agent 既定パス) へマウントする `volumes` が無い / マウント元のファイルがホストに存在しない / 名前付きボリュームを設定の注入元にしている |
| 設定ファイルの内容 | JSON の構文エラー / `logs` セクションが無い / `collect_list` が空 / `file_path`・`log_group_name` の欠落 / CloudWatch Logs の命名規則に反する `log_group_name`・`log_stream_name` |
| 送信先 (`logs.endpoint_override`) | 送信先ホストが `compose.yml` のサービス名・`container_name` のいずれとも一致しない / `localhost` を指している / `depends_on` で送信先の listen 完了を待っていない |
| 収集対象ログファイルのマウント | `collect_list` の `file_path` が `cwagent` の `volumes` に含まれていない / 同じボリュームを書き込みモードでマウントするサービスが無い |
| リージョンと認証情報 | `agent.region` も `AWS_REGION` も無い / クレデンシャルのマウント元がホストに存在しない |

**マウント元のファイルがホストに存在しない**のは特に見つけにくい不備です。存在しない
パスを bind mount すると Docker は空のディレクトリを作るため、CloudWatch Agent は
既定設定のまま正常に起動し、ログだけが送信されません。

```
===================================================================
ビルド前の設定ファイルチェック
===================================================================
  [OK] compose.yml の cwagent サービス定義
      image=public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest / AWS_REGION=ap-northeast-1
  [OK] 設定ファイルの注入 (compose.yml volumes → /etc/cwagentconfig)
      ./compose/cwagent/cwagent-config.json → /etc/cwagentconfig/cwagent-config.json:ro
  [OK] 設定ファイルの内容 (収集定義とロググループ)
      収集対象 2 件 / 送信先: /local/myapp/efs/app-front/front-local, /local/myapp/efs/app-back/back-local / force_flush_interval=5 秒
  [NG] 送信先 (logs.endpoint_override)
      endpoint_override のホスト 'cloudwatch-logs-stub' が compose.yml のサービス名・container_name のいずれとも一致しません。
      cwagent コンテナ内で名前解決できず、送信はすべて失敗します: http://cloudwatch-logs-stub:8080
  [NG] 収集対象ログファイルのマウント
      収集対象パスが cwagent にマウントされていません: /mnt/logs/app-front*.log
───────────────────────────────────────────────────────────────────
  総合判定: NG あり — 上記 [NG] の段が、CloudWatch Logs へ届かない直接の原因です。
───────────────────────────────────────────────────────────────────
```

#### (B) 送信状況のチェック (起動確認後)

起動確認 (`--verify-startup` / `--verify-url`) を伴う実行では、アプリがログを
書き終えた時点でコンテナ内の設定を照合します。実際の送達確認は
`--cwagent-delivery-report` を指定した実行だけで行います。

1. 起動した `cwagent` コンテナから設定ファイルを読み出し、ホスト側の内容と比較します。
   一致しない場合は「編集した設定が反映されていない」「マウントが効いていない」ことが
   分かります。
2. **`--cwagent-delivery-report` を指定した場合のみ**、設定済みのロググループ /
   ログストリームへログイベントが届くまで、`--cwagent-delivery-timeout` (既定 60 秒)
   まで `--cwagent-delivery-interval` (既定 5 秒) 間隔で待ち合わせ、送達レポートを
   表示します。指定しない既定の実行では、待ち合わせも送信先への問い合わせも行わず、
   「ログイベントの送達」の段に実施していないことを「情報」として記録します。
   - `logs.endpoint_override` が偽装 CloudWatch Logs (WireMock) を指す場合は、その
     request journal の `PutLogEvents` を確認し、ロググループ / ストリーム / 受信した
     ログイベント本文を表示します。
   - `endpoint_override` が無い (実 CloudWatch Logs 宛て) 場合は `aws logs` コマンドで
     ロググループの存在、ログストリームの最終イベント時刻、**今回の実行以降に届いた
     イベント**を確認します。`aws` コマンドと AWS 認証が必要です。
     設定ファイルの `log_group_name` のロググループが CloudWatch Logs に存在しない
     場合は NG となり、`--cwagent-create-log-group` を併用するとその名前で作成して
     から確認します (下記)。
3. `cwagent` 自身が出した警告・エラーログ (`E!` / `W!` / `failed` など) を最大 20 行
   抜き出して表示します。

ログイベント本文に `password` / `token` / `authorization` などの名前で値が含まれる
場合は、画面と全量レポートの双方で `[REDACTED]` に置き換えます。

`--report-dir` を指定した場合、(A) と (B) の結果は全量レポートの
`[8] CloudWatch Logs 送信検証 (cwagent)` へ保存されます。

#### ロググループの自動作成 (`--cwagent-create-log-group`)

ロググループが CloudWatch Logs に存在しないと `PutLogEvents` は
`ResourceNotFoundException` となり、`cwagent` 側に `logs:CreateLogGroup` 権限が
無ければログは 1 件も残りません。そこで確認先が実 CloudWatch Logs (`aws`) の場合、
**設定ファイルに記載されている `log_group_name` のロググループが存在しなければ、
その名前で作成できます**。AWS アカウントへ実体を残す副作用があるため
**既定では作成せず**、`--cwagent-create-log-group` を指定した実行だけで作成します。
指定が無い場合は作成せず、存在しないことを NG として報告するだけになります。

- 作成は `aws logs create-log-group` で行い、リージョンは `agent.region`
  (無ければ `--region`) を使います。`logs:CreateLogGroup` 権限が必要です。
- **コンテナ起動前**に作成するため、`cwagent` の最初の送信から取りこぼしません。
- 同じロググループを複数の `collect_list` エントリが共有する場合も作成は 1 回だけです。
- 既に存在する場合は何もしません。他の実行やエージェント自身が先に作成していた場合
  (`ResourceAlreadyExistsException`) も「既存」として扱います。
- 作成できなかった場合は NG とし、必要な権限とリージョンを表示します。
- ログストリームは `cwagent` が作成するため、スクリプトでは作成しません。
- `--dry-run` / コンテナを起動しない実行 / 確認先が偽装サービス (`mock`) の場合は
  作成しません。

```
# --cwagent-create-log-group を指定した実行
[10:12:04] CloudWatch Logs にロググループがないため、設定ファイルの名前で作成します: /local/myapp/efs/app-front (region=ap-northeast-1)
...
  [OK] ロググループの自動作成 (CloudWatch Logs)
      設定ファイルのロググループ名で作成しました (region=ap-northeast-1): /local/myapp/efs/app-front, /local/myapp/efs/app-back

# 指定しない既定の実行
[10:12:04] CloudWatch Logs のロググループ自動作成は行いません (--cwagent-create-log-group を指定すると、設定ファイルの log_group_name で作成します)。
```

#### オプション

| オプション | 説明 |
| --- | --- |
| `--verify-cwagent` | `cwagent` サービスが定義されていない場合も検証を試み、見つからなければ NG として報告する |
| `--no-verify-cwagent` | 検証を行わない |
| `--cwagent-service NAME` | CloudWatch Agent の Compose サービス名 (既定: `cwagent`) |
| `--cwagent-config-dir PATH` | コンテナ内の設定ディレクトリ (既定: `/etc/cwagentconfig`) |
| `--cwagent-delivery-target auto\|mock\|aws` | 送信状況の確認先。`auto` は `logs.endpoint_override` があれば `mock`、無ければ `aws` (既定: `auto`) |
| `--cwagent-delivery-report` | 送達を待ち合わせて送達レポートを表示する (既定では行わない) |
| `--no-cwagent-delivery-report` | 送達レポートを行わない (既定) |
| `--cwagent-delivery-timeout SEC` | 送達を待つ最大秒数。`--cwagent-delivery-report` 指定時に使う (既定: 60) |
| `--cwagent-delivery-interval SEC` | 送達確認のポーリング間隔・秒。`--cwagent-delivery-report` 指定時に使う (既定: 5) |
| `--cwagent-mock-service NAME` | 偽装 CloudWatch Logs の Compose サービス名 (未指定時は `endpoint_override` から解決) |
| `--cwagent-mock-port PORT` | 偽装 CloudWatch Logs のコンテナ側ポート (未指定時は `endpoint_override` から解決、既定 8080) |
| `--cwagent-required` | 検証で NG があった場合に終了コード 1 とする (既定は警告のみ) |
| `--cwagent-create-log-group` | 実 CloudWatch Logs 宛ての構成で、設定ファイルの `log_group_name` のロググループが存在しなければ自動作成する (既定では作成しない) |
| `--no-cwagent-create-log-group` | ロググループの自動作成を行わない (既定。存在しない場合は NG として報告するだけにする) |

既定では NG を検出しても警告のみで、ビルド結果の判定は変えません
(`--verify-jboss-password` の伝搬検証と同じ扱いです)。CI で送信不備を失敗として
扱う場合は `--cwagent-required` を指定してください。

```bash
# ビルド + 起動確認 + cwagent の設定チェック (compose.yml に cwagent があれば自動。
# 送達レポートは行わない)
./build_and_verify.sh \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app

# 送達レポートまで行い、送達待ちを 3 分へ延ばして NG をビルド失敗として扱う
./build_and_verify.sh \
    --compose-service app,cwagent,cloudwatch-logs-mock \
    --startup-service app \
    --cwagent-delivery-report \
    --cwagent-delivery-timeout 180 --cwagent-required

# 実 CloudWatch Logs のロググループへ届いたかを aws logs で確認する
# (ロググループが無ければ設定ファイルの名前で作成してから確認する)
./build_and_verify.sh \
    --compose-service app,cwagent --startup-service app \
    --cwagent-delivery-target aws \
    --cwagent-delivery-report --cwagent-create-log-group
```

起動後に `--keep-container-mode logs` で対話的に同じ送達診断を実行することもできます。
[起動状態を維持した対話操作](#起動状態を維持した対話操作---keep-container-mode) を参照してください。

### 起動状態を維持した対話操作 (`--keep-container-mode`)

`--keep-container-mode bash|http|logs` を指定すると、JBoss EAP の起動確認に成功した後も
対象コンテナを停止せず、次の操作をその場で実行できます。このオプションは
`--verify-startup` と `--keep-container` を暗黙に有効化します。bash/http モードで
検証対象コンテナが複数ある場合は、サービス名とコンテナ名を表示する番号選択
ダイアログが開きます。

- `bash`: 選択したコンテナへ `docker exec -it <container> /bin/bash` で直接接続します。
  bash を終了した後もコンテナは起動状態を維持します。対象イメージには
  `/bin/bash` が必要です。
- `http`: JBoss EAP の接続情報を解決した後、パス、HTTP メソッド、必要な POST
  ボディをダイアログで入力し、ホスト側の `curl` から 1 回リクエストします。
  HTTP ステータスコードとレスポンスボディ全体を区切り付きで表示します。
- `logs`: 現在起動している Compose サービスを番号付きで表示します。サービス選択後、
  `1` で今回の起動以降のログ表示、`2` で対象コンテナの対話式 `/bin/bash` 接続を
  選べます。`3` では Docker healthcheck の設定・実行履歴・通信内容を確認できます。
  bash セッション内では `cd` で移動しながら任意のコマンドを実行でき、
  bash 終了後は同じサービスの操作選択へ戻ります。同一サービスに複数コンテナがある場合は
  警告を表示して先頭の実行中コンテナへ接続します。ログ表示後も Enter キーで操作選択へ
  戻ります。操作選択の `0` で最新のサービス一覧へ戻り、サービス選択の `0` で終了します。
  ログ表示行数は `--startup-log-lines` (既定: 末尾 50 行) に従い、明示的に選択した
  ログは `--suppress-startup-logs` の指定中でも表示します。bash 操作を行う対象イメージには
  `/bin/bash` が必要です。

healthcheck 診断では、Docker に反映された `Config.Healthcheck` の形式、コマンド、interval、
timeout、retries、start period と、`State.Health` の現在状態、連続失敗回数、Docker が保持する
直近の実行開始・終了時刻、終了コード、stdout/stderr を表示します。続けて同じコマンドを
選択時点でコンテナ内から一度だけ手動再実行し、その終了コードと出力を表示します。手動再実行は
診断専用で、Docker の health 状態や実行履歴自体は更新しません。ホストで `timeout` を利用できる場合、
手動再実行には `--url-timeout` の時間上限（既定 60 秒）を適用します。healthcheck 未設定のサービスでも
項目 `3` は表示され、未設定であることを明示します。

`CMD ["/healthcheck"]` のように絶対パスの実行ファイルが指定されている場合は、そのファイルの
存在、権限、SHA-256 も確認します。単純な `curl` / `wget` の HTTP(S) healthcheck では、同じ
コンテナのネットワーク名前空間から補助 GET/HEAD リクエストを送り、リクエスト URL、終了コード、
レスポンスヘッダー／本文と接続メトリクスを最大 32768 bytes 表示します。ヘッダーやボディを伴う
複雑なコマンドは HTTP 補助リクエストを自動生成せず、元のコマンドの手動再実行結果だけを表示します。
認証指定や認証情報を含む URL を検出した場合は、ホストのプロセス引数への露出を避けるため手動再実行も
スキップし、Docker の実行履歴だけを表示します。表示内容にはアプリケーション情報が含まれ得るため、
画面出力とログファイルの取り扱いには注意してください。

ADOT Collector のような distroless イメージには `/bin/sh` が無く、`CMD-SHELL` 形式の
healthcheck をそのまま再実行できません。この場合は次の順にフォールバックし、
どの手段を使ったかを「実行方式」として表示します。

1. コンテナ内シェル (`/bin/sh` → `/bin/bash` → `/bin/ash` → `/busybox/sh` → `/usr/bin/sh` →
   `/usr/bin/bash`) で実行
2. シェルが無い場合、シェル構文を含まないコマンド（末尾の `|| exit N` は除去）を
   `docker exec` で直接実行
3. コンテナ内に実行ファイルやシェルが無い場合、healthcheck の URL をホストから確認
   （公開ポート優先、未公開ならコンテナ IP）
4. いずれも不可なら、`docker inspect` の `State.Health` 参照、ネットワーク名前空間を借りた
   一時コンテナからの `curl`、ホストからの `curl` など、手元で実行すべきコマンドを案内

healthcheck 実行ファイルの確認も、シェルが無い場合は `docker cp` での取り出し方法を
案内するだけに切り替えます。

`logs` モードで選択した実行中コンテナに `mysql` クライアントと `mysqld` がある場合、
`MySQL クライアントへ接続` が次の操作番号（通常は `4`）として追加されます。選択すると
コンテナ内の Unix socket 経由で対話式 `mysql` クライアントが直ちに開き、SQL クエリを
実行できます。`exit` または `\q` で終了すると、同じ Compose サービスの操作選択へ戻ります。
この方式はサービス名やイメージタグに依存せず、MySQL 8.0.42 と
MySQL 8.4 / Aurora 8.4 互換系で共通です。

接続ユーザーは `MYSQL_USER`（`root` 以外）があればそのユーザーを優先し、なければ `root` を
使います。パスワードは対応する `MYSQL_PASSWORD` または `MYSQL_ROOT_PASSWORD`、初期 DB は
`MYSQL_DATABASE` から取得し、それぞれ Docker secrets 用の `_FILE` 形式にも対応します。
パスワードを解決できない構成では安全な対話入力を求めます。解決したパスワードは Docker の
コマンドラインへ含めず、コンテナ内に権限を制限して作成した一時オプションファイルから
`mysql` へ渡し、セッション終了時に削除します。

さらに、対象のComposeサービス名に応じて次の可観測性専用操作が追加されます。MySQL 操作と
同時に利用可能な場合も番号は重複せず、専用操作を使わない通常サービスでは
`0`から`3`が表示されます。この診断は
[ProjectRubyRing/Container_Compose_file](https://github.com/ProjectRubyRing/Container_Compose_file)
のローカル可観測性構成（cwagent + WireMock、ADOT Collector + Jaeger）に合わせています。

- `cwagent` / `cloudwatch-logs-mock`: `cwagent`コンテナ内の
  `/etc/cwagentconfig/cwagent-config.json`から収集対象、ロググループ、ログストリームを
  取得します。続いて`cloudwatch-logs-mock`の公開ポートを解決し、WireMock request
  journalの`CreateLogGroup`、`CreateLogStream`、`PutLogEvents`受信数と、直近100リクエスト
  内のイベントを照合します。設定したグループ／ストリームごとの送信件数と、最新20件の
  イベント本文をコンソールへ表示します。
- `otel` / `adot-collector` / `jaeger`: Collectorのヘルスチェックとdebug exporterログから
  アプリケーションからのスパン受信を確認し、Jaeger Query APIからトレースサービスを
  番号選択します。選択サービスについて直近1時間・最大5トレースを取得し、trace ID、
  開始時刻、所要時間、サービス、スパン親子関係、リソース属性、スパン属性、イベントを
  コンソールへ表示します。参照先ComposeではOTel Collectorのサービス名は
  `adot-collector`です。`otel`も別Composeでの互換サービス名として認識します。
  Collectorのヘルスチェックは、composeサービスに設定された`healthcheck`定義を最優先で
  実行し、`/bin/sh`を持たないイメージでは「シェル無しの直接実行 → 同梱`/healthcheck`
  バイナリ → `health_check`拡張のエンドポイント (既定 13133/tcp) へホストからHTTP確認」の
  順にフォールバックします。すべて実行できない場合は、`docker inspect`で記録済みの
  health状態を表示したうえで、手元で実行すべきコマンドを案内します。

CloudWatch Logsモックは実ログストレージではなく、受信要求を成功応答するWireMockです。
したがってヘルパーの`OK`は、`cwagent`設定とrequest journal内の`PutLogEvents`送信先・
イベント本文が一致したことを表します。また、Jaeger確認はCompose内でX-Rayを代替する
Jaegerへの到達確認であり、実AWS CloudWatch LogsまたはX-Rayへの送信確認ではありません。

専用送達診断を選択した時だけ、ホスト側の`curl`とPython 3
（`python3`、Python 3の`python`、またはRHELの`/usr/libexec/platform-python`）が必要です。
認証ヘッダーは出力せず、パスワードやトークンを示す属性値は伏せ字にします。ただしログ本文や
トレースには業務データが含まれる可能性があるため、画面出力と`--log-dir`の取り扱いには
引き続き注意してください。

HTTP モードでは、`WFLYUT0021` からコンテキストルート、`WFLYUT0006` から
コンテナ側 HTTP リスナーポートを取得します。コンテキストルートが複数ある場合は
番号で選択できます。ポートは `docker port` の公開先を優先し、未公開の場合は
コンテナ IP へ直接接続します。検出できない場合の既定はコンテキストルート `/`、
ポート `8080` です。環境に応じて `--jboss-context-root` と `--jboss-http-port` で
明示的に上書きできます。入力する URL 情報はコンテキストルート以降のパスだけです。

HTTP メソッドは `GET` / `POST` の番号選択です。POST では続けて次のいずれかを選び、
ボディを 1 行で入力します。

- JSON: `Content-Type: application/json`
- form URL encoded: `Content-Type: application/x-www-form-urlencoded`

```bash
# 起動確認後、app コンテナの bash へ直接接続
./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode bash

# 起動確認後、app と db を番号選択し、ログ閲覧、bash、MySQL 操作を繰り返す
./build_and_verify.sh \
    --compose-service app,db \
    --startup-service app \
    --keep-container-mode logs

# 起動確認後、JBoss EAP へ対話式に HTTP 通信
# 例: /orders が検出された場合、入力した health は /orders/health になる
./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http

# ログから検出できない環境ではコンテキストルートとコンテナ側ポートを明示
./build_and_verify.sh \
    --compose-service app \
    --startup-service app \
    --keep-container-mode http \
    --jboss-context-root /orders \
    --jboss-http-port 8080
```

HTTP `4xx` / `5xx` も調査対象の応答としてステータスと本文を表示します。接続失敗や
タイムアウトなど `curl` 自体が失敗した場合は終了コード `1` になります。1 リクエストの
最大時間は `--url-timeout` (既定 60 秒) で変更できます。操作終了後の
コンテナは自動削除されないため、不要になったら表示される `docker compose ... down`
コマンドで停止・削除してください。`--cleanup-all-docker-data` とは併用できません。
`build_and_push.sh --build-only --log-dir` 経由で使う場合は、bash セッションの表示内容、
HTTP レスポンス、選択した Compose サービスのログもログファイルへ保存されるため、
秘密情報を画面へ出力しないでください。

### URL 応答確認 (`--verify-url`)

jbosseap サーバーの起動後、**指定した URL へ HTTP リクエストを送り、その応答
(ステータスコード / 本文) を確認**します。単独指定でもコンテナを起動して確認します
(起動ログの確認も行う場合は `--verify-startup` を併用してください)。

- 期待するステータスコードは `--expect-status` (既定 `200`) で指定します。
- `--url-content-type` で `Content-Type` ヘッダを明示指定できます。
- `--url-body-json` / `--url-body-form` で POST 等のリクエストボディを指定できます。
  `--url-body-json` は未指定時に `Content-Type: application/json`、
  `--url-body-form` は未指定時に
  `Content-Type: application/x-www-form-urlencoded` を自動設定します。
  両方の同時指定はできません。
- `--url-timeout` (既定 60 秒) 以内は `--url-interval` (既定 3 秒) ごとにリトライし、
  期待するステータスコードが得られた時点で成功とします。サーバーが応答可能になる
  までの待機 (readiness) も兼ねます。
- 応答本文の先頭を表示するので、内容を目視で確認できます。

```bash
# ビルド + 起動確認 + ヘルスチェック URL の応答確認 (200 を期待)
./build_and_verify.sh --verify-startup \
    --verify-url http://localhost:8080/health --expect-status 200

# POST で確認 / 自己署名証明書の HTTPS を許可
./build_and_verify.sh --verify-startup \
    --verify-url https://localhost:8443/api/ping \
    --url-method POST --url-insecure --expect-status 204

# JSON ボディ付き POST
./build_and_verify.sh --verify-startup \
    --verify-url http://localhost:8080/api/health/check \
    --url-method POST \
    --url-body-json '{"target":"app"}' \
    --expect-status 200

# form 形式ボディ付き POST (Content-Type を明示)
./build_and_verify.sh --verify-startup \
    --verify-url http://localhost:8080/oauth/token \
    --url-method POST \
    --url-content-type 'application/x-www-form-urlencoded; charset=UTF-8' \
    --url-body-form 'grant_type=client_credentials&scope=read' \
    --expect-status 200
```

> **補足**: 起動確認・URL 確認では `compose.yml` の定義に従ってコンテナを起動します
> (`docker compose up -d`)。`--verify-url` で指定する URL のホスト/ポートは、
> `compose.yml` のポートマッピングに合わせてください。

## AWS 認証チェック (`aws login --remote`)

`build_and_push.sh` / `buildx_build_and_push.sh` は、**スクリプト実行開始時に、
事前に `aws login --remote` による認証操作が実行されているか**を
`aws sts get-caller-identity` で確認します。

- **未認証の場合**: 認証を促す警告メッセージを表示して終了します (exit 1)。
  `aws login --remote` を実行して認証してから再実行してください。
- `--dry-run` 併用時は、未認証でも警告のみ表示してプレビューを継続します。
- `build_and_verify.sh` は通常 AWS を操作しないためチェックしませんが、
  `--jboss-password-param` (パラメータストア参照) を指定した場合のみ同じ
  チェックを行います。

## JBoss マスターパスワードの取得と BuildKit シークレット注入

compose ビルド / buildx build の前に、**JBoss のマスターパスワードを取得し、
環境変数経由の BuildKit シークレット (environment 型) として安全にビルドへ注入**
できます。シークレットはビルド中のみ `/run/secrets/<id>` にマウントされ、
**イメージのレイヤ・履歴・環境変数には残りません**。パスワードの値はスクリプトの
ログにも出力されません。

パスワードの取得元は 3 通りから選べます (いずれか 1 つを指定):

| 指定方法 | 説明 |
| --- | --- |
| `--jboss-password-param NAME` | **パラメータストアの指定キーから取得** (`aws ssm get-parameter --with-decryption`)。SecureString パラメータを推奨 |
| `--jboss-password VALUE` | **直接指定** (パラメータストアから取得しない場合)。コマンドライン (ps / シェル履歴) に平文が残るため、可能なら他の 2 方式を推奨 |
| `--jboss-password-env NAME` (単独指定) | **事前に export 済みの環境変数** `NAME` の値をそのまま使う |

取得した値は `--jboss-password-env` の環境変数 (既定: `JBOSS_MASTER_PASSWORD`) へ
export され、以下の経路でビルドに渡されます。

- **buildx 版**: `docker buildx build --secret id=<id>,env=<環境変数名>` を自動付与
  します。id は `--jboss-secret-id` (既定: `jboss_master_password`) で変更できます。
  `--secret` の引数に含まれるのは id と環境変数名のみで、値そのものは含まれません。
- **compose 版** (`build_and_push.sh` / `build_and_verify.sh`): `compose.yml` の
  environment 型シークレット定義を通じて渡します (`docker compose build` には
  シークレットを渡す CLI オプションが無いため)。本リポジトリの `compose.yml` には
  定義済みです。環境変数名を変える場合は `secrets.jboss_master_password.environment`
  と `--jboss-password-env` を一致させてください。

```yaml
# compose.yml (抜粋)
services:
  base:
    build:
      secrets:
        - jboss_master_password
secrets:
  jboss_master_password:
    environment: JBOSS_MASTER_PASSWORD
```

Dockerfile からは `RUN --mount=type=secret` で参照します:

```dockerfile
RUN --mount=type=secret,id=jboss_master_password \
    JBOSS_MASTER_PASSWORD="$(cat /run/secrets/jboss_master_password)" \
    && /opt/jboss/bin/setup-credential-store.sh "$JBOSS_MASTER_PASSWORD"
```

使用例:

```bash
# パラメータストアから取得して注入 (compose 版)
./build_and_push.sh --account-id 123456789012 \
    --jboss-password-param /j1/jboss/master-password

# パラメータストアから取得して注入 (buildx 版, シークレット id を変更)
./buildx_build_and_push.sh --account-id 123456789012 \
    --jboss-password-param /j1/jboss/master-password \
    --jboss-secret-id jboss_vault_password

# パラメータストアを使わず直接渡す
./build_and_push.sh --account-id 123456789012 \
    --jboss-password 'MyMasterPassword'

# 事前に export した環境変数から渡す (コマンドラインに平文を残さない)
export JBOSS_MASTER_PASSWORD='MyMasterPassword'
./buildx_build_and_push.sh --account-id 123456789012 \
    --jboss-password-env JBOSS_MASTER_PASSWORD

# ビルドのみ (build_and_verify.sh / --build-only 委譲) でも利用可能
./build_and_verify.sh --jboss-password-param /j1/jboss/master-password
./build_and_push.sh --build-only --jboss-password-param /j1/jboss/master-password
```

- `--jboss-password-param` と `--jboss-password` は同時に指定できません (exit 2)。
- パラメータストアの取得は、AWS 権限が必要なためスイッチバック確定後に行います。
  取得に失敗した場合 (権限不足 / パラメータ名誤り / リージョン違い) はエラー内容を
  表示して終了します。
- `--dry-run` 併用時は、パラメータストアへの実際のアクセスは行いません。

## JBoss マスターパスワードの伝搬検証 (`--verify-jboss-password`)

マスターパスワードに `$` `#` `"` `` ` `` などが含まれると、**取得元では正しいのに、
CredentialStore の作成や `standalone.xml` の生成を経る間に別の文字列へ変わってしまう**
ことがあります。`--verify-jboss-password` を指定すると、`build_and_verify.sh` が
**各段のパスワードを原本とバイト単位で突き合わせ、一致・不一致をビルド時に画面へ出力**
します。

```bash
export JBOSS_MASTER_PASSWORD='pa$w#o"r`d&x'
./build_and_verify.sh --verify-startup --verify-jboss-password
```

### 検証する段

| # | 段 | 何を確認するか |
| --- | --- | --- |
| 1 | 取得元 → 環境変数 | パラメータストア / `--jboss-password` / 事前 export の値が、`--jboss-password-env` の環境変数へ欠落なく入ったか。パラメータストア利用時は `--output json` の生値とも突き合わせ、`--output text` によるタブ・末尾空白の欠落を検出する |
| 2 | 環境変数 → `compose.yml` の secrets 定義 | `secrets.<名前>.environment` が `--jboss-password-env` と一致し、かつ **どこかのサービスの `build.secrets` から参照されている**か。名前が食い違うとビルドには空文字が渡る |
| 3 | BuildKit シークレット → `/run/secrets/<id>` | ビルド中のコンテナへ実際に届いた値。ビルド済みイメージをベースにした**プローブビルド (`--no-cache`)** でマウント内容をそのまま取り出す。最終ステージは `scratch` で、値はイメージにもレイヤにも残さない |
| 4 | `standalone.xml` のファイル上の表記 | `jboss-cli` が書き込んだ `clear-text` 属性の生の文字列 (XML 実体参照と WildFly の `$$` エスケープを含んだまま) |
| 5 | → WildFly が実行時に解釈する値 | 4 の値から XML 実体参照 (`&amp;` `&quot;` …) と WildFly の `$$` → `$` を戻した、**実際に使われる値** |
| 6 | Elytron CredentialStore | CredentialStore を**原本パスワードで実際に開けるか** (`elytron-tool.sh credential-store --aliases`)。開ければ、登録済みのマスターパスワードが原本と同一だと確認できる |
| 7 | 利用箇所の一覧 | `credential-reference` で `store` / `alias` を参照しているリソース (データソース等) の一覧 |

段 4〜7 はコンテナ内の `standalone.xml` を読むため、**`--verify-startup` または
`--verify-url` との併用が必要**です。単独指定時は段 1〜3 のみ検証し、残りは `未確認`
として記録します。

### 出力

- **一致した段**: `[一致]` と、**一致したパスワード文字列**、可視化表記、16 進ダンプ、
  バイト長を表示します。全段一致した場合は総括にも一致した文字列を再掲します。
- **一致しない段**: `[不一致]` と、**原本と「実際に設定されている文字列」の双方**を、
  可視化表記・16 進ダンプ・**最初に食い違ったバイト位置**とともに表示します。
- **エスケープ済みで一致**: ファイル上の表記と実効値が異なるだけの場合は
  `[一致 (エスケープ済み)]` とし、ファイル上の表記も併記します。
- **確認できない段**: `[未確認]` と理由 (コンテナ未起動 / ファイルが無い等)。

可視化表記では、目に見えない差分を判別できるよう空白を `<SP>`、タブを `<TAB>`、
改行を `<LF>`、CR を `<CR>`、その他の制御文字・非 ASCII バイトを `<xNN>` で示します。

```text
  [一致] (3) BuildKit シークレット → ビルド中コンテナの /run/secrets/jboss_master_password
      一致した文字列: pa$w#o"r`d&x
      16 進ダンプ   : 70 61 24 77 23 6f 22 72 60 64 26 78

  [不一致] (5) standalone.xml → WildFly が実行時に解釈する値 (利用される値)
      原本 (取得元) : pa$w#o"r`d&x
        16 進ダンプ : 70 61 24 77 23 6f 22 72 60 64 26 78
      実際に設定されている文字列: pa$w
        16 進ダンプ : 70 61 24 77
      相違位置      : 5 バイト目から相違 (原本: 23 / 実際: (ここで終端))
```

### 危険文字のリスク分析

検証の冒頭で、パスワードに含まれる文字のうち**シェル・XML・WildFly 式のいずれかで
意味を持つもの**だけを、壊れ方とともに列挙します。

| 文字 | 主なリスク |
| --- | --- |
| `$` | シェルの変数展開 (二重引用符内でも展開)。WildFly は `${...}` を式として解決するため、リテラルの `$` は `$$` へのエスケープが必要 |
| `` ` `` | シェルのコマンド置換 (二重引用符内でも実行される) |
| `"` `'` | シェル・`jboss-cli` の引用終端。XML 属性値では `&quot;` / `&apos;` が必要 |
| `#` | 引用しないとシェルのコメント開始。`jboss-cli` スクリプトと properties ファイルでも行コメント |
| `\` | シェル・`jboss-cli`・properties のエスケープ文字。多段解釈で個数が変わる |
| `&` `<` `>` | XML の実体参照が必要。引用漏れ時はシェルのリダイレクト・バックグラウンド実行 |
| `,` `=` `:` `(` `)` | `jboss-cli` の操作構文 `op(name=value,...)` の区切り |
| 空白 / タブ / CR / LF | 引数分割、`--output text` での欠落、コマンド置換での末尾改行落ち、CRLF 混入 |
| 非 ASCII | ホストとコンテナの文字エンコーディング差 |

### `$` のエスケープ漏れの検出

`standalone.xml` の `clear-text` に未解決の `${...}` が残っており、かつ原本に `$` が
含まれる場合は `[不一致 (式が未解決)]` として報告します。WildFly は起動時にこの式を
システムプロパティ / 環境変数として解決するため、**ファイル上の文字列がそのまま
使われることはありません**。`jboss-cli` への登録時に `$` を `$$` へエスケープしてください。

```
pa$word  →  clear-text="pa$$word"
```

### 注意

- 既定では**パスワードを平文で画面と全量レポートへ出力**します。共有端末や CI ログへ
  残したくない場合は `--jboss-password-mask` を併用してください (判定・バイト長・
  16 進ダンプは残ります)。
- 不一致を検出しても**終了コードは変わりません** (ビルド成否の判定は従来どおり)。
  画面には `[WARN]` を出し、全量レポートの `[7]` にも記録します。
- CredentialStore は鍵ストアのため、**登録済みのパスワード文字列そのものは取り出せません**。
  段 6 は「原本で開けるか」による確認で、実際の文字列は段 4・5 の表示で確認します。
- `compose.yml` のシークレット名が `--jboss-secret-id` (既定 `jboss_master_password`) と
  異なる場合は、段 2 の補足で警告します。Dockerfile は
  `/run/secrets/<compose のシークレット名>` を参照するため、段 3 のプローブが実際とは
  違うマウント先を見ないよう、表示された名前を `--jboss-secret-id` に指定してください。
- `--dry-run` 併用時は、実際の値を取得しないため検証を行いません。

## push 失敗時の原因診断 / 調査ガイド

`docker push` が失敗した場合、スクリプトは自動的に以下を行います。

1. **AWS API の応答を確認**
   - `aws sts get-caller-identity` … どの IAM プリンシパルとして実行しているか
   - `aws ecr describe-repositories` … プッシュ先リポジトリが実在するか
2. **`docker push` の出力を解析**し、該当する原因カテゴリを推定
3. 各原因について、**詳細な説明 + 具体的な AWS CLI 調査コマンド + AWS コンソールの確認箇所**を表示

判定・ガイドする原因カテゴリ:

| カテゴリ | 主な兆候 | ガイド内容 |
| --- | --- | --- |
| **A. IAM 権限エラー** | `denied` / `not authorized to perform` / `ecr:*` | 必要な ECR アクション一覧、`iam simulate-principal-policy`、CloudTrail での AccessDenied 追跡 |
| **B. ECR エンドポイント権限設定エラー** | `denied` (IAM は正常でも発生) | リポジトリポリシー / VPC エンドポイントポリシーの確認 (`get-repository-policy`, `describe-vpc-endpoints`) |
| **C. ECR エンドポイント不存在疑い** | `no such host` / `timeout` / `dial tcp` | ecr.api / ecr.dkr / s3 の VPC エンドポイント有無・PrivateDNS・ルート・SG(443) の確認 |
| **D. ECR リポジトリが存在しない** | `name unknown` / `does not exist` | `describe-repositories` での一覧確認、リージョン取り違え、`create-repository` |
| **E. 認証トークン期限切れ** | `token has expired` / `401 Unauthorized` | `get-login-password | docker login` での再ログイン |

パターンに一致しない場合は、上記すべての観点を切り分け用チェックリストとして表示します。

## スイッチバックについて

このステージでは CodeCommit の操作は不要で、ECR の操作権限のみが必要です。
現在の操作権限で ECR を操作できない場合の挙動を 2 通りから選べます。

- **(A) 既定 (`--warn-only`)**: スイッチバックを促す警告を出して終了 (exit 1)
- **(B) (`--auto-switchback`)**: 別チーム提供のスイッチバック用シェルを `source` で呼び出し、
  自動的にスイッチバックしてから処理を継続する

スイッチバック用シェルの配置場所は `--switchback-shell` で指定します。
