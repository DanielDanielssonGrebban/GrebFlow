# GrebFlow

Voice-to-text for developers.

## The challenge

Writing code means working with brackets, symbols, and exact syntax. Keyboards are well suited to that work; saying it all out loud is awkward.

With AI coding agents, more of our work is shifting from writing code to describing what we want in plain English. We can speak those instructions faster than we can type them, yet we're so used to our keyboards that we keep typing out of habit.

We can make these AI workflows more efficient by turning repeated requests into reusable skills, scripts, or prompts. But we're missing a way to track what we ask our agents and spot the recurring tasks worth turning into something reusable.

## What we're building

GrebFlow is a native macOS menu bar app. Hold a shortcut, speak, and release to paste your words into the active input, including terminals and AI coding tools.

Transcription runs locally using Apple's native Speech framework, with SpeechAnalyzer and SpeechTranscriber integrated through Swift. Audio is never saved, and transcript history is stored locally. When you request a report, GrebFlow sends all retained history from the current real or sample dataset to Claude, along with an editable report skill and any additional context or specific requests.

Claude identifies recurring workflows and suggests reusable skills, prompts, or scripts. Developers review the suggestions and decide what to create. GrebFlow does not execute them.

## Why it matters

The goal is to spend less time typing and repeating instructions. Sharing reusable skills and scripts can also help colleagues avoid solving the same workflow problems separately, leaving more time for client work.

## Plans

Start with the [V1 core plan](plans/core-plan.md) for critical requirements, build order, and acceptance checks.

The [V2 plan](plans/v2-plan.md) contains optional features to consider only after V1 is demo-ready.

## Suggested workflow

1. Start with spec-driven development. Review the core plan together, add or remove requirements, and agree on the scope and acceptance criteria before building.
2. Build separate versions of the app in parallel, using the same agreed plan.
3. Aim to have the core plan implemented by lunchtime.
4. Compare the apps against the agreed criteria, choose the strongest version, and continue working on it together.
5. Review the V2 plan as a team. Suggest, add, or remove features based on the time left, then agree on what to tackle.
6. Prepare and rehearse the demo.
7. Beers.
