# Cowork Launch UX Checklist

Last updated: March 8, 2026

This checklist turns the Work with Fae launch bar into concrete pass/fail criteria.
Use it together with [app-release-validation.md](/Users/davidirvine/Desktop/Devel/projects/fae/docs/checklists/app-release-validation.md), which is the canonical full-app release gate for main Fae, Cowork, audio, permissions, and scripted harness coverage.

## First impression

- [ ] A new user can tell within 3 seconds what the main Fae window is for.
- [ ] A new user can tell within 3 seconds what Work with Fae is for.
- [x] The startup path lands on one coherent main surface instead of an empty auxiliary canvas.
- [ ] Opening Work with Fae leaves the role of the main Fae window completely obvious.

## Visual hierarchy

- [x] Send is the only dominant action in the cowork composer.
- [x] Compare is secondary and reads as optional multi-model help.
- [x] The current model is visible without opening a menu.
- [x] Local vs remote is visible at a glance without backend-heavy wording.
- [x] The thinking control reads like a user-facing response choice, not a debug knob.
- [ ] The main orb feels calming and mysterious rather than blurry or decorative.

## Context clarity

- [x] Attached folders do not surface path soup in the main cowork chrome.
- [x] The details rail reads like an inspector instead of a second dashboard.
- [ ] Approval and export states feel calm, trustworthy, and precise in the live UI.
- [ ] Failure states are actionable instead of merely technical.

## Discoverability

- [x] A user can find compare, switch model, and add context without hunting.
- [ ] A user can find fork conversation without using a hidden context menu.
- [x] A user can see voice capture in cowork.
- [x] A user can see read-aloud in cowork.

## Windowing and layout

- [x] Cowork remains readable when resized narrower.
- [ ] The main Fae window and cowork window feel intentional together rather than accidental.
- [x] The app no longer opens a stray empty canvas on launch.

## Voice and text

- [x] Listening can remain active while the user types.
- [x] The main input bar explicitly supports typing while listening.
- [x] The main-window onboarding CTA uses real audio capture instead of injected fake speech.
- [ ] A live speech-to-Fae pass has been verified end to end on the shipping bundle.
- [ ] Cowork read-aloud has been verified end to end on the shipping bundle.

## Response quality

- [ ] A trivial typed prompt in the main window returns a timely, relevant answer.
- [x] A benign remote cowork prompt returns a response on the configured provider.
- [ ] Main-window voice and text turns remain reliable while cowork is open.

## Accessibility

- [x] Send, compare, model selection, and workspace rows expose accessibility labels/hints.
- [x] Cowork composer supports Return to send and Shift-Return for newline.
- [ ] VoiceOver has been validated live across the main window and cowork window.
- [ ] Small targets and truncation have been reviewed for low-vision comfort.

## Current blockers

- Main-window typed turns can still stall in a persistent `Thinking...` state during live testing.
- A full live VoiceOver pass has not been completed yet.
- End-to-end live validation of cowork read-aloud on the packaged app remains incomplete.
- The relationship between the main Fae window and cowork is improved, but app reactivation still needs one more clarity pass for launch polish.
- The cowork utility surfaces still need a full live pass for model switching, skills, scheduler, and inspector interactions.
