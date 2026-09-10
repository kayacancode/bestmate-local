# Third-party components

Model artifacts and dependencies are downloaded separately and retain their own licenses. The MIT license here applies to Bestmate's source, not to third-party artifacts or provider services.

- [Mellea](https://github.com/generative-computing/mellea): adapter invocation and model backend APIs.
- [Granite Switch](https://github.com/generative-computing/granite-switch): composed model support and the reference RAG flow. The Bestmate flow was patterned after its section 5 example; review its upstream license when using or redistributing upstream code.
- [Granite RAG Library](https://huggingface.co/ibm-granite/granitelib-rag-r1.0) and [Guardian Library](https://huggingface.co/ibm-granite/granitelib-guardian-r1.0): downloaded adapters. Read the model cards and licenses for the exact revisions you use.
- PyTorch, Transformers, PEFT, sentence-transformers, FAISS and other Python dependencies: exact versions and package sources are recorded in `experiments/local-rag-pilot/uv.lock`.
- SwiftUI, AppKit, PDFKit and system fonts are supplied by macOS, not redistributed here.

Slack, Telegram, WhatsApp and Granola integrations use those providers' APIs and require user-supplied credentials and applicable service permissions. Provider names are descriptive and do not imply endorsement.
