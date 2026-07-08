# Ranking global por wallet + PODIOS por ciclo (para repartir fees)

El server del juego cuenta los kills de forma **autoritativa** (nadie puede
inflarlos) y, por cada wallet **EVM real** (MetaMask, `0x...`), manda los kills
nuevos a una **planilla de Google**. La planilla los **suma** y queda como el
ranking permanente: sobrevive a los reinicios de Render.

Además, cada **ciclo de 25 minutos** (configurable) el server **cierra el
podio**, guarda un **snapshot inmutable** de los ganadores (top 10, con wallet +
kills + puntaje) y **reinicia** el marcador para el próximo ciclo. Cada snapshot
queda archivado con su `cycleId` único y **nunca se sobrescribe**. Ese snapshot
es lo que usás para repartir los fees de ese ciclo.

## Config (sin tocar código)

En **Render → arena-ffa-server → Environment** podés setear:

| Variable          | Default | Qué hace                               |
|-------------------|---------|----------------------------------------|
| `CYCLE_MINUTES`   | `25`    | Duración de cada ciclo de podio.       |
| `SNAPSHOT_TOP_N`  | `10`    | Cuántos ganadores entran al snapshot.  |
| `SCORE_WEBHOOK_URL` | —     | URL `/exec` del Web App (ver abajo).   |
| `SCORE_SECRET`    | —       | Clave compartida con el script.        |

- Los **bots no cuentan**.
- Los **invitados sin wallet no cuentan** (no se les puede pagar).
- La planilla es la **fuente de verdad**: abrís, ordenás por `total_kills` y
  repartís las fees a las wallets del top.

## Paso 1 — Crear la planilla

1. Andá a <https://sheets.google.com> y creá una planilla nueva.
2. Ponele nombre (ej. `CZ Shooter — Leaderboard`).

## Paso 2 — Pegar el script (webhook)

1. En la planilla: menú **Extensiones → Apps Script**.
2. Borrá lo que haya y pegá TODO el contenido de [`leaderboard.gs`](leaderboard.gs)
   (está en esta misma carpeta).
3. Arriba de todo, cambiá `const SECRET = 'CAMBIAME';` por una clave secreta
   tuya (cualquier texto largo, ej. `cz_9f3k2_leaderboard`). **Anotala.**
4. Guardá (ícono de disquete).

## Paso 3 — Publicar el webhook

1. En Apps Script: botón **Implementar (Deploy) → Nueva implementación**.
2. Tipo: **Aplicación web (Web app)**.
3. Configurá:
   - **Ejecutar como:** Yo (tu cuenta).
   - **Quién tiene acceso:** **Cualquier persona** (*Anyone*). ⚠️ Es necesario
     para que el server pueda postear; la seguridad la da el `SECRET`.
4. **Implementar** → autorizá los permisos que pida.
5. Copiá la **URL de la app web** (termina en `/exec`). **Es tu `SCORE_WEBHOOK_URL`.**

## Paso 4 — Cargar las claves en Render

1. En el dashboard de Render, entrá al servicio **arena-ffa-server**.
2. **Environment** → agregá dos variables:
   - `SCORE_WEBHOOK_URL` = la URL `/exec` del paso 3.
   - `SCORE_SECRET` = la misma clave que pusiste en el script.
3. Guardá. Render reinicia el server solo.

Listo. Desde ahí, cada ~2 minutos (y cuando alguien se va o se resetea el
ciclo), el server actualiza la planilla. Vas a ver filas
`wallet | total_kills | name | last_seen`.

## Ver / exportar los snapshots de cada ciclo (tu "admin endpoint")

Cada cierre de ciclo se archiva en dos lados:

- **Hoja `Snapshots`** de la planilla: una fila por ciclo (`cycleId`, hora,
  cantidad de ganadores, y el JSON completo). Append-only, nunca se pisa.
- **Backup local** en el disco del server (`user://snapshots.json`).

Y podés pedir el JSON directo desde el navegador (es el `/admin/snapshots`),
pasando tu `secret`:

- **Todos los ciclos:**
  `https://TU-WEBAPP/exec?secret=TU_SECRET`
- **Un ciclo puntual (listo para repartir):**
  `https://TU-WEBAPP/exec?secret=TU_SECRET&cycle=cycle-0007`

Devuelve algo así:

```json
{
  "cycleId": "cycle-0007",
  "closedAt": "2026-07-08T01:46:18",
  "cycleSeconds": 1500,
  "eligibleCount": 12,
  "winners": [
    { "rank": 1, "wallet": "0xbbbb...bbbb", "name": "Bob",   "kills": 12, "points": 1400 },
    { "rank": 2, "wallet": "0xaaaa...aaaa", "name": "Alice", "kills": 8,  "points": 900 }
  ]
}
```

## Cómo repartir las fees

1. Abrí la planilla (hoja `Snapshots`) o el endpoint `?cycle=...`.
2. Tomás el array `winners` de ese ciclo: ya viene con `rank`, `wallet` y `kills`.
3. Copiás las wallets y mandás las fees (manualmente, o con una herramienta de
   *disperse* / multisend en BNB Chain).

Para el **total histórico** (todos los ciclos sumados) usás la hoja
`Leaderboard`: ordenás por `total_kills` (Z→A) y ahí tenés el ranking global.

> El reparto **on-chain lo hacés vos**: el juego solo te da el ranking confiable
> con las wallets; nunca firma transacciones ni mueve fondos.

## Probar que funciona

- Entrá al juego en la web, tocá **CONNECT WALLET** (MetaMask), jugá y hacé
  algún kill. En ~2 min tu wallet aparece en la planilla con tus kills.
- Si no aparece: revisá que las dos env vars de Render estén bien y que el Web
  App esté publicado como *Anyone*.
