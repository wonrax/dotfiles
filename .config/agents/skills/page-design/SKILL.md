---
name: page-design
description: Visual and motion taste rules for standalone pages. Use BEFORE writing any standalone or one-off HTML page (reports, explainers, trackers, system maps, notes, interactive demos) that has no design system of its own, and before adding animation or interaction to one. Overrides generic page design defaults (fonts, cards, borders, badges, callouts, easing, durations). Do NOT use for UI inside a project that already has a design system, tokens or component library, or for product UI design work; follow that project's guidelines instead.
---

# Page Design

Scope: standalone and one-off HTML pages only. If the page lives in a project with its own design system, tokens, DESIGN.md or component library, that wins and these rules don't apply.

What good looks like: one quiet type family, soft shadow surfaces, small mono labels, dots instead of badges, lots of whitespace. The failure mode these rules exist to stop is the generic AI-generated page: a border on every box, filled status pills, accent-bar callouts, an extra display font.

## Information order

- **Explain every term where it first appears, never further down the page.** A status, score or summary card that names a metric, level or internal term carries its plain-language meaning in the same place: a one-line definition in the card, or a "what counts" column next to the status. Never open with a dashboard of jargon and define it in a later section.
- **Put a status next to what it measures.** One table with requirement, what counts, target and current state beats a summary in one section and the definitions in another.
- **Assume the reader has none of your context.** Before using an acronym, ticket number, team name or someone's shorthand, say what it is. Write each note so it makes sense on its own, without the section above it.
  Why: the reader spent 15 minutes decoding a status dashboard full of undefined terms before finding the definitions further down, and assumed the page itself didn't know what they meant.
  <!-- 2026-11-23: "when i look at the 3 card dashboard idk wtf is a driven PR or what guardrails are we fucking have ... then i scrolled down and discover you describe them" -->
- **Present terms the way Wikipedia does, on the first mention only:**
  - Spell out an acronym in full words the first time, with the acronym in parentheses, then use the acronym: "continuous integration (CI)".
  - A public tool, concept or product gets a link to its Wikipedia article or official docs on its first mention. Later mentions are plain text.
  - An internal term with nothing to link to (a team, a shared account, an internal dashboard, a person's role) gets a hover tooltip on its first mention, or a short inline explanation of who or what it is.
  - A ticket ID links to the ticket.
  - Tooltip component: a dotted underline (`border-bottom: 1px dotted var(--ink-3)`), focusable with `tabindex="0"`, shown on hover after 400ms, instantly for the next term within 600ms, instantly on keyboard focus, toggled by tap on touch, closed by Escape. It scales from the term (`transform-origin` at the term) from `scale(0.97)` with `opacity: 0` over 125ms `--ease-out`, and is linked with `aria-describedby`.
  Why: Wikipedia's first-mention convention lets a reader with little context follow without detours, without re-explaining what the page's readers already know.
  <!-- 2026-11-23: "if they can't explain a term there they would link to another wikipedia page (only the first mention) ... or write full words before start using its corresponding acronym. you must write for someone who has as little context as possible (although there should be some baselines so you don't reexplain the world)" -->
- **Prose on the page follows the human-writing rules:** full sentences instead of compressed notes, plain verbs, almost no bold, no em dashes.

## Surfaces

- **Raised surfaces use a shadow ring, never a solid border:** `box-shadow: 0 0 0 1px rgba(ink, .06), 0 1px 2px rgba(ink, .05)`, radius 12-14px. In dark mode: `0 0 0 1px rgba(255,255,255,.07)`. No large blurred drop shadow.
  Why (inferred): bordering every block reads as a generic admin template and flattens hierarchy.
  <!-- 2026-11-23: "why do you always output such design slop" -->
  <!-- 2026-11-25: dropped the `0 8px 24px -8px` layer (and its dark-mode twin): "it looks distracting" -->
- **Only a genuinely separate object gets a card** (a diagram stage, side-by-side cards). Tables, lists, notes and question lists sit directly on the page background.
  Why (inferred): when everything is a card, nothing stands out.
  <!-- 2026-11-23: same correction -->
- **Never put an accent bar or thick left border on a callout or card.** Mark an item with a 7px dot before its heading: filled in the warning color = issue, hollow ring (`box-shadow: inset 0 0 0 1.5px var(--ink-3)`) = open or unresolved.
  Why (inferred): the left-rail callout is a stock AI-generated pattern.
  <!-- 2026-11-23: same correction -->

## Typography

- **One text family plus its mono. Never add a separate display face.**
  - Sans (default): Geist, with Geist Mono. Inter is an acceptable alternative.
  - Serif (when the page is editorial or long-form reading): Crimson Pro, with Geist Mono for labels and code.
  Why (inferred): one family with tight headings reads crisp; a separate display face reads as decoration.
  <!-- 2026-11-23: "for serif use Crimson Pro, sans use inter or whatever the new cool kid" -->
- **A Crimson Pro page sets `font-size-adjust: ex-height 0.53` on `body`,** so the serif and Geist Mono share one x-height and the type scale below applies unchanged. Never compensate by bumping the serif's font sizes.
  Why: Crimson Pro's x-height is about 0.43em against roughly 0.53em for Geist, so at the same size it reads about 20% smaller than the sans and mono around it.
  <!-- 2026-11-25: "why does the crimson pro font looks so small compared to other fonts" / "font-size-adjust so we keep a single type size scale" -->
- **Every font size is in `rem`, never `px`, and running text is never below `1rem`.** Body `1rem/1.65` (16px by default). Prose in notes, cards and lists is also `1rem`. Tables `0.9375rem`, secondary lines under a table cell `0.875rem`. Only a genuinely dense page (a diagram-first page, a large data table) may drop the body to `0.9375rem`.
  Why: px ignores the reader's browser text-size setting, and sizes below 16px made a prose-heavy page "look really small and hard to read".
  <!-- 2026-11-23: "why they chose the body to be 15px. isn't the standard 16" / "the page text overall looks really small and hard to read" -->
- **Headings are weight 600 with negative tracking:** h1 `clamp(2.25rem, 5vw, 3rem)` / -0.035em, h2 `1.5rem` / -0.02em, h3 `1.0625rem` / -0.01em. The intro paragraph is `1.1875rem` in `--ink-2`.
- **Tracking and leading scale with size, never one value for all:** large text gets negative tracking and tight leading (h1 line-height 1.05), body stays near 0 tracking with loose leading, small uppercase labels get positive tracking. Build hierarchy from weight, size and leading together.
  Why: letters read too far apart as type grows and too cramped as it shrinks.
  <!-- 2026-11-23: "incorporate these too", from Apple's UI typography guidance -->
  <!-- Skipped from the same source: "default to the system font"; the font rule above wins. -->
- **Labels, kickers and table headers are mono `0.75rem`, uppercase, letter-spacing .1em, in `--ink-3`.** Nothing on the page is smaller than `0.75rem`.
- **When a row or line mixes mono and sans, or mixes sizes, align on the baseline:** `vertical-align: baseline` on table cells, `align-items: baseline` on flex rows. Never `top`, and never padding hacks to line cells up. An icon or dot in such a row sits at `vertical-align: 0.1em`.
  Why: mono and sans at different sizes have different line boxes, so top alignment leaves the first lines visibly off.
  <!-- 2026-11-23: "since u mix mono and sans in there, they're not aligned on the baseline right now" --> Table headers have no background fill, tables have no box around them, rows are separated only by `--hair` lines.
  Why (inferred): small mono labels carry structure without competing with content.
- **The meta line under the title is mono `0.8125rem` in `--ink-3`, with values in `<b>` at `--ink-2`.**

## Color

- **Neutrals:** background `#fafafa` (dark `#0a0b0d`), surface `#fff` (dark `#131519`), three ink levels `--ink` / `--ink-2` / `--ink-3`, and dividers as `--hair: rgba(ink, .08)`. Never a solid grey hex for a divider.
  Why (inferred): alpha hairlines sit right in both themes.
- **Accent colors map to real categories in the subject** (e.g. control plane, data plane, scanning), never generic ok/warn/bad fills.
- **No filled pill badges.** Show status with a dot, or a tiny outlined tag: mono 10px, uppercase, `border: 1px solid color-mix(in srgb, <accent> 40%, transparent)`, no background.
  Why (inferred): rows of colored pills are visual noise.

## Spacing & layout

- **Separate sections with whitespace, never horizontal rules:** `display: grid; gap: 72px` on the page wrapper (56px under 860px).
  Why (inferred): whitespace groups sections without adding lines.
- **A sticky header separates from scrolling content with a soft fade or blur mask at its edge, never a 1px border.**
  Why: a hard divider is another line; the fade only appears where content actually passes under it.
  <!-- 2026-11-23: "incorporate these too", from Apple's materials guidance -->

## Motion

Decide in this order, and stop early: the most common right answer is no animation.

- **Animate only with a named purpose:** feedback, spatial consistency (showing where something came from), a state change, bridging a jarring jump, or explaining how something works. "Looks cool" is never enough on anything seen often. Never animate keyboard-triggered actions. Data the reader is reading or acting on never moves for style.
  Why: an animation seen a hundred times a day makes the page feel slow every time after the first.
- **Cheapest tool that works:** CSS transition for hover, press and toggles; `@starting-style` for enter-on-mount; CSS keyframes for one-shot predetermined motion; WAAPI (`element.animate()`) for programmatic control. No animation library on a standalone page unless it needs springs or gestures.
- **Animate only `transform` and `opacity`** (`clip-path` is the one allowed extra; `height` only for accordions). Never `transition: all`; name the properties.
  Why: these skip layout and paint, so they stay smooth while the page is busy.
- **Never enter from `scale(0)`.** Start at `scale(0.95)` with `opacity: 0`. Popovers, menus and tooltips scale from their trigger (`transform-origin` at the trigger); modals stay centered.
  Why: nothing in the real world appears from nothing.
- **Use these curves, never the built-in keywords for deliberate motion, never `ease-in` on UI:**
  - `--ease-out: cubic-bezier(0.23, 1, 0.32, 1)` for entering and exiting (the default)
  - `--ease-in-out: cubic-bezier(0.77, 0, 0.175, 1)` for things moving or morphing on screen
  - `--ease-drawer: cubic-bezier(0.32, 0.72, 0, 1)` for drawers and sheets
  - plain `ease` for hover and color changes, `linear` for constant motion (progress, marquee)
  Why: `ease-in` delays the first frames, exactly when the user is watching, so it feels sluggish at any duration.
- **Durations:** press feedback 100-160ms, tooltips and small popovers 125-200ms, dropdowns 150-250ms, modals and drawers 200-500ms. Everything else in UI stays under 300ms. Exits are faster than entrances.
- **Anything that can be re-triggered uses transitions, not keyframes,** so it retargets from where it is. Things exit the way they entered (in from the right, out to the right).
- **Reduced motion and hover gating ship with the animation, not later.** Under `prefers-reduced-motion: reduce`, keep opacity changes, drop movement and delays (gentler, not zero). Hover motion lives inside `@media (hover: hover) and (pointer: fine)`.
  Why: motion can cause sickness, and touch devices fire false hovers on tap.
  <!-- 2026-11-23: "incorporate these too", from Emil Kowalski's design-engineering and animation guidance -->

## Choreography

When two or more things move on the same event:

- **One entrance per container.** If a panel slides in, its content is already there. Never animate the parent and stagger its children.
- **Stagger only one-off entrances**, never menus, tabs, list rows or anything opened often. Gaps of 30-80ms, uneven (shrinking or ordered by importance, never one fixed delay), total under ~300ms. A once-per-visit hero may use 100-150ms steps.
  Why: a uniform stagger reads like a metronome, and any stagger on frequent UI slows every use.
- **Give each mover a role.** The lead moves first and travels furthest, support moves less, decoration only fades, containers stay still. If two things both want to be the lead, fix the hierarchy, not the timing.
- **Nothing waits.** Everything is clickable as soon as it is visible. A removed element leaves the layout immediately so its siblings close the gap while it fades. A view swap in one container is a crossfade, not exit-then-enter. Exits happen all at once, shorter than entrances.
- **Collapse it under reduced motion:** no delays, no movement, the group appears together.
  <!-- 2026-11-23: "incorporate these too", from Emil Kowalski's choreography guidance -->

## Interaction

- **Every pressable element responds on press:** `transform: scale(0.97)` on `:active` with a 160ms `--ease-out` transition. Feedback starts on pointer-down, never only on release.
- **Tooltips delay the first appearance, then adjacent tooltips open instantly with no animation.**
- **Draggable things track the pointer 1:1:** use `setPointerCapture`, keep the offset from where it was grabbed, resist progressively past an edge instead of stopping hard, and let a fast flick count even below the distance threshold. Release with a spring that inherits the pointer's velocity: no bounce by default, bounce 0.1-0.3 only when a flick or throw preceded it.
- **Every animation can be interrupted** and reversed from its current on-screen position. Never lock out input during a transition.
  Why: feedback that lags or can't be grabbed mid-motion makes the page feel like a computer instead of an object.
  <!-- 2026-11-23: "incorporate these too", from Emil Kowalski's and Apple's interaction guidance -->

## Exploring a look

- **When asked to explore options, or the direction is genuinely undecided, build 3 variants (up to 5 if asked)** that differ on a stated axis: layout, density, personality, motion or interaction model. Name each for its direction ("Quiet", "Editorial", "Dense"), never "Option A". If two differ only in color or copy, they are one variant; replace one.
- **Every variant fully works** with realistic content, shown one at a time at full size in a single file behind an instant switcher (no animation on the swap).
- **Present a table** of variant, axis, when it's the right choice, and its cost. Don't pre-pick a favourite; the user chooses.
  Why: three tints of the same idea teach nothing when flipped between.
  <!-- 2026-11-23: "incorporate these too", from Emil Kowalski's prototyping guidance -->
