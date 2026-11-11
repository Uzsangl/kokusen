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
api.CHARACTERS.forEach((c) => { stat[c.id] = { name: c.name, picked: 0, teamWins: 0, fielded: 0, kills: 0 }; });

for (let i = 0; i < N; i++) {
  const S = api.newMatch(api.shuffled(api.CHARACTERS).slice(0, api.TEAM_SIZE),
                         api.shuffled(api.CHARACTERS).slice(0, api.TEAM_SIZE));
  while (!S.over) {
    const side = S.teams.findIndex((t) => t.breakReady);
    if (side >= 0) { breaks++; api.breakRally(S, side, api.pickBreakHand(S, side), noLog); }
    else api.rally(S, api.randomHand(), api.randomHand(), noLog);
  }
  S.teams.forEach((t, side) => t.cards.forEach((c) => {
    const s = stat[c.ch.id];
    s.picked++;
    if (S.winner === side) s.teamWins++;
    if (c.turn > 0) { s.fielded++; s.kills += c.kills; }
  }));
  rallies += S.rally;
  kos += S.teams[0].wins + S.teams[1].wins;
  if (S.winner === -1) draws++; else wins[S.winner]++;
}
console.log(`試合数 ${N}`);
console.log(`1試合の平均ラリー数: ${(rallies / N).toFixed(1)}`);
console.log(`1枚倒すまでの平均ラリー数: ${(rallies / kos).toFixed(2)}`);
console.log(`1試合の平均ブレイク回数: ${(breaks / N).toFixed(2)}`);
console.log(`先攻側勝率 ${(wins[0] / N * 100).toFixed(1)}% / 引き分け ${(draws / N * 100).toFixed(2)}%`);
console.log('キャラ別 チームに入れたときの試合勝率 / 場に出たときの平均撃破数:');
Object.values(stat).forEach((s) => console.log(`  ${s.name}: ${(s.teamWins / s.picked).toFixed(3)} / ${(s.kills / s.fielded).toFixed(2)}`));
