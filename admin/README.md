# CZ Shooter — Panel Admin

Panel propio (con la marca CZ Shooter) para **repartir fees**: recibe los datos
del server del juego, los guarda en **Postgres (Neon)** de forma durable y los
muestra con login:

- **Podium Snapshots**: cada ciclo cerrado (inmutable, append-only) con sus
  ganadores (rank / wallet / kills / points). Botón *Copy wallets* y *CSV* por
  ciclo.
- **All-Time Leaderboard**: kills totales por wallet, ordenado. Export CSV.

Server-authoritative: los kills los cuenta el juego, el panel solo los guarda y
los muestra. Reemplaza el webhook de Google Sheets.

## Cómo funciona

```
Godot game server  --POST /ingest-->  arena-ffa-admin (Node)  -->  Neon (Postgres)
     (Render)          secret            (Render, este panel)         (durable)
                                              |
                                       Vos abrís el panel (login) y repartís fees
```

El juego ya manda los mismos payloads que el panel entiende:
`{secret, players:[...]}` (kills) y `{secret, type:"snapshot", snapshot:{...}}`
(podio de ciclo). **No hay que tocar código del juego**, solo apuntar la env
`SCORE_WEBHOOK_URL` al `/ingest` del panel.

## Setup (una vez)

### 1) Base de datos gratis (Neon)

1. Entrá a <https://neon.tech> → **Sign up** (gratis).
2. Creá un proyecto (ej. `cz-shooter`).
3. Copiá el **connection string** (empieza con `postgresql://...`). Es tu
   `DATABASE_URL`. (Usá el "pooled connection" si te lo ofrece.)

### 2) El panel en Render

El `render.yaml` ya define el servicio **arena-ffa-admin**. En Render:

1. Si usás el Blueprint, aparece solo. Si no, creá un **Web Service** apuntando
   a este repo con **Root Directory = `admin`**, build `npm install`, start
   `node server.js`.
2. En **Environment** cargá:
   - `DATABASE_URL` = el connection string de Neon.
   - `INGEST_SECRET` = una clave secreta larga (la comparte con el juego).
   - `ADMIN_PASSWORD` = la contraseña para entrar al panel.
3. Deploy. Cuando termine, tu panel vive en
   `https://arena-ffa-admin.onrender.com`.

### 3) Conectar el juego al panel

En el servicio **arena-ffa-server** (Render → Environment):

- `SCORE_WEBHOOK_URL` = `https://arena-ffa-admin.onrender.com/ingest`
- `SCORE_SECRET` = **el mismo valor** que `INGEST_SECRET` del panel.

Guardá; Render reinicia el server. Listo.

### 4) Entrar al panel

Abrí `https://arena-ffa-admin.onrender.com`, usuario cualquiera y contraseña =
`ADMIN_PASSWORD`.

## Repartir fees

1. Pestaña **Podium Snapshots** → elegí el ciclo.
2. **Copy wallets** (copia las wallets del podio) o **CSV** (rank/wallet/kills).
3. Mandás las fees a esas wallets (manual o con un multisend/disperse en BNB).

Para el total histórico, pestaña **All-Time Leaderboard** → **Export CSV**.

## Config del ciclo (opcional)

En **arena-ffa-server** (env): `CYCLE_MINUTES` (default 25) y `SNAPSHOT_TOP_N`
(default 10).

## Local (dev)

```
cd admin && npm install
PORT=3778 INGEST_SECRET=sek ADMIN_PASSWORD=pw node server.js
```
Sin `DATABASE_URL` corre en memoria (no durable) — solo para probar. El panel
avisa "storage: MEMORY" cuando pasa eso.
