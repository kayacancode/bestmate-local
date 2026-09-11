# Bestmate Local

An experimental macOS workspace for turning your sources and reviewed decisions into a scoped assistant that teammates and agents can consult.

This repository contains the standalone SwiftUI app, a local Python retrieval service with an OpenAI-compatible model connection, and reproducible evaluations of IBM Granite's Hugging Face adapters. It is a clean source export; it does not include the legacy hosted Bestmate backend, private workspace data, model weights, or credentials.

**[Start here: connect your own model endpoint](#quick-start-bring-your-own-model-endpoint).** No local model downloads are required for that path.

**For the optional Granite adapter experiments, see the [HF evaluation report](experiments/local-rag-pilot/results/hf-flow-evaluation.md)** and its [fixed test cases](experiments/local-rag-pilot/hf_flow_cases.json). Twelve fictional scenarios were run twice locally. The current flow incorrectly blocked 10 of 20 legitimate requests and failed to clarify four ambiguous requests. Answered cases took a median 11.55 seconds on the development Mac. These are small experimental results, not production benchmarks.

The follow-up [Guardian scope diagnostic](experiments/local-rag-pilot/results/scope-diagnostic.md) compares six formulations across 20 questions. None was reliable enough to promote; the existing gate remains unchanged.

The checked-in evaluation predates the September 10 generation-cache fix. The HF backend now caches attention states within each generation and retains no KV entries between calls. The source checker also has a larger output budget, but can still return malformed output; those answers remain withheld. Earlier latency measurements have not been refreshed; the scope and clarification findings above still need separate work.

## What is here

- **Knowledge:** add text/Markdown/PDF files, search local folders, or explicitly connect Granola with your own key.
- **Judgment:** review proposed decisions and preserve their supporting sources. Reviewed judgments become retrieval evidence; this does not fine-tune model weights.
- **Twins and access:** choose people, shared sources, availability and owner-review requirements.
- **Channels:** experimental Slack, Telegram and WhatsApp Business adapters; no connection starts automatically. Messages use the provider's network while retrieval stays with your configured runtime.
- **Local agent gateway:** scoped credentials for the loopback API.
- **Evaluation:** real HF adapter experiments, deterministic regression tests, complete fictional inputs and outputs.

<a id="install-and-run-locally"></a>

## Quick start: bring your own model endpoint

**Use this path to try Bestmate with your organization's existing model server.** No Granite, Hugging Face, embedding weights, or Python packages need downloading. It uses local BM25 keyword retrieval; the existing FAISS + embedding path remains available in the optional setup below.

You need macOS 13+, full Xcode (open it once to finish setup), [Homebrew](https://brew.sh/), and an endpoint supporting `POST /chat/completions`. Only the Mac app requires macOS; the Python service itself can also be explored through its browser lab, though endpoint configuration in this release is in the native app.

```sh
brew install python xcodegen
git clone https://github.com/kayacancode/bestmate-local.git
cd bestmate-local
xcodegen generate --spec macos/project.yml
xcodebuild -project macos/BestmateLocal.xcodeproj -scheme BestmateLocal \
  -derivedDataPath /tmp/bestmate-local-build build
open /tmp/bestmate-local-build/Build/Products/Debug/BestmateLocal.app
python3 experiments/local-rag-pilot/server.py
```

Leave the terminal running. In **Environment** during onboarding, or **Local setup** later:

1. Choose **Your model endpoint · OpenAI compatible**.
2. Enter the **model base URL**, such as `https://your-approved-server/v1` or `http://127.0.0.1:8000/v1`. Bestmate appends `/chat/completions`; include any gateway path prefix in the base URL.
3. Enter the **model name** exactly as your server expects.
4. Enter an **API key** if required. It is stored in macOS Keychain, not the workspace JSON or repository. Leave it empty for an endpoint with no authentication.
5. Keep **Bestmate local service URL** at `http://127.0.0.1:4390` and click **Check connection**. This sends a short generation request with no workspace documents; it does not rely on a `/models` endpoint.
6. Import a note or document, ask a question whose answer is in it, and review the result.

**Where data goes:** documents, retrieval, source permissions, and review records stay on your Mac. Questions and selected excerpts go to the model endpoint you explicitly configure. A remote endpoint is organization-hosted inference, not on-Mac inference. Endpoint mode sends ordinary chat requests for answerability, generation, and grounding checks; it does **not** invoke Gabe's specialized Granite adapters or provide calibrated confidence scores. Permission enforcement runs before retrieval. Model checks can still fail or be wrong.

Remote endpoints must use HTTPS with a trusted certificate. HTTP is allowed for loopback servers and SSH tunnels. Redirects are rejected to avoid forwarding keys or source excerpts to another host; configure the final URL. This first version supports non-streaming chat completions and optional Bearer authentication, not arbitrary vendor-specific authentication or API schemas. BM25 matches words rather than semantic embeddings; use the terms present in your notes when testing retrieval.

For later launches, reopen the built app and rerun `python3 experiments/local-rag-pilot/server.py` from the repository root. If port 4390 is already in use, use the running Bestmate service or stop it before launching another. Existing installations must restart the Python service after pulling this update. A connection failure will show the HTTP status or connection error; there is no automatic model fallback.

## Optional: install Granite and HF adapters on this Mac

This is a **build-from-source preview**, with two parts: the macOS app and a Python model service running on the same Mac. You do not need Ollama, a hosted model API key, or a Granite Switch server for this setup.

### 1. Install prerequisites and clone

Use macOS 13+ with the full Xcode app installed. Open Xcode once to finish its setup and accept its license. Command Line Tools alone are not enough to build the app. The model experiment was tested on Apple Silicon; Intel/CPU performance has not been validated. Allow several GB of disk space for model downloads.

With [Homebrew](https://brew.sh/) installed, run:

```sh
brew install uv xcodegen
git clone https://github.com/kayacancode/bestmate-local.git
cd bestmate-local
```

Keep this terminal open. The following steps start from this repository folder.

### 2. Download the model and adapters

```sh
(
  cd experiments/local-rag-pilot
  uv sync --locked --python 3.12
  .venv/bin/python prepare.py --adapters
)
```

This installs the locked Python dependencies and downloads Granite 4.1 3B, the RAG adapters, and the embedding model. `uv` can provision Python 3.12 if needed. This step needs internet access and may take a while. Wait for **“Prepared. Run server.py for offline inference.”** before continuing.

Downloads are stored under `experiments/local-rag-pilot/.cache/`. Keep that folder for subsequent launches; model weights are not included in Git. The service enables offline Hugging Face mode during inference.

### 3. Build and open the app

From the same terminal, still at the repository root:

```sh
xcodegen generate --spec macos/project.yml
xcodebuild -project macos/BestmateLocal.xcodeproj -scheme BestmateLocal \
  -derivedDataPath /tmp/bestmate-local-build build
open /tmp/bestmate-local-build/Build/Products/Debug/BestmateLocal.app
```

The app uses a separate workspace directory at `~/Library/Application Support/io.bestmate.local.opensource/LocalWorkspace` and a separate Keychain service. It does not migrate data from another Bestmate installation.

### 4. Start the local service

In the same terminal:

```sh
cd experiments/local-rag-pilot
.venv/bin/python server.py
```

Leave this terminal running while you use Bestmate. The service listens at `http://127.0.0.1:4390`. You can also open that address in a browser to use the standalone local lab. Press **Control-C** in the terminal to stop the service when finished.

### 5. Connect Bestmate and try a question

In onboarding's **Environment** step, or **Local setup** in the main app:

1. Choose **Granite + Hugging Face RAG adapters** as the answer pipeline.
2. Set **Local service URL** to `http://127.0.0.1:4390`.
3. Click **Check connection** and wait for the readiness result.
4. Add a short note or text/Markdown/PDF document in **Knowledge**, then ask a question that its contents can answer.

For a simple first test, add a note saying “The demo project's kickoff is Monday. Alex owns the handoff.” Then ask “Who owns the demo project handoff?” The first question also loads the model into memory, so it can take longer than later questions. A successful connection confirms service readiness; use the question to check actual inference.

The app's HF pipeline and the full notebook-flow evaluation are separate paths; see the evaluation section below for Guardian, clarification and citation-adapter experiments.

### Launch again later

You do not need to repeat the downloads or build unless you change the setup or source. From the repository root:

```sh
open /tmp/bestmate-local-build/Build/Products/Debug/BestmateLocal.app
cd experiments/local-rag-pilot
.venv/bin/python server.py
```

If macOS has cleared the temporary build folder, repeat step 3. Alternatively, **Local setup → Start a prepared runtime** can launch the service for you: select the `experiments/local-rag-pilot` service folder and its `.venv/bin/python` executable. Use either the terminal or the app to start it, so only one service uses port 4390.

### Troubleshooting

- **Xcode build says it requires Xcode:** check `xcode-select -p`. If it points to Command Line Tools, select your full Xcode installation in **Xcode → Settings → Locations → Command Line Tools**, then retry the build.
- **Connection refused:** start `server.py`, leave its terminal open, and check that the app uses `http://127.0.0.1:4390`.
- **Models or adapters are missing:** rerun step 2 with internet access, then restart the service and check the connection again.
- **Address already in use:** an existing service may already be running. Use it, or stop it before starting another copy.
- **Inference is very slow or times out:** run the service in a normal macOS terminal with GPU access, close other model workloads, and inspect the service terminal for the underlying error. Intel/CPU performance is unvalidated. Bestmate does not silently switch to a cloud model or another backend.

## Reproduce the notebook-flow evaluation

This uses **Granite 4.1 3B plus individual HF adapters**, not the composed Granite Switch checkpoint. The flow follows the pattern in [the Granite Switch RAG notebook](https://github.com/generative-computing/granite-switch/blob/main/tutorials/notebooks/rag_flow.ipynb): Guardian harm/scope checks, history-aware query rewriting, retrieval, answerability, clarification, generation and citation attribution. FAISS retrieval uses only the supplied source snapshot.

From the repository root, in a separate terminal:

```sh
cd experiments/local-rag-pilot
uv run python prepare.py --full-flow
uv run python evaluate_hf_flow.py --repeats 2
uv run python summarize_hf_evaluation.py
```

Run this separately from other model workloads. On Apple Silicon, the process needs access to the GPU; restricted execution environments can make PyTorch fall back to CPU. The evaluator writes results under `results/` and replaces the checked-in run, so preserve previous output before comparing configurations. Runtime inference is offline; only the explicit prepare commands download artifacts.

The app's default HF pipeline still uses its earlier rewrite/answerability/grounding/repair flow. The full notebook-flow HF implementation is currently exercised through the evaluation harness. The separate `granite-switch` app option expects a composed model served at a loopback OpenAI-compatible endpoint; see [serving notes](docs/GRANITE_SWITCH.md). That endpoint has not been live-tested here. Selecting it never silently falls back to HF or Ollama.

## Tests

No model downloads are required for deterministic Python tests. Start from the repository root:

```sh
cd experiments/local-rag-pilot
python3 -m unittest test_switch test_pipeline test_grounding test_runtime test_http test_gateway
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
