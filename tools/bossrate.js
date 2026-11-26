// ボス(ソロの敵)の勝率を出す道具。手順は次の3つ。
//  1) ランダムなパーティで戦わせる(全体の目安。「適当に打つ」「考えて打つ」の両方)
//  2) 「考えて打つ」の勝率が高かったパーティを上位10通り抜き出す(適正パーティ)
//  3) 適正パーティだけで、もう一度たくさん戦わせる → ここで出た数字を、そのボスの勝率とする
//
// 使い方:
//   node tools/bossrate.js --stage y3                                   既存のステージ(index.html の STAGES)
//   node tools/bossrate.js --foes g_z3b:5.5:1.9 --level 4 --read 0.35   ガチャキャラなどに倍率を掛けた敵
//     --foes は「id:HP倍率:ATK倍率:DFS倍率:フィジカル」をカンマでつなぐ(後ろは省略できる)
//   そのほかの指定(省略すると右の値):
//     --parties 400  手順1で試すパーティの数      --games 20   手順1で1パーティあたりの試合数
//     --top 10       抜き出すパーティの数          --final 300  手順3で1パーティあたりの試合数
//     --pool all     使えるキャラ(all=ガチャ込みのアドバンス / basic=ガチャ抜き)
//     --jobs 4       同時に動かす数               --seed 1     乱数の種(同じ指定なら同じ結果)
//     --verbose      適正パーティごとの勝率も全部出す(ふだんは短くまとめて出す)
//   効率よく測るための指定:
//     --save 名前    見つけた適正パーティを tools/parties/名前.json に保存する
//     --load 名前    保存した適正パーティを使い、手順1・2を飛ばして手順3だけ行う(数値を少し変えたときの確認が速い)
//     --scout 0.5    手順1はHPをこの倍率にして測る(強いボスだと誰も勝てず、強いパーティを見分けられないため。手順3は元のHP)
//     --target 8     適正パーティでの勝率が8%になるように、HPの倍率を自動で合わせる(手順3だけを繰り返す)
//   プレイヤー側のキャラから、ガチャの★1・★2(ハズレ)は最初から外す。
const fs = require('fs');
const path = require('path');
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');

const HTML = path.join(__dirname, '..', 'index.html');
function loadApi() {
  const html = fs.readFileSync(HTML, 'utf8');
  const logic = html.split('// <logic>')[1].split('// </logic>')[0];
  return new Function(logic + '; return { CHARACTERS, SPECIAL_CHARS, GACHA_CHARS, ENEMIES, STAGES, stageFoes, newMatch, rally, breakRally, randomHand, aiHand, aiBreakHand };')();
}
// 乱数の種を決められるように Math.random を差し替える(mulberry32)
function seedRandom(seed) {
  let a = seed >>> 0;
  Math.random = () => { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}
function parseArgs(argv) {
  const o = { parties: 200, games: 10, top: 10, final: 200, hpMul: 1, scout: 0.5, pool: 'all', jobs: 4, seed: 1, level: 4, read: 0.35, verbose: false, high: 0 };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i].replace(/^--/, ''), v = argv[i + 1];
    if (k === 'verbose') { o.verbose = true; continue; }
    if (k in o || ['stage', 'foes', 'save', 'load', 'target'].includes(k)) { o[k] = isNaN(+v) || ['foes', 'stage', 'pool', 'save', 'load'].includes(k) ? v : +v; i++; }
  }
  return o;
}
// 敵を作る
function makeFoes(api, o) {
  if (o.stage) {
    const st = api.STAGES.find((s) => s.id === o.stage);
    if (!st) throw new Error('ステージが見つからない: ' + o.stage);
    const mk = () => api.stageFoes(st).map((f) => ({ ...f, hp: Math.round(f.hp * o.hpMul / 10) * 10 }));
    return { foes: mk(), mk: st.justice ? mk : null, level: st.level, read: st.read || 0, stage: st };   // 降臨:敵の顔ぶれが毎回変わるので、試合ごとに引き直す
  }
  const r10 = (v) => Math.max(1, Math.round(v / 10) * 10);
  const all = [...api.CHARACTERS, ...api.SPECIAL_CHARS, ...api.GACHA_CHARS];
  const foes = o.foes.split(',').map((spec) => {
    const [id, hp = 1, atk = 1, dfs = 1, phys] = spec.split(':');
    const base = api.ENEMIES[id] ? { ...api.ENEMIES[id], id } : all.find((c) => c.id === id);
    if (!base) throw new Error('キャラが見つからない: ' + id);
    return { ...base, id, hp: r10(base.hp * +hp * o.hpMul), atk: r10(base.atk * +atk), dfs: base.dfs ? r10(base.dfs * +dfs) : 0, phys: phys ? +phys : base.phys };
  });
  return { foes, level: o.level, read: o.read };
}
// 1試合。hard=true なら自分も考えて打つ(深さ3)
function play(api, party, F, hard) {
  const S = api.newMatch(party, (F.mk ? F.mk() : F.foes).map((f) => ({ ...f }))); S.noDecay = true; if (F.read) S.bossRead = F.read; if (F.stage) S.stage = F.stage;   // ★5のボスの性格の切り替えは、ステージを見て決める
  const noLog = () => {};
  let g = 0;
  while (!S.over && g++ < 4000) {
    const side = S.teams.findIndex((t) => t.breakReady);
    if (side === 0) api.breakRally(S, 0, hard ? api.aiBreakHand(S, 0) : api.randomHand(), noLog);
    else if (side === 1) api.breakRally(S, 1, api.aiBreakHand(S, 1), noLog);
    else api.rally(S, hard ? api.aiHand(S, 0, 3).hand : api.randomHand(), api.aiHand(S, 1, F.level).hand, noLog);
  }
  return S.winner === 0 ? S.rally : 0;   // 勝ったら、かかったラリー数(負けは0)
}

if (!isMainThread) {
  // 作業する側:渡されたパーティごとに試合をして、勝った数を返す
  const { o, jobs, seed } = workerData;
  seedRandom(seed);
  const api = loadApi(), F = makeFoes(api, o);
  const byId = Object.fromEntries([...api.CHARACTERS, ...api.SPECIAL_CHARS, ...api.GACHA_CHARS].map((c) => [c.id, c]));
  const out = jobs.map(({ ids, games, modes }) => {
    const party = ids.map((id) => byId[id]);
    const r = {};
    for (const m of modes) { let w = 0, wr = 0; for (let i = 0; i < games; i++) { const x = play(api, party, F, m === 'hard'); if (x) { w++; wr += x; } } r[m] = w; r[m + 'R'] = wr; }
    return { ids, games, ...r };
  });
  parentPort.postMessage(out);
} else {
  const o = parseArgs(process.argv.slice(2));
  if (!o.stage && !o.foes) { console.log('使い方は tools/bossrate.js の先頭を見てください'); process.exit(1); }
  seedRandom(o.seed);
  const api = loadApi(), F = makeFoes(api, o);
  const pool = o.pool === 'basic' ? [...api.CHARACTERS, ...api.SPECIAL_CHARS.filter((c) => !c.adv)] : [...api.CHARACTERS, ...api.SPECIAL_CHARS, ...api.GACHA_CHARS.filter((c) => c.rarity >= 3)];   // ★1・★2は外す。ベーシックはアドバンス専用キャラも外す
  const rar = (c) => c.rarity || (api.SPECIAL_CHARS.includes(c) ? 4 : 3);
  const name = (ids) => ids.map((id) => pool.find((c) => c.id === id).name).join(' → ');
  // 並行して動かす
  const runAll = (jobs, oo = o) => {
    const chunks = Array.from({ length: o.jobs }, () => []);
    jobs.forEach((j, i) => chunks[i % o.jobs].push(j));
    return Promise.all(chunks.filter((c) => c.length).map((c, k) => new Promise((ok, ng) => {
      const w = new Worker(__filename, { workerData: { o: oo, jobs: c, seed: o.seed * 1000 + k + jobs.length } });
      w.on('message', ok); w.on('error', ng);
    }))).then((rs) => rs.flat());
  };
  (async () => {
    const t0 = Date.now();
    const PDIR = path.join(__dirname, 'parties');
    const sec = () => `${((Date.now() - t0) / 1000).toFixed(0)}秒`;
    // 手順3:適正パーティだけで測る(hpMul を変えて何度も呼べる)
    const step3 = async (ids, hpMul) => {
      const oo = { ...o, hpMul };
      const r = await runAll(ids.map((x) => ({ ids: x, games: o.final, modes: ['hard'] })), oo);
      r.sort((a, b) => b.hard - a.hard);
      const wins = r.reduce((s, x) => s + x.hard, 0), wr = r.reduce((s, x) => s + x.hardR, 0);
      return { r, rate: wins / (r.length * o.final), wins, avgR: wins ? wr / wins : 0 };
    };
    const show = (F2) => F2.foes.map((f) => `${f.name}(HP${f.hp} ATK${f.atk} DFS${f.dfs} フィジカル${f.phys})`).join(' / ');
    let topIds;
    if (o.load) {
      topIds = JSON.parse(fs.readFileSync(path.join(PDIR, o.load + '.json'), 'utf8'));
      console.log(`適正パーティ:${o.load}.json から${topIds.length}通り`);
    }
    if (o.target != null) {
      if (!topIds) { console.log('--target は --load と一緒に使う(先に --save で適正パーティを作る)'); return; }
      // HPの倍率を二分探索で合わせる(HPを上げるほど勝率は下がる)
      let lo = 0.3, hi = 4, best = null;
      for (let it = 0; it < 7; it++) {
        const m = Math.sqrt(lo * hi);
        const { rate, avgR } = await step3(topIds, o.hpMul * m);
        console.log(`   HP×${(o.hpMul * m).toFixed(2)} → ${(rate * 100).toFixed(2)}%`);
        if (!best || Math.abs(rate * 100 - o.target) < Math.abs(best.rate * 100 - o.target)) best = { m, rate, avgR };
        if (rate * 100 > o.target) lo = m; else hi = m;
      }
      const F2 = makeFoes(api, { ...o, hpMul: o.hpMul * best.m });
      console.log(`★ 目標${o.target}% → HPの倍率を${best.m.toFixed(2)}倍(${show(F2)})で ${(best.rate * 100).toFixed(2)}%(勝った試合の平均 ${best.avgR.toFixed(0)}ラリー)  (${sec()})`);
      return;
    }
    if (topIds) {
      const { r, rate, wins, avgR } = await step3(topIds, o.hpMul);
      console.log(`敵: ${show(makeFoes(api, o))}`);
      if (o.verbose) r.forEach((x) => console.log(`   ${name(x.ids)}  ${(x.hard / o.final * 100).toFixed(1)}%`));
      else console.log(`   最も勝てた:${name(r[0].ids)} ${(r[0].hard / o.final * 100).toFixed(1)}%`);
      console.log(`★ 勝率(適正パーティの平均): ${(rate * 100).toFixed(2)}%  勝った試合 ${wins}回・平均 ${avgR.toFixed(0)}ラリー  (${sec()})`);
      return;
    }
    console.log(`敵: ${F.foes.map((f) => `${f.name}(HP${f.hp} ATK${f.atk} DFS${f.dfs} フィジカル${f.phys})`).join(' / ')}  CPU深さ${F.level} 読み${Math.round(F.read * 100)}%`);
    // 1) ランダムなパーティ(同じ顔ぶれ・同じ順番は1回だけ)
    const seen = new Set(), parties = [];
    while (parties.length < o.parties) {
      const ids = []; while (ids.length < 3) { const c = pool[Math.floor(Math.random() * pool.length)]; if (ids.includes(c.id)) continue;
        if (o.high && rar(c) >= 4 && ids.some((id) => rar(pool.find((x) => x.id === id)) >= 4)) continue;   // --high 1:★4以上は1体まで(降臨など)
        if (ids.some((id) => { const x = pool.find((y) => y.id === id); return x.sameAs === c.id || c.sameAs === x.id; })) continue;   // 同じ人物は入れない
        ids.push(c.id); }
      const k = ids.join(','); if (!seen.has(k)) { seen.add(k); parties.push(ids); }
    }
    const r1 = await runAll(parties.map((ids) => ({ ids, games: o.games, modes: ['random', 'hard'] })), { ...o, hpMul: o.hpMul * o.scout });
    const tot = (m) => r1.reduce((s, r) => s + r[m], 0) / (r1.length * o.games);
    console.log(`1) ランダム${o.parties}通り(HP×${o.scout}で見分け):適当 ${(tot('random') * 100).toFixed(1)}% / 考えて ${(tot('hard') * 100).toFixed(1)}%`);
    // 2) 考えて打つ勝率の上位
    const top = [...r1].sort((a, b) => b.hard - a.hard || b.random - a.random).slice(0, o.top);
    if (o.save) { fs.mkdirSync(PDIR, { recursive: true }); fs.writeFileSync(path.join(PDIR, o.save + '.json'), JSON.stringify(top.map((r) => r.ids))); console.log(`   適正パーティを tools/parties/${o.save}.json に保存`); }
    if (o.verbose) { console.log(`2) 適正パーティ(上位${o.top}通り)`); top.forEach((r, i) => console.log(`   ${i + 1}. ${name(r.ids)}  ${(r.hard / o.games * 100).toFixed(0)}%`)); }
    // 3) 適正パーティだけで、もう一度
    const r3 = await runAll(top.map((r) => ({ ids: r.ids, games: o.final, modes: ['hard'] })));
    r3.sort((a, b) => b.hard - a.hard);
    const fin = r3.reduce((s, r) => s + r.hard, 0) / (r3.length * o.final);
    if (o.verbose) { console.log(`3) 適正パーティだけで ${o.final}試合ずつ`); r3.forEach((r) => console.log(`   ${name(r.ids)}  ${(r.hard / o.final * 100).toFixed(1)}%`)); }
    else console.log(`   最も勝てた:${name(r3[0].ids)} ${(r3[0].hard / o.final * 100).toFixed(1)}% / ${o.top}位:${(r3.at(-1).hard / o.final * 100).toFixed(1)}%`);
    console.log(`★ 勝率(適正パーティの平均): ${(fin * 100).toFixed(1)}%  (${((Date.now() - t0) / 1000).toFixed(0)}秒)`);
  })();
}
