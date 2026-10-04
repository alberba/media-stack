const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname,
    '../stacks/jellyfin/web/syncplay-web-player.js'), 'utf8');

test('the compatibility image uses the same Jellyfin version as the Core', () => {
    const core = fs.readFileSync(path.join(__dirname, '../stacks/jellyfin/compose.yaml'), 'utf8');
    const dockerfile = fs.readFileSync(path.join(__dirname, '../stacks/jellyfin/Dockerfile'), 'utf8');
    assert.equal(dockerfile.match(/^ARG JELLYFIN_IMAGE=(.+)$/m)[1], core.match(/image:\s*(\S+)/)[1]);
});

function app({ active = null, stop = async () => {}, players = true, requestError = null } = {}) {
    const calls = [];
    const web = { id: 'htmlvideoplayer', isLocalPlayer: true };
    const playback = {
        syncPlayEnabled: false,
        _currentPlayer: active,
        getPlayers: () => players ? [web] : [],
        stop: async player => { calls.push(['stop', player.id]); await stop(); },
        setActivePlayer: player => {
            calls.push(['select', player.id]);
            playback._currentPlayer = player;
        }
    };
    const native = id => ({ id, isLocalPlayer: true, playbackManager: playback,
        canPlayItem(item, options) { return options.fullscreen && !this.playbackManager.syncPlayEnabled; }
    });
    const integrated = native('exoplayer');
    const external = native('externalplayer');
    const callbacks = [];
    const api = {
        subscribe(types, callback) { callbacks.push(callback); },
        async createSyncPlayGroup(options) {
            calls.push(['create', options, integrated.canPlayItem({}, { fullscreen: true })]);
            return 'created';
        },
        async joinSyncPlayGroup(options) {
            if (requestError) throw requestError;
            calls.push(['join', options, external.canPlayItem({}, { fullscreen: true })]);
            return 'joined';
        }
    };
    const window = { ExoPlayer: integrated, ExtPlayer: external, ApiClient: api,
        setInterval: callback => { window.poll = callback; } };
    const context = vm.createContext({ window, console });
    vm.runInContext(source, context);
    function update(Type) {
        if (Type === 'GroupJoined') playback.syncPlayEnabled = true;
        if (Type === 'GroupLeft') playback.syncPlayEnabled = false;
        callbacks.forEach(callback => callback({ Data: { Type } }));
    }
    return { calls, web, playback, integrated, external, api, window, context, update };
}

test('both participants select the web player before creating/joining', async () => {
    const host = app();
    const guest = app();
    assert.equal(await host.api.createSyncPlayGroup({ GroupName: 'Movie night' }), 'created');
    assert.equal(await guest.api.joinSyncPlayGroup({ GroupId: 'group' }), 'joined');
    assert.deepEqual(host.calls.map(c => c[0]), ['select', 'create']);
    assert.deepEqual(guest.calls.map(c => c[0]), ['select', 'join']);
    assert.equal(host.calls[1][2], false);
    assert.equal(guest.calls[1][2], false);
    host.update('GroupJoined');
    guest.update('GroupJoined');
    for (const participant of [host, guest]) {
        assert.equal(participant.playback._currentPlayer.id, 'htmlvideoplayer');
        assert.equal(participant.external.canPlayItem({}, { fullscreen: true }), false);
        participant.update('GroupLeft');
        assert.equal(participant.integrated.canPlayItem({}, { fullscreen: true }), true);
        assert.equal(participant.external.canPlayItem({}, { fullscreen: true }), true);
    }
});

test('waits for an active native player to stop before sending the request', async () => {
    let stopped;
    const state = app({ stop: () => new Promise(resolve => { stopped = resolve; }) });
    state.playback._currentPlayer = state.integrated;
    const request = state.api.joinSyncPlayGroup({ GroupId: 'group' });
    await Promise.resolve();
    assert.deepEqual(state.calls, [['stop', 'exoplayer']]);
    stopped();
    await request;
    assert.deepEqual(state.calls.map(c => c[0]), ['stop', 'select', 'join']);
});

test('failed requests release the native player guard', async () => {
    const state = app({ players: false });
    await assert.rejects(state.api.joinSyncPlayGroup({}), /not available/);
    assert.equal(state.calls.length, 0);
    assert.equal(state.integrated.canPlayItem({}, { fullscreen: true }), true);
});

test('does not interrupt casting or remote playback', async () => {
    const state = app({ active: { id: 'remoteplayer', isLocalPlayer: false } });
    await assert.rejects(state.api.createSyncPlayGroup({}), /select this device/);
    assert.equal(state.calls.length, 0);
});

test('denied group membership releases the guard', async () => {
    const state = app();
    await state.api.joinSyncPlayGroup({});
    state.update('JoinGroupDenied');
    assert.equal(state.external.canPlayItem({}, { fullscreen: true }), true);
});

test('installs once, including a replacement API client', async () => {
    const state = app();
    const original = state.api.joinSyncPlayGroup;
    vm.runInContext(source, state.context);
    state.window.poll();
    assert.equal(state.api.joinSyncPlayGroup, original);
    const replacement = app();
    state.window.ApiClient = replacement.api;
    state.window.poll();
    await state.window.ApiClient.joinSyncPlayGroup({ GroupId: 'other-server' });
    assert.equal(state.calls[0][0], 'select');
});

test('HTTP/network failures release the native player guard', async () => {
    const state = app({ requestError: new Error('Offline') });
    await assert.rejects(state.api.joinSyncPlayGroup({}), /Offline/);
    assert.equal(state.integrated.canPlayItem({}, { fullscreen: true }), true);
});

test('native plugins registered after startup are detected', async () => {
    const state = app();
    const delayed = { ApiClient: state.api, setInterval(callback) { this.poll = callback; } };
    vm.runInNewContext(source, { window: delayed });
    delayed.ExoPlayer = state.integrated;
    delayed.ExtPlayer = state.external;
    delayed.poll();
    await delayed.ApiClient.joinSyncPlayGroup({});
    assert.equal(state.playback._currentPlayer.id, 'htmlvideoplayer');
});

test('browsers without Android native plugins are untouched', () => {
    let subscribed = false;
    const api = { subscribe() { subscribed = true; } };
    const window = { ApiClient: api, setInterval() {} };
    vm.runInNewContext(source, { window });
    assert.equal(subscribed, false);
});
