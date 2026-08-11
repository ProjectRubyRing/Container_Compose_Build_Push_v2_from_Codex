#!/bin/sh
# ベースイメージ側にだけ入っている起動スクリプトの代役。
# ビルドコンテキストには無いため、実行中のコンテナから読めるかどうかを確認する。
mkdir -p /opt/jboss-eap/standalone/boot-work
exec java -jar /opt/app.jar
