# ollama-scripts

![hello](./hello.png)

Point coding CLIs at [ollama.com](https://ollama.com)'s cloud models using one `OLLAMA_API_KEY`. No `ollama launch`, no sign-in.

It is however recommended that you have the tool `curl -fsSL https://ollama.com/install.sh | sh` installed so you can take advantage of local models.

## Setup

```sh
export OLLAMA_API_KEY=...   # your ollama.com key (put in shell rc)
# set -gx OLLA...           # if you're on fish
mise install                # fetch gum (model chooser)
mise run check              # verify key + API reachable
mise run install            # symlink launchers into ~/.local/bin
```

`mise run uninstall` removes the symlinks. No mise? `brew install gum` and
`ln -s "$PWD"/ollama-{claude,codex,pi,codex-app,claude-app,gui} ~/.local/bin/`.

## Launchers

| Command | Harness | Endpoint |
|---|---|---|
| `ollama-claude` | Claude Code | Anthropic `/v1/messages` (Bearer) |
| `ollama-codex` | Codex CLI | OpenAI `/v1/responses` |
| `ollama-pi` | pi | OpenAI `/v1/chat/completions` |

Pick a model three ways (first wins): `--model NAME`, `OLLAMA_MODEL=NAME`, or the
`gum` chooser (prefilled with your last pick, remembered per-harness in
`~/.config/ollama-scripts/`). Everything else is passed through:

```sh
ollama-codex --model qwen3-coder:480b exec "fix the failing test"
ollama-claude                       # chooser, then normal claude session
```

## Desktop apps

Same idea for the GUIs, mirroring `ollama launch` but keyed straight to
ollama.com — no sign-in. **macOS only.**

| Command | App | How |
|---|---|---|
| `ollama-codex-app` | Codex desktop | ephemeral `codex app -c …`, touches no files |
| `ollama-claude-app` | Claude Desktop | writes Claude's 3p gateway profile (backed up), then relaunches |
| `ollama-gui` | Ollama app | launches `Ollama.app` with `OLLAMA_API_KEY` in its env |

```sh
ollama-codex-app --model glm-5.2        # picks a model like the CLIs
ollama-claude-app                       # switch Claude Desktop to Ollama Cloud
ollama-claude-app --restore             # switch it back
ollama-gui                              # open the Ollama app with cloud access
```

`ollama-claude-app` edits Claude Desktop's config under
`~/Library/Application Support/Claude{,-3p}/`; each touched file is copied to
`<file>.ollama-scripts.bak` before the first change, and `--restore` reverts the
profile.

## Adding your harness

Each launcher is ~10 lines. Copy one, then:

1. **Source the lib** and require the key:
   ```sh
   source "$(dirname "$(readlink -f "$0")")/lib.sh"
   _require_key
   ```
1. **Resolve the model** — parses `--model`, else chooser/`OLLAMA_MODEL`:
   ```sh
   _resolve_model <harness-name> "$@"   # sets $MODEL and array $REST (leftover args)
   ```
   `<harness-name>` is just the key for the last-used file.
1. **Wire the endpoint** to `https://ollama.com` using `$OLLAMA_API_KEY`, then
   `exec` the tool with `$MODEL` and the passthrough args:
   ```sh
   exec yourtool --model "$MODEL" "${REST[@]+"${REST[@]}"}"
   ```
