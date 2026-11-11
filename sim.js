// バランス調整用シミュレーター: node sim.js [試合数]
// index.html のルール部分をそのまま読み込み、両者ランダムの手で対戦させて集計する。
const fs = require('fs');
const html = fs.readFileSync(__dirname + '/index.html', 'utf8');
const logic = html.split('// <logic>')[1].split('// </logic>')[0];
const api = new Function(logic + '; return { CHARACTERS, TEAM_SIZE, newMatch, rally, breakRally, pickBreakHand, randomHand, shuffled };')();

const N = Number(process.argv[2]) || 20000;
const noLog = () => {};
let rallies = 0, kos = 0, breaks = 0, wins = [0, 0], draws = 0;
const stat = {};
api.CHARACTERS.forEach((c) => { stat[c.id] = { name: c.name, used: 0, kos: 0 }; });

for (let i = 0; i < N; i++) {
  const S = api.newMatch(api.shuffled(api.CHARACTERS).slice(0, api.TEAM_SIZE),
                         api.shuffled(api.CHARACTERS).slice(0, api.TEAM_SIZE));
  S.teams.forEach((t) => t.cards.forEach((c) => stat[c.ch.id].used++));
  while (!S.over) {
    const before = S.teams.map((t) => t.idx);
    const attackers = S.teams.map((t) => t.cards[t.idx].ch.id);
    const side = S.teams.findIndex((t) => t.breakReady);
    if (side >= 0) { breaks++; api.breakRally(S, side, api.pickBreakHand(S, side), noLog); }
    else api.rally(S, api.randomHand(), api.randomHand(), noLog);
    S.teams.forEach((t, s) => { if (t.idx > before[s]) { kos++; stat[attackers[1 - s]].kos++; } });
  }
  rallies += S.rally;
  if (S.winner === -1) draws++; else wins[S.winner]++;
}
console.log(`試合数 ${N}`);
console.log(`1枚倒すまでの平均ラリー数: ${(rallies / kos).toFixed(2)}`);
console.log(`1試合の平均ラリー数: ${(rallies / N).toFixed(1)}`);
console.log(`1試合の平均ブレイク回数: ${(breaks / N).toFixed(2)}`);
console.log(`先攻側勝率 ${(wins[0] / N * 100).toFixed(1)}% / 引き分け ${(draws / N * 100).toFixed(2)}%`);
console.log('キャラ別 1出場あたりの撃破数:');
Object.values(stat).forEach((s) => console.log(`  ${s.name}: ${(s.kos / s.used).toFixed(2)}`));
