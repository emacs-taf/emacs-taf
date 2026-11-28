#!/usr/bin/env python3
"""Controllable protocol peer for public transport/lifecycle scenarios."""
import json
import os
import sys
import time

mode = sys.argv[1]
revision = count = 0
for line in sys.stdin:
    request = json.loads(line)
    if mode == 'crash':
        sys.stderr.write('fixture engine stopped\n')
        sys.exit(7)
    if mode == 'hang':
        time.sleep(10)
        continue
    revision += 1
    if request['op'] == 'step':
        count += 1
    observation = {'schema': 'fixture/1', 'rows': ['frame-0'], 'pid': os.getpid(), 'count': count}
    reply = {'version': 1, 'id': request['id'], 'revision': revision,
             'capabilities': ['step'], 'observation': observation, 'error': None}
    if mode == 'large':
        observation['tensor'] = list(range(4000))
    if mode == 'stale' and request['op'] == 'step':
        reply['revision'] = 1
    if mode == 'uncorrelated':
        reply['id'] = 999
    if mode == 'malformed':
        observation['rows'] = 42
    if mode == 'missing-field':
        reply.pop('error')
    if mode == 'empty-error':
        reply['error'] = ''
    if mode == 'bad-object':
        reply = 42
    if mode == 'bad-observation':
        reply['observation'] = []
    if mode == 'oversized':
        observation['rows'] = ['x' * (1024 * 1024 + 1)]
    if mode == 'rejection' and request['op'] == 'step':
        reply['error'] = 'Action rejected'
    encoded = json.dumps(reply) + '\n'
    if mode == 'split':
        middle = len(encoded) // 2
        sys.stdout.write(encoded[:middle])
        sys.stdout.flush()
        time.sleep(0.02)
        sys.stdout.write(encoded[middle:])
        sys.stdout.flush()
    else:
        print(encoded, end='', flush=True)
    if mode == 'rejection' and request['op'] == 'step':
        revision += 1
        reply.update(id=None, revision=revision, error=None)
        print(json.dumps(reply), flush=True)
    if mode == 'burst' and request['op'] == 'step':
        for number in range(1, 101):
            revision += 1
            reply.update(id=None, revision=revision)
            observation['rows'] = [f'{number:08d}']
            print(json.dumps(reply), flush=True)
