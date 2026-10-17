# MacadeKit

The open-source part of [MaPC](https://mapc.games), the Mac app that plays Windows games from Steam, Epic, GOG,
Ubisoft and EA on Apple Silicon. MacadeKit is everything that decides *how* a game runs: the Wine engines, the
graphics backends (DXVK, D3DMetal, WineD3D), the environment each game gets, the store integrations, saves and
controllers. The app's interface and its licensing code are not part of this repository.

If a game doesn't work in MaPC, the fix is usually here: a DLL override, an environment variable, a backend
choice, a file a game needs in its environment. You can change it, test it on your own Mac with `mapc`, and send
a pull request.

## What's here

| Folder | What it is |
|---|---|
| `Sources/MacadeKit/Wine` | Engines, environments ("bottles"), graphics backends, the launch environment (`WineRunner`) |
| `Sources/MacadeKit/Library` | Game detection, including what a game's files say about its graphics (`GraphicsProbe`) |
| `Sources/MacadeKit/Stores` | Steam, Epic (via Legendary), GOG, Ubisoft Connect and EA app |
| `Sources/MacadeKit/Engine` | Engine download and checks, D3DMetal set-up from the user's own Game Porting Toolkit |
| `Sources/MacadeKit/Saves`, `Playtime`, `Shortcuts` | Save backups, play time, game links |
| `Sources/mapc` | `mapc`, a command-line tool that runs Windows programs the way the app does |
| `engine/` | How the engines are built from pinned upstream releases, and their license texts |
| `game-fixes/` | Fixes for single games that don't belong in the app (each with its own license) |

## Build and test

Needs macOS 15 and Xcode 16 or later.

```bash
swift test                     # unit tests (no Wine needed)
swift build --product mapc     # the test tool, at .build/debug/mapc
```

## Trying a change with `mapc`

`mapc` uses the engines and environments MaPC has already set up, so install MaPC and open it once first.
It reads MaPC's settings but never changes them.

```bash
mapc engines                                       # installed engines
mapc probe "/path/to/Game"                         # DirectX 12? 64-bit? what Automatic would pick
mapc env --bottle gog --backend dxvk               # the exact environment Wine would get
mapc run --bottle gog --backend wined3d --verbose 'C:\GOG Games\Some Game\Game.exe'
```

`run` waits for the program to exit and prints where its log is. Like the app, it won't start an environment
that is already running on a different engine; quit the game in MaPC first. To experiment without touching
your real environments, point `MACADE_HOME` at another folder.

Steam games usually need Steam running in the same environment, so for those run `steam.exe` with
`-applaunch <app id>`, or start Steam from MaPC and test from there.

## Building an engine

```bash
engine/build-engine.sh 1.0.0             # Wine Staging + DXVK (DirectX 9 to 11)
engine/build-engine-d3dmetal.sh 2.0.0    # Wine from CodeWeavers' CrossOver source, ready for D3DMetal
```

Every download is pinned by SHA-256. The output goes to `engine/dist` with a manifest; to use it, point MaPC at the
manifest with `MACADE_ENGINE_MANIFEST=file:///…/engine-manifest.json`. Needs `brew install mingw-w64` (and, for
the CrossOver build, `bison pkgconf freetype gnutls sdl2`).

**Apple's D3DMetal is never part of this repository or of any engine built from it.** Its license only allows
redistribution for non-commercial use, and DirectX 12 support in MaPC is offered as advanced and at the user's own
risk. MaPC copies D3DMetal from the user's own download of Apple's Game Porting Toolkit. Don't add D3DMetal files,
or anything else from Apple's toolkit, to a pull request.

## Contributing

- Keep changes small and focused, with a test where the logic can be tested without Wine (most of it can: see
  `Tests/`). Say which game you tested with and on which Mac.
- Nothing that sends data anywhere new, and no new downloads without a pinned SHA-256.
- By sending a pull request you agree that your contribution is licensed under the Apache License 2.0, the same
  as this repository.

## License

Apache License 2.0 (see [LICENSE](LICENSE) and [NOTICE](NOTICE)), except where a folder has its own LICENSE file
(for example `game-fixes/witcher3`, MIT). The engines are made of third-party software under their own licenses,
listed in `engine/licenses`. "MaPC" is a trademark of Steale LLC; the license doesn't grant use of the name or logo.
