"""Small, inspectable RAG pipeline. Checks are model judgments, not guarantees."""
from dataclasses import dataclass, asdict
import re
import time


class CheckUnavailable(Exception):
    """The verifier returned an unreadable result; this is not a passing check."""


@dataclass(frozen=True)
class Document:
    id: str
    title: str
    text: str


def validate_documents(values, *, max_documents=30, max_characters=200000):
    if not isinstance(values, list) or not 1 <= len(values) <= max_documents:
        raise ValueError(f'Add between 1 and {max_documents} text documents.')
    docs, seen = [], set()
    for v in values:
        if not isinstance(v, dict): raise ValueError('Invalid document.')
        key, title, text = v.get('id'), v.get('title'), v.get('text')
        if not isinstance(key, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,60}', key) or key in seen:
            raise ValueError('Document IDs must be unique letters, numbers, hyphens or underscores.')
        if not isinstance(title, str) or not title.strip() or len(title)>200:
            raise ValueError('Each document needs a title under 200 characters.')
        if not isinstance(text, str) or not text.strip() or len(text)>50000:
            raise ValueError('Each document needs text under 50,000 characters.')
        seen.add(key)
        docs.append(Document(key, title.strip(), text.strip()))
    if sum(len(d.text) for d in docs)>max_characters: raise ValueError(f'Limit this request to {max_characters:,} characters total.')
    return docs


class LocalSearch:
    def __init__(self):
        from sentence_transformers import SentenceTransformer
        self.model = SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2', local_files_only=True, device='cpu')
        self.key = None

    def search(self, question, documents):
        import faiss
        import numpy as np
        key = tuple((d.id,d.title,d.text) for d in documents)
        if self.key != key:
            self.chunks = []
            # Small overlapping chunks respect the embedding model's short context.
            for d in documents:
                words = d.text.split()
                for offset in range(0,len(words),130):
                    self.chunks.append(Document(d.id,d.title,' '.join(words[offset:offset+180])))
            vectors = self.model.encode([d.text for d in self.chunks], normalize_embeddings=True)
            vectors = np.asarray(vectors,dtype='float32')
            self.index = faiss.IndexFlatIP(vectors.shape[1])
            self.index.add(vectors)
            self.key = key
        query = np.asarray(self.model.encode([question],normalize_embeddings=True),dtype='float32')
        _, ids = self.index.search(query,min(4,len(self.chunks)))
        return [self.chunks[int(i)] for i in ids[0] if i>=0]


class Pipeline:
    def __init__(self, search, backend):
        self.search, self.backend = search, backend

    def ask(self, question, documents, progress=None):
        if not isinstance(question,str) or not question.strip() or len(question)>2000:
            raise ValueError('Enter a question under 2,000 characters.')
        question = question.strip()
        trace = []
        def step(name, fn):
            if progress: progress(name)
            start=time.monotonic()
            value=fn()
            trace.append({'stage':name,'seconds':round(time.monotonic()-start,2),'result':value})
            return value
        rewritten=step('query_rewrite',lambda:self.backend.rewrite(question))
        if not isinstance(rewritten,str) or not rewritten.strip(): rewritten=question
        retrieved=step('retrieval',lambda:[asdict(d) for d in self.search.search(rewritten,documents)])
        docs=[Document(**d) for d in retrieved]
        base={'mode':self.backend.mode,'query':question,'rewritten_query':rewritten,'sources':retrieved,'trace':trace,
              'check_notice':'Model checks can be wrong. No calibrated confidence score or owner approval is implied.'}
        if not docs or not step('answerability',lambda:self.backend.answerable(question,docs)):
            return {**base,'status':'needs_context','answer':'The selected material does not provide enough evidence. Add a relevant source or ask the owner.'}
        answer=step('generation',lambda:self.backend.generate(question,docs))
        def flags_for(answer):
            flags=list(self.backend.check(question,answer,docs))
            refs=set(re.findall(r'\[([a-zA-Z0-9_-]+)\]',answer))
            allowed={d.id for d in docs}
            if not refs or not refs.issubset(allowed): flags.append('Missing or unknown source citation.')
            return flags
        try:
            flags=step('grounding_check',lambda:flags_for(answer))
            if flags:
                answer=step('repair',lambda:self.backend.generate(question,docs,repair=flags))
                flags=step('repair_check',lambda:flags_for(answer))
        except CheckUnavailable:
            for item in trace:
                if item['stage'] in ('generation','repair'):
                    item['result']='Draft withheld because verification could not complete.'
            return {**base,'status':'needs_review','answer':'The local model wrote a draft, but its source check returned an unreadable result. The unchecked draft was withheld. Try a narrower question or review the retrieved sources.'}
        if flags:
            # Remove generated drafts from trace too: only the held-answer message is displayed.
            for item in trace:
                if item['stage'] in ('generation','repair'): item['result']='Draft withheld after failed checks.'
            return {**base,'status':'needs_review','answer':'The answer did not pass the grounding checks after one repair attempt. Review the sources or ask the owner.'}
        return {**base,'status':'answered','answer':answer}
