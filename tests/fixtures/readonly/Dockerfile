# 読み取り専用ファイルシステム分析のテスト用 Dockerfile。
# ビルド段階で書き込むディレクトリと、実行段階 (entrypoint.sh) で書き込む
# ディレクトリを分けて判定できるかを確認するために使う。
#   - /opt/appconfig    : ビルド時にだけ書き込む → read_only: true でも問題なし
#   - /var/lib/appstate : entrypoint.sh が起動のたびに作る → 書き込み先が要る
#   - /var/log/app      : entrypoint.sh が起動のたびに書く → 書き込み先が要る
FROM registry.example.com/jboss-eap:8.1

ENV JBOSS_HOME=/opt/jboss-eap

# ビルド時の書き込み。イメージのレイヤへ焼き込まれるため、実行時は読むだけになる。
RUN mkdir -p /opt/appconfig \
    && echo "built" > /opt/appconfig/build.stamp \
    && chown -R jboss:root /opt/appconfig

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/opt/jboss-eap/bin/standalone.sh"]
