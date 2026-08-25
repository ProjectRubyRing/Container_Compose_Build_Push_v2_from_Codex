# パラメータ チートシート

3 つのシェルスクリプトが**指定できるパラメータだけ**を、スクリプトごとに表へまとめたものです。
説明は 1 行に切り詰めてあります。動作の背景・組み合わせ・出力例は各ガイドを参照してください。

| スクリプト | 役割 | 詳細ガイド |
| --- | --- | --- |
| [`build_and_verify.sh`](#build_and_verifysh) | ビルド + 起動確認・URL 確認・各種診断 (ECR へは触れない) | [build_and_verify_guide.md](build_and_verify_guide.md) |
| [`build_and_push.sh`](#build_and_pushsh) | `docker compose build` → ECR へタグ付け・プッシュ | [build_and_push_guide.md](build_and_push_guide.md) |
| [`buildx_build_and_push.sh`](#buildx_build_and_pushsh) | `docker buildx build` → ECR へタグ付け・プッシュ | [buildx_build_and_push_guide.md](buildx_build_and_push_guide.md) |

表の見かた

- **値** … `フラグ` は値を取らないオプション。`(繰り返し可)` は同じオプションを複数回書けるもの。
- **既定** … 指定しなかったときの値。`—` は「打ち消し用のフラグで既定値を持たない」もの。
- `-h` / `--help` はどのスクリプトでも使え、ヘルプを表示して `exit 0` します。

---

## `build_and_verify.sh`

### ビルド関連

> 取り込み検証 (`--verify-copy-artifact`) は**既定では行いません**。`--copy-artifact-path` / `--copy-artifact-search-dir` / `--copy-artifact-required` のいずれかを指定した場合も有効になります。

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--local-image NAME` | イメージ名 | `j1/base.local` | compose build で生成されるローカルイメージ名 |
| `--compose-file FILE` | ファイルパス | `compose.yml` | compose 定義ファイル |
| `--compose-service NAME` | サービス名<br>(繰り返し / カンマ区切り) | (全サービス) | ビルド・起動対象。複数指定時は `base` を先行ビルド |
| `--base-context DIR` | ディレクトリパス | (compose の値) | サービス名に `base` を含むサービスの `build.context` を上書き |
| `--base-dockerfile FILE` | Dockerfile 名 | (compose の値) | 同じ対象サービスの `build.dockerfile` を上書き |
| `--frontend-context DIR` | ディレクトリパス | (compose の値) | サービス名に `frontend` を含むサービスの `build.context` を上書き |
| `--frontend-dockerfile FILE` | Dockerfile 名 | (compose の値) | 同じ対象サービスの `build.dockerfile` を上書き |
| `--backend-context DIR` | ディレクトリパス | (compose の値) | サービス名に `backend` を含むサービスの `build.context` を上書き |
| `--backend-dockerfile FILE` | Dockerfile 名 | (compose の値) | 同じ対象サービスの `build.dockerfile` を上書き |
| `--no-cache` | フラグ | `false` | キャッシュを破棄してビルド |
| `--keep-service NAME` | サービス名<br>(繰り返し / カンマ区切り) | (なし) | 指定したサービスを `--no-cache` の対象から外し、後始末でイメージと名前付きボリュームを残す |
| `--build-progress-interval SEC` | 0 以上の整数 (秒) | `30` | ビルド中に経過時間・BuildKit のフェーズ・data root の空き容量の増減を表示する間隔 |
| `--build-stall-timeout SEC` | 0 以上の整数 (秒) | `300` | ビルド出力がこの秒数途切れたら停滞と判断し、原因の切り分け診断を表示する |
| `--build-timeout SEC` | 0 以上の整数 (秒) | `0` (無制限) | ビルド全体の上限秒数 |
| `--no-build-watchdog` | フラグ | `false` | 上記の監視をすべて行わない |
| `--dry-run` | フラグ | `false` | ビルド/起動/URL 呼び出し/ファイル操作を行わずプレビュー |
| `--copy-file SRC:DEST_DIR` | `コピー元:コピー先ディレクトリ`<br>(繰り返し可) | (なし) | ビルド前にコピーし、終了後に自動削除 |
| `--copy-file-no-overwrite` | フラグ | `false` | `--copy-file` のコピー先に同名ファイルがあれば上書きせず中止 (`exit 1`) |
| `--verify-copy-artifact` | フラグ | `false` | コピーしたファイルの取り込み検証を行う |
| `--no-verify-copy-artifact` | フラグ | — | 取り込み検証を行わない (既定と同じ)。`--copy-artifact-*` とは排他 |
| `--copy-artifact-path PATH` | コンテナ内の絶対パス<br>(繰り返し可) | (自動探索) | 照合するコンテナ内パスを明示指定 (シェルの無いコンテナでも `docker cp` で照合)。指定すると検証が有効になる |
| `--copy-artifact-search-dir DIR` | コンテナ内の絶対パス<br>(繰り返し可) | `/` | コンテナ内の探索起点を絞る。指定すると検証が有効になる |
| `--copy-artifact-required` | フラグ | `false` | コンテナ内に見つからない場合もエラーとする (既定は警告のみ)。指定すると検証が有効になる |

### JBoss マスターパスワード (BuildKit シークレット)

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--jboss-password-param NAME` | SSM パラメータ名 | (なし) | パラメータストアから取得 |
| `--jboss-password VALUE` | パスワード文字列 | (なし) | 直接指定 |
| `--jboss-password-env NAME` | 環境変数名 | `JBOSS_MASTER_PASSWORD` | 受け渡しに使う環境変数名 |
| `--jboss-secret-id ID` | シークレット id | `jboss_master_password` | `compose.yml` の secrets 名 / Dockerfile の `RUN --mount=type=secret,id=...` と一致させる |
| `--region REGION` | AWS リージョン名 | `ap-northeast-1` (env `AWS_REGION`) | パラメータストア参照時のリージョン |

### CA 証明書 (BuildKit シークレット)

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--cacert-dir DIR` | ディレクトリのパス<br>(繰り返し可) | (なし) | `cacert.crt` を置いたディレクトリ |
| `--cacert-secret-id ID` | 英数字と `. _ -` | `cacerts` | シークレット id |
| `--cacert-bundle PATH` | tar のパス | 一時ファイル | 生成する tar の出力先 |
| `--cacert-bundle-env NAME` | 環境変数名 | `CACERT_BUNDLE_FILE` | tar のパスを compose へ渡す環境変数名 |
| `--cacert-glob PATTERN` | glob パターン<br>(繰り返し可) | `*.crt` と `*.pem` | 各ディレクトリから取り込むファイルのパターン |

### マスターパスワードの伝搬検証

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--verify-jboss-password` | フラグ | `false` | 取得元から実行時に利用される値までの各段で、パスワードが一致するかを検証して出力する |
| `--jboss-password-mask` | フラグ | `false` | 検証出力のパスワード文字列を伏字にする (判定・バイト長・16 進ダンプは表示) |
| `--jboss-config-file PATH` | コンテナ内の絶対パス | (自動探索) | 比較対象の `standalone.xml` |
| `--jboss-cli-path PATH` | コンテナ内の絶対パス | (自動探索) | `jboss-cli.sh` |
| `--jboss-elytron-tool PATH` | コンテナ内の絶対パス | (自動探索) | `elytron-tool.sh` |
| `--jboss-credential-store PATH` | コンテナ内の絶対パス | (`standalone.xml` から特定) | CredentialStore ファイル |

### CloudWatch Agent (cwagent) のログ送信検証

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--verify-cwagent` | フラグ | `auto` | `cwagent` サービスが未定義でも検証し、見つからなければ NG とする |
| `--no-verify-cwagent` | フラグ | — | 検証を行わない |
| `--cwagent-service NAME` | サービス名 | `cwagent` | CloudWatch Agent の Compose サービス名 |
| `--cwagent-config-dir PATH` | コンテナ内の絶対パス | `/etc/cwagentconfig` | 設定ファイルの注入先ディレクトリ |
| `--cwagent-delivery-target auto\|mock\|aws` | 列挙 | `auto` | 送達確認先 |
| `--cwagent-delivery-report` | フラグ | `false` | 送達を待ち合わせて送達レポートを表示する (既定では行わない) |
| `--no-cwagent-delivery-report` | フラグ | — | 送達レポートを行わない (既定) |
| `--cwagent-delivery-timeout SEC` | 1 以上の整数 | `60` | 送達を待つ最大秒数 (`--cwagent-delivery-report` 指定時に使用) |
| `--cwagent-delivery-interval SEC` | 1 以上の整数 | `5` | 送達確認のポーリング間隔 (`--cwagent-delivery-report` 指定時に使用) |
| `--cwagent-mock-service NAME` | サービス名 | (`endpoint_override` から解決) | 偽装 CloudWatch Logs の Compose サービス名 |
| `--cwagent-mock-port PORT` | 1〜65535 | (`endpoint_override` から解決、既定 8080) | 偽装 CloudWatch Logs のコンテナ側ポート |
| `--cwagent-required` | フラグ | `false` | 検証 NG を終了コード 1 として扱う |
| `--cwagent-create-log-group` | フラグ | `false` | 実 CloudWatch Logs 宛ての構成で、設定ファイルの `log_group_name` のロググループが存在しなければ自動作成する (既定では作成しない) |
| `--no-cwagent-create-log-group` | フラグ | — | ロググループの自動作成を行わない (既定) |

### 起動確認 (JBoss EAP / WildFly)

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--verify-startup` | フラグ | `false` | ビルド後にコンテナを起動し、起動完了をログから確認 |
| `--startup-service NAME` | サービス名<br>(繰り返し可) | (対象全体) | 起動完了チェックの対象 (指定すると `--verify-startup` を暗黙に有効化) |
| `--startup-log-pattern P` | 拡張正規表現 | `WFLYSRV0025:` | 起動完了とみなすログのパターン |
| `--startup-timeout SEC` | 1 以上の整数 | `120` | 起動完了を待つ最大秒数 |
| `--startup-interval SEC` | 1 以上の整数 | `3` | ポーリング間隔 |
| `--startup-log-lines N\|all` | 1 以上の整数または `all` | `50` | 表示するログ行数 (末尾 N 行 / 全行) |
| `--wait-healthy` | フラグ | `false` | `compose up` に `--wait` を付け、healthy になるまで compose 側で待つ |
| `--wait-timeout SEC` | 1 以上の整数 | `600` | `--wait` の最大待機秒数 (指定すると `--wait-healthy` を暗黙に有効化) |
| `--allow-service-exit NAME` | サービス名<br>(繰り返し可) | (なし) | 起動確認中に停止していても失敗扱いにしないサービス |
| `--no-pull-images` | フラグ | `false` | `compose up` の前に行うイメージの事前取得 (`compose pull`) を行わない |
| `--pull-retry N` | 0 以上の整数 | `2` | 事前取得が一過性のエラーで失敗したときの再試行回数 |
| `--pull-retry-interval SEC` | 0 以上の整数 | `10` | 事前取得の再試行間隔 |
| `--up-retry N` | 0 以上の整数 | `1` | `compose up` が一過性の理由で失敗したときの再試行回数 |
| `--no-up-retry` | フラグ | `false` | `compose up` の再試行を行わない (`--up-retry 0` と同じ) |
| `--up-retry-interval SEC` | 0 以上の整数 | `15` | `compose up` の再試行間隔 |
| `--recreate-containers` | フラグ | `false` | 前回の実行が残したコンテナを、状態にかかわらず `--force-recreate` で作り直す |
| `--no-recreate-containers` | フラグ | `false` | 前回の実行が残したコンテナの点検と作り直しを行わない (従来の動作) |
| `--suppress-startup-logs` | フラグ | `false` | 起動ログの表示を抑制 (判定は継続。失敗時は表示される) |
| `--shutdown-timeout SEC` | 1 以上の整数 | `30` | エラー終了時の SIGTERM から SIGKILL までの猶予秒数 (ECS の StopTimeout 既定と同じ) |
| `--no-shutdown-logs` | フラグ | `false` | エラー終了時の SIGTERM 停止と終了ログ取得を行わない |
| `--suppress-removed-logs` | フラグ | `false` | `compose down` / `compose stop` の `Removed` 等の出力を抑制 |
| `--keep-container` | フラグ | `false` | 確認後もコンテナを停止・削除しない |

### URL 応答確認

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--verify-url URL` | URL | (なし) | 起動確認後にこの URL へリクエストして応答を確認 |
| `--expect-status CODE` | HTTP ステータスコード | `200` | 期待するステータスコード |
| `--url-method METHOD` | HTTP メソッド | `GET` | リクエストメソッド |
| `--url-content-type TYPE` | MIME タイプ | (自動) | `Content-Type` ヘッダ (`--verify-url` と併用必須) |
| `--url-body-json JSON` | JSON 文字列 | (なし) | リクエストボディ (未指定時は `application/json` を自動設定) |
| `--url-body-form DATA` | `key=value&...` | (なし) | リクエストボディ (未指定時は `application/x-www-form-urlencoded` を自動設定) |
| `--url-timeout SEC` | 1 以上の整数 | `60` | 期待応答を得るまでの最大秒数 |
| `--url-interval SEC` | 1 以上の整数 | `3` | リトライ間隔 |
| `--url-insecure` | フラグ | `false` | TLS 証明書検証を無効化 (`curl -k`) |

### 起動維持後の対話操作

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--keep-container-mode MODE` | `bash` / `http` / `logs` | (なし) | 起動確認後の対話操作。`--verify-startup` と `--keep-container` を暗黙に有効化 |
| `--jboss-context-root ROOT` | コンテキストルートのパス | (ログから検出) | `http` モード専用。コンテキストルート (URL 全体は指定不可) |
| `--jboss-http-port PORT` | 1〜65535 | (ログから検出。既定 8080) | `http` モード専用。コンテナ側の HTTP ポート |
| `--exit-on-deploy-error` | フラグ | `false` | デプロイエラーを検出しても調査用の対話操作へ入らず、従来どおり終了する |
| `--keep-container-after-interaction` | フラグ | `false` | 対話操作をすべて終えても完全クリーンアップを行わず、従来どおりコンテナを残す |
| `--remove-volumes` | フラグ | `false` | この実行が行うすべての `compose down` に `--volumes` を付ける |
| `--keep-volumes` | フラグ | `false` | 対話操作の終了後の後始末でもボリュームを削除しない (従来の動作) |
| `--usage-check-script PATH` | ファイルパス | (自動解決) | 完全クリアに使う `docker-usage-check.sh` のパス |
| `--disk-free-path DIR` | ディレクトリ | (既定の 7 か所) | 終了時の空き容量一覧へ表示するディレクトリを追加 (繰り返し指定可) |

### 情報表示・レポート

> Java 例外解析の Excel / テキストは、`--deploy-exception-excel` / `--deploy-exception-text` を指定したときだけ出力します (`--report-dir` だけでは出力しません)。

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--env-list-limit N\|all` | 1 以上の整数または `all` | `all` | 環境変数一覧の表示件数 (コンテナごと) |
| `--env-list-file FILE` | ファイルパス | (なし) | 環境変数一覧をファイルにも出力 |
| `--directory-tree` | フラグ | `false` (非表示) | コンテナ内ツリーと JBoss EAP デプロイ構造を画面へ表示する |
| `--no-directory-tree` | フラグ | `false` | ツリーの画面表示を行わない (深さ等の指定による自動有効化も打ち消す) |
| `--directory-tree-report` | フラグ | `false` (非出力) | 全量レポートの `[3]` `[4]` へツリーとデプロイ構造を出力する (`--report-dir` と併用) |
| `--no-directory-tree-report` | フラグ | `true` (既定) | 全量レポートへツリーとデプロイ構造を出力しない |
| `--directory-tree-depth N\|all` | 1 以上の整数または `all` | `all` | ツリーの最大深さ (指定すると画面表示を自動で有効化) |
| `--directory-file-limit N\|all` | 1 以上の整数または `all` | (ファイル非表示) | 通常ファイルも表示する (N 件超過時は拡張子別の件数)。指定すると画面表示を自動で有効化 |
| `--deployment-dir-env NAME` | 環境変数名<br>(繰り返し可) | (なし) | ディレクトリパスを値に持つ環境変数。その配下を階層表示 (画面表示を自動で有効化) |
| `--report-dir DIR` | ディレクトリパス | (なし) | 全量レポートを `DIR/build_and_verify_<日時>.txt` へ保存 (読み取り専用 FS 分析の Excel / テキストも同じ場所へ) |
| `--deploy-exception-display` | フラグ | `false` (非表示) | WAR デプロイ時 Java 例外解析の結果を画面へ表示する |
| `--no-deploy-exception-display` | フラグ | — | 画面表示を行わない (既定と同じ) |
| `--deploy-exception-excel FILE` | `.xlsx` のパス | (なし) | Java 例外解析の Excel 出力先。**指定したときだけ出力**する |
| `--deploy-exception-text FILE` | ファイルパス | (なし) | Java 例外解析のテキスト出力先。**指定したときだけ出力**する |
| `--deploy-exception-limit N` | 1 以上の整数 | `50` | 詳細分析を行う例外の最大件数 |
| `--no-deploy-exception-analysis` | フラグ | `false` | Java 例外の解析とファイル出力を行わない |
| `--readonly-analysis-excel FILE` | `.xlsx` のパス | (なし) | 読み取り専用ファイルシステム分析の Excel 出力先 |
| `--readonly-analysis-text FILE` | ファイルパス | (なし) | 同じ内容のテキスト出力先。`--no-readonly-analysis` とは排他 |
| `--no-readonly-analysis` | フラグ | `false` | 読み取り専用ファイルシステムの書き込み先分析とファイル出力を行わない |
| `--undertow-host-header NAME` | ホスト名 (カンマ区切りも可)<br>(繰り返し可) | (なし) | Undertow バーチャルホスト分析で振り分けを判定する `Host` ヘッダー名を追加する |
| `--undertow-probe-path PATH` | `/` で始まるパス | (`WFLYUT0021` から検出) | `Host` ヘッダーを差し替えた実リクエストの送信先パス |
| `--no-undertow-probe` | フラグ | `false` | 実リクエストを送らず、`standalone.xml` の解析だけで判定する |
| `--undertow-analysis-text FILE` | ファイルパス | (なし) | Undertow バーチャルホスト分析のテキスト出力先 (内容は画面表示と同一) |
| `--no-undertow-analysis-display` | フラグ | `false` | 画面出力だけを抑制する |
| `--no-undertow-analysis-text` | フラグ | `false` | テキスト出力だけを抑制する |
| `--no-undertow-analysis` | フラグ | `false` | Undertow バーチャルホスト (`default-host`) の分析と出力を一切行わない |
| `--cert-check-text FILE` | ファイルパス | (なし) | 証明書チェック (`--keep-container-mode logs` の操作) の結果テキストの出力先 |
| `--no-cert-check-text` | フラグ | `false` | 証明書チェック結果のテキスト出力を行わない (画面表示だけにする) |
| `--jboss-module-list-text FILE` | ファイルパス | (なし) | JBoss モジュール一覧 (`--keep-container-mode logs` の操作) の結果テキストの出力先 |
| `--no-jboss-module-list-text` | フラグ | `false` | JBoss モジュール一覧のテキスト出力を行わない (画面表示だけにする) |

### 終了時のクリーンアップ

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--cleanup-all-docker-data` | フラグ | `false` | 終了時に確認フレーズ入力のうえ Docker context の全データを削除 (`--keep-container` とは排他) |

### ディスク使用量の抑制

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--no-reclaim-old-image` | フラグ | `false` | 旧世代イメージの回収を行わない (従来どおり残す) |
| `--prune-build-cache` | フラグ | `false` | 終了時に `docker builder prune --all --force` を実行 |
| `--prune-build-cache-keep SIZE` | サイズ (`10GB` / `512MB`) | (なし) | 終了時に `docker builder prune --keep-storage SIZE` を実行 (`--prune-build-cache` も暗黙に有効化) |
| `--disk-usage-report` | フラグ | `false` | ビルド前と終了時に Docker 管理対象の使用量を測定し、実行前からの増減を表示 (削除は行わない) |

### その他

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `-h`, `--help` | フラグ | — | ヘルプを表示して `exit 0` |

---

## `build_and_push.sh`

> `--build-only` を付けると ECR 関連処理を行わず `build_and_verify.sh` へ委譲します。
> このとき **`build_and_verify.sh` のオプションもそのまま指定できます** (`--verify-startup` /
> `--report-dir` / `--keep-container-mode` など)。ECR 専用オプション
> (`--account-id` / `--registry` / `--repository` / `--tag-prefix` / `--container-name` /
> `--output` / `--switchback-shell` / `--auto-switchback` / `--warn-only`) は警告のうえ除去されます。

### ECR 接続先の指定

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--account-id ID` | 12 桁の AWS アカウント ID | env `AWS_ACCOUNT_ID` | レジストリ URL の組み立てに使用 |
| `--region REGION` | AWS リージョン名 | `ap-northeast-1` (env `AWS_REGION` → `AWS_DEFAULT_REGION`) | ECR / SSM の対象リージョン |
| `--registry URL` | `<account>.dkr.ecr.<region>.amazonaws.com` | env `ECR_REGISTRY` (未指定なら自動組み立て) | レジストリを直接指定する (末尾 `/` は自動除去) |
| `--repository NAME` | 小文字英数字と `. _ - /` | `baseimage` | ECR リポジトリ名 = プッシュするイメージ名。**大文字は使用不可** |
| `--tag-prefix PREFIX` | 英数字と `. _ -` (先頭は英数字か `_`、113 文字以内) | `BaseImage` | タグは `<PREFIX>-<YYYYMMDDHHMMSS>` になる (大文字も可) |

### ビルドと出力

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--local-image NAME` | イメージ名 | `j1/base.local` | compose build で生成されるローカルイメージ名 |
| `--compose-file FILE` | ファイルパス | `compose.yml` | compose 定義ファイル |
| `--compose-service NAME` | サービス名 | (全サービス) | 指定時はそのサービスのみビルド |
| `--no-cache` | フラグ | `false` | キャッシュを破棄してビルド |
| `--build-progress-interval SEC` | 0 以上の整数 (秒) | `30` | ビルド中に経過時間・BuildKit のフェーズ・data root の空き容量の増減を表示する間隔 |
| `--build-stall-timeout SEC` | 0 以上の整数 (秒) | `300` | ビルド出力がこの秒数途切れたら停滞と判断し、原因の切り分け診断を表示する |
| `--build-timeout SEC` | 0 以上の整数 (秒) | `0` (無制限) | ビルド全体の上限秒数 |
| `--no-build-watchdog` | フラグ | `false` | 上記の監視をすべて行わない |
| `--container-name NAME` | 任意の文字列 | `--repository` の値 | `imagedefinition.json` の `name` |
| `--output FILE` | ファイルパス | `imagedefinition.json` | imagedefinition の出力先 |

### 実行制御・ログ

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--dry-run` | フラグ | `false` | ビルド/ログイン/タグ付け/プッシュ/ファイル出力を行わず、実行内容のみ表示 |
| `--build-only` | フラグ | `false` | ビルドのみ実行 (`build_and_verify.sh` へ委譲)。ECR 関連処理は行わない |
| `--log-dir DIR` | ディレクトリパス | (なし) | 画面出力を `DIR/build_and_push_<日時>.log` にも保存 |
| `-h`, `--help` | フラグ | — | ヘルプを表示して `exit 0` |

### ビルド前後の一時ファイル

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--copy-file SRC:DEST_DIR` | `コピー元:コピー先ディレクトリ`<br>(繰り返し可) | (なし) | ビルド前にコピーし、終了後 (成功・失敗を問わず) 自動削除 |

### JBoss マスターパスワード (BuildKit シークレット)

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--jboss-password-param NAME` | SSM パラメータ名 | (なし) | パラメータストアから取得 (`--with-decryption`) |
| `--jboss-password VALUE` | パスワード文字列 | (なし) | 直接指定 |
| `--jboss-password-env NAME` | 環境変数名 | `JBOSS_MASTER_PASSWORD` | 受け渡しに使う環境変数名 |

### スイッチバック

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--switchback-shell PATH` | シェルスクリプトのパス | env `SWITCHBACK_SHELL` | 別チーム提供のスイッチバック用シェル (`source` で読み込む) |
| `--auto-switchback` | フラグ | `false` | ECR 権限が無い場合に自動でスイッチバックして継続 |
| `--warn-only` | フラグ | **既定** | ECR 権限が無い場合に警告して終了 |

### CA 証明書 (BuildKit シークレット)

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--cacert-dir DIR` | ディレクトリのパス<br>(繰り返し可) | (なし) | `cacert.crt` を置いたディレクトリ |
| `--cacert-secret-id ID` | 英数字と `. _ -` | `cacerts` | シークレット id |
| `--cacert-bundle PATH` | tar のパス | 一時ファイル | 生成する tar の出力先 |
| `--cacert-bundle-env NAME` | 環境変数名 | `CACERT_BUNDLE_FILE` | tar のパスを compose へ渡す環境変数名 |
| `--cacert-glob PATTERN` | glob パターン<br>(繰り返し可) | `*.crt` と `*.pem` | 各ディレクトリから取り込むファイルのパターン |

---

## `buildx_build_and_push.sh`

### ECR 接続先の指定

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--account-id ID` | 12 桁の AWS アカウント ID | env `AWS_ACCOUNT_ID` | レジストリ URL の組み立てに使用 |
| `--region REGION` | AWS リージョン名 | `ap-northeast-1` (env `AWS_REGION` → `AWS_DEFAULT_REGION`) | ECR / SSM の対象リージョン |
| `--registry URL` | `<account>.dkr.ecr.<region>.amazonaws.com` | env `ECR_REGISTRY` | レジストリを直接指定する (末尾 `/` は自動除去) |
| `--repository NAME` | 小文字英数字と `. _ - /` | `baseimage` | ECR リポジトリ名。**大文字は使用不可** |
| `--tag-prefix PREFIX` | 英数字と `. _ -` (先頭は英数字か `_`、113 文字以内) | `BaseImage` | タグは `<PREFIX>-<YYYYMMDDHHMMSS>` になる (大文字も可) |

### buildx ビルド関連 (このスクリプト固有)

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--local-image NAME` | イメージ名 | `j1/base.local` | `-t` に渡すローカルイメージ名 |
| `--dockerfile FILE` | ファイルパス | `Dockerfile` | `-f` に渡す Dockerfile |
| `--context DIR` | ディレクトリパス | `.` | ビルドコンテキスト |
| `--platform PLATFORM` | 例: `linux/amd64` | (なし) | `--load` のため**単一プラットフォームのみ** (`,` 区切りは `exit 2`) |
| `--builder NAME` | buildx ビルダー名 | (現在のビルダー) | 使用するビルダーを切り替える |
| `--build-arg KEY=VALUE` | `KEY=VALUE`<br>(繰り返し可) | (なし) | ビルド引数 |
| `--build-context NAME=VALUE` | `NAME=VALUE`<br>(繰り返し可) | (なし) | 追加のビルドコンテキスト |
| `--secret SPEC` | buildx の `--secret` と同一書式<br>(繰り返し可) | (なし) | 例: `id=npmrc,src=./.npmrc` / `id=token,env=GITHUB_TOKEN` |
| `--progress MODE` | `auto`/`plain`/`tty`/`rawjson`/`quiet` | (buildx 既定) | buildx の進捗表示形式 (CI ログには `plain` が読みやすい) |
| `--no-cache` | フラグ | `false` | キャッシュを破棄してビルド |
| `--build-progress-interval SEC` | 0 以上の整数 (秒) | `30` | ビルド中に経過時間・BuildKit のフェーズ・data root の空き容量の増減を表示する間隔 |
| `--build-stall-timeout SEC` | 0 以上の整数 (秒) | `300` | ビルド出力がこの秒数途切れたら停滞と判断し、原因の切り分け診断を表示する |
| `--build-timeout SEC` | 0 以上の整数 (秒) | `0` (無制限) | ビルド全体の上限秒数 |
| `--no-build-watchdog` | フラグ | `false` | 上記の監視をすべて行わない |

### 出力・実行制御

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--container-name NAME` | 任意の文字列 | `--repository` の値 | `imagedefinition.json` の `name` |
| `--output FILE` | ファイルパス | `imagedefinition.json` | imagedefinition の出力先 |
| `--log-dir DIR` | ディレクトリパス | (なし) | 画面出力を `DIR/buildx_build_and_push_<日時>.log` にも保存 |
| `--dry-run` | フラグ | `false` | ビルド/ログイン/タグ付け/プッシュ/ファイル出力を行わずプレビュー |
| `-h`, `--help` | フラグ | — | ヘルプを表示して `exit 0` |

### ビルド前後の一時ファイル

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--copy-file SRC:DEST_DIR` | `コピー元:コピー先ディレクトリ`<br>(繰り返し可) | (なし) | ビルド前にコピーし、終了後に自動削除 |

### JBoss マスターパスワード (BuildKit シークレット)

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--jboss-password-param NAME` | SSM パラメータ名 | (なし) | パラメータストアから取得 (`--with-decryption`) |
| `--jboss-password VALUE` | パスワード文字列 | (なし) | 直接指定 |
| `--jboss-password-env NAME` | 環境変数名 | `JBOSS_MASTER_PASSWORD` | 受け渡しに使う環境変数名 |
| `--jboss-secret-id ID` | シークレット id | `jboss_master_password` | `--secret id=...` の id。Dockerfile の `RUN --mount=type=secret,id=...` と一致させる |

### スイッチバック

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--switchback-shell PATH` | シェルスクリプトのパス | env `SWITCHBACK_SHELL` | スイッチバック用シェル (`source` で読み込む) |
| `--auto-switchback` | フラグ | `false` | ECR 権限が無い場合に自動でスイッチバックして継続 |
| `--warn-only` | フラグ | **既定** | ECR 権限が無い場合に警告して終了 |

### CA 証明書 (BuildKit シークレット)

| オプション | 値 | 既定 | 説明 |
| --- | --- | --- | --- |
| `--cacert-dir DIR` | ディレクトリのパス<br>(繰り返し可) | (なし) | `cacert.crt` を置いたディレクトリ |
| `--cacert-secret-id ID` | 英数字と `. _ -` | `cacerts` | シークレット id |
| `--cacert-bundle PATH` | tar のパス | 一時ファイル | 生成する tar の出力先 |
| `--cacert-glob PATTERN` | glob パターン<br>(繰り返し可) | `*.crt` と `*.pem` | 各ディレクトリから取り込むファイルのパターン |
