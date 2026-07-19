#!/usr/bin/env bash
# Undo every *persistent* change the ollama-* launchers made, returning Codex,
# Claude Desktop, and pi to their original providers.
#
# The CLI wrappers (ollama-codex, ollama-claude) are already ephemeral — they
# only touch their own subprocess env. The launchers that drive GUI/desktop
# apps must write config files (those apps can't read shell env), and ollama-pi
# edits pi's models.json. This script reverts exactly those.
#
# Each managed file is restored from its <file>.ollama-scripts.bak when present
# (an exact revert); otherwise only the keys we added are stripped.
set -euo pipefail
source "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/lib.sh"

PROVIDER="ollama-scripts"
CLAUDE_PROFILE_ID="00000000-0000-4000-8000-000000000114"

_restore_bak() {          # <file> -> restore from .bak (and drop it); 0 if done
  local f="$1" b="$1.ollama-scripts.bak"
  [ -f "$b" ] || return 1
  cp "$b" "$f"; rm -f "$b"; echo "  restored $f"
}

_quit_app() { osascript -e "tell application \"$1\" to quit" >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------- Codex desktop
CODEX="$HOME/.codex/config.toml"
if [ -f "$CODEX" ]; then
  echo "Codex:"
  _quit_app Codex
  if ! _restore_bak "$CODEX"; then
    CODEX="$CODEX" PROVIDER="$PROVIDER" python3 - <<'PY'
import os, re
p = os.environ["CODEX"]; prov = os.environ["PROVIDER"]
t = open(p).read()
t = re.sub(rf'(?ms)^\[model_providers\.{re.escape(prov)}\].*?(?=^\[|\Z)', "", t)
t = re.sub(rf'(?m)^model_provider = "{re.escape(prov)}"\n', "", t)
t = re.sub(r'(?m)^model_catalog_json = ".*ollama-scripts.*"\n', "", t)
open(p, "w").write(t.rstrip("\n") + "\n")
print("  stripped %s provider from config.toml (no backup found)" % prov)
PY
  fi
fi
rm -f "$STATE_DIR/codex-catalogue.json" 2>/dev/null || true

# --------------------------------------------------------------- Claude Desktop
CB="$HOME/Library/Application Support/Claude"
C3="$HOME/Library/Application Support/Claude-3p"
if [ -d "$CB" ] || [ -d "$C3" ]; then
  echo "Claude Desktop:"
  _quit_app Claude
  for f in \
    "$CB/claude_desktop_config.json" \
    "$C3/claude_desktop_config.json" \
    "$C3/configLibrary/_meta.json" \
    "$C3/configLibrary/$CLAUDE_PROFILE_ID.json"; do
    [ -e "$f" ] || [ -e "$f.ollama-scripts.bak" ] || continue
    _restore_bak "$f" && continue
    # No backup for this file: revert only our additions.
    F="$f" PROFILE_ID="$CLAUDE_PROFILE_ID" python3 - <<'PY'
import json, os
f = os.environ["F"]; pid = os.environ["PROFILE_ID"]
try:
    cfg = json.load(open(f))
except (FileNotFoundError, ValueError):
    raise SystemExit
name = os.path.basename(f)
if name == "_meta.json":
    if cfg.get("appliedId") == pid: cfg.pop("appliedId", None)
    cfg["entries"] = [e for e in cfg.get("entries", [])
                      if not (isinstance(e, dict) and e.get("id") == pid)]
elif name == pid + ".json":
    cfg["disableDeploymentModeChooser"] = False
    for k in ("inferenceProvider", "inferenceGatewayBaseUrl",
              "inferenceGatewayAuthScheme", "inferenceGatewayApiKey", "inferenceModels"):
        cfg.pop(k, None)
else:  # a claude_desktop_config.json
    cfg["deploymentMode"] = "1p"
with open(f, "w") as fh:
    json.dump(cfg, fh, indent=2); fh.write("\n")
print("  reverted %s (no backup found)" % f)
PY
  done
fi

# -------------------------------------------------------------------------- pi
PIM="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json"
if [ -f "$PIM" ]; then
  PIM="$PIM" python3 - <<'PY'
import json, os
p = os.environ["PIM"]
try:
    d = json.load(open(p))
except ValueError:
    raise SystemExit
provs = d.get("providers", {})
if provs.pop("ollama_cloud", None) is not None:
    with open(p, "w") as f:
        json.dump(d, f, indent=1); f.write("\n")
    print("pi:\n  removed ollama_cloud provider from models.json")
PY
fi

echo "Done. Codex / Claude Desktop / pi are back on their original providers."
echo "Reopen the apps to pick up the reverted config."
