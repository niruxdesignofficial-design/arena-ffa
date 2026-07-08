/**
 * CZ Shooter — Webhook del ranking global + snapshots de podio por ciclo.
 * Ver docs/leaderboard-setup.md.
 *
 * POST admite dos tipos:
 *  - scores  (default): { secret, players:[{wallet,name,kills}] }
 *      Suma los kills nuevos por wallet en la hoja "Leaderboard" (total histórico).
 *  - snapshot: { secret, type:"snapshot", snapshot:{ cycleId, winners:[...], ... } }
 *      Archiva INMUTABLE (append-only) el podio del ciclo en la hoja "Snapshots".
 *
 * GET = endpoint admin para VOS (pasás ?secret=...):
 *  - ...?secret=XXX                 -> lista todos los snapshots (JSON)
 *  - ...?secret=XXX&cycle=cycle-0007 -> JSON de ese ciclo (rank+wallet+kills)
 */

// Cambiá esto por tu clave secreta (la misma que pongas en Render como SCORE_SECRET).
const SECRET = 'CAMBIAME';
const SCORES_SHEET = 'Leaderboard';
const SNAPS_SHEET = 'Snapshots';

function doPost(e) {
  const lock = LockService.getScriptLock();
  try { lock.waitLock(30000); } catch (err) { return _json({ error: 'busy' }); }
  try {
    const data = JSON.parse(e.postData.contents);
    if (String(data.secret) !== SECRET) return _json({ error: 'unauthorized' });
    if (data.type === 'snapshot') return _storeSnapshot(data.snapshot || {});
    return _addScores(data.players || []);
  } catch (err) {
    return _json({ error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  if (String(p.secret) !== SECRET) return _json({ error: 'unauthorized' });
  const sh = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SNAPS_SHEET);
  if (!sh || sh.getLastRow() < 2) return _json({ count: 0, snapshots: [] });
  const rows = sh.getDataRange().getValues();
  const out = [];
  for (let i = 1; i < rows.length; i++) {
    let snap;
    try { snap = JSON.parse(rows[i][5]); } catch (err) { continue; }
    if (p.cycle && String(snap.cycleId) !== String(p.cycle)) continue;
    out.push(snap);
  }
  if (p.cycle) return _json(out[0] || { error: 'cycle not found' });
  return _json({ count: out.length, snapshots: out });
}

/** Suma kills nuevos por wallet (total permanente). */
function _addScores(players) {
  const sheet = _sheet(SCORES_SHEET, ['wallet', 'total_kills', 'name', 'last_seen']);
  const values = sheet.getDataRange().getValues();
  const rowByWallet = {};
  for (let i = 1; i < values.length; i++) rowByWallet[String(values[i][0]).toLowerCase()] = i + 1;
  const now = new Date();
  for (let k = 0; k < players.length; k++) {
    const w = String(players[k].wallet || '').toLowerCase();
    const add = Number(players[k].kills) || 0;
    if (!w || add <= 0) continue;
    if (rowByWallet[w]) {
      const r = rowByWallet[w];
      sheet.getRange(r, 2).setValue((Number(sheet.getRange(r, 2).getValue()) || 0) + add);
      sheet.getRange(r, 3).setValue(players[k].name || '');
      sheet.getRange(r, 4).setValue(now);
    } else {
      sheet.appendRow([w, add, players[k].name || '', now]);
      rowByWallet[w] = sheet.getLastRow();
    }
  }
  return _json({ ok: true });
}

/** Archiva un snapshot de ciclo INMUTABLE y APPEND-ONLY (no sobrescribe). */
function _storeSnapshot(snap) {
  if (!snap.cycleId) return _json({ error: 'missing cycleId' });
  const sheet = _sheet(SNAPS_SHEET, ['cycleId', 'cycleNumber', 'closedAt', 'eligibleCount', 'winnersCount', 'json']);
  const ids = sheet.getRange(1, 1, Math.max(sheet.getLastRow(), 1), 1).getValues().flat();
  if (ids.indexOf(snap.cycleId) !== -1) return _json({ ok: true, duplicate: snap.cycleId });
  sheet.appendRow([
    snap.cycleId, snap.cycleNumber || '', snap.closedAt || '',
    snap.eligibleCount || 0, (snap.winners || []).length, JSON.stringify(snap),
  ]);
  return _json({ ok: true, stored: snap.cycleId });
}

function _sheet(name, header) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  if (sh.getLastRow() === 0) sh.appendRow(header);
  return sh;
}

function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
