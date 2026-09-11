# Codex 設定

`config.toml` には、移植可能かつ非機密なユーザー既定値だけを含めます。

以下のローカルファイルは Git 管理しません。

- `auth.json`、すべてのトークン、API キー
- Herdr/Codex が生成する `hooks.json`、`herdr-agent-state.sh`、`[hooks.state]` のエントリー
- セッション、ログ、SQLite データベース、キャッシュ、信頼済みプロジェクトのパス

新しい端末では `codex login` を実行してから、`herdr integration install codex`
で Herdr 連携を導入します。両コマンドが利用可能なら、bootstrap がこの処理を自動で行います。

Google Search Console MCP はマシン固有のサービスアカウント鍵を必要とするため、
意図的に含めていません。鍵をリポジトリ外へ安全に保管したうえで、
`~/.codex/config.toml` に手動で追加してください。
