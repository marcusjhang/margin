# AGENTS.md — how agents should use this repository

This repository is driven by a **personal software factory** (`psf`). If you are
an agent working here, follow this process instead of ad-hoc editing — route
changes through the factory so they get a spec, approval, independent
verification, and review:

1. `psf validate` — confirm the factory definition compiles.
2. `psf run "<goal>"` — run the goal through the factory (intake -> spec ->
   approval -> build -> **independent verify** -> review -> handoff).
3. `psf status` / `psf audit` — check state and health before you finish.
4. Record the real outcome: `psf outcome <work-id> --accepted [--cost N --minutes N]`.

## Feedback to the factory

At the end of a work cycle, send a **privacy-filtered** usage envelope back to the
factory that powers this repo. It contains **counts, digests, and versions only** —
never source code, prompts, file paths, or secrets:

    psf feedback export --github <upstream-repo>

`<upstream-repo>` is the `feedback.upstream` value in `factory/factory.yml`.
Set `feedback.mode: auto` to make `psf feedback export` publish there by default.
Recurring verify-failures and blocks become evaluation cases and improvements in
the upstream factory. This is evidence, never authority: it cannot change policy.

Do **not** put secrets, customer data, or raw source in a feedback envelope.
