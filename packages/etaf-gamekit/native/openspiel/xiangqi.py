#!/usr/bin/env python3
"""Bounded opponent search using OpenSpiel's xiangqi state, not new rules."""
# SPDX-License-Identifier: GPL-3.0-or-later
import math
import random
import time

VALUES = {'R': 900, 'H': 420, 'E': 220, 'A': 220, 'G': 100000, 'C': 450, 'S': 100}
MATE = 1000000


class Search:
    """Iterative alpha-beta; native states own legality and terminal outcomes.

    Scores are always from the root player's perspective. Terminal wins outrank
    every material score; losses rank below them. Completed iterations alone
    replace the selected move. A deadline stops search without touching the
    live match, falling back to a legal move if even depth one cannot finish.
    """

    def __init__(self, state, depth, seconds, seed):
        self.root = state
        self.player = state.current_player()
        self.depth = depth
        self.deadline = time.monotonic() + seconds
        self.random = random.Random(seed)
        self.nodes = 0
        self.completed_depth = 0

    @staticmethod
    def board(state):
        return state.observation_string(0).replace('\n', '')

    def evaluate(self, state):
        board = self.board(state)
        score = sum(value * (board.count(piece) - board.count(piece.lower()))
                    for piece, value in VALUES.items())
        # Soldiers become more useful after advancing, especially over the river.
        for square, piece in enumerate(board):
            if piece == 'S':
                score += 10 * max(0, 6 - square // 9)
            elif piece == 's':
                score -= 10 * max(0, square // 9 - 3)
        return score if self.player == 0 else -score

    def ordered(self, state, actions):
        board = self.board(state)
        # OpenSpiel xiangqi actions are source * 90 + target, both row-major.
        def rank(action):
            source, target = divmod(action, 90)
            victim = board[target].upper()
            return (VALUES.get(victim, 0) * 16 - VALUES[board[source].upper()]
                    if victim != '.' else 0)
        return sorted(actions, key=rank, reverse=True)

    def visit(self, state, depth, alpha, beta, ply):
        self.nodes += 1
        if self.nodes % 64 == 0 and time.monotonic() >= self.deadline:
            raise TimeoutError
        if state.is_terminal():
            return state.player_return(self.player) * (MATE - ply)
        if depth == 0:
            return self.evaluate(state)
        maximizing = state.current_player() == self.player
        best = -math.inf if maximizing else math.inf
        for action in self.ordered(state, state.legal_actions()):
            value = self.visit(state.child(action), depth - 1, alpha, beta, ply + 1)
            if maximizing:
                best = max(best, value)
                alpha = max(alpha, best)
            else:
                best = min(best, value)
                beta = min(beta, best)
            if alpha >= beta:
                break
        return best

    def run(self):
        actions = self.root.legal_actions()
        self.random.shuffle(actions)
        actions = self.ordered(self.root, actions)
        best, score = actions[0], self.evaluate(self.root)
        for depth in range(1, self.depth + 1):
            if time.monotonic() >= self.deadline:
                break
            choice, value = best, -math.inf
            try:
                for action in [best] + [a for a in actions if a != best]:
                    candidate = self.visit(self.root.child(action), depth - 1,
                                           value, math.inf, 1)
                    if candidate > value:
                        choice, value = action, candidate
            except TimeoutError:
                break
            best, score, self.completed_depth = choice, value, depth
            if score >= MATE - depth:
                break
        return best, score
