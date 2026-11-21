// 監督役ボード: Herdr app の Changes パネルの代わりに、監督役の進捗ファイルと、
// いま人の対応を待っているセッションを 1 か所に出す。
// 進捗ファイル（~/.local/share/hc-supervisor/board.md）は監督役だけが書く。書き方は
// dotfiles の .config/herdr-core/claude/supervisor-prompt.md の「ボード」、全体像は
// docs/herdr-core-orchestration.md。dotfiles で管理しているので、直すときは dotfiles 側を編集する。
import { View, div } from "gpui-kit";
import { v_flex, h_flex, TextView } from "gpui-base";
import { agents, terminals, readTextFile, watchFolder, theme, home, run, checking } from "herdr";

const STALE_MINUTES = 30;
const folder = () => `${home()}/.local/share/hc-supervisor`;
const boardPath = () => `${folder()}/board.md`;

// 「更新: 2026-11-21 21:40」の行から、最後に書かれた時刻を読む。
function updatedAt(text) {
  const m = /更新:\s*(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})/.exec(text ?? "");
  return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) : null;
}

function ago(date, now) {
  const minutes = Math.max(0, Math.floor((now - date) / 60000));
  if (minutes < 1) return "たった今";
  if (minutes < 60) return `${minutes} 分前`;
  const hours = Math.floor(minutes / 60);
  return hours < 24 ? `${hours} 時間前` : `${Math.floor(hours / 24)} 日前`;
}

// 人の対応を待っている terminal（権限の確認、質問で止まったもの）。agents() に無いもの（ペインのない
// terminal）も terminals() の status で拾う。
function waiting() {
  const shown = agents();
  const byAddress = new Map(terminals().map((x) => [x.address, x]));
  const rows = shown.filter((a) => a.status === "blocked").map((a) => ({
    address: a.address,
    name: byAddress.get(a.address)?.name || a.tab_name || a.title,
    where: a.space_name,
  }));
  for (const x of byAddress.values()) {
    if (x.state === "live" && x.status === "blocked" && !shown.some((a) => a.address === x.address)) {
      rows.push({ address: x.address, name: x.name || x.address, where: "ペインなし" });
    }
  }
  return rows;
}

// ペインがあればそこへ移り、無ければ覗き窓（peek）で開く。
function open(address) {
  const a = agents().find((x) => x.address === address);
  if (a) run("pane.focus", { pane: a.pane });
  else run("terminal.peek", { terminal: address });
}

export default class SupervisorBoard extends View {
  init(_props, cx) {
    this.text = null;
    this.error = null;
    this.now = Date.now();
    this.reload(cx);
    if (checking()) return;
    // 経過時間の表示と、フォルダ監視が使えないときの読み直し。
    cx.timer.every(10000, (cx) => { this.now = Date.now(); this.reload(cx); });
    cx.spawn(async (cx) => {
      for (;;) {
        try {
          await watchFolder(folder());
        } catch {
          return; // フォルダが無いなどで監視できなければ、10 秒ごとの読み直しに任せる。
        }
        this.reload(cx);
      }
    });
  }

  reload(cx) {
    if (this.loading) return;
    this.loading = true;
    cx.spawn(async (cx) => {
      try {
        const text = await readTextFile(boardPath());
        if (text !== this.text || this.error) { this.text = text; this.error = null; cx.notify(); }
      } catch (e) {
        this.error = String(e);
        cx.notify();
      } finally {
        this.loading = false;
      }
    });
  }

  statusDot(status, t) {
    const color = { working: t.working, blocked: t.blocked, done: t.done, idle: t.idle }[status] ?? t.unknown;
    return div().size(7).flex_none().rounded(4).bg(color);
  }

  row(id, x, t) {
    return h_flex().id(id).h(26).px(8).gap(8).items_center().rounded(6).cursor_pointer()
      .hover((s) => s.bg(t.hover)).on_click(() => open(x.address))
      .child(this.statusDot(x.status, t))
      .child(div().flex_1().min_w(0).truncate().child(x.name))
      .child(div().flex_none().text_size(11).text_color(t.dim).child(x.detail ?? x.address));
  }

  section(title, count, color, t) {
    return h_flex().px(14).pt(10).pb(4).gap(6).items_center().text_size(11).text_color(color ?? t.muted)
      .child(div().font_semibold().child(title))
      .when(count !== null, (el) => el.child(div().child(String(count))));
  }

  render(cx) {
    const t = theme();
    const live = terminals().filter((x) => x.state === "live");
    const supervisor = live.find((x) => x.name === "supervisor");
    const workers = live.filter((x) => x.labels?.role === "worker");
    const blocked = waiting();
    const updated = updatedAt(this.text);
    const stale = updated && (this.now - updated) / 60000 > STALE_MINUTES && workers.some((w) => w.status === "working");

    const header = h_flex().h(42).flex_none().px(14).gap(8).items_center().border_b(1).border_color(t.border)
      .child(div().font_semibold().child("監督役ボード"))
      .child(div().flex_1())
      .when(Boolean(updated), (el) => el.child(div().text_size(11).text_color(stale ? t.blocked : t.dim)
        .child(`更新 ${ago(updated, this.now)}${stale ? "（古い）" : ""}`)))
      .child(h_flex().id("open-supervisor").h(24).px(8).gap(6).items_center().rounded(6).text_size(12)
        .border_1().border_color(t.border).cursor_pointer().hover((s) => s.bg(t.hover))
        .when(Boolean(supervisor), (el) => el.on_click(() => open(supervisor.address)))
        .child(this.statusDot(supervisor?.status, t))
        .child(supervisor ? "supervisor" : "監督役なし"));

    const live_rows = v_flex().flex_none().pb(6).border_b(1).border_color(t.border)
      .child(this.section("あなたの対応待ち", blocked.length, blocked.length ? t.blocked : null, t))
      .child(v_flex().px(6).children(blocked.length
        ? blocked.map((x, i) => this.row(`wait-${i}`, { ...x, status: "blocked", detail: x.where }, t))
        : [div().px(8).py(2).text_size(12).text_color(t.dim).child("止まっているセッションはありません")]))
      .child(this.section("ワーカー", workers.length, null, t))
      .child(v_flex().px(6).children(workers.length
        ? workers.map((w, i) => this.row(`worker-${i}`, { address: w.address, name: w.name || w.address, status: w.status }, t))
        : [div().px(8).py(2).text_size(12).text_color(t.dim).child("動いているワーカーはいません")]));

    let body;
    if (this.error) {
      body = div().p(14).text_size(12).text_color(t.blocked).child(`読めませんでした: ${this.error}`);
    } else if (this.text == null) {
      body = v_flex().p(14).gap(6).text_size(12).text_color(t.muted)
        .child("監督役がまだボードを書いていません。")
        .child(div().text_color(t.dim).child(boardPath()));
    } else {
      body = TextView.markdown("board-md", this.text).selectable(true);
    }

    return v_flex().id("supervisor-board").size_full().min_h(0).rounded(10).overflow_hidden()
      .bg(t.background).border_1().border_color(t.border).text_color(t.foreground).text_size(13)
      .child(header)
      .child(live_rows)
      .child(div().flex_1().min_h(0).relative()
        .child(v_flex().id("board-scroll").absolute().inset_0().overflow_y_scrollbar().px(14).py(10).child(body)));
  }
}
