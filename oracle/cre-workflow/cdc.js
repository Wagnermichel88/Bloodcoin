// Reine Logik des Workflows, ohne CRE-Abhängigkeit, damit sie mit Node testbar ist (test-cdc.mjs).
// Gleiche Regel wie oracle/signed/report.py und MortalityEmission.sol:
//   recent   = Tote der 4 Wochen bis zur gemeldeten Woche
//   baseline = Durchschnitt derselben 4 Wochen in den 3 Vorjahren (je 52 Wochen zurück)
// Gemeldet wird die neueste Woche, die mindestens 8 Wochen alt ist und für die alle 16 Wochen vorliegen.
export const LAG_DAYS = 56;
export const WINDOW_WEEKS = 4;
export const BASELINE_YEARS = 3;
const DAY = 86400000;

/** Tage seit 1970 (UTC) für einen Zeitpunkt in Millisekunden. */
export const dayOf = (ms) => Math.floor(ms / DAY);

/** Abfrage-URL für den CDC-Datensatz r8kw-7aab, nur Wochen bis zur 8-Wochen-Grenze. */
export function cdcUrl(base, today) {
  const cutoff = new Date((today - LAG_DAYS) * DAY).toISOString().slice(0, 10);
  const q = [
    ["state", "United States"],
    ["$select", "week_ending_date,total_deaths"],
    // "group" ist in SoQL ein reserviertes Wort: als einfacher Filter lehnt die CDC die Abfrage
    // mit 400 ab, deshalb im $where mit Backticks.
    ["$where", `\`group\` = 'By Week' AND week_ending_date <= '${cutoff}T00:00:00.000'`],
    ["$order", "week_ending_date DESC"],
    // 3 Jahre plus 4 Wochen plus etwas Spielraum für fehlende neueste Wochen
    ["$limit", "180"],
  ];
  return base + "?" + q.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

/**
 * Wählt die zu meldende Woche aus der CDC-Antwort und rechnet beide Summen.
 * @returns {{weekEnding: number, recent: number, baseline: number}} weekEnding in Sekunden (Samstag 00:00 UTC)
 */
export function pickWindow(data, today) {
  if (!Array.isArray(data)) throw new Error("CDC answer is not a list");
  const weeks = new Map();
  for (const r of data) {
    const day = Date.parse(String(r.week_ending_date).slice(0, 10) + "T00:00:00Z") / DAY;
    const deaths = Math.trunc(Number(r.total_deaths));
    if (Number.isInteger(day) && Number.isInteger(deaths) && deaths > 0 && deaths < 10000000) weeks.set(day, deaths);
  }
  const sum = (end) => {
    let s = 0;
    for (let j = 0; j < WINDOW_WEEKS; j++) {
      const v = weeks.get(end - 7 * j);
      if (v === undefined) return undefined;
      s += v;
    }
    return s;
  };
  for (const day of [...weeks.keys()].sort((a, b) => b - a)) {
    if (day > today - LAG_DAYS) continue;
    const recent = sum(day);
    if (recent === undefined) continue;
    let past = 0;
    for (let k = 1; k <= BASELINE_YEARS; k++) {
      const s = sum(day - 364 * k);
      if (s === undefined) { past = undefined; break; }
      past += s;
    }
    if (past === undefined) continue;
    // Auf ganze Zahl gerundet, wie report.py: (s + 1) // 3
    return { weekEnding: day * 86400, recent, baseline: Math.floor((past + 1) / BASELINE_YEARS) };
  }
  throw new Error("no usable week");
}

/** Ziel-Faktor in Promille, exakt wie MortalityEmission.targetFor (nur zur Anzeige im Log). */
export function targetMilli(recent, baseline) {
  if (recent <= baseline) return 1000; // weniger Tote: keine Extra-Coins
  const bp = Math.floor(((recent - baseline) * 10000 + Math.floor(baseline / 2)) / baseline);
  if (bp <= 300) return 1000;
  return Math.max(500, 1000 - Math.floor((5 * (bp - 300)) / 10));
}
