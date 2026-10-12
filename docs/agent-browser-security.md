# Agent browser guard

Windows Chrome の専用 profile と、TradingView のチャートだけを扱う固定操作 bridge。
launcher は process 単位の `ExecutionPolicy Bypass` を指定する。Windows の永続 execution policy は変更しない。
通常 Chrome の 9222 には接続せず、`%LOCALAPPDATA%\AgentBrowser\TradingView\Profile` の 9333 に接続する。
既存 profile の Cookie、credential、session はコピーしない。専用ウィンドウへユーザーがログインする。

`agent-browser-guard start` で専用 Chrome を起動し、`status` でチャート数を確認する。
`serve` は接続を維持し、stdin の JSON Lines を受け取る。許可する例は `{"action":"snapshot"}`。
固定操作は `snapshot`、strategy の `settings`、開いている dialog の `parameters` / `properties` の読み取り。
`bootstrap_inventory` は chart/editor 関連のボタン属性、入力領域の属性、Monaco API の存在だけを読み取る。
editor のコード、textarea の値、Cookie、storage の内容は取得しない。bootstrap の UI 操作実装前に実 DOM の根拠を得る用途である。
`bootstrap_editor_inspect` は可視 Pine editor の冒頭 2,000 文字と rendered line 数を返す。
これは既存コードを保全するための事前確認であり、コード全体を検証した証拠にはならない。
`bootstrap_symbol_open` は可視の「シンボルの変更」ボタンが一つだけの場合に検索 UI を開く。
`bootstrap_symbol_search` は実測済み symbol dialog 入力へ固定 `USDJPY` を入力する。最終選択は provider `FXCM` の照合が必要。
`bootstrap_symbol_search_close` は symbol-search-input を持つ dialog 内の一意な close ボタンだけを扱う。
`bootstrap_editor_select_all` は名前なしの Pine editor に限定した Ctrl+A と選択 metadata の読み取り。
全体を選択した内容の長さ、line 数、SHA-256、built-in template の構文判定を返し、source 内容は返さない。
この構文判定だけではユーザーの変更がないことを証明できないため、書き換え前には canonical default の照合が必要。
chart 設定は TradingView に autosave される場合がある。
Issue #43 の明示依頼用に `bootstrap_chart_usdjpy5` は固定 chart URL の FX:USDJPY (表示 provider FXCM) / 5 分を要求する。
`bootstrap_pine_open` は実測済み Pine opener のみをクリックする。
実際に適用された symbol/provider/timeframe は別途 read-back する。任意 URL 引数は受け取らない。
`bootstrap_insert_tv1` は固定 worktree の Pine bytes を SHA-256 `bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f` で確認する。
両操作とも、名前なし editor の全選択 175 文字・default SHA `e627e32206b21de8406371be3e54d70753f61baa57dc85db54de954467b259b3` を要求する。
insert は固定 Input.insertText 後に全選択 digest を照合する。失敗時には editor の現状を保全して止め、blind retry をしない。
Monaco textarea は長い選択を切り詰める場合があるため、textarea digest は長い source 全体の証拠にしない。
`bootstrap_editor_copy_hash` は既知 editor の Ctrl+A / Ctrl+C の後だけ clipboard を読み、TV1 source と確認できた場合だけ長さと LF 正規化 digest を返す。
clipboard の既存形式を process memory 内に保存して finally で戻す。内容を output/log/file に残さない。
最後の自分の clipboard 更新後に sequence が変わった場合は復元しない。複数アプリの同時更新を完全には判別できないため、同時にコピー操作をしない。
`bootstrap_repair_tv1_clipboard` は Agent が作成した autoindent 破損 draft の全体 digest と LF 長さが一致した場合だけ、固定 Git source を Ctrl+V で置き換える。
対象 digest `46504a3f6eae3e698c299eb6a1c8ff3bc2472731cebaf01b1812fece6c3d2fb4` / LF 長さ 686200 に限定し、他のコードは拒否する。
置換後は Ctrl+A/C の全体 digest で pinned source との一致を確認する。Input.insertText による再挿入は行わない。
source 追加は無保存 editor に行うが、TradingView 自体の autosave を禁止する機構ではない。公開・broker 注文の操作は含まない。
settings は legend のタイトルが `Loop IFD fixed grid (TV1)` またはその後に空白を伴う表示設定である source を一つだけ選ぶ。
source や settings ボタンが一意でない場合は失敗する。Vol など別 indicator の設定は開かない。
snapshot は legend タイトルと固定 selector の親属性 inventory、TV1 dialog、strategy Report、TV1 diagnostics の限定文字列を返す。
DOM selector が現在の UI と一致しない項目は空となるため、実 UI での read-back が必要。
任意 selector、JavaScript、CDP method、任意入力値変更、任意 navigation、
新しいタブ、ファイル操作、Cookie、network、公開、注文の操作は提供しない。
未対応の検証操作は人間が専用ウィンドウで行う。snapshot は限定 panel の表示文字列を返すため、
返却内容には金融情報が含まれ得る。raw response をログ保存しない。

許可 origin は `https://jp.tradingview.com` と `https://www.tradingview.com` の `/chart/` のみ。
接続時に対象を一つに固定し、操作ごとに URL を確認し、同じ JavaScript 内でも origin/path を検査する。
変更操作の前に metadata の監査記録を同期書き込みし、書き込み不能なら実行しない。
監査記録は `%LOCALAPPDATA%\AgentBrowser\TradingView\audit.jsonl`。DOM、URL、入力値、credential を記録しない。
`revoke` は次の要求から拒否する。実行済み/実行中操作を巻き戻す機能ではない。
`resume` は明示的な再許可である。完全停止には専用 Chrome をユーザーが終了し、9333 を閉じる。

これは unrestricted shell を持つ Agent に対する強制 sandbox ではない。
Agent は直接 CDP 接続やファイル編集で迂回でき、許可 origin 内の UI 変更や同時 navigation による race も残る。
専用 profile は普段の認証情報との混在を減らすが、同じ OS account 内の秘密を保護する境界にはならない。
強制隔離には別 OS account / VM、Agent が触れない broker と credential、直接 CDP 接続を禁止するネットワーク境界が必要。
URL allowlist は通信先の network firewall ではないため、TradingView の配信通信は制限しない。

検証: Windows PowerShell で `tests/test_agent_browser_guard.ps1`、WSL で `bash -n .local/bin/agent-browser-guard`。
