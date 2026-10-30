# Project skills and workflows

Coding agents read their setup from the folder they start in. Claude Code reads `CLAUDE.md` and
the skills and subagents in `.claude/`; Codex reads `AGENTS.md`. Tools such as
[Buildline](https://github.com/julianoczkowski/buildline) install into those files. A new Claude
Code or Codex session in a project that has a source folder starts in that folder, so the
repository's own setup applies to it.

## Use a repository's skills and workflows

1. Add the setup to the repository, for example `cd your-project && npx buildline`.
2. In Otto, click **New**, choose **Project → New project…**, and add the repository folder as
   its source folder. Existing projects keep their source folders.
3. Pick Claude Code or Codex. The session starts in the project's first source folder that still
   exists.

The folder is fixed when the session starts. Switching the chat to another project later changes
its project context, not the folder the running agent works in; start a new session for that.
Sessions in a project without a source folder, and helpers beside documents or dashboards, still
start in the Otto workspace.

## Which agents start in the project folder

Only Claude Code and Codex. Other agents always start in the Otto workspace, because starting
them in your repository would be unsafe or would gain nothing:

- **Cursor** and **Pi** launch with their own approval turned off (`--trust --approve-mcps`,
  `--approve`), so they would trust whatever the repository configures.
- **Cursor, Kimi, Pi and Grok** receive Otto's tools through a config file Otto writes into the
  folder they start in (`.cursor/mcp.json`, `.kimi-code/mcp.json`, `.pi/mcp.json`,
  `.grok/config.toml`), which would land in your repository.
- **Otto Harness** reads none of these files, so the repository's setup would not apply anyway.

Otto keeps its own files for these sessions (pasted images, run bootstrap copies) in the Otto
workspace, not in the repository.

## Shared across agents

- **Claude Code:** `CLAUDE.md` plus project skills and subagents in the repository's `.claude/`,
  which Buildline installs, and your personal skills in `~/.claude/skills/`.
- **Codex:** `AGENTS.md` in the repository. Buildline writes its pipeline there, and its stations
  are plain markdown under `.buildline/stations/`, so you can ask either agent to "follow
  `.buildline/stations/buildline.md`".
- **One project, several sessions:** each Claude Code or Codex session you open in the project
  starts in the same folder, so they share the same files, specs and progress logs.

## Limits

- Bots keep their own working folder (the Otto workspace). Use a session in the project for
  repository workflows.
- Otto does not install skill packages itself. Use the tool's own installer, such as
  `npx buildline`, in the repository.
