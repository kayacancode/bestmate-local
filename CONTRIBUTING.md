# Contributing

Use fictional sources and redact tokens, personal paths and conversation content from bug reports. Do not attach real corporate documents.

For adapter changes, preserve the existing evaluation fixture as a baseline and save changed criteria or fixtures separately. Include model/adapter revisions, serving backend, expected behavior, actual output and per-stage timings. Distinguish automated checks from semantic review and avoid presenting a small sample as a general accuracy benchmark.

Run the deterministic Python tests and relevant native tests before opening a pull request. Do not run live inference or connect provider accounts in ordinary CI.

Contributions are provided under this repository's MIT license. Third-party code must retain its applicable notices and licenses.
