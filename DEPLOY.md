# ARENA FFA — public deploy

Two pieces: the **game server** (headless Godot, WebSocket port 8910)
and the **web client** (`build/web/`, static files).

## Quick path: Render (recommended, free tier works)

The repo is already Render-ready: `render.yaml` defines both services, the
`Dockerfile` builds the game server, the server reads Render's `PORT` env
var, and `build/web/` (committed) is the static client.

1. Push this repo to GitHub (private is fine):
   ```bash
   git remote add origin https://github.com/YOUR_USER/arena-ffa.git
   git push -u origin main
   ```
2. In https://dashboard.render.com → **New → Blueprint** → pick the repo.
   Render creates both services from `render.yaml`:
   - `arena-ffa-server` (Docker web service) → note its URL, e.g.
     `https://arena-ffa-server-xxxx.onrender.com`
   - `arena-ffa-web` (static site) → e.g. `https://arena-ffa-web.onrender.com`
   (You can also create them by hand: New → Web Service (Docker) for the
   server, New → Static Site with publish directory `build/web`.)
3. Open the static site URL, PLAY → pick character → in the address field
   type the server host **without** `https://`:
   `arena-ffa-server-xxxx.onrender.com` → JOIN BY IP.
   The client auto-uses `wss://` for domains, and remembers the last
   server, so you only type it once. Share both URLs with friends.

Notes for Render:
- Free-tier services sleep after ~15 min idle; the first connection takes
  up to a minute to wake the server.
- The Docker build imports the Godot assets during `docker build`, so the
  first deploy takes several minutes.
- If the server deploy hangs on "waiting for port", set the service's
  health check to TCP (Settings → Health Checks) since the game server
  speaks WebSocket, not plain HTTP.

## 1. Game server

### Docker option (VPS, Fly.io, Railway, etc.)

```bash
docker build -t arena-ffa-server .
docker run -d -p 8910:8910 arena-ffa-server
```

The root `Dockerfile` downloads headless Godot and runs `-- server`.

### Direct option (any Linux/Mac with the Godot binary)

```bash
godot --headless -- server
```

## 2. Web client

`build/web/` is 100% static: upload it to Netlify, Vercel, GitHub Pages,
Cloudflare Pages or an nginx. To regenerate it:

```bash
godot --headless --export-release "Web" build/web/index.html
```

## 3. Connecting client and server

- The address field in the menu is pre-filled with the **page host**:
  if you serve the web build and the game server on the same machine or
  domain, FIND MATCH works without typing anything.
- If the server lives on another domain, players type the IP/host (or a
  full `ws://…`/`wss://…` URL) and use JOIN BY IP.

### IMPORTANT: https ⇒ wss

If the page is served over **https**, browsers require **wss://**
(WebSocket over TLS). Put a TLS reverse proxy in front of port 8910
(Caddy does it in two lines) and players connect with
`wss://yourdomain.com` (or whatever port you expose):

```
# Caddyfile
game.yourdomain.com {
    reverse_proxy localhost:8910
}
```

With the page over plain **http** (LAN testing), direct `ws://` works.

## 4. Room settings

- Port: `Net.PORT` (8910) in `Autoload/Net.gd`.
- Kill limit / round length: `Net.kill_limit` / `Net.round_seconds_total`.
- Max players: `Net.MAX_PLAYERS` (8).
- The dedicated server waits in the lobby; the first client to join is the
  leader and decides when to start (and the rematch), and can add bots.

**Test-server note**: `-- autotest=server` (used by the test harness)
auto-starts the match at ≥2 players; the normal `-- server` mode lets the
leader decide.
