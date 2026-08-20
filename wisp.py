#!/usr/bin/env python3
import sys, json, subprocess, shlex, socket, os, time, urllib.request, re

# Load API keys from file (works even when macOS doesn't pass env vars to app subprocesses)
_KEYS_FILE = os.path.expanduser("~/.claude/hooks/ai-keys.env")
if os.path.exists(_KEYS_FILE):
    for _line in open(_KEYS_FILE):
        _line = _line.strip()
        if _line and not _line.startswith("#") and "=" in _line:
            _k, _v = _line.split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip())

# Verbs that carry a complete meaning on their own (no subject needed)
_SCRIPT_STANDALONE = {
    "seed": "Seed the database",
    "migrate": "Run database migrations",
    "migration": "Run database migrations",
    "setup": "Set up the project",
    "deploy": "Deploy the app",
    "clean": "Clean up generated files",
    "init": "Initialize the project",
    "initialize": "Initialize the project",
    "backup": "Back up data",
    "restore": "Restore saved data",
    "populate": "Populate the database",
    "index": "Rebuild the search index",
    "reindex": "Rebuild the search index",
    "lint": "Check code style",
    "typecheck": "Check TypeScript types",
    "type-check": "Check TypeScript types",
    "type_check": "Check TypeScript types",
}
# Verbs that need a subject from the remaining filename words
_SCRIPT_VERB = {
    "build": "Build", "generate": "Generate", "gen": "Generate",
    "export": "Export", "import": "Import", "sync": "Sync",
    "fetch": "Fetch", "process": "Process", "analyze": "Analyze",
    "analyse": "Analyze", "update": "Update", "check": "Check",
    "validate": "Validate", "fix": "Fix", "convert": "Convert",
    "upload": "Upload", "download": "Download", "reset": "Reset",
    "create": "Create", "delete": "Delete", "merge": "Merge",
    "publish": "Publish", "load": "Load", "transform": "Transform",
    "watch": "Watch", "format": "Format", "compile": "Compile",
    "report": "Generate a report for", "scrape": "Scrape",
    "run": "Run", "start": "Start", "test": "Test",
    "install": "Install",
}


def humanize_script(path):
    """'scripts/generate_types.py' → 'Generate types'"""
    base = os.path.splitext(os.path.basename(path))[0]
    words = [w for w in re.split(r'[_\-\d]+', base.lower()) if w and len(w) > 1]
    if not words:
        return None
    verb = words[0]
    subject = " ".join(words[1:])
    if verb in _SCRIPT_STANDALONE:
        return _SCRIPT_STANDALONE[verb]
    if verb in _SCRIPT_VERB:
        label = _SCRIPT_VERB[verb]
        return f"{label} {subject}" if subject else f"{label} something"
    # Unknown verb — just capitalize the words
    return " ".join(w.capitalize() for w in words) or None

# Map folder/file basenames to friendly names
FRIENDLY = {
    ".": "the project", "src": "the source folder", "lib": "the library folder",
    "dist": "the build folder", "build": "the build folder", "out": "the output folder",
    ".next": "the Next.js cache", "node_modules": "the packages folder",
    ".cache": "a cache folder", "coverage": "the test reports folder",
    "tmp": "a temp folder", "temp": "a temp folder", ".git": "the git history",
    "package.json": "the project config", "package-lock.json": "the lockfile",
    "yarn.lock": "the lockfile", ".env": "the environment settings",
    ".env.local": "the local environment settings",
    "tsconfig.json": "the TypeScript config", "vite.config.ts": "the build config",
    "tailwind.config.js": "the styling config", "next.config.js": "the app config",
    "README.md": "the readme", "Dockerfile": "the container config",
}

EXT_LABELS = {
    ".tsx": "React component", ".jsx": "React component",
    ".ts": "TypeScript file", ".js": "JavaScript file",
    ".css": "stylesheet", ".scss": "stylesheet", ".module.css": "stylesheet",
    ".py": "Python file", ".rb": "Ruby file", ".go": "Go file",
    ".json": "config file", ".yaml": "config file", ".yml": "config file",
    ".toml": "config file", ".env": "environment settings",
    ".md": "documentation", ".mdx": "documentation",
    ".html": "web page", ".svg": "icon or graphic",
    ".sql": "database script", ".sh": "shell script",
}

GIT = {
    "push": "Upload your code to the remote repository",
    "pull": "Download the latest code from the remote",
    "clone": "Download a full copy of a repository",
    "commit": "Save the current changes as a checkpoint",
    "reset": "Undo recent changes",
    "merge": "Combine another branch into this one",
    "rebase": "Replay commits on top of another branch",
    "stash": "Temporarily set aside uncommitted changes",
    "fetch": "Check the remote for new commits",
    "checkout": "Switch branches or restore a file",
    "branch": "Create, list, or delete branches",
    "tag": "Create a version label",
    "rm": "Remove files from git tracking",
    "log": "Show the commit history",
    "diff": "Show what changed in the code",
    "status": "Check which files have changed",
    "init": "Set up a new git repository",
}
NPM = {
    "install": "Install the project's packages",
    "run": "Run a project script",
    "build": "Build the project for production",
    "test": "Run the tests",
    "start": "Start the app",
    "publish": "Publish the package online",
    "uninstall": "Remove a package",
    "ci": "Install packages from the lockfile",
    "update": "Upgrade installed packages",
}
BREW = {
    "install": "Install a program", "uninstall": "Remove a program",
    "update": "Refresh available programs list", "upgrade": "Upgrade installed programs",
}
DOCKER = {
    "build": "Build a container image", "run": "Start a container",
    "stop": "Stop a running container", "pull": "Download a container image",
    "push": "Upload a container image", "exec": "Run a command inside a container",
    "rm": "Remove stopped containers", "rmi": "Remove container images",
    "compose": "Manage multi-container setup",
}


def friendly_path(path):
    """Turn a file path into plain English. './dist' → 'the build folder'."""
    # os.path.basename handles ./ and ../ prefixes correctly without mangling dotfiles
    base = os.path.basename(path.strip().rstrip('/')) or path.strip()
    if base in FRIENDLY:
        return FRIENDLY[base]
    _, ext = os.path.splitext(base)
    label = EXT_LABELS.get(ext.lower(), "")
    if label:
        name = base[: -len(ext)].lstrip('.')  # strip leading dot for display only
        return f"the {name} {label}"
    return f'"{base}"' if base else "a file"


def translate_bash(cmd):
    cmd = cmd.strip()
    if not cmd:
        return "Run a terminal command"
    try:
        parts = shlex.split(cmd)
    except ValueError:
        parts = cmd.split()
    if not parts:
        return "Run a terminal command"

    first = parts[0]
    if first in ("sudo", "env", "npx", "bunx") and len(parts) > 1:
        first, parts = parts[1], parts[1:]
    # Strip KEY=VALUE env var prefixes (e.g. NODE_ENV=production npm ...)
    while "=" in first and len(parts) > 1:
        first, parts = parts[1], parts[1:]

    sub = parts[1] if len(parts) > 1 else ""
    arg = parts[2] if len(parts) > 2 else ""
    # Exclude shell operators and flag-like tokens from non_flags
    _SHELL_OPS = {"&&", "||", ";", "|", ">", ">>", "<"}
    non_flags = [a for a in parts[1:] if not a.startswith("-") and a not in _SHELL_OPS]

    if first == "rm":
        targets = [friendly_path(t) for t in non_flags] if non_flags else ["some files"]
        return f"Delete {', '.join(targets)}"
    if first == "mkdir":
        base = os.path.basename(non_flags[0].rstrip('/')) if non_flags else ""
        return f'Create a "{base}" folder' if base and base not in FRIENDLY else f"Create {FRIENDLY.get(base, 'a new folder')}"
    if first == "cp":
        src = friendly_path(non_flags[0]) if non_flags else "a file"
        dst = friendly_path(non_flags[-1]) if len(non_flags) > 1 else "a new location"
        return f"Copy {src} to {dst}"
    if first == "mv":
        src = friendly_path(non_flags[0]) if non_flags else "a file"
        dst = friendly_path(non_flags[-1]) if len(non_flags) > 1 else "a new location"
        return f"Move {src} to {dst}"
    if first == "git":
        desc = GIT.get(sub, f"Run git {sub}")
        if sub == "push" and "--force" in parts:
            desc = "Force-upload your code (overwriting remote history)"
        elif sub == "clone" and arg:
            desc = f"Download a copy of {arg.split('/')[-1].replace('.git', '')}"
        return desc
    if first in ("npm", "yarn", "pnpm", "bun"):
        pkg = next((a for a in non_flags[1:] if not a.startswith("http")), None)
        if sub in ("install", "add") and pkg:
            return f"Install the {pkg} package"
        if sub == "run" and arg and not arg.startswith("-"):
            return f'Run the "{arg}" script'
        return NPM.get(sub, f"Run {first} {sub}")
    if first in ("pip", "pip3", "uv"):
        if sub == "install":
            return f"Install {arg or 'Python packages'}"
        if sub == "uninstall":
            return f"Remove the {arg or 'Python package'}"
        return "Manage Python packages"
    if first == "brew":
        if sub in ("install", "uninstall") and non_flags:
            verb = "Install" if sub == "install" else "Remove"
            return f"{verb} {non_flags[-1]}"
        return BREW.get(sub, f"Run brew {sub}")
    if first == "docker":
        if sub == "compose":
            return f"Docker Compose: {arg or 'manage containers'}"
        return DOCKER.get(sub, f"Run docker {sub}")
    if first in ("curl", "wget"):
        url = next((a for a in parts if a.startswith("http")), "")
        return f"Download from {url.split('/')[2]}" if url else "Download from the internet"
    if first == "chmod":
        return f"Change permissions on {friendly_path(non_flags[-1]) if non_flags else 'a file'}"
    if first in ("python", "python3"):
        script = next((a for a in non_flags if a.endswith(".py")), None)
        if script:
            desc = humanize_script(script)
            return desc if desc else f"Run {friendly_path(script)}"
        # python3 -m module
        _m_idx = next((i for i, a in enumerate(parts) if a == "-m"), None)
        if _m_idx and _m_idx + 1 < len(parts):
            mod = parts[_m_idx + 1]
            _MODULES = {
                "pytest": "Run the test suite", "unittest": "Run unit tests",
                "venv": "Create a virtual environment",
                "http.server": "Start a local web server",
                "black": "Format Python code", "mypy": "Check types",
                "flake8": "Check code style", "isort": "Sort imports",
                "json.tool": "Format JSON output",
            }
            return _MODULES.get(mod, f"Run the {mod} module")
        # Inline -c code: show the snippet
        inline = next((parts[i + 1] for i, a in enumerate(parts) if a == "-c" and i + 1 < len(parts)), None)
        if inline:
            snippet = inline.strip()[:70]
            return f"Run Python code: {snippet}{'…' if len(inline) > 70 else ''}"
        return "Run a Python script"
    if first in ("tsx", "ts-node"):
        script = next((a for a in non_flags if a.endswith(".ts") or a.endswith(".mts")), None)
        if script:
            desc = humanize_script(script)
            return desc if desc else f"Run {friendly_path(script)}"
        return "Run a TypeScript file"
    if first == "node":
        script = next((a for a in non_flags if any(a.endswith(e) for e in (".js", ".mjs", ".ts", ".cjs"))), None)
        if script:
            desc = humanize_script(script)
            return desc if desc else f"Run {friendly_path(script)}"
        inline = next((parts[i + 1] for i, a in enumerate(parts) if a == "-e" and i + 1 < len(parts)), None)
        if inline:
            snippet = inline.strip()[:70]
            return f"Run JavaScript code: {snippet}{'…' if len(inline) > 70 else ''}"
        return "Run a JavaScript file"
    if first in ("kill", "pkill", "killall"):
        target = next((a for a in non_flags if not a.isdigit()), None) or "the process"
        return f"Stop {target}"
    if first == "make":
        return f"Build the project{' (' + sub + ')' if sub else ''}"
    if first == "open":
        return f"Open {friendly_path(sub)}" if sub else "Open a file or app"
    if first in ("ls", "dir"):
        target = friendly_path(non_flags[0]) if non_flags else "the current folder"
        return f"List files in {target}"
    if first in ("cat", "less", "head", "tail"):
        return f"Read {friendly_path(non_flags[0]) if non_flags else 'a file'}"
    if first in ("grep", "rg", "ag", "ripgrep"):
        pattern = non_flags[0] if non_flags else ""
        where = friendly_path(non_flags[-1]) if len(non_flags) > 1 else "the project"
        return f'Search for "{pattern}" in {where}' if pattern else "Search for text in files"
    if first in ("sed", "awk"):
        return "Find and replace text in files"
    if first == "find":
        return "Search for files"
    if first in ("ssh", "scp", "rsync"):
        return "Connect to or sync with a remote server"
    if first in ("tar", "unzip", "gzip", "zip"):
        return f"{'Extract' if any(a in parts for a in ['-x', '--extract', 'x']) else 'Package'} files"
    if first in ("touch",):
        return f"Create {friendly_path(non_flags[0]) if non_flags else 'a new file'}"
    if first == "echo" and ">" in parts:
        idx = parts.index(">")
        target = parts[idx + 1] if idx + 1 < len(parts) else "a file"
        return f"Write to {friendly_path(target)}"

    # Known npx/bunx tools that didn't match earlier patterns
    _NPX_TOOLS = {
        "prettier": "Format code", "eslint": "Check code for issues",
        "jest": "Run the test suite", "vitest": "Run the test suite",
        "tsc": "Compile TypeScript", "ts-node": "Run a TypeScript file",
        "tsx": "Run a TypeScript file",
        "prisma": "Manage the database",
        "drizzle-kit": "Manage the database schema",
        "knex": "Run database migrations", "sequelize": "Run database migrations",
        "tailwindcss": "Build CSS styles", "postcss": "Process CSS",
        "webpack": "Bundle the app", "rollup": "Bundle the app",
        "esbuild": "Bundle the app", "turbo": "Run a Turbo task",
        "playwright": "Run browser tests", "cypress": "Run browser tests",
        "storybook": "Start Storybook", "vite": "Start the dev server",
        "next": "Run the Next.js app", "nuxt": "Run the Nuxt app",
        "astro": "Run the Astro app", "expo": "Run the Expo app",
    }
    if first in _NPX_TOOLS:
        desc = _NPX_TOOLS[first]
        # Only show target if it's an actual file/folder, not a subcommand word
        file_target = next((a for a in non_flags if "/" in a or "." in a), None)
        if file_target:
            return f"{desc} in {friendly_path(file_target)}"
        return desc

    # Last resort: at least name the tool and its main target
    target = non_flags[-1] if non_flags else ""
    if target and not target.startswith("-"):
        return f'Run "{first}" on {friendly_path(target)}'
    return f'Run "{first}"'


def translate(tool_name, inp):
    if tool_name == "Bash":
        return translate_bash(inp.get("command", ""))
    if tool_name == "Edit":
        path = inp.get("file_path", "")
        return f"Edit {friendly_path(path)}" if path else "Edit a file"
    if tool_name in ("Write", "NotebookEdit"):
        path = inp.get("file_path", "")
        return f"Create or update {friendly_path(path)}" if path else "Write a file"
    if tool_name == "MultiEdit":
        path = inp.get("file_path", "")
        return f"Make edits to {friendly_path(path)}" if path else "Edit a file"
    if tool_name == "WebFetch":
        url = inp.get("url", "")
        host = url.split("/")[2] if url.count("/") >= 2 else url
        return f"Read a page from {host}" if host else "Fetch a web page"
    if tool_name == "WebSearch":
        return f"Search the web for: {inp.get('query', '')}"
    if tool_name == "Read":
        path = inp.get("file_path", "")
        return f"Read {friendly_path(path)}" if path else "Read a file"
    return f"Use {tool_name}"


BALL = os.path.expanduser('~/wisp/wisp-ball')
PORT = 7891


def ball_running():
    try:
        socket.create_connection(('localhost', PORT), timeout=0.3).close()
        return True
    except OSError:
        return False


def start_ball():
    subprocess.Popen(
        [BALL],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    for _ in range(10):
        time.sleep(0.2)
        if ball_running():
            return


def post(message):
    data = json.dumps({'message': message}).encode()
    req = urllib.request.Request(
        f'http://localhost:{PORT}',
        data=data,
        headers={'Content-Type': 'application/json'},
    )
    urllib.request.urlopen(req, timeout=1)


PROMPT = (
    "An AI coding assistant is about to perform this action:\n"
    "Tool: {tool_name}\n"
    "Details: {tool_input}\n\n"
    "Complete this sentence for a non-technical person: 'Claude wants to...'\n"
    "Write only the part after 'Claude wants to' — start with a verb, be specific, mention the actual filename or search term if relevant.\n"
    "Keep it to one sentence. No jargon, no flags, no technical terms — but DO include specific names (files, terms being searched, etc.) so it's clear what exactly is happening.\n"
    "Good completions (just the part after 'Claude wants to...'):\n"
    "- 'delete the old compiled app files so the project can be rebuilt from scratch'\n"
    "- 'download all the libraries this project needs to run'\n"
    "- 'search wisp.py for where the API key is loaded'\n"
    "- 'save a snapshot of recent changes with the note: fix Gemini timeout'\n"
    "- 'read the first 50 lines of package.json to check which version of React is installed'\n"
    "Reply with ONLY the sentence completion, nothing else. Do not include 'Claude wants to' in your reply."
)


def _llm_call(url, headers, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
    resp = urllib.request.urlopen(req, timeout=5)
    return json.loads(resp.read())


def translate_with_ai(tool_name, tool_input):
    prompt = PROMPT.format(
        tool_name=tool_name,
        tool_input=json.dumps(tool_input, ensure_ascii=False)
    )

    # Try each provider in order — first key found wins
    # 1. Gemini (Google)
    gemini_key = os.environ.get("GEMINI_API_KEY", "") or os.environ.get("GOOGLE_API_KEY", "")
    if gemini_key:
        d = _llm_call(
            f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={gemini_key}",
            {"content-type": "application/json"},
            {"contents": [{"parts": [{"text": prompt}]}],
             "generationConfig": {"maxOutputTokens": 300, "thinkingConfig": {"thinkingBudget": 0}}},
        )
        candidates = d.get("candidates", [])
        if not candidates:
            log(f"Gemini empty candidates: {json.dumps(d)[:200]}")
            return None
        text = candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "").strip()
        if not text:
            log(f"Gemini empty text, finishReason={candidates[0].get('finishReason')}")
            return None
        return text.strip('"').strip("'")

    # 2. Groq (free tier, fast, OpenAI-compatible)
    groq_key = os.environ.get("GROQ_API_KEY", "")
    if groq_key:
        d = _llm_call(
            "https://api.groq.com/openai/v1/chat/completions",
            {"content-type": "application/json", "authorization": f"Bearer {groq_key}"},
            {"model": "llama-3.1-8b-instant", "max_tokens": 60,
             "messages": [{"role": "user", "content": prompt}]},
        )
        return d["choices"][0]["message"]["content"].strip().strip('"').strip("'") or None

    # 2. OpenAI
    openai_key = os.environ.get("OPENAI_API_KEY", "")
    if openai_key:
        d = _llm_call(
            "https://api.openai.com/v1/chat/completions",
            {"content-type": "application/json", "authorization": f"Bearer {openai_key}"},
            {"model": "gpt-4o-mini", "max_tokens": 60,
             "messages": [{"role": "user", "content": prompt}]},
        )
        return d["choices"][0]["message"]["content"].strip().strip('"').strip("'") or None

    # 3. Anthropic
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "") or os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
    if anthropic_key:
        is_oauth = not os.environ.get("ANTHROPIC_API_KEY")
        headers = {"content-type": "application/json", "anthropic-version": "2023-06-01"}
        if is_oauth:
            headers["authorization"] = f"Bearer {anthropic_key}"
            headers["anthropic-beta"] = "oauth-2025-04-20"
        else:
            headers["x-api-key"] = anthropic_key
        d = _llm_call(
            "https://api.anthropic.com/v1/messages",
            headers,
            {"model": "claude-haiku-4-5", "max_tokens": 60,
             "messages": [{"role": "user", "content": prompt}]},
        )
        return d["content"][0]["text"].strip().strip('"').strip("'") or None

    # 4. Ollama (local, free, no key needed)
    try:
        d = _llm_call(
            "http://localhost:11434/api/chat",
            {"content-type": "application/json"},
            {"model": "llama3.2", "stream": False, "messages": [{"role": "user", "content": prompt}]},
        )
        return d["message"]["content"].strip().strip('"').strip("'") or None
    except Exception:
        pass

    return None  # no provider available → fall back to lookup table


LOG = os.path.expanduser("~/.claude/hooks/wisp-debug.log")

def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass

try:
    data = json.load(sys.stdin)
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    description = None
    try:
        description = translate_with_ai(tool_name, tool_input)
        log(f"AI ok: {description!r}")
    except Exception as e:
        log(f"AI FAIL ({tool_name}): {type(e).__name__}: {e}")

    if not description:
        description = translate(tool_name, tool_input)
        log(f"Fallback: {description!r}")

    if not ball_running():
        start_ball()
    post(description)
except Exception as e:
    log(f"Outer fail: {e}")
