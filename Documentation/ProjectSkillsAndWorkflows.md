# Project skills and workflows

Agents read their setup from the folder they start in: `AGENTS.md`, `CLAUDE.md`, Claude Code
skills and subagents in `.claude/`, and anything a tool such as
[Buildline](https://github.com/julianoczkowski/buildline) installs. A new session in a project
that has a source folder starts in that folder, so the repository's own setup applies to every
agent you open there.

## Use a repository's skills and workflows

1. Add the setup to the repository, for example `cd your-project && npx buildline`.
2. In Otto, click **New**, choose **Project → New project…**, and add the repository folder as
   its source folder. Existing projects keep their source folders.
3. Pick an agent (Claude Code, Codex, Cursor, Otto Harness and so on). The session starts in the
   project's first source folder that still exists.

The folder is fixed when the session starts. Switching the chat to another project later changes
its project context, not the folder the running agent works in; start a new session for that.
Sessions in a project without a source folder, and helpers beside documents or dashboards, still
start in the Otto workspace.

## Shared across agents

- **Every agent:** `AGENTS.md` in the repository. Buildline writes its pipeline there, and its
  stations are plain markdown under `.buildline/stations/`, so you can ask any agent to "follow
  `.buildline/stations/buildline.md`".
- **Claude Code:** project skills and subagents in the repository's `.claude/`, which Buildline
  installs, plus your personal skills in `~/.claude/skills/`.
- **One project, many agents:** each session you open in the project starts in the same folder,
  so they share the same files, specs and progress logs.

## Limits

- Bots keep their own working folder (the Otto workspace). Use a session in the project for
  repository workflows.
- Otto does not install skill packages itself. Use the tool's own installer, such as
  `npx buildline`, in the repository.
