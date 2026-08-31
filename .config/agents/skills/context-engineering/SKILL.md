---
name: context-engineering
description: How to write context that a model reads rather than a human. Use BEFORE writing or editing any agent-facing text - system prompts, agent and subagent prompts, CLAUDE.md or AGENTS.md, skills, tool and MCP descriptions, JSON schema field descriptions, slash commands, rubrics, and prompt strings embedded in application code. Also use when auditing or trimming existing instructions, when deciding where a piece of guidance belongs, or when an agent ignores, over-applies, or seems confused by its instructions. Covers trading rules for judgement, designing interfaces instead of supplying examples, progressive disclosure, and picking high-fidelity references. For prose aimed at people, use human-writing instead.
---

# Context Engineering

Anthropic deleted over 80% of Claude Code's system prompt for Claude 5 generation models with no measurable loss on coding evals. That result generalizes: with current models the usual failure is overconstraint, not underspecification. Every line is paid for on every request, and every line is a chance to contradict another layer.

Write less. Say the intent instead of the prohibition. Put it where it is used, and load it only when it is needed.

## Rules lose to judgement

A blanket rule is wrong for some subset of requests, and the model spends reasoning reconciling it with the request in front of it.

```
Bad:  In code: default to writing no comments. Never write multi-paragraph docstrings
      or multi-line comment blocks - one short line max.
Good: Write code that reads like the surrounding code: match its comment density,
      naming, and idiom.
```

Before writing a rule, name the specific failure it prevents, then ask whether the model would actually do that without being told. If no failure can be named, cut the line.

Rules still earn their place for irreversible or destructive actions, and for taste and local conventions that cannot be inferred from the repo. Everywhere else, describe the goal and let surrounding context decide.

## Conflicts are resolved by deletion

Context arrives assembled from the system prompt, CLAUDE.md, skills, memory, tool descriptions, and the user's own message. When two layers disagree - "leave documentation as appropriate" against "DO NOT add comments" - behavior gets unpredictable and reasoning gets spent on the contradiction rather than the task.

Before adding a line, search the other layers for the same topic. When two exist, delete the loser. Adding a tiebreaker sentence just creates a third instruction.

## Design the interface instead of giving examples

Usage examples pin the model to the shape of the example and shrink the space it explores. Spend those tokens on the interface instead: expressive parameter names, enums over free-form strings, required versus optional, types that make illegal states unrepresentable. A `status` enum of `pending | in_progress | completed` teaches the lifecycle by existing; one line - "keep exactly one item in_progress" - covers what the schema cannot say.

The same holds for scripts and CLIs handed to an agent: flag names, `--help` output, and error text are the instruction.

For tool descriptions, parameter docs, return values, and when an example is genuinely justified, read [references/tool-design.md](references/tool-design.md).

## Instructions live at the point of use

Tool usage guidance belongs in the tool description, not the system prompt, and not both. Repetition was a workaround for older models weighting the end of the context window more heavily; now it only costs tokens and invites drift between the two copies.

The general form: guidance sits with the thing it governs. A quirk about one module belongs in that module's docs or the skill that touches it, not in global memory.

## Progressive disclosure

Crucial-but-rare content should be reachable, not resident.

- Verification steps, review checklists, runbooks: their own skill or reference file.
- Long skills: a tree of files one level deep, each with a line saying when to open it.
- Large tool sets: deferred loading, so definitions cost nothing until searched.
- CLAUDE.md: a router, not a repository.

The trigger line does the work. A reference nobody knows to open is dead weight, so state the condition for reading it, not just its existence.

## CLAUDE.md and AGENTS.md

Brief statement of what the repo is, then spend the rest on gotchas: invariants and traps that reading the code does not reveal quickly. All types live in one file. This crate must not import that one. The suite needs a fixture server running.

Cut anything discoverable in ten seconds with `ls` or `rg`, and anything already in package.json, the README, or file naming. Hand-maintained memory sections are also obsolete - the harness saves relevant memories on its own. Anything procedural becomes a skill that CLAUDE.md names.

## Prefer references that are code

Models read code with higher fidelity than prose about code. When a reference exists in a form the model can execute or mirror, point at it instead of describing it.

- A test suite or type signature as the spec, over a prose spec.
- An existing function or module to port or mirror, over a description of the design.
- An HTML mockup, over a screenshot, over a paragraph describing the layout.
- A rubric the model can check work against, and hand to verifier subagents.

@-mention the file rather than paraphrasing it.

## Skills

A skill is a lightweight guide for finding information at the right moment, not a rulebook. Constrain tightly only where the stakes are high.

Encode what is specific to you, the team, or the product: opinions, house conventions, hard-won gotchas. Generic best practice is already in the model and only adds noise.

The `description` field is the entire trigger - the body is read only after it fires, so "when to use this" must live in the description, covering both what the skill does and the surfaces or phrases that should summon it.

## Before shipping the context

1. For each line, name the failure it prevents. Cannot name one, cut it.
2. Search the other layers for the same topic. Delete the loser, do not arbitrate.
3. Cut anything the agent could discover with `ls`, `rg`, or by opening the file it describes.
4. Check placement: at the point of use, and behind a trigger line if rarely needed.
5. Rewrite prohibitions as intent, and usage examples as interface.
6. Run the real task with the line and without it. Keep the version that works; keep the shorter one on a tie. For inherited configs, `claude doctor` rightsizes CLAUDE.md and skills.

Worked before/after pairs across all of these surfaces are in [references/rewrites.md](references/rewrites.md) - read it when rewriting an existing prompt or when a concrete model would help.
