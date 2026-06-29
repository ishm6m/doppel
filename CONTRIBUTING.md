# CONTRIBUTING.md — Contributing to Doppel

> **Purpose:** Onboard human contributors to an OSS project that has strict privacy/safety invariants.
> **Scope:** Workflow, the non-negotiables, code style, PR expectations.
> **Dependencies:** `CLAUDE.md`, `TESTING.md`, `SECURITY.md`.

---

## The three invariants no PR may violate
1. **Offline:** never add code or a dependency that transmits file content, names, paths, hashes, or embeddings. (Egress test will fail you.)
2. **Reversible:** never permanently delete user files. Trash-only, with undo.
3. **Explainable:** every duplicate group carries a non-empty explanation + confidence.

If your change touches deletion, networking, or dependencies, expect extra review.

## Workflow
1. Pick an issue / a task from `TASKS.md`.
2. Branch: `feat/<short>`, `fix/<short>`, etc.
3. Write tests alongside code (engine = TDD).
4. Run `swiftformat . && swiftlint --strict` and the test suite locally.
5. Open a PR using Conventional Commits in the title (`feat:`, `fix:`, `perf:`…). One logical change per PR.

## Code style
- Swift 6, strict concurrency. `Sendable` across module boundaries. Swift Concurrency only.
- No force-unwraps in non-test code except documented `// SAFETY:` invariants.
- Engine package imports no UI. UI never touches SQL directly (go through `IndexStore`).
- Public APIs documented; new domain terms added to `GLOSSARY.md`.

## PR checklist
- [ ] Tests added/updated and green (incl. safety/egress where relevant).
- [ ] Lint + format clean.
- [ ] No new phone-home dependency (or explicitly justified + reviewed).
- [ ] Docs updated (the relevant `*.md`), Open Questions noted if ambiguity found.
- [ ] Accessibility considered for UI changes.

## Reporting security/privacy issues
Privacy is the product. Report suspected egress or data-loss issues privately (see SECURITY contact in repo) rather than in public issues.

## Related Documents
- `CLAUDE.md`, `TESTING.md`, `SECURITY.md`, `TASKS.md`.
