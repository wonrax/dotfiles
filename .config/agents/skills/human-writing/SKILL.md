---
name: human-writing
description: Style rules that keep agent-written prose from reading like a bot wrote it. Use BEFORE writing ANY text whose audience is other people rather than the current chat, including but not limited to PR/MR descriptions, commit messages, code review and issue comments, tickets, READMEs and docs, changelogs, release notes, Slack/chat/text messages, emails, and announcements. Also use when asked to rewrite or humanize text that sounds AI-generated. Covers audience assumptions, sentence style, formatting restraint, and word choice. Not for code comments (use slop-terminator) or replies to the current chat.
---

# Human Writing

Text handed to other humans gets judged as human writing. The bot failure mode is text that is accurate but over-formatted, over-compressed, over-sold, and leaking context from the session that produced it. Apply these rules to any prose a reader will see verbatim.

## Write for the zero-context reader

The reader was not in this chat. For a PR they have the diff and general knowledge of the project — not the conversation, and not deep familiarity with the corner of the codebase being changed.

- Never reference the session: no "as requested", "as discussed", no shorthand or codenames invented during the conversation.
- Don't address the person who asked for the work. A PR description speaks to the team, not to the requester.
- Don't narrate the working process ("after investigating...", "I found that..."). Describe the change and its reasons, not the journey.
- Expand insider shorthand on first use: "carries the family's 3 Snyk mediums" becomes "includes fixes for the package family's three medium-severity Snyk findings".
- Name the files, flags, and services involved instead of alluding to them.
- If a sentence only makes sense with knowledge from the chat, restate the needed fact or cut the sentence.

## Sentences, not compressed notes

Bots compress; people write sentences. Expand notation into words.

```
Bad:  cost + nondeterminism meant no spec could exist
Good: The cost and nondeterminism made it impractical to test.

Bad:  short-circuits the viz/replay/extraction paths *before* the agent
Good: bypasses the viz, replay, and extraction paths before reaching the agent

Bad:  **Specs**: live-turn.spec.ts — streamed answer + reload persistence; tool round-trip
Good: live-turn.spec.ts covers a streamed answer with reload persistence and a tool round-trip.

Bad:  Land this first → migrate on a branch → rerun the same specs
Good: Landing these tests first gives the migration branch a stable e2e check.

Bad:  (unit-tested: a real key leaking into a test env cannot cause billing)
Good: A unit test verifies that a real key leaking into the test environment cannot trigger billing.
```

Keep `→`, `+`, and `/` only as literal notation: event sequences (`started → answer_delta → result`), version moves (`0.3 → 1.x`), actual paths and expressions. Promote load-bearing claims out of parentheses into their own sentences; short asides can stay parenthesized.

## Formatting is navigation, not emphasis

Default to prose. Reach for markdown only when it genuinely helps the reader scan or compare.

- Bold a handful of things per document at most, and only what a scanner must find: a flag name, a headline number. Never bold a claim to make it feel important.
- No ALL CAPS or italics for stress. If a word needs emphasis, restructure the sentence so position provides it.
- Bullets are for parallel items. A bullet holding several sentences of reasoning should be a paragraph. Prose carries narrative; lists carry lists.
- Headers only where the format expects them (PR template sections). None in chat messages.
- Em dashes are the loudest tell. Budget about one per document and count a pair as two; for a mid-sentence aside use a colon, a comma, parentheses, or a second sentence.
- Emoji only where the venue already uses them.

```
Bad:  This adds a fake provider that slots in underneath the real machinery — the agent loop, streaming,
      and persistence all run for real, only the model is scripted — plus the first specs that use it.
Good: This adds a fake provider that stubs before the core chat implementation: the agent loop, streaming,
      and persistence all run, only the model is scripted, plus the first specs that use it.
```

The bad version also carries fluff: "slots in underneath", "real machinery", and "for real" add attitude, not information.

## Plain words, measured claims

- Prefer the plain verb: "bypasses" over "short-circuits", "takes precedence over" over "outranks", "hard to miss" over "unmissable".
- Use the precise technical verb, not a spatial metaphor: stubs, returns, constructs, replaces, exercises. Not "slots in underneath", "hands out", "picks it up", "sits in front of".
- Delete words that add attitude instead of information: "for real", "real machinery", "happily", "actually". If deleting a word changes nothing, delete it.
- Default-delete: leverage, utilize, delve, robust, seamless, comprehensive, blazing, supercharge, streamline, battle-tested, belt-and-suspenders, and cutesy metaphors ("cheap canary" becomes "cheap regression test").
- Cut filler: "simply", "just", "note that", "it's worth noting", "importantly", "in order to".
- Size claims to the evidence: "made it impractical to test" beats "meant no spec could exist".
- Spell product names properly: LangChain, WeasyPrint, Ruff.

## Report, don't sell

- State numbers plainly and explain anomalies honestly: "1377 passed. The remaining 17 failures are the documented host-WeasyPrint limitation, unrelated to this change."
- Name what was verified and what was not. No "everything works perfectly".
- No marketing adjectives on your own work ("significantly improves", "dramatically simplifies").
- State the mechanism, not the benefit. "A few guards so this can't bill anyone" pitches; "Guards against misconfiguration" describes. Teaser lead-ins, vague quantifiers, and dramatized stakes belong to blog posts, not technical writing.
- End when the content ends. No "Let me know if you have any questions!", no "Hope this helps!", no closing summary that repeats the document.

## Rhythm tells

Structure gives bots away even when the words are clean:

- Adjective triads everywhere ("fast, reliable, and secure"). Vary list lengths.
- "It's not just X — it's Y" and "not only... but also" constructions.
- Every bullet opening with a **Bold label:** pattern.
- Uniform sentence length. Mix short and long.
- Restating the question before answering it.

## Sanitized is still a bot

Applying every rule above mechanically produces text that is grammatical, restrained, and still obviously machine-written. Draft 2 in [references/pr-example.md](references/pr-example.md) shows this failure mode in full. What still gives it away:

- Exhaustive coverage. Narrating every change in the diff with equal weight is a tell. Weight by what the reviewer needs — the idea, the non-obvious mechanics, the traps — and let the diff carry the mechanical rest. Dropping detail is allowed; a human decides what matters.
- Uniform grammar. Bullets of identical shape and length read assembled, not written. Human structure is ragged: a one-line bullet next to a three-line one, a lopsided section, a list that gives way to prose.
- Stiff register. Contractions are normal. First person is normal in a PR ("I'd rather land this first"). "it is hard to miss" reads machine; "it's easy to spot" reads human.
- Zero texture, or fake texture. A lowercase tool name, a short parenthetical aside, a first-person call are fine when they carry information. Injected casualness ("for real", "happily", "sneaks in") is worse than sterile: it reads as a bot impersonating a person. Default to plain technical writing and let personality in only where it adds meaning. Don't inject errors on purpose; stop polishing once the content is right.

## Channel notes

- PR and MR descriptions: lead with what changed and why it was needed. Don't paraphrase the diff hunk by hunk; explain intent, non-obvious mechanics, and consequences. Validation states exactly what ran and what happened.
- Commit messages: imperative subject, body explains why. The repo's existing convention wins over any general rule.
- Chat, Slack, and texts: answer first, context only if needed. Match the channel's register — lowercase, contractions, whatever is already the norm. No headers, no bullet decks, no sign-offs in a DM.
- Email: match the thread's existing formality. Plain paragraphs; bullets only for genuine lists like action items.

## Final pass

Reread the draft as the zero-context reader:

1. Any sentence that needs the chat to make sense: fix or cut.
2. Count bolds, bullets, and em dashes (a pair counts as two). If the density feels high for the length, cut.
3. Read each sentence as if speaking to a colleague. Anything you wouldn't say out loud, rewrite.
4. Fragments become sentences; arrows become words; parenthetical claims become sentences.
5. If the last paragraph summarizes the document or offers help, delete it.
6. If every bullet has the same shape, or every change in the diff got its own bullet, the text was assembled rather than written — vary, merge, and cut what the diff already says.

For the same PR description written three ways — bot voice, rules applied but still a bot, human — read [references/pr-example.md](references/pr-example.md) before writing PR descriptions or other long-form artifacts.
