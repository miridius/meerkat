import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type Fixture = {
	dir: string;
	commitMsgPath: string;
	// git invoker scoped to this fixture's repo, with a sanitised env
	// (no global config, fixed author). Useful for tests that need to
	// add commits beyond the initial staged state.
	git: (...args: string[]) => string;
	// Recursively remove every tmp directory the fixture allocated. The
	// runner calls this on meerkat's exit; tests that build a fixture
	// without going through the runner should call it from a `finally`.
	cleanup: () => void;
};

export type PrFixture = {
	dir: string;
	prNumber: number;
	baseRef: string;
	headRef: string;
	title: string;
	body: string;
	url: string;
	// Stub directory that should be PREPENDED to PATH before invoking
	// meerkat so `gh pr view <N>` and `gh api ...` are intercepted
	// instead of hitting api.github.com.
	ghStubDir: string;
	// Path the stub writes any captured `gh api` stdin body to. Tests
	// can read this file to inspect the request that the server sent.
	apiCapturePath: string;
	// Canned review URL the stub returns from `gh api ... POST ... reviews`.
	// Used by tests to assert the post-to-github flow opened the right tab.
	reviewHtmlUrl: string;
	// Recursively remove every tmp directory the fixture allocated
	// (local clone, bare remote, staging clone, gh stub dir). The
	// runner calls this on meerkat's exit.
	cleanup: () => void;
};

const DEFAULT_COMMIT_MSG = `Subject line under sixty-three chars

Body paragraph that explains the why.
Multiple lines so the gutter has a multi-line block.

- bullet one
- bullet two
`;

const DEFAULT_RUST_FILE = `fn main() {
    let name = "world";
    println!("Hello, {}!", name);
    let n: i32 = 42;
    let m = n.checked_add(1);
    if let Some(v) = m {
        println!("v = {}", v);
    }
}
`;

const DEFAULT_NOTES_MD = `# Notes

Lorem ipsum dolor sit amet.

- thing one
- thing two

## Subsection

More text.
`;

function rmAll(dirs: string[]): void {
	for (const d of dirs) rmSync(d, { recursive: true, force: true });
}

// One `git` invoker bound to a working dir. Used everywhere we
// shell out to git from a fixture so we don't ship four near-identical
// `(...args) => execFileSync("git", args, ...)` closures.
function gitFor(cwd: string): (...args: string[]) => string {
	return (...args: string[]) =>
		execFileSync("git", args, { cwd, env: sanitisedGitEnv(), encoding: "utf8" });
}

// Build a tmp git repo with realistic staged changes. The commit-msg
// file is written next to the repo so meerkat can pick it up via
// --commit-msg.
export function makeFixture(
	opts: { commitMsg?: string; files?: Record<string, string> } = {},
): Fixture {
	const dir = mkdtempSync(join(tmpdir(), "meerkat-e2e-"));
	const git = gitFor(dir);

	git("init", "-q", "-b", "main");
	git("commit", "--allow-empty", "-q", "-m", "initial");

	const files = opts.files ?? {
		"src/main.rs": DEFAULT_RUST_FILE,
		"NOTES.md": DEFAULT_NOTES_MD,
	};

	for (const [path, content] of Object.entries(files)) {
		const full = join(dir, path);
		mkdirSync(join(full, ".."), { recursive: true });
		writeFileSync(full, content);
		git("add", path);
	}

	const commitMsgPath = join(dir, "COMMIT_MSG");
	writeFileSync(commitMsgPath, opts.commitMsg ?? DEFAULT_COMMIT_MSG);

	return { dir, commitMsgPath, git, cleanup: () => rmAll([dir]) };
}

// Build a complete fixture for `meerkat --pr <N>`:
//   * a bare "remote" repo with `refs/heads/<base>` and
//     `refs/pull/<N>/head` populated (mirroring how GitHub publishes PR
//     refs)
//   * a local working clone with `origin` pointing at the bare remote
//   * a stub `gh` binary that returns canned JSON for `gh pr view <N>`
//
// The caller prepends `ghStubDir` to PATH when spawning meerkat so the
// stub wins over the real `gh`.
export function makePrFixture(
	opts: {
		prNumber?: number;
		baseRef?: string;
		headRef?: string;
		title?: string;
		body?: string;
	} = {},
): PrFixture {
	const prNumber = opts.prNumber ?? 123;
	const baseRef = opts.baseRef ?? "main";
	const headRef = opts.headRef ?? "feat/the-feature";
	const title = opts.title ?? "Feature: add a thing";
	const body = opts.body ?? "Detailed body explaining why the feature was added.";
	const url = `https://github.com/example/example/pull/${prNumber}`;

	// Bare remote — mirrors GitHub-style PR refs.
	const remoteDir = mkdtempSync(join(tmpdir(), "meerkat-e2e-pr-remote-"));
	const remoteGit = gitFor(remoteDir);
	remoteGit("init", "-q", "--bare", "-b", baseRef);

	// Workspace where we author the base + head commits, then push them
	// up to the bare remote.
	const stagingDir = mkdtempSync(join(tmpdir(), "meerkat-e2e-pr-staging-"));
	const stagingGit = gitFor(stagingDir);
	stagingGit("init", "-q", "-b", baseRef);
	// Base commit — the merge-base.
	writeFileSync(join(stagingDir, "base.txt"), "shared base content\n");
	stagingGit("add", "base.txt");
	stagingGit("commit", "-q", "-m", "Initial base");
	stagingGit("remote", "add", "origin", remoteDir);
	stagingGit("push", "-q", "origin", baseRef);
	// Head commit — diverges from the base with a new file.
	writeFileSync(join(stagingDir, "feature.rs"), "fn feature() {}\n");
	stagingGit("add", "feature.rs");
	stagingGit("commit", "-q", "-m", "Add feature");
	// Publish the head as a "pull request" ref on the remote, mirroring
	// GitHub's `refs/pull/<N>/head`.
	stagingGit("push", "-q", "origin", `HEAD:refs/pull/${prNumber}/head`);

	// Local working clone — this is what meerkat is invoked inside.
	const dir = mkdtempSync(join(tmpdir(), "meerkat-e2e-pr-local-"));
	const localGit = gitFor(dir);
	localGit("clone", "-q", remoteDir, ".");

	// gh stub directory — a tiny shell script that handles the two
	// gh subcommands meerkat invokes:
	//
	//   gh pr view <N> --json ...
	//     → emits the canned PR metadata JSON
	//
	//   gh api -X POST /repos/.../pulls/<N>/reviews --input <file>
	//     → copies the file's contents to
	//       `<dir>/last-api-input.json`, then prints a canned
	//       review response (with html_url) to stdout.
	//
	// The captured request body lets tests assert on what the server
	// actually sent.
	const ghStubDir = mkdtempSync(join(tmpdir(), "meerkat-e2e-gh-"));
	const ghPath = join(ghStubDir, "gh");
	const apiCapturePath = join(ghStubDir, "last-api-input.json");
	const reviewHtmlUrl = `${url}#pullrequestreview-12345`;
	const prJson = JSON.stringify({
		number: prNumber,
		baseRefName: baseRef,
		headRefName: headRef,
		title,
		body,
		url,
	});
	const apiResponseJson = JSON.stringify({
		id: 12345,
		html_url: reviewHtmlUrl,
		state: "PENDING",
	});
	writeFileSync(
		ghPath,
		`#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  cat <<'EOF_JSON'
${prJson}
EOF_JSON
  exit 0
fi
if [ "$1" = "api" ]; then
  # Find the --input flag's value (the tmp file path meerkat
  # wrote the request body to).
  input_path=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --input)
        input_path="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  if [ -n "$input_path" ] && [ "$input_path" != "-" ]; then
    cp "$input_path" '${apiCapturePath}'
  else
    cat - > '${apiCapturePath}'
  fi
  cat <<'EOF_JSON'
${apiResponseJson}
EOF_JSON
  exit 0
fi
echo "gh stub: unsupported invocation: $*" >&2
exit 1
`,
	);
	chmodSync(ghPath, 0o755);

	return {
		dir,
		prNumber,
		baseRef,
		headRef,
		title,
		body,
		url,
		ghStubDir,
		apiCapturePath,
		reviewHtmlUrl,
		cleanup: () => rmAll([dir, remoteDir, stagingDir, ghStubDir]),
	};
}

function sanitisedGitEnv(): NodeJS.ProcessEnv {
	return {
		...process.env,
		GIT_AUTHOR_NAME: "test",
		GIT_AUTHOR_EMAIL: "test@example.com",
		GIT_COMMITTER_NAME: "test",
		GIT_COMMITTER_EMAIL: "test@example.com",
		GIT_CONFIG_GLOBAL: "/dev/null",
		GIT_CONFIG_SYSTEM: "/dev/null",
	};
}
