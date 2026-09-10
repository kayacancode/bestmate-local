# Public export verification

This repository starts with a new history and an explicit source allowlist. It contains the native local workspace, the Granola API client, a reduced Keychain helper, the local Python experiments, fictional evaluation fixtures/results, and tests.

Excluded: legacy hosted application and backend, previous Git history, production configuration, private workspace files, meeting notes, chat transcripts, screenshots, credentials, model weights, downloaded caches, compiled frameworks, app bundles, release signing material and local logs.

The exported app builds independently without the original Rust framework or cloud dependencies. Its bundle, workspace directory and Keychain service are separate from the original app.

Verification on the export:

- Standalone Xcode build succeeded.
- Native suite: 32 passed, 1 prepared-runtime lifecycle test skipped, 0 failed. The skip is expected without a local `.venv` and prepared models.
- Python deterministic suite: 29 passed; no model downloads needed.
- Text review and targeted patterns checked private-key blocks, common provider credential formats, JWTs, personal filesystem paths and email-like values. The email-like match was an intentionally invalid loopback URL containing `@evil.test` in a security test; no credential was present.
- Checked-in evaluation inputs and results contain fictional runbooks and handoffs. Model caches and user-supplied source material are ignored and were not copied.

This is a scoped release review, not an independent security audit or a claim of enterprise readiness. Model and channel limitations are listed in the README.
