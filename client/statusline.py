"""Claude Code statusline: context, subscription quota, cost, model.

Optional. client/install.sh copies it to ~/.claude/statusline.py; you enable it
in ~/.claude/settings.json. Every `claude` and `claude-lite` on the machine runs
it on every redraw, so it must never block and never raise.

The quota segment depends on which subscription serves the session model:

  Max (direct, or claude-* through the gateway)
      5h: 12% (2h3m) | 7d: 4% (3d2h)
      From Claude Code's own `rate_limits` input. Through the gateway these exist
      only because litellm-headers-shim re-injects the anthropic-ratelimit-*
      headers (gateway/docker-compose.yml).

  OpenCode Go (deepseek-v4.1-flash-*, glm-5.3-flash through the gateway)
      Go 5h: 5% (33m) | wk: 2% (6d15h) | mo: 2% (29d3h)
      From GET https://opencode.ai/zen/go/v1/usage -- undocumented, measured
      2026-09-14. The windows are "5-hour -- 20% of the monthly limit; weekly --
      50%; and monthly -- 100%" (opencode.ai/docs/go). Usage is account-wide:
      `?model=` returned identical numbers for two models. Same shape as Max:
      percent, then the time to reset, as the Go console shows it.

  Other gateway models (OpenRouter, pay per use)
      OpenRouter: pay per use

Choose by MODEL, not by whether `rate_limits` is present: Claude Code keeps the
last-seen Max windows in memory, so a DeepSeek turn still carries stale Max
numbers.

Go data is cached for GO_TTL seconds and refreshed by a detached copy of this
script (`--refresh-go`), so a redraw never waits on the network. The key is read
from GO_KEY_FILE (mode 0600, not in git).

Debug: set STATUSLINE_DUMP=<path> on the claude process to save the raw input.
"""
import sys, os, json, time, re

if sys.platform == "win32":
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    sys.stdout.reconfigure(encoding="utf-8")

GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
RESET = "\033[0m"

# Gateway model names served by OpenCode Go. Source of truth:
# gateway/config.yaml (entries with api_base opencode.ai).
# This list changed provider once already (2026-09-13); keep it in step.
GO_MODEL_MARKERS = ("deepseek-v4.1-flash", "glm-5.3-flash")

GO_USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
GO_KEY_FILE = os.environ.get("STATUSLINE_GO_KEY_FILE", os.path.expanduser("~/.claude/opencode-go.key"))
CACHE_DIR = os.environ.get("STATUSLINE_CACHE_DIR", os.path.expanduser("~/.cache/claude-statusline"))
GO_CACHE = os.path.join(CACHE_DIR, "go-usage.json")
GO_LOCK = GO_CACHE + ".lock"
GO_TTL = 60          # seconds before a refresh is started
GO_STALE = 600       # seconds before the cached numbers are marked stale
GO_TIMEOUT = 5       # seconds for the HTTP call, in the detached refresher only


def color_for(pct):
    if pct < 70:
        return GREEN
    if pct < 90:
        return YELLOW
    return RED


def format_remaining(seconds):
    seconds = max(0, int(seconds))
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    if days >= 1:
        return f"{days}d{hours}h"
    if hours >= 1:
        return f"{hours}h{minutes}m"
    return f"{minutes}m"


def parse_epoch(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        # Normalize millisecond epochs
        return value / 1000 if value > 1e12 else value
    if isinstance(value, str):
        # ISO 8601 -- e.g. "2026-04-16T18:30:00Z"
        try:
            from datetime import datetime
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except Exception:
            return None
    return None


def countdown(resets_at):
    epoch = parse_epoch(resets_at)
    if epoch is None:
        return ""
    return f" ({format_remaining(epoch - time.time())})"


# -- which subscription serves the session ------------------------------------

def is_gateway():
    base = os.environ.get("ANTHROPIC_BASE_URL", "")
    return bool(base) and "api.anthropic.com" not in base


def provider_for(d):
    model = d.get("model") or {}
    model_id = str(model.get("id") or "").lower()
    name = str(model.get("display_name") or "").lower()
    both = f"{model_id} {name}"
    if any(m in both for m in GO_MODEL_MARKERS):
        return "go"
    if not is_gateway():
        return "max"
    if "openrouter" in both:
        return "payg"
    if re.match(r"(claude-|opus|sonnet|haiku|fable)", model_id) or re.match(r"(opus|sonnet|haiku|fable)\b", name):
        return "max"
    return "payg"


# -- Max ----------------------------------------------------------------------

def format_quota(label, obj):
    if not obj:
        return f"{label}: --"
    pct = obj.get("used_percentage", 0) or 0
    return f"{color_for(pct)}{label}: {pct:.0f}%{countdown(obj.get('resets_at'))}{RESET}"


def max_segment(d):
    rl = d.get("rate_limits") or {}
    return f"{format_quota('5h', rl.get('five_hour'))} | {format_quota('7d', rl.get('seven_day'))}"


# -- OpenCode Go --------------------------------------------------------------

def read_go_cache():
    try:
        with open(GO_CACHE, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def start_go_refresh():
    """Start a detached refresher unless one is already running."""
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        try:
            if time.time() - os.path.getmtime(GO_LOCK) > GO_TIMEOUT * 4:
                os.remove(GO_LOCK)  # a refresher that died without cleaning up
        except FileNotFoundError:
            pass
        fd = os.open(GO_LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    except Exception:
        return
    try:
        import subprocess
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--refresh-go"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, close_fds=True,
        )
    except Exception:
        try:
            os.remove(GO_LOCK)
        except Exception:
            pass


def refresh_go():
    """Fetch Go usage and write the cache atomically. Runs detached."""
    result = {"fetched_at": time.time()}
    try:
        import urllib.request
        with open(GO_KEY_FILE, encoding="utf-8") as fh:
            key = fh.read().strip()
        req = urllib.request.Request(GO_USAGE_URL, headers={
            "Authorization": f"Bearer {key}",
            "User-Agent": "claude-statusline/1.0",
        })
        with urllib.request.urlopen(req, timeout=GO_TIMEOUT) as r:
            result["usage"] = json.loads(r.read().decode("utf-8"))["usage"]
    except FileNotFoundError:
        result["error"] = "no key"
    except Exception as e:
        result["error"] = type(e).__name__
    # Keep the last good numbers through a failed fetch, so one timeout does
    # not blank the segment; the age check marks them stale in time.
    old = read_go_cache()
    if "usage" not in result and old and "usage" in old:
        result["usage"] = old["usage"]
        result["usage_at"] = old.get("usage_at", old.get("fetched_at"))
    elif "usage" in result:
        result["usage_at"] = result["fetched_at"]
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = f"{GO_CACHE}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(result, fh)
        os.replace(tmp, GO_CACHE)
    finally:
        try:
            os.remove(GO_LOCK)
        except Exception:
            pass


def format_go_window(label, win):
    if not win:
        return f"{label}: --"
    pct = win.get("percent", 0) or 0
    status = win.get("status", "ok")
    if status != "ok":
        # Only "ok" has been seen. At a limit the docs say requests stop, or
        # fall back to the Zen balance if "Use balance" is on.
        return f"{RED}{label}: {status}{countdown(win.get('resetsAt'))}{RESET}"
    return f"{color_for(pct)}{label}: {pct:.0f}%{countdown(win.get('resetsAt'))}{RESET}"


def go_segment():
    cache = read_go_cache()
    if cache is None or time.time() - cache.get("fetched_at", 0) > GO_TTL:
        start_go_refresh()
    if not cache or "usage" not in cache:
        err = (cache or {}).get("error")
        return f"Go: -- ({err})" if err else "Go: --"
    u = cache["usage"]
    parts = [
        format_go_window("Go 5h", u.get("rolling")),
        format_go_window("wk", u.get("weekly")),
        format_go_window("mo", u.get("monthly")),
    ]
    seg = " | ".join(parts)
    if time.time() - cache.get("usage_at", 0) > GO_STALE:
        seg += " (stale)"
    return seg


# -----------------------------------------------------------------------------

def format_cost(cost_obj):
    cost = (cost_obj or {}).get("total_cost_usd") or 0
    return f"~${cost:.2f}"


def main():
    raw = sys.stdin.read()
    dump = os.environ.get("STATUSLINE_DUMP")
    if dump:
        try:
            with open(dump, "w", encoding="utf-8") as fh:
                fh.write(raw)
        except Exception:
            pass
    d = json.loads(raw)
    ctx_pct = (d.get("context_window") or {}).get("used_percentage", 0) or 0
    model = (d.get("model") or {}).get("display_name", "Claude")

    try:
        provider = provider_for(d)
        if provider == "go":
            quota = go_segment()
        elif provider == "payg":
            quota = "OpenRouter: pay per use"
        else:
            quota = max_segment(d)
    except Exception:
        quota = "quota: --"

    print(f"Context: {ctx_pct:.1f}% | {quota} | {format_cost(d.get('cost'))} | {model}", end="")


if __name__ == "__main__":
    if sys.argv[1:] == ["--refresh-go"]:
        refresh_go()
    else:
        main()
