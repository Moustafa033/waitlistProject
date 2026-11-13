// Email validation. Deliberately conservative (ASCII only) — the same rule as
// private.email_ok() in SQL. Better to refuse a rare exotic address than to let
// header injection, homographs or spreadsheet formulas into the list.
import { HttpError } from "./http.ts";

const LOCAL = /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}$/;
// Refused characters, written as \u escapes (never as raw invisible characters, which a
// reviewer cannot see — "Trojan Source"): C0/C1 controls, soft hyphen, Arabic letter mark,
// Mongolian vowel separator, zero-width + bidi marks, bidi embeddings/overrides, word joiner
// and invisible operators, bidi isolates, BOM.
// deno-lint-ignore no-control-regex -- matching control characters is the whole point (we refuse them)
const HIDDEN_OR_CONTROL = /[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u180e\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/;
const LABEL = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

/** P-2: identity = lower(trim(email)). No dot/plus folding: those are different people. */
export function normalizeEmail(raw: unknown): string {
  if (typeof raw !== "string") throw new HttpError(400, "invalid_email");
  if (raw.length > 320) throw new HttpError(400, "invalid_email");
  // any control char (CR/LF/TAB/NUL...) or bidi/zero-width => refuse, never "clean"
  if (HIDDEN_OR_CONTROL.test(raw)) throw new HttpError(400, "invalid_email");
  const e = raw.trim().toLowerCase();
  if (e.length < 6 || e.length > 254) throw new HttpError(400, "invalid_email");
  const at = e.indexOf("@");
  if (at < 1 || at !== e.lastIndexOf("@")) throw new HttpError(400, "invalid_email");
  const local = e.slice(0, at), domain = e.slice(at + 1);
  if (!LOCAL.test(local) || local.startsWith(".") || local.endsWith(".") || local.includes("..")) throw new HttpError(400, "invalid_email");
  // Reject MIME "encoded-word" local parts (=?charset?enc?...?=). They are a known
  // parser-confusion / email-spoofing trick: some mail software decodes them and can
  // deliver the message somewhere other than what we validated. (PortSwigger, "Splitting
  // the email atom".) No real local part needs "=?".
  if (local.includes("=?")) throw new HttpError(400, "invalid_email");
  const labels = domain.split(".");
  if (labels.length < 2 || !labels.every((l) => LABEL.test(l))) throw new HttpError(400, "invalid_email");
  if (!/^[a-z]{2,63}$/.test(labels[labels.length - 1])) throw new HttpError(400, "invalid_email");
  return e;
}

export function domainOf(email: string): string {
  return email.slice(email.indexOf("@") + 1);
}

/** Disposable domains: matches the domain and every parent (x.mailinator.com). */
export function isDisposable(email: string, blocklist: ReadonlySet<string>): boolean {
  const parts = domainOf(email).split(".");
  for (let i = 0; i < parts.length - 1; i++) if (blocklist.has(parts.slice(i).join("."))) return true;
  return false;
}

export function isToken(v: unknown): v is string {
  return typeof v === "string" && /^[A-Za-z0-9_-]{43}$/.test(v);
}

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
}
