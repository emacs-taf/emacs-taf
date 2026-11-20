// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic rule fixture for the boardgame.io adapter's public contract.
module.exports = {
  name: 'resource-draft',
  setup: ({ random }) => ({ pool: 12, score: [0, 0], hands: [random.D6(), random.D6()] }),
  playerView: ({ G, playerID }) => ({ pool: G.pool, score: G.score,
    hand: playerID === null || playerID === undefined ? null : G.hands[Number(playerID)] }),
  phases: {
    draft: { start: true, moves: { claim: ({ G, playerID }, amount) => {
      if (!Number.isInteger(amount) || amount < 1 || amount > 3 || amount > G.pool) return 'INVALID_MOVE';
      G.pool -= amount;
      G.score[Number(playerID)] += amount;
    } }, endIf: ({ G }) => G.pool <= 6, next: 'final' },
    final: { moves: { claim: ({ G, playerID }, amount) => {
      if (!Number.isInteger(amount) || amount < 1 || amount > 3 || amount > G.pool) return 'INVALID_MOVE';
      G.pool -= amount;
      G.score[Number(playerID)] += amount;
    } } },
  },
  turn: { maxMoves: 2 },
  endIf: ({ G }) => G.pool === 0 ? { winner: G.score[0] >= G.score[1] ? '0' : '1' } : undefined,
};
