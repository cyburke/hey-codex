# Security

Hey Codex holds two sensitive permissions: Microphone and Accessibility. Accessibility lets it post a global keyboard event. That is a real attack surface, even for a small app.

## Scope

In scope: anything that could let audio, transcripts, or keywords leave the Mac without consent; anything that could let the app post keystrokes or events beyond the one configured Voice hotkey; anything that could escalate the Accessibility grant into something broader.

Out of scope: the underlying macOS permission model, Gatekeeper and notarization behavior, and vulnerabilities in ChatGPT desktop itself.

## Reporting

Please use [GitHub's private security advisories](https://github.com/cyburke/hey-codex/security/advisories/new) for this repo instead of a public issue. That keeps the report private until there is a fix.

## Response time

This is a single-maintainer project. Expect an initial response within a few days, not hours. There is no SLA.

## Disclosure

Once a fix is out, the advisory is published and credited unless you ask otherwise.
