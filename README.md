# ARENA FFA

Multiplayer free-for-all FPS, playable **in the browser** and on desktop.
Built with Godot 4.4 on top of the `fpsdemo` assets, the map/weapon packs
in `assets mapa y armas`, and the character GLBs from `Personaje`.

## Play NOW (local)

You need Godot 4.4.1 — there's a copy at `~/Downloads/Godot.app`
(the `godot` command below is `~/Downloads/Godot.app/Contents/MacOS/Godot`).

1. **Game server** (headless, port 8910):
   ```bash
   godot --headless -- server
   ```
2. **Serve the web build** (any port):
   ```bash
   python3 -m http.server 8091 --directory build/web
   ```
3. Open `http://127.0.0.1:8091/` in a browser (one tab per player).
   Menu → PLAY → pick your character and name → FIND MATCH → you drop
   straight into the endless match. Click once to grab the mouse.

It also runs **native**: open the project with Godot and use CREATE ROOM
(LAN host) or JOIN BY IP. LAN discovery only exists on native builds.

## Rules

- **One endless online match** (dedicated server): you drop straight into
  the action — no lobby. The dashboard resets every **30 minutes**; each
  cycle's results are saved on the server (`user://match_history.json`)
  and the winner is announced to everyone.
- The server keeps the room populated with server-driven players so the
  match always feels alive.
- LAN/hosted rooms (native CREATE ROOM) still play classic rounds:
  first to 10 kills or best in 5 minutes, with a 3-2-1 countdown.
- **All 6 weapons from the start** (keys 1-6 or mouse wheel): Knife,
  Pistol, MAC-10 (auto), Shotgun, AK-47 (auto), AWP.
- **Headshots** deal 1.5x damage (red hitmarker + ☠ in the feed).
- **Damage falls off** with distance past half of each gun's range.
- **Kills heal you +25 HP.** Medkits (+40) and spinning ammo boxes
  respawn around the map; climb the stacked crates to reach rooftops.
- **Right-click to aim** (ADS); the AWP has a real 4x scope overlay.
- **Enter = text chat** with everyone in the match.
- **Radar** (bottom-left): nearby enemies, and anyone who just fired.
- Kill streaks are announced (DOUBLE KILL, TRIPLE KILL, RAMPAGE...).
- Damage direction indicators show where you're being shot from.
- Tab = live scoreboard with the **ALL-TIME top-3** footer (persisted on
  the server across dashboard resets). ESC = pause (with quick settings).
- Score: 100 per kill, +50 for headshots (SCORE column in the scoreboard).
- Ping + FPS shown in the corner (toggle in Settings). All sounds are
  100% procedural — footsteps included.

## Adding characters

Drop a `.glb` into `Characters/Models/` and add one entry to
`Characters/manifest.json` (id, name, model, animation clips).
No code changes. If the model is missing animations, the game says so on
the character screen and uses procedural fallbacks.

## Layout

- `Autoload/Net.gd` — WebSocket session, players, scores, round (server-authoritative)
- `Actors/Player/NetPlayer.gd` — networked player; the server resolves shots/damage/kills; bot AI
- `Weapons/WeaponDefs.gd` — weapon stats shared by client and server
- `Levels/Arena.gd` — map built from the FBX kit + collisions + pickups
- `UI/Menus/Menu.gd` — full menu (main/character/lobby/settings/results)
- `UI/HUD/MatchHUD.gd` — scoreboard, kill feed, leader, death, pause
- `Autoload/AutoTest.gd` — test harness (`-- autotest=server|host|join|solo`)

## Public deploy

See [DEPLOY.md](DEPLOY.md). Only the hosting (owner's credentials) is missing.
