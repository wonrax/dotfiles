/**
 * The version-control half of a repo-backed task: what cuts the workspace, what
 * it is cut from, how its state is captured between nodes, and what is left in
 * the operator's repository once the task is gone.
 *
 * jj and git are asked for the same five things — a checkout of its own beside
 * the operator's, a base, a snapshot, a restore, a teardown — and differ in
 * how much of that they do unasked. jj's working copy is already a commit in
 * the shared store, so a snapshot is any jj command and the host reads the
 * agent's work with `jj diff -r <workspace>@`. Git has a staging area and no
 * such commit, so the engine writes one after every node under
 * `refs/agentflow/<branch>/snapshot`, which is what gives the git side the same
 * two properties: the operator can see uncommitted work from their own repo,
 * and tearing the workspace down loses none of it.
 *
 * Nothing here imports the engine. The host-side half runs git and jj directly
 * and the container-side half is shell text the engine executes, which keeps
 * this importable from `tasks.ts` at spawn time, before any container exists.
 */
import type { TaskRecord, Vcs } from "./model.ts";

const dec = new TextDecoder();

interface Ran {
  code: number;
  out: string;
  err: string;
}

const ran = (r: Deno.CommandOutput): Ran => ({
  code: r.code,
  out: dec.decode(r.stdout),
  err: dec.decode(r.stderr),
});

const failed = (e: unknown): Ran => ({ code: -1, out: "", err: String(e) });

const command = (cmd: string, args: string[]) =>
  new Deno.Command(cmd, { args, stdin: "null", stdout: "piped", stderr: "piped" });

const run = (cmd: string, args: string[]): Promise<Ran> =>
  command(cmd, args).output().then(ran, failed);

const runSync = (cmd: string, args: string[]): Ran => {
  try {
    return ran(command(cmd, args).outputSync());
  } catch (e) {
    return failed(e);
  }
};

const stat = (path: string): Deno.FileInfo | undefined => {
  try {
    return Deno.statSync(path);
  } catch {
    return undefined;
  }
};

/** records written before git was an option are all jj */
export const vcsOf = (task: TaskRecord): Vcs | undefined =>
  task.request.repo ? task.vcs ?? "jj" : undefined;

/**
 * jj wins in a colocated repo: the `.jj` is there because that is how its owner
 * works in it, and a git worktree cut from under jj shows up in their log as
 * a branch jj then imports. `vcs: "git"` on the request is the override.
 */
export const detectVcs = (repo: string): Vcs | undefined =>
  stat(`${repo}/.jj`) ? "jj" : stat(`${repo}/.git`) ? "git" : undefined;

/** why this repo cannot back a task, in words worth showing at spawn; nothing when it can */
export const repoProblem = (repo: string, vcs: Vcs): string | undefined => {
  if (!repo.startsWith("/")) return `repo must be an absolute path on the host, got "${repo}"`;
  if (vcs === "jj") {
    return stat(`${repo}/.jj`) ? undefined : `${repo} is not a jj repo: there is no .jj in it`;
  }
  const git = stat(`${repo}/.git`);
  if (!git) return `${repo} is not a git repo: there is no .git in it`;
  // The container sees the repo and nothing around it. A linked worktree or a
  // submodule checkout keeps its real git directory somewhere else and leaves
  // a pointer file here, and that pointer leads out of the mount.
  if (!git.isDirectory) {
    return `${repo}/.git is a file, so this is a linked worktree or a submodule checkout and its ` +
      `history lives outside it, where a container that mounts only this directory cannot ` +
      `reach. Point repo at the main checkout.`;
  }
  return undefined;
};

export interface Base {
  /** one line for a person: short id, what points at it, what it says */
  line?: string;
  /** the full commit id, when the base is a single commit */
  commit?: string;
}

const JJ_BASE = `commit_id ++ " " ++ ` +
  `separate(" ", commit_id.short(8), bookmarks, description.first_line()) ++ "\\n"`;

/**
 * What the task's workspace will be cut from. With nothing asked for it is
 * where the operator's checkout stands — `jj workspace add` with no `-r` gives
 * the new working copy the same parents as the current one, and a git worktree
 * starts at HEAD — which means an operator who left their checkout on a
 * half-finished branch has just handed the agent a tree they never meant to.
 * That is invisible until the first gate fails, half an hour in, so it is worth
 * one line at second zero.
 *
 * Read on the host, synchronously, because `af spawn` prints it before the
 * container the workspace lives in exists. Best effort when the base was left
 * to default — a repo jj cannot read is a task with no base line, not a spawn
 * that failed — and an error when one was named, because a base that does not
 * resolve is a typo, and a task cut from somewhere else instead is the quiet
 * version of the failure this exists to make loud.
 */
export const resolveBase = (repo: string, vcs: Vcs, rev?: string): Base => {
  if (vcs === "jj") {
    // deno-fmt-ignore
    const r = runSync("jj", [
      "--repository", repo, "--ignore-working-copy", "log", "--no-graph", "--color", "never",
      "-r", rev ?? "@-", "-T", JJ_BASE,
    ]);
    const revs = r.code === 0 ? r.out.split("\n").map((l) => l.trim()).filter(Boolean) : [];
    if (!revs.length) {
      if (!rev) return {};
      throw new Error(
        `base "${rev}" does not resolve in ${repo}` +
          (r.code === 0 ? ": the revset is empty" : `: ${r.err.trim().slice(-400)}`),
      );
    }
    const line = revs
      .map((l) => l.slice(l.indexOf(" ") + 1).replace(/\s+/g, " ").slice(0, 90))
      .join(" + ");
    return { line, commit: revs.length === 1 ? revs[0].split(" ")[0] : undefined };
  }

  const git = (...args: string[]) => runSync("git", ["--no-optional-locks", "-C", repo, ...args]);
  const found = git(
    "rev-parse",
    "--verify",
    "--quiet",
    "--end-of-options",
    `${rev ?? "HEAD"}^{commit}`,
  );
  const commit = found.out.trim();
  if (found.code !== 0 || !commit) {
    throw new Error(
      rev
        ? `base "${rev}" does not resolve to a commit in ${repo}`
        : `${repo} has no commit to cut a worktree from: HEAD does not resolve`,
    );
  }
  const info = git("log", "-1", "--format=%h%x00%D%x00%s%x00%cr", commit);
  const [short, refs, subject, age] = info.out.trim().split("\0");
  if (info.code !== 0 || !short) return { line: commit.slice(0, 8), commit };
  // Clipped separately: a branch with a long name and its remote twin would
  // otherwise spend the whole line on refs and leave one letter of the subject.
  // The age is the part that catches a remote-tracking ref nobody has fetched
  // in a week, so it is never clipped at all.
  const clip = (s: string, n: number) => s.length > n ? `${s.slice(0, n - 1)}…` : s;
  const what = `${short} ${refs ? `(${clip(refs, 48)}) ` : ""}${clip(subject ?? "", 60)}`
    .replace(/\s+/g, " ").trim();
  return { line: `${what}${age ? `, ${age}` : ""}`, commit };
};

/** who the operator commits as in this repo, for commits made in the container */
export const hostIdentity = async (
  repo: string,
  vcs: Vcs,
): Promise<{ name: string; email: string } | undefined> => {
  const get = (key: string) =>
    vcs === "jj" ? run("jj", ["config", "get", key]) : run("git", ["-C", repo, "config", key]);
  const [name, email] = await Promise.all([get("user.name"), get("user.email")]);
  if (name.code !== 0 || email.code !== 0) return undefined;
  return { name: name.out.trim(), email: email.out.trim() };
};

// ---------------------------------------------------------------------------
// remotes

/**
 * The repo's remotes as `<name> <url>` lines, read host-side where nothing
 * rewrites them. That is jj's own listing format; git's is put into it so one
 * baseline file and one parser serve both.
 */
export const listRemotes = async (repo: string, vcs: Vcs): Promise<string | undefined> => {
  if (vcs === "jj") {
    const r = await run("jj", ["-R", repo, "--ignore-working-copy", "git", "remote", "list"]);
    return r.code === 0 ? r.out : undefined;
  }
  const r = await run("git", [
    "-C",
    repo,
    "config",
    "--local",
    "--get-regexp",
    "^remote\\..*\\.url$",
  ]);
  // exit 1 is "no such key": a repo with no remotes, which is an answer
  if (r.code !== 0 && r.code !== 1) return undefined;
  return r.out.split("\n").filter(Boolean).map((l) => {
    const cut = l.indexOf(" ");
    const key = cut < 0 ? l : l.slice(0, cut);
    return `${key.slice("remote.".length, -".url".length)} ${cut < 0 ? "" : l.slice(cut + 1)}`;
  }).join("\n");
};

export const setRemote = (
  repo: string,
  vcs: Vcs,
  op: "add" | "set-url" | "remove",
  name: string,
  url?: string,
): Promise<unknown> => {
  const tail = [op, name, ...(url === undefined ? [] : [url])];
  return vcs === "jj"
    ? run("jj", ["-R", repo, "--ignore-working-copy", "git", "remote", ...tail])
    : run("git", ["-C", repo, "remote", ...tail]);
};

// ---------------------------------------------------------------------------
// git: the container side

/**
 * Settings the container's git runs under whatever the repo's own config says,
 * which a worktree shares with the operator's checkout. Carried in the
 * environment because that outranks every config file, and because the other
 * place to put them is that shared file.
 *
 * Signing is off since the key is not in here: a repo with `commit.gpgsign`
 * fails every commit, and the obvious fix from inside — `git config
 * commit.gpgsign false` — lands in the operator's config and quietly stops
 * their commits being signed too. Same shape as the remote URL an agent
 * rewrote to get a push through, and the same answer: take away the reason.
 *
 * Auto-gc is off because it repacks and prunes the operator's object store
 * from inside a container, as root, on a schedule nobody chose. A task adds
 * objects to the repository; reorganising it stays with its owner.
 */
const GIT_OVERRIDES: [string, string][] = [
  ["commit.gpgsign", "false"],
  ["tag.gpgsign", "false"],
  ["gc.auto", "0"],
  ["maintenance.auto", "false"],
];

/** `GIT_CONFIG_*` entries to add to a container env that may already carry some */
export const gitConfigEnv = (env: Record<string, string>): Record<string, string> => {
  const have = Math.max(0, Number.parseInt(env.GIT_CONFIG_COUNT ?? "0", 10) || 0);
  const theirs = new Set(
    Array.from({ length: have }, (_, i) => env[`GIT_CONFIG_KEY_${i}`]?.toLowerCase()),
  );
  // the operator's own entry for a key stands: later entries win, so ours are
  // simply not added where they have spoken
  const ours = GIT_OVERRIDES.filter(([key]) => !theirs.has(key));
  const out: Record<string, string> = { GIT_CONFIG_COUNT: String(have + ours.length) };
  ours.forEach(([key, value], i) => {
    out[`GIT_CONFIG_KEY_${have + i}`] = key;
    out[`GIT_CONFIG_VALUE_${have + i}`] = value;
  });
  return out;
};

/**
 * Run before anything touches the repo. `safe.directory` because the mount
 * belongs to the operator's uid and this is root, which git refuses as dubious
 * ownership before it will so much as read a ref. The LFS filter because it is
 * global config an image may not have written, and a checkout made without it
 * is a tree of 130-byte pointer files that fails much later, as something
 * else: sqlite's "file is not a database", a model that will not load.
 *
 * $1 name, $2 email — either may be empty.
 */
export const GIT_PREPARE = `set -e
git config --global --replace-all safe.directory '*'
[ -z "$1" ] || git config --global user.name "$1"
[ -z "$2" ] || git config --global user.email "$2"
if command -v git-lfs >/dev/null 2>&1; then git lfs install --skip-repo >/dev/null 2>&1 || true; fi`;

/**
 * Locked the moment it exists. The worktree's path is a container path, so on
 * the host it looks like a checkout whose directory was deleted — exactly what
 * `git worktree prune` is for, and what a repo's own cleanup script goes
 * looking for. Pruned, the task's next git command finds no repository at all.
 * A lock is the documented way to say the path is somewhere this machine
 * cannot see.
 *
 * $1 branch, $2 path, $3 base commit
 */
export const GIT_ADD_WORKTREE = `set -e
git -C /repo worktree add -b "$1" "$2" "$3"
git -C /repo worktree lock --reason "agentflow task: this path exists only inside its container" "$2"`;

/** a worktree is cut without its submodules, and a build that needs one fails on a missing file */
export const GIT_SUBMODULES = `[ -f .gitmodules ] || exit 0
git submodule update --init --recursive`;

/** prints LFS_WITHOUT_FILTER when the checkout tracks LFS files and the image cannot smudge them */
export const GIT_LFS_CHECK = `command -v git-lfs >/dev/null 2>&1 && exit 0
git grep -q -e 'filter=lfs' -- ':(glob)**/.gitattributes' 2>/dev/null && echo LFS_WITHOUT_FILTER
exit 0`;

/**
 * What a snapshot takes: every change to a tracked file, and every new file
 * that is neither ignored nor enormous — which is what jj's working-copy commit
 * holds, size limit included. The limit is there because this runs unasked
 * after every node, in the operator's object store: a core dump or a dataset
 * someone forgot to ignore would otherwise be hashed into it each time it
 * changed. 10 MiB is far above any source file and far below those.
 *
 * Into whichever index `GIT_INDEX_FILE` names, so a snapshot can use a
 * scratch one and leave the agent's staging area exactly as it was.
 */
const STAGE = `stage() {
  git add -u >/dev/null 2>&1 || true
  git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null |
    while IFS= read -r f; do
      if [ -h "$f" ]; then :
      elif [ -f "$f" ] && [ "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" -le 10485760 ] 2>/dev/null; then :
      else continue
      fi
      printf '%s\\0' "$f"
    done |
    GIT_LITERAL_PATHSPECS=1 git add --pathspec-from-file=- --pathspec-file-nul >/dev/null 2>&1 || true
}`;

export const snapshotRef = (workspace: string) => `refs/agentflow/${workspace}/snapshot`;

/**
 * The worktree as it stands, as a commit on top of HEAD, left under one ref in
 * the shared repository. One ref rather than one per node because a watch loop
 * visits nodes for weeks; its reflog is what keeps the older snapshots alive
 * for as long as git keeps reflogs, which is the same promise jj's operation
 * log makes about the commits `--reset-workspace` restores from.
 *
 * Prints the snapshot's commit id as its last line. Unchanged since the last
 * one, it prints that one's id and writes nothing.
 *
 * $1 ref
 */
export const GIT_SNAPSHOT = `set -e
${STAGE}
idx=$(mktemp)
trap 'rm -f "$idx" "$idx.lock"' EXIT
real=$(git rev-parse --git-path index)
# an empty file is not an index git will read, so with nothing to copy it goes
if [ -f "$real" ]; then cp "$real" "$idx"; else rm -f "$idx"; fi
export GIT_INDEX_FILE="$idx"
stage
tree=$(git write-tree)
unset GIT_INDEX_FILE
head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=
prev=$(git rev-parse -q --verify "$1^{commit}" 2>/dev/null) || prev=
if [ -n "$prev" ]; then
  was=$(git rev-parse -q --verify "$prev^{tree}" 2>/dev/null) || was=
  on=$(git rev-parse -q --verify "$prev^1" 2>/dev/null) || on=
  if [ "$was" = "$tree" ] && [ "$on" = "$head" ]; then echo "$prev"; exit 0; fi
fi
commit=$(git -c user.name=agentflow -c user.email=agentflow@localhost \\
  commit-tree --no-gpg-sign "$tree" \${head:+-p "$head"} -m "agentflow: workspace snapshot")
git update-ref --create-reflog -m "agentflow: workspace snapshot" "$1" "$commit"
echo "$commit"`;

/**
 * Put the worktree's files back the way a snapshot has them. Staging first is
 * what lets `read-tree` delete what was created since: it removes what the
 * index knows and the snapshot lacks, and a file nobody staged is one it has
 * never heard of. The index then goes back to HEAD, so what comes out is the
 * snapshot's files with nothing staged — the branch has not moved, and the
 * difference between it and these files is ordinary unstaged work.
 *
 * $1 snapshot commit
 */
export const GIT_RESTORE = `set -e
${STAGE}
git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1 || {
  echo "snapshot $1 is not in this repository any more"; exit 3; }
stage
git read-tree --reset -u "$1"
git reset -q`;

// ---------------------------------------------------------------------------
// git: the host side

/**
 * A branch name nothing holds. A removed task frees its id but keeps its branch
 * when the branch has work on it, so the next task to take the id finds the
 * name in use — and the snapshot ref counts as in use too, since a kept one is
 * somebody's uncommitted work and the new task's first snapshot would move it.
 */
export const freeBranch = async (repo: string, stem: string): Promise<string> => {
  const held = async (name: string) => {
    for (const ref of [`refs/heads/${name}`, snapshotRef(name)]) {
      const r = await run("git", ["-C", repo, "show-ref", "--verify", "--quiet", ref]);
      if (r.code === 0) return true;
    }
    return false;
  };
  for (let n = 1; n < 50; n++) {
    const name = n === 1 ? stem : `${stem}-${n}`;
    if (!await held(name)) return name;
  }
  return `${stem}-${crypto.randomUUID().slice(0, 6)}`;
};

/**
 * Take a task's worktree out of the operator's repository, and keep whatever
 * holds work. Returns what was kept, in words for the operator.
 *
 * Done by hand on the host rather than with `git worktree remove` because that
 * command validates a path which only ever existed inside a container that may
 * already be gone. Removing the administrative directory is what it and
 * `prune` come down to, and the `gitdir` check is what makes sure the one
 * removed is this task's: git names those directories after the worktree's
 * last path segment, so every task's is some spelling of `wc`.
 *
 * Nothing that holds work goes. A branch still at its base and a snapshot
 * identical to what is committed are residue, and a hundred finished tasks
 * would leave a hundred of each; anything else is the task's output, which is
 * the one thing a teardown must not be able to cost — and the same guarantee a
 * jj workspace gets for free, since forgetting one leaves its commits where
 * they were.
 */
export const forgetGitWorktree = async (
  repo: string,
  branch: string,
  path: string,
  baseCommit?: string,
): Promise<string[]> => {
  const git = (...args: string[]) => run("git", ["-C", repo, ...args]);
  const rev = async (spec: string) => {
    const r = await git("rev-parse", "-q", "--verify", spec);
    return r.code === 0 ? r.out.trim() : undefined;
  };

  const common = await git("rev-parse", "--git-common-dir");
  if (common.code !== 0) return [];
  const dir = common.out.trim();
  const admin = `${dir.startsWith("/") ? dir : `${repo}/${dir}`}/worktrees`;
  try {
    for await (const entry of Deno.readDir(admin)) {
      if (!entry.isDirectory) continue;
      const points = await Deno.readTextFile(`${admin}/${entry.name}/gitdir`).catch(() => "");
      if (points.trim() !== `${path}/.git`) continue;
      await Deno.remove(`${admin}/${entry.name}`, { recursive: true }).catch(() => {});
    }
  } catch {
    // no worktrees directory: nothing was ever added, or it is already gone
  }

  const kept: string[] = [];
  const tip = await rev(`refs/heads/${branch}^{commit}`);
  let branchKept = false;
  if (tip) {
    if (baseCommit && tip === baseCommit) {
      await git("branch", "-D", branch);
    } else {
      branchKept = true;
      const ahead = baseCommit
        ? await git("rev-list", "--count", `${baseCommit}..${tip}`)
        : undefined;
      const n = ahead?.code === 0 ? Number(ahead.out.trim()) : undefined;
      kept.push(
        `branch ${branch}${n === undefined ? "" : ` (${n} commit${n === 1 ? "" : "s"} on it)`}`,
      );
    }
  }

  const ref = snapshotRef(branch);
  const snapshot = await rev(`${ref}^{tree}`);
  if (snapshot) {
    const committed = await rev(`${branchKept ? tip : baseCommit ?? tip}^{tree}`);
    if (committed && committed === snapshot) await git("update-ref", "-d", ref);
    else kept.push(`${ref} (work that was never committed)`);
  }
  return kept;
};

// ---------------------------------------------------------------------------
// what the agents are told

/**
 * What the working directory is, how the change in it is read, and how work
 * gets recorded — the three things that differ between the two and that an
 * agent cannot work out from inside. Appended to every agent turn rather than
 * written into the bundled prompts, so a graph somebody wrote for their own
 * repo gets it too, and so those prompts can say "the diff" and "one commit"
 * and be right under either.
 *
 * The git half names what is shared because that is the part with
 * consequences: a worktree looks like a private clone and is not one. It says
 * what `git diff` leaves out because a reviewer handed a diff with the new
 * files missing reviews half a change and cannot know it.
 */
export const workspaceNote = (task: TaskRecord): string | undefined => {
  const vcs = vcsOf(task);
  if (!vcs) return undefined;
  if (vcs === "jj") {
    return `The working directory is a jujutsu (jj) workspace of the operator's repository — this
repo is jj, not git. The \`.git\` beside it holds no history and is not the
project's; it exists so nix can tell source from build output. jj records the
working copy as a commit by itself, so there is nothing to stage: \`jj diff\` is
this task's change as the operator and every later node read it, and
\`jj describe -m "..."\` is how that commit gets its message.`;
  }
  const base = task.baseCommit ? `${task.baseCommit.slice(0, 12)} (also $AF_BASE)` : "$AF_BASE";
  return `The working directory is a git worktree of the operator's repository, on a branch
made for this task${
    task.workspace ? `, \`${task.workspace}\`` : ""
  }, cut from ${base}. Only the checked-out files are
this task's alone: branches, remotes and config belong to the repository, so
what changes there changes for the operator too. \`git diff $AF_BASE\` is this
task's change as the operator and every later node read it, and it shows what
git tracks — a file you create is not in it until it is added, and work is on
the record once it is committed to this branch.`;
};
