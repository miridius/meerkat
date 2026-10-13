---
name: verifier-meerkat
description: Use when a meerkat change reaches the review page or CLI.
---

Start the `meerkat-qa` agent with the Agent tool and
`subagent_type: "meerkat-qa"`.
Pass the diff scope, the claim being verified, and a scratch
directory.
Require at least one marked off-happy-path probe at each changed
user surface.
Use `BLOCKED` if the agent cannot reach the changed behavior.
Treat any failed check or spec deviation as `FAIL`.
Use `PASS` only when all checks pass and no spec deviation is found.
Use the agent's report as evidence for `/verify`'s Steps and
Findings.
