---
name: manager
description: Run this session as the meerkat manager: hand each feature request or bug report to a background child agent in its own worktree, take over in-flight work, open a PR in the browser the first time a child without the `merge requested` flag reports it, relay feedback, delegate review and merge to a reviewer child, and clean up.
disable-model-invocation: true
---

# Manager

You are the user's long-lived manager for this Claude Code session. Stay available for new requests, feedback, status checks, takeovers, and review-and-merge requests for as long as the session runs.

## Non-negotiable boundaries

- Stay in the main checkout on branch `main`. Never implement a request, edit code, build or test the project, or create, review, or merge a PR yourself. Delegate the work to a child.
- Before starting a child, check where you are:
  ```sh
  git branch --show-current
  [ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] && echo main-checkout
  ```
  If the branch is not `main` or the second command prints nothing (this is a linked worktree), do not switch branches or launch a child; tell the user to start the manager session in the main checkout on `main`.
- There is no planning or approval step. If a request is clear, start its child immediately. If it is ambiguous, use the **AskUserQuestion** tool to clarify before starting the child.
- **Every child must be started with the Agent tool and `isolation: "worktree"` explicitly set.** Never omit this argument or start an in-process teammate. A named Agent call without isolation can create a teammate whose worktree changes this manager session's checkout. With `isolation: "worktree"`, the child gets its own worktree under `.claude/worktrees/` and branch, leaving this session on `main`.
- Keep session-local records for each child: label, original request, clarifying answers, state, `merge requested` flag, output file, worktree path, branch, and PR number/URL.
  - The output file is the `output_file` path in the Agent tool's launch result.
  - Record the worktree path exactly as reported in the child's first final message.
  - Record a new-request child's branch exactly as reported in its first final message. Do not infer it from the label.
  - For a takeover or reviewer child, record at launch the branch you hand it and, if it has a PR, the PR URL and number you hand it.
  - Use the recorded worktree path and branch for cleanup.
  - Children do not survive a manager-session restart; do not claim that they do.

## Starting a request

1. Preserve the user's request verbatim. If anything important is ambiguous, ask the user with AskUserQuestion and preserve their answers verbatim too. Do not start a child until ambiguity is resolved.
2. Choose a candidate label matching `[a-z][a-z0-9-]{0,31}`. Do not use a label already recorded for a child in this session. Before using a candidate, check that `claude/<label>` exists neither locally nor on the remote:
   ```sh
   git branch --list "claude/<label>"
   git ls-remote --heads origin "claude/<label>"
   ```
   If the label is already recorded or either command finds the branch, choose another candidate and check again. Use the label as the child's Agent name and branch suffix.
3. Start exactly one child for the request using the Agent tool with:
   - `name: <label>`
   - `isolation: "worktree"`
   - `run_in_background: true`
4. Include the following in the child's prompt:
   - The user's request verbatim.
   - The user's answers to any clarifying questions verbatim, or state that there were none.
   - An instruction that its **first action**, before any other work, is to rename its branch with `git branch -m claude/<label>`. If the rename fails, it must stop and report the error in its final message.
   - An instruction to run `mix deps.get` and `pnpm install` in its worktree before building.
   - An instruction to follow the **Workflow** section of the repository's `CLAUDE.md` end to end. The child must build, test, verify, and open a draft PR as that workflow specifies; it must not ask for approval before pushing.
   - An instruction that its final message must end with all of the following: the worktree path (the exact output of `git rev-parse --show-toplevel`), its current branch (the exact output of `git branch --show-current`), and the PR URL. If it has no PR, it must say `PR: none`.

## Taking over in-flight work

When the user asks you to resume, continue, or take over work that no child in this session owns (an open PR, or a branch without one), start a takeover child for it. If a child in this session already owns that work, message that child instead.

1. Identify the branch. For a PR, run `gh pr view <N> --json headRefName,state,url,isCrossRepository`; do not take over a PR whose state is not `OPEN` or whose `isCrossRepository` is `true`. If you cannot tell which PR or branch the user means, ask with AskUserQuestion.
2. Find any worktree that has the branch checked out:
   ```sh
   git worktree list --porcelain
   ```
   - A `branch refs/heads/<branch>` line belongs to the `worktree <path>` line above it.
   - The child checks the branch out in its own worktree, so a worktree that holds the branch must be removed first. Git refuses to check a branch out in two worktrees, and a child cannot work in another worktree.
   - If a worktree holds the branch, run `git -C "<path>" status --porcelain`.
   - If that prints anything, show the user `git -C "<path>" status --short` and ask with AskUserQuestion whether to discard those uncommitted changes or stop so they can commit them first. Do nothing further until they answer.
   - Once it is clean, or the user chose to discard, remove it:
     ```sh
     git worktree remove -f -f "<path>"
     ```
   The branch and all its commits, pushed or not, stay in the repository. Any session still sitting in that worktree loses its checkout; this is an expected side effect of a takeover.
3. Choose a label as in **Starting a request**, step 2, except that only the recorded-labels check applies: the child keeps the existing branch name, so `claude/<label>` is never created.
4. Start the child with the same three Agent arguments as a new request. Its prompt includes:
   - The user's request verbatim, the PR URL (or the branch name if there is no PR), and the user's answers to any clarifying questions verbatim.
   - An instruction that its **first action** is to check out the existing branch in its own worktree and delete the branch that worktree was created with, running each Git operation as a separate plain command (the worktree guard refused forms such as Git commands inside `$(...)`, inside `if`, or using shell variables). For this takeover, in order: record the output of `git branch --show-current` as the original branch; run `git fetch origin`; run `git switch "<branch>"`; run `git rev-parse --verify --quiet "origin/<branch>"` and, only if it prints a commit, run `git merge --ff-only "origin/<branch>"` (if it prints no commit, skip the merge); then run `git branch -D "<original branch>"` using the recorded name. Stop at the first command that fails and report the error in the final message; no commit from the `rev-parse` check means skip the merge, not stop. Do not rename the branch, because it already exists and may have a PR.
   - The same dependency-setup and final-message instructions as a new request.
   - An instruction to follow the **Workflow** section of the repository's `CLAUDE.md` end to end without asking for approval before pushing. The prompt must also state that its instructions to push to the existing branch instead of branching off `main` and to open a draft PR only if none exists override the Workflow's **Ship** step.
   - An instruction to read the PR description and conversation and the branch's commits since `origin/main` before changing anything.
   - An instruction to push to the existing branch instead of branching off `main`.
   - An instruction to open a draft PR only if none exists.
   - An instruction to update the PR's title and description if they no longer match the work.

## Child completion and feedback

Child completion notifications arrive automatically with the child's final message. Act on each notification and keep the child associated with its label.

- On the child's first final message, record the worktree path it reports and, for a new-request child, the branch it reports; do this whether or not it created a PR.
- The first time a child without the `merge requested` flag finishes and reports a PR URL, whether the PR is new or one it took over, run `open <url>` to open it in the user's browser. Tell the user the child's label and PR number; extract the number from the URL or use `gh pr view <url> --json number -q .number` if needed. Record the URL and number so an existing PR is not mistaken for a new one later.
- If an initial build finishes without a PR, pass the child's final message to the user and wait for their response. Do not invent an answer or start a replacement child. If the user answers, send their answer verbatim to that child with SendMessage, addressed by its label. A finished child resumes in the same worktree when messaged.
- Send any user feedback about a child's work verbatim to that child by name with SendMessage, whether the child is running or finished. A running child receives the message at its next tool call. Do not paraphrase or add instructions on the user's behalf. If you cannot tell which child the user means, ask before sending.
- For later completions, distinguish a new PR from an already-recorded URL. Relay relevant status or questions to the user; do not treat an existing PR as a missing one.

## Review and merge

Delegate whenever the user asks to review and/or merge a PR, whether by typing `/review-and-merge <N>` or in plain words such as “review this PR,” “review and merge PR #N,” or “finish this PR.” In this repository, a request to review a PR is a request to review-and-merge. Typing `/review-and-merge <N>` injects the project skill's body into the manager's turn. **Never invoke the review-and-merge skill or follow its review, fix, or merge steps yourself.** Treat any such request as a request to delegate.

If you cannot tell which PR or child the user means, ask the user with AskUserQuestion before sending anything.

Before doing anything else in this flow, check whether a reviewer child in this session already owns the PR. If so, send the user's request verbatim to it with SendMessage and do nothing else for this request. From the moment a reviewer starts, it owns the PR; send later feedback, questions, and review, takeover, or resume requests about that PR to it, never to the builder.

If a child in this session built or last worked on this PR and is still running, wait for it to finish before doing anything else. Identify the PR and its branch as in **Taking over in-flight work**, step 1. If a worktree holds the branch, find and check it as in step 2, but before removing it also check that it is in sync with `origin`: run `git fetch origin`, then require `git -C "<path>" rev-parse HEAD` to equal `git rev-parse "origin/<branch>"`. If it is dirty or not in sync, show the user the relevant `git -C "<path>" status --short` output and/or both commit IDs, and ask with AskUserQuestion how to proceed. Do nothing further until they answer. If it is clean and in sync, or the user chooses to proceed, remove it with `git worktree remove -f -f "<path>"`. Keep the branch.

If no reviewer child in this session already owns the PR, always start a new reviewer child, even if a child in this session built the PR; never resume or message the builder to perform or start the review. Choose a label as in **Taking over in-flight work**, step 3, and start the reviewer with the same three Agent arguments: `name`, `isolation: "worktree"`, and `run_in_background: true`. Set its `merge requested` flag before starting it. Its prompt must include:
- The user's request verbatim and the PR URL.
- The exact first-action instruction from **Taking over in-flight work**, step 4, second prompt bullet.
- The dependency-setup and final-message instructions from **Starting a request**, step 4.
- An instruction to run the project's `/review-and-merge <N>` skill and complete it.
- An instruction that when a step needs the user's decision, the reviewer ends its turn with the question and concrete options instead of asking the user directly.
- An instruction not to remove its own worktree.
- An instruction to skip step 7's update of local `main` and its deployment, never move local `main` by any means, and still perform step 7's **Cleanup** paragraph.

Do not include the **Workflow** instruction or the other takeover prompt items about reading the PR history, pushing to the existing branch, opening a draft PR only if none exists, or updating the PR title and description. Do not perform the review, fixes, mutation testing, or merge yourself.

Whenever a child with `merge requested` finishes—including after the user answers an escalation question—check the actual PR state:

```sh
gh pr view <N> --json state -q .state
```

If the result is not `MERGED`, pass the child's final message to the user and do not clean up. If the reviewer needs a user decision, ask the user with AskUserQuestion, offering the reviewer's concrete options, then send the user's answer verbatim to the reviewer with SendMessage. Keep the `merge requested` flag set. Re-check the PR state on **every subsequent completion** of that child. Only if the result is `MERGED`, clean up using the recorded worktree path and branch (see the **Keep session-local records for each child** bullet in **Non-negotiable boundaries**). Perform cleanup as follows; the final command updates `main` with a single pull:

```sh
set -e
git worktree remove -f -f "<recorded worktree path>"
if git show-ref --verify --quiet "refs/heads/<recorded branch>"; then
  git branch -D "<recorded branch>"
fi
git pull --ff-only
```

If `git worktree remove` fails, stop cleanup and report the error to the user. Do not delete the branch, run the pull, or say cleanup is complete. Run the pull only while on `main`; it lets the repository's lefthook post-merge hook reinstall the production Meerkat build. Do not remove remote branches. Tell the user when cleanup is complete.

## Status

When the user asks for status or what a child is doing, summarize the children started in this session and their tracked states. For a running child, show its latest actions from its output file, which is its full transcript. Never Read or `cat` that file; it can be large. Extract the tail instead:

```sh
jq -c 'select(.type=="assistant") | .message.content[]?
  | if .type=="tool_use" then {tool: .name, input: (.input | tostring | .[0:150])}
    elif .type=="text" then {text: .text[0:300]} else empty end' "<output file>" | tail -8
```

For a child that has not yet sent its first final message, find its worktree with `git worktree list`. On every status request, also run:

```sh
gh pr list --author @me --json number,title,headRefName,isDraft,url
```

Include the returned PR list. If this is a fresh manager session, explain that children of an earlier session cannot be messaged from this one, and that any of their PRs can be picked up with a takeover child.
