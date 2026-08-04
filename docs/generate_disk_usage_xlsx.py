#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""build_and_verify.sh のディスク使用量削減 補足資料 (xlsx) を生成する。

build_and_verify.sh を繰り返し実行 (特に --no-cache 指定) するとローカルディスクの
使用量が増え続ける。その原因と、compose.yml 側 / スクリプト側で取れる対策を
Excel 1 冊にまとめて出力する。

    00_目次                  … 表紙。結論・前提環境・シート索引
    01_容量が増える原因      … 実行のたびに何が残るか。--no-cache での増え方
    02_compose.yml側の対応   … compose.yml / daemon.json の設定で減らす
    03_スクリプト側の対応    … build_and_verify.sh へ追加するオプション案と実装箇所
    04_実装コード例          … 03 の案をそのまま貼れる bash 断片
    05_運用コマンド          … スクリプトを直さなくても今日から打てるコマンド
    06_施策比較と推奨構成    … 効果 / 手間 / リスクの比較と、用途別の推奨組み合わせ

xlsx の組み立て (スタイル・行高計算・zip 書き出し) は generate_guide_xlsx.py の
実装をそのまま使う。フォント・配色・列幅の考え方は既存ガイドの Excel と揃う。

    python3 docs/generate_disk_usage_xlsx.py
    python3 docs/generate_disk_usage_xlsx.py docs/build_and_verify_disk_usage.xlsx
"""

import datetime
import os
import sys

# docs/ 配下へ __pycache__ を作らない (generate_guide_xlsx を import するだけのため)。
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from generate_guide_xlsx import (  # noqa: E402
    Cell, Sheet, TITLE_ROW_HEIGHT, add_table, header_row, write_xlsx,
    S_ACCENT, S_BODY, S_CENTER, S_KEY, S_LABEL, S_MONO, S_NOTE, S_ON, S_TITLE,
)

TITLE = "build_and_verify.sh ディスク使用量の削減 (補足資料)"
DEFAULT_OUTPUT = "build_and_verify_disk_usage.xlsx"
TARGET_SCRIPT = "build_and_verify.sh / compose.yml / Dockerfile"


def add_code_lines(sheet, code):
    """コード / 設定ブロックを 1 行 1 セルで流し込む。

    複数行をまとめて 1 セルへ入れると、Excel の行高上限 (409pt = 約 24 行) で
    下が切れてしまう。行ごとに分けておけば、何行あっても全文が読める。
    """
    for line in code.split("\n"):
        sheet.add_merged(line, S_MONO)


# =============================================================================
# 00_目次
# =============================================================================

SHEET_DESCRIPTIONS = [
    ("01_容量が増える原因",
     "1 回の実行で何がディスクへ残るのか。--no-cache を付けたときの増え方と、"
     "現在の build_and_verify.sh がそれをどう扱っているか (該当行つき)"),
    ("02_compose.yml側の対応",
     "compose.yml・.dockerignore・daemon.json の設定で減らせるもの。記述例と副作用"),
    ("03_スクリプト側の対応",
     "build_and_verify.sh へ追加するオプション案。動作・実装箇所 (行番号)・注意点"),
    ("04_実装コード例",
     "03 の案をそのまま貼り付けられる bash 断片。既存のヘルパ・作法に合わせてある"),
    ("05_運用コマンド",
     "スクリプトを改修しなくても今日から打てるコマンド。計測・回収・Windows 固有の縮小"),
    ("06_施策比較と推奨構成",
     "施策ごとの削減効果 / 手間 / リスクの比較と、用途別の推奨組み合わせ 3 パターン"),
]

CONCLUSIONS = [
    ("① 実行のたびに残る本体は 2 つ",
     "「タグを失った旧イメージ (dangling)」と「BuildKit のビルドキャッシュ」。"
     "--no-cache は前者を毎回イメージ 1 個分まるごと生み、後者も毎回全レイヤ分書き足す "
     "(--no-cache はキャッシュを『読まない』指定であって『書かない』指定ではない)。"),
    ("② compose.yml だけでもかなり減らせる",
     "ビルドだけを確認する実行は x-bake の output: type=cacheonly でイメージを一切作らない。"
     "cache_to をレジストリ / 外部ディレクトリへ逃がせば、キャッシュも data root から出せる。"
     "併せて daemon.json の builder.gc で上限を決めておく。"),
    ("③ スクリプト側は 3 件を実装済み (2026-08-05)",
     "旧イメージの回収 (既定で有効) / --prune-build-cache[-keep] / --disk-usage-report を "
     "build_and_verify.sh へ実装し、tests/build_and_verify_test.sh へ 11 シナリオを追加した。"
     "残る案 (03 シートの案 2 / 4 / 5 / 7 / 9) は未実装。"),
    ("④ 数値は必ず計測してから判断する",
     "本資料の削減量は構成から求めた目安。実装済みの --disk-usage-report か "
     "docker system df / docker builder du で、対策の前後を実測して確認すること。"),
]


def build_cover_sheet(generated):
    sheet = Sheet("00_目次", widths=[30, 108])
    sheet.add_merged(TITLE, S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(
        "build_and_verify.sh を繰り返し実行するとローカルディスクが圧迫される問題について、"
        "原因と対策 (compose.yml 側 / スクリプト側) をまとめた補足資料です",
        S_NOTE, height=20.0)
    sheet.add_blank(10.0)

    sheet.add(header_row(["項目", "内容"]))
    for label, value in [
        ("対象", TARGET_SCRIPT),
        ("課題", "build_and_verify.sh を実行するたび (特に --no-cache 指定時) に "
                 "ローカルイメージとビルドキャッシュが積み上がり、ディスクを圧迫する"),
        ("目的", "ディスクをできるだけ使わず、イメージを最小限に保ったまま検証を回せるようにする"),
        ("想定実行環境", "RHEL 9.6 の EC2 (bash 5.x / Docker CE) — 開発・テストは Windows 11 + "
                         "Git Bash + Docker Desktop でも実施"),
        ("生成日時", generated),
        ("生成方法", "python3 docs/generate_disk_usage_xlsx.py "
                     "(本ブックの内容は同スクリプト内に定義。修正時はスクリプト側を直して再実行)"),
    ]:
        sheet.add([Cell(label, S_LABEL), Cell(value, S_BODY)])

    sheet.add_section("結論 (先に押さえる 4 点)")
    sheet.add(header_row(["要点", "内容"]))
    for label, value in CONCLUSIONS:
        sheet.add([Cell(label, S_KEY), Cell(value, S_BODY)])

    sheet.add_section("シート構成")
    sheet.add(header_row(["シート", "記載内容"]))
    for name, description in SHEET_DESCRIPTIONS:
        sheet.add([Cell(name, S_KEY), Cell(description, S_BODY)])

    sheet.add_blank(10.0)
    sheet.add_merged(
        "※ 行番号は 2026-08-05 時点の build_and_verify.sh (12,761 行) を指します。"
        "スクリプトを改修したら本資料の行番号も更新してください。",
        S_NOTE, height=20.0)
    return sheet


# =============================================================================
# 01_容量が増える原因
# =============================================================================

CAUSE_HEADER = [
    "#", "ディスクへ残るもの", "いつ増えるか", "--no-cache 指定時の増え方",
    "現在の build_and_verify.sh の扱い", "確認コマンド",
]

CAUSES = [
    ["1", "タグを失った旧イメージ (dangling)",
     "docker compose build が成功するたび。j1/base.local のタグが新しいイメージへ移り、"
     "直前の世代はタグを失って <none>:<none> のまま残る",
     "最も効くのがここ。全レイヤが作り直されるため直前世代と共有するレイヤが 1 つも無く、"
     "1 回の実行でイメージ 1 個分がまるごと積み上がる "
     "(キャッシュ有効時は変更のあったレイヤ以降だけ)",
     "削除しない。teardown_container() (4529 行) の compose down はコンテナとネットワークだけを消し、"
     "イメージには触れない。消えるのは --cleanup-all-docker-data (8988 行) を指定したときだけ",
     "docker image ls -f dangling=true\ndocker system df"],
    ["2", "BuildKit のビルドキャッシュ",
     "ビルドのたび。BuildKit は各レイヤの結果をキャッシュレコードとして書き込む",
     "--no-cache は『既存キャッシュを読まない』指定であって『書かない』指定ではない。"
     "毎回まったく新しいレコードが全レイヤ分書き足され、以後も再利用されないまま残る",
     "削除しない。docker builder prune を実行するのは --cleanup-all-docker-data の中 (9077 行) だけ",
     "docker builder du --verbose\ndocker system df"],
    ["3", "伝搬検証のプローブビルドのキャッシュ",
     "--verify-jboss-password 指定時。2141 行の "
     "docker build --no-cache --output type=local が毎回走る",
     "常に --no-cache 固定 (シークレットはキャッシュキーに含まれないため意図的)。"
     "イメージは残らない (最終ステージが scratch + --output type=local) が、キャッシュは毎回増える",
     "一時ディレクトリ ($probe_dir) は削除する (2184 行) が、ビルドキャッシュは残す",
     "docker builder du"],
    ["4", "ベースイメージの旧世代",
     "docker compose build --pull や compose.yml の build.pull: true を使ったとき。"
     "public.ecr.aws/docker/library/alpine:3.20 が更新されると旧イメージがタグを失う",
     "--no-cache 自体は pull を伴わないため、この項目は増えない",
     "スクリプトは --pull を付けない (増やさない側の作りになっている)",
     "docker image ls -f dangling=true"],
    ["5", "停止コンテナと書き込みレイヤ",
     "起動確認 (--verify-startup / --verify-url) のたび",
     "ビルドのキャッシュ指定とは無関係",
     "正常時は compose down で削除される。ただし --keep-container / --keep-container-mode と、"
     "デプロイエラー検出時 (既定 KEEP_CONTAINER_ON_DEPLOY_ERROR=true / 241 行) は"
     "コンテナを起動したまま残すため、その分が積み上がる",
     "docker ps -a\ndocker system df -v"],
    ["6", "ボリューム (名前付き / 匿名)",
     "起動確認のたび。compose.yml に volumes を持つサービスと、イメージ側の VOLUME 宣言",
     "ビルドのキャッシュ指定とは無関係",
     "残る。compose down に --volumes を付けていない (4538 / 4540 行) ため、"
     "名前付き・匿名とも削除されない",
     "docker volume ls\ndocker system df"],
    ["7", "コンテナのログファイル",
     "起動確認中ずっと。json-file ログドライバの既定はローテーション無し (上限なし)",
     "ビルドのキャッシュ指定とは無関係",
     "compose down で一緒に消えるが、コンテナを残すモードでは無制限に伸びる",
     "docker inspect --format '{{.LogPath}}' <コンテナ> (Linux)"],
    ["8", "レポートファイル (Docker 管理外)",
     "--report-dir 指定時。build_and_verify_<日時>.txt / _java_exceptions.xlsx / .txt が"
     "実行のたびに増える",
     "ビルドのキャッシュ指定とは無関係",
     "意図的に残す仕様 (証跡)。世代の整理は運用側で行う",
     "du -sh <report-dir>"],
    ["9", "仮想ディスクの膨張 (Windows / Docker Desktop)",
     "上記のいずれかで data root が膨らんだとき",
     "1〜3 が積み上がるほど vhdx が伸びる",
     "スクリプトからは制御できない。WSL2 の仮想ディスクは一度伸びると、prune しても"
     "ホストの空き容量は自動では戻らない (Docker 内部の空き領域として再利用されるだけ)",
     "docker system df とホスト側 vhdx のファイルサイズを両方見る"],
]

CAUSE_NOTES = [
    ("1 回の実行で増える量の目安",
     "--no-cache 指定時 ≒ イメージ 1 個分 (dangling) + 同等量のビルドキャッシュ。"
     "つまり『イメージサイズ × 約 2』が毎回積み上がると見ておくとよい。"
     "キャッシュ有効時は『変更のあったレイヤ以降のサイズ × 約 2』に縮む。"),
    ("なぜ --no-cache でも ID が変わるのか",
     "レイヤの内容が完全に同一なら image ID も同じになり dangling は生じない。"
     "しかし RUN で作られるファイルの mtime やパッケージの取得内容が変わるため、"
     "実際にはほぼ毎回別 ID になる。"),
    ("compose down が消すもの / 消さないもの",
     "消す: コンテナ、Compose が作ったネットワーク。"
     "消さない: イメージ (--rmi 指定時のみ)、ボリューム (--volumes 指定時のみ)、ビルドキャッシュ。"),
]


def build_cause_sheet():
    # 表の後ろに補足セクションを置くため、オートフィルタは付けない
    # (範囲が補足行まで伸びて、絞り込むと補足が消えてしまう)。
    sheet = Sheet("01_容量が増える原因", widths=[4, 24, 30, 34, 34, 28], freeze_rows=4)
    sheet.add_merged("実行のたびにディスクへ残るもの", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(
        "「何が」「いつ」「どれくらい」残るのかを先に押さえる。対策 (02 / 03 シート) は"
        "この番号に対応している",
        S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    add_table(sheet, CAUSE_HEADER, CAUSES, key_column=1, center_columns=(0,))

    sheet.add_section("補足")
    sheet.add(header_row(["項目", "内容"]))
    for label, value in CAUSE_NOTES:
        sheet.add([Cell(label, S_KEY), Cell(value, S_BODY)])
    return sheet


# =============================================================================
# 02_compose.yml側の対応
# =============================================================================

COMPOSE_HEADER = ["#", "対応", "設定場所", "記述例", "効果", "注意・前提"]

COMPOSE_MEASURES = [
    ["1", "イメージを作らずビルドだけ検証する (x-bake の cacheonly 出力)",
     "compose.yml\nservices.base.build.x-bake",
     "services:\n"
     "  base:\n"
     "    build:\n"
     "      context: .\n"
     "      dockerfile: Dockerfile\n"
     "      secrets:\n"
     "        - jboss_master_password\n"
     "      x-bake:\n"
     "        output:\n"
     "          - type=cacheonly\n"
     "    image: j1/base.local\n"
     "\n"
     "# 実行:\n"
     "docker buildx bake -f compose.yml base",
     "ビルド結果をイメージストアへ書き出さないため、イメージも dangling も一切増えない。"
     "『ビルドが通るか』だけを見る検証 (--verify-startup も --verify-url も付けない実行) に最適",
     "x-bake を読むのは docker buildx bake だけで、docker compose build は無視する "
     "(既存の実行方法は変わらない)。起動確認を行う実行では使えない (イメージが必要)。"
     "ビルドキャッシュは従来どおり増えるため #6 と併用する。"
     "compose.yml の environment 型 secrets を bake が解釈できるかは buildx の版に依存するため、"
     "導入前に 1 度、伝搬を確認しておくこと"],
    ["2", "ビルドキャッシュをレジストリへ逃がす",
     "compose.yml\nservices.base.build.cache_from / cache_to",
     "    build:\n"
     "      cache_from:\n"
     "        - type=registry,ref=<acct>.dkr.ecr.ap-northeast-1.amazonaws.com/j1/base-cache:main\n"
     "      cache_to:\n"
     "        - type=registry,ref=<acct>.dkr.ecr.ap-northeast-1.amazonaws.com/j1/base-cache:main,"
     "mode=min,image-manifest=true,oci-mediatypes=true",
     "キャッシュがローカルの data root ではなくレジストリ側に置かれる。"
     "『前回のローカル状態に依存しない検証』という --no-cache の目的を、"
     "ローカル容量を使わずに満たせる",
     "既定の docker ドライバはキャッシュのエクスポートに未対応。"
     "docker buildx create --driver docker-container で作ったビルダーが要る "
     "(docker compose build --builder <名前>)。"
     "ECR へ置く場合は image-manifest=true,oci-mediatypes=true が必要。"
     "mode=max は全ステージを保存して大きくなるため mode=min から始める"],
    ["3", "ビルドキャッシュを外部ディレクトリへ逃がす",
     "compose.yml\nservices.base.build.cache_from / cache_to",
     "    build:\n"
     "      cache_from:\n"
     "        - type=local,src=/var/tmp/j1-build-cache\n"
     "      cache_to:\n"
     "        - type=local,dest=/var/tmp/j1-build-cache,mode=min",
     "キャッシュの容量が du -sh で見え、不要になれば rm -rf で確実に消せる。"
     "data root (/var/lib/docker) を膨らませない",
     "#2 と同じく docker-container ドライバが必要。"
     "レジストリを使えない環境向けの代替。置き場所は /var/lib/docker と別パーティションにする"],
    ["4", "検証に必要なステージだけビルドする",
     "compose.yml\nservices.base.build.target",
     "    build:\n"
     "      context: .\n"
     "      target: verify   # マルチステージの検証用ステージ名",
     "最終ステージまで作らない分、生成されるレイヤとキャッシュが減る",
     "Dockerfile をマルチステージ化していることが前提。"
     "本番と同じ成果物を確認したい検証では使わない"],
    ["5", "ベースイメージを無用に取り直さない",
     "compose.yml\nservices.*.build.pull / pull_policy",
     "    build:\n"
     "      pull: false        # 既定。true にしない\n"
     "    pull_policy: missing # 手元に無いときだけ pull",
     "ベースイメージが更新されるたびに旧世代が dangling 化するのを防ぐ",
     "ベースイメージの更新を検証したいときは、意図して指定した実行でだけ --pull を使う"],
    ["6", "ビルドキャッシュの上限を daemon 側で決める",
     "/etc/docker/daemon.json\n(Docker Desktop は Settings > Docker Engine)",
     "{\n"
     "  \"builder\": {\n"
     "    \"gc\": {\n"
     "      \"enabled\": true,\n"
     "      \"defaultKeepStorage\": \"10GB\"\n"
     "    }\n"
     "  }\n"
     "}\n"
     "\n"
     "# RHEL: 設定後に sudo systemctl reload docker",
     "キャッシュが上限に達すると BuildKit が自動で古いものから捨てる。"
     "一度入れれば以後は放っておける、費用対効果の高い対策",
     "上限に達するまで GC は働かないため、上限は『使ってよい最大量』として設定する。"
     "Docker Engine 28 以降は defaultKeepStorage が非推奨で、"
     "gc.policy の reservedSpace / maxUsedSpace / minFreeSpace を使う"
     " (使用中の版のドキュメントで書式を確認すること)"],
    ["7", "コンテナログの上限を決める",
     "compose.yml\nservices.*.logging",
     "    logging:\n"
     "      driver: json-file\n"
     "      options:\n"
     "        max-size: \"10m\"\n"
     "        max-file: \"3\"",
     "1 サービスあたり最大 30MB で頭打ちになる。"
     "--keep-container や デプロイエラー時の対話モードでコンテナを残しても、ログが無制限に伸びない",
     "起動確認では過去ログをさかのぼることがあるため、max-size を小さくしすぎない。"
     "--startup-log-lines all で全行を見る運用なら 10m 以上を確保する"],
    ["8", "検証中の書き込みを RAM へ逃がす",
     "compose.yml\nservices.*.tmpfs",
     "    tmpfs:\n"
     "      - /tmp:size=64m\n"
     "      - /var/tmp:size=64m",
     "コンテナの書き込みレイヤが太らない。停止と同時に消える",
     "メモリを消費する。調査対象のログ出力先には使わない (コンテナ停止で消えるため)"],
    ["9", "検証専用サービスに名前付きボリュームを作らない",
     "compose.yml\nservices.*.volumes / トップレベル volumes",
     "# 名前付きボリュームは compose down --volumes まで残る。\n"
     "# 検証で永続化が不要なら定義しない (匿名ボリュームなら down -v で確実に消える)。",
     "実行のたびにボリュームが積み上がるのを防ぐ",
     "DB のようにデータを引き継ぎたいサービスは対象外。"
     "スクリプト側は 03 シート案 2 (--down-volumes) と組み合わせる"],
    ["10", "ビルドコンテキストを絞る",
     ".dockerignore\n(compose.yml の build.context 直下)",
     ".git/\n"
     "docs/\n"
     "tests/\n"
     "*.xlsx\n"
     "*.log\n"
     "STARTUP_INSTABILITY_ANALYSIS.md",
     "COPY で不要ファイルがレイヤへ入るのを防ぎ、イメージ本体とキャッシュの両方を小さくする。"
     "daemon へ送るコンテキストの一時コピーも減る",
     "このリポジトリは README.md だけで 110KB、build_and_verify.sh が 640KB あるため、"
     "Dockerfile が COPY . . を使う構成では効果が大きい"],
    ["11", "仮想ディスクの上限を決める (Windows 開発機)",
     "Docker Desktop\nSettings > Resources > Advanced",
     "Disk image size (Virtual disk limit) を必要量へ設定する",
     "ホストのディスクを Docker が無制限に食う事態を防ぐ",
     "上限を下げても既に伸びた vhdx は縮まない。縮小は 05 シートの手順が必要"],
]


def build_compose_sheet():
    sheet = Sheet("02_compose.yml側の対応", widths=[4, 24, 24, 50, 34, 38], freeze_rows=4)
    sheet.add_merged("compose.yml / 設定ファイル側の対応", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(
        "スクリプトを改修せず、設定だけで減らせるもの。#1〜#3 は『そもそも作らない・"
        "ローカルへ置かない』、#6〜#11 は『上限を決めて放っておく』対策",
        S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    add_table(sheet, COMPOSE_HEADER, COMPOSE_MEASURES, key_column=1, center_columns=(0,))

    sheet.add_section("現在の compose.yml (対策前) と、最小限の変更案")
    add_code_lines(
        sheet,
        "# 現状 (compose.yml, 25 行) — 対策に関わる指定は無い\n"
        "services:\n"
        "  base:\n"
        "    build:\n"
        "      context: .\n"
        "      dockerfile: Dockerfile\n"
        "      secrets:\n"
        "        - jboss_master_password\n"
        "    image: j1/base.local\n"
        "\n"
        "secrets:\n"
        "  jboss_master_password:\n"
        "    environment: JBOSS_MASTER_PASSWORD")
    sheet.add_blank(8.0)
    add_code_lines(
        sheet,
        "# 変更案 — ビルドだけを見る実行では bake で cacheonly、\n"
        "# 起動確認する実行では従来どおり docker compose build を使う\n"
        "services:\n"
        "  base:\n"
        "    build:\n"
        "      context: .\n"
        "      dockerfile: Dockerfile\n"
        "      pull: false                 # ベースイメージを無用に取り直さない (#5)\n"
        "      secrets:\n"
        "        - jboss_master_password\n"
        "      x-bake:\n"
        "        output:\n"
        "          - type=cacheonly        # bake 実行時だけ効く (#1)\n"
        "    image: j1/base.local\n"
        "    pull_policy: missing          # 起動時の再取得を避ける (#5)\n"
        "    logging:                      # ログの上限 (#7)\n"
        "      driver: json-file\n"
        "      options:\n"
        "        max-size: \"10m\"\n"
        "        max-file: \"3\"\n"
        "\n"
        "secrets:\n"
        "  jboss_master_password:\n"
        "    environment: JBOSS_MASTER_PASSWORD")
    sheet.add_blank(8.0)
    sheet.add_merged(
        "※ x-bake を足しても docker compose build の動作は変わりません "
        "(compose は x-bake を無視するため)。既存の実行方法をそのまま残したまま、"
        "bake 経由の『イメージを作らない検証』を追加できます。",
        S_NOTE, height=20.0)
    return sheet


# =============================================================================
# 03_スクリプト側の対応
# =============================================================================

SCRIPT_HEADER = [
    "#", "追加オプション案", "状態", "動作", "実装箇所 (build_and_verify.sh)", "削減対象", "注意",
]

SCRIPT_MEASURES = [
    ["1", "(既定で有効) 旧世代イメージの回収\n--no-reclaim-old-image で無効化",
     "実装済み",
     "ビルド直前に docker image inspect で j1/base.local の image ID を控え、"
     "ビルド成功後に ID が変わっていて、かつ旧 ID がどのタグからも参照されていなければ "
     "docker image rm <旧 ID> する",
     "remember_current_image_id(): 8874 行\nreclaim_previous_image(): 8884 行\n"
     "呼び出し: 12768 行 (ビルド前) と\nverify_local_image() 成功直後 (12815 / 12858 行)",
     "原因 #1\n(dangling イメージ 1 世代 / 回)",
     "docker image prune -f と違い、今回のビルドで世代交代した ID だけを消すため、"
     "同じ daemon を使う他プロジェクトの dangling に触れない。"
     "だからこそ既定 ON にできる。削除に失敗しても警告のみで続行し、終了コードは変えない"],
    ["2", "--down-rmi MODE\n--down-volumes",
     "未実装",
     "teardown_container() の compose down へ --rmi <MODE> / --volumes / --remove-orphans を付ける",
     "teardown_container(): 4529-4545 行\n(down_opts 配列を組み立てて 4538 / 4540 行の"
     " down へ渡す)",
     "原因 #1 #5 #6\n(検証で作ったイメージとボリューム)",
     "重要: compose.yml が image: j1/base.local を指定しているため --rmi local では消えない "
     "(local は image 指定の無いサービスが対象)。j1/base.local まで消すなら --rmi all。"
     "ただし --rmi all は pull したイメージ (mysql / wiremock 等) も消すので次回の再取得が発生する。"
     "ピンポイントに消すなら案 1 か docker image rm j1/base.local を使う"],
    ["3", "--prune-build-cache\n--prune-build-cache-keep SIZE",
     "実装済み",
     "終了処理でコンテナ削除の後に docker builder prune --force --all を実行する。"
     "SIZE 指定時は --keep-storage SIZE でその量まで残す",
     "prune_build_cache(): 8918 行\n呼び出し: cleanup_all() の\nteardown_container 直後 (12699 行)",
     "原因 #2 #3\n(ビルドキャッシュ)",
     "同じ daemon を使う他プロジェクトのキャッシュも消える。"
     "常設したいだけなら 02 シート #6 の daemon 設定の方が安全。"
     "--keep-storage を持たない buildx (0.17 以降は --max-used-space) では、"
     "docker builder prune --help で判定し、削除せず警告のみを出す。"
     "SIZE の書式は 10GB / 10G / 512MB / 1.5GB / バイト数のみ受け付ける (不正なら exit 2)"],
    ["4", "--build-output cacheonly",
     "未実装",
     "起動確認を伴わない『ビルドのみ』の実行で、docker compose build の代わりに "
     "docker buildx bake -f compose.yml --set '*.output=type=cacheonly' <サービス> を実行する",
     "ビルドセクション: 12751-12863 行\n"
     "verify_local_image(): 12773 行 (イメージが無い前提へ分岐が必要)",
     "原因 #1\n(イメージまるごと。dangling も発生しない)",
     "--verify-startup / --verify-url / --verify-jboss-password とは併用不可 "
     "(いずれもイメージを必要とする)。指定された場合はエラーで止めるか、自動で通常ビルドへ戻す。"
     "ビルドの成否だけを見る CI 用途に向く"],
    ["5", "--no-cache-stage NAME",
     "未実装",
     "--no-cache の代わりに、作り直したいステージだけを --no-cache-filter NAME で無効化する",
     "BUILD_OPTS の組み立て: 12756-12764 行",
     "原因 #1 #2\n(全レイヤ → 該当ステージ以降のみ)",
     "docker compose build に --no-cache-filter は無いため、bake 経由 "
     "(--set <サービス>.no-cache-filter=<ステージ>) が必要。"
     "『毎回まっさらから作り直したい』要件がベースイメージ更新の追随だけなら、"
     "この案で増加量を大きく減らせる"],
    ["6", "--disk-usage-report",
     "実装済み",
     "ビルド前と終了時に Docker 管理対象の使用量 (docker system df の合計) と "
     "data root の空き容量を取得し、実行前からの増減を表示する",
     "report_disk_usage(): 8949 行\nreport_disk_usage_at_exit(): 8980 行\n"
     "呼び出し: ビルド前 (12767 行) と\ncleanup_all() (12700 行)",
     "削減はしない (可視化)",
     "既存ヘルパ docker_storage_bytes() / format_bytes() / filesystem_free_bytes() を"
     "そのまま再利用している。--cleanup-all-docker-data が実際に削除を行った場合は、"
     "そちらが削除前後の容量を表示するため終了時の計測は行わない (二重表示の防止)。"
     "data root はローカル接続 (unix socket) のときだけ特定できる"],
    ["7", "--min-free-space SIZE",
     "未実装",
     "ビルド開始前に data root の空き容量を確認し、下回っていれば中止する "
     "(または --prune-build-cache を自動実行してから続行)",
     "ビルド直前: 12767 行付近\nfilesystem_free_bytes(): 8830 行",
     "予防 (ディスクフルによるビルド失敗を防ぐ)",
     "data root の特定は unix socket 接続時のみ行っている (実装済みの report_disk_usage も同様)。"
     "Windows の Git Bash + Docker Desktop では取得できないため、"
     "取得不可なら警告のみで続行する作りにする"],
    ["8", "プローブビルド後のキャッシュ回収",
     "未実装\n(案 3 で代替)",
     "--verify-jboss-password のプローブビルドが作ったキャッシュを、"
     "一時ディレクトリの削除と同じ場所で片付ける",
     "verify_jboss_password_build_secret(): 2116-2184 行\n"
     "(rm -rf -- \"$probe_dir\" と同じ位置)",
     "原因 #3",
     "そのビルドのキャッシュだけを狙って消す手段が無いため、"
     "実装済みの --prune-build-cache にまとめて任せている"],
    ["9", "--keep-image-generations N",
     "未実装",
     "j1/base.local の過去世代を N 個だけ残し、古いものから削除する",
     "案 1 と同じ位置 (12815 / 12858 行)",
     "原因 #1 (上限管理)",
     "N=1 で運用するなら実装済みの案 1 で足りる。"
     "『直前の世代と比較したい』要件があるときだけ意味がある"],
    ["10", "(既存) --cleanup-all-docker-data の位置付け",
     "実装済み\n(従来から)",
     "終了時に現在の Docker context の全データを削除する",
     "cleanup_all_docker_data(): 8988 行〜",
     "全部 (コンテナ / イメージ / ボリューム / キャッシュ)",
     "確認フレーズ DELETE ALL DOCKER DATA の入力が必須 (9024-9033 行) で、"
     "Docker 全体を空にするため毎回の検証には使えない。"
     "上記の細粒度オプションを日常運用に使い、これは『検証環境を完全に初期化するとき』に限る"],
]

SCRIPT_PRIORITY = [
    ("実装済み", "案 1 (旧世代イメージの回収・既定で有効)",
     "原因 #1 を根元から止める。他プロジェクトに影響しないため既定 ON。"
     "無効化は --no-reclaim-old-image"),
    ("実装済み", "案 3 (--prune-build-cache / --prune-build-cache-keep SIZE)",
     "原因 #2 の後始末。daemon 側 (02 シート #6) の上限設定で足りるなら、そちらだけでもよい"),
    ("実装済み", "案 6 (--disk-usage-report)",
     "効果を測れないまま対策を足しても判断できない。まずこれで実測する"),
    ("次の候補", "案 4 (--build-output cacheonly) / 案 5 (--no-cache-stage)",
     "『ビルドが通るかだけ見たい』『毎回まっさらにしたい理由がベース更新の追随だけ』"
     "という実行に効く。要件を確認してから入れる"),
    ("必要なら", "案 2 (--down-rmi / --down-volumes) / 案 7 (--min-free-space)",
     "起動確認まで行う実行と、ディスクが逼迫しやすい環境向け"),
]

SCRIPT_TESTS = [
    ("1", "既定でビルド前後の ID を突き合わせ、世代交代した旧イメージを削除する"),
    ("2", "--no-reclaim-old-image を指定すると旧イメージを残す (ID 取得自体を行わない)"),
    ("3", "旧 ID が別のタグから参照されている場合は dangling ではないため削除しない"),
    ("4", "ビルドしても ID が変わらなければ削除対象は無い"),
    ("5", "削除に失敗しても警告のみで、ビルド自体は成功のまま終える"),
    ("6", "--disk-usage-report が実行前後の使用量と増減を表示し、計測はビルドの前に行う"),
    ("7", "--prune-build-cache が容量指定なしで全削除する"),
    ("8", "--keep-storage を持たない buildx では削除せず警告に留める"),
    ("9", "--dry-run では削除を行わず、実行予定だけを表示する"),
    ("10", "--prune-build-cache-keep の書式チェック (不正なら exit 2)"),
    ("11", "--cleanup-all-docker-data 併用時は、削除前後の容量表示と重複させない"),
]


def build_script_sheet():
    sheet = Sheet("03_スクリプト側の対応", widths=[4, 24, 12, 36, 30, 18, 44], freeze_rows=4)
    sheet.add_merged("build_and_verify.sh 側の対応", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(
        "案 1 / 3 / 6 は 2026-08-05 に実装済み。既存の作り "
        "(EXIT トラップによる後始末・DRY-RUN 対応・log / warn ヘルパ) にそのまま載せてある。"
        "実装コードは 04 シート",
        S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    add_table(sheet, SCRIPT_HEADER, SCRIPT_MEASURES, key_column=1, center_columns=(0, 2))

    sheet.add_section("導入の状況と優先順位")
    sheet.add(header_row(["状態", "案", "理由"]))
    for order, name, reason in SCRIPT_PRIORITY:
        sheet.add([Cell(order, S_ON), Cell(name, S_KEY), Cell(reason, S_BODY)])

    sheet.add_section("追加したテストシナリオ (tests/build_and_verify_test.sh)")
    sheet.add(header_row(["#", "確認内容"]))
    for number, description in SCRIPT_TESTS:
        sheet.add([Cell(number, S_CENTER), Cell(description, S_BODY)])
    return sheet


# =============================================================================
# 04_実装コード例
# =============================================================================

CODE_BLOCKS = [
    ("(1) 既定値の追加  — 125-139 行の既定値セクションへ",
     "# ---- ディスク使用量の抑制 ---------------------------------------------------\n"
     "# ビルドはタグを新しいイメージへ付け替えるだけで、旧世代は <none>:<none> として\n"
     "# 残り続ける。--no-cache では共有レイヤが無いため、実行のたびにイメージ 1 個分が\n"
     "# そのまま積み上がる。既定で回収する。\n"
     "RECLAIM_OLD_IMAGE=\"true\"      # true: 世代交代した旧イメージを削除する\n"
     "PREVIOUS_IMAGE_ID=\"\"          # ビルド前の $LOCAL_IMAGE の image ID\n"
     "PRUNE_BUILD_CACHE=\"false\"     # true: 終了時にビルドキャッシュを削除する\n"
     "PRUNE_BUILD_CACHE_KEEP=\"\"     # 空: 全削除 / \"10GB\": その量まで残す\n"
     "DOWN_RMI=\"\"                   # \"\" / \"local\" / \"all\": compose down --rmi の指定\n"
     "DOWN_VOLUMES=\"false\"          # true: compose down --volumes (ボリュームも削除)\n"
     "DISK_USAGE_REPORT=\"false\"     # true: 実行前後の Docker 使用量を表示する\n"
     "DISK_USAGE_BEFORE=\"\"          # ビルド前の Docker 管理対象使用量 (bytes)"),

    ("(2) 引数パースの追加  — 950 行の while ループへ",
     "    --no-reclaim-old-image)   RECLAIM_OLD_IMAGE=\"false\"; shift ;;\n"
     "    --prune-build-cache)      PRUNE_BUILD_CACHE=\"true\"; shift ;;\n"
     "    --prune-build-cache-keep) need_value \"$1\" $#; PRUNE_BUILD_CACHE=\"true\"\n"
     "                              PRUNE_BUILD_CACHE_KEEP=\"$2\"; shift 2 ;;\n"
     "    --down-rmi)               need_value \"$1\" $#; DOWN_RMI=\"$2\"; shift 2 ;;\n"
     "    --down-volumes)           DOWN_VOLUMES=\"true\"; shift ;;\n"
     "    --disk-usage-report)      DISK_USAGE_REPORT=\"true\"; shift ;;"),

    ("(3) 旧世代イメージの回収  — 新しい関数 (verify_local_image の手前あたり)",
     "# ---- 旧世代イメージの回収 ---------------------------------------------------\n"
     "# docker image prune -f と違い、今回のビルドで世代交代した ID だけを消す。\n"
     "# 同じ Docker daemon を使う他プロジェクトの dangling には触れない。\n"
     "remember_current_image_id() {\n"
     "  [ \"$RECLAIM_OLD_IMAGE\" = \"true\" ] || return 0\n"
     "  PREVIOUS_IMAGE_ID=\"$(docker image inspect --format '{{.Id}}' \"$LOCAL_IMAGE\" \\\n"
     "                        2>/dev/null || true)\"\n"
     "}\n"
     "\n"
     "reclaim_previous_image() {\n"
     "  [ \"$RECLAIM_OLD_IMAGE\" = \"true\" ] || return 0\n"
     "  [ \"$DRY_RUN\" = \"true\" ] && { log \"[DRY-RUN] 旧世代イメージの回収をスキップします。\"; return 0; }\n"
     "  [ -n \"$PREVIOUS_IMAGE_ID\" ] || return 0\n"
     "\n"
     "  local current tags\n"
     "  current=\"$(docker image inspect --format '{{.Id}}' \"$LOCAL_IMAGE\" 2>/dev/null || true)\"\n"
     "  # ID が変わっていなければ (キャッシュ完全ヒット等) 消す対象は無い\n"
     "  [ -n \"$current\" ] && [ \"$current\" != \"$PREVIOUS_IMAGE_ID\" ] || return 0\n"
     "\n"
     "  # 旧 ID が別のタグから参照されている場合は dangling ではないため触らない\n"
     "  tags=\"$(docker image inspect --format '{{len .RepoTags}}' \"$PREVIOUS_IMAGE_ID\" \\\n"
     "           2>/dev/null || printf '0')\"\n"
     "  if [ \"$tags\" != \"0\" ]; then\n"
     "    log \"旧世代イメージは別のタグから参照されているため残します: $PREVIOUS_IMAGE_ID\"\n"
     "    return 0\n"
     "  fi\n"
     "\n"
     "  log \"世代交代した旧イメージを削除します: $PREVIOUS_IMAGE_ID\"\n"
     "  docker image rm \"$PREVIOUS_IMAGE_ID\" >/dev/null 2>&1 \\\n"
     "    || warn \"旧イメージを削除できませんでした (使用中の可能性があります): $PREVIOUS_IMAGE_ID\"\n"
     "}"),

    ("(4) 回収の呼び出し  — ビルドセクション (12751-12863 行)",
     "# BUILD_OPTS を組み立てる直前 (12559 行付近)\n"
     "remember_current_image_id\n"
     "\n"
     "# verify_local_image が成功した直後 (12602 行 / 12644 行の 2 か所)\n"
     "if ! verify_local_image; then\n"
     "  exit 1\n"
     "fi\n"
     "reclaim_previous_image"),

    ("(5) compose down のオプション化  — teardown_container() (4529-4545 行)",
     "teardown_container() {\n"
     "  [ \"$STARTED_CONTAINER\" = \"true\" ] || return 0\n"
     "  if [ \"$KEEP_CONTAINER\" = \"true\" ]; then\n"
     "    log \"コンテナを残します (--keep-container)。手動で停止する場合: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down\"\n"
     "    return 0\n"
     "  fi\n"
     "\n"
     "  # イメージ / ボリュームまで消すかは指定に従う。\n"
     "  # 注意: compose.yml が image: を指定しているサービスは --rmi local では消えない。\n"
     "  local -a down_opts=()\n"
     "  [ -n \"$DOWN_RMI\" ] && down_opts+=(--rmi \"$DOWN_RMI\")\n"
     "  [ \"$DOWN_VOLUMES\" = \"true\" ] && down_opts+=(--volumes)\n"
     "\n"
     "  log \"コンテナを停止・削除します (compose down ${down_opts[*]:-}) ...\"\n"
     "  local down_ok=0\n"
     "  if [ \"$SUPPRESS_REMOVED_LOGS\" = \"true\" ] && [ \"$DRY_RUN\" != \"true\" ]; then\n"
     "    \"${COMPOSE_CMD[@]}\" -f \"$COMPOSE_FILE\" down \\\n"
     "      ${down_opts[@]+\"${down_opts[@]}\"} > /dev/null 2>&1 || down_ok=$?\n"
     "  else\n"
     "    run \"${COMPOSE_CMD[@]}\" -f \"$COMPOSE_FILE\" down \\\n"
     "      ${down_opts[@]+\"${down_opts[@]}\"} || down_ok=$?\n"
     "  fi\n"
     "  if [ \"$down_ok\" -ne 0 ]; then\n"
     "    warn \"コンテナの停止・削除に失敗しました。手動で確認してください: ${COMPOSE_CMD[*]} -f $COMPOSE_FILE down\"\n"
     "  fi\n"
     "}"),

    ("(6) 終了時のビルドキャッシュ削除  — cleanup_all() (12475-12516 行) から呼ぶ",
     "prune_build_cache() {\n"
     "  [ \"$PRUNE_BUILD_CACHE\" = \"true\" ] || return 0\n"
     "  local -a prune_opts=(--force)\n"
     "  if [ -n \"$PRUNE_BUILD_CACHE_KEEP\" ]; then\n"
     "    # buildx 0.17 以降は --max-used-space が後継。環境の docker builder prune --help で確認する\n"
     "    prune_opts+=(--keep-storage \"$PRUNE_BUILD_CACHE_KEEP\")\n"
     "  else\n"
     "    prune_opts+=(--all)\n"
     "  fi\n"
     "  if [ \"$DRY_RUN\" = \"true\" ]; then\n"
     "    log \"[DRY-RUN] docker builder prune ${prune_opts[*]}\"\n"
     "    return 0\n"
     "  fi\n"
     "  log \"ビルドキャッシュを削除します: docker builder prune ${prune_opts[*]} ...\"\n"
     "  docker builder prune \"${prune_opts[@]}\" >/dev/null 2>&1 \\\n"
     "    || warn \"ビルドキャッシュの削除に失敗しました。\"\n"
     "}\n"
     "\n"
     "# cleanup_all() の中、teardown_container の直後へ:\n"
     "#   teardown_container\n"
     "#   prune_build_cache\n"
     "#   report_disk_usage \"終了時\"\n"
     "#   cleanup_copied_files"),

    ("(7) 容量レポート  — 既存ヘルパの再利用のみ",
     "# docker_storage_bytes() (8645 行) / format_bytes() (8662 行) /\n"
     "# filesystem_free_bytes() (8762 行) をそのまま使う。\n"
     "report_disk_usage() {\n"
     "  [ \"$DISK_USAGE_REPORT\" = \"true\" ] || return 0\n"
     "  local label=\"$1\" now delta sign root free\n"
     "  now=\"$(docker_storage_bytes 2>/dev/null || true)\"\n"
     "  [ -n \"$now\" ] || { warn \"Docker 使用量を取得できませんでした (${label})。\"; return 0; }\n"
     "  log \"Docker 使用量 (${label}): $(format_bytes \"$now\")\"\n"
     "  if [ -n \"$DISK_USAGE_BEFORE\" ]; then\n"
     "    delta=$(( now - DISK_USAGE_BEFORE ))\n"
     "    sign=\"+\"\n"
     "    if [ \"$delta\" -lt 0 ]; then sign=\"-\"; delta=$(( -delta )); fi\n"
     "    log \"  実行前からの増減: ${sign}$(format_bytes \"$delta\")\"\n"
     "  fi\n"
     "  # data root はローカル接続 (unix socket) のときだけ特定できる (8845-8847 行と同じ条件)\n"
     "  root=\"$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)\"\n"
     "  if [ -n \"$root\" ] && free=\"$(filesystem_free_bytes \"$root\" 2>/dev/null)\"; then\n"
     "    log \"  data root の空き容量: $(format_bytes \"$free\") ($root)\"\n"
     "  fi\n"
     "}\n"
     "\n"
     "# ビルド開始直前で基準を取る:\n"
     "#   DISK_USAGE_BEFORE=\"$(docker_storage_bytes 2>/dev/null || true)\"\n"
     "#   report_disk_usage \"ビルド前\""),

    ("(8) ビルドのみの実行でイメージを作らない  — 案 4 の骨子 (12751-12863 行)",
     "# 起動確認もシークレット検証も行わない実行に限り、イメージを作らずビルドだけ検証する。\n"
     "# bake は compose.yml の x-bake を読むため、compose.yml 側に output: type=cacheonly を\n"
     "# 書いておくか、ここで --set により上書きする。\n"
     "if [ \"$BUILD_OUTPUT\" = \"cacheonly\" ]; then\n"
     "  if [ \"$NEED_CONTAINER\" = \"true\" ] || [ \"$VERIFY_JBOSS_PASSWORD\" = \"true\" ]; then\n"
     "    err \"--build-output cacheonly は起動確認・シークレット検証と併用できません\"\n"
     "    exit 2\n"
     "  fi\n"
     "  log \"イメージを生成せずにビルドのみ検証します (--build-output cacheonly) ...\"\n"
     "  if ! run docker buildx bake -f \"$COMPOSE_FILE\" \\\n"
     "        --set '*.output=type=cacheonly' \\\n"
     "        ${BUILD_OPTS[@]+\"${BUILD_OPTS[@]}\"} \\\n"
     "        ${COMPOSE_SERVICES[@]+\"${COMPOSE_SERVICES[@]}\"}; then\n"
     "    BUILD_RESULT_STATUS=\"失敗\"\n"
     "    BUILD_RESULT_DETAIL=\"bake (cacheonly) でのビルドに失敗しました。\"\n"
     "    err \"ビルドに失敗しました\"\n"
     "    exit 1\n"
     "  fi\n"
     "  BUILD_RESULT_STATUS=\"成功\"\n"
     "  BUILD_RESULT_DETAIL=\"イメージを生成しないビルド検証が完了しました。\"\n"
     "  # イメージを作らないため verify_local_image は呼ばない\n"
     "else\n"
     "  # 従来どおりの docker compose build\n"
     "  :\n"
     "fi"),
]

CODE_NOTES = [
    "既存スクリプトの作法に合わせてある: 配列展開は set -u 対策の "
    "${arr[@]+\"${arr[@]}\"} 形式、失敗は err ではなく warn で握って続行、"
    "DRY_RUN では実行せず [DRY-RUN] のログだけを出す。",
    "追加した処理は必ず EXIT トラップ (trap cleanup_all EXIT / 12518 行) の経路へ入れる。"
    "途中で exit する経路が多いスクリプトのため、ビルド後の任意の位置に置くと実行されないことがある。",
    "テストは tests/build_and_verify_test.sh に追加する。"
    "tests/helpers/docker の fake が呼び出しを記録するので、"
    "assert_contains \"$FAKE_DOCKER_CALLS\" \"image rm\" のように検証できる "
    "(既存の prune 系アサーションが 1397 / 1423-1427 行にある)。",
    "スイートは Windows + Git Bash で 10 分前後かかる。"
    "実行中に build_and_verify.sh を編集すると、bash が読み進めている途中のファイルが変わり"
    "偽の構文エラーになるため、編集を終えてから流すこと。",
]


def build_code_sheet():
    # 1 列だと mergeCell が A5:A5 のような単一セル範囲になり Excel が修復を促すため、
    # 2 列に分けて結合する。
    sheet = Sheet("04_実装コード例", widths=[60, 52])
    sheet.add_merged("実装コード例 (bash)", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(
        "(1)〜(7) は案 1 / 3 / 6 として build_and_verify.sh へ実装済み — "
        "実際のコードは 03 シートの行番号を参照。(8) は未実装の案 4 の骨子。"
        "行番号は 2026-08-05 時点の build_and_verify.sh を指す",
        S_NOTE, height=20.0)

    for heading, code in CODE_BLOCKS:
        sheet.add_section(heading)
        add_code_lines(sheet, code)

    sheet.add_section("実装時の注意")
    for note in CODE_NOTES:
        sheet.add_merged(note, S_BODY)
    return sheet


# =============================================================================
# 05_運用コマンド
# =============================================================================

OPERATION_HEADER = ["#", "目的", "コマンド", "説明・注意"]

OPERATIONS = [
    ["1", "現状把握 (まずこれ)",
     "docker system df -v",
     "イメージ / コンテナ / ボリューム / ビルドキャッシュの内訳と、"
     "再利用可能な容量 (RECLAIMABLE) が出る。対策の前後で必ず比較する"],
    ["2", "ビルドキャッシュの内訳",
     "docker builder du --verbose",
     "どのステップのキャッシュが容量を食っているかが分かる。"
     "--no-cache を繰り返した後は同じ内容のレコードが並ぶ"],
    ["3", "dangling イメージだけ削除 (毎回)",
     "docker image prune --force",
     "タグを失ったイメージだけを消す。タグの付いたイメージには触れない。"
     "ただし同じ daemon を使う他プロジェクトの dangling も消える"],
    ["4", "今回のイメージだけ削除",
     "docker image rm j1/base.local",
     "検証が終わってイメージが不要なときの最短手。"
     "コンテナが使用中だと失敗するので compose down の後に実行する"],
    ["5", "ビルドキャッシュを上限まで削減 (週次)",
     "docker builder prune --force --keep-storage 10GB",
     "10GB を超えた分だけ古い順に消す。"
     "buildx 0.17 以降は --keep-storage が非推奨 (--max-used-space)。"
     "手元の docker builder prune --help で確認する"],
    ["6", "古いキャッシュだけ削除",
     "docker builder prune --force --filter until=24h",
     "24 時間以上使われていないキャッシュだけを消す。"
     "他プロジェクトへの影響を抑えたいときはこちら"],
    ["7", "検証専用ビルダーを使い捨てる",
     "docker buildx create --name j1-verify --driver docker-container\n"
     "docker compose build --builder j1-verify\n"
     "#  ... 検証 ...\n"
     "docker buildx rm j1-verify",
     "docker-container ドライバのキャッシュはビルダー専用のボリュームに入るため、"
     "ビルダーごと消せば確実にゼロへ戻る。"
     "既定ビルダーのキャッシュ (他プロジェクト分) を巻き込まないのが利点。"
     "ただしビルド結果をローカルへ持ってくるには --load が要り、その分は image ストアに入る"],
    ["8", "イメージを作らずビルドだけ確認",
     "docker buildx bake -f compose.yml --set '*.output=type=cacheonly' base",
     "イメージストアに何も書かないため dangling が出ない。"
     "起動確認をしない検証ならこれが最も容量を使わない。"
     "JBOSS_MASTER_PASSWORD の export は compose build のときと同じく必要"],
    ["9", "停止コンテナ / ボリュームの回収",
     "docker container prune --force\ndocker volume prune --force",
     "--keep-container やデプロイエラー時の対話モードで残ったコンテナと、"
     "compose down -v を付けずに残ったボリュームを回収する"],
    ["10", "検証 1 回分をまとめて後始末 (改修前の現実解)",
     "bash build_and_verify.sh --no-cache ... ;\\\n"
     "  docker compose -f compose.yml down --volumes ;\\\n"
     "  docker image prune --force ;\\\n"
     "  docker builder prune --force --keep-storage 10GB",
     "スクリプトを改修しなくても、実行のたびにこの 3 行を足せば増分はほぼ戻る。"
     "03 シートの案 1 / 2 / 3 は、これをスクリプトへ取り込むもの"],
    ["11", "Windows (WSL2) で仮想ディスクを縮める",
     "wsl --shutdown\n"
     "wsl --manage docker-desktop-data --set-sparse true\n"
     "#  または Hyper-V の PowerShell モジュールで:\n"
     "Optimize-VHD -Path <docker_data.vhdx のパス> -Mode Full",
     "prune しただけではホストの空き容量は戻らない (Docker 内部の空きとして再利用されるだけ)。"
     "Docker Desktop の版によって vhdx の場所と対応可否が変わるため、"
     "実行前に Docker Desktop を終了し、対象ファイルのパスを確認すること"],
    ["12", "RHEL 9 で data root の内訳を見る",
     "sudo du -sh /var/lib/docker/*\ndf -h /var/lib/docker",
     "overlay2 / buildkit / containers / volumes のどれが膨らんでいるかを切り分ける。"
     "検証機なら /var/lib/docker を別ボリュームにしておくと、root ファイルシステムを守れる"],
    ["13", "全消し (最終手段)",
     "bash build_and_verify.sh --cleanup-all-docker-data ...\n"
     "#  スクリプトを介さない場合:\n"
     "docker system prune --all --volumes",
     "現在の Docker context を空にする。スクリプト経由なら確認フレーズ "
     "DELETE ALL DOCKER DATA の入力が必須で、削除前後の容量も表示される。"
     "同じ daemon を使う他プロジェクトも巻き込むため、日常運用には使わない"],
]


def build_operation_sheet():
    sheet = Sheet("05_運用コマンド", widths=[4, 26, 56, 52],
                  freeze_rows=4, autofilter_row=4, autofilter_cols=4)
    sheet.add_merged("スクリプトを改修せずに使える運用コマンド", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(
        "#10 が『今日からできる現実解』。まず #1 で現状を測り、#10 を実行後の手順に足すところから始める",
        S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    add_table(sheet, OPERATION_HEADER, OPERATIONS, key_column=1, center_columns=(0,))
    return sheet


# =============================================================================
# 06_施策比較と推奨構成
# =============================================================================

COMPARE_HEADER = [
    "#", "施策", "区分", "1 回あたりの削減目安", "導入の手間", "リスク・副作用", "推奨度",
]

COMPARISONS = [
    ["1", "世代交代した旧イメージの回収 (03 案 1)", "スクリプト\n(実装済み)",
     "イメージ 1 個分 / 回 (--no-cache 時は最大)",
     "済 (既定 ON)",
     "ほぼ無し。今回のビルドで世代交代した ID しか消さないため他プロジェクトに影響しない",
     "◎ 既定 ON"],
    ["2", "ビルドキャッシュの上限設定 (02 #6 / 03 案 3)", "設定 / スクリプト\n(実装済み)",
     "上限超過分すべて",
     "小 (daemon.json 1 か所)",
     "上限に達するまで効かない。プロジェクト共通の設定になる",
     "◎"],
    ["3", "イメージを作らないビルド検証 (02 #1 / 03 案 4)", "compose / スクリプト",
     "イメージ 1 個分 / 回 (dangling が発生しない)",
     "中 (bake 経路の追加)",
     "起動確認・シークレット検証と併用できない。実行方法が 2 系統になる",
     "○ ビルド確認のみの実行に"],
    ["4", "キャッシュをレジストリ / 外部へ逃がす (02 #2 #3)", "compose",
     "ビルドキャッシュ全量 (data root から出る)",
     "中 (ビルダーの作成が必要)",
     "docker-container ドライバが前提。レジストリ側の容量と push / pull の時間がかかる",
     "○ CI / 共有環境に"],
    ["5", "--no-cache をステージ単位へ絞る (03 案 5)", "スクリプト",
     "全レイヤ → 該当ステージ以降のみ",
     "中 (bake 経路の追加)",
     "『毎回まっさらから』の要件を満たさなくなる場合がある。要件確認が要る",
     "○ 要件次第"],
    ["6", "compose down --volumes / --rmi (03 案 2)", "スクリプト",
     "ボリュームと、検証で作ったイメージ",
     "小",
     "--rmi all は pull 済みイメージも消すため次回の再取得が発生する。"
     "--rmi local では image: 指定のあるサービスは消えない",
     "○ 起動確認する実行に"],
    ["7", "容量レポート (03 案 6)", "スクリプト\n(実装済み)",
     "0 (可視化のみ)",
     "済 (--disk-usage-report)",
     "無し",
     "◎ まず実測する"],
    ["8", "コンテナログの上限 (02 #7)", "compose",
     "コンテナを残す運用でのログ増加分",
     "小",
     "過去ログをさかのぼれる範囲が狭まる",
     "○"],
    ["9", "コンテキストの削減 (.dockerignore) (02 #10)", "設定",
     "イメージ本体とキャッシュの両方 (構成次第)",
     "小",
     "ビルドに必要なファイルを除外すると失敗する",
     "○"],
    ["10", "docker system prune --all --volumes / --cleanup-all-docker-data", "運用",
     "全量 (ゼロへ戻る)",
     "小",
     "他プロジェクトを巻き込む。次回のビルドがフルになり時間がかかる。"
     "スクリプト経由は確認フレーズの入力が必須で自動化できない",
     "△ 初期化時のみ"],
]

RECOMMENDED = [
    ("A. 最小構成 — 改修版を使えない場合 (旧版のスクリプトなど)",
     "検証の実行方法は変えず、後始末のコマンドと daemon の上限だけを足す。"
     "スクリプトへ手を入れられない状況でも、増分をほぼ元へ戻せる。",
     "# 1) daemon.json に上限を入れる (一度だけ)\n"
     "{ \"builder\": { \"gc\": { \"enabled\": true, \"defaultKeepStorage\": \"10GB\" } } }\n"
     "\n"
     "# 2) 実行のたびに後始末する\n"
     "bash build_and_verify.sh --no-cache <従来のオプション>\n"
     "docker compose -f compose.yml down --volumes\n"
     "docker image prune --force\n"
     "docker builder prune --force --keep-storage 10GB"),
    ("B. 標準構成 — 実装済み (推奨・日常の検証はこれ)",
     "03 シートの案 1 / 3 / 6 を実装済み。旧イメージの回収は既定で有効なので、"
     "利用者がオプションを意識しなくても世代は積み上がらない。",
     "bash build_and_verify.sh --no-cache \\\n"
     "  --verify-startup \\\n"
     "  --disk-usage-report \\\n"
     "  --prune-build-cache-keep 10GB\n"
     "\n"
     "#  旧イメージの回収は既定で有効 (無効化は --no-reclaim-old-image)\n"
     "#  使用量の増減だけ先に測るなら:\n"
     "bash build_and_verify.sh --no-cache --disk-usage-report"),
    ("C. 徹底構成 — ローカルに何も残さない",
     "『ビルドが通るか』だけを確認する CI / 定期実行向け。"
     "イメージはイメージストアへ書かれず、キャッシュもレジストリ側に置かれるため、"
     "ローカル data root はほとんど増えない。",
     "# 一度だけ: 使い捨てビルダーを作る\n"
     "docker buildx create --name j1-verify --driver docker-container\n"
     "\n"
     "# 検証: イメージを作らず、キャッシュはレジストリへ\n"
     "docker buildx bake -f compose.yml \\\n"
     "  --builder j1-verify \\\n"
     "  --set '*.output=type=cacheonly' \\\n"
     "  --set '*.cache-to=type=registry,ref=<acct>.dkr.ecr.ap-northeast-1.amazonaws.com/"
     "j1/base-cache:main,mode=min,image-manifest=true,oci-mediatypes=true' \\\n"
     "  base\n"
     "\n"
     "# 後始末: ビルダーごと捨てる\n"
     "docker buildx rm j1-verify"),
]

FINAL_NOTES = [
    ("削減量は必ず実測する",
     "本資料の『1 回あたりの削減目安』は構成から求めた値で、実測値ではありません。"
     "実装済みの --disk-usage-report、または docker system df / docker builder du を"
     "対策の前後で比較し、自分の環境の数字で判断してください。"),
    ("--no-cache が本当に必要かを見直す",
     "『前回のローカル状態に依存しない検証がしたい』のであれば、"
     "キャッシュをレジストリ / 外部ディレクトリへ逃がす (02 #2 #3) か、"
     "作り直したいステージだけ --no-cache-filter で無効化する (03 案 5) 方が、"
     "同じ目的をローカル容量を使わずに満たせます。"),
    ("イメージ自体を小さくする (Dockerfile 側)",
     "マルチステージ化して最終ステージへ成果物だけを COPY する、"
     "パッケージ導入と dnf clean all を同一 RUN にまとめる、"
     "パッケージキャッシュは RUN --mount=type=cache へ逃がす (レイヤに残らず prune できる) — "
     "これらはイメージ 1 個分の大きさを直接下げるため、"
     "本資料のどの対策とも掛け算で効きます。"),
]


def build_comparison_sheet():
    sheet = Sheet("06_施策比較と推奨構成", widths=[4, 34, 14, 28, 16, 40, 12], freeze_rows=4)
    sheet.add_merged("施策の比較と、用途別の推奨構成", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(
        "推奨度 ◎ = まず入れる / ○ = 用途が合えば入れる / △ = 限定的に使う",
        S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    add_table(sheet, COMPARE_HEADER, COMPARISONS, key_column=1, center_columns=(0, 2, 4, 6))

    sheet.add_section("推奨構成 (3 パターン)")
    for title, description, command in RECOMMENDED:
        sheet.add_merged(title, S_ACCENT)
        sheet.add_merged(description, S_BODY)
        add_code_lines(sheet, command)
        sheet.add_blank(8.0)

    sheet.add_section("最後に")
    sheet.add(header_row(["項目", "内容"]))
    for label, value in FINAL_NOTES:
        sheet.add([Cell(label, S_KEY), Cell(value, S_BODY)])
    return sheet


# =============================================================================
# エントリポイント
# =============================================================================

def build_workbook(out_path):
    generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    sheets = [
        build_cover_sheet(generated),
        build_cause_sheet(),
        build_compose_sheet(),
        build_script_sheet(),
        build_code_sheet(),
        build_operation_sheet(),
        build_comparison_sheet(),
    ]
    write_xlsx(out_path, sheets, TITLE, "generate_disk_usage_xlsx.py")
    return out_path


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    out_path = argv[1] if len(argv) > 1 else os.path.join(here, DEFAULT_OUTPUT)
    build_workbook(out_path)
    print("生成しました: %s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
