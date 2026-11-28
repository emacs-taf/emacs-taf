#!/usr/bin/env python3
"""GameKit adapter for OpenSpiel's public game/state APIs, with no renderer."""
# SPDX-License-Identifier: GPL-3.0-or-later
from __future__ import annotations
import argparse
import importlib.metadata
import json
import math
import os
from pathlib import Path
import random
import sys
import tempfile
import time
import pyspiel
from xiangqi import Search

VERSION = importlib.metadata.version('open-spiel')
MAX_MESSAGE = 1024 * 1024
MAX_SNAPSHOT = 8 * MAX_MESSAGE
MAX_HISTORY = 128
MAX_BOT_SECONDS = 10


class Match:
    """Own one native rule state and a separate chance sampler."""

    def __init__(self, specification, player, seed):
        self.game = pyspiel.load_game(specification)
        kind = self.game.get_type()
        if kind.dynamics not in (pyspiel.GameType.Dynamics.SEQUENTIAL, pyspiel.GameType.Dynamics.SIMULTANEOUS):
            raise ValueError('This adapter supports sequential and simultaneous games, not mean-field updates')
        if kind.chance_mode == pyspiel.GameType.ChanceMode.SAMPLED_STOCHASTIC:
            raise ValueError('Sampled-stochastic kernels require an engine-specific RNG adapter')
        self.player = self.valid_player(player)
        self.seed = seed
        self.random = random.Random(seed)
        self.state = self.game.new_initial_state()
        self.resolve_chance(self.state, self.random)
        self.past, self.future, self.action_count = [], [], 0
        self.bot = None

    def frame(self):
        return self.state.clone(), self.random.getstate(), self.player, self.action_count

    def use_frame(self, frame):
        self.state, state, self.player, self.action_count = frame
        self.random.setstate(state)

    def valid_player(self, player):
        if type(player) is not int or not 0 <= player < self.game.num_players():
            raise ValueError('Player is outside this game')
        return player

    @staticmethod
    def resolve_chance(state, generator):
        for _ in range(10000):
            if not state.is_chance_node():
                return
            outcomes = state.chance_outcomes()
            state.apply_action(generator.choices([x[0] for x in outcomes], [x[1] for x in outcomes])[0])
        raise ValueError('Chance resolution exceeded 10000 transitions')

    def observe(self):
        state, kind = self.state, self.game.get_type()
        terminal = state.is_terminal()
        legal = [] if terminal else state.legal_actions(self.player)
        return {
            'schema': 'openspiel/1', 'engine': {'name': 'openspiel', 'version': VERSION},
            'game': {'name': kind.short_name, 'specification': str(self.game),
                     'players': self.game.num_players(), 'dynamics': str(kind.dynamics)},
            'player': self.player, 'current_player': state.current_player(),
            'can_undo': bool(self.past), 'can_redo': bool(self.future),
            'action_count': self.action_count,
            'terminal': terminal, 'simultaneous': state.is_simultaneous_node(),
            'legal_actions': [{'id': action, 'label': state.action_to_string(self.player, action)} for action in legal],
            'observation': state.observation_string(self.player) if kind.provides_observation_string else None,
            'observation_tensor': state.observation_tensor(self.player) if kind.provides_observation_tensor else None,
            'information_state': state.information_state_string(self.player) if kind.provides_information_state_string else None,
            'returns': state.returns(), 'rewards': state.rewards(), 'bot': self.bot,
        }

    def supports_bot(self):
        """Return True when this kernel can play a move for the side to move."""
        return self.game.get_type().dynamics == pyspiel.GameType.Dynamics.SEQUENTIAL

    def begin(self):
        """Return a candidate clone and a copy of the chance sampler."""
        if self.state.is_terminal():
            raise ValueError('The game is over')
        candidate = self.state.clone()
        generator = random.Random()
        generator.setstate(self.random.getstate())
        return candidate, generator

    def commit(self, candidate, generator):
        """Make CANDIDATE the live state and remember its predecessor."""
        self.resolve_chance(candidate, generator)
        self.past.append(self.frame())
        del self.past[:-MAX_HISTORY]
        self.future.clear()
        self.state, self.random = candidate, generator
        self.action_count += 1
        self.bot = None

    def bot_move(self, args):
        """Choose the side to move's action and describe the decision."""
        if self.state.is_terminal():
            raise ValueError('The game is over')
        if self.state.is_simultaneous_node() or self.state.current_player() < 0:
            raise ValueError('A bot move needs a turn-based player')
        policy = args.get('policy', 'search')
        if policy == 'random':
            action = random.Random(self.seed * 1000003 + self.action_count).choice(self.state.legal_actions())
            return action, {'policy': 'random', 'depth': 0, 'nodes': 0, 'score': 0, 'elapsed': 0.0}
        if policy != 'search':
            raise ValueError('Unsupported bot policy')
        depth = args.get('depth', 4)
        seconds = args.get('seconds', 1.0)
        if type(depth) is not int or not 1 <= depth <= 12:
            raise ValueError('Bot depth must be an integer from 1 to 12')
        if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 0.05 <= seconds <= MAX_BOT_SECONDS:
            raise ValueError(f'Bot time must be between 0.05 and {MAX_BOT_SECONDS:g} seconds')
        kind = self.game.get_type()
        if not (self.game.num_players() == 2 and kind.dynamics == pyspiel.GameType.Dynamics.SEQUENTIAL
                and kind.chance_mode == pyspiel.GameType.ChanceMode.DETERMINISTIC
                and kind.information == pyspiel.GameType.Information.PERFECT_INFORMATION
                and kind.utility == pyspiel.GameType.Utility.ZERO_SUM and kind.short_name == 'xiangqi'):
            raise ValueError('The search policy needs a supported two-player perfect-information game')
        search = Search(self.state, depth, seconds,
                        self.seed * 1000003 + self.action_count)
        started = time.monotonic()
        action, score = search.run()
        return action, {'policy': 'search', 'depth': search.completed_depth, 'requested_depth': depth,
                        'nodes': search.nodes, 'score': score,
                        'elapsed': round(time.monotonic() - started, 3)}

    def command(self, operation, args):
        if operation == 'set-player':
            self.player = self.valid_player(args.get('player'))
        elif operation == 'save':
            self.save(self.path(args))
        elif operation == 'load':
            self.restore(self.path(args))
            self.bot = None
        elif operation in ('undo', 'redo'):
            count = args.get('count', 1)
            if type(count) is not int or not 1 <= count <= MAX_HISTORY:
                raise ValueError('Undo/redo count must be a positive integer within the retained history')
            source, destination = (self.past, self.future) if operation == 'undo' else (self.future, self.past)
            if not source:
                raise ValueError(f'Nothing to {operation}')
            for _ in range(min(count, len(source))):
                destination.append(self.frame())
                self.use_frame(source.pop())
            self.bot = None
        elif operation == 'reset':
            seed = args.get('seed', self.seed)
            if type(seed) is not int:
                raise ValueError('Reset seed must be an integer')
            candidate = self.game.new_initial_state()
            generator = random.Random(seed)
            self.resolve_chance(candidate, generator)
            self.state, self.random, self.seed = candidate, generator, seed
            self.past, self.future, self.action_count, self.bot = [], [], 0, None
        elif operation in ('act', 'joint-action'):
            candidate, generator = self.begin()
            if operation == 'act':
                action = args.get('action')
                if candidate.is_simultaneous_node() or candidate.current_player() != self.player:
                    raise ValueError('Select the active player, or submit a joint action for simultaneous play')
                if type(action) is not int or action not in candidate.legal_actions(self.player):
                    raise ValueError('Illegal action')
                candidate.apply_action(action)
            else:
                actions = args.get('actions')
                if not candidate.is_simultaneous_node() or not isinstance(actions, list) or len(actions) != self.game.num_players():
                    raise ValueError('A simultaneous node needs one action per player')
                if any(type(action) is not int or action not in candidate.legal_actions(player)
                       for player, action in enumerate(actions)):
                    raise ValueError('Illegal joint action')
                candidate.apply_actions(actions)
            self.commit(candidate, generator)
        elif operation == 'bot':
            action, report = self.bot_move(args)
            candidate, generator = self.begin()
            player = candidate.current_player()
            if candidate.is_simultaneous_node() or player < 0:
                raise ValueError('A bot move needs a turn-based player')
            if action not in candidate.legal_actions(player):
                raise ValueError('The bot policy returned an illegal action')
            label = candidate.action_to_string(player, action)
            candidate.apply_action(action)
            self.commit(candidate, generator)
            self.bot = dict(report, action=action, label=label)
        else:
            raise ValueError('Unsupported game operation')

    @staticmethod
    def path(args):
        value = args.get('path')
        if not isinstance(value, str) or not value:
            raise ValueError('A snapshot path is required')
        return Path(value).expanduser().resolve()

    def save(self, path):
        def encode(frame):
            state, rng, player, count = frame
            return {'native': pyspiel.serialize_game_and_state(self.game, state),
                    'random': rng, 'player': player, 'action_count': count}
        value = {'schema': 'gamekit.openspiel/snapshot-2', 'engine_version': VERSION,
                 'game': str(self.game), 'seed': self.seed, 'current': encode(self.frame()),
                 'past': [encode(frame) for frame in self.past],
                 'future': [encode(frame) for frame in self.future]}
        encoded = json.dumps(value, allow_nan=False).encode('utf-8')
        if len(encoded) > MAX_SNAPSHOT:
            raise ValueError('Snapshot exceeds 8 MiB')
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + '.', delete=False) as output:
                temporary = Path(output.name)
                output.write(encoded)
            os.replace(temporary, path)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()

    def restore(self, path):
        with path.open('rb') as source:
            raw = source.read(MAX_SNAPSHOT + 1)
        if len(raw) > MAX_SNAPSHOT:
            raise ValueError('Snapshot exceeds 8 MiB')
        saved = json.loads(raw)
        if not isinstance(saved, dict) or saved.get('schema') != 'gamekit.openspiel/snapshot-2' or \
                saved.get('engine_version') != VERSION or saved.get('game') != str(self.game) or \
                type(saved.get('seed')) is not int or \
                any(not isinstance(saved.get(key), list) or len(saved[key]) > MAX_HISTORY
                    for key in ('past', 'future')) or len(saved['past']) + len(saved['future']) > MAX_HISTORY:
            raise ValueError('Snapshot does not match this engine and game')

        def decode(frame):
            if not isinstance(frame, dict) or not isinstance(frame.get('native'), str) or \
                    type(frame.get('action_count')) is not int or frame['action_count'] < 0:
                raise ValueError('Invalid saved action frame')
            player = self.valid_player(frame.get('player'))
            state = frame.get('random')
            if not isinstance(state, list) or len(state) != 3 or not isinstance(state[1], list):
                raise ValueError('Invalid saved chance sampler')
            if state[2] is not None and (type(state[2]) not in (int, float) or not math.isfinite(state[2])):
                raise ValueError('Invalid saved Gaussian sample')
            generator = random.Random()
            generator.setstate((state[0], tuple(state[1]), state[2]))
            game, native = pyspiel.deserialize_game_and_state(frame['native'])
            if str(game) != str(self.game) or native.is_chance_node():
                raise ValueError('Snapshot native state does not match its game')
            return native, generator.getstate(), player, frame['action_count']

        current = decode(saved.get('current'))
        past = [decode(frame) for frame in saved['past']]
        future = [decode(frame) for frame in saved['future']]
        self.use_frame(current)
        self.past, self.future, self.seed = past, future, saved['seed']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game')
    parser.add_argument('--player', type=int, default=0)
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--list', action='store_true', help='List native registered game names.')
    parser.add_argument('--version', action='version', version=f'OpenSpiel {VERSION}')
    options = parser.parse_args()
    if options.list:
        print(json.dumps(pyspiel.registered_names()))
        return 0
    if not options.game:
        parser.error('--game is required unless --list is used')
    match = Match(options.game, options.player, options.seed)
    revision = previous_id = 0
    connected = False
    capabilities = ['act', 'joint-action', 'set-player', 'undo', 'redo', 'reset', 'save', 'load']
    if match.supports_bot():
        capabilities.append('bot')
    while True:
        raw = sys.stdin.buffer.readline(MAX_MESSAGE + 2)
        if not raw:
            return 0
        if len(raw) > MAX_MESSAGE + 1 or not raw.endswith(b'\n'):
            raise ValueError('Oversized or incomplete GameKit request')
        if not raw.strip():
            continue
        request = json.loads(raw)
        if not isinstance(request, dict) or request.get('version') != 1 or \
                type(request.get('id')) is not int or request['id'] <= previous_id or \
                not isinstance(request.get('op'), str) or not isinstance(request.get('args'), dict):
            raise ValueError('Malformed GameKit request')
        previous_id = request['id']
        failure = None
        try:
            if request['op'] == 'start' and not connected:
                connected = True
            else:
                if not connected or request['op'] not in capabilities:
                    raise ValueError('Start once before sending advertised actions')
                match.command(request['op'], request['args'])
        except (ValueError, TypeError, RuntimeError, OSError, KeyError) as error:
            failure = str(error) or type(error).__name__
        revision += 1
        response = json.dumps({'version': 1, 'id': previous_id, 'revision': revision,
                               'capabilities': capabilities, 'observation': match.observe(), 'error': failure},
                              allow_nan=False, ensure_ascii=False)
        if len(response.encode('utf-8')) > MAX_MESSAGE:
            raise ValueError('Observation exceeds 1 MiB')
        print(response, flush=True)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, TypeError, RuntimeError, OSError) as error:
        print(f'OpenSpiel adapter failed: {error}', file=sys.stderr)
        sys.exit(2)
