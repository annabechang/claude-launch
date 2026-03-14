#!/usr/bin/env python3
"""Unified Execution Engine — shared brain for Launcher + Conductor + Regular Sessions.

Provides:
  - Task classification (complexity → execution strategy)
  - Model routing (phase + budget → claude/codex)
  - Pipeline phase management (transitions, conditions)
  - Refinement decisions (when to critique, when to stop)
  - Prompt generation (high-quality, phase-aware)

CLI usage (for bash callers like the launcher):
  python3 execution_engine.py classify "task description"
  python3 execution_engine.py route <task_type> <phase> [--budget-pct N]
  python3 execution_engine.py next-phase <current_phase> <verdict>
  python3 execution_engine.py should-refine <task_type> <round> [--max N]
  python3 execution_engine.py prompt <phase> <iteration> --task "desc" [--contract "..."] [--remaining-min N]
  python3 execution_engine.py cooldown-plan <iteration> --task-type <type> [--codex-wait] [--pr-review]

Python usage (for conductor):
  from execution_engine import ExecutionEngine
  engine = ExecutionEngine()
  strategy = engine.classify("Add JWT auth to all API endpoints")
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from enum import Enum
from typing import Optional


# ─── Enums ────────────────────────────────────────────────────────

class Strategy(Enum):
    """Execution strategy for a task."""
    DIRECT = "direct"              # Single-pass, no pipeline
    LIGHTWEIGHT = "lightweight"    # Think-then-code, Codex review at end
    PIPELINE = "pipeline"          # Full research→implement→review (cyclic)
    BUG_HUNT = "bug_hunt"          # Iterative find→fix→verify
    AUTORESEARCH = "autoresearch"  # Autonomous experiment loop (modify→run→eval→keep/discard)


class Phase(Enum):
    """Pipeline phases (superset of both launcher and conductor phases)."""
    RESEARCH = "research"
    TEST_BRAINSTORM = "test_brainstorm"
    IMPLEMENT = "implement"
    BUG_HUNT = "bug_hunt"
    BUGFIX = "bugfix"
    REVIEW = "review"
    REFINE = "refine"  # Cross-model refinement sub-phase
    EXPERIMENT = "experiment"  # Autoresearch experiment loop


class Model(Enum):
    CLAUDE = "claude"
    CODEX = "codex"
    AUTO = "auto"


class BudgetPhase(Enum):
    SPRINT = "sprint"        # 0-30%
    CRUISE = "cruise"        # 30-60%
    CONSERVE = "conserve"    # 60-80%
    CHECKPOINT = "checkpoint" # 80%+


# ─── Data Classes ─────────────────────────────────────────────────

@dataclass
class ClassificationResult:
    strategy: Strategy
    confidence: float  # 0.0-1.0
    phases: list[str]
    reason: str
    signals: dict = field(default_factory=dict)

    def to_dict(self):
        d = asdict(self)
        d["strategy"] = self.strategy.value
        return d


@dataclass
class RouteResult:
    model: Model
    reason: str
    fallback: Optional[Model] = None

    def to_dict(self):
        d = {"model": self.model.value, "reason": self.reason}
        if self.fallback:
            d["fallback"] = self.fallback.value
        return d


@dataclass
class CooldownPlan:
    """What to do during a rate-limit cooldown."""
    steps: list[dict]  # [{"action": "codex_review", "priority": 1, "condition": "..."}]

    def to_dict(self):
        return {"steps": self.steps}


# ─── Engine ───────────────────────────────────────────────────────

class ExecutionEngine:
    """Unified execution intelligence for all task runners."""

    # ── Classification ────────────────────────────────────────

    # Patterns that suggest autoresearch (metric optimization loop)
    AUTORESEARCH_SIGNALS = [
        r"autoresearch", r"experiment\s+loop", r"autonomous\s+experiment",
        r"modify.run.eval", r"keep.discard", r"optimize.*metric",
        r"lowest\s+val_bpb", r"train\.py.*prepare\.py",
        r"program\.md", r"hill.climb", r"hyperparameter\s+search",
        r"/autoresearch\b",
    ]

    # Patterns that suggest high complexity
    COMPLEXITY_SIGNALS = {
        "architectural": [
            r"refactor", r"redesign", r"migrate", r"rewrite",
            r"new service", r"new module", r"new system",
            r"integrate.*with", r"replace.*with",
            r"database.*layer", r"entire", r"overhaul",
        ],
        "multi_file": [
            r"across.*files", r"multiple.*files", r"all.*endpoints",
            r"every.*component", r"throughout.*codebase",
            r"full.stack", r"end.to.end",
        ],
        "multi_step": [
            r"and then", r"after that", r"followed by",
            r"step \d", r"phase \d", r"first.*then",
            r"pipeline", r"workflow",
            r",\s*and\s+", r"update.*all", r"rewrite",
        ],
        "research_needed": [
            r"understand.*how", r"figure out", r"investigate",
            r"explore.*approach", r"compare.*options",
            r"best.practice", r"architecture.*decision",
        ],
        "bug_hunt": [
            r"find.*bugs", r"bug.hunt", r"audit.*for.*issues",
            r"security.*audit", r"code.*review",
            r"identify.*problems", r"stress.test",
        ],
    }

    # Patterns that suggest simplicity
    SIMPLICITY_SIGNALS = [
        r"^fix\s", r"^rename", r"^update.*version",
        r"^add.*comment", r"^remove.*unused", r"^format",
        r"single.file", r"one.liner", r"quick.*fix",
        r"typo", r"docstring", r"readme",
    ]

    def classify(self, description: str) -> ClassificationResult:
        """Classify a task description into an execution strategy."""
        desc_lower = description.lower()
        signals = {}

        # Check simplicity first
        simplicity_score = 0
        for pattern in self.SIMPLICITY_SIGNALS:
            if re.search(pattern, desc_lower):
                simplicity_score += 1
                signals.setdefault("simple", []).append(pattern)

        if simplicity_score >= 2:
            return ClassificationResult(
                strategy=Strategy.DIRECT,
                confidence=0.9,
                phases=["execute"],
                reason=f"Simple task ({simplicity_score} simplicity signals)",
                signals=signals,
            )

        # Check for autoresearch pattern (before complexity — it's a distinct strategy)
        autoresearch_score = 0
        for pattern in self.AUTORESEARCH_SIGNALS:
            if re.search(pattern, desc_lower):
                autoresearch_score += 1
                signals.setdefault("autoresearch", []).append(pattern)
        if autoresearch_score >= 1:
            return ClassificationResult(
                strategy=Strategy.AUTORESEARCH,
                confidence=min(0.7 + autoresearch_score * 0.1, 0.95),
                phases=["setup", "experiment"],
                reason=f"Autoresearch pattern ({autoresearch_score} signals: {signals.get('autoresearch', [])})",
                signals=signals,
            )

        # Check complexity signals
        complexity_score = 0
        for category, patterns in self.COMPLEXITY_SIGNALS.items():
            category_matches = []
            for pattern in patterns:
                if re.search(pattern, desc_lower):
                    category_matches.append(pattern)
            if category_matches:
                complexity_score += 1
                signals[category] = category_matches
                # Bonus: multiple matches in one category = extra complexity
                if len(category_matches) >= 3:
                    complexity_score += 1

        # Length/clause heuristic: long descriptions with many commas = complex
        comma_count = desc_lower.count(",")
        word_count = len(desc_lower.split())
        if comma_count >= 3 and word_count >= 20:
            complexity_score += 1
            signals["length"] = [f"{word_count} words, {comma_count} commas"]

        # Check for bug hunt specifically
        if "bug_hunt" in signals:
            return ClassificationResult(
                strategy=Strategy.BUG_HUNT,
                confidence=0.8,
                phases=["bug_hunt", "bugfix", "verify"],
                reason="Bug hunt/audit pattern detected",
                signals=signals,
            )

        # Decision tree
        if complexity_score >= 3:
            return ClassificationResult(
                strategy=Strategy.PIPELINE,
                confidence=min(0.6 + complexity_score * 0.1, 0.95),
                phases=["research", "implement", "review"],
                reason=f"High complexity ({complexity_score} signals across {list(signals.keys())})",
                signals=signals,
            )
        elif complexity_score >= 2 or "research_needed" in signals:
            return ClassificationResult(
                strategy=Strategy.LIGHTWEIGHT,
                confidence=0.7,
                phases=["plan", "implement", "review"],
                reason=f"Moderate complexity ({complexity_score} signals)",
                signals=signals,
            )
        else:
            return ClassificationResult(
                strategy=Strategy.DIRECT,
                confidence=0.6 if complexity_score == 1 else 0.8,
                phases=["execute"],
                reason=f"Standard task ({complexity_score} complexity signals)",
                signals=signals,
            )

    # ── Model Routing ─────────────────────────────────────────

    # Default routing by phase
    PHASE_ROUTING = {
        Phase.RESEARCH: Model.CLAUDE,
        Phase.TEST_BRAINSTORM: Model.CLAUDE,
        Phase.IMPLEMENT: Model.CODEX,
        Phase.BUG_HUNT: Model.CLAUDE,
        Phase.BUGFIX: Model.CODEX,
        Phase.REVIEW: Model.CLAUDE,  # Review uses opposite of implementer
        Phase.REFINE: Model.AUTO,    # Opposite of whoever produced
    }

    def route(self, task_type: str, phase: str,
              budget_pct: float = 0, producer: str = "") -> RouteResult:
        """Pick the right model for a task phase."""
        budget_phase = self._budget_phase(budget_pct)

        try:
            phase_enum = Phase(phase)
        except ValueError:
            phase_enum = Phase.IMPLEMENT  # fallback

        # Default routing
        default = self.PHASE_ROUTING.get(phase_enum, Model.CLAUDE)

        # Refinement uses opposite of producer
        if phase_enum == Phase.REFINE or phase_enum == Phase.REVIEW:
            if producer == "codex":
                default = Model.CLAUDE
            elif producer == "claude":
                default = Model.CODEX

        # Budget override: if chosen model in CHECKPOINT, swap
        if budget_phase == BudgetPhase.CHECKPOINT:
            fallback = Model.CODEX if default == Model.CLAUDE else Model.CLAUDE
            return RouteResult(
                model=fallback,
                reason=f"{default.value} in CHECKPOINT (budget {budget_pct:.0f}%), falling back to {fallback.value}",
                fallback=default,
            )

        return RouteResult(
            model=default,
            reason=f"Phase {phase} routes to {default.value} (budget: {budget_phase.value})",
        )

    def _budget_phase(self, pct: float) -> BudgetPhase:
        if pct >= 80:
            return BudgetPhase.CHECKPOINT
        elif pct >= 60:
            return BudgetPhase.CONSERVE
        elif pct >= 30:
            return BudgetPhase.CRUISE
        return BudgetPhase.SPRINT

    # ── Phase Transitions ─────────────────────────────────────

    # Strategy → phase sequence (pipeline and bug_hunt are cyclic, not linear)
    PHASE_SEQUENCES = {
        Strategy.DIRECT: ["execute"],
        Strategy.LIGHTWEIGHT: ["plan", "implement", "review"],
        Strategy.PIPELINE: ["research", "test_brainstorm", "implement", "bug_hunt", "review"],
        Strategy.BUG_HUNT: ["bug_hunt", "bugfix", "bug_hunt", "review"],  # iterative
        Strategy.AUTORESEARCH: ["setup", "experiment"],  # experiment loops indefinitely
    }

    def next_phase(self, current_phase: str, verdict: str = "success",
                   strategy: str = "pipeline") -> dict:
        """Determine the next phase given current phase and result.

        Pipeline and bug_hunt are CYCLIC: review can loop back to implement
        or research based on verdict. Autoresearch loops experiment indefinitely.
        """
        try:
            strat = Strategy(strategy)
        except ValueError:
            strat = Strategy.PIPELINE

        sequence = self.PHASE_SEQUENCES.get(strat, ["execute"])

        # Autoresearch: experiment phase loops forever
        if strat == Strategy.AUTORESEARCH:
            if current_phase == "setup":
                return {"phase": "experiment", "reason": "Setup complete, starting experiment loop"}
            # experiment phase never advances — it loops until interrupted
            return {"phase": "experiment", "reason": "Continuing experiment loop (never stops)"}

        # Special handling for bug hunt iteration
        if current_phase == "bug_hunt" and verdict.lower() in ("bugs_found", "substantive_issues"):
            return {"phase": "bugfix", "reason": "Bugs found, creating fix task"}

        if current_phase == "bugfix":
            return {"phase": "bug_hunt", "reason": "Fix applied, re-hunting"}

        # Cyclic pipeline: review can loop back instead of terminating
        if current_phase == "review":
            verdict_lower = verdict.lower()
            if verdict_lower in ("approve", "clean", "minor_issues"):
                return {"phase": "done", "reason": f"Review verdict: {verdict}"}
            elif verdict_lower in ("design_flaw", "wrong_approach", "needs_research"):
                # Loop back to research — the approach was wrong
                return {"phase": "research", "reason": f"Review found design flaw, looping back to research: {verdict}"}
            else:
                # Loop back to implement — the approach is right but needs changes
                return {"phase": "implement", "reason": f"Review requests changes, looping back to implement: {verdict}"}

        # Linear progression through the sequence
        try:
            idx = sequence.index(current_phase)
            if idx + 1 < len(sequence):
                return {"phase": sequence[idx + 1], "reason": "Advancing to next phase"}
        except ValueError:
            pass

        return {"phase": "done", "reason": "No more phases"}

    # ── Refinement ────────────────────────────────────────────

    REFINABLE_TYPES = {"implement", "complex", "research", "bugfix"}

    def should_refine(self, task_type: str, current_round: int,
                      max_rounds: int = 3) -> dict:
        """Should this task go through another refinement round?"""
        if task_type.lower() not in self.REFINABLE_TYPES:
            return {"refine": False, "reason": f"Task type '{task_type}' not refinable"}
        if current_round >= max_rounds:
            return {"refine": False, "reason": f"Max rounds ({max_rounds}) exhausted"}
        return {"refine": True, "reason": f"Round {current_round + 1}/{max_rounds}"}

    # ── Cooldown Planning ─────────────────────────────────────

    def cooldown_plan(self, iteration: int, task_type: str = "code",
                      codex_wait: bool = False, pr_review: bool = False,
                      desloppify: bool = False, model_used: str = "opus",
                      has_contract: bool = True) -> CooldownPlan:
        """Plan what to do during a rate-limit cooldown between iterations.

        Merges the best of launcher's cooldown utilization with conductor's
        refinement capabilities.
        """
        steps = []
        priority = 0

        # 1. ALWAYS: Alignment check (if contract exists)
        if has_contract:
            priority += 1
            steps.append({
                "action": "alignment_check",
                "priority": priority,
                "description": "Check goal drift against task contract",
                "tool": "codex",
                "timeout_pct": 0.15,  # 15% of cooldown time
            })

        # 2. ALWAYS: Test suite gate
        priority += 1
        steps.append({
            "action": "test_suite",
            "priority": priority,
            "description": "Run tests, measure coverage delta",
            "tool": "native",
            "timeout_pct": 0.20,
        })

        # 3. Security scan (always)
        priority += 1
        steps.append({
            "action": "security_scan",
            "priority": priority,
            "description": "Scan for hardcoded secrets and vulnerable deps",
            "tool": "native",
            "timeout_pct": 0.10,
        })

        # 4. Cross-model review (Sonnet iterations always, or --codex-wait)
        if model_used == "sonnet" or codex_wait:
            priority += 1
            steps.append({
                "action": "codex_review",
                "priority": priority,
                "description": "Codex code review of uncommitted changes",
                "tool": "codex",
                "timeout_pct": 0.25,
            })

        # 5. Opus quality review (only when Sonnet was used)
        if model_used == "sonnet":
            priority += 1
            steps.append({
                "action": "opus_review",
                "priority": priority,
                "description": "Opus reviews Sonnet's code quality",
                "tool": "claude",
                "timeout_pct": 0.15,
            })

        # 6. PR-based review (if --pr-review)
        if pr_review:
            priority += 1
            steps.append({
                "action": "pr_review",
                "priority": priority,
                "description": "Create/update PR and get Codex GitHub review",
                "tool": "codex",
                "timeout_pct": 0.30,
            })

        # 7. Refinement loop (NEW — bringing conductor's refinement into cooldowns)
        # For complex/implement tasks after iteration 2+, run a critique cycle
        if iteration >= 2 and task_type.lower() in ("complex", "implement", "code"):
            priority += 1
            steps.append({
                "action": "refinement_critique",
                "priority": priority,
                "description": "Cross-model critique: review changes, produce structured feedback",
                "tool": "codex" if model_used == "claude" else "claude",
                "timeout_pct": 0.20,
                "output": "notes/refinement-critique.json",
            })

        # 8. Desloppify (if --desloppify)
        if desloppify:
            priority += 1
            steps.append({
                "action": "desloppify",
                "priority": priority,
                "description": "Code quality scan and issue sync",
                "tool": "native",
                "timeout_pct": 0.15,
            })

        return CooldownPlan(steps=steps)

    # ── Prompt Building ───────────────────────────────────────

    def build_phase_prompt(self, phase: str, iteration: int,
                           task: str, contract: str = "",
                           remaining_min: int = 60,
                           research_notes: str = "",
                           implementation_plan: str = "") -> str:
        """Generate a high-quality prompt for a specific pipeline phase.

        Combines launcher's prompt quality with conductor's phase structure.
        """
        if phase == "research":
            return self._research_prompt(task, contract, remaining_min)
        elif phase == "test_brainstorm":
            return self._test_brainstorm_prompt(task, contract, research_notes)
        elif phase == "implement":
            return self._implement_prompt(task, contract, remaining_min,
                                          research_notes, implementation_plan)
        elif phase == "bug_hunt":
            return self._bug_hunt_prompt(task, contract, iteration)
        elif phase == "review":
            return self._review_prompt(task, contract)
        elif phase == "refine":
            return self._refine_prompt(task, iteration)
        else:
            return self._direct_prompt(task, contract, remaining_min)

    def _research_prompt(self, task: str, contract: str, remaining_min: int) -> str:
        return f"""## Research Phase (Phase 1 — Research Only, No Code)

### Task
{task}

{f"### Contract{chr(10)}{contract}" if contract else ""}

### Time Budget
~{remaining_min // 3} minutes for research (1/3 of session).

### Your Job
1. Explore the codebase to understand current architecture
   - Use subagents for parallel exploration of different modules
   - Map file dependencies, key abstractions, data flow
2. Research external dependencies, patterns, or libraries needed
3. Identify edge cases, potential conflicts, and risks

### Deliverables (commit and push these)
- `notes/research-notes.md`:
  - Architecture overview (key files, classes, data flow)
  - Relevant existing patterns to follow
  - External dependencies needed
  - Risks and mitigation strategies

- `notes/implementation-plan.md`:
  - Step-by-step plan with:
    - Files to modify/create (with rationale)
    - Key functions/classes to implement
    - Edge cases to handle
    - Test strategy (unit + integration + E2E)
    - Estimated complexity per step (S/M/L)
  - Priority order (highest impact + most feasible first)
  - Explicit dependencies between steps

### Rules
- Do NOT implement anything — research and plan only
- Be thorough — the implementation phase will rely on your plan
- If something is ambiguous, document both options with tradeoffs
- Commit and push notes when done"""

    def _test_brainstorm_prompt(self, task: str, contract: str,
                                 research_notes: str) -> str:
        return f"""## Test Brainstorm Phase (Phase 2 — Test Strategy Only)

### Task
{task}

### Context
Research has been completed. Read:
- `notes/research-notes.md` — architecture findings
- `notes/implementation-plan.md` — step-by-step plan

### Your Job
Design the test strategy BEFORE implementation begins.

1. For each implementation step, define:
   - Unit tests (function-level, isolated)
   - Integration tests (module interactions)
   - E2E tests (user-visible behavior)
2. Identify test boundaries and mock requirements
3. Define acceptance criteria per test

### Deliverable
Write `notes/test-manifest.json`:
```json
{{
  "test_cases": [
    {{
      "id": "TC-001",
      "step": "implementation step reference",
      "type": "unit|integration|e2e",
      "description": "what this tests",
      "file": "tests/test_X.py",
      "acceptance": "expected outcome",
      "mock_required": false,
      "priority": "P0|P1|P2"
    }}
  ],
  "coverage_target": "85%",
  "e2e_count": 3
}}
```

### Rules
- Every new function/class must have at least one test case
- At least 1 real E2E test (not mocked)
- Not ALL tests can be mocked — real integration tests required
- Commit and push when done"""

    def _implement_prompt(self, task: str, contract: str, remaining_min: int,
                           research_notes: str, implementation_plan: str) -> str:
        return f"""## Implementation Phase (Phase 3 — Follow the Plan)

### Task
{task}

{f"### Contract{chr(10)}{contract}" if contract else ""}

### Context
Research and test planning are complete. Read these FIRST:
- `notes/research-notes.md` — architecture findings
- `notes/implementation-plan.md` — your step-by-step plan
- `notes/test-manifest.json` — test cases to implement alongside code

### Time Budget
~{remaining_min} minutes for implementation.

### Your Job
1. Read the research notes and implementation plan thoroughly
2. Follow the plan step by step (deviate only for clear errors)
3. For EACH step:
   - Implement the code change
   - Write tests from the test manifest
   - Run tests to verify
   - Fix any failures
   - Commit and push

### Debugging Protocol (when tests fail)
a. TRIAGE: Read the full error. Run linter. Check git diff.
b. REPRODUCE: Re-run the failing command.
c. ISOLATE: Binary search to narrow the cause.
d. INVESTIGATE: Read full logs. Add targeted debug logging if unclear.
e. RESEARCH: Web search exact error message if still stuck.
f. FIX from evidence, not guessing. Remove debug logging. Full test suite.

### Rules
- Follow the implementation plan — don't freelance
- Write tests alongside code (not after)
- Never commit code that breaks existing tests
- If an item takes 2x longer than expected, skip and note in plan
- Commit and push each logical unit of work"""

    def _bug_hunt_prompt(self, task: str, contract: str, round_num: int) -> str:
        return f"""## Bug Hunt Phase (Round {round_num})

### Task
{task}

### Context
Implementation is complete. Your job is adversarial: FIND BUGS.

Read:
- `notes/implementation-plan.md` — what was supposed to be built
- `notes/test-manifest.json` — what tests were planned
- Recent git log — what was actually committed

### Your Job
1. Review ALL code changes against the plan
2. Run the full test suite
3. Try edge cases the tests don't cover
4. Check for:
   - Off-by-one errors, null handling, race conditions
   - Missing error handling at system boundaries
   - Security issues (injection, auth bypass, data leaks)
   - Performance issues (N+1 queries, unbounded loops)
   - Missing tests for critical paths

### Output
Write `notes/bug-hunt-round-{round_num}.json`:
```json
{{
  "round": {round_num},
  "bugs": [
    {{
      "id": "BUG-001",
      "severity": "critical|high|medium|low",
      "file": "path/to/file.py",
      "line": 42,
      "description": "what's wrong",
      "fix_suggestion": "how to fix it"
    }}
  ],
  "tests_run": true,
  "tests_passed": true,
  "verdict": "CLEAN|BUGS_FOUND"
}}
```

### Rules
- Be thorough but fair — report real issues, not style preferences
- Focus on correctness and security over cosmetics
- If CLEAN: state so clearly. No phantom bugs.
- Commit and push when done"""

    def _review_prompt(self, task: str, contract: str) -> str:
        return f"""## Review Phase (Final Quality Gate)

### Task
{task}

{f"### Contract{chr(10)}{contract}" if contract else ""}

### Context
Research, implementation, and testing are complete. You are the final reviewer.

Read:
- `notes/research-notes.md` — what was planned
- `notes/implementation-plan.md` — step-by-step plan
- `notes/test-manifest.json` — test cases
- `notes/bug-hunt-round-*.json` — bug hunt results (if any)
- Recent git log — what was committed

### Your Job
1. Verify ALL plan steps were implemented
2. Run the full test suite
3. Check test quality (real assertions, not just "no error")
4. Verify contract success criteria are met
5. Security check: secrets, injection, auth

### Output
Write `notes/pipeline-review.json`:
```json
{{
  "verdict": "APPROVE|NEEDS_CHANGES",
  "plan_coverage": "X/Y steps implemented",
  "test_coverage": "X% (delta: +Y%)",
  "contract_met": true,
  "issues": [
    {{"severity": "high", "description": "...", "file": "...", "suggestion": "..."}}
  ],
  "summary": "Overall assessment"
}}
```

### Rules
- APPROVE only if all success criteria met and tests pass
- If NEEDS_CHANGES: list specific, actionable issues
- Be rigorous but fair"""

    def _refine_prompt(self, task: str, round_num: int) -> str:
        return f"""## Refinement (Round {round_num})

A cross-model review found issues with the previous work.

### Task
{task}

### Your Job
1. Read `notes/refinement-critique.json` or `notes/critique-round-{round_num}.json`
2. Address ALL substantive issues raised
3. Do NOT regress on previously correct work
4. Run full test suite after changes
5. Commit and push revisions
6. Write `notes/revision-round-{round_num}.md` explaining what changed and why"""

    def _direct_prompt(self, task: str, contract: str, remaining_min: int) -> str:
        return f"""## Task

{task}

{f"### Contract{chr(10)}{contract}" if contract else ""}

### Time Budget
~{remaining_min} minutes.

### Approach
1. Assess: understand current state, read relevant files
2. Plan: think through approach in extended thinking
3. Execute: implement, test, commit
4. Review: run Codex review if changes are substantial

### Rules
- Commit and push after every logical change
- Run tests after each change
- If tests fail, fix before moving on"""

    # ── Quality Gates (from conductor) ────────────────────────

    def quality_gate_checks(self) -> list[dict]:
        """Return the quality gate definitions for pipeline tasks."""
        return [
            {
                "id": "tests_pass",
                "description": "Full test suite passes (exit code 0)",
                "command": "pytest",  # discovered dynamically
                "required": True,
            },
            {
                "id": "real_e2e",
                "description": "At least 1 real E2E test (not mocked)",
                "check": "grep -c 'real.*e2e\\|@pytest.mark.e2e' in test-manifest.json",
                "required": True,
            },
            {
                "id": "no_mock_only",
                "description": "Not ALL tests are mocked",
                "check": "test manifest has mix of mocked and real tests",
                "required": True,
            },
            {
                "id": "bug_hunt_clean",
                "description": "Last bug hunt found 0 bugs",
                "check": "latest bug-hunt-round-N.json verdict == CLEAN",
                "required": False,  # advisory
            },
            {
                "id": "no_secrets",
                "description": "No hardcoded secrets in changed files",
                "check": "security scan clean",
                "required": True,
            },
        ]


# ─── CLI Interface ────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: execution_engine.py <command> [args]"}))
        sys.exit(1)

    engine = ExecutionEngine()
    cmd = sys.argv[1]

    if cmd == "classify":
        if len(sys.argv) < 3:
            print(json.dumps({"error": "Usage: classify <description>"}))
            sys.exit(1)
        desc = " ".join(sys.argv[2:])
        result = engine.classify(desc)
        print(json.dumps(result.to_dict()))

    elif cmd == "route":
        if len(sys.argv) < 4:
            print(json.dumps({"error": "Usage: route <task_type> <phase> [--budget-pct N]"}))
            sys.exit(1)
        task_type = sys.argv[2]
        phase = sys.argv[3]
        budget = 0
        producer = ""
        i = 4
        while i < len(sys.argv):
            if sys.argv[i] == "--budget-pct" and i + 1 < len(sys.argv):
                budget = float(sys.argv[i + 1])
                i += 2
            elif sys.argv[i] == "--producer" and i + 1 < len(sys.argv):
                producer = sys.argv[i + 1]
                i += 2
            else:
                i += 1
        result = engine.route(task_type, phase, budget, producer)
        print(json.dumps(result.to_dict()))

    elif cmd == "next-phase":
        if len(sys.argv) < 4:
            print(json.dumps({"error": "Usage: next-phase <current> <verdict> [--strategy S]"}))
            sys.exit(1)
        current = sys.argv[2]
        verdict = sys.argv[3]
        strategy = "pipeline"
        if "--strategy" in sys.argv:
            idx = sys.argv.index("--strategy")
            if idx + 1 < len(sys.argv):
                strategy = sys.argv[idx + 1]
        result = engine.next_phase(current, verdict, strategy)
        print(json.dumps(result))

    elif cmd == "should-refine":
        if len(sys.argv) < 4:
            print(json.dumps({"error": "Usage: should-refine <task_type> <round> [--max N]"}))
            sys.exit(1)
        task_type = sys.argv[2]
        round_num = int(sys.argv[3])
        max_rounds = 3
        if "--max" in sys.argv:
            idx = sys.argv.index("--max")
            if idx + 1 < len(sys.argv):
                max_rounds = int(sys.argv[idx + 1])
        result = engine.should_refine(task_type, round_num, max_rounds)
        print(json.dumps(result))

    elif cmd == "prompt":
        if len(sys.argv) < 4:
            print(json.dumps({"error": "Usage: prompt <phase> <iteration> --task '...'"}))
            sys.exit(1)
        phase = sys.argv[2]
        iteration = int(sys.argv[3])
        task = contract = ""
        remaining = 60
        i = 4
        while i < len(sys.argv):
            if sys.argv[i] == "--task" and i + 1 < len(sys.argv):
                task = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == "--contract" and i + 1 < len(sys.argv):
                contract = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == "--remaining-min" and i + 1 < len(sys.argv):
                remaining = int(sys.argv[i + 1])
                i += 2
            else:
                i += 1
        result = engine.build_phase_prompt(phase, iteration, task, contract, remaining)
        # Print prompt directly (not JSON) for easy embedding in bash
        print(result)

    elif cmd == "cooldown-plan":
        if len(sys.argv) < 3:
            print(json.dumps({"error": "Usage: cooldown-plan <iteration> [flags]"}))
            sys.exit(1)
        iteration = int(sys.argv[2])
        task_type = "code"
        codex_wait = "--codex-wait" in sys.argv
        pr_review = "--pr-review" in sys.argv
        desloppify = "--desloppify" in sys.argv
        model = "opus"
        has_contract = True
        i = 3
        while i < len(sys.argv):
            if sys.argv[i] == "--task-type" and i + 1 < len(sys.argv):
                task_type = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == "--model" and i + 1 < len(sys.argv):
                model = sys.argv[i + 1]
                i += 2
            elif sys.argv[i] == "--no-contract":
                has_contract = False
                i += 1
            else:
                i += 1
        result = engine.cooldown_plan(iteration, task_type, codex_wait,
                                       pr_review, desloppify, model, has_contract)
        print(json.dumps(result.to_dict()))

    elif cmd == "quality-gates":
        gates = engine.quality_gate_checks()
        print(json.dumps(gates))

    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
