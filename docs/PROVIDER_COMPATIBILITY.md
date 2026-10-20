# Provider compatibility

Otto probes provider versions locally and classifies them without changing provider-global configuration.

| Provider | Minimum supported | Tested range | Current local fixture |
|---|---:|---:|---:|
| Claude Code | 2.1.0 | >=2.1.0 and <3.0.0 | 2.1.187 |
| OpenAI Codex CLI | 0.100.0 | >=0.100.0 and <1.0.0 | 0.144.3 |
| Cursor CLI | calendar build | 2026.08 builds | 2026.08.04-aaa8809 |
| Kimi Code CLI | 0.34.0 | >=0.34.0 and <1.0.0 | 0.34.0 |
| OpenCode | 1.18.0 | >=1.18.0 and <2.0.0 | 1.18.15 |
| Grok Build TUI | 1.0.0 | >=1.0.0 and <2.0.0 | 1.0.3 |
| Generic shell | Configured executable | macOS system shell | system |

Versions below the minimum are reported as unsupported. Versions newer than the tested range or versions that cannot be parsed are reported as untested; Otto keeps launch available so a newly released CLI does not become an artificial outage. Diagnostics and onboarding show the same classification.

Update this matrix and its golden tests whenever provider flags, structured output, session resume, completion markers, or MCP behavior changes. Credentialed smoke tests remain a release gate.
