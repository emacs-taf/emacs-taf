"""Exercise native backend command, observation and snapshot contracts."""
import json
import hashlib
import os
from pathlib import Path
import platform
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'emacs-taf/game-engines'


class Engine:
    def __init__(self, command=None, expected_stderr=''):
        self.number = self.revision = 0
        self.expected_stderr = expected_stderr
        self.messages = queue.Queue()
        self.process = subprocess.Popen(
            command or [str(CACHE / 'bin/godot'), '--headless', '--no-header', '--path',
             str(ROOT / 'tests/fixtures/godot'), '--script', str(ROOT / 'native/godot/gamekit.gd')],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8')
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            self.messages.put(line)
        self.messages.put(None)

    def receive(self, timeout=10):
        line = self.messages.get(timeout=timeout)
        if line is None:
            raise AssertionError('Backend stopped: ' + self.process.stderr.read())
        result = json.loads(line)
        assert result['version'] == 1
        assert result['revision'] > self.revision
        self.revision = result['revision']
        return result

    def request(self, operation, **payload):
        self.number += 1
        self.process.stdin.write(json.dumps({'version': 1, 'id': self.number,
                                             'op': operation, 'args': payload}) + '\n')
        self.process.stdin.flush()
        while True:
            result = self.receive()
            if result['id'] == self.number:
                return result
            assert result['id'] is None

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError('Backend did not exit after stdin closed')
        finally:
            self.reader.join(timeout=1)
            error = self.process.stderr.read()
            self.process.stdout.close()
            self.process.stderr.close()
        if self.process.returncode != 0 or error != self.expected_stderr:
            raise AssertionError(f'Unexpected engine exit/diagnostics: {self.process.returncode}: {error!r}')


class GodotBridgeContract(unittest.TestCase):
    def test_project_commands_rejections_and_start_lifetime(self):
        engine = Engine()
        self.addCleanup(engine.close)
        started = engine.request('start')
        self.assertEqual(started['observation'], {'schema': 'counter/1', 'count': 0})
        self.assertIsNone(started['error'])
        self.assertTrue(engine.request('start')['error'])
        bad = engine.request('increment', amount='invalid')
        self.assertTrue(bad['error'])
        self.assertEqual(bad['observation'], started['observation'])
        changed = engine.request('increment', amount=3)
        self.assertIsNone(changed['error'])
        self.assertEqual(changed['observation']['count'], 3)


class EngineSetupContract(unittest.TestCase):
    def test_setup_installs_a_verified_release_and_replaces_a_stale_archive(self):
        """A local release copy exercises download, repair and rejection offline."""
        if sys.platform not in ('darwin', 'linux'):
            self.skipTest('the pinned releases cover macOS and Linux')
        machine = platform.machine().lower()
        key = ('macos-universal' if sys.platform == 'darwin' else
               f'linux-{"arm64" if machine in ("arm64", "aarch64") else machine}')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'package'
            shutil.copytree(ROOT / 'native/godot', root / 'native/godot')
            release = Path(directory) / 'release'
            release.mkdir()
            engine = release / 'godot'
            engine.write_text('#!/bin/sh\necho 4.7.2.stable.official\n')
            engine.chmod(0o755)
            archive = release / 'pinned-godot.zip'
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.write(engine, 'fake-godot')
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            manifest = {'version': '4.7.2', 'license': 'test',
                        'platforms': {key: {'url': archive.as_uri(), 'sha256': digest,
                                            'executable': 'fake-godot'}}}
            (root / 'native/godot/engine-sources.json').write_text(json.dumps(manifest))
            cache = Path(directory) / 'cache'
            command = ['python3', str(root / 'native/godot/install-godot.py'), '--cache', str(cache)]
            installed = subprocess.run(command, capture_output=True, text=True, check=True)
            self.assertTrue(Path(json.loads(installed.stdout)['godot']).is_symlink())
            # An interrupted download leaves an archive that can never verify;
            # the next run has to drop it instead of failing the same way again.
            shutil.rmtree(next(cache.glob('godot-4.7.2-*')))
            (cache / 'pinned-godot.zip').write_bytes(b'truncated')
            repaired = subprocess.run(command, capture_output=True, text=True, check=True)
            self.assertIn('4.7.2', json.loads(repaired.stdout)['version'])
            self.assertEqual(hashlib.sha256((cache / 'pinned-godot.zip').read_bytes()).hexdigest(), digest)
            # Bytes that do not match the pinned checksum are refused and cleaned up.
            shutil.rmtree(next(cache.glob('godot-4.7.2-*')))
            manifest['platforms'][key]['sha256'] = '0' * 64
            (root / 'native/godot/engine-sources.json').write_text(json.dumps(manifest))
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(rejected.returncode, 1)
            self.assertIn('Checksum mismatch', rejected.stderr)
            self.assertFalse((cache / 'pinned-godot.zip').exists())

    def test_setup_manifest_missing_cache_and_existing_executable(self):
        command = ['python3', str(ROOT / 'native/godot/install-godot.py')]
        manifest = subprocess.run([*command, '--manifest'], capture_output=True, text=True, check=True)
        self.assertIn('sha256', json.loads(manifest.stdout)['platforms']['macos-universal'])
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([*command, '--check', '--cache', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Engine setup failed', result.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])
            installed = subprocess.run([*command, '--cache', directory, '--godot', str(CACHE / 'bin/godot')],
                                       capture_output=True, text=True, check=True)
            self.assertTrue(Path(json.loads(installed.stdout)['godot']).is_symlink())
            checked = subprocess.run([*command, '--check', '--cache', directory],
                                     capture_output=True, text=True, check=True)
            self.assertIn('4.', json.loads(checked.stdout)['version'])

    def test_openspiel_setup_names_its_command_and_refuses_an_old_interpreter(self):
        """A missing environment reports the install command and writes nothing."""
        script = ROOT / 'native/openspiel/install-openspiel.py'
        with tempfile.TemporaryDirectory() as directory:
            command = ['python3', str(script), '--cache', directory]
            missing = subprocess.run([*command, '--check'], capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn('etaf-gamekit-install-openspiel', missing.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])
            # An interpreter below 3.11 is rejected before anything is written.
            old = Path(directory) / 'python-old'
            old.write_text('#!/bin/sh\necho 3.10.9\n')
            old.chmod(0o755)
            rejected = subprocess.run([*command, '--python', str(old)], capture_output=True, text=True)
            self.assertEqual(rejected.returncode, 1)
            self.assertIn('Python 3.11 or newer is required', rejected.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [old])


class RuleKernelContracts(unittest.TestCase):
    def backend(self, name, game=None, expected_stderr=''):
        if name == 'boardgame-io':
            command = ['node', str(ROOT / 'native/boardgame-io/bridge.cjs'), '--game',
                       str(ROOT / 'tests/fixtures/tabletop.cjs'), '--player', '0', '--seed', 'contract']
        else:
            command = [str(CACHE / 'openspiel/bin/python'), str(ROOT / 'native/openspiel/bridge.py'),
                       '--game', game, '--player', '0', '--seed', '42']
        engine = Engine(command, expected_stderr)
        self.addCleanup(engine.close)
        response = engine.request('start')
        self.assertIsNone(response['error'])
        return engine, response['observation']

    def test_boardgame_rules_turns_phases_undo_and_player_views(self):
        engine, before = self.backend('boardgame-io', expected_stderr='ERROR: invalid move: claim args: 99\n')
        self.assertNotIn('hands', before['state']['G'])
        rejected = engine.request('move', name='claim', args=[99])
        self.assertTrue(rejected['error'])
        self.assertEqual(rejected['observation'], before)
        self.assertEqual(engine.request('move', name='claim', args=[2])['observation']['state']['G']['pool'], 10)
        self.assertEqual(engine.request('undo')['observation']['state']['G']['pool'], 12)
        self.assertEqual(engine.request('redo')['observation']['state']['G']['pool'], 10)
        self.assertEqual(engine.request('event', name='endTurn')['observation']['state']['ctx']['currentPlayer'], '1')
        inactive = engine.request('move', name='claim', args=[2])
        self.assertTrue(inactive['error'])
        engine.request('set-player', player='1')
        engine.request('move', name='claim', args=[3])
        engine.request('event', name='endTurn')
        engine.request('set-player', player='0')
        final = engine.request('move', name='claim', args=[1])
        self.assertIsNone(final['error'])
        self.assertEqual(final['observation']['state']['ctx']['phase'], 'final')
        spectator = engine.request('set-player', player=None)['observation']
        self.assertIsNone(spectator['state']['G']['hand'])

    def test_boardgame_replay_snapshot_restores_rng_and_rejects_bad_input(self):
        engine, _ = self.backend('boardgame-io')
        engine.request('move', name='claim', args=[2])
        before = engine.request('set-player', player='1')['observation']
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'tabletop.snapshot'
            self.assertIsNone(engine.request('save', path=str(target))['error'])
            engine.request('reset')
            loaded = engine.request('load', path=str(target))
            self.assertIsNone(loaded['error'])
            self.assertEqual(loaded['observation'], before)
            for text in ('{}', '{broken', '[]'):
                target.write_text(text)
                bad = engine.request('load', path=str(target))
                self.assertTrue(bad['error'])
                self.assertEqual(bad['observation'], before)

    def test_openspiel_resolves_chance_and_validates_player_actions(self):
        engine, before = self.backend('openspiel', 'kuhn_poker')
        self.assertEqual(before['current_player'], 0)
        self.assertEqual([a['id'] for a in before['legal_actions']], [0, 1])
        bad = engine.request('act', action=999)
        self.assertTrue(bad['error'])
        self.assertEqual(bad['observation'], before)
        passed = engine.request('act', action=0)['observation']
        self.assertEqual(passed['current_player'], 1)
        self.assertEqual(passed['legal_actions'], [])
        self.assertTrue(engine.request('act', action=0)['error'])
        engine.request('set-player', player=1)
        ended = engine.request('act', action=0)['observation']
        self.assertTrue(ended['terminal'])
        self.assertEqual(sum(ended['returns']), 0)
        self.assertTrue(engine.request('act', action=0)['error'])

    def test_openspiel_simultaneous_actions_use_the_native_joint_transition(self):
        engine, before = self.backend('openspiel', 'matrix_rps')
        self.assertTrue(before['simultaneous'])
        self.assertEqual(len(before['legal_actions']), 3)
        bad = engine.request('joint-action', actions=[0])
        self.assertTrue(bad['error'])
        self.assertEqual(bad['observation'], before)
        ended = engine.request('joint-action', actions=[0, 1])
        self.assertIsNone(ended['error'])
        self.assertTrue(ended['observation']['terminal'])
        self.assertEqual(ended['observation']['returns'], [-1, 1])

    def test_openspiel_native_snapshot_preserves_progress_and_future_legality(self):
        engine, _ = self.backend('openspiel', 'kuhn_poker')
        before = engine.request('act', action=0)['observation']
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'native.snapshot'
            self.assertIsNone(engine.request('save', path=str(target))['error'])
            engine.request('reset')
            restored = engine.request('load', path=str(target))
            self.assertIsNone(restored['error'])
            self.assertEqual(restored['observation'], before)
            target.write_text('{}')
            rejected = engine.request('load', path=str(target))
            self.assertTrue(rejected['error'])
            self.assertEqual(rejected['observation'], before)
        engine.request('set-player', player=1)
        self.assertTrue(engine.request('act', action=0)['observation']['terminal'])

    def test_openspiel_undo_redo_restores_chance_and_survives_snapshots(self):
        engine, initial = self.backend('openspiel', 'solitaire')
        self.assertFalse(initial['can_undo'])
        self.assertTrue(engine.request('undo')['error'])
        action = next(item['id'] for item in initial['legal_actions'] if item['id'] != 0)
        played = engine.request('act', action=action)['observation']
        self.assertEqual(played['action_count'], 1)
        undone = engine.request('undo')['observation']
        expected = dict(initial, can_redo=True)
        self.assertEqual(undone, expected)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'history.snapshot'
            self.assertIsNone(engine.request('save', path=str(target))['error'])
            engine.request('reset', seed=123)
            self.assertEqual(engine.request('load', path=str(target))['observation'], expected)
            self.assertEqual(engine.request('redo')['observation'], played)
        engine.request('undo')
        self.assertEqual(engine.request('act', action=action)['observation'], played)
        self.assertTrue(engine.request('redo')['error'])

    def test_openspiel_seeded_reset_and_invalid_history_are_atomic(self):
        engine, initial = self.backend('openspiel', 'solitaire')
        other = engine.request('reset', seed=99)['observation']
        self.assertNotEqual(other['observation'], initial['observation'])
        self.assertEqual(engine.request('reset', seed=42)['observation'], initial)
        rejected = engine.request('reset', seed='not-an-integer')
        self.assertTrue(rejected['error'])
        self.assertEqual(rejected['observation'], initial)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'history.snapshot'
            engine.request('save', path=str(target))
            saved = json.loads(target.read_text())
            saved['past'] = [{'native': 3}]
            target.write_text(json.dumps(saved))
            rejected = engine.request('load', path=str(target))
            self.assertTrue(rejected['error'])
            self.assertEqual(rejected['observation'], initial)

    def test_openspiel_search_takes_wins_for_either_side(self):
        cases = json.loads((ROOT / 'tests/fixtures/xiangqi-tactics.json').read_text())
        for case in cases:
            with self.subTest(player=case['player']):
                engine, _ = self.backend('openspiel', 'xiangqi')
                for turn, action in enumerate(case['actions']):
                    self.assertIsNone(engine.request('set-player', player=turn % 2)['error'])
                    self.assertIsNone(engine.request('act', action=action)['error'])
                # Bot ownership is the side to move, not the observer's seat.
                before = engine.request('set-player', player=1 - case['player'])['observation']
                self.assertFalse(before['terminal'])
                result = engine.request('bot', policy='search', depth=3, seconds=1)
                self.assertIsNone(result['error'])
                after = result['observation']
                self.assertTrue(after['terminal'])
                self.assertEqual(after['returns'][case['player']], 1)
                self.assertIn(after['bot']['action'], case['wins'])
                rejected = engine.request('bot', policy='search')
                self.assertTrue(rejected['error'])
                self.assertEqual(rejected['observation'], after)
                self.assertFalse(engine.request('undo')['observation']['terminal'])
                self.assertTrue(engine.request('redo')['observation']['terminal'])

    def test_openspiel_search_defends_against_the_opponents_reply(self):
        engine, _ = self.backend('openspiel', 'xiangqi')
        actions = [5761, 2338, 8098, 1, 7533, 373, 7816, 198, 6352, 90,
                   4723, 1192, 7990, 2003, 6352]
        for turn, action in enumerate(actions):
            engine.request('set-player', player=turn % 2)
            self.assertIsNone(engine.request('act', action=action)['error'])
        result = engine.request('bot', depth=2, seconds=1)
        self.assertIsNone(result['error'])
        self.assertNotIn(result['observation']['bot']['action'], [562, 1732])
        # With one ply, red must not have a winning reply to black's defense.
        reply = engine.request('bot', depth=1, seconds=1)
        self.assertIsNone(reply['error'])
        self.assertFalse(reply['observation']['terminal'])

    def test_openspiel_bot_deadline_rejection_and_round_history(self):
        engine, initial = self.backend('openspiel', 'xiangqi')
        for args in ({'depth': 0}, {'depth': True}, {'seconds': 0},
                     {'seconds': 20}, {'policy': 'missing'}):
            rejected = engine.request('bot', **args)
            self.assertTrue(rejected['error'])
            self.assertEqual(rejected['observation'], initial)
        result = engine.request('bot', depth=12, seconds=0.05)
        self.assertIsNone(result['error'])
        report = result['observation']['bot']
        self.assertIn(report['action'], [a['id'] for a in initial['legal_actions']])
        self.assertLess(report['elapsed'], 1)
        self.assertLess(report['depth'], report['requested_depth'])
        reply = engine.request('bot', policy='random')['observation']
        self.assertEqual(reply['action_count'], 2)
        before = dict(reply, bot=None)
        with tempfile.TemporaryDirectory() as directory:
            target = str(Path(directory) / 'round.snapshot')
            self.assertIsNone(engine.request('save', path=target)['error'])
            self.assertEqual(engine.request('undo', count=2)['observation']['action_count'], 0)
            self.assertEqual(engine.request('redo', count=2)['observation'], before)
            engine.request('reset')
            self.assertEqual(engine.request('load', path=target)['observation'], before)
        # Seeded bot choices do not consume the game's chance sampler.
        engine.request('reset')
        first = engine.request('bot', policy='random')['observation']
        engine.request('undo')
        replay = engine.request('bot', policy='random')['observation']
        self.assertEqual(first, replay)

    def test_openspiel_catalog_is_discoverable_without_starting_a_game(self):
        output = subprocess.run([str(CACHE / 'openspiel/bin/python'),
                                 str(ROOT / 'native/openspiel/bridge.py'), '--list'],
                                capture_output=True, text=True, check=True)
        self.assertEqual(output.stderr, '')
        self.assertTrue({'kuhn_poker', 'matrix_rps', 'tic_tac_toe'} <= set(json.loads(output.stdout)))


if __name__ == '__main__':
    unittest.main()
