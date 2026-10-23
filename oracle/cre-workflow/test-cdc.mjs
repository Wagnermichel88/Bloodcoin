// Prüft die Workflow-Logik mit nachgebauten CDC-Antworten: `node oracle/cre-workflow/test-cdc.mjs`
import assert from "node:assert/strict";
import { cdcUrl, dayOf, pickWindow, targetMilli } from "./cdc.js";

const DAY = 86400000;
const today = dayOf(Date.parse("2026-10-11T16:00:00Z"));   // Grenze: 2026-08-16
const iso = (day) => new Date(day * DAY).toISOString().slice(0, 10);
const row = (day, n) => ({ week_ending_date: `${iso(day)}T00:00:00.000`, total_deaths: String(n) });
const D = (s) => Date.parse(s + "T00:00:00Z") / DAY;
// 170 Wochen bis einschließlich `last`, Wert pro Woche aus f(day)
const series = (last, f) => Array.from({ length: 170 }, (_, i) => last - 7 * i).map((d) => row(d, f(d)));
const pick = (rows) => { const r = pickWindow(rows, today); return { week: iso(r.weekEnding / 86400), recent: r.recent, baseline: r.baseline }; };

// 1) Normalfall: neueste Woche mit allen 16 Wochen; URL enthält die 8-Wochen-Grenze
const last = D("2026-08-15");
const recentDays = [0, 1, 2, 3].map((j) => last - 7 * j);
let rows = series(last, (d) => (recentDays.includes(d) ? 63_000 : 60_000));
assert.deepEqual(pick(rows), { week: "2026-08-15", recent: 252_000, baseline: 240_000 });
const url = new URL(cdcUrl("https://data.cdc.gov/resource/r8kw-7aab.json", today));
assert.equal(url.searchParams.get("$where"), "`group` = 'By Week' AND week_ending_date <= '2026-08-16T00:00:00.000'");
assert.equal(url.searchParams.get("state"), "United States");
assert.equal(url.searchParams.get("$limit"), "180");
// 2) Vorjahre werden gemittelt und gerundet wie in Python ((s + 1) // 3)
rows = series(last, (d) => (d === last - 364 ? 60_002 : 60_000));
assert.deepEqual(pick(rows), { week: "2026-08-15", recent: 240_000, baseline: 240_001 });
rows = series(last, (d) => (d === last - 364 ? 60_001 : 60_000));
assert.equal(pick(rows).baseline, 240_000);
// 3) Lücke im Vorjahresfenster: diese Woche wird übersprungen, die vorige genommen
rows = series(last, () => 60_000).filter((r) => r.week_ending_date.slice(0, 10) !== iso(last - 728));
assert.equal(pick(rows).week, "2026-08-08");
// 4) Kaputte Werte zählen als fehlend, Kommazahlen werden abgeschnitten (wie int(float()) in Python)
rows = series(last, () => 60_000);
rows[0].total_deaths = "abc";
rows[1].total_deaths = "60000.9";
assert.equal(pick(rows).week, "2026-08-08");
// 5) Zu junge Wochen werden nie gemeldet
rows = [row(last + 7, 99_999), ...series(last, () => 60_000)];
assert.equal(pick(rows).week, "2026-08-15");
// 6) Fehlerhafte, leere oder zu kurze Antworten führen zu einem Fehler, nicht zu falschen Zahlen
assert.throws(() => pickWindow({ error: "x" }, today), /not a list/);
assert.throws(() => pickWindow([], today), /no usable week/);
assert.throws(() => pickWindow(series(last, () => 60_000).slice(0, 100), today), /no usable week/);
// 7) Gemeldete Woche ist ein Samstag (das prüft auch der Contract)
assert.equal((pickWindow(series(last, () => 1), today).weekEnding / 86400) % 7, 2);
// 8) Faktor wie MortalityEmission.targetFor (gleiche Werte wie test/Bloodcoin.t.sol)
for (const [r, b, f] of [
  [240_000, 240_000, 1000], [247_200, 240_000, 1000], [232_800, 240_000, 1000], [247_440, 240_000, 995],
  [252_000, 240_000, 900], [228_000, 240_000, 1000], [264_000, 240_000, 650], [276_000, 240_000, 500],
  [180_000, 240_000, 1000], [271_200, 240_000, 500], [271_000, 240_000, 504], [1, 9_999_999, 1000], [9_999_999, 1, 500],
]) assert.equal(targetMilli(r, b), f, `${r}/${b}`);

console.log("cdc.js: alle Prüfungen bestanden");
