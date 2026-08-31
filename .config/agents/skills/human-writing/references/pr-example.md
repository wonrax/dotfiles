# One PR, three drafts

The same PR described three times. Draft 1 is raw bot voice. Draft 2 applies the mechanical rules in SKILL.md and is still recognizably machine-written — this is the overcorrection trap. Draft 3 is the target. The diff between drafts 2 and 3 matters more than the diff between 1 and 2.

## Draft 1 — bot voice

Over-formatted, over-compressed, over-sold: arrow chains and `+`-as-and in prose, CAPS and italics for stress, label-colon fragments, claims stuffed in parentheses, hype words ("unmissable", "belt-and-suspenders", "cheap canary").

```markdown
## What

Live chat turns had **zero e2e coverage**: MOCK_AGENT short-circuits the viz/replay/extraction paths *before* the agent, and the real thread-turn path (`thread_service` → `run_agent`) would call an actual provider — cost + nondeterminism meant no spec could exist. This PR adds an explicit test-stack-only fake provider UNDER the real machinery, plus the first live-turn specs.

## How

- **`LLM_FAKE_PROVIDER=true`** (Settings) → `model_registry.active_provider()` returns `fake`, outranking real credentials (unit-tested: a real key leaking into a test env cannot cause billing). `_build_llm` then constructs `app/llm/fake_chat_model.FakeChatModel` — a `BaseChatModel` with stateless scripted turns:
  - plain question → `E2E-FAKE-ANSWER: <question>` streamed word-by-word (real `answer_delta` SSE traffic)
  - `[e2e:tool]` marker → one scripted `render_table` tool call first, then the final answer on the next model turn — exercising `create_tool_calling_agent`, the scratchpad, and `AgentExecutor`'s loop for real
- The gateway path (`LangChainLLMClient` → `_build_llm`) inherits the fake automatically; startup logs `llm_fake_provider_active` at warning level so a misconfigured real deployment is unmissable.
- **Test stack cannot bill anyone**: `docker-compose.test.yml` sets the flag AND blanks every provider credential inherited from `.env` (`ANTHROPIC_API_KEY`, `AWS_BEARER_TOKEN_BEDROCK`, AWS key trio) — belt-and-suspenders for code paths that build clients straight from settings (`entity_extraction`/`protocol_summary`). CI e2e job gets the flag too.
- **Specs**: `e2e/chat/live-turn.spec.ts` — streamed answer + reload persistence; tool round-trip. `createCabinetAndDoc` gains a `domain` option: the backend refuses turns whose scope resolves to zero documents, and the scope resolver matches docs by domain, so a sendable thread needs a domained doc.
- **Unit regression harness**: `test_fake_chat_model.py` runs a full `AgentExecutor` round-trip in-process — bind_tools → scripted tool call → scratchpad → final answer. This is the cheap canary for the upcoming langchain 0.3→1.x migration.

## Validation

- Backend: ruff clean; unit suite **1377 passed** (17 failures are the documented host-weasyprint pdf limitation — env-only, untouched; CI installs libpango and runs them).
- E2E: `live-turn.spec.ts` **2/2 green** locally against the compose test stack; backend verified streaming `started → answer_delta… → result` with `provider=fake model=fake-chat-v1` in the startup log.

## Why now

The langchain 0.3→1.x migration (carries the family's 3 Snyk mediums) touches exactly the agent loop / scratchpad / streaming code this suite exercises. Land this first → migrate on a branch → rerun the same specs as the migration's e2e validation.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## Draft 2 — rules applied, still a bot

Sentences are complete, arrows and fragments are gone, claims left the parentheses, hype words are replaced. It still reads machine-written: every change in the diff gets its own bullet in the same two-to-three-sentence cadence, there is no first person and no contraction anywhere, every section is equally fleshed out, and bold still decorates claims. Assembled, not written.

```markdown
## What

Live chat turns had **no e2e coverage**. `MOCK_AGENT` bypasses the viz, replay, and extraction paths before reaching the agent, while the real thread-turn path (`thread_service` → `run_agent`) calls an actual provider. The cost and nondeterminism made it impractical to test.

This PR adds a test-only fake provider beneath the real agent machinery, along with the first live-turn specs.

## How

- Setting **`LLM_FAKE_PROVIDER=true`** makes `model_registry.active_provider()` return `fake`, taking precedence over any real credentials. A unit test verifies that a real key leaking into the test environment cannot trigger billing.
- `_build_llm` constructs `app/llm/fake_chat_model.FakeChatModel`, a `BaseChatModel` with stateless scripted turns:
  - A plain question returns `E2E-FAKE-ANSWER: <question>`, streamed word by word through real `answer_delta` SSE events.
  - An `[e2e:tool]` marker triggers a scripted `render_table` call, followed by the final answer on the next model turn. This exercises `create_tool_calling_agent`, the scratchpad, and the actual `AgentExecutor` loop.
- The gateway path (`LangChainLLMClient` → `_build_llm`) picks up the fake automatically. Startup logs `llm_fake_provider_active` at warning level so it is hard to miss if enabled in a real deployment.
- The test stack cannot bill a provider. `docker-compose.test.yml` enables the flag and clears all provider credentials inherited from `.env`: `ANTHROPIC_API_KEY`, `AWS_BEARER_TOKEN_BEDROCK`, and the AWS key trio. This also covers code paths such as `entity_extraction` and `protocol_summary`, which build clients directly from settings. The CI e2e job enables the flag as well.
- `e2e/chat/live-turn.spec.ts` covers a streamed answer with reload persistence and a tool round-trip.
- `createCabinetAndDoc` now accepts a `domain` option. The backend rejects turns when their scope resolves to zero documents, and the scope resolver matches documents by domain, so a sendable thread needs a document with a domain.
- `test_fake_chat_model.py` runs a full `AgentExecutor` round-trip in-process: `bind_tools` → scripted tool call → scratchpad → final answer. This gives us a cheap regression test for the upcoming LangChain 0.3 → 1.x migration.

## Validation

- Backend: Ruff clean; unit suite **1377 passed**. The remaining 17 failures are the documented host-WeasyPrint PDF limitation and are unrelated to this change. CI installs `libpango` and runs them successfully.
- E2E: `live-turn.spec.ts` is **2/2 green** locally against the Compose test stack.
- Verified backend streaming sequence: `started` → `answer_delta…` → `result`.
- Startup log confirmed `provider=fake model=fake-chat-v1`.

## Why now

The LangChain 0.3 → 1.x migration, which includes fixes for the package family's three medium-severity Snyk findings, touches the same agent loop, scratchpad, and streaming code covered here. Landing these tests first gives the migration branch a stable e2e check.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

## Draft 3 — human

Weighted by what a reviewer needs, and it trusts the diff: the credential variable names and most file paths are dropped, not rephrased. Contractions and first person appear where they carry a decision. Sections are lopsided; How carries the story in prose, Validation is one paragraph. Bold is gone, em dashes are gone. The register is plain technical writing: precise verbs (stubs, constructs, exercises), no spatial metaphors, no injected casualness, and list lead-ins that describe ("Guards against misconfiguration") instead of sell ("A few guards so this can't bill anyone").

```markdown
## What

There's no e2e coverage for live chat turns. `MOCK_AGENT` covers the viz, replay, and extraction flows but bypasses the agent code. The real path (`thread_service` → `run_agent`) calls an actual provider, so a spec against it would be flaky and cost money on every CI run.

This adds a fake provider that stubs before the core chat implementation: the agent loop, streaming, and persistence all run, only the model is scripted, plus the first specs that use it.

## How

Set `LLM_FAKE_PROVIDER=true` and `model_registry.active_provider()` returns `fake`, even when real credentials are present. `_build_llm` then constructs `FakeChatModel`, a `BaseChatModel` with stateless scripted turns. A plain question streams `E2E-FAKE-ANSWER: <question>` word by word through the `answer_delta` SSE path. A question containing `[e2e:tool]` calls `render_table` first and answers on the next turn, which exercises the `AgentExecutor` tool loop and the scratchpad. Every caller of `_build_llm`, including the gateway path, gets the fake without changes.

Guards against misconfiguration:

- startup logs a warning when the fake is active, so it's visible if enabled in a real deployment
- the test compose file and the CI e2e job both set the flag, and the compose file also blanks every provider credential inherited from `.env`, because `entity_extraction` and `protocol_summary` build clients directly from settings and the flag alone wouldn't cover them
- a unit test covers the precedence: a real credential leaking into the test environment is never used

The specs are in `e2e/chat/live-turn.spec.ts`: one streamed answer (checked again after a reload), one tool round-trip. Getting a sendable thread meant adding a `domain` option to `createCabinetAndDoc`, since the backend refuses turns whose scope resolves to zero documents and scoping matches docs by domain.

There's also `test_fake_chat_model.py`, which runs a full `AgentExecutor` round-trip in-process. It exists mainly as a regression check for the langchain 0.3 → 1.x migration.

## Validation

ruff and the unit suite pass: 1377 passed, and the 17 failures are the known weasyprint-on-host issue (CI installs libpango and runs them). Both specs pass against the compose stack, with `provider=fake model=fake-chat-v1` in the backend log and the full `started → answer_delta → result` event sequence.

## Why now

The langchain 0.3 → 1.x bump is next (it clears the three medium Snyk findings), and it rewrites exactly the code these specs cover: the agent loop, scratchpad, and streaming. I'd rather land the specs first and rerun them on the migration branch than review that migration blind.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
