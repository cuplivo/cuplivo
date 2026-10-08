# ADR-0004: Follow upstream — re-base each release instead of diverging

**Status:** Accepted (2026-09)
**Deciders:** cuplivo

## Context

Cuplivo 3.x forked from Kelivo v1.1.17 and developed on top of that fork point. As the fork grew,
every upstream change had to be synced by hand and re-checked for compatibility, and the line closed
with v3.2.1 (2026-09-12), whose notes said contributors would go back to upstream instead.

Cuplivo 4.0 re-baselined the whole code base on Kelivo v1.3.0 (ADR-0001) and re-implemented the
Cuplivo features that earn their place on that baseline. That only pays off if it keeps happening: a
re-baseline that is then left to drift reproduces exactly the condition that ended 3.x.

## Decisions

| Item | Decision |
| --- | --- |
| Baseline | The latest Kelivo **stable** release, not a frozen fork point |
| Normal update | Re-base the code base on the new baseline and re-do Cuplivo's own features on it |
| Upstream architectural change | Cherry-pick Cuplivo's features onto the new baseline instead of porting the fork forward |
| Divergence | Never permanent: no long-lived fork-only architecture |
| v3.x features | Re-implemented only when they still earn their place on the new baseline; otherwise they stay removed and are listed in `CHANGELOG*.md` |
| Coexistence | The application id still differs from every other lineage, so a 4.x install never overwrites another app, and data is never migrated automatically |
| GitHub-facing identity | Release artifacts, installer identity and packaging metadata are Cuplivo's; names that are protocol, persisted data or upstream infrastructure stay unchanged (`CONTEXT.md` § Branding & Naming Boundary) |

## Consequences

- Upstream's work keeps arriving without a porting project. The cost is that Cuplivo cannot carry
  fork-only architecture — the features listed under *Removed* in `CHANGELOG*.md` are the first
  payment, and returning one to the product means re-implementing it on the current baseline.
- This supersedes the archived line's terminal-release stance ("v3.2.1 is the last major update").
- The replay itself is recorded in [`docs/rebase-runbook.md`](../rebase-runbook.md): the commit
  units to cherry-pick, in order, and the rules that keep the re-base a replay rather than a port.
- ADR-0001's *Not in scope* item "rebranding the GitHub issue templates / FUNDING" is superseded for
  the issue templates, the repository description and the release identity; `FUNDING.yml` still
  points at upstream's sponsor image on purpose.
