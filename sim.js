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
  while (!S.over) {
    const side = S.teams.findIndex((t) => t.breakReady);
    if (side >= 0) { breaks++; api.breakRally(S, side, api.pickBreakHand(S, side), noLog); }
    else api.rally(S, api.randomHand(), api.randomHand(), noLog);
  }
  S.teams.forEach((t) => t.cards.forEach((c) => {
    if (c.result) stat[c.ch.id].used++;
    if (c.result === 'win') stat[c.ch.id].kos++;
  }));
  rallies += S.rally;
  kos += S.bouts;
  if (S.winner === -1) draws++; else wins[S.winner]++;
}
console.log(`試合数 ${N}`);
console.log(`番手戦1本あたりの平均ラリー数: ${(rallies / kos).toFixed(2)}`);
console.log(`1試合の平均ラリー数: ${(rallies / N).toFixed(1)}`);
console.log(`1試合の平均ブレイク回数: ${(breaks / N).toFixed(2)}`);
console.log(`先攻側勝率 ${(wins[0] / N * 100).toFixed(1)}% / 引き分け ${(draws / N * 100).toFixed(2)}%`);
console.log('キャラ別 番手戦の勝率:');
Object.values(stat).forEach((s) => console.log(`  ${s.name}: ${(s.kos / s.used).toFixed(2)}`));
