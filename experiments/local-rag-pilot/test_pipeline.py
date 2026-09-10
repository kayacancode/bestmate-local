import unittest
from pipeline import Pipeline, Document, validate_documents


class FakeSearch:
    def search(self, question, documents):
        return documents[:3]


class FakeBackend:
    mode = 'test'
    def rewrite(self, question): return question
    def answerable(self, question, documents): return self.can_answer
    can_answer = True
    def generate(self, question, documents, repair=None):
        return 'Inspect partial writes before retrying. [runbook]'
    def check(self, question, answer, documents):
        return self.flags
    flags = []


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.backend = FakeBackend()
        self.pipeline = Pipeline(FakeSearch(), self.backend)
        self.docs = [Document('runbook', 'Service runbook', 'Inspect partial writes before retrying.')]

    def test_answer_includes_retrieved_sources_and_trace(self):
        r = self.pipeline.ask('Can I retry?', self.docs)
        self.assertEqual(r['status'], 'answered')
        self.assertEqual(r['sources'][0]['id'], 'runbook')
        self.assertTrue(r['trace'])
        self.assertNotIn('confidence', r)

    def test_missing_evidence_abstains_without_generation(self):
        self.backend.can_answer = False
        self.backend.generate = lambda *a, **k: self.fail('must not generate')
        r = self.pipeline.ask('What is the budget?', self.docs)
        self.assertEqual(r['status'], 'needs_context')

    def test_failed_repair_is_withheld(self):
        self.backend.flags = ['Unsupported claim']
        r = self.pipeline.ask('Can I retry?', self.docs)
        self.assertEqual(r['status'], 'needs_review')
        self.assertNotIn('Inspect partial writes', r['answer'])
        self.assertEqual(sum(x['stage']=='repair' for x in r['trace']), 1)

    def test_unreadable_check_withholds_draft_without_repair_or_crash(self):
        from pipeline import CheckUnavailable
        def unreadable(*args): raise CheckUnavailable('Invalid JSON')
        self.backend.check=unreadable
        r=self.pipeline.ask('Can I retry?',self.docs)
        self.assertEqual(r['status'],'needs_review')
        self.assertIn('unreadable result',r['answer'])
        self.assertFalse(any(x['stage']=='repair' for x in r['trace']))
        self.assertNotIn('Inspect partial writes',str([x for x in r['trace'] if x['stage']=='generation']))

    def test_unknown_citation_is_withheld(self):
        self.backend.generate = lambda *a, **k: 'Deploy now. [secret]'
        r = self.pipeline.ask('Can I deploy?', self.docs)
        self.assertEqual(r['status'], 'needs_review')

    def test_context_ids_match_citations_and_merge_chunks(self):
        from backends import context_docs
        value = context_docs(self.docs + [Document('runbook', 'Service runbook', 'A second chunk.')])
        self.assertEqual(list(value), ['runbook'])
        self.assertIn('A second chunk.', value['runbook'])
        self.assertIn('Inspect partial writes', value['runbook'])

    def test_subject_suggestions_are_bounded_labels(self):
        from backends import suggest_subjects
        self.backend.text=lambda *a,**k: '["Architecture", "Client handoffs", "Architecture"]'
        self.assertEqual(suggest_subjects(self.backend,self.docs),['Architecture','Client handoffs'])
        for invalid in ['not JSON','[]','[1]','["'+('x'*61)+'"]']:
            self.backend.text=lambda *a, value=invalid, **k:value
            with self.assertRaises(ValueError):suggest_subjects(self.backend,self.docs)

    def test_document_validation(self):
        for docs in [[], [{'id':'x','title':'a','text':''}], [{'id':'x','title':'a','text':'ok'}]*2]:
            with self.assertRaises(ValueError): validate_documents(docs)
        self.assertEqual(validate_documents([{'id':'x','title':'A','text':'valid'}])[0].id, 'x')


if __name__ == '__main__': unittest.main()
