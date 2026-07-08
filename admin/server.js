// server.js — CZ Shooter admin panel.
// Recibe los datos del server del juego (POST /ingest) y sirve un panel con la
// marca CZ Shooter: snapshots de podio por ciclo + ranking histórico, con
// export CSV. Almacenamiento durable en Postgres (Neon) vía store.js.
//
// Env:
//   PORT            (Render lo inyecta)
//   DATABASE_URL    connection string de Neon (Postgres)
//   INGEST_SECRET   clave que valida los POST del juego (== SCORE_SECRET del server)
//   ADMIN_PASSWORD  contraseña del panel (usuario: cualquiera)

const path = require('path');
const express = require('express');
const store = require('./store');

const app = express();
app.use(express.json({ limit: '256kb' }));

const INGEST_SECRET = process.env.INGEST_SECRET || '';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '';

// --- Ingesta desde el server del juego (mismos payloads que ya manda) --------
// scores:   { secret, players:[{wallet,name,kills}] }
// snapshot: { secret, type:"snapshot", snapshot:{ cycleId, winners:[...], ... } }
app.post('/ingest', async (req, res) => {
  try {
    const body = req.body || {};
    if (!INGEST_SECRET || String(body.secret) !== INGEST_SECRET) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    if (body.type === 'snapshot') {
      const r = await store.addSnapshot(body.snapshot || {});
      return res.json({ ok: true, ...r });
    }
    await store.addScores(body.players || []);
    return res.json({ ok: true });
  } catch (err) {
    console.error('ingest error', err);
    return res.status(500).json({ error: 'server_error' });
  }
});

// --- Auth básica para todo lo del panel (páginas + API + export) --------------
function auth(req, res, next) {
  if (!ADMIN_PASSWORD) return res.status(503).send('ADMIN_PASSWORD not set');
  const h = req.headers.authorization || '';
  const m = h.match(/^Basic (.+)$/);
  if (m) {
    const [, pass] = Buffer.from(m[1], 'base64').toString().split(':');
    if (pass === ADMIN_PASSWORD) return next();
  }
  res.set('WWW-Authenticate', 'Basic realm="CZ Shooter Admin"');
  return res.status(401).send('Auth required');
}

// --- API (JSON) ---------------------------------------------------------------
app.get('/api/snapshots', auth, async (_req, res) => {
  res.json({ snapshots: await store.getSnapshots(), durable: store.durable });
});
app.get('/api/snapshots/:cycleId', auth, async (req, res) => {
  const s = await store.getSnapshot(req.params.cycleId);
  if (!s) return res.status(404).json({ error: 'not_found' });
  res.json(s);
});
app.get('/api/leaderboard', auth, async (_req, res) => {
  res.json({ leaderboard: await store.getLeaderboard(), durable: store.durable });
});

// --- Export CSV ---------------------------------------------------------------
function csv(rows) {
  return rows.map((r) => r.map((c) => {
    const s = String(c == null ? '' : c);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  }).join(',')).join('\n');
}
function sendCsv(res, name, rows) {
  res.set('Content-Type', 'text/csv; charset=utf-8');
  res.set('Content-Disposition', `attachment; filename="${name}"`);
  res.send(csv(rows));
}

app.get('/export/leaderboard.csv', auth, async (_req, res) => {
  const rows = [['wallet', 'total_kills', 'name', 'last_seen']];
  for (const r of await store.getLeaderboard()) {
    rows.push([r.wallet, r.total_kills, r.name, r.last_seen]);
  }
  sendCsv(res, 'leaderboard.csv', rows);
});

app.get('/export/snapshots.csv', auth, async (_req, res) => {
  const rows = [['cycleId', 'closedAt', 'rank', 'wallet', 'name', 'kills', 'points']];
  for (const s of await store.getSnapshots()) {
    for (const w of s.winners || []) {
      rows.push([s.cycleId, s.closedAt, w.rank, w.wallet, w.name, w.kills, w.points]);
    }
  }
  sendCsv(res, 'snapshots.csv', rows);
});

app.get('/export/:cycleId.csv', auth, async (req, res) => {
  const s = await store.getSnapshot(req.params.cycleId);
  if (!s) return res.status(404).send('not found');
  const rows = [['rank', 'wallet', 'name', 'kills', 'points']];
  for (const w of s.winners || []) rows.push([w.rank, w.wallet, w.name, w.kills, w.points]);
  sendCsv(res, `${req.params.cycleId}.csv`, rows);
});

// --- Panel (página con marca) -------------------------------------------------
app.get('/', auth, (_req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));
app.use('/static', auth, express.static(path.join(__dirname, 'public')));

// Healthcheck público (Render / keepalive).
app.get('/health', (_req, res) => res.json({ ok: true, durable: store.durable }));

const PORT = process.env.PORT || 3000;
store.init()
  .then(() => app.listen(PORT, () => console.log(`[admin] listening on ${PORT} (durable=${store.durable})`)))
  .catch((err) => { console.error('init failed', err); process.exit(1); });
