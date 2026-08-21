Ah, the dreaded **Agentic Death Spiral**—where an overzealous reviewer agent meets a hyper-obedient author agent, and together they over-engineer a simple 10-line function into a 200-line monolith of defensive paranoia and bloat.

Because LLMs are trained to be helpful, reviewer agents will *always* find something if you ask them "what can be improved?" They will invent edge cases that will never happen in real life just to give you your money's worth.

To break this feedback loop and achieve convergence, you need to introduce structural constraints, strict heuristics, and clear decay mechanics into your multi-agent architecture.

---

## 1. The "Burden of Proof" Heuristic (Failing Test Requirement)

Speculative critique is the #1 cause of agent churn ("What if `user_id` is a list of strings instead of an int?").

* **The Rule:** The reviewer agent **cannot request a code change** based on logic or runtime behavior unless it can provide a self-contained, failing unit test that reproduces the bug on the current codebase.
* **Why it works:** If the reviewer agent can't write a test that fails, the critique is downgraded to an informational comment and the code is approved. This instantly eliminates 80% of defensive code bloat.

## 2. Hard Severity Gating & Actionability Shields

Do not let the author agent act on every comment. Force the reviewer agent to structure its output into strict severity buckets:

* **`BLOCKING` (Critical/Security/Correctness):** The author agent *must* fix this (e.g., SQL injection, memory leak, off-by-one error).
* **`NON-BLOCKING` (Nitpicks/Refactoring/Aesthetics):** Written to the PR notes for human context, but **hidden from the author agent** during auto-remediation loops.

If a review yields zero `BLOCKING` issues, the cycle converges immediately.

## 3. Offload Style & Safety to Deterministic Tools

LLMs are terrible arbiters of style, formatting, and strict typing because their opinion fluctuates with every call.

* **The Rule:** Never let an LLM review anything a linter, type checker, or static analysis tool (e.g., `Ruff`, `ESLint`, `Mypy`, `SonarQube`) can catch.
* Run deterministic tools **first**. If they pass, the LLM reviewer is *only* prompted to assess high-level semantic intent, business logic, and security risks.

## 4. Scope Locking & Feedback Decay

As iterations increase, narrow the reviewer's scope to prevent "churn creep" (where fixing Issue A introduces a minor style flaw that the reviewer flags in Round 2).

* **Round 1:** Review full PR diff.
* **Round 2:** Review *only* the specific lines modified in response to Round 1.
* **Round 3:** Reviewer prompt switches to "Strict Bug Hunt"—it is explicitly forbidden from commenting on architecture, readability, or defensive handling. It can only block if Round 2 introduced a breaking regression.
* **Round 4:** **Hard Circuit Breaker.** Fall back to a human or default-merge if tests pass.

## 5. "Bias Toward Approval" System Prompting

Modify your reviewer agent's system prompt to penalize rejections. Give it a high "cost" for requesting changes.

```markdown
You are a senior staff engineer conducting a PR review. 

GOAL: Approve code that is correct, safe, and readable. 
BIAS TOWARD MERGING: Perfection is the enemy of shipped software. Do not request changes for hypothetical edge cases, minor stylistic preferences, or speculative future needs. 

RULES:
1. Accept code as long as it works, passes existing tests, and lacks severe security vulnerabilities.
2. Avoid suggesting defensive checks for inputs that are already typed or handled upstream.
3. If the code is "good enough," output STATUS: APPROVED.

```

---

## Summary Matrix

| Problem | Cause | Heuristic Solution |
| --- | --- | --- |
| **Defensive Bloat** | LLM inventing rare edge cases | Require a failing unit test to reject code. |
| **Endless Nitpicking** | LLMs always wanting to "help" | Gate feedback; only pass `BLOCKING` severity to Coder Agent. |
| **Scope Creep** | Refactoring fixes introduce new tweaks | Scope-lock reviews exclusively to newly touched diff lines. |
| **Flaky Formatting Debate** | LLM non-determinism | Offload formatting/types to native AST linters (`Mypy`, `Ruff`). |

---

How are you currently orchestrating the loop between the reviewer and author agents (e.g., custom Python script, LangGraph, AutoGen, or GitHub Actions)?
