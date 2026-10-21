# Overlay

An overlay for Spotify on macOS. Press a shortcut from any app, even full screen, to bring up the current song, playback controls and your playlists over whatever you're doing, then press it again to get back to work. Think Steam overlay, for music.

Not affiliated with, endorsed or sponsored by Spotify.

## Features

- **⌥`** (changeable) opens and closes it on the screen your mouse is on; Esc or clicking outside also closes it
- Current song with artwork, play/pause, previous, next and volume
- Your playlists in a grid; open one to see every song and click to play it
- Stays fixed on screen while you swipe between Spaces
- Lives in the menu bar (♪), no Dock icon

## What you need

| | Free Spotify | Spotify Premium |
|---|---|---|
| Now playing, controls, volume | ✅ no setup | ✅ no setup |
| Playlists and playing songs from them | ❌ | ✅ after a 2-minute setup |

- macOS 13 or later and the Spotify desktop app.
- Playlists use the Spotify Web API. Spotify requires whoever owns the developer app to have Premium, and only lets apps start playback for Premium accounts.
- Spotify only shares the songs of playlists you own or collaborate on. Others show their cover but no songs.

## Install

### Download

1. Download `Overlay-x.y.z.zip` from [Releases](../../releases), unzip it and move `Overlay.app` to Applications.
2. Open it. Overlay isn't notarized by Apple, so macOS will block it the first time. Go to **System Settings → Privacy & Security** and click **Open Anyway**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Overlay.app
   ```

### Build from source

Needs Apple's command line tools (`xcode-select --install`).

```bash
./build.sh
open Overlay.app
```

To start it when you log in, add it under **System Settings → General → Login Items**.

The first time Overlay talks to Spotify, macOS asks for permission to control it. Click **Allow**.

## Setting up playlists (Premium)

1. Go to the [Spotify developer dashboard](https://developer.spotify.com/dashboard) and create an app. Don't put "Spotify" in its name.
2. Tick **Web API** and add this redirect URI exactly: `http://127.0.0.1:8765/callback`
3. Open Overlay, click **‹ Playlists**, paste the app's **Client ID** and click **Continue**, then **Log in**.

Your developer app can have up to 5 users. To share yours, add their Spotify email under **User Management**; otherwise each person sets up their own.

## Changing the shortcut

Click the shortcut button at the top right of the player, then press the new combination. It needs ⌘, ⌥ or ⌃. Esc cancels.

## Privacy

Overlay has no server and sends nothing anywhere except to Spotify.

- Your Client ID is saved in `~/Library/Application Support/Overlay/client_id.txt`.
- Your Spotify login token is saved in Overlay's preferences on your Mac.
- Playlist and song data is fetched when you look at it and isn't stored.
- **♪ → Log Out of Spotify** deletes the saved login. Delete the folder above to remove the Client ID.

## Notes

- To stay put while you swipe between Spaces, Overlay uses undocumented macOS functions. A future macOS update could break that; everything else would keep working.
- Playback controls on the player use Spotify's AppleScript support; playlists use the Spotify Web API.

## Releasing

```bash
./release.sh
```

Builds a universal (Apple Silicon + Intel) `Overlay.app`, zips it as `Overlay-<version>.zip` and prints its checksum. Bump `VERSION` in `build.sh` first, then upload the zip to a GitHub release tagged `v<version>`.

## License

[MIT](LICENSE). The Spotify logo in `assets/` is a trademark of Spotify AB and isn't covered by this license; it's included only for the attribution Spotify requires.
