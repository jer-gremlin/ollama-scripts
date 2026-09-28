#!/usr/bin/env bash
set -euo pipefail
# Source me:  source unsloth-env.sh
# Points OpenAI + Anthropic SDKs/CLIs at the unsloth server (:18888 remote
# ssh tunnel, :8888 local). Sends the key the server authenticated with;
# open servers get a dummy (they ignore auth).

_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
source "$_DIR/lib.sh"
source "$_DIR/unsloth-lib.sh"
_us_base_url

export OPENAI_BASE_URL="$US_URL/v1"
export OPENAI_API_KEY="${US_KEY:-unsloth}"

# Anthropic SDK / CLI (posts to $ANTHROPIC_BASE_URL/v1/messages). The unsloth
# servers ignore x-api-key, so ANTHROPIC_API_KEY (not a Bearer AUTH_TOKEN).
export ANTHROPIC_BASE_URL="$US_URL"
export ANTHROPIC_API_KEY="${US_KEY:-unsloth}"

echo "unsloth-env: OpenAI -> $OPENAI_BASE_URL, Anthropic -> $ANTHROPIC_BASE_URL/v1/messages"