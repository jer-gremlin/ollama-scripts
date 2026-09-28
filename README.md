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
`ln -s "$PWD"/ollama-{claude,codex,pi,hermes,oh-my-cli,oh-my-cli-app,codex-app,claude-app,gui} ~/.local/bin/`.

## Launchers

| Command | Harness | Endpoint |
|---|---|---|
| `ollama-claude` | Claude Code | Anthropic `/v1/messages` (Bearer) |
| `ollama-codex` | Codex CLI | OpenAI `/v1/responses` |
| `ollama-pi` | pi | OpenAI `/v1/chat/completions` |
| `ollama-hermes` | Hermes agent TUI | OpenAI `/v1/chat/completions` (ollama-cloud) |
| `ollama-oh-my-cli` | oh-my-cli | OpenAI `/v1/responses` |
| `ollama-oh-my-cli-app` | oh-my-cli Desktop | Electron shell, env-pumped to ollama.com |
| `unsloth-*` | all of the above CLIs | same harnesses at your unsloth server (`:18888`/`:8888`) — see [Unsloth variants](#unsloth-variants) |

Pick a model three ways (first wins): `--model NAME`, `OLLAMA_MODEL=NAME`, or the
`gum` chooser (prefilled with your last pick, remembered per-harness in
`~/.config/ollama-scripts/`). Everything else is passed through:

```sh
ollama-codex --model qwen3-coder:480b exec "fix the failing test"
ollama-claude                       # chooser, then normal claude session
```

## Unsloth variants

Every CLI launcher above has an `unsloth-*` twin that points at your Unsloth
Studio servers instead of ollama.com: `unsloth-claude`, `unsloth-codex`,
`unsloth-pi`, `unsloth-hermes`, `unsloth-oh-my-cli`, `unsloth-oh-my-cli-app`,
plus a source-me `unsloth-env.sh` (mirrors `ollama-env.sh`).

Server discovery (first match wins):

1. `UNSLOTH_BASE_URL` — explicit, e.g. `https://gpu-box.lan:18888`
1. `:18888` — usually the remote unsloth machine, ssh-tunnelled to localhost
1. `:8888` — usually the local unsloth server

When **more than one** server is up you get an fzf-style chooser (server lines
look like `http://127.0.0.1:18888  key UNSLOTH_BIG_GPU · 16 models`); your last
pick is prefilled and auto-accepted, clear the query to switch. One server up
→ no question.

### Keys

Auth is probed per server, not assumed — keys are tried in order:

1. `UNSLOTH_API_KEY` (e.g. the local server's key)
1. `UNSLOTH_BIG_GPU` (e.g. the remote box's key)
1. any other exported `UNSLOTH_*KEY*` variable

A server that accepts a key runs in `bearer` mode and every client sends that
key; if none matches but the server answers anyway, it runs in `open` mode and
clients send **no** Authorization header (these servers 401 any Bearer they
don't know). Claude is special: it authenticates via `ANTHROPIC_API_KEY`
(x-api-key), which the unsloth servers ignore — so it works against both.
Codex omits its auth entirely on open servers; `pi`, `hermes` and `oh-my-cli`
can't send requests without a Bearer, so on open servers the launcher warns.
The chosen server + key are cached for an hour in `~/.config/ollama-scripts/`.

```sh
set -gx UNSLOTH_API_KEY   sk-unsloth-…      # :8888
set -gx UNSLOTH_BIG_GPU   sk-unsloth-…      # :18888
```

Model metadata (quant, context length, loaded state) is read straight from the
server's `/v1/models`, so the chooser shows it:

```
unsloth/Qwen3.8-27B-GGUF   UD-Q4_K_XL · 74k ctx · loaded
```

The model picker is fzf-style: `fzf` if installed, else `gum filter`, else a
plain `select`. Skip it with `--model NAME` or `UNSLOTH_MODEL=NAME`; the last
pick is remembered per harness, same as the ollama launchers.

```sh
unsloth-codex --model unsloth/Qwen3.8-27B-GGUF exec "fix the failing test"
UNSLOTH_BASE_URL=http://127.0.0.1:8888 unsloth-pi   # pin a server
```

Test matrix, both servers, real completions: claude, codex, pi, hermes and
oh-my-cli all answer `ok` against `:8888` (key `UNSLOTH_API_KEY`) and `:18888`
(key `UNSLOTH_BIG_GPU`).

No desktop-app twins (`*-app`, `gui`) — those exist to punch ollama.com
credentials into macOS app configs, which a plain HTTP server doesn't need.

## Desktop apps

Same idea for the GUIs, mirroring `ollama launch` but keyed straight to
ollama.com — no sign-in. **macOS only.**

Unlike the CLIs, desktop apps can't read the shell env, so these must **write
config files** — persistent, not ephemeral. Every touched file is copied to
`<file>.ollama-scripts.bak` first, and `ollama-unset.sh` reverts everything.

| Command | App | How |
|---|---|---|
| `ollama-codex-app` | Codex desktop | writes `~/.codex/config.toml` provider (backed up), then restarts Codex |
| `ollama-claude-app` | Claude Desktop | writes Claude's 3p gateway profile (backed up), then relaunches |
| `ollama-gui` | Ollama app | launches `Ollama.app` with `OLLAMA_API_KEY` in its env |

```sh
ollama-codex-app --model glm-5.2        # picks a model like the CLIs
ollama-claude-app                       # switch Claude Desktop to Ollama Cloud
ollama-gui                              # open the Ollama app with cloud access
```

Because the Codex launchers write a model catalogue covering **all** your ollama
cloud models, you can switch mid-session with `/model` inside Codex instead of
restarting the harness. Launching still picks one default (`--model`, `OLLAMA_MODEL`,
or the chooser), but the picker lists everything.

### Undo

`ollama-unset.sh` returns Codex, Claude Desktop, and pi to their original
providers — restoring each config from its `.ollama-scripts.bak` (or stripping
only what was added if no backup exists) and quitting the apps so they reload
clean. The CLI wrappers (`ollama-claude`, `ollama-codex`) need no undo; they only
set env for their own subprocess.

```sh
ollama-unset.sh                         # revert all app/pi config changes
```

Per-app reverts also exist: `ollama-codex-app --restore`, `ollama-claude-app --restore`.

## VS Code

The [Ollama VS Code extension](https://marketplace.visualstudio.com/items?itemName=Ollama.ollama)
supports cloud models natively — no launcher script needed. Install the
extension, then set two options in VS Code settings (`Cmd+,`):

- `ollama.endpoint` → `https://ollama.com`
- `ollama.headers` → add an `Authorization` header with value `Bearer <your-key>`

![VS Code settings](./vscode-setup.png)

Open the model picker in VS Code Chat (`Cmd+Shift+M`) and your cloud models
appear under the **Ollama** section.

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
