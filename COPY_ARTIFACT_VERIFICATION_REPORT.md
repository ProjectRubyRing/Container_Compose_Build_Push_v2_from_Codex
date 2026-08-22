# コピー成果物の取り込み検証 — 調査報告と実装内容

> 出典: Claude Code セッション 482651f3-ee64-4b28-84eb-3dd8a95d029a の回答（2026-08-21 21:36:42.320 UTC）を md 化したもの。

---

## 1. 原因の調査結果

### 症状の意味するところ

報告された 4 つの事実を組み合わせると、原因の範囲が一意に絞れます。

| 観測 | そこから分かること |
| --- | --- |
| `compose build` は成功し、イメージも作り直されている | ビルド前の `--copy-file` は正しく動いている |
| `--no-cache` を付けても症状が変わらない | **ビルドキャッシュは原因ではない**。むしろ「イメージは毎回正しく作り直されている」ことの裏付け |
| 起動もデプロイも成功する | AP サーバ側の異常ではない |
| `server.log` の内容が前回のまま | コンテナが**古い成果物**を読んでいる |

つまり、壊れているのは **ビルドより後 — 「イメージの中身がコンテナへ届くところ」** です。

### 本命の原因: 名前付きボリュームがデプロイ先を覆っている

`compose.yml` の `frontend` に

```yaml
volumes:
  - deployments:/opt/jboss/standalone/deployments
```

のような定義があると、次の挙動が効きます。

1. Docker が **イメージ側の内容をボリュームへ複製するのは、そのボリュームを新規作成した (中身が空の) 1 回目だけ**。
2. 2 回目以降の実行では **既存のボリュームの中身が優先** され、イメージへ焼いた新しい WAR はコンテナから一切見えない。
3. `build_and_verify.sh` の `teardown_container` は `compose down`（`-v` なし）だったため、**ボリュームが毎回残り続ける**。

結果として、一度ボリュームが作られると **消すまで永遠に同じ古い WAR がデプロイされ続けます**。`--no-cache` はイメージのビルドにしか効かないので無関係です。JBoss の `.war.deployed` マーカーや `standalone/data/content` も同じボリューム上に残るため、再デプロイも走りません。`standalone/log` がボリュームなら `server.log` 自体も前回分の続きです。

### 副次的にありうる原因（同じ症状になる）

| # | 原因 | 見分け方 |
| --- | --- | --- |
| B | バインドマウントがデプロイ先を覆っている | ホスト側ディレクトリの中身が見える |
| C | コンテナが今回のイメージから作り直されていない（`--no-recreate-containers` など） | 既存コンテナ点検が WARN を出すが、これまでエラーにはしていなかった |
| D | ビルドがコピーしたファイルを取り込んでいない（`.dockerignore` の除外、`COPY` 元の誤り、コピー先がビルドコンテキスト外） | イメージ側も古い |

**これらはどれもログに何も出ません。** そこが本質的な問題でした。

---

## 2. 実装した修正

### (1) 取り込み検証 — 検知してエラーにする

`--copy-file` を指定した実行では、**コピー時点でコピー元の SHA-256 を控え**、`compose up -d` の直後（起動完了の確認より前）に照合します。

- `docker exec` でコンテナ内を `find` → **コンテナから見えている中身**の SHA-256
- `docker create`（起動しない）→ `docker cp` → **イメージに入っている中身**の SHA-256
- `docker inspect .Mounts` → **そのパスを覆っているマウント**

この 3 点照合で原因まで切り分けます。

| イメージ側 | コンテナ側 | 診断 |
| --- | --- | --- |
| 一致 | 一致 | **OK** |
| 一致 | 不一致・マウントあり | `マウントがイメージの内容を隠しているため、今回ビルドした成果物が使われていません` → **exit 1** |
| 一致 | 不一致・マウントなし | `コンテナが今回のイメージから作り直されていない可能性があります` → **exit 1** |
| 不一致 | 不一致 | `ビルドがコピーしたファイルを取り込めていません` → **exit 1** |

判定ルール:
- 一致が 1 件でもあれば成功（`.npmrc` のように同名ファイルが複数箇所にある構成を壊さない）
- **未検出は既定では警告のみ** — ビルド時だけ必要なファイルはイメージに残らないのが正しいため。WAR には `--copy-artifact-required` を付けて未検出もエラーにします
- SHA-256 を算出できなかったものは不一致と断定せず `[判定不可]` として残す
- `--copy-file` 未使用でも、デプロイ先が覆われていれば WARN を出す

新オプション: `--verify-copy-artifact` / `--no-verify-copy-artifact` / `--copy-artifact-path` / `--copy-artifact-search-dir` / `--copy-artifact-required`

### (2) 対話モード終了時のボリューム削除

- 対話操作を「0) 対話操作を終了」まで進めた実行は **既定で `compose down --volumes`**（従来はコンテナのみ削除）
- 取り込み検証が「古い成果物を抱えたボリューム」を検出したときも `-v` を付ける（付けないと次回も同じ失敗を繰り返すため）
- `--remove-volumes`（常に）/ `--keep-volumes`（従来どおり残す）を追加。同時指定は `exit 2`

### 想定される使い方

```bash
./build_and_verify.sh \
    --verify-startup --compose-service frontend --startup-service frontend \
    --copy-file ./dist/frontend.war:./app \
    --copy-artifact-required \
    --copy-artifact-search-dir /opt/jboss/standalone \
    --keep-container-mode logs
```

---

## 3. 変更ファイルと検証

| ファイル | 内容 |
| --- | --- |
| `build_and_verify.sh` | 検証機能・ボリューム削除・全量レポート `[13]`・ヘッダーの `コピー取込検証` 行 (+813 行) |
| `build_and_push.sh` | 新しい値付きオプションの `--build-only` 透過 |
| `tests/build_and_verify_test.sh` | 14 シナリオ追加（不一致検知／ビルド未取り込み／一致／未検出／`--copy-artifact-required`／混在／無効化／シェル無し 3 種／指定エラー／`down -v` 3 種） |
| `tests/helpers/docker` | `copy-artifact-probe` / `create` / `cp` / `rm` / シェル無しの再現 |
| `README.md`, `docs/*_guide.md`, `docs/*.xlsx` | 原因の解説と全オプションを追記、Excel 再生成 |

**テスト:** `bash tests/build_and_verify_test.sh` を修正後 2 回完走、いずれも exit 0（各約 47 分）。

一点だけ申し添えると、原因の特定は提示いただいた症状からの推定です。実際の `compose.yml` の `frontend` に `volumes:` があるかを確認いただければ確定します。もし無ければ、今回の検証機能が (C) か (D) のどちらかを実行時に名指ししてくれます。

---

## 4. 同等の設定を ECS / Fargate のタスク定義で行った場合

Compose の `volumes:` に相当する設定を Fargate のタスク定義（バインドマウント）で行ったときに同じ症状になるか、なるとしてタスク定義側で回避できるか、を整理します。

### 4.1 結論

| 構成 | 「古い成果物が使われ続ける」 | 実際に起きること |
| --- | --- | --- |
| **Fargate のバインドマウント**（`volumes: [{ "name": "x" }]` + `mountPoints`） | **起きない** | 代わりに **デプロイ先が空**になる。毎回同じように失敗するので気づきやすい |
| **EFS ボリューム**（`efsVolumeConfiguration`） | **起きる** | Compose の名前付きボリュームと**症状が完全に一致**する |
| **EBS ボリューム**（`configuredAtLaunch` + `snapshotId`） | **起きうる** | スナップショット時点の成果物が毎回復活する |
| 可変タグ（`:latest`）＋ 新リビジョン登録なし | **起きる**（(C) 相当） | タスクがそもそも入れ替わっていない |
| init コンテナ / `volumesFrom` で書き込む構成 | **起きうる**（(D) 相当） | 書き込む側が古い |

要するに、**バインドマウント単体では今回の症状は再現しません。** ただし Fargate で「デプロイ先に永続ストレージを重ねたい」となったときに選ぶことになる **EFS / EBS では同じ罠がそのまま復活します**。

### 4.2 なぜバインドマウントでは起きないのか

理由は 3 つあり、いずれも決定的です。

1. **Compose の名前付きボリュームとは意味が違う。** 名前付きボリュームは「空のときだけイメージ側の内容を複製し、以後は既存の中身を優先」する。バインドマウントに複製の仕組みは無く、**常にマウント元でイメージ側を覆う**だけ。「古い中身が生き残る」のは前者だけの性質です。
2. **Fargate のバインドマウントはタスクのエフェメラルストレージ上にある。** タスクごとに作られ、タスク停止とともに破棄される。**次のタスクへ持ち越す経路が存在しません**（`ephemeralStorage.sizeInGiB` は容量の指定であって永続化ではない）。
3. **Fargate では Compose の名前付きボリューム相当をそもそも作れない。** Docker ボリューム（`dockerVolumeConfiguration`）は EC2 起動タイプ専用、ホストパス指定（`host.sourcePath`）も Fargate では使えません。指定できるのは「名前だけの空ボリューム」「EFS」「EBS」「（Windows の）FSx」に限られます。

したがって Fargate で `deployments` を覆うと、**JBoss は空のデプロイディレクトリを見る**ことになり、`server.log` は「前回の内容のまま」ではなく「何もデプロイしていない」になります。今回の「成功しているのに中身だけ古い」より、はるかに気づきやすい壊れ方です。

> 補足: マウント時にイメージ側の内容が複製されるか（＝空になるか）はランタイム実装に依存する余地がありますが、**どちらであってもタスクごとに作り直される**ため、前回の成果物が残る経路はありません。実環境での確認方法は 4.5 に置きました。

### 4.3 それでも Fargate で「古い成果物」になる 4 パターン

#### (A) EFS をデプロイ先にマウントしている — 本命の再来

```json
{
  "name": "deployments",
  "efsVolumeConfiguration": {
    "fileSystemId": "fs-xxxxxxxx",
    "rootDirectory": "/deployments",
    "transitEncryption": "ENABLED"
  }
}
```

EFS はタスクをまたいで**永続します**。一度書かれた WAR は誰かが消すまで残り、新しいイメージの WAR はマウントに覆われて見えません。JBoss なら `.war.deployed` マーカーや `standalone/data/content` も EFS 上に残るため、再デプロイも走りません。**Compose の名前付きボリュームと症状が完全に一致します。** しかも `compose down -v` に相当する「ついでに消える」操作が無いぶん、こちらの方が根深くなります。

#### (B) EBS ボリュームをスナップショットから作成している

`configuredAtLaunch: true` のボリュームを `snapshotId` 付きで起動すると、スナップショット時点の中身がマウントされ、イメージ側を覆います。タスク終了で消えても**次回も同じスナップショットから復元される**ため、症状は毎回再現します。

#### (C) 可変タグを push し直しただけでタスクが入れ替わっていない

`:latest` を上書き push してもサービス側では何も起きません。タスク定義のリビジョンが変わらないため ECS は「あるべき状態は満たされている」と判断し、**古いイメージのタスクが動き続けます**。`aws ecs update-service --force-new-deployment` を忘れた、あるいは新リビジョンを登録していないケースで、Compose 側の (C) と同じ位置づけです。

#### (D) 書き込む側が古い

init コンテナや `volumesFrom` で成果物をバインドマウントへ書き込む構成では、**書き込む側のイメージ／ソースが古ければ結果も古く**なります。マウントが毎回空でも救えません。Compose 側の (D) に相当します。

加えてローリング更新中は新旧タスクが同居するため、**旧タスクのログを見ているだけ**、というパターンも実際にはよく混ざります。

### 4.4 タスク定義側での回避策

| # | 施策 | 効く相手 |
| --- | --- | --- |
| 1 | デプロイ先にボリュームを重ねない | (A) (B) — 最優先 |
| 2 | 共有が必要なら「毎回空のバインドマウント + init コンテナ」 | (A) (B) |
| 3 | `image` をダイジェストで固定し、ECR タグを不変にする | (C) |
| 4 | EFS を使うなら `rootDirectory` をリビジョン単位にする / `readOnly` | (A) |
| 5 | 起動時セルフチェックで**タスクを落とす** + デプロイサーキットブレーカー | (A)〜(D) すべて |
| 6 | `readonlyRootFilesystem: true` で書き込み先を明示させる | 予防 |

#### 1. デプロイ先にボリュームを重ねない

最も効きます。**デプロイ成果物はイメージに焼き、ボリュームは本当に可変な状態（ログ・一時領域・データ）だけに使う**。今回の原因そのものを構造的に消せます。

#### 2. 共有が必要なら「毎回空のバインドマウント + init コンテナ」

コンテナ間で成果物を共有したい場合は、**永続ストレージではなくバインドマウント**を使い、成果物は init コンテナが毎回書き込みます。バインドマウントはタスクごとに作り直されるので、古い中身が残りません。

```json
{
  "volumes": [ { "name": "deployments" } ],
  "containerDefinitions": [
    {
      "name": "artifact-init",
      "image": "<acct>.dkr.ecr.<region>.amazonaws.com/frontend@sha256:<digest>",
      "essential": false,
      "command": ["sh", "-c", "cp /app/frontend.war /mnt/deployments/ && sha256sum /mnt/deployments/frontend.war"],
      "mountPoints": [
        { "sourceVolume": "deployments", "containerPath": "/mnt/deployments", "readOnly": false }
      ]
    },
    {
      "name": "frontend",
      "image": "<acct>.dkr.ecr.<region>.amazonaws.com/frontend@sha256:<digest>",
      "essential": true,
      "dependsOn": [ { "containerName": "artifact-init", "condition": "SUCCESS" } ],
      "mountPoints": [
        { "sourceVolume": "deployments", "containerPath": "/opt/jboss/standalone/deployments", "readOnly": false }
      ]
    }
  ]
}
```

`dependsOn` は Fargate プラットフォームバージョン 1.3.0 以降が必要です。`sha256sum` をログに出しておくと、CloudWatch Logs 上で「今回どの成果物を置いたか」が後から追えます。

#### 3. `image` をダイジェストで固定する

```json
"image": "<acct>.dkr.ecr.<region>.amazonaws.com/frontend@sha256:1a2b3c..."
```

ダイジェスト指定にすると、**成果物が変わればタスク定義のリビジョンが必ず変わる**ため、(C)（入れ替わっていない）が原理的に起こらなくなります。あわせて ECR リポジトリを `imageTagMutability: IMMUTABLE` にしておくと、同じタグの上書き push 自体を禁止できます。可変タグを使い続ける場合は、デプロイ手順に `--force-new-deployment` を必ず入れてください。

#### 4. EFS をどうしても使う場合

- `rootDirectory` を **ビルド／リビジョン単位のパス**にする（`/deployments/build-1234`）。古い中身を引き継ぐ経路が消えます。
- 参照専用なら `mountPoints[].readOnly: true` と `efsVolumeConfiguration.authorizationConfig` のアクセスポイントで書き込みを禁止する。
- デプロイ先（`standalone/deployments`）と可変データ（`standalone/log` など）を**同じボリュームに同居させない**。

#### 5. 起動時セルフチェックでタスクを落とす（`build_and_verify.sh` の検証の移植）

`build_and_verify.sh` の「コンテナ側 SHA-256 照合」に相当する処理を、タスク定義の起動時チェックとして持たせます。

```json
"entryPoint": ["/usr/local/bin/verify-artifact.sh"],
"environment": [
  { "name": "EXPECTED_WAR_SHA256", "value": "<ビルド時に控えた SHA-256>" }
]
```

```sh
#!/bin/sh
set -eu
target=/opt/jboss/standalone/deployments/frontend.war
if [ ! -f "$target" ]; then
    echo "ERROR: デプロイ先に成果物がありません（マウントがイメージの内容を隠している可能性）: $target" >&2
    exit 1
fi
actual="$(sha256sum "$target" | cut -d' ' -f1)"
if [ "$actual" != "$EXPECTED_WAR_SHA256" ]; then
    echo "ERROR: デプロイ先の成果物が今回ビルドしたものと一致しません expected=$EXPECTED_WAR_SHA256 actual=$actual" >&2
    exit 1
fi
exec "$@"
```

不一致ならコンテナが異常終了し、ECS がタスクを落とします。サービス側に

```json
"deploymentConfiguration": {
  "deploymentCircuitBreaker": { "enable": true, "rollback": true }
}
```

を入れておけば、**古い成果物のまま「成功」してしまう代わりに、デプロイが失敗して自動でロールバック**します。今回 `build_and_verify.sh` に入れた「検知して exit 1」と同じ思想を、Fargate 側へ持ち込む形です。

#### 6. `readonlyRootFilesystem: true`

コンテナのルートファイルシステムを読み取り専用にすると、書き込みが必要な場所を `mountPoints` で明示せざるを得なくなり、「なんとなく重ねていたボリューム」が棚卸しされます。予防策としては有効です。

### 4.5 実環境での確認コマンド

```bash
# (1) タスク定義にデプロイ先を覆うマウントが無いか
aws ecs describe-task-definition --task-definition frontend \
  --query 'taskDefinition.{volumes:volumes, mounts:containerDefinitions[].{name:name,mountPoints:mountPoints}}'

# (2) サービスが今どのリビジョンで動いているか（(C) の切り分け）
aws ecs describe-services --cluster <cluster> --services <service> \
  --query 'services[0].deployments[].{status:status, td:taskDefinition, running:runningCount, created:createdAt}'

# (3) 実タスクが解決したイメージダイジェスト（可変タグの取り違えはここで判る）
aws ecs describe-tasks --cluster <cluster> --tasks <task-id> \
  --query 'tasks[0].containers[].{name:name, image:image, digest:imageDigest}'

# (4) 動作中コンテナの中身を直接照合（enableExecuteCommand: true / PV 1.4.0 以降が必要）
aws ecs execute-command --cluster <cluster> --task <task-id> --container frontend \
  --interactive --command "sh -c 'find /opt/jboss/standalone -name \"*.war\" -exec sha256sum {} +'"
```

(4) が `build_and_verify.sh` の「コンテナ側」照合そのものです。「イメージ側」の照合はローカル／CI で `build_and_verify.sh --verify-copy-artifact` を通した時点で担保されるので、

**ローカルで 3 点照合 → イメージを push → Fargate では起動時セルフチェック（4.4-5）と ECS Exec（4.5-4）で確認**

という分担になります。4.2 の「バインドマウントは毎回空か」も、(4) を新規タスクに対して 2 回連続で実行すれば実環境で確定できます。
