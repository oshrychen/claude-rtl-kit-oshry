# Versions

| Component | Source | Commit / version | Date |
|---|---|---|---|
| Patch engine + macOS scripts | https://github.com/liorshaya/claude-desktop-rtl | tag v0.2.21 = `b57f4d8` (Merge fix/macos-patch-atomicity) | 2026-08-16 |
| Code-tab user-turn fix | liorshaya/claude-desktop-rtl PR #3 (nioasoft:feat/claude-code-surface) | `04a9f2f` — kept as `patches/0001-code-tab-surface.patch` | 2026-08-29 |
| Verified against Claude Desktop (macOS) | claude.com/download | 2.2553.0 | 2026-09-18 |
| Verified against Claude Desktop (Linux) | apt `downloads.claude.ai/claude-desktop/apt/stable` | 2.110.1 (Electron 44.2.0), Ubuntu 26.04 | 2026-09-18 |

`source/claude-desktop-rtl` = upstream `b57f4d8` with the patch applied, copied without
`.git`, `dist/`, `node_modules/`. Test suite at that state: 606 passing.
