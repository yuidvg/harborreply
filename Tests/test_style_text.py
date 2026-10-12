import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources/HarborReply/Resources/worker'))
from archive import Archive, ArchiveError
from context import build_context

class StyleTextProfileTests(unittest.TestCase):
    def test_model_description_persists_without_raw_samples_or_reanalysis(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'test.invalid.sqlite'
            a=Archive(path)
            description='短い段落を使う。例：「ご確認をお願いします。」'
            a.publish_text_style(dict(description=description, characters=32768, messages=4,
                source_address='owner@test.invalid', source_account_id='account.invalid'))
            a.db.close(); a=Archive(path)
            try:
                self.assertEqual(a.style_summary(verify=True)['description'], description)
                self.assertEqual(a.selected_style_messages(), [])
                ctx=build_context(a,dict(body='test.invalid',subject='',sender=''))
                self.assertEqual(ctx['style_summary']['description'],description)
                self.assertEqual(ctx['style_examples'],[])
            finally: a.db.close()
    def test_invalid_result_does_not_replace_published_profile(self):
        with tempfile.TemporaryDirectory() as root:
            a=Archive(Path(root)/'test.invalid.sqlite')
            try:
                with self.assertRaises(ArchiveError): a.publish_text_style(dict(description=''))
                self.assertIsNone(a.text_style_summary())
            finally:a.db.close()
