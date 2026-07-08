/**
 * CZ Shooter — Webhook del ranking global por wallet.
 * Recibe POSTs del server del juego con los kills NUEVOS por wallet y los SUMA
 * a un total permanente en la planilla. Ver docs/leaderboard-setup.md.
 */

// 1) Cambiá esto por una clave secreta tuya (la misma que pongas en Render como
//    SCORE_SECRET). Cualquier texto largo sirve.
const SECRET = 'CAMBIAME';

// Nombre de la hoja donde se guarda el ranking.
const SHEET_NAME = 'Leaderboard';

function doPost(e) {
  const lock = LockService.getScriptLock();
  try {
    lock.waitLock(30000); // evita que dos POSTs se pisen (doble conteo)
  } catch (err) {
    return _json({ error: 'busy' });
  }
  try {
    const data = JSON.parse(e.postData.contents);
    if (String(data.secret) !== SECRET) {
      return _json({ error: 'unauthorized' });
    }
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    let sheet = ss.getSheetByName(SHEET_NAME);
    if (!sheet) sheet = ss.insertSheet(SHEET_NAME);
    if (sheet.getLastRow() === 0) {
      sheet.appendRow(['wallet', 'total_kills', 'name', 'last_seen']);
    }
    // Mapa wallet -> fila (1-based).
    const values = sheet.getDataRange().getValues();
    const rowByWallet = {};
    for (let i = 1; i < values.length; i++) {
      rowByWallet[String(values[i][0]).toLowerCase()] = i + 1;
    }
    const now = new Date();
    const players = data.players || [];
    for (let k = 0; k < players.length; k++) {
      const p = players[k];
      const wallet = String(p.wallet || '').toLowerCase();
      const add = Number(p.kills) || 0;
      if (!wallet || add <= 0) continue;
      if (rowByWallet[wallet]) {
        const r = rowByWallet[wallet];
        const cur = Number(sheet.getRange(r, 2).getValue()) || 0;
        sheet.getRange(r, 2).setValue(cur + add);
        sheet.getRange(r, 3).setValue(p.name || '');
        sheet.getRange(r, 4).setValue(now);
      } else {
        sheet.appendRow([wallet, add, p.name || '', now]);
        rowByWallet[wallet] = sheet.getLastRow();
      }
    }
    return _json({ ok: true });
  } catch (err) {
    return _json({ error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function _json(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
