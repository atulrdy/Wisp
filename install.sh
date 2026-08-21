#!/usr/bin/env bash
set -e

INSTALL_DIR="$HOME/.claude/hooks/wisp"
PLIST_DST="$HOME/Library/LaunchAgents/com.wisp.plist"
SETTINGS="$HOME/.claude/settings.json"

echo ""
echo "  ✦ Wisp installer"
echo "  A floating orb that shows what Claude is doing — in plain English."
echo ""

# ── 1. API key ────────────────────────────────────────────────────────────────
echo "Wisp uses any one of: Gemini (free), Groq (free), OpenAI, or Anthropic."
echo "Get a free Gemini key at: https://aistudio.google.com"
echo ""
echo "Paste your key(s) below. Press Enter to skip any you don't have."
echo ""

read -rp "  Gemini API key    : " GEMINI_KEY
read -rp "  Groq API key      : " GROQ_KEY
read -rp "  OpenAI API key    : " OPENAI_KEY
read -rp "  Anthropic API key : " ANTHROPIC_KEY

if [[ -z "$GEMINI_KEY" && -z "$GROQ_KEY" && -z "$OPENAI_KEY" && -z "$ANTHROPIC_KEY" ]]; then
  echo ""
  echo "  ⚠  No keys provided. Wisp will use the built-in lookup table instead of AI."
  echo "  You can add keys later at: $INSTALL_DIR/ai-keys.env"
fi

# ── 2. Compile the floating orb ───────────────────────────────────────────────
echo ""
echo "  Compiling wisp-ball (needs Xcode Command Line Tools)..."
if ! command -v swiftc &>/dev/null; then
  echo ""
  echo "  ✗ swiftc not found. Install Xcode Command Line Tools:"
  echo "    xcode-select --install"
  exit 1
fi

swiftc wisp.swift -o wisp-ball
echo "  ✓ wisp-ball compiled"

# ── 3. Install files ──────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cp wisp.py   "$INSTALL_DIR/wisp.py"
cp wisp-ball "$INSTALL_DIR/wisp-ball"
cp VERSION   "$INSTALL_DIR/VERSION"
chmod +x "$INSTALL_DIR/wisp-ball"

# Write ai-keys.env (only lines with a value)
KEYS_FILE="$INSTALL_DIR/ai-keys.env"
{
  [[ -n "$GEMINI_KEY"    ]] && echo "GEMINI_API_KEY=$GEMINI_KEY"
  [[ -n "$GROQ_KEY"      ]] && echo "GROQ_API_KEY=$GROQ_KEY"
  [[ -n "$OPENAI_KEY"    ]] && echo "OPENAI_API_KEY=$OPENAI_KEY"
  [[ -n "$ANTHROPIC_KEY" ]] && echo "ANTHROPIC_API_KEY=$ANTHROPIC_KEY"
} > "$KEYS_FILE"
chmod 600 "$KEYS_FILE"
echo "  ✓ files installed to $INSTALL_DIR"

# ── 4. LaunchAgent ────────────────────────────────────────────────────────────
sed "s|WISP_INSTALL_DIR|$INSTALL_DIR|g" com.wisp.plist > "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load   "$PLIST_DST"
echo "  ✓ LaunchAgent started (wisp-ball will auto-start on login)"

# ── 5. Register Claude Code hook ──────────────────────────────────────────────
HOOK_CMD="python3 $INSTALL_DIR/wisp.py"

if [[ ! -f "$SETTINGS" ]]; then
  echo '{}' > "$SETTINGS"
fi

# Use Python to safely merge the hook into settings.json
python3 - "$SETTINGS" "$HOOK_CMD" <<'PYEOF'
import sys, json

path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

hook_entry = {"type": "command", "command": cmd}
hooks = cfg.setdefault("hooks", {})
pre   = hooks.setdefault("PreToolUse", [])

# Check if already registered
for group in pre:
    for h in group.get("hooks", []):
        if h.get("command") == cmd:
            print("  ✓ hook already registered")
            sys.exit(0)

pre.append({"matcher": "", "hooks": [hook_entry]})
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("  ✓ hook registered in Claude Code")
PYEOF

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "  ✦ Wisp is running. The orb will appear whenever Claude asks permission."
echo "  Click the orb to dismiss it."
echo ""
