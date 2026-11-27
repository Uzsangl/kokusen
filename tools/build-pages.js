// 読めるページ(howto.html・characters.html・world.html)を、ゲームのデータから書き出す。
//   使い方: node tools/build-pages.js
// ルールブックの文章やキャラの数字を変えたら、これを実行して、できた3つのファイルも一緒にコミットする。
// index.html を実際にブラウザで開いて、ゲームが画面に出しているのと同じ文章(describe など)を取り出すので、ゲームと食い違わない。
// 載せるのは、キャラ一覧に最初から名前が出ているキャラだけ(名前を伏せているキャラ・ボス専用の敵は載せない)。
const fs = require('fs'), path = require('path'), http = require('http');
const { chromium } = require('playwright');
const ROOT = path.join(__dirname, '..');
const SITE = 'https://kokusen.org/';
const X_URL = 'https://x.com/kokusenofficial';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.webp': 'image/webp', '.png': 'image/png', '.jpg': 'image/jpeg', '.mp3': 'audio/mpeg', '.css': 'text/css' };
const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

async function extract() {
  const server = http.createServer((req, res) => {
    const f = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html');
    if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(f)] || 'application/octet-stream' }); fs.createReadStream(f).pipe(res);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.route((u) => !u.hostname.startsWith('127.'), (r) => r.abort());   // 外には何も送らない
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
    await page.waitForFunction(() => typeof ALL_CHARS !== 'undefined' && typeof RULEBOOK !== 'undefined' && typeof describe === 'function');
    return await page.evaluate(() => {
      const iso = (c) => c.id === 'g_z5' || !['錨', '零', '矢'].includes(c.faction);
      const group = (c) => (iso(c) ? '隔絶' : c.faction);
      const icon = (c) => { const m = iconHtml(c, 'md').match(/src="([^"?]+)/); return m ? m[1] : ''; };
      const chars = ALL_CHARS.filter((c) => !c.boss && !c.secret).map((c) => ({
        id: c.id, name: c.name, group: group(c), role: c.role || '', stars: rarityOf(c), adv: !!(c.gacha || c.adv),
        hp: c.hp, atk: c.atk, dfs: c.dfs, icon: icon(c),
        traits: traitsOf(c).map((t) => ({ name: t.name, desc: t.desc })),
        actions: HAND_KEYS.map((h) => ({ icon: HANDS[h].icon, hand: HANDS[h].label, power: HANDS[h].power, name: c.actions[h].name, desc: describe(c.actions[h]) })),
      }));
      const css = [...document.styleSheets].flatMap((s) => [...s.cssRules]).filter((r) => r.selectorText && /^\.(rb|rbflow|rbnote|rbt|rainbow)\b/.test(r.selectorText)).map((r) => r.cssText).join('\n');
      return { chars, rulebook: RULEBOOK, rbCss: css, ver: APP_VER, team: TEAM_SIZE, streak: BREAK_STREAK, breakName: BREAK_NAME };
    });
  } finally { await browser.close(); server.close(); }
}

const CSS = `
  :root { --bg: #090b16; --panel: #141830; --text: #eef0ff; --sub: #9aa0c3; --line: #2b3157; --gold: #f5c451; --violet: #8b6cff; --red: #ff4d5e; --hp: #4ade80; }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 0 16px 56px; color: var(--text); line-height: 1.8;
    background: radial-gradient(1200px 600px at 50% -10%, #1c2250 0%, var(--bg) 60%) fixed var(--bg);
    font-family: system-ui, -apple-system, "Hiragino Sans", "Noto Sans JP", sans-serif; }
  main, header.site, footer.site { max-width: 720px; margin: 0 auto; }
  header.site { padding: 14px 0 10px; display: flex; flex-wrap: wrap; align-items: center; gap: 8px 14px; border-bottom: 1px solid var(--line); }
  header.site .logo { font-weight: 900; font-size: 1.25rem; color: var(--gold); text-decoration: none; letter-spacing: .08em; }
  header.site nav { display: flex; flex-wrap: wrap; gap: 4px 12px; font-size: .9rem; }
  header.site nav a { color: var(--sub); text-decoration: none; padding: 2px 0; }
  header.site nav a.on { color: var(--text); border-bottom: 2px solid var(--gold); }
  a { color: var(--gold); }
  h1 { font-size: 1.5rem; line-height: 1.4; margin: 22px 0 6px; }
  h2 { font-size: 1.15rem; margin: 34px 0 8px; color: var(--gold); border-left: 4px solid var(--gold); padding-left: 10px; }
  h3 { font-size: 1rem; margin: 18px 0 4px; }
  p, li, td, th { color: #d5d8f0; font-size: .95rem; }
  .lead { color: var(--sub); margin: 0 0 8px; }
  .play { display: block; margin: 18px 0; padding: 14px; border-radius: 12px; text-align: center; font-weight: 900; font-size: 1.05rem; text-decoration: none;
    color: #1a1304; background: linear-gradient(180deg, #ffe08a, #f5c451); }
  table.t { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: .9rem; }
  table.t th, table.t td { border: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }
  table.t th { background: var(--panel); white-space: nowrap; }
  table.t td:nth-child(-n+2) { white-space: nowrap; }
  .toc { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0; padding: 0; list-style: none; }
  .toc a { display: block; padding: 4px 10px; border: 1px solid var(--line); border-radius: 999px; text-decoration: none; font-size: .85rem; background: var(--panel); }
  .char { display: grid; grid-template-columns: 84px 1fr; gap: 6px 12px; margin: 12px 0; padding: 12px; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); }
  .char img { width: 84px; height: 84px; border-radius: 12px; object-fit: cover; background: #0c0f22; }
  .char .noimg { width: 84px; height: 84px; border-radius: 12px; background: #0c0f22; display: grid; place-items: center; font-size: 2rem; font-weight: 900; color: var(--sub); }
  .char h3 { margin: 0; font-size: 1.1rem; }
  .char .meta { color: var(--sub); font-size: .82rem; }
  .char .stars { color: var(--gold); letter-spacing: .05em; }
  .char .stats { font-weight: 800; font-size: .9rem; display: flex; flex-wrap: wrap; gap: 4px 12px; }
  .char .stats .hp { color: var(--hp); } .char .stats .atk { color: var(--red); } .char .stats .dfs { color: var(--gold); }
  .char .body { grid-column: 1 / -1; }
  .char dl { margin: 6px 0 0; }
  .char dt { font-weight: 800; color: #ffe08a; font-size: .9rem; margin-top: 6px; }
  .char dd { margin: 0; font-size: .88rem; color: #d5d8f0; line-height: 1.6; }
  .char h4 { margin: 10px 0 0; font-size: .8rem; color: var(--sub); font-weight: 700; letter-spacing: .1em; }
  footer.site { margin-top: 44px; padding-top: 14px; border-top: 1px solid var(--line); color: var(--sub); font-size: .82rem; }
  footer.site a { color: var(--sub); }
  .rainbow { color: var(--gold); font-weight: 900; }
`;
const NAV = [['./', 'ゲームで遊ぶ'], ['howto.html', '遊び方'], ['characters.html', 'キャラクター'], ['world.html', '世界観']];
function pageHtml({ file, title, desc, body, extraCss = '' }) {
  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} | 刻戦(コクセン)</title>
<meta name="description" content="${esc(desc)}">
<link rel="canonical" href="${SITE}${file}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="刻戦">
<meta property="og:title" content="${esc(title)} | 刻戦">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${SITE}${file}">
<meta property="og:image" content="${SITE}img/og.jpg">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" type="image/png" sizes="32x32" href="icons/app/favicon-32.png">
<meta name="theme-color" content="#090b16">
<style>${CSS}${extraCss}</style>
</head>
<body>
<!-- このファイルは tools/build-pages.js が書き出したもの。直接は書き換えず、スクリプトを直して作り直す -->
<header class="site"><a class="logo" href="./">刻戦</a><nav>${NAV.map(([h, t]) => `<a href="${h}"${h === file ? ' class="on"' : ''}>${t}</a>`).join('')}</nav></header>
<main>
${body}
<a class="play" href="./">▶ 刻戦を無料で遊ぶ(ブラウザ・登録なし)</a>
</main>
<footer class="site">
  <p><a href="./">刻戦</a> ・ <a href="howto.html">遊び方</a> ・ <a href="characters.html">キャラクター</a> ・ <a href="world.html">世界観</a> ・ <a href="terms.html">利用規約</a> ・ <a href="privacy.html">プライバシーポリシー</a> ・ <a href="${X_URL}" target="_blank" rel="noopener">X「刻戦公式」</a></p>
  <p>音楽:<a href="https://nagumorizu.com/" target="_blank" rel="noopener">なぐもりずの音楽室</a>(南雲莉翠)</p>
</footer>
</body>
</html>
`;
}

function howto(d) {
  const tabs = Object.keys(d.rulebook);
  const body = `<h1>刻戦の遊び方</h1>
<p class="lead">一手を読み合え。刻戦(コクセン)は、じゃんけんで読み合う対戦ゲームです。ブラウザで無料、登録なしですぐ遊べます。</p>
<h2>刻戦はどんなゲーム?</h2>
<p>キャラクターを${d.team}体選んでチームを組み、相手のチームと勝ち抜き戦を行います。操作はじゃんけんだけ。グー・チョキ・パーのどれかを出して、<b>じゃんけんに勝った側だけが、出した手に割り当てられた技を使えます。</b></p>
<p>技はキャラクターごと、手ごとに違います。大きなダメージを与える手、回復する手、味方を強くする手。相手が今いちばん出したい手はどれかを読み、その裏をかく。ただのじゃんけんが、ここで心理戦に変わります。</p>
<p>じゃんけんに${d.streak}回続けて勝つと「${esc(d.breakName)}」が発動し、じゃんけんなしで技が確定で決まります。あと1勝で${esc(d.breakName)}という場面で、相手は何を出して止めに来るのか。勝負どころの読み合いが、刻戦のいちばんの見せ場です。</p>
<table class="t"><tr><th>手</th><th>時間の力</th><th>勝てる相手</th></tr>
<tr><td>✊ グー</td><td>停止</td><td>✌️ チョキ(跳躍)</td></tr>
<tr><td>✌️ チョキ</td><td>跳躍</td><td>🖐️ パー(遡行)</td></tr>
<tr><td>🖐️ パー</td><td>遡行</td><td>✊ グー(停止)</td></tr></table>
<p>それぞれのキャラクターの技は<a href="characters.html">キャラクター紹介</a>で、三つの力の意味は<a href="world.html">世界観</a>で読めます。</p>
<h2>ルールブック</h2>
<p class="lead">ここから下は、ゲームの中の「ルールブック」と同じ内容です(ver ${esc(d.ver)} 時点)。</p>
<ul class="toc">${tabs.map((t, i) => `<li><a href="#rule${i}">${esc(t)}</a></li>`).join('')}</ul>
${tabs.map((t, i) => `<section id="rule${i}"><h2>${esc(t)}</h2>\n${d.rulebook[t]}\n</section>`).join('\n')}`;
  return pageHtml({ file: 'howto.html', title: '遊び方・ルール', desc: `刻戦(コクセン)の遊び方とルール。${d.team}体のチームで戦うじゃんけん対戦ゲーム。勝った手で出る技が変わる心理戦、${d.streak}連勝で発動する${d.breakName}などを解説します。`, body, extraCss: d.rbCss.replace(/var\(--sub\)/g, '#9aa0c3') + '\n section h3 { color: #ffe08a; }' });
}

const GROUPS = [
  ['錨', '維持派「錨」', '停止の力を得意とし、今の時間を守ろうとする陣営。'],
  ['零', '回帰派「零」', '遡行の力を得意とし、時の始まりからやり直そうとする陣営。'],
  ['矢', '前進派「矢」', '跳躍の力を得意とし、滅びの先の未来へ跳ぼうとする陣営。'],
  ['隔絶', '隔絶', 'どの陣営にも属さない者たち。'],
];
function characters(d) {
  const card = (c) => `<article class="char" id="${esc(c.id)}">
  ${c.icon ? `<img src="${esc(c.icon)}" alt="${esc(c.name)}のアイコン" width="84" height="84" loading="lazy">` : `<div class="noimg" aria-hidden="true">${esc(c.name[0])}</div>`}
  <div><h3>${esc(c.name)}</h3>
    <div class="meta"><span class="stars" aria-label="レア度${c.stars}">${'★'.repeat(c.stars)}</span>${c.role ? ` ・ ${esc(c.role)}` : ''}${c.adv ? ' ・ アドバンス専用' : ''}</div>
    <div class="stats"><span class="hp">HP ${c.hp}</span><span class="atk">ATK ${c.atk}</span><span class="dfs">DFS ${c.dfs}</span></div></div>
  <div class="body">${c.traits.length ? `<h4>特性</h4><dl>${c.traits.map((t) => `<dt>${esc(t.name)}</dt><dd>${t.desc}</dd>`).join('')}</dl>` : ''}
    <h4>技</h4><dl>${c.actions.map((a) => `<dt>${a.icon} ${esc(a.power)}「${esc(a.name)}」</dt><dd>${a.desc}</dd>`).join('')}</dl></div>
</article>`;
  const secs = GROUPS.map(([g, label, text]) => [g, label, text, d.chars.filter((c) => c.group === g)]).filter((x) => x[3].length);
  const body = `<h1>キャラクター紹介</h1>
<p class="lead">刻戦(コクセン)に登場するキャラクター ${d.chars.length}体の、能力値・特性・技の一覧です(ver ${esc(d.ver)} 時点)。</p>
<p>キャラクターごとに、グー(停止)・チョキ(跳躍)・パー(遡行)で出る技が違います。じゃんけんに勝った側だけが、出した手の技を使えます。「この相手は、どの手で勝ちたいか」を知っておくことが、読み合いの第一歩です。遊び方は<a href="howto.html">遊び方・ルール</a>を見てください。</p>
<ul class="toc">${secs.map(([g, label, , cs]) => `<li><a href="#f-${esc(g)}">${esc(label)}(${cs.length})</a></li>`).join('')}</ul>
${secs.map(([g, label, text, cs]) => `<section id="f-${esc(g)}"><h2>${esc(label)}</h2><p class="lead">${esc(text)}</p>\n${cs.map(card).join('\n')}\n</section>`).join('\n')}`;
  return pageHtml({ file: 'characters.html', title: 'キャラクター紹介', desc: `刻戦(コクセン)のキャラクター${d.chars.length}体の一覧。錨・零・矢の陣営ごとに、能力値、特性、グー・チョキ・パーで出る技を紹介します。`, body });
}

function world(d) {
  const body = `<h1>刻戦の世界観</h1>
<p class="lead">刻戦(コクセン)の舞台となる世界と、三つの時間の力、三つの陣営について。</p>
<h2>刻(とき)が流れる世界</h2>
<p>この世界では、時間が「刻(とき)」という目に見える物質として流れています。人の体力や寿命も、刻でできています。</p>
<p>けれど、世界の刻は少しずつ減っています。朝が来なくなった村。一晩で老いてしまう森。各地で、時間が抜け落ちる現象が起きています。</p>
<p>この世界の戦いは、時間の流れに沿った普通の戦いです。ただ、そこで有利を取る手段として、人々は時間そのものを扱うようになりました。戦いの中で使える時間の力は三つ。どれも、扱えるのは数秒が限度です。</p>
<h2>三つの時間の力</h2>
<p>刻戦のじゃんけんは、この三つの力のぶつかり合いを表しています。</p>
<table class="t"><tr><th>力</th><th>手</th><th>勝てる相手</th><th>理由</th></tr>
<tr><td>停止</td><td>✊ グー</td><td>跳躍</td><td>停止が止めるのは、現在から未来まで。跳んだ先の時間も、止まっている。</td></tr>
<tr><td>跳躍</td><td>✌️ チョキ</td><td>遡行</td><td>過去を書き換えても、すでに先の時点に立っている者には届かない。確定するのは、いつも先にいる側。</td></tr>
<tr><td>遡行</td><td>🖐️ パー</td><td>停止</td><td>過去は、停止の力が届かない場所にある。</td></tr></table>
<p>同じ力がぶつかれば、打ち消し合って「あいこ」になります。そして、じゃんけんに${d.streak}回続けて勝つと「${esc(d.breakName)}」が発動します。</p>
<h2>三つの陣営</h2>
<p>減っていく刻を前にして、人々は三つの考えに分かれました。誰もが三つの力をすべて使えますが、陣営ごとに得意な力が一つあります。</p>
<table class="t"><tr><th>陣営</th><th>得意な力</th><th>目的</th><th>そのために手放すもの</th></tr>
<tr><td>維持派「錨」</td><td>停止</td><td>今の時間を守る</td><td>未来。滅びを先送りにしているだけかもしれない。</td></tr>
<tr><td>回帰派「零」</td><td>遡行</td><td>時の始まりからやり直す</td><td>今を生きる人々。やり直せば、いなかったことになる。</td></tr>
<tr><td>前進派「矢」</td><td>跳躍</td><td>滅びの先の未来へ、世界ごと跳ぶ</td><td>途中の時間。人々の残りの人生が、飛ばされる。</td></tr></table>
<p>錨は港の衛士や船乗りのような姿で、鎖や錨、羅針盤を身につけています。零は黒い長衣や仮面をまとい、割れた文字盤や針のない時計を持ちます。矢は軽い旅装束で、羽根や弦、矢羽の飾りが、いつも前へなびいています。</p>
<p>三つの陣営の力関係も、三つの力と同じ三つ巴です。錨は矢に強く、矢は零に強く、零は錨に強い。どの陣営にも、それぞれの言い分があります。</p>
<p>それぞれの陣営に属するキャラクターは、<a href="characters.html">キャラクター紹介</a>で見られます。</p>`;
  return pageHtml({ file: 'world.html', title: '世界観', desc: '刻戦(コクセン)の世界観。時間が「刻」という物質として流れる世界、停止・跳躍・遡行の三つの力、錨・零・矢の三つの陣営について。', body });
}

(async () => {
  const d = await extract();
  const out = { 'howto.html': howto(d), 'characters.html': characters(d), 'world.html': world(d) };
  for (const [f, html] of Object.entries(out)) fs.writeFileSync(path.join(ROOT, f), html);
  console.log(`書き出し完了: ${Object.keys(out).join(', ')}(キャラ ${d.chars.length}体、ルールブック ${Object.keys(d.rulebook).length}項目、ver ${d.ver})`);
})().catch((e) => { console.error(e); process.exit(1); });
