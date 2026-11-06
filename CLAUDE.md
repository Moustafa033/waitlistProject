# CLAUDE.md

@AGENTS.md

- The full specification is `docs/WAITLIST_SECURITY_GUIDE.md`. Read the section for your task before writing code.
- For any security-relevant task, use the project skill `waitlist-security` (`.claude/skills/waitlist-security/SKILL.md`).
- Static site: `site/`. Database: `supabase/migrations/`. Edge Functions: `supabase/functions/`. Tests: `tests/` (SQL + races), `supabase/functions/tests/` (Deno), `e2e/` (real browser).
