from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from meeting_pilot import business_glossary


class BusinessGlossaryTests(unittest.TestCase):
    def use_glossary(self, content: str) -> None:
        folder = Path(self.enterContext(tempfile.TemporaryDirectory()))
        path = folder / "business-glossary.txt"
        path.write_text(content, encoding="utf-8")
        self.enterContext(patch.dict(os.environ, {"BUSINESS_GLOSSARY_FILE": str(path)}))

    def test_first_item_is_the_term_and_the_rest_are_variants(self) -> None:
        self.use_glossary("isycontrol, isi control, easy control\nISP, I.S.P.\nAcme\n")

        self.assertEqual(business_glossary.terms(), ("isycontrol", "ISP", "Acme"))
        self.assertEqual(business_glossary.entries()[0].variants, ("isi control", "easy control"))

    def test_variants_are_replaced_as_whole_words_ignoring_case(self) -> None:
        self.use_glossary("isycontrol, isi control, easy control\nISP, I.S.P.\n")

        corrected = business_glossary.apply_corrections("Isi Control e easy controller, poi I.S.P. e isp.")

        self.assertEqual(corrected, "isycontrol e easy controller, poi ISP e isp.")

    def test_summary_prompt_never_presents_variants_as_correct_spellings(self) -> None:
        self.use_glossary("isycontrol, isi control\nAcme\n")

        prompt = business_glossary.summary_instructions()

        self.assertIn("use exactly these spellings when relevant: isycontrol, Acme.", prompt)
        self.assertIn("'isi control' -> 'isycontrol'", prompt)

    def test_missing_glossary_changes_nothing(self) -> None:
        with patch.dict(os.environ, {"BUSINESS_GLOSSARY_FILE": ""}):
            self.assertEqual(business_glossary.apply_corrections("isi control"), "isi control")
            self.assertEqual(business_glossary.summary_instructions(), "")


if __name__ == "__main__":
    unittest.main()
