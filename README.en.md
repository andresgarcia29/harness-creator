# harness-creator

**Universal installer for multi-repo agentic engineering harnesses**, packaged
as a Claude Code plugin. *(Full docs are currently in Spanish — [README.md](README.md).
This is a faithful condensed version; translations welcome, see CONTRIBUTING.)*

Point it at a folder with your repositories and it generates a complete
harness adapted to your stack: agents with real knowledge of your code,
deterministic gates protecting `main`, a ticket-to-production pipeline
**sized to blast radius** (a small task runs with 2 LLM sessions; a
multi-service migration gets the full pipeline), memory, secrets handling,
nightly self-healing, and living documentation. It works for any project
because it **discovers** your stack instead of assuming it. Claude Code
first — but it generates `AGENTS.md` (the cross-tool standard), so Cursor,
Kimi Code, Codex or any other agent can read and operate the same harness.

> **Philosophy (one line):** *agents propose, deterministic systems verify.*
> Every check a script can do, a script does; models only apply judgment
> where there is judgment. And laws aren't prose: they have a hook or a gate.
>
> **Speed corollary:** since safety lives in the gates, canary and rollback —
> not in the number of LLM phases — the pipeline cuts deliberation without
> cutting verification: lanes by blast radius, parallel gates, reviewer ∥ QA,
> deterministic prefetch, warm starts.

## Quickstart

```bash
# 1. Workspace: your repos cloned under repos/
mkdir my-workspace && cd my-workspace
mkdir repos && git clone <your-repos> repos/

# 2. Install the plugin (inside a Claude Code session)
/plugin marketplace add andresgarcia29/harness-creator
/plugin install harness-creator@harness

# 3. Install the harness (guided interview, ~10 min)
/harness-init .

# 4. One-pass onboarding (deps, credentials, secrets, health)
make init
```

Day-to-day is one line:

```
/auto COR-123                                   # a ticket
/auto "add per-tenant rate limiting, 100 req/min"   # or a literal prompt
/auto COR-123 --model deep                      # same task, your model choice
```

`/auto` runs the whole pipeline — intake, lane, [RFC], implement, review,
ship, deploy, archive — without asking you anything. State lives in
`tasks/<id>/` and worktree commits, never in a conversation: a dead session
resumes with `/auto <task-id>`.

## The core ideas

- **Lanes by blast radius**: deterministic signals classify each task as
  express (1 repo, 1 ownership domain, no contracts → skips the RFC entirely),
  standard (architect, no lawyer agents) or full. `gate_lane` in `ship.sh`
  verifies the real diff against the declared lane — misclassifying costs a
  re-entry, never an unsafe ship. Gates are identical in all three lanes.
- **`ship.sh` is the only door to `main`**: rebase → task trailer → lane in
  series; then in parallel: build/test + buf breaking ∥ gitleaks + semgrep ∥
  tests-not-weakened ∥ review verdict + evidence + policy. Red gates report
  together; every gate error includes its exact remediation (the error IS the
  fix prompt). Hooks are fail-closed; a direct push never happens.
- **Lawyers, not a mob**: one "tech lead" agent per ownership domain defends
  invariants in RFCs — and is only summoned when the task actually crosses
  domain boundaries.
- **Models are one knob**: `models.yaml` speaks aliases (`fast|smart|deep`)
  per provider (Anthropic, Vertex, Bedrock, Kimi, OpenRouter); change a role,
  an agent, or the whole provider with one line + `make models`.
- **The catalog rule (no empty advice)**: every tool a prompt cites must have
  its full chain — who installs it → who feeds it (e.g. the code graph is
  rebuilt incrementally by `graph-refresh.sh`) → who watches it (doctor, with
  remediation) → who actually runs it (gate, cronjob or agent).
- **Self-healing cronjobs**: a deterministic detector (0 tokens) finds
  problems; an agent only wakes if there's something to fix, and everything
  lands as a PR — never a direct push. Includes rule-miner (monthly: turns
  bugs into semgrep rules) and skill-miner (turns repeated procedures into
  skills).
- **Anti-cheating gates**: `gate_tests_untouched` blocks weakened tests
  (deleted assertions, added skips) unless the spec declares the behavior
  change; `gate_evidence` verifies the reviewer actually *opened* the tests
  it cites (set intersection with tracked reads — zero LLM).

## Local panel

`make ui` serves a localhost-only read panel (tasks, live agents, costs,
assumption ledger). Out of the box it runs on vendored Python stdlib +
precompiled frontend — no npm, no network. An optional Go daemon
([harness-daemon](https://github.com/andresgarcia29/harness-daemon), MIT) adds
multi-machine views via its companion
([harness-ui](https://github.com/andresgarcia29/harness-ui), MIT); the panel
falls back automatically when it's not available.

## Tests

```bash
./tests/run.sh        # full suite; every test builds and destroys its own
                      # temp workspace, nothing touches the network
```

The suite tests the **real template code** (functions extracted from
templates and executed), not mocks. CI runs it on Linux and on macOS with
`/bin/bash` (the stock 3.2) — portability is tested, not declared.

## License

MIT · Author: Andres Garcia
