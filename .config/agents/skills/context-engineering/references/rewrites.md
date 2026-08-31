# Rewrites

Before/after pairs for the common surfaces. Each one names the move it demonstrates.

Contents: [System prompt](#system-prompt) · [CLAUDE.md](#claudemd) · [Tool descriptions](#tool-descriptions) · [Skills](#skills) · [Specs and references](#specs-and-references) · [Subagent prompts](#subagent-prompts) · [Rules worth keeping](#rules-worth-keeping)

## System prompt

Prohibition to intent. The rule is wrong wherever the codebase or the user disagrees, and the model can read the surrounding code.

```
Bad:  In code: default to writing no comments. Never write multi-paragraph docstrings
      or multi-line comment blocks - one short line max. Don't create planning,
      decision, or analysis documents unless the user asks for them.
Good: Write code that reads like the surrounding code: match its comment density,
      naming, and idiom.
```

Two layers, one topic. The skill says one thing and the system prompt says the opposite, so every request pays to reconcile them. Pick one and delete the other rather than adding a precedence rule.

```
Bad:  [system prompt]  DO NOT add comments to generated code.
      [skill]          Leave documentation as appropriate for the change.
      [CLAUDE.md]      Comment public APIs.
Good: [CLAUDE.md]      Public APIs carry doc comments; internals stay uncommented.
```

## CLAUDE.md

Discoverable facts out, gotchas in. The first version narrates what `ls` already shows.

```
Bad:  This is a TypeScript monorepo using pnpm workspaces. Source lives in src/,
      tests in tests/, and the CLI entrypoint is src/cli.ts. Run tests with
      `pnpm test`. We use Vitest.
Good: Every type lives in src/model.ts and nowhere else - adding one next to its
      consumer breaks the codegen step. Tests need `pnpm dev:db` running first;
      the failure looks like a timeout, not a connection error.
```

Procedure moves behind a trigger. A verification section that applies to one change in ten does not belong in context for the other nine.

```
Bad:  ## Verification
      After any change to the sync engine, run the contract tests, then the
      docker smoke test, then check the dashboard for orphaned tasks, then...
      [30 more lines]
Good: Changes to the sync engine need the full verification pass: see
      .claude/skills/verify-sync/SKILL.md.
```

## Tool descriptions

Examples out, schema in. The example version answers one case; the enum teaches the whole lifecycle.

```
Bad:  Updates a todo item. Example: {"id": "1", "status": "in_progress"}
      Example: {"id": "2", "status": "completed"}
      Example: mark a task done when you finish it.
Good: Updates a todo item's state as work progresses.
      status: pending | in_progress | completed
      Keep exactly one item in_progress.
```

Instructions move to the point of use. The system prompt copy drifts from the description copy, and the model reads both.

```
Bad:  [system prompt]  Always call SearchDocs before answering questions about the
                       API. Pass the user's exact wording as the query.
      [tool]           Searches the docs.
Good: [system prompt]  -
      [tool]           Searches the API documentation. Use before answering any
                       question about API behavior, since local knowledge lags the
                       docs. query: the user's wording, unrewritten - the index is
                       tuned for natural phrasing.
```

## Skills

The description is the trigger. The first version fires on nothing because it never names a surface.

```
Bad:  description: Helps with database work.
Good: description: Query patterns and schema gotchas for the analytics warehouse.
      Use when writing or debugging SQL against the events, sessions, or billing
      tables, when a query is slow, or when a column's meaning is unclear.
```

## Specs and references

Prose about code loses to code. The second version is unambiguous and already executable.

```
Bad:  The parser should handle nested quotes, escape sequences, and trailing
      commas leniently, returning a partial result on malformed input rather
      than throwing.
Good: The behavior is pinned by tests/parser.spec.ts - make those pass. The
      lenient-recovery shape mirrors packages/legacy/json5.ts:parseLoose.
```

Design descriptions lose to artifacts.

```
Bad:  Build a settings page with a sidebar on the left, sections for profile,
      billing, and notifications, and a sticky save bar at the bottom.
Good: Match mockups/settings.html. Section order and the sticky save bar are
      load-bearing; colors come from the existing theme tokens.
```

## Subagent prompts

Goal and return contract, not a script. The step list forecloses what the subagent might discover.

```
Bad:  Step 1: run rg for "useEffect". Step 2: open each file. Step 3: check for
      a dependency array. Step 4: if missing, note the line. Step 5: report.
Good: Find effects in src/ that re-run more often than intended. Return each as
      {file, line, why} - empty array if none.
```

## Rules worth keeping

Deletion is the default, not the goal. These survive because the failure has a name and the model cannot infer the answer from context.

```
Keep: Never force-push to main - the release tags are cut from it.
      (irreversible, and the repo gives no hint)

Keep: This project uses jj, not git. Running git commands alongside a jj working
      copy corrupts the repository.
      (local convention, catastrophic failure, .git exists and looks normal)

Keep: Reviews report findings via the ReportFindings tool, ranked most severe
      first. Never also print them as text.
      (an interface contract the model has no way to guess)
```
