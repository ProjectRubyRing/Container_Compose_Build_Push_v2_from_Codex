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

CMD ["/bin/sh"]
