# novum-tracker — Claude Code plugin

Coding-time tracking for [Novum Startup](https://novumstartup.com), packaged
as a Claude Code plugin (works in the CLI and the desktop app). Replaces the
manual `~/.claude/settings.json` hook setup.

## Install

Inside Claude Code:

```
/plugin marketplace add NovumStartup/novum-tracker
/plugin install novum-tracker@novumstartup
```

Then connect it — no key needed:

```
/novum-tracker:connect
```

That device-pairs: it shows a short code, you approve it at
[novumstartup.com/connect](https://novumstartup.com/connect) in a logged-in
browser, and the key is delivered straight to this machine. For CI or manual
setups you can still pass a key minted on **Account → Integrations →
AI coding tools**: `/novum-tracker:connect cf_yourkeyhere`.

(Self-hosted instances: `/novum-tracker:connect https://your-instance`, or
`/novum-tracker:connect cf_yourkeyhere https://your-instance` with a key.)

Check liveness anytime with `/novum-tracker:status`.

## What it sends (privacy)

Heartbeats fire at most about once per minute while you actively use Claude
Code, plus a flush when a turn ends. Each heartbeat contains only:

| Field | Example |
| --- | --- |
| editor | `claude-code` |
| branch | `feature/login` |
| workspaceFolder | `my-repo` (basename only) |
| duration | `150` seconds |
| timestamp | ISO 8601 |
| gitRemoteUrl | `https://github.com/org/repo.git` |
| commitHash / commitAuthorEmail | HEAD commit info |

**Never sent:** prompts, model output, diffs, file contents, file paths.

Scope which repos ever send anything by setting
`NEONPOD_TRACK_REMOTES="org/repo other-org/"` in
`~/.config/neonpod/heartbeat.env` — when set, non-matching repos (and
non-git directories) send nothing at all.

## Uninstall

```
/plugin uninstall novum-tracker@novumstartup
```

Then optionally delete `~/.config/neonpod/heartbeat.env` and revoke the API
key on the Account page.

## Release checklist (maintainers)

Both hook scripts are verbatim copies of their chronoforge upstreams
(which the app also serves): `hooks/heartbeat.sh` ←
`scripts/coding-tool-heartbeat.sh` (`/install/heartbeat.sh`) and
`hooks/session-check.sh` ← `scripts/coding-tool-session-check.sh`
(`/install/session-check.sh`). Per release:

1. `diff` each bundled script against its chronoforge upstream — the only
   allowed delta is the copy's UPSTREAM header block.
2. Copy verbatim if upstream changed; re-add the headers.
3. Bump `version` in `.claude-plugin/plugin.json` **and** the repo-root
   `.claude-plugin/marketplace.json` (they must agree).
4. `claude plugin validate .` from this directory, then push `main` as
   `novumstartup-bot`. Users pick the release up via `/plugin update
   novum-tracker` or the periodic marketplace refresh.

Hook wiring note: `SessionStart` (self-check) must stay SYNCHRONOUS — its
`systemMessage` warning renders at session start; async loses it.
`SessionEnd` must stay `NEONPOD_LOCAL_ONLY=1` — its hook budget is not
guaranteed to fit a network call; the spool drains on the next send.
`DirectoryAdded` is documented upstream but rejected by the 2.1.218
validator's schema — add it alongside `CwdChanged` once the fleet's CLI
accepts the key.
