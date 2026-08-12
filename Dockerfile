# ベースイメージのサンプル。実際のベースイメージ内容に置き換えてください。
FROM public.ecr.aws/docker/library/alpine:3.20

LABEL org.opencontainers.image.title="j1/base.local"

# 例: 共通で入れておきたいパッケージなど
RUN apk add --no-cache ca-certificates

# 例: JBoss のマスターパスワードを BuildKit シークレットとして参照する場合。
# シークレットはビルド中のみ /run/secrets/<id> にマウントされ、イメージの
# レイヤ・履歴・環境変数には残らない。id は compose 版は compose.yml の secrets 名、
# buildx 版は --jboss-secret-id (既定: jboss_master_password) と一致させる。
#
# パスワードに $ # " ` \ 等が含まれると、シェル・jboss-cli・standalone.xml の
# それぞれで意味を持つため、途中で値が変わることがある。
#   - "$(cat ...)" はコマンド置換のため、値の末尾の改行が落ちる
#     (末尾に改行を含むパスワードでは CredentialStore の作成と検証で値がずれる)
#   - 変数は必ず二重引用符で囲む (囲まないと空白での分割と # 以降の切り捨てが起きる)
#   - jboss-cli で standalone.xml へ書き込む際、リテラルの $ は $$ へエスケープする
#     (WildFly は ${...} を式として起動時に解決するため)
# 設定後の値が原本と一致しているかは、build_and_verify.sh --verify-jboss-password で
# 段ごとに突き合わせて確認できる。
#
# RUN --mount=type=secret,id=jboss_master_password \
#     /opt/jboss/bin/setup-credential-store.sh "$(cat /run/secrets/jboss_master_password)"

# 例: 提供元ごとの CA 証明書を BuildKit シークレットとして受け取る場合。
# compose 版 / buildx 版とも --cacert-dir で指定したディレクトリ群
# (例: secrets/extraslb, secrets/others1, secrets/others2) の cacert.crt を
# 1 つの tar へまとめ、シークレット (既定 id: cacerts) として渡す。
# BuildKit のシークレットはディレクトリをマウントできないため tar 1 ファイルで
# 受け取り、展開と提供元の列挙はここ (ビルドコンテナ側) で行う。これにより
# **提供元が増えてもこの Dockerfile とビルドコマンドは変更不要**になる。
# tar の中身は <提供元名>/<ファイル名> (例: extraslb/cacert.crt)。
# シークレットはビルド中のみマウントされ、イメージのレイヤ・履歴には残らない。
#
# RUN --mount=type=secret,id=cacerts \
#     mkdir -p /tmp/cacerts && \
#     tar -xf /run/secrets/cacerts -C /tmp/cacerts && \
#     for cert in /tmp/cacerts/*/*; do \
#         [ -f "$cert" ] || continue; \
#         alias_name="$(basename "$(dirname "$cert")")-$(basename "$cert")"; \
#         cp "$cert" "/usr/local/share/ca-certificates/${alias_name}.crt"; \
#     done && \
#     update-ca-certificates && \
#     rm -rf /tmp/cacerts
#
# ※ tar の展開にはイメージ内の tar が必要。*-minimal 系のベースイメージへ
#    差し替える場合は tar を導入すること。

CMD ["/bin/sh"]
