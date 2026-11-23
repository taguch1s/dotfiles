// 監督役ボード: Herdr app の Changes パネルの代わりに、監督役の進捗ファイルと、
// いま人の対応を待っているセッションを 1 か所に出す。
// 進捗ファイル（~/.local/share/hc-supervisor/board.md）は監督役だけが書く。書き方は
// dotfiles の .config/herdr-core/claude/supervisor-prompt.md の「ボード」、全体像は
// docs/herdr-core-orchestration.md。dotfiles で管理しているので、直すときは dotfiles 側を編集する。
import { View, div } from "gpui-kit";
import { v_flex, h_flex, TextView, Scrollbar } from "gpui-base";
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

// board.md を「## 見出し」ごとの行に分ける。最初の「## 」より前（「# 監督役ボード」「更新: …」）は捨てる。
// 「なし」だけの節は空にする。
function parseBoard(text) {
  const sections = [];
  let cur = null;
  for (const raw of (text ?? "").split("\n")) {
    const line = raw.trim();
    const h = /^##\s+(.+)$/.exec(line);
    if (h) { cur = { title: h[1].trim(), lines: [] }; sections.push(cur); continue; }
    if (!cur || !line || line === "なし") continue;
    cur.lines.push(line);
  }
  return sections;
}

const bullet = (line) => line.replace(/^(?:[-*]|\d+[.)])\s+/, "");

// 進行中: 「- <名前>（tN）<リポジトリ> Issue #<番号> [<モデル> / <経路>]: <段階>（HH:MM 時点）」。
// 形が崩れた行は null を返し、普通の文として出す。
function parseActive(line) {
  const m = /^-\s+(.+?)（(t\w+)）\s*(.*?)\s*\[([^\]]+)\]:\s*(.+?)(?:（(\d{1,2}:\d{2})\s*時点）)?$/.exec(line);
  if (!m) return null;
  return { name: m[1], terminal: m[2], sub: m[3], model: m[4], text: m[5], time: m[6] ?? "" };
}

// 完了: 「- Issue #<番号> <PR URL> [<モデル> / <経路>、差し戻し N]: <結果> HH:MM」。
function parseDone(line) {
  const m = /^-\s+(.*?)\s*(https?:\/\/\S+?\/pull\/(\d+))\s*\[([^\]]+)\]:\s*(.+?)(?:\s+(\d{1,2}:\d{2}))?$/.exec(line);
  if (!m) return null;
  const meta = m[4].split(/[、,]\s*/);
  const back = meta.find((x) => /差し戻し/.test(x));
  return {
    name: m[1], url: m[2], pr: `#${m[3]}`, model: meta.filter((x) => x !== back).join("、"),
    back: back ? back.replace(/差し戻し\s*/, "") : "", text: m[5], time: m[6] ?? "",
  };
}

// 要確認の判断: 「- D-YYYYMMDD-HHMM(-N): 決定」。
function parseDecision(line) {
  const m = /^-\s+(D-\d{8}-\d{4}(?:-\d+)?):\s*(.+)$/.exec(line);
  return m ? { id: m[1], text: m[2] } : null;
}

const LINE = 18; // 長い文を 2 行で切るときの 1 行の高さ。

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
    this.expanded = new Set(); // 全文を開いた長い文の id。
    this.raw = false; // Markdown のまま見る。
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

  // ボードの節の見出し。件数があれば丸い札で添える。
  heading(title, count, t, color) {
    return h_flex().pt(14).pb(6).gap(6).items_center().text_size(12).text_color(color ?? t.muted)
      .child(div().font_semibold().child(title))
      .when(count != null, (el) => el.child(div().px(6).rounded_full().text_size(11)
        .bg(t.surface).border_1().border_color(t.border).child(String(count))));
  }

  // 長い文。閉じているときは 2 行で切り、押すと全文を出す。全文はホバーでも読める。
  longText(id, text, t, color) {
    const open = this.expanded.has(id);
    return div().id(id).w_full().min_w(0).whitespace_normal().line_height(LINE).cursor_pointer()
      .text_color(color ?? t.foreground).tooltip(text)
      .when(!open, (el) => el.max_h(LINE * 2).overflow_hidden())
      .on_click((_e, cx) => { open ? this.expanded.delete(id) : this.expanded.add(id); cx.notify(); })
      .child(text);
  }

  // 形の崩れた行も落とさず、普通の文として出す。
  plainRow(id, line, t) {
    return div().py(4).border_t(1).border_color(t.border).text_size(12).child(this.longText(id, bullet(line), t));
  }

  waitingCard(lines, t) {
    const card = v_flex().gap(6).p(10).rounded(8).border_1()
      .border_color(lines.length ? t.blocked : t.border).bg(t.surface)
      .child(h_flex().gap(6).items_center().text_size(12).font_semibold()
        .text_color(lines.length ? t.blocked : t.muted)
        .child(div().size(8).flex_none().rounded(4).bg(lines.length ? t.blocked : t.idle))
        .child(lines.length ? `あなたの対応待ち ${lines.length} 件` : "あなたの対応待ちはありません"));
    return card.children(lines.map((line, i) => h_flex().items_start().gap(6).text_size(13)
      .child(div().flex_none().text_color(t.blocked).child("•"))
      .child(div().flex_1().min_w(0).whitespace_normal().child(bullet(line)))));
  }

  nextList(lines, t) {
    return v_flex().gap(4).children(lines.map((line, i) => h_flex().items_start().gap(8).text_size(13)
      .child(div().flex_none().w(20).h(18).rounded(4).bg(t.surface).border_1().border_color(t.border)
        .text_size(11).text_color(t.muted).flex().items_center().justify_center()
        .child((/^(\d+)[.)]/.exec(line) ?? [])[1] ?? String(i + 1)))
      .child(div().flex_1().min_w(0).whitespace_normal().child(bullet(line)))));
  }

  // 表の見出し行。列の幅は行と同じ固定幅にそろえる。
  tableHead(cols, t) {
    return h_flex().gap(8).pb(4).text_size(11).text_color(t.dim)
      .children(cols.map(([label, w]) => (w ? div().flex_none().w(w) : div().flex_1().min_w(0)).truncate().child(label)));
  }

  // 1 行目に短い列（名前・PR・モデル・時刻）、2 行目に段階・結果の長い文を全幅で出す。
  // 狭いパネルでも長い文の列がつぶれない。
  tableRow(id, cells, text, t) {
    return v_flex().py(6).gap(2).border_t(1).border_color(t.border).text_size(12)
      .child(h_flex().gap(8).items_center().children(cells))
      .child(div().text_size(12).text_color(t.muted).child(this.longText(id, text, t, t.foreground)));
  }

  activeTable(lines, t) {
    const head = this.tableHead([["名前 / Issue", null], ["モデル / 経路", 92], ["時刻", 38]], t);
    return v_flex().child(head).children(lines.map((line, i) => {
      const x = parseActive(line);
      if (!x) return this.plainRow(`active-${i}`, line, t);
      return this.tableRow(`active-${i}`, [
        v_flex().flex_1().min_w(0)
          .child(h_flex().gap(4).min_w(0).child(div().font_semibold().truncate().child(x.name))
            .child(div().flex_none().text_size(11).text_color(t.dim).child(x.terminal)))
          .child(div().truncate().text_size(11).text_color(t.muted).child(x.sub)),
        div().flex_none().w(92).truncate().text_size(11).text_color(t.muted).tooltip(x.model).id(`active-model-${i}`).child(x.model),
        div().flex_none().w(38).text_size(11).text_color(t.dim).child(x.time),
      ], x.text, t);
    }));
  }

  doneTable(lines, t) {
    const head = this.tableHead([["Issue", null], ["PR", 44], ["モデル / 経路", 92], ["時刻", 38]], t);
    return v_flex().child(head).children(lines.map((line, i) => {
      const x = parseDone(line);
      if (!x) return this.plainRow(`done-${i}`, line, t);
      return this.tableRow(`done-${i}`, [
        div().flex_1().min_w(0).font_semibold().truncate().tooltip(x.name).id(`done-name-${i}`).child(x.name),
        div().id(`done-pr-${i}`).flex_none().w(44).truncate().text_color(t.accent).cursor_pointer()
          .hover((s) => s.underline()).tooltip(x.url).on_click((_e, cx) => cx.open_url(x.url)).child(x.pr),
        div().id(`done-model-${i}`).flex_none().w(92).truncate().text_size(11).text_color(t.muted)
          .tooltip(`${x.model}${x.back ? `、差し戻し ${x.back}` : ""}`)
          .child(x.back && x.back !== "0" ? `${x.model} ↩${x.back}` : x.model),
        div().flex_none().w(38).text_size(11).text_color(t.dim).child(x.time),
      ], x.text, t);
    }));
  }

  // 全件を ID・決定の 2 列で出す。決定の文は切らず、全文を折り返す。
  decisionTable(lines, t) {
    const head = this.tableHead([["ID", 112], ["決定", null]], t);
    return v_flex().child(head).children(lines.map((line, i) => {
      const x = parseDecision(line);
      if (!x) return this.plainRow(`decision-${i}`, line, t);
      return h_flex().items_start().gap(8).py(4).border_t(1).border_color(t.border).text_size(12)
        .child(div().flex_none().w(112).pt(1).text_size(11).text_color(t.muted).child(x.id))
        .child(div().flex_1().min_w(0).whitespace_normal().text_color(t.foreground).child(x.text));
    }));
  }

  boardView(t) {
    const sections = parseBoard(this.text);
    const out = [];
    sections.forEach((s, k) => {
      const n = s.lines.length;
      if (/対応待ち/.test(s.title)) {
        out.push(div().pt(4).child(this.waitingCard(s.lines, t)));
        return;
      }
      out.push(this.heading(s.title, /判断|完了|進行中/.test(s.title) ? n : null, t));
      if (!n) out.push(div().text_size(12).text_color(t.dim).child("なし"));
      else if (/次にやること/.test(s.title)) out.push(this.nextList(s.lines, t));
      else if (/進行中/.test(s.title)) out.push(this.activeTable(s.lines, t));
      else if (/完了/.test(s.title)) out.push(this.doneTable(s.lines, t));
      else if (/判断/.test(s.title)) out.push(this.decisionTable(s.lines, t));
      else out.push(v_flex().children(s.lines.map((line, i) => this.plainRow(`other-${k}-${i}`, line, t))));
    });
    return v_flex().w_full().min_w(0).children(out).child(h_flex().pt(14).child(div().id("show-raw").text_size(11).text_color(t.dim).cursor_pointer()
      .hover((s) => s.underline()).on_click((_e, cx) => { this.raw = true; cx.notify(); })
      .child("Markdown のまま見る")));
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
      .child(this.section("止まっているセッション", blocked.length, blocked.length ? t.blocked : null, t))
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
    } else if (this.raw) {
      body = v_flex().gap(8)
        .child(div().id("show-table").text_size(11).text_color(t.accent).cursor_pointer()
          .hover((s) => s.underline()).on_click((_e, cx) => { this.raw = false; cx.notify(); })
          .child("表で見る"))
        .child(TextView.markdown("board-md", this.text).selectable(true));
    } else {
      body = this.boardView(t);
    }

    return v_flex().id("supervisor-board").size_full().min_h(0).rounded(10).overflow_hidden()
      .bg(t.background).border_1().border_color(t.border).text_color(t.foreground).text_size(13)
      .child(header)
      .child(live_rows)
      // overflow_y_scrollbar() は要素を別の入れ物で包むため、absolute().inset_0() が包みの外へ届かず、
      // 高さの決まらない領域になってスクロールしない（changes mod と同じ）。overflow_y_scroll() で
      // 自分でスクロールさせ、同じ id の Scrollbar を重ねる。
      .child(div().flex_1().min_h(0).relative()
        .child(v_flex().id("board-scroll").absolute().inset_0().overflow_y_scroll().px(14).py(10).child(body))
        .child(Scrollbar.vertical("board-scroll").absolute().inset_0()));
  }
}
