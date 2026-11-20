#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Public boardgame.io Client API; stdout belongs exclusively to GameKit.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { Console } = require('node:console');
const { pathToFileURL } = require('node:url');
global.console = new Console(process.stderr, process.stderr);
const { Client } = require('boardgame.io/client');
const engineVersion = require('boardgame.io/package.json').version;

const MAX_MESSAGE = 1024 * 1024;
const MAX_SNAPSHOT = 8 * MAX_MESSAGE;
const operations = ['move', 'event', 'undo', 'redo', 'reset', 'set-player', 'save', 'load'];
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

function argumentsFromCLI() {
  const result = {};
  for (let n = 2; n < process.argv.length; n += 2) {
    const name = process.argv[n];
    if (!['--game', '--num-players', '--player', '--seed'].includes(name) || n + 1 >= process.argv.length)
      throw new Error('Expected --game MODULE with optional --num-players, --player and --seed');
    result[name.slice(2)] = process.argv[n + 1];
  }
  result['num-players'] = Number(result['num-players'] || 2);
  if (!result.game || !Number.isInteger(result['num-players']) || result['num-players'] < 1 || result['num-players'] > 100)
    throw new Error('A readable game module and 1–100 players are required');
  return result;
}

function snapshotPath(args) {
  if (typeof args.path !== 'string' || !args.path) throw new Error('A snapshot path is required');
  return path.resolve(args.path);
}

function atomicWrite(destination, value) {
  const data = JSON.stringify(value);
  if (Buffer.byteLength(data) > MAX_SNAPSHOT) throw new Error('Snapshot exceeds 8 MiB');
  const temporary = `${destination}.${crypto.randomUUID()}.tmp`;
  try {
    fs.writeFileSync(temporary, data, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, destination);
  } finally {
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
  }
}

async function main() {
  if (process.argv.length === 3 && process.argv[2] === '--version') {
    process.stdout.write(`boardgame.io ${engineVersion}\n`);
    return;
  }
  const options = argumentsFromCLI();
  const filename = path.resolve(options.game);
  const imported = await import(pathToFileURL(filename).href);
  const game = imported.game || (imported.default && imported.default.game) || imported.default;
  if (!object(game)) throw new Error('The module must export a boardgame.io Game as default or game');
  const fingerprint = crypto.createHash('sha256').update(fs.readFileSync(filename)).digest('hex');
  const numPlayers = options['num-players'];
  const initialPlayer = options.player === undefined ? null : options.player;
  let seed = options.seed === undefined ? crypto.randomUUID() : options.seed;
  let journal = [];
  let revision = 0;
  let previousID = 0;
  let connected = false;

  function validPlayer(player) {
    return player === null || (typeof player === 'string' && /^\d+$/.test(player) && Number(player) < numPlayers);
  }
  if (!validPlayer(initialPlayer)) throw new Error('Player must be a valid player ID');

  function createClient(randomSeed) {
    const value = Client({ game: { ...game, seed: randomSeed }, numPlayers, playerID: initialPlayer, debug: false });
    value.start();
    return value;
  }
  let client = createClient(seed);

  function observe(value = client) {
    const state = value.getState();
    return {
      schema: 'boardgame.io/1', engine: { name: 'boardgame.io', version: engineVersion },
      game: { name: game.name || 'default', players: numPlayers }, player: value.playerID,
      state: { G: state.G, ctx: state.ctx, isActive: state.isActive },
      moves: Object.keys(value.moves), events: Object.keys(value.events),
    };
  }

  function apply(value, operation, args) {
    if (!object(args)) throw new Error('Action arguments must be an object');
    if (operation === 'set-player') {
      if (!Object.hasOwn(args, 'player') || !validPlayer(args.player)) throw new Error('Invalid player ID');
      value.updatePlayerID(args.player);
      return;
    }
    const before = value.getState()._stateID;
    if (operation === 'move' || operation === 'event') {
      const dispatchers = operation === 'move' ? value.moves : value.events;
      if (typeof args.name !== 'string' || !Object.hasOwn(dispatchers, args.name) ||
          (args.args !== undefined && !Array.isArray(args.args))) throw new Error('Unknown move/event or invalid argument array');
      if (!value.getState().isActive) throw new Error('This player is not active');
      dispatchers[args.name](...(args.args || []));
    } else if (operation === 'undo' || operation === 'redo' || operation === 'reset') {
      value[operation]();
    } else {
      throw new Error('Unsupported game operation');
    }
    if (operation !== 'reset' && value.getState()._stateID === before)
      throw new Error('The game rejected this action');
  }

  function restore(filename) {
    if (fs.statSync(filename).size > MAX_SNAPSHOT) throw new Error('Snapshot exceeds 8 MiB');
    const saved = JSON.parse(fs.readFileSync(filename, 'utf8'));
    if (!object(saved) || saved.schema !== 'gamekit.boardgame.io/snapshot-1' ||
        saved.engineVersion !== engineVersion || saved.fingerprint !== fingerprint ||
        saved.numPlayers !== numPlayers || saved.initialPlayer !== initialPlayer ||
        typeof saved.seed !== 'string' || !Array.isArray(saved.journal) || saved.journal.length > 100000)
      throw new Error('Snapshot does not match this game, engine or player configuration');
    const candidate = createClient(saved.seed);
    try {
      for (const action of saved.journal) {
        if (!object(action) || !['move', 'event', 'undo', 'redo', 'reset', 'set-player'].includes(action.op))
          throw new Error('Invalid snapshot action');
        apply(candidate, action.op, action.args);
      }
      if (JSON.stringify(observe(candidate)) !== JSON.stringify(saved.observation))
        throw new Error('Snapshot replay diverged; game rules must be deterministic');
    } catch (error) {
      candidate.stop();
      throw error;
    }
    client.stop();
    client = candidate;
    seed = saved.seed;
    journal = saved.journal;
  }

  function command(operation, args) {
    if (operation === 'save') {
      atomicWrite(snapshotPath(args), {
        schema: 'gamekit.boardgame.io/snapshot-1', engineVersion, fingerprint, numPlayers,
        initialPlayer, seed, journal, observation: observe(),
      });
    } else if (operation === 'load') {
      restore(snapshotPath(args));
    } else {
      apply(client, operation, args);
      journal.push({ op: operation, args });
    }
  }

  function emit(id, error = null) {
    const text = JSON.stringify({ version: 1, id, revision: ++revision,
      capabilities: operations, observation: observe(), error });
    if (Buffer.byteLength(text) > MAX_MESSAGE) throw new Error('Observation exceeds 1 MiB');
    process.stdout.write(text + '\n');
  }

  function receive(line) {
    if (!line.length) return;
    if (line.length > MAX_MESSAGE) throw new Error('Request exceeds 1 MiB');
    const request = JSON.parse(line.toString('utf8'));
    if (!object(request) || request.version !== 1 || !Number.isSafeInteger(request.id) ||
        request.id <= previousID || typeof request.op !== 'string' || !object(request.args))
      throw new Error('Malformed GameKit request');
    previousID = request.id;
    let failure = null;
    try {
      if (request.op === 'start' && !connected) connected = true;
      else {
        if (!connected || !operations.includes(request.op)) throw new Error('Start once before sending advertised actions');
        command(request.op, request.args);
      }
    } catch (error) {
      failure = error.message || String(error);
    }
    emit(request.id, failure);
  }

  let input = Buffer.alloc(0);
  process.stdin.on('data', chunk => {
    try {
      input = Buffer.concat([input, chunk]);
      let boundary;
      while ((boundary = input.indexOf(10)) !== -1) {
        receive(input.subarray(0, boundary));
        input = input.subarray(boundary + 1);
      }
      if (input.length > MAX_MESSAGE) throw new Error('Unterminated request exceeds 1 MiB');
    } catch (error) {
      console.error(error.message);
      client.stop();
      process.exit(2);
    }
  });
  process.stdin.on('end', () => {
    client.stop();
    if (input.length) { console.error('Incomplete final request'); process.exitCode = 2; }
  });
}

main().catch(error => { console.error(error.stack || error.message); process.exitCode = 2; });
