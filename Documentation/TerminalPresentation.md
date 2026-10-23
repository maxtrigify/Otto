# Terminal presentation in Chat

Agent commands run under Otto's supervisor without automatically creating work-panel tabs.
This applies even when a browser has already opened the panel, and to every space.

Previously, Chat kept the panel closed when a command started but registered a tab for every
terminal on appearance and whenever terminal nodes changed. This still exposed clone, install,
and other routine commands in an already-open browser panel.

`ChatWorkspaceView.applyTerminalReveal` creates a terminal tab when the person explicitly
opens it. Commands waiting for the person continue to appear through `waitingTerminalNotices`
and the transcript's `TerminalWaitingCard`; its Open button reveals the terminal. A person
can still explicitly open the agent's terminal from the work-surface picker.

Closing a terminal tab does not stop its process or delete its stored terminal node. Chat
does not restore command tabs on appearance or recreate a closed tab when another command
starts. No storage migration is needed: command tabs are view state, separate from the
persisted terminal nodes and supervisor processes.

The updated app must be loaded for this behavior to take effect. Do not restart an older
running app while agents are working merely to apply this presentation change.
