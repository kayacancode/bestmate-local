# Bestmate Local

An experimental macOS workspace for turning your sources and reviewed decisions into a scoped assistant that teammates and agents can consult.

This repository contains the standalone SwiftUI app, a local Python RAG service, and reproducible evaluations of IBM Granite's Hugging Face adapters. It is a clean source export; it does not include the legacy hosted Bestmate backend, private workspace data, model weights, or credentials.

**Start with the [HF evaluation report](experiments/local-rag-pilot/results/hf-flow-evaluation.md)** and its [fixed test cases](experiments/local-rag-pilot/hf_flow_cases.json). Twelve fictional scenarios were run twice locally. The current flow incorrectly blocked 10 of 20 legitimate requests and failed to clarify four ambiguous requests. Answered cases took a median 11.55 seconds on the development Mac. These are small experimental results, not production benchmarks.

## What is here

- **Knowledge:** add text/Markdown/PDF files, search local folders, or explicitly connect Granola with your own key.
- **Judgment:** review proposed decisions and preserve their supporting sources. Reviewed judgments become retrieval evidence; this does not fine-tune model weights.
- **Twins and access:** choose people, shared sources, availability and owner-review requirements.
- **Channels:** experimental Slack, Telegram and WhatsApp Business adapters; no connection starts automatically. Messages use the provider's network while retrieval stays with your configured runtime.
- **Local agent gateway:** scoped credentials for the loopback API.
- **Evaluation:** real HF adapter experiments, deterministic regression tests, complete fictional inputs and outputs.

## Build the macOS app

Requires macOS 13+, Xcode with command-line tools, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The model experiment was tested on Apple Silicon; Intel/CPU performance has not been validated.

```sh
brew install xcodegen
xcodegen generate --spec macos/project.yml
xcodebuild -project macos/BestmateLocal.xcodeproj -scheme BestmateLocal \
  -derivedDataPath /tmp/bestmate-local-build build
open /tmp/bestmate-local-build/Build/Products/Debug/BestmateLocal.app
```

The app has no Sparkle updater, hosted authentication, Rust framework or external Swift package dependency. It uses a separate workspace directory at `~/Library/Application Support/io.bestmate.local.opensource/LocalWorkspace` and a separate Keychain service. It does not migrate data from another Bestmate installation.

## Prepare the local model service

Install [uv](https://docs.astral.sh/uv/) and allow space for several GB of model downloads. Run from this repository:

```sh
cd experiments/local-rag-pilot
uv sync --locked --python 3.12
uv run python prepare.py --adapters
uv run python server.py
```

Preparation downloads public model artifacts. The service then enables offline Hugging Face mode and listens at `http://127.0.0.1:4390`. In the app, open **Local setup**, select **Granite + Hugging Face RAG adapters**, and check that service URL. Alternatively open that URL in a browser for the standalone local lab.

## Reproduce the notebook-flow evaluation

This uses **Granite 4.1 3B plus individual HF adapters**, not the composed Granite Switch checkpoint. The flow follows the pattern in [the Granite Switch RAG notebook](https://github.com/generative-computing/granite-switch/blob/main/tutorials/notebooks/rag_flow.ipynb): Guardian harm/scope checks, history-aware query rewriting, retrieval, answerability, clarification, generation and citation attribution. FAISS retrieval uses only the supplied source snapshot.

```sh
cd experiments/local-rag-pilot
uv run python prepare.py --full-flow
uv run python evaluate_hf_flow.py --repeats 2
uv run python summarize_hf_evaluation.py
```

Run this separately from other model workloads. On Apple Silicon, the process needs access to the GPU; restricted execution environments can make PyTorch fall back to CPU. The evaluator writes results under `results/` and replaces the checked-in run, so preserve previous output before comparing configurations. Runtime inference is offline; only the explicit prepare commands download artifacts.

The app's default HF pipeline still uses its earlier rewrite/answerability/grounding/repair flow. The full notebook-flow HF implementation is currently exercised through the evaluation harness. The separate `granite-switch` app option expects a composed model served at a loopback OpenAI-compatible endpoint; see [serving notes](docs/GRANITE_SWITCH.md). That endpoint has not been live-tested here. Selecting it never silently falls back to HF or Ollama.

## Tests

No model downloads are required for deterministic Python tests:

```sh
cd experiments/local-rag-pilot
python3 -m unittest test_switch test_pipeline test_grounding test_runtime test_http
```

Native tests (from repository root):

```sh
xcodebuild -project macos/BestmateLocal.xcodeproj -scheme BestmateLocal \
  -derivedDataPath /tmp/bestmate-local-build test
```

Stop other local gateway/WhatsApp receivers before native tests; they use ports 4392 and 4393. The prepared-runtime lifecycle test skips unless a local `.venv` exists.

## Current limitations

This is a single-owner prototype, not a hardened enterprise deployment. Scope judgments can reject relevant questions, clarification can guess, and citation attribution does not prove completeness or correct interpretation. Channel delivery requires your own provider setup and has not been end-to-end verified with live accounts in this export. Scheduling depends on the app staying open. The local gateway does not yet provide multi-turn conversation sessions.

Do not put private documents, tokens, chat logs or cached model files in commits or issues. The app stores workspace data locally; Granola and messaging integrations contact external services only when you explicitly use them. SSH-tunneled inference sends evidence to the server at the other end of the tunnel—it is not on-Mac inference.

## License and attribution

Source code in this export is available under the [MIT License](LICENSE). Dependency and model licenses remain their own; no model weights or third-party fonts are bundled. See [third-party notes](THIRD_PARTY.md). Bestmate is independent of IBM, Microsoft, Hugging Face and the integration providers.
