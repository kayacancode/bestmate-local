"""Download pinned adapter I/O metadata only; no model weights or private data."""
import json
from pathlib import Path
from urllib.request import urlopen
from granite_switch_backend import MODEL, REVISION

if __name__ == '__main__':
    root = Path(__file__).parent / '.cache/granite-switch'
    base = f'https://huggingface.co/{MODEL}/resolve/{REVISION}/'
    paths = ['adapter_index.json'] + [f'io_configs/{name}/io.yaml' for name in (
        'answerability', 'citations', 'context-attribution', 'factuality-correction',
        'factuality-detection', 'guardian-core', 'hallucination_detection', 'policy-guardrails',
        'query_clarification', 'query_rewrite', 'requirement-check', 'uncertainty')]
    for path in paths:
        with urlopen(base + path, timeout=30) as response: content = response.read()
        dest = root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
    (root / 'bestmate-revision.json').write_text(json.dumps({'model': MODEL, 'revision': REVISION}))
    print('Prepared pinned Granite Switch adapter metadata. Start the GPU endpoint separately.')
