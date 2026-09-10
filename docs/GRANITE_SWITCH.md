# Granite Switch in Bestmate

This backend implements the flow in the reference notebook:
https://github.com/generative-computing/granite-switch/blob/main/tutorials/notebooks/rag_flow.ipynb

It uses Mellea 0.7.0's actual embedded intrinsics: guardian-core (harm and scope), query_rewrite, answerability, query_clarification, base generation and citations. FAISS retrieval continues to use only the caller's permitted source snapshot. This does not fine-tune owner judgment or change source permissions.

## Serving

The notebook's supported serving path needs a compatible GPU environment (its prerequisites specify T4 or better). This Apple Silicon Mac has no running Granite Switch server. The app integration and metadata are prepared, but real model inference has not been verified here.

On your approved Linux GPU machine, create a separate environment using the Granite Switch repository's prerequisites. The repository currently specifies `granite-switch[vllm]` with vLLM >=0.19.1,<0.20.0. Do not install its tutorial dependency bundle into Bestmate's existing Python environment: it pins an older Mellea version.

Example dedicated server setup (downloads public model weights):

```sh
python3 -m venv .venv-switch
.venv-switch/bin/pip install 'granite-switch[vllm]==0.1.0'
.venv-switch/bin/python -m vllm.entrypoints.openai.api_server \
  --model ibm-granite/granite-switch-4.1-3b-preview \
  --revision 7a3ac02e07868411424ac89440397b475da66fa7 \
  --host 127.0.0.1 --port 8000 --max-model-len 30720 \
  --max-num-seqs 1 --enforce-eager
```

If this server runs on another approved machine, forward its loopback port from your Mac:

```sh
ssh -N -L 127.0.0.1:8000:127.0.0.1:8000 your-approved-gpu-host
```

Questions and selected evidence then go to that machine through the tunnel. This is not on-Mac inference; choose a machine your data policy allows. Bestmate never chooses a remote host automatically.

In `experiments/local-rag-pilot`, run `.venv/bin/python prepare_switch.py` to download only pinned adapter I/O metadata. This has already been run on this Mac. No Switch model weights are downloaded by this preparation step.

Restart the Bestmate RAG service, then choose **Local setup → Answer pipeline → Granite Switch · notebook adapter flow**, and **Check connection**. Keep the Bestmate service URL at `http://127.0.0.1:4390`; that service connects to the separate inference endpoint `http://127.0.0.1:8000/v1`. `BESTMATE_SWITCH_URL` can change its loopback port and `BESTMATE_SWITCH_SOURCE` can select a prepared local metadata directory when launching the service.

The readiness probe checks metadata presence and the served model ID. The first question verifies actual adapter execution. No fallback to HF, Ollama or a hosted model occurs. Reset adapter session stops Bestmate's worker, not the separate GPU server.

## Conversation and results

The native question box keeps up to six turn pairs; New conversation resets it. Slack, Telegram and WhatsApp use separate keys containing provider, connection generation, route and sender, plus member/twin/topic. Any evidence, member or twin changes clear the reused context. History stays in app memory; the model worker starts each request from only the supplied history and stores no conversation. Gateway calls remain single-turn until an authenticated conversation protocol is added.

Results distinguish blocked, needs_context, needs_clarification, needs_review and answered. Clarification is shown as a follow-up rather than an approved decision. Owner review still applies to generated answers. Drafts withheld from a teammate are not inserted into their conversation history. Citation spans must match the response and source text and cover the answer's alphanumeric content; invalid attribution withholds the draft. These are attribution checks, not proof that a model's semantic judgment is correct.

Subject-label suggestions are currently unavailable in Switch mode; they remain optional. Answer verbosity uses the concise Switch generation instruction in this first integration.

## Verification

`test_switch.py` tests the flow order, early exits, malformed Guardian output, rewritten retrieval, clarification, source attribution, history isolation and loopback validation using deterministic doubles. Existing HTTP/runtime/pipeline tests cover service boundaries. Real Mellea registration against pinned adapter metadata was exercised successfully. Full GPU inference and performance benchmarking require the actual server above.
