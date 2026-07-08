// store.js — almacenamiento del panel. Usa Postgres (Neon) si hay DATABASE_URL;
// si no, cae a memoria (solo para desarrollo local / pruebas — NO durable).
//
// Interfaz:
//   init()                       -> prepara tablas
//   addSnapshot(snap)            -> archiva un ciclo (APPEND-ONLY, ignora duplicados por cycleId)
//   getSnapshots()               -> array de snapshots (más nuevo primero)
//   getSnapshot(cycleId)         -> un snapshot o null
//   addScores(players)           -> suma kills nuevos por wallet
//   getLeaderboard()             -> array {wallet,total_kills,name,last_seen} desc

const hasDb = !!process.env.DATABASE_URL;

function memStore() {
  const snaps = new Map(); // cycleId -> snap
  const board = new Map(); // wallet -> {wallet,total_kills,name,last_seen}
  return {
    durable: false,
    async init() {},
    async addSnapshot(snap) {
      if (!snap || !snap.cycleId) return { stored: false };
      if (snaps.has(snap.cycleId)) return { stored: false, duplicate: true };
      snaps.set(snap.cycleId, { ...snap, _created: Date.now() });
      return { stored: true };
    },
    async getSnapshots() {
      return [...snaps.values()].sort((a, b) => (b._created || 0) - (a._created || 0));
    },
    async getSnapshot(cycleId) {
      return snaps.get(cycleId) || null;
    },
    async addScores(players) {
      const now = new Date().toISOString();
      for (const p of players || []) {
        const w = String(p.wallet || '').toLowerCase();
        const add = Number(p.kills) || 0;
        if (!w || add <= 0) continue;
        const cur = board.get(w) || { wallet: w, total_kills: 0, name: '', last_seen: now };
        cur.total_kills += add;
        cur.name = p.name || cur.name;
        cur.last_seen = now;
        board.set(w, cur);
      }
    },
    async getLeaderboard() {
      return [...board.values()].sort((a, b) => b.total_kills - a.total_kills);
    },
  };
}

function pgStore() {
  const { Pool } = require('pg');
  const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false },
  });
  return {
    durable: true,
    async init() {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS snapshots (
          cycle_id      TEXT PRIMARY KEY,
          cycle_number  INTEGER,
          closed_at     TEXT,
          eligible_count INTEGER,
          data          JSONB NOT NULL,
          created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
        );
        CREATE TABLE IF NOT EXISTS leaderboard (
          wallet      TEXT PRIMARY KEY,
          total_kills BIGINT NOT NULL DEFAULT 0,
          name        TEXT,
          last_seen   TIMESTAMPTZ NOT NULL DEFAULT now()
        );
      `);
    },
    async addSnapshot(snap) {
      if (!snap || !snap.cycleId) return { stored: false };
      // APPEND-ONLY: ON CONFLICT DO NOTHING -> nunca sobrescribe un ciclo.
      const r = await pool.query(
        `INSERT INTO snapshots (cycle_id, cycle_number, closed_at, eligible_count, data)
         VALUES ($1,$2,$3,$4,$5) ON CONFLICT (cycle_id) DO NOTHING`,
        [snap.cycleId, snap.cycleNumber || null, snap.closedAt || null,
         snap.eligibleCount || 0, snap],
      );
      return { stored: r.rowCount > 0, duplicate: r.rowCount === 0 };
    },
    async getSnapshots() {
      const r = await pool.query(`SELECT data FROM snapshots ORDER BY created_at DESC`);
      return r.rows.map((row) => row.data);
    },
    async getSnapshot(cycleId) {
      const r = await pool.query(`SELECT data FROM snapshots WHERE cycle_id = $1`, [cycleId]);
      return r.rows[0] ? r.rows[0].data : null;
    },
    async addScores(players) {
      for (const p of players || []) {
        const w = String(p.wallet || '').toLowerCase();
        const add = Number(p.kills) || 0;
        if (!w || add <= 0) continue;
        await pool.query(
          `INSERT INTO leaderboard (wallet, total_kills, name, last_seen)
           VALUES ($1,$2,$3, now())
           ON CONFLICT (wallet) DO UPDATE
             SET total_kills = leaderboard.total_kills + EXCLUDED.total_kills,
                 name = EXCLUDED.name,
                 last_seen = now()`,
          [w, add, p.name || ''],
        );
      }
    },
    async getLeaderboard() {
      const r = await pool.query(
        `SELECT wallet, total_kills, name, last_seen FROM leaderboard ORDER BY total_kills DESC`,
      );
      return r.rows.map((row) => ({
        wallet: row.wallet,
        total_kills: Number(row.total_kills),
        name: row.name,
        last_seen: row.last_seen,
      }));
    },
  };
}

module.exports = hasDb ? pgStore() : memStore();
