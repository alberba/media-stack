# SyncPlay in Jellyfin Android

The integrated and external players in Jellyfin Android explicitly reject SyncPlay
in their `canPlayItem` methods. They have no SyncPlay player wrapper. A group can
exist even when a participant's current native player cannot follow it.

The optional compatibility image selects Jellyfin's web video player **before**
the app creates or joins a group. It stops any active native playback first and
keeps native players out of selection while joining or in a group. Leaving the
group restores normal player selection; it does not change the app's saved player
preference. Both Android devices use the web player within the existing app.

## Enable

From the Template root, add the override to the Compose files used by the Instance:

```bash
docker compose -f compose.yaml -f compose.syncplay.yaml up -d --build --no-deps jellyfin
```

If the Instance uses the GPU override, include it as well:

```bash
docker compose -f compose.yaml -f compose.gpu.yaml -f compose.syncplay.yaml up -d --build --no-deps jellyfin
```

Close and reopen the app on both devices to load the new web client. Create a new
group from the home screen, join on the second device, then start the movie.
Verify that both display the video and that pause, resume and seek affect both.
Joining while a native video is open stops that local video; start the group's
movie after joining. Casting is left alone: select this device before joining.

The server image and App data schema remain at the Core version. The custom image
only adds a JavaScript asset and loads it from `index.html`. On image updates,
keep the Dockerfile's `JELLYFIN_IMAGE` equal to the Core image and rebuild. Use this
override on subsequent Compose updates; omitting it restores the official image.
To keep it enabled for ordinary `docker compose` commands, append
`:compose.syncplay.yaml` to `COMPOSE_FILE` in the Instance's `.env` (or set
`COMPOSE_FILE=compose.yaml:compose.syncplay.yaml` if it was unset). When disabling,
remove this file from `COMPOSE_FILE` too. The setup assistant's GPU question resets
`COMPOSE_FILE`; append the SyncPlay override again if you rerun that step.

## A group joins but playback never starts on the other device

A saved Android login can retain the old client name `Jellyfin Android`, while
the current app sends HTTP requests as `Jellyfin for Android`. Jellyfin associates
WebSocket connections using the login token's stored client name, but SyncPlay
requests use the HTTP client's name. Those names can therefore create two sessions
for the same device: one receives the events, while the other owns the group.

The compatibility script cannot renew an Android login token. Sign out and sign
back in on the affected device, then create a fresh group. Merely closing the app
keeps the existing token. In Dashboard > Devices/Sessions, the active session for
the device should now match the current app name. This diagnosis can be confirmed
by comparing the session attached to a WebSocket with the one in SyncPlay logs;
there is no need to enable legacy authentication or edit the database.

## Disable

Recreate Jellyfin using the Instance's original Compose files, for example:

```bash
docker compose -f compose.yaml -f compose.gpu.yaml up -d --no-deps jellyfin
```

App data, media mounts and the Android app's player preference are preserved.

## Validation

```bash
node --test tests/syncplay-web-player.test.cjs
docker build -t media-stack-jellyfin-syncplay:local stacks/jellyfin
```

The tests verify player selection before group requests, native teardown, denied
requests, restoring selection on leave, switching servers, and desktop isolation.
They do not replace a playback test on physical Android devices. Web playback can
require transcoding for formats supported only by the native player.

Sources: [Android integrated player](https://github.com/jellyfin/jellyfin-android/blob/master/app/src/main/assets/native/ExoPlayerPlugin.js),
[Android external player](https://github.com/jellyfin/jellyfin-android/blob/master/app/src/main/assets/native/ExternalPlayerPlugin.js),
[SyncPlay player wrappers](https://github.com/jellyfin/jellyfin-web/tree/master/src/plugins/syncPlay/ui/players).
