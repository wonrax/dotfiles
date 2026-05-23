---
name: slop-terminator
description: Review code changes (diffs) and identify slops, vibecoded artifacts, and low-quality code patterns. Use when reviewing PRs, cleaning up changesets, or eliminating slops including contextual comments, over-abstraction, dead code, style inconsistencies etc.
---

# Slop Terminator

Review code changes and identify slops—low-quality artifacts left by AI agents during development.

## Core Workflow

1. **Get the diff**: Check for jj (`.jj/` directory) first, fall back to git
   - jj: `jj diff --from "trunk()"`
   - git: `git diff HEAD~1` or compare to trunk/main
2. **Analyze changed files**: Read modified files and the diff
3. **Identify slops**: Mark each issue found
4. **Report findings**: List slops with file:line references

## Slop Patterns to Detect

### 1. Contextual/Session Comments
Comments explaining why the agent made a change in this specific session:
- "Added this function to fix the bug"
- "Refactored to be more readable"
- "Updated as requested"
- "We need to..." (agentic language)
- TODO/FIXME that reference conversation context
- Organizational comments summarizing what code does

**Keep only**: Comments explaining WHY code exists for future maintainers when the reason is non-obvious.

### 2. Over-Abstraction
Functions split into tiny pieces with no clear purpose:
- Private methods that are only called once
- Functions that just call another function
- "Helper" functions that don't share code or abstract complexity
- Excessive indirection (A calls B calls C calls D for simple logic)

### 3. Under-Abstraction
- Repeated code blocks that should be functions
- Copy-pasted logic with minor variations
- Large functions doing too many things

### 4. Dead/Inefficient Code
- Unused imports, variables, or functions after refactoring
- Code that no longer fits the new architecture
- Obsolete workarounds that were forgotten
- Imports added but never used

### 5. Unnecessary Defensive Checks
- Try/catch blocks in trusted code paths
- Redundant null checks in validated contexts
- Exception handling that just re-throws
- Checks that contradict the established contract

### 6. Style Inconsistencies
- Different naming conventions within a file
- Mixed quote styles, spacing, or formatting
- Patterns that don't match surrounding code

### 7. Agentic Emoji/Symbol Usage
- Unusual symbols a human wouldn't type
- Decorative emoji in code or comments
- Unicode symbols for basic operations (➕ instead of +)

## Output Format

For each slop found, report:
- **File:Line**: Location
- **Type**: Category (comment/abstraction/dead-code/defensive/style/symbol)
- **Issue**: What was found
- **Suggestion**: How to fix (or "Remove")

## Diff Commands

```bash
# jj (preferred if .jj/ exists)
jj diff --from "trunk()" --stat
cd <file-dir> && jj diff --from "trunk()" <file>

# git (fallback)
git diff HEAD~1 --name-only
git diff HEAD~1 <file>
git diff main --name-only
git diff main <file>
```

## Example Analysis

```
FILE: src/utils.js:42
TYPE: comment
ISSUE: "Added this to handle the edge case from our discussion"
FIX: Remove - explains conversation context, not code purpose

FILE: src/api.js:15
TYPE: abstraction
ISSUE: Private method `processData()` just calls `transform()`
FIX: Inline `processData()` calls

FILE: src/handlers.js:8
TYPE: dead-code
ISSUE: Import `lodash` added but not used
FIX: Remove import
```
