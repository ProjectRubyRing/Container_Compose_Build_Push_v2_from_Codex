#!/usr/bin/env bash
#
# 別プロジェクト Docker_usage_check の docker-usage-check.sh の代役。
#
# build_and_verify.sh は対話操作をすべて終えたときに、このスクリプトを
# --clean all --force で呼び出して未使用リソースを完全クリアする。テストでは
# 実際に削除するわけにいかないため、引数を記録して定型の出力を返すだけにする。
#   FAKE_USAGE_CHECK_CALLS : 呼び出し引数の記録先
#   FAKE_USAGE_CHECK_FAIL  : true でクリーンアップ失敗 (exit 1) を再現する
set -uo pipefail

if [ -n "${FAKE_USAGE_CHECK_CALLS:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_USAGE_CHECK_CALLS"
fi

if [ "${FAKE_USAGE_CHECK_FAIL:-false}" = "true" ]; then
  printf 'fake docker-usage-check: docker コマンドがエラーを返しました。\n' >&2
  exit 1
fi

printf '\n'
printf '==============================================================================\n'
printf '  クリーンアップ: all\n'
printf '==============================================================================\n'
printf '  内容 : 未使用リソースを完全クリアします (未使用イメージ・ボリューム含む)\n'
printf '  実行 : docker system prune -a --volumes -f\n'
printf '\n'
printf '  完了。使用量: 3.05GB → 0B  (削減: 3.05GB)\n'
exit 0
