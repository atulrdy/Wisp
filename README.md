# ✦ Wisp

A floating orb that shows what Claude Code is doing — in plain English, before it happens.

Whenever Claude asks for permission to run a command, read a file, or make a change, Wisp pops up a small translucent bubble explaining what's going on in plain English. No code, no jargon — something a non-technical person can actually read.

---

## What it looks like

> **Claude wants to…**
> search package.json for which version of React is installed

---

## Requirements

- macOS
- [Claude Code](https://claude.ai/code)
- Xcode Command Line Tools (`xcode-select --install`)
- One free API key (any of the below)

## API keys (pick one — all have free tiers)

| Provider | Get a key |
|----------|-----------|
| **Gemini** (recommended) | [aistudio.google.com](https://aistudio.google.com) |
| **Groq** | [console.groq.com](https://console.groq.com) |
| OpenAI | [platform.openai.com](https://platform.openai.com) |
| Anthropic | [console.anthropic.com](https://console.anthropic.com) |

No key at all? Wisp still works — it falls back to a built-in lookup table.

---

## Install

```bash
git clone https://github.com/your-org/wisp
cd wisp
bash install.sh
```

The installer will:
1. Ask for your API key(s)
2. Compile the floating orb
3. Install files to `~/.claude/hooks/wisp/`
4. Register the Claude Code hook
5. Start the orb (auto-restarts on login)

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.wisp.plist
rm ~/Library/LaunchAgents/com.wisp.plist
rm -rf ~/.claude/hooks/wisp
```

Then remove the hook from `~/.claude/settings.json`.

---

## How it works

Wisp hooks into Claude Code's `PreToolUse` event. Before any tool runs, the hook sends the tool name and input to an AI model which returns a plain-English completion of "Claude wants to…". The result is posted to a tiny local HTTP server running inside the floating Swift ball, which displays it on screen.

Provider priority: Gemini → Groq → OpenAI → Anthropic → built-in lookup table.
