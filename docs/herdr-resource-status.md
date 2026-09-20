# Herdr のホスト資源・Codex lease 表示

`herdr-codex-status` は、既存の選択中 Codex セッション情報の末尾に次を表示する。

```
... | host cpu:18% mem:9.4/31.2G (30%) | agents:2 (稼働:1) | lease:2/3
```

- `cpu` は `/proc/stat` の前回値との差分、`mem` は `/proc/meminfo` の `MemAvailable` から算出するホスト全体の使用量である。CPU の初回だけは比較元がないため `cpu:—` とする。
- `agents` は Herdr snapshot にある、`unknown` ではない一意の Codex session 数で、括弧内は `working` 数である。これは Codex の実際のサービス側 lease/課金 API ではなく、同時に lease を消費しうる Herdr 管理セッションの保守的な可視化である。
- `lease:N/L` の `L` は既定で 3。`HERDR_CODEX_LEASE_LIMIT` を正の整数で設定すれば変更でき、`N >= L` は `⚠` を付ける。警告は作業者に新規 delegate を増やさず完了・待機中 agent を整理する判断を促すもので、agent や pane を自動停止しない。

表示コマンドは既存どおり 5 秒間隔・1 秒 timeout であり、毎回の追加コストは小さな Herdr snapshot、`/proc/stat`、`/proc/meminfo` の読み取りだけである。CPU 使用率は `XDG_CACHE_HOME/herdr-codex-status/cpu.json`（既定 `~/.cache`）に 2 個のカウンタだけを保存する。プロセス一覧、cgroup 全走査、ネットワーク照会は行わない。既存の transcript 後方読み取りも維持する。

この表示は Linux `/proc` を前提とする。`/proc` やキャッシュが読めない環境では該当値を `—` にして、ステータス表示自体は継続する。
