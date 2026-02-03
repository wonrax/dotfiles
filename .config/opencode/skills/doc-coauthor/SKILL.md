---
name: doc-coauthor
description: Guide users through a structured workflow for co-authoring documentation. Use when user wants to write documentation, proposals, technical specs, decision docs, RFCs, READMEs, or similar structured content. Triggers on phrases like "write a doc", "draft a proposal", "create a spec", "document this", or mentions of PRDs, design docs, decision docs, RFCs.
---

# Document Co-Authoring Workflow

Guide users through collaborative document creation in three stages: Context Gathering, Refinement & Structure, and Reader Testing.

## When to Offer This Workflow

**Trigger phrases:** "write a doc", "draft a proposal", "create a spec", "document this", "PRD", "design doc", "decision doc", "RFC"

**Initial offer:**
Explain the three-stage workflow:
1. **Context Gathering** - Transfer knowledge and ask clarifying questions
2. **Refinement & Structure** - Build sections iteratively through brainstorming and editing
3. **Reader Testing** - Test with a fresh agent instance to catch blind spots

Ask if they want this structured approach or prefer freeform. If declined, work freeform. If accepted, proceed to Stage 1.

## Stage 1: Context Gathering

**Goal:** Close the knowledge gap between user and agent.

### Initial Questions

Ask 5 meta-questions:
1. What type of document? (spec, decision doc, proposal, README, etc.)
2. Who's the primary audience?
3. What's the desired impact when someone reads this?
4. Is there a template or specific format?
5. Any constraints or additional context?

Inform them they can answer in shorthand.

**If user mentions a template:**
- Ask if they have a template file to share
- If they provide a file path, read it with the Read tool

### Info Dumping

Encourage the user to dump all context:
- Background on the project/problem
- Related discussions or documents
- Why alternatives aren't being used
- Organizational context
- Timeline pressures
- Technical architecture

Advise them not to organize it - just get it out.

**If user mentions files or documents:**
- If they provide file paths, read them
- If they provide links, ask them to share the content directly

### Clarifying Questions

When user signals they're done dumping context, generate 5-10 numbered questions based on gaps. Accept shorthand answers.

**Exit condition:** Can ask about edge cases and trade-offs without needing basics explained.

**Transition:** Ask if ready to move to drafting, or if more context is needed.

## Stage 2: Refinement & Structure

**Goal:** Build the document section by section.

### Document Setup

**If structure is clear:**
Ask which section to start with (suggest the one with most unknowns).

**If structure is unclear:**
Suggest 3-5 appropriate sections based on doc type. Get confirmation.

**Create the scaffold:**
Create a markdown file in the working directory (e.g., `decision-doc.md`, `technical-spec.md`). Use Write tool to create the file with all section headers and placeholder text like "[To be written]".

Inform them the scaffold is ready and it's time to fill in sections.

### Section Workflow

For each section:

**Step 1: Clarifying Questions**
Ask 5-10 specific questions about what to include in this section.

**Step 2: Brainstorming**
Generate 5-20 numbered options for content. Look for forgotten context and unmentioned angles.

**Step 3: Curation**
Ask which points to keep/remove/combine. Accept formats like:
- "Keep 1,4,7,9"
- "Remove 3 (duplicates 1)"
- "Combine 11 and 12"

**Step 4: Gap Check**
Ask if anything important is missing for this section.

**Step 5: Drafting**
Use Edit tool to replace the placeholder text with drafted content. Confirm completion and ask them to review.

**Key instruction:** Instead of editing directly, ask them to indicate what to change (e.g., "Remove X - covered by Y"). This helps learn their style.

**Step 6: Iterative Refinement**
Use Edit tool for changes. Continue until satisfied.

After 3 iterations with no substantial changes, ask if anything can be removed without losing information.

**Repeat for all sections.**

### Near Completion

When 80%+ sections done, re-read entire document and check for:
- Flow and consistency
- Redundancy or contradictions
- Generic filler content
- Whether every sentence carries weight

Review and provide suggestions. Ask if ready for Reader Testing.

## Stage 3: Reader Testing

**Goal:** Verify the document works for readers with no prior context.

### Testing Approach

Use Task tool to spawn sub-agents for testing.

### Step 1: Predict Questions

Generate 5-10 questions readers would realistically ask when discovering this document.

### Step 2: Test with Sub-Agent

For each question:
1. Spawn a sub-agent using Task tool with:
   - The document content
   - The reader question
   - Instructions to answer based only on the document
2. Summarize what Reader Agent got right/wrong

### Step 3: Additional Checks

Spawn sub-agent to check for:
- Ambiguity or unclear sections
- False assumptions
- Internal contradictions

### Step 4: Fix Issues

If issues found, report them and loop back to Stage 2 to refine problematic sections.

### Exit Condition

When Reader Agent consistently answers correctly and finds no gaps, proceed to Final Review.

## Final Review

When testing passes:

1. Remind them they own the document - do a final read-through
2. Suggest double-checking facts, links, technical details
3. Ask if it achieves the desired impact

**Completion:**
Provide tips:
- Link this conversation in an appendix for transparency
- Use appendices for depth without bloating main content
- Update based on real reader feedback

## Tips for Effective Guidance

**Tone:** Direct and procedural. Explain rationale briefly when it affects behavior.

**Handling Deviations:**
- If user wants to skip a stage: Ask if they prefer freeform
- If user seems frustrated: Acknowledge and suggest ways to move faster
- Always give user agency to adjust

**Context Management:**
- Proactively ask about missing context
- Address gaps as they come up

**Quality over Speed:**
- Don't rush through stages
- Each iteration should improve meaningfully
- Goal is a document that works for readers
