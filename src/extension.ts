import * as vscode from "vscode";
import { execSync } from "child_process";

const HEARTBEAT_MS = 2 * 60 * 1000;

// Module-scoped so deactivate() can flush a final heartbeat.
let lastActivity = Date.now();
let lastHeartbeatAt = Date.now();
let sessionSeconds = 0;
let intervalHandle: ReturnType<typeof setInterval> | undefined;
let statusBar: vscode.StatusBarItem | undefined;

export function activate(context: vscode.ExtensionContext) {
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusBar = status;
  status.command = "novum.showOutput";
  status.text = "$(circle-outline) Novum: 0h 0m";
  status.tooltip = "Novum Startup IDE tracking";
  status.show();

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

  type GitInfo = {
    branch?: string;
    gitRemoteUrl?: string;
    commitHash?: string;
    commitAuthorEmail?: string;
  };

  function gitExec(cmd: string, cwd: string): string | undefined {
    try {
      return execSync(cmd, {
        cwd,
        encoding: "utf-8",
        timeout: 2000,
        stdio: ["ignore", "pipe", "ignore"],
      }).trim() || undefined;
    } catch {
      return undefined;
    }
  }

  function getGitInfo(): GitInfo {
    const wsFolder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!wsFolder) return {};
    return {
      branch: gitExec("git rev-parse --abbrev-ref HEAD", wsFolder),
      gitRemoteUrl: gitExec("git config --get remote.origin.url", wsFolder),
      commitHash: gitExec("git rev-parse HEAD", wsFolder),
      commitAuthorEmail: gitExec("git log -1 --format=%ae", wsFolder),
    };
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

    const now = Date.now();
    const elapsed = Math.floor((now - lastHeartbeatAt) / 1000);
    const maxDuration = Math.floor(HEARTBEAT_MS / 1000);
    const durationSec = Math.min(Math.max(elapsed, 1), maxDuration);

    const editor = vscode.env.appName.toLowerCase().includes("cursor")
      ? "cursor"
      : vscode.env.appName.toLowerCase().includes("visual studio code")
        ? "vscode"
        : "other";

    const folder =
      vscode.workspace.workspaceFolders?.[0]?.name ??
      vscode.workspace.workspaceFolders?.[0]?.uri.fsPath.split(/[/\\]/).pop() ??
      "workspace";

    let file: string | undefined;
    let language: string | undefined;
    const active = doc ?? vscode.window.activeTextEditor?.document;
    if (active && !excluded(vscode.workspace.asRelativePath(active.uri))) {
      file = vscode.workspace.asRelativePath(active.uri);
      language = active.languageId;
    }

    const git = getGitInfo();

    try {
      const res = await fetch(`${base}/api/ide/heartbeat`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-API-Key": apiKey,
        },
        body: JSON.stringify({
          editor,
          language: language ?? null,
          file: file ?? null,
          branch: git.branch ?? null,
          workspaceFolder: folder,
          duration: durationSec,
          timestamp: new Date().toISOString(),
          gitRemoteUrl: git.gitRemoteUrl ?? null,
          commitHash: git.commitHash ?? null,
          commitAuthorEmail: git.commitAuthorEmail ?? null,
        }),
      });
      if (res.status === 429) {
        status.text = "$(error) Novum: rate limited";
        return;
      }
      if (!res.ok) {
        status.text = "$(error) Novum: error";
        return;
      }
      lastHeartbeatAt = now;
      sessionSeconds += durationSec;
      const h = Math.floor(sessionSeconds / 3600);
      const m = Math.floor((sessionSeconds % 3600) / 60);
      const dot = isIdle() ? "$(circle-outline)" : "$(circle-filled)";
      status.text = `${dot} Novum: ${h}h ${m}m`;
    } catch {
      status.text = "$(error) Novum: offline";
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
        "Novum Startup: heartbeats run every 2 minutes on any IDE activity (typing, cursor movement, scrolling, file switches, window focus) and on file save.",
      );
    }),
  );
}

export function deactivate() {}
