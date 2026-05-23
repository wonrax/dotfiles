---
name: effective-planning
description: Guides thoughtful, iterative planning for complex tasks. Use when the user asks for help with planning, structuring work, or needs to break down a complex problem before execution. Triggers on phrases like "help me plan", "how should I approach this", "what's the best way to", "create a plan for", or when the user seems uncertain about how to proceed with a multi-step task.
---

# Effective Planning

## Overview

Guide users through a thoughtful, iterative planning process that prioritizes exploration and understanding before committing to a specific approach. Avoid rushing to conclusions—instead, ask questions, brainstorm possibilities, and refine plans collaboratively.

## Core Principles

### 1. Explore Before Concluding

**Never jump to a plan immediately.** Premature conclusions waste time and often miss better alternatives.

**Instead, prioritize:**
- Asking clarifying questions to understand the full context
- Exploring different approaches and tradeoffs
- Brainstorming possibilities with the user
- Identifying constraints, requirements, and unknowns

**Signs you should explore more:**
- User hasn't provided specific details about requirements
- Multiple valid approaches exist
- Technical constraints haven't been discussed
- Success criteria are unclear

### 2. Provide Direction When User Is Lost

**When the user seems stuck or unsure,** give them an initial direction or rough plan to react to.

**Approach:**
1. Offer a "strawman" plan or initial direction based on what you know
2. Present it as a starting point for discussion, not a final answer
3. Ask specific questions about what to adjust or refine
4. Iterate based on their feedback

**Example:**
> "Based on what you've shared, I'm thinking we approach this in three phases: first X, then Y, finally Z. Does that feel right? Should we adjust the order or add anything?"

### 3. Don't Waste Context on Unnecessary Confirmations

**Never output a detailed final plan after every user message just for confirmation.** This wastes context window and slows progress.

**Instead:**
- For small adjustments or clarifications: Simply acknowledge and continue
- When a significant milestone is reached: Ask if they're satisfied or want to review
- When the plan feels complete: Ask explicitly: "Does this plan look good, or would you like to review/adjust anything before we start?"

**Context-aware behavior:**
| Situation | Action |
|-----------|--------|
| User asks a small question about the plan | Answer directly, no need to re-output full plan |
| User provides new requirements | Incorporate silently and confirm briefly |
| User seems uncertain about direction | Offer to walk through the current plan together |
| Multiple options exist | Present options concisely, ask for preference |
| Plan feels complete | Ask: "Ready to proceed, or want to review first?" |

## Planning Workflow

### Phase 1: Discovery (Always Start Here)

Begin every planning session by gathering context:

1. **Understand the goal**
   - What are we trying to achieve?
   - What does success look like?
   - Are there specific constraints or requirements?

2. **Explore the landscape**
   - What approaches could work?
   - What are the tradeoffs between them?
   - Are there unknowns we need to resolve?

3. **Ask clarifying questions**
   - Don't assume—ask about anything unclear
   - Focus on the most important unknowns first
   - Give the user options when they're unsure

### Phase 2: Direction (When Needed)

If the user seems lost or wants guidance:

1. **Draft an initial approach** based on what you know
2. **Present it as a hypothesis:** "Here's one way we could approach this..."
3. **Ask for feedback:** "Does this direction feel right? What would you change?"
4. **Iterate rapidly** based on their response

### Phase 3: Refinement

As the plan takes shape:

1. **Incorporate feedback** without re-outputting the entire plan each time
2. **Focus on open questions** or decisions that need to be made
3. **Highlight tradeoffs** the user should consider
4. **Keep it lightweight**—only present what's needed to move forward

### Phase 4: Confirmation (At the Right Time)

Before execution begins:

1. **Ask for explicit confirmation:** "Are you satisfied with this plan, or would you like to review/adjust anything before we start?"
2. **If they want to review:** Present a concise summary of the plan
3. **If they're satisfied:** Transition smoothly into execution

## Common Anti-Patterns to Avoid

| Anti-Pattern | Better Approach |
|--------------|-----------------|
| Outputting full plan after every user message | Only output plan when explicitly asked or at natural review points |
| Immediately presenting a detailed plan without questions | First ask 1-2 key questions to understand context |
| Sticking to first approach that comes to mind | Brainstorm 2-3 alternatives, discuss tradeoffs |
| Asking user to choose between options without recommendation | Offer a recommendation with reasoning, ask for their preference |
| Repeating the entire plan for small clarifications | Acknowledge change briefly, confirm understanding |

## Example Interactions

### Good: Exploration First

> **User:** "I need to refactor this codebase"
>
> **Agent:** "Before we dive into a plan, let me understand better: What prompted the refactor? Are there specific pain points (performance, maintainability, tech debt), or is this part of adding new features? And what's your timeline—are we doing this incrementally or is there a hard deadline?"

### Good: Direction When Lost

> **User:** "I'm not sure how to structure this project..."
>
> **Agent:** "Based on what you've shared, I'm thinking we organize it like this: [brief structure]. The main benefit is X, though we could also do Y if you prefer Z. What aspects of this feel right or wrong to you?"

### Good: Lightweight Confirmation

> **User:** "Yeah, let's add testing to phase 2"
>
> **Agent:** "Got it—incorporating testing into phase 2. Does the overall plan feel solid now, or are there other adjustments before we dive in?"

### Bad: Premature Conclusion

> **User:** "I need help with this feature"
>
> **Agent:** "Here's the complete plan: [lengthy detailed plan spanning 20 lines]... Let me know if this looks good!"
>
> **Problem:** No questions asked, no exploration of alternatives, full plan output immediately.

### Bad: Unnecessary Repetition

> **User:** "Can we move step 3 before step 2?"
>
> **Agent:** "[Re-outputs entire 15-step plan with the swap made]... Does this updated plan look good?"
>
> **Problem:** Should have just said "Done—swapped steps 2 and 3. Ready to proceed?"
