# Tuning model metadata

Harnesses warn like:

```
⚠ Model metadata for `gpt-oss:120b` not found. Defaulting to fallback metadata;
  this can degrade performance and cause issues.
```

The cloud models aren't in the harness's built-in catalogue, so it guesses the
context window, output cap, and capabilities. Guessing wrong truncates prompts
or disables tools/reasoning. Fix = give the harness the real numbers.

## Where the numbers live

Ollama serves per-model metadata at `/api/show`:

```sh
curl -s https://ollama.com/api/show \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -d '{"model":"gpt-oss:120b"}' \
| python3 -c 'import sys,json; d=json.load(sys.stdin); \
  print("capabilities:", d.get("capabilities")); \
  print("details:", d.get("details")); \
  mi=d.get("model_info",{}); \
  print({k:v for k,v in mi.items() if k.endswith("context_length")})'
```

You get the three things every harness wants:

| Field | From `/api/show` | Meaning |
|---|---|---|
| context window | `model_info.*.context_length` | max prompt+output tokens |
| capabilities | `capabilities` (`tools`, `thinking`, `vision`, …) | tool calls, reasoning, image input |
| size / quant | `details.parameter_size`, `details.quantization_level` | informational |

The model's page at `https://ollama.com/library/<model>` lists the context length too.

## Codex (automatic)

`ollama-codex` already does this for you: on each launch `_codex_catalog`
(in `lib.sh`) fetches `/api/show` for the chosen model, derives
`context_window` (from `model_info.*.context_length`), reasoning levels and
image support (from `capabilities`), writes a catalogue to
`~/.config/ollama-scripts/codex-catalog.json`, and passes it via
`-c model_catalog_json=…`. No action needed. If the fetch fails it still writes
a 128k-context fallback entry, which silences the warning.

To override manually, the catalogue schema is:

```jsonc
// ~/.codex/ollama-cloud-models.json
{
  "models": [
    {
      "slug": "gpt-oss:120b",
      "display_name": "gpt-oss:120b",
      "context_window": 131072,          // from /api/show
      "input_modalities": ["text"],       // add "image" if capabilities has vision
      "supported_reasoning_levels": ["low","medium","high"],  // if capabilities has thinking
      "supports_parallel_tool_calls": true,                   // if capabilities has tools
      "supported_in_api": true,
      "visibility": "list"
    }
  ]
}
```

Wire it in `ollama-codex` by adding one line to the `exec codex` block:

```sh
  -c 'model_catalog_json="'"$HOME"'/.codex/ollama-cloud-models.json"' \
```

`context_window` alone silences the warning; the rest improves behaviour.

## pi

pi's per-model metadata are fields on the model entry in `models.json`
(defaults: `contextWindow` 128000, `maxTokens` 16384). Tunable fields:

```jsonc
{
  "id": "gpt-oss:120b",
  "contextWindow": 131072,
  "maxTokens": 32768,
  "reasoning": true,                 // capabilities has thinking
  "input": ["text"],                 // add "image" for vision
  "compat": { "supportsReasoningEffort": true }
}
```

Caveat: `ollama-pi` **rewrites** `providers.ollama_cloud` on every launch, so
edits to `models.json` are overwritten. To persist pi tuning, edit the model
dict inside `ollama-pi` itself — the line:

```python
"models": [{"id": i} for i in ids],
```

Replace with a lookup that adds fields for the ids you care about, e.g.:

```python
TUNED = {"gpt-oss:120b": {"contextWindow": 131072, "reasoning": True}}
"models": [{"id": i, **TUNED.get(i, {})} for i in ids],
```

## Claude Code

`ollama-claude` needs no catalogue — Claude Code takes the model from
`ANTHROPIC_MODEL` and doesn't emit this warning. If context handling feels off,
there's nothing to tune here; it's driven by the endpoint.
