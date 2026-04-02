# CodexMate README Redesign

Date: 2026-04-03
Status: Approved design draft

## Context

The current `README.md` explains the project accurately, but it is optimized for developers packaging and releasing the app instead of ordinary Codex Desktop users deciding whether CodexMate is worth installing.

CodexMate is already a usable macOS menu bar companion for Codex Desktop. The README should therefore sell the product value first, then help users install it, and only then point builders and maintainers to separate technical documentation.

## Primary Audience

- Primary reader: ordinary macOS users who already use Codex Desktop
- Reader intent: understand why CodexMate exists, decide whether it helps their workflow, then install it
- Reader baseline: comfortable downloading a release from GitHub, but not interested in build, packaging, notarization, or release internals

## Problem Statement

As AI systems improve, the limiting factor shifts from model capability to human attention. CodexMate exists to reduce that human bottleneck so users can keep multiple projects moving without repeatedly checking windows, waiting for state changes, and burning attention on context switching.

This philosophy should be the main framing of the README, not a side note.

## Goals

- Reposition the main `README.md` as a user-facing product document
- Lead with a strong manifesto-style explanation of why CodexMate exists
- Translate that philosophy into concrete user benefits quickly
- Show the product visually before asking the reader to install it
- Place the main download CTA after the reader understands the product
- Keep the README readable on GitHub without turning it into a long essay
- Move technical build, packaging, and release instructions out of the main README

## Non-Goals

- Writing a fully bilingual README with complete Korean duplication
- Keeping all current developer operations content in the main README
- Turning the README into a release engineering manual
- Changing product scope or app behavior as part of the README rewrite

## Messaging Strategy

### Positioning

CodexMate is a macOS menu bar companion for Codex Desktop that reduces the attention overhead of managing active Codex work.

### Main Message

Use the following hero copy as the core README message:

> Codex keeps getting better, but human attention is still the bottleneck. CodexMate was built to reduce that bottleneck, so you can keep multiple projects moving without constantly checking, waiting, and context-switching.

### Tone

- Manifesto-first, but still product-oriented
- Clear and direct rather than hype-heavy
- Written as product explanation, not as a personal founder essay
- Philosophical in the opening, practical immediately after

### Language Policy

- Main README body language: English
- Korean support: add at most one short Korean supporting note directly under the hero section if needed for nuance, but do not duplicate full sections in Korean
- Core install, feature, and FAQ content stays in English for first-pass GitHub readability

## README Information Architecture

### 1. Hero / Manifesto

Purpose:
Introduce the core belief that human attention is now the bottleneck and position CodexMate as a response to that problem.

Requirements:

- Use the approved hero copy verbatim
- Do not place the main download CTA here
- Keep this section tight: headline, short supporting paragraph, and optionally one brief Korean supporting line directly below that paragraph

Expected outcome:
The reader should understand why the app exists before learning the feature list.

### 2. What CodexMate Does

Purpose:
Translate the manifesto into practical value for a Codex Desktop user.

Required content:

- CodexMate is a macOS menu bar companion for Codex Desktop
- It helps users monitor recent threads and task state changes with less manual checking
- It surfaces approval, completion, and failure signals so attention is spent only when needed
- It supports users handling multiple projects in parallel

Expected outcome:
The reader should be able to answer, "What does this app actually do for me?"

### 3. Screenshots or Usage Flow

Purpose:
Show the product experience before asking the user to install it.

Preferred structure:

- Screenshot 1: menu bar plus recent thread dropdown
- Screenshot 2: notification state or settings view
- Short 3-step usage flow below or beside the images

Suggested usage flow copy:

1. Watch recent Codex threads from the menu bar.
2. Catch approvals, completions, and failures without babysitting every window.
3. Jump back into the right thread when attention is actually needed.

Requirements:

- This section must appear before the main download CTA
- It should connect the manifesto to actual product behavior
- Captions should describe real user outcomes, not UI trivia

### 4. Download / Get Started

Purpose:
Convert informed readers into installers after they understand the product.

Required content:

- Link to the latest GitHub release
- Minimum platform requirement: macOS 13+
- Codex Desktop dependency stated plainly
- Very short setup/start guidance

Requirements:

- The CTA belongs after product framing and screenshots, not at the top
- Keep this section short and high-confidence
- Avoid release-engineering detail here

### 5. Key Features

Purpose:
Give a skimmable summary of the app's main user-facing capabilities.

Expected feature set:

- Recent threads in the menu bar
- Visibility into running, waiting, or completed states
- Approval, completion, and failure notifications
- Fast return path into the right Codex Desktop thread
- Lightweight settings for language, notifications, updates, and app behavior

Requirements:

- Write features as user benefits, not implementation details
- Keep the list concise, ideally 4 to 6 bullets

### 6. FAQ / Notes

Purpose:
Answer practical pre-install questions without sending the user into developer documentation.

Recommended topics:

- Who this is for
- Required macOS version
- Works with Codex Desktop
- Some state indicators may use fallback heuristics for threads the app did not resume itself
- Some behaviors differ between packaged app and `swift run`

Requirements:

- Be honest about limits without making the product sound fragile
- Keep troubleshooting brief in the main README

### 7. Developer Docs

Purpose:
Keep the main README user-friendly while preserving technical documentation elsewhere.

Current content to move out of `README.md`:

- `Run`
- `UTM Troubleshooting`
- `Package App`
- `Release App`

Recommended destination structure:

- `docs/build-from-source.md`
- `docs/packaging-and-release.md`

These two documents should become the canonical homes for build, packaging, notarization, and release instructions.

Main README behavior:

- Include a short `For developers` section near the end
- Link out instead of embedding long shell command blocks

## Content Rules

- Start with why the app exists, not with shell commands
- Keep the opening visible without scrolling into engineering detail
- Do not front-load environment variables, packaging scripts, or notarization steps
- Prefer short paragraphs and tight bullet lists
- Avoid over-claiming reliability or automation scope
- Use screenshots and usage flow to reduce abstractness

## Implementation Notes

- The README rewrite will require new screenshot assets or stable image paths
- The release/download link should point to the current GitHub Releases page rather than a hard-coded older version
- Existing technical sections should be preserved during the rewrite, but relocated to dedicated docs
- The final README should remain maintainable as the product evolves

## Success Criteria

- A Codex Desktop user can understand the product value from the first screenful
- The README clearly communicates the "human attention is the bottleneck" philosophy
- The reader sees what the app looks like before the install CTA
- The main install path is easy to find after the product explanation
- Developer-focused operational detail no longer dominates the main README
- The README still links maintainers to build and release documentation
