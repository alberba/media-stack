/* Android's native players do not implement SyncPlay. Select the web player
 * before joining, so the SyncPlay wrapper binds to a supported player. */
(function () {
    'use strict';

    if (window.MediaStackSyncPlayWebPlayer) return;
    const installedClients = new WeakSet();
    const installedPlayers = new WeakSet();
    let joining = false;
    let joined = false;
    let generation = 0;

    function nativePlayers() {
        return [window.ExoPlayer, window.ExtPlayer].filter(Boolean);
    }

    function manager() {
        return nativePlayers()[0]?.playbackManager;
    }

    function guardPlayers() {
        for (const player of nativePlayers()) {
            if (installedPlayers.has(player)) continue;
            const original = player.canPlayItem;
            if (typeof original !== 'function') continue;
            player.canPlayItem = function (...args) {
                return !(joining || joined || this.playbackManager.syncPlayEnabled)
                    && original.apply(this, args);
            };
            installedPlayers.add(player);
        }
    }

    async function prepareWebPlayer() {
        const playback = manager();
        if (!playback) return;
        const web = playback.getPlayers().find(player => player.id === 'htmlvideoplayer');
        if (!web) throw new Error('SyncPlay: the web video player is not available');
        const current = playback._currentPlayer;
        // Do not alter casting or another remote playback target.
        if (current && !current.isLocalPlayer) {
            throw new Error('SyncPlay: select this device before joining a group');
        }
        if (nativePlayers().includes(current)) {
            await playback.stop(current);
        }
        playback.setActivePlayer(web);
    }

    function installClient(client) {
        if (installedClients.has(client) || typeof client.subscribe !== 'function') return;
        for (const method of ['createSyncPlayGroup', 'joinSyncPlayGroup']) {
            if (typeof client[method] !== 'function') return;
        }
        installedClients.add(client);

        client.subscribe(['SyncPlayGroupUpdate'], ({ Data }) => {
            if (client !== window.ApiClient) return;
            if (Data.Type === 'GroupJoined') {
                joining = false;
                joined = true;
            } else if (['GroupLeft', 'NotInGroup', 'GroupDoesNotExist',
                'CreateGroupDenied', 'JoinGroupDenied', 'LibraryAccessDenied',
                'SyncPlayIsDisabled'].includes(Data.Type)) {
                joining = false;
                joined = false;
                generation++;
            }
        });

        for (const method of ['createSyncPlayGroup', 'joinSyncPlayGroup']) {
            const original = client[method];
            client[method] = async function (...args) {
                const attempt = ++generation;
                joining = true;
                guardPlayers();
                try {
                    await prepareWebPlayer();
                    return await original.apply(this, args);
                } catch (error) {
                    if (attempt === generation) joining = false;
                    throw error;
                }
            };
        }
    }

    let currentClient;
    function refresh() {
        // ExoPlayer and ExtPlayer are exported by Jellyfin Android's plugins.
        // Desktop browsers and other apps are left alone.
        if (!nativePlayers().length) return;
        guardPlayers();
        const client = window.ApiClient;
        if (!client) return;
        if (client !== currentClient) {
            currentClient = client;
            joining = false;
            joined = Boolean(manager()?.syncPlayEnabled);
            generation++;
        }
        installClient(client);
    }

    window.MediaStackSyncPlayWebPlayer = { refresh };
    refresh();
    // The app registers its native plugins after the web client starts. Keep
    // watching to cover login, logout and switching between saved servers.
    window.setInterval(refresh, 250);
})();
