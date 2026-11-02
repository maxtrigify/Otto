'use strict';

// Teams: a room of bots with a brief, members, an orchestrator and a permission mode, as the
// Mac's Create/Edit team sheet sets up. The room itself is a "group" thread on the host RPC.
const Teams = (() => {
  const $ = (id) => document.getElementById(id);
  let roster = [];
  let editing = null; // team details being edited, or null when creating
  let selected = new Set();
  let hooks = { onError: () => {}, saved: () => {}, deleted: () => {} };

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  };

  function renderMembers() {
    const list = $('team-members');
    list.replaceChildren();
    for (const bot of roster) {
      const on = selected.has(bot.id);
      const row = el('button', `team-member ${on ? 'on' : ''}`.trim());
      row.type = 'button';
      row.append(Icons.icon(on ? 'checkmark.circle' : 'circle', 15), Icons.face(bot.name, 22));
      const text = el('span', 'team-member-text');
      text.append(el('strong', '', `${bot.name}  @${bot.handle}`), el('span', '', bot.jobTitle || bot.provider));
      row.append(text);
      row.addEventListener('click', () => {
        if (on) selected.delete(bot.id);
        else selected.add(bot.id);
        renderMembers();
      });
      list.append(row);
    }
    if (roster.length < 2) list.append(el('p', 'dialog-hint', 'A team needs at least two bots. Hire another first.'));

    const members = roster.filter((bot) => selected.has(bot.id));
    const lead = $('team-lead');
    const current = lead.value;
    lead.replaceChildren();
    for (const bot of members) {
      const option = el('option', '', `${bot.name} (@${bot.handle})`);
      option.value = bot.id;
      lead.append(option);
    }
    if (members.some((bot) => bot.id === current)) lead.value = current;
    $('team-lead-label').hidden = members.length < 2;
    $('team-save').disabled = members.length < 2;
    renderMentions();
  }

  /** Members named in the brief join the team, and @ suggestions complete names. */
  function adoptMentions() {
    const text = $('team-instructions').value.toLowerCase();
    let changed = false;
    for (const bot of roster) {
      if (!selected.has(bot.id) && new RegExp(`@${bot.handle}\\b`).test(text)) {
        selected.add(bot.id);
        changed = true;
      }
    }
    if (changed) renderMembers();
    else renderMentions();
  }

  function renderMentions() {
    const box = $('team-mentions');
    box.replaceChildren();
    const text = $('team-instructions').value;
    const partial = text.match(/@(\w*)$/);
    if (!partial) return;
    for (const bot of roster.filter((candidate) => candidate.handle.startsWith(partial[1].toLowerCase()))) {
      const chip = el('button', 'mention-chip', `@${bot.handle}`);
      chip.type = 'button';
      chip.addEventListener('click', () => {
        $('team-instructions').value = text.slice(0, text.length - partial[0].length) + `@${bot.handle} `;
        $('team-instructions').focus();
        adoptMentions();
      });
      box.append(chip);
    }
  }

  function permissionHint() {
    $('team-permission-hint').textContent =
      $('team-permission').value === 'unrestricted'
        ? 'Team turns run without asking you to approve each step.'
        : 'Team turns may stop and wait for your approval.';
  }

  /** Opens the sheet to create a team, or to edit `teamID`. */
  async function open(teamID = null) {
    try {
      roster = await window.otto.desktop('teams.roster');
      editing = teamID ? await window.otto.desktop('teams.get', { id: teamID }) : null;
    } catch (error) {
      hooks.onError(error);
      return;
    }
    selected = new Set(editing?.memberProfileIDs ?? []);
    $('team-dialog-title').textContent = editing ? 'Edit team' : 'Create a team';
    $('team-dialog-sub').textContent = editing
      ? 'Change the name, brief, members, lead and permissions.'
      : 'Name the group, say how it works, and pick who leads. @mention members in the brief.';
    $('team-name').value = editing?.name ?? '';
    $('team-instructions').value = editing?.instructions ?? '';
    // Teams run unattended by default; approving every step defeats the point of a team.
    $('team-permission').value = editing ? editing.permissionMode ?? '' : 'unrestricted';
    $('team-save').textContent = editing ? 'Save changes' : 'Create team';
    $('team-delete').hidden = !editing;
    renderMembers();
    if (editing?.orchestratorProfileID) $('team-lead').value = editing.orchestratorProfileID;
    permissionHint();
    $('team-dialog').showModal();
  }

  async function submit(action) {
    if (action === 'delete' && editing) {
      if (!confirm('Delete this team? Its members stay hired.')) return;
      try {
        await window.otto.desktop('teams.delete', { id: editing.id });
        hooks.deleted(editing);
      } catch (error) {
        hooks.onError(error);
      }
      return;
    }
    if (action !== 'save') return;
    const params = {
      name: $('team-name').value.trim() || null,
      instructions: $('team-instructions').value.trim() || null,
      memberProfileIDs: [...selected],
      orchestratorProfileID: $('team-lead').value || null,
      permissionMode: $('team-permission').value || null,
    };
    try {
      const team = editing
        ? await window.otto.desktop('teams.update', { id: editing.id, ...params })
        : await window.otto.desktop('teams.create', params);
      hooks.saved(team);
    } catch (error) {
      hooks.onError(error);
    }
  }

  function wire() {
    $('team-instructions').addEventListener('input', adoptMentions);
    $('team-permission').addEventListener('change', permissionHint);
    $('team-form').addEventListener('submit', (event) => submit(event.submitter?.value));
  }

  return {
    open,
    wire,
    configure(next) {
      hooks = { ...hooks, ...next };
    },
  };
})();
