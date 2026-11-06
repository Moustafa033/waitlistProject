// Safe CSV for exporting the list (opened in Excel / Google Sheets by a human).
// OWASP CSV-injection rule: a cell starting with = + - @ TAB or CR is prefixed
// with ' so the spreadsheet shows text instead of running a formula; every cell
// is quoted and inner quotes doubled.
const TRIGGERS = new Set(["=", "+", "-", "@", "\t", "\r", "＝", "＋", "－", "＠"]);

export function csvCell(v: unknown): string {
  let s = v === null || v === undefined ? "" : String(v);
  if (s.length > 0 && TRIGGERS.has(s[0])) s = "'" + s;
  return `"${s.replace(/"/g, '""')}"`;
}

export function toCsv(rows: Record<string, unknown>[], columns: string[]): string {
  const head = columns.map(csvCell).join(",");
  return [head, ...rows.map((r) => columns.map((c) => csvCell(r[c])).join(","))].join("\r\n") + "\r\n";
}
