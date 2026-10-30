// Finds the agent CLIs on this machine. ottod only launches absolute executable paths, and
// apps started from a desktop launcher do not see the PATH a terminal would, so the login
// shell's PATH is recovered once and handed to ottod (and through it to every agent).
'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const isWindows = process.platform === 'win32';

const AGENTS = [
  { id: 'claude', name: 'Claude Code', command: 'claude', blurb: 'Anthropic' },
  { id: 'codex', name: 'Codex', command: 'codex', blurb: 'OpenAI' },
  { id: 'pi', name: 'Pi', command: 'pi', blurb: 'Any provider' },
  { id: 'shell', name: 'Terminal', command: null, blurb: 'Plain shell' },
];

function loginEnvironment() {
  const env = { ...process.env };
  if (isWindows) return env;
  const shell = process.env.SHELL || '/bin/bash';
  try {
    const marker = '__OTTO_PATH__';
    const output = execFileSync(shell, ['-ilc', `printf '${marker}%s${marker}' "$PATH"`], {
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const match = output.match(new RegExp(`${marker}(.*)${marker}`));
    if (match && match[1]) env.PATH = match[1];
  } catch {
    // Fall back to the launcher's PATH plus the usual install locations.
  }
  const extras = [path.join(os.homedir(), '.local/bin'), '/usr/local/bin', '/opt/homebrew/bin'];
  env.PATH = [env.PATH, ...extras].filter(Boolean).join(path.delimiter);
  return env;
}

function findExecutable(command, env) {
  const extensions = isWindows ? (env.PATHEXT || '.EXE;.CMD;.BAT').split(';') : [''];
  for (const directory of (env.PATH || env.Path || '').split(path.delimiter)) {
    if (!directory) continue;
    for (const extension of extensions) {
      const candidate = path.join(directory, command + extension.toLowerCase());
      const upper = path.join(directory, command + extension);
      for (const file of new Set([candidate, upper])) {
        try {
          const stat = fs.statSync(file);
          if (stat.isFile() && (isWindows || (stat.mode & 0o111) !== 0)) return file;
        } catch {}
      }
    }
  }
  return null;
}

function defaultShell(env) {
  if (isWindows) {
    const root = env.SystemRoot || 'C:\\Windows';
    const pwsh = findExecutable('pwsh', env);
    return pwsh || path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  }
  return env.SHELL && fs.existsSync(env.SHELL) ? env.SHELL : '/bin/bash';
}

/** Agents with their resolved executable, or `available: false` with an install hint. */
function discoverAgents(env) {
  return AGENTS.map((agent) => {
    const executable = agent.command ? findExecutable(agent.command, env) : defaultShell(env);
    return { ...agent, executable, available: Boolean(executable) };
  });
}

module.exports = { loginEnvironment, discoverAgents, findExecutable };
