# Style Preferences

### 2026-09-01 — Popup/UI copy: English + "AI agent" (never a tool name)

Type: preference

Summary:
Tailcat Manager popup copy (help/guide text) must be written in **English**, and
when it points users at an assistant for the advanced management workflow, say
**"AI agent"** — do not hard-code "pi" (or any specific tool). The user runs
several AI agents (pi, codex, claude, opencode), so tool names should not leak
into user-facing copy.

Details:
- Example applied to the slim popup: "Devices, identities, and file transfers
  are handled by an AI agent in the terminal — say “manage tailcat”." (was
  Chinese "交给 pi").
- Apply to visible popup text, manifest descriptions, and (for consistency)
  developer comments/READMEs that describe the same "handled by an AI agent"
  mechanism.

Evidence:
User instruction 2026-09-01: "弹窗的说明用英文描述，而且不只是 pi，用 ai agent 即可";
applied in `/home/max/tailcat-manager` (slim popup) across ui/Manager.qml,
manifest.json, README.md, TailcatBridge.qml.

Action:
For any Tailcat Manager (or future Omarchy widget) copy: English only; refer to
the assistant as "an AI agent", never a specific product.

Status: active
