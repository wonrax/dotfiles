# Tool and Interface Design

Contents: [Description](#the-description-is-the-manual) · [Parameters](#parameters-carry-the-instruction) · [Examples](#when-an-example-is-justified) · [Returns and errors](#returns-and-errors-are-instructions-too) · [Tool sets](#sizing-the-tool-set) · [Subagent prompts](#subagent-prompts-are-interfaces-too) · [Checklist](#checklist)

Applies to anything an agent calls through a schema: native tools, MCP servers, CLIs and scripts written for agent use, and subagent contracts.

## The description is the manual

The description is read twice: once when deciding whether this tool is the right one, and again when constructing the call. Front-load the first job.

- Open with what the tool does and when to reach for it. That sentence is the routing signal, and it does the same work as a skill's `description`.
- State scope limits early, because they prevent wrong selection rather than wrong arguments: what the tool cannot do, what it is not for, which sibling tool covers the neighboring case.
- Put call-construction detail after the routing sentence. Ordering the other way makes the model read argument trivia to answer a selection question.
- Describe behavior, not implementation. The agent cannot see the code, and internal detail invites reasoning about mechanics that do not affect the call.
- Say what happens on success, since that determines whether a follow-up call is needed.

Never restate the tool's rules in the system prompt. The description is already loaded whenever the tool is a candidate.

## Parameters carry the instruction

Anything the schema can enforce should not be prose. Schema constraints are validated; prose constraints are advisory and cost tokens on every read.

- Enums over free strings. The allowed set teaches the model the domain's states.
- Names from the domain, not the implementation: `commit_range` beats `arg2`, `include_drafts` beats `flag`.
- Required versus optional communicates the minimal call. Anything with a sensible default should be optional, with the default named in the parameter's own description.
- Types that make illegal states unrepresentable beat a warning sentence about not combining two fields.
- Per-parameter descriptions handle per-parameter facts. Units, coordinate spaces, accepted formats, and clamping ranges go on the field, not in the tool blurb.
- Avoid an `action` or `mode` string that multiplexes unrelated behaviors. Either split into separate tools, or make the enum exhaustive and its values self-describing.

Reserve tool-level prose for what the schema genuinely cannot express: cross-parameter invariants, sequencing against other tools, and behavioral requests such as keeping exactly one item in progress.

## When an example is justified

Default to none. Examples narrow the exploration space, and the cost is invisible - the model simply stops considering the calls that do not resemble them.

Include one only when the format is ambiguous and the schema cannot capture it: a query DSL, an exact timestamp format, a path syntax with escaping rules, an encoding. Then give one minimal example of the format alone, not a gallery of use cases. An example that demonstrates *when* to call the tool is a description problem, not an example problem.

## Returns and errors are instructions too

Return payloads and error strings are context delivered exactly when relevant and free until then. This is the cheapest instruction channel available.

- Make results self-describing. Identifiers the agent will need later should be labeled in the payload rather than explained in the tool description.
- Errors state the cause and the next action: "no booted simulator - boot one, then retry" rather than "invalid state". A good error deletes a paragraph of preconditions from the description.
- Say plainly when retrying will not help, otherwise a model facing a wall will try the same call again.
- Truncate large results with an explicit marker and a way to fetch the rest. Silent truncation reads as a complete answer.

## Sizing the tool set

Prefer fewer, more expressive tools over many near-duplicates: overlapping tools force a selection decision on every call and their descriptions all stay resident.

When the surface is genuinely large, use deferred loading. Definitions stay out of context until the agent searches for them, which buys tool count without paying for it upfront. Keep the frequently-used core loaded and defer the long tail.

## Subagent prompts are interfaces too

A subagent prompt is a call signature. Specify the goal, the constraints that matter, and the shape of what must come back. Do not script the steps - the same overconstraint tax applies, and the parent cannot anticipate what the subagent will find.

State the return contract explicitly, including what to return when the work turns up nothing. A schema for the response beats a prose description of the response.

## Checklist

1. Can the first sentence alone answer "is this the tool I want?"
2. Is every prose constraint one the schema could not enforce?
3. Are enums used wherever the value set is closed?
4. Does any example exist for a reason other than an ambiguous format?
5. Do the errors say what to do next?
6. Does the system prompt repeat anything already in the description?
