# Novum Startup Tracker (VS Code / Cursor)

Sends **heartbeats** from your editor to your [Novum Startup](https://novumstartup.com)
server so your team can see IDE activity on **Dashboard → IDE integration**, map
workspaces to projects, and optionally convert ranges into time entries.

## Install

- **VS Code** — search **"Novum Startup Tracker"** in the Extensions view, or
  install from the [Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=novumstartup.novum-tracker).
- **Cursor / VSCodium / Windsurf** — search the Extensions view (these editors use
  the [Open VSX Registry](https://open-vsx.org/extension/novumstartup/novum-tracker)).
- **Claude Code (CLI + desktop app)** — this repo also ships a Claude Code
  plugin (see [`claude-plugin/`](claude-plugin/)):

  ```
  /plugin marketplace add NovumStartup/novum-tracker
  /plugin install novum-tracker@novumstartup
  /novum-tracker:connect
  ```

  (`connect` with no arguments device-pairs via a code you approve in the
  browser; pass `cf_yourkeyhere` instead for CI/manual setups.)

## Setup

The easiest path: open **Novum Startup → Settings → API keys** in the web app and
click **Connect to VS Code / Cursor**. That generates a key and hands it to the
extension automatically.

To configure manually, open **Settings → Extensions → Novum Startup** (or edit
`settings.json` under the `novum.*` keys):

| Key | Purpose |
| --- | --- |
| `novum.apiKey` | API key from the web app (shown once when generated). |
| `novum.apiUrl` | Server origin, e.g. `https://novumstartup.com` (no trailing slash). |
| `novum.enabled` | Master toggle. |
| `novum.idleThresholdMinutes` | Pause interval heartbeats after this many minutes without typing (default 5). |
| `novum.excludePatterns` | Glob patterns; matching paths skip file/language in heartbeats. |

The status bar shows **Novum: Xh Ym** and an active/idle indicator.

## What gets sent

Each heartbeat is a small JSON payload to `POST <apiUrl>/api/ide/heartbeat`,
authenticated with your API key. It includes: editor name, active file path
(relative to the workspace, unless excluded), language id, git branch, latest
commit hash + author email, workspace folder name, a duration in seconds, a
timestamp, and the audit fields added in 1.1.0 — a truncated hash of the
checkout root (`repoKey`, never the path itself), the repo's root commit
(omitted for shallow clones), a random per-install `machineId` (never the
hostname), a per-beat `eventId`, the editor `sessionId`, and the extension
version. Heartbeats only fire while you're active; files matching
`novum.excludePatterns` are omitted.

Heartbeats that can't be delivered (offline, server restart, rate limit)
queue in a local spool inside the extension's global storage and send when
the server is reachable again. Closing the window flushes the final interval
to the same queue.

## Development

```bash
npm install
npm run compile
```

Press **F5** in VS Code to launch an Extension Development Host and test against
your Novum Startup server.
