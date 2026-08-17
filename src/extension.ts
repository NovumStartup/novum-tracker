import * as vscode from "vscode";
import { execFile, execFileSync } from "child_process";
import { randomUUID } from "crypto";
import * as fs from "fs";
import * as path from "path";

import {
  DRAIN_BATCH,
  MAX_SPOOL_AGE_SECONDS,
  MAX_SPOOL_LINES,
  buildSpoolLine,
  clampDuration,
  classifyStatus,
  parseSpoolLine,
  repoKeyFromToplevel,
  rootCommitFromRevList,
  trimSpoolLines,
} from "./core";

const HEARTBEAT_MS = 2 * 60 * 1000;
const MAX_DURATION_SEC = Math.floor(HEARTBEAT_MS / 1000);
const ORPHAN_RECLAIM_MS = 10 * 60 * 1000;
const FETCH_TIMEOUT_MS = 10_000;
const MACHINE_ID_KEY = "novum.machineId";

type GitInfo = {
  branch?: string;
  gitRemoteUrl?: string;
  commitHash?: string;
  commitAuthorEmail?: string;
  repoKey?: string;
};

// Module-scoped so deactivate() can spool a final beat without the async
// machinery: the last computed git identity is reused there (a subprocess in
// deactivate risks outliving the host's shutdown budget).
let lastActivity = Date.now();
let lastHeartbeatAt = Date.now();
let sessionSeconds = 0;
let intervalHandle: ReturnType<typeof setInterval> | undefined;
let statusBar: vscode.StatusBarItem | undefined;
let storageDir: string | undefined;
let machineId: string | undefined;
let clientVersion: string | undefined;
let lastGitInfo: GitInfo | undefined;

function editorName(): string {
  const app = vscode.env.appName.toLowerCase();
  if (app.includes("cursor")) return "cursor";
  if (app.includes("visual studio code")) return "vscode";
  return "other";
}

function workspaceFolderName(): string {
  return (
    vscode.workspace.workspaceFolders?.[0]?.name ??
    vscode.workspace.workspaceFolders?.[0]?.uri.fsPath.split(/[/\\]/).pop() ??
    "workspace"
  );
}

// ---- spool + shared clock --------------------------------------------------
//
// Files live in the extension's globalStorage dir, which every window of this
// editor shares. The spool holds beats that could not be delivered (each
// still claims its interval — lastHeartbeatAt advances either way, so the
// next live beat never re-claims a spooled span) and drains only after a
// successful live send, oldest first, a bounded batch per run. Each line
// carries its own eventId; the server dedupes per (user, eventId), so a
// retry after a timed-out-but-committed send acknowledges as a duplicate
// instead of double-storing.

function spoolPath(): string | undefined {
  return storageDir ? path.join(storageDir, "spool.jsonl") : undefined;
}

function readDroppedTotal(file: string): number {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf-8")) as {
      droppedTotal?: unknown;
    };
    return Number.isSafeInteger(parsed.droppedTotal) && (parsed.droppedTotal as number) > 0
      ? (parsed.droppedTotal as number)
      : 0;
  } catch {
    return 0;
  }
}

function countDropped(n: number): void {
  if (!storageDir || n <= 0) return;
  const file = path.join(storageDir, "spool-dropped.json");
  try {
    fs.writeFileSync(
      file,
      JSON.stringify({
        droppedTotal: readDroppedTotal(file) + n,
        lastDropAt: new Date().toISOString(),
      }) + "\n",
    );
  } catch {
    // Best-effort accounting; never let bookkeeping break tracking.
  }
}

function spoolAppend(epochSec: number, payloadJson: string): void {
  const spool = spoolPath();
  if (!spool) return;
  try {
    fs.appendFileSync(spool, buildSpoolLine(epochSec, payloadJson));
    const lines = fs.readFileSync(spool, "utf-8").split("\n").filter(Boolean);
    if (lines.length > MAX_SPOOL_LINES) {
      const { kept, dropped } = trimSpoolLines(lines, MAX_SPOOL_LINES);
      fs.writeFileSync(spool, kept.join("\n") + "\n");
      countDropped(dropped);
    }
  } catch {
    // A failed append loses one beat; there is no safer place to put it.
  }
}

// The editor's shared clock across windows — the conservation clamp's source.
// Read-modify-write between windows is unsynchronized on purpose; the worst
// case is one interval of over-claim, the same bound the shell client accepts.
function readGlobalLastFire(): number {
  if (!storageDir) return 0;
  try {
    const parsed = JSON.parse(
      fs.readFileSync(path.join(storageDir, "global-clock.json"), "utf-8"),
    ) as { lastFire?: unknown };
    return Number.isSafeInteger(parsed.lastFire) && (parsed.lastFire as number) > 0
      ? (parsed.lastFire as number)
      : 0;
  } catch {
    return 0;
  }
}

function advanceClocks(nowMs: number): void {
  lastHeartbeatAt = nowMs;
  if (!storageDir) return;
  try {
    fs.writeFileSync(
      path.join(storageDir, "global-clock.json"),
      JSON.stringify({ lastFire: Math.floor(nowMs / 1000) }) + "\n",
    );
  } catch {
    // Losing the shared clock only weakens the cross-window clamp.
  }
}

async function postBeat(
  base: string,
  apiKey: string,
  payloadJson: string,
): Promise<{ status: number; body: Record<string, unknown> | null }> {
  try {
    const res = await fetch(`${base}/api/ide/heartbeat`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": apiKey },
      body: payloadJson,
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    let body: Record<string, unknown> | null = null;
    try {
      body = (await res.json()) as Record<string, unknown>;
    } catch {
      body = null;
    }
    return { status: res.status, body };
  } catch {
    return { status: 0, body: null };
  }
}

function reclaimOrphans(spool: string): void {
  // A drainer killed mid-loop (window closed, host shutdown) leaves its
  // renamed claim behind with every unsent beat inside. Sweep stale claims
  // back into the live spool — age-gated so an ACTIVE drainer in another
  // window is never robbed; beats it already posted re-send and the server's
  // eventId dedupe ACKs them as duplicates.
  try {
    const dir = path.dirname(spool);
    const prefix = path.basename(spool) + ".draining.";
    for (const name of fs.readdirSync(dir)) {
      if (!name.startsWith(prefix)) continue;
      const full = path.join(dir, name);
      try {
        if (Date.now() - fs.statSync(full).mtimeMs < ORPHAN_RECLAIM_MS) continue;
        fs.appendFileSync(spool, fs.readFileSync(full, "utf-8"));
        fs.unlinkSync(full);
      } catch {
        // Another window may have reclaimed it first.
      }
    }
  } catch {
    // No spool dir yet.
  }
}

async function drainSpool(base: string, apiKey: string): Promise<void> {
  const spool = spoolPath();
  if (!spool) return;
  reclaimOrphans(spool);
  const nowSec = Math.floor(Date.now() / 1000);
  // rename-claim: atomically take the whole file so a concurrent drainer in
  // another window skips. New failures append to a fresh live spool. The
  // claim name carries pid + epoch so it can never collide with an orphan.
  const claim = `${spool}.draining.${process.pid}.${nowSec}`;
  try {
    fs.renameSync(spool, claim);
  } catch {
    return; // No spool, or another window claimed it.
  }
  let sent = 0;
  let dropped = 0;
  let transient = false;
  const remainder: string[] = [];
  let lines: string[] = [];
  try {
    lines = fs.readFileSync(claim, "utf-8").split("\n").filter(Boolean);
  } catch {
    lines = [];
  }
  for (const line of lines) {
    if (transient || sent + dropped >= DRAIN_BATCH) {
      remainder.push(line);
      continue;
    }
    const parsed = parseSpoolLine(line);
    if (!parsed) {
      dropped++;
      continue;
    }
    if (nowSec - parsed.epoch > MAX_SPOOL_AGE_SECONDS) {
      dropped++;
      continue;
    }
    const { status } = await postBeat(base, apiKey, parsed.payload);
    switch (classifyStatus(status)) {
      case "ok":
        sent++;
        break;
      case "transient":
        // Put it back and stop burning the batch on a down API.
        remainder.push(line);
        transient = true;
        break;
      case "permanent":
        dropped++;
        break;
    }
  }
  try {
    if (remainder.length > 0) {
      fs.appendFileSync(spool, remainder.join("\n") + "\n");
    }
    fs.unlinkSync(claim);
  } catch {
    // A failed unlink leaves the claim for the orphan sweep; its already-sent
    // beats replay as duplicate-ACKs.
  }
  countDropped(dropped);
}

export function activate(context: vscode.ExtensionContext) {
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusBar = status;
  status.command = "novum.showOutput";
  status.text = "$(circle-outline) Novum: 0h 0m";
  status.tooltip = "Novum Startup IDE tracking";
  status.show();

  storageDir = context.globalStorageUri.fsPath;
  try {
    fs.mkdirSync(storageDir, { recursive: true });
  } catch {
    storageDir = undefined;
  }
  clientVersion = String(context.extension.packageJSON.version ?? "");

  // Random installation id, minted once per machine. Deliberately NOT in
  // setKeysForSync: Settings Sync copying it to a second machine would
  // collapse two installations into one stream and defeat the server's
  // per-(editor, machine) dark-stream detection — a dead laptop must not be
  // masked by a live desktop. Never derived from the hostname (hostnames
  // rename, collide, and dictionary-reverse).
  const storedId = context.globalState.get<string>(MACHINE_ID_KEY);
  if (storedId && /^[0-9a-f-]{8,64}$/.test(storedId)) {
    machineId = storedId;
  } else {
    machineId = randomUUID();
    void context.globalState.update(MACHINE_ID_KEY, machineId);
  }

  // URI handler: vscode://novumstartup.novum-tracker/setup?key=xxx&url=xxx
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri: vscode.Uri) {
        if (uri.path !== "/setup") return;
        const params = new URLSearchParams(uri.query);
        const key = params.get("key");
        const url = params.get("url");
        if (!key) {
          void vscode.window.showErrorMessage("Novum Startup: setup link is missing the API key.");
          return;
        }
        const cfg = vscode.workspace.getConfiguration("novum");
        await cfg.update("apiKey", key, vscode.ConfigurationTarget.Global);
        if (url) {
          await cfg.update("apiUrl", url.replace(/\/$/, ""), vscode.ConfigurationTarget.Global);
        }
        void vscode.window.showInformationMessage(
          "Novum Startup connected! Heartbeats will start automatically.",
        );
      },
    }),
  );

  const markActive = () => {
    lastActivity = Date.now();
  };

  // Typing
  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument(markActive),
  );
  // Cursor movement / selection (includes clicks within a file)
  context.subscriptions.push(
    vscode.window.onDidChangeTextEditorSelection(markActive),
  );
  // Switching between files
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor(markActive),
  );
  // Splits / new visible editors
  context.subscriptions.push(
    vscode.window.onDidChangeVisibleTextEditors(markActive),
  );
  // Scrolling within a file
  context.subscriptions.push(
    vscode.window.onDidChangeTextEditorVisibleRanges(markActive),
  );
  // Focus-gained counts as activity; losing focus does not.
  context.subscriptions.push(
    vscode.window.onDidChangeWindowState((state) => {
      if (state.focused) markActive();
    }),
  );

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => {
      void sendHeartbeat(doc, "save");
    }),
  );

  function isIdle(): boolean {
    const cfg = vscode.workspace.getConfiguration("novum");
    const mins = cfg.get<number>("idleThresholdMinutes") ?? 5;
    return Date.now() - lastActivity > mins * 60 * 1000;
  }

  function globToRegex(pattern: string): RegExp {
    let re = "";
    let i = 0;
    while (i < pattern.length) {
      const c = pattern[i];
      if (c === "*" && pattern[i + 1] === "*") {
        re += ".*";
        i += pattern[i + 2] === "/" ? 3 : 2;
      } else if (c === "*") {
        re += "[^/]*";
        i++;
      } else if (c === "?") {
        re += "[^/]";
        i++;
      } else {
        re += c!.replace(/[.+^${}()|[\]\\]/g, "\\$&");
        i++;
      }
    }
    return new RegExp(`^${re}$`);
  }

  function excluded(rel: string): boolean {
    const cfg = vscode.workspace.getConfiguration("novum");
    const patterns = cfg.get<string[]>("excludePatterns") ?? [];
    return patterns.some((p) => {
      if (!p) return false;
      return globToRegex(p).test(rel);
    });
  }

  function gitExec(args: string[], cwd: string, timeout = 2000): Promise<string | undefined> {
    return new Promise((resolve) => {
      execFile(
        "git",
        args,
        { cwd, encoding: "utf-8", timeout, windowsHide: true },
        (err, stdout) => {
          resolve(err ? undefined : stdout.trim() || undefined);
        },
      );
    });
  }

  async function getGitInfo(): Promise<GitInfo> {
    const wsFolder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!wsFolder) return {};
    const [branch, gitRemoteUrl, commitHash, commitAuthorEmail, toplevel] =
      await Promise.all([
        gitExec(["rev-parse", "--abbrev-ref", "HEAD"], wsFolder),
        gitExec(["config", "--get", "remote.origin.url"], wsFolder),
        gitExec(["rev-parse", "HEAD"], wsFolder),
        gitExec(["log", "-1", "--format=%ae"], wsFolder),
        gitExec(["rev-parse", "--show-toplevel"], wsFolder),
      ]);
    return {
      branch,
      gitRemoteUrl,
      commitHash,
      commitAuthorEmail,
      repoKey: toplevel ? repoKeyFromToplevel(toplevel) : undefined,
    };
  }

  async function getRootCommit(hasRepo: boolean): Promise<string | undefined> {
    // The repo's root commit — the same object in every clone, worktree and
    // fork, and unchanged by an org rename or repo transfer, all of which
    // break the remote URL. A SHALLOW clone must send nothing:
    // `rev-list --max-parents=0` returns the grafted boundary commit there —
    // stable, plausible and WRONG, the one failure mode that could attribute
    // one repo's time to another. NOT cached, deliberately: a checkout path
    // can be deleted and re-cloned from a different repo between beats, and a
    // path-keyed cache would keep binding the old repo's identity.
    const wsFolder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!wsFolder || !hasRepo) return undefined;
    const shallow = await gitExec(["rev-parse", "--is-shallow-repository"], wsFolder);
    if (shallow !== "false") return undefined;
    const revList = await gitExec(["rev-list", "--max-parents=0", "HEAD"], wsFolder, 5000);
    return revList ? rootCommitFromRevList(revList) ?? undefined : undefined;
  }

  function buildPayload(input: {
    durationSec: number;
    nowMs: number;
    git: GitInfo;
    rootCommit?: string;
    doc?: vscode.TextDocument;
  }): string {
    let file: string | undefined;
    let language: string | undefined;
    const active = input.doc ?? vscode.window.activeTextEditor?.document;
    if (active && !excluded(vscode.workspace.asRelativePath(active.uri))) {
      file = vscode.workspace.asRelativePath(active.uri);
      language = active.languageId;
    }
    return JSON.stringify({
      editor: editorName(),
      language: language ?? null,
      file: file ?? null,
      branch: input.git.branch ?? null,
      workspaceFolder: workspaceFolderName(),
      duration: input.durationSec,
      timestamp: new Date(input.nowMs).toISOString(),
      gitRemoteUrl: input.git.gitRemoteUrl ?? null,
      commitHash: input.git.commitHash ?? null,
      commitAuthorEmail: input.git.commitAuthorEmail ?? null,
      repoKey: input.git.repoKey ?? null,
      rootCommit: input.rootCommit ?? null,
      eventId: randomUUID(),
      sessionId: vscode.env.sessionId.slice(0, 128),
      clientVersion: clientVersion || null,
      machineId: machineId ?? null,
    });
  }

  function claimedDuration(nowMs: number): number {
    const elapsedSec = Math.floor((nowMs - lastHeartbeatAt) / 1000);
    const globalLast = readGlobalLastFire();
    const globalElapsedSec =
      globalLast > 0 ? Math.floor(nowMs / 1000) - globalLast : null;
    return clampDuration(elapsedSec, globalElapsedSec, MAX_DURATION_SEC);
  }

  function showSession(prefix: string, suffix = "") {
    const h = Math.floor(sessionSeconds / 3600);
    const m = Math.floor((sessionSeconds % 3600) / 60);
    status.text = `${prefix} Novum: ${h}h ${m}m${suffix}`;
  }

  async function sendHeartbeat(
    doc: vscode.TextDocument | undefined,
    reason: string,
  ) {
    const cfg = vscode.workspace.getConfiguration("novum");
    if (!cfg.get<boolean>("enabled")) return;
    const apiKey = cfg.get<string>("apiKey")?.trim();
    const base = cfg.get<string>("apiUrl")?.replace(/\/$/, "") ?? "";
    if (!apiKey || !base) {
      status.text = "$(warning) Novum: set apiKey + apiUrl";
      return;
    }
    if (isIdle() && reason !== "save") return;

    const nowMs = Date.now();
    const durationSec = claimedDuration(nowMs);
    const git = await getGitInfo();
    lastGitInfo = git;
    const rootCommit = await getRootCommit(Boolean(git.repoKey));
    const payload = buildPayload({ durationSec, nowMs, git, rootCommit, doc });

    const { status: httpStatus, body } = await postBeat(base, apiKey, payload);
    if (classifyStatus(httpStatus) === "ok") {
      advanceClocks(nowMs);
      sessionSeconds += durationSec;
      // Attribution feedback: a 200 with attributed=false means the beat
      // landed but counts toward no project. A replay ACK (reason
      // "duplicate") is not a fresh attribution verdict — ignore it.
      if (body?.reason !== "duplicate" && body?.attributed === false) {
        showSession("$(warning)", " · unattributed");
        status.tooltip =
          "Heartbeats are arriving but attach to no project. Map this folder " +
          "under Dashboard → IDE integration in Novum Startup.";
      } else {
        showSession(isIdle() ? "$(circle-outline)" : "$(circle-filled)");
        status.tooltip = "Novum Startup IDE tracking";
      }
      await drainSpool(base, apiKey);
      return;
    }

    // The beat is NOT lost: it goes to the spool with its interval claimed,
    // and drains after the next successful send. Permanent rejections are
    // classified (and counted as dropped) at drain time.
    spoolAppend(Math.floor(nowMs / 1000), payload);
    advanceClocks(nowMs);
    sessionSeconds += durationSec;
    if (httpStatus === 429) {
      showSession("$(error)", " · rate limited, queued");
    } else if (httpStatus === 0) {
      showSession("$(error)", " · offline, queued");
    } else {
      showSession("$(error)", " · error, queued");
    }
  }

  intervalHandle = setInterval(() => {
    void sendHeartbeat(vscode.window.activeTextEditor?.document, "interval");
  }, HEARTBEAT_MS);

  context.subscriptions.push({
    dispose: () => {
      if (intervalHandle) clearInterval(intervalHandle);
    },
  });

  context.subscriptions.push(
    vscode.commands.registerCommand("novum.showOutput", () => {
      void vscode.window.showInformationMessage(
        "Novum Startup: heartbeats run every 2 minutes on any IDE activity (typing, cursor movement, scrolling, file switches, window focus) and on file save. Undeliverable heartbeats queue locally and send when the server is reachable again.",
      );
    }),
  );
}

export function deactivate() {
  // Final flush, spool-only: a network call here can outlive the host's
  // shutdown budget, so the tail interval is appended to the spool (fs sync,
  // no network) and drains from the next session's first successful send —
  // the same durability design as the shell client's SessionEnd path.
  if (!storageDir || !machineId) return;
  const cfg = vscode.workspace.getConfiguration("novum");
  if (!cfg.get<boolean>("enabled")) return;
  if (!cfg.get<string>("apiKey")?.trim() || !cfg.get<string>("apiUrl")?.trim()) return;

  const nowMs = Date.now();
  const idleMins = cfg.get<number>("idleThresholdMinutes") ?? 5;
  if (nowMs - lastActivity > idleMins * 60 * 1000) return;
  const elapsedSec = Math.floor((nowMs - lastHeartbeatAt) / 1000);
  if (elapsedSec < 5) return; // A beat just went out; nothing worth claiming.

  // Reuse the last send's git identity rather than spawning subprocesses in
  // shutdown; fall back to a quick synchronous read for a window that closes
  // before its first heartbeat. rootCommit is deliberately omitted either
  // way (never cached; not worth an O(history) walk in shutdown) — the
  // spooled beat falls back to the remote / folder-map paths.
  let git = lastGitInfo;
  if (!git) {
    git = {};
    const wsFolder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (wsFolder) {
      const syncGit = (args: string[]): string | undefined => {
        try {
          return (
            execFileSync("git", args, {
              cwd: wsFolder,
              encoding: "utf-8",
              timeout: 750,
              stdio: ["ignore", "pipe", "ignore"],
              windowsHide: true,
            }).trim() || undefined
          );
        } catch {
          return undefined;
        }
      };
      const toplevel = syncGit(["rev-parse", "--show-toplevel"]);
      git = {
        branch: syncGit(["rev-parse", "--abbrev-ref", "HEAD"]),
        gitRemoteUrl: syncGit(["config", "--get", "remote.origin.url"]),
        commitHash: syncGit(["rev-parse", "HEAD"]),
        commitAuthorEmail: syncGit(["log", "-1", "--format=%ae"]),
        repoKey: toplevel ? repoKeyFromToplevel(toplevel) : undefined,
      };
    }
  }

  const globalLast = readGlobalLastFire();
  const globalElapsedSec =
    globalLast > 0 ? Math.floor(nowMs / 1000) - globalLast : null;
  const durationSec = clampDuration(elapsedSec, globalElapsedSec, MAX_DURATION_SEC);

  const payload = JSON.stringify({
    editor: editorName(),
    language: null,
    file: null,
    branch: git.branch ?? null,
    workspaceFolder: workspaceFolderName(),
    duration: durationSec,
    timestamp: new Date(nowMs).toISOString(),
    gitRemoteUrl: git.gitRemoteUrl ?? null,
    commitHash: git.commitHash ?? null,
    commitAuthorEmail: git.commitAuthorEmail ?? null,
    repoKey: git.repoKey ?? null,
    rootCommit: null,
    eventId: randomUUID(),
    sessionId: vscode.env.sessionId.slice(0, 128),
    clientVersion: clientVersion || null,
    machineId,
  });
  spoolAppend(Math.floor(nowMs / 1000), payload);
  advanceClocks(nowMs);
}
