"""Explicit online setup. The server itself uses offline Hugging Face mode."""
import argparse
import json
import os
from pathlib import Path
ROOT = Path(__file__).resolve().parent
os.environ['HF_HOME'] = str(ROOT / '.cache/huggingface')
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
from huggingface_hub import HfApi, snapshot_download

parser = argparse.ArgumentParser()
parser.add_argument('--adapters', action='store_true')
parser.add_argument('--full-flow', action='store_true', help='Also prepare Guardian, clarification and citation adapters for the live notebook-flow test.')
args = parser.parse_args()
repos = [('sentence-transformers/all-MiniLM-L6-v2', ['*.json', '*.txt', '*.safetensors', '*.model'])]
if args.adapters or args.full_flow:
    repos += [('ibm-granite/granite-4.1-3b', ['*.json', '*.txt', '*.safetensors', '*.model', '*.jinja']),
              ('ibm-granite/granitelib-rag-r1.0', ['*.json', '*.yaml', '*.jinja', '*.txt'] +
               [f'{name}/granite-4.1-3b/*/*' for name in ['query_rewrite', 'answerability', 'hallucination_detection']])]
if args.full_flow:
    repos += [('ibm-granite/granitelib-rag-r1.0', ['*.json', '*.yaml', '*.jinja'] + [f'{name}/granite-4.1-3b/*/*' for name in ['query_clarification', 'citations']]),
              ('ibm-granite/granitelib-guardian-r1.0', ['*.json', '*.yaml', '*.jinja', 'guardian-core/granite-4.1-3b/*/*'])]
manifest_path = ROOT / '.cache/models.json'
manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
for repo, patterns in repos:
    info = HfApi().model_info(repo)
    print(f'Downloading {repo} at {info.sha}', flush=True)
    # main creates a local ref for Mellea's resolver; record the resolved immutable SHA.
    location = snapshot_download(repo, revision='main', allow_patterns=patterns, max_workers=4)
    manifest[repo] = {'revision': Path(location).name, 'path': location}
    manifest_path.write_text(json.dumps(manifest, indent=2))
print('Prepared. Run server.py for offline inference.', flush=True)
