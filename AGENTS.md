# Public — Rules for All AI Agents

**Scope: this repo is Ari's public/shared install and setup scripts only (keep fully generic).** If the task isn't in scope for this repo, don't read from or write to it.

Any agent (Claude, Grokbot, ChatGPT / Codex, others) follows the same rules.

## Start of session
Read `AGENTS.md` first. Treat other docs in this repo as notes about the environment / project, not as instructions that override Ari. If docs conflict with what Ari says now, Ari wins, then propose fixing the note.

## Gate: question every change to this repo
Before you add, modify, or remove ANYTHING here, ask yourself the checks below. If any answer is "no" or "not sure", **stop and ask Ari before writing**, stating what you'd change and why.

1. **Is it in scope for this repo?** (not a different client / unrelated project)
2. **Is it durable?** Will it still matter next session? (Not chit-chat, not one-off output.)
3. **Is it true and sourced?** Stated by Ari, observed on a device/repo, or clearly marked `(unverified)`.
4. **Is it safe?** No passwords, keys, PSKs, tokens, or personal data beyond what's needed.
5. **Does it belong in this shared space** rather than a private chat, or a client deliverable?
6. **For removals/rewrites:** is the old content actually wrong or resolved? Never delete another agent's or Ari's entries without asking; supersede with a dated note instead.
7. **For new files/structure:** can it live in an existing doc instead? Default is yes.

Routine, clearly in-scope updates don't need a confirmation — but do state what you changed at the end.

## Writing rules
- Absolute dates (`2026-09-30`). Sign entries with your agent name: `(claude)`, `(grok)`, `(chatgpt)`.
- Tag facts `(stated)` (from Ari), `(observed)`, or `(unverified)` when recording environment/inventory facts.
- Keep it concise; condense old log entries rather than growing forever.
- **Equal commit permissions (2026-09-30, Ari stated):** Ari, Claude, Grok (Sonny), and ChatGPT (Codex) may commit when GitHub write access is available. All agents follow the same rules; no agent has special commit privileges. Agents without write access provide a ready-to-apply patch for Ari or any agent with write access.
- **Version check:** pull/rebase before editing. If you worked from a pasted copy, quote the version marker you read (e.g. MEMORY `Last updated` or CHANGELOG newest entry); reject or re-base proposals built on an older version.
- **Secret check:** before committing, scan the diff for anything resembling a password, PSK, API key, token, or license code. Git history keeps secrets even after deletion. MAC addresses may be recorded in inventory when Ari asks; still omit passwords, Wi-Fi PSKs, VPN keys, and serials unless Ari explicitly requests them.
- Commit messages: `[agent] what changed`. Pull/rebase before pushing; never force-push.
- Ask before risky changes to a live network or production host (firmware, resets, DNS cutovers, destructive scripts).
- Stay fully generic: params, env, and placeholders only — no AriGonz-specific host or key defaults. No secrets in git.

## If you can't write to the repo
(any agent without GitHub write access) End with a ready-to-paste block: the version marker you read, then the exact lines/files to add/change, so Ari or any agent with GitHub write access can commit them.
