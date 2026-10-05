"""Offline tests for build_db.py pure parts. Run: python -m unittest test_build_db -v"""
import io
import json
import gzip
import tarfile
import tempfile
import unittest
from pathlib import Path

import build_db as b


class Pinyin(unittest.TestCase):
    def test_marks(self):
        cases = {"qing1 chu5": "qīng chu", "lu:4": "lǜ", "nu:3": "nǚ", "hao3": "hǎo",
                 "gou3": "gǒu", "xue2": "xué", "gui4": "guì", "liu2": "liú", "er4": "èr",
                 "Zhong1": "Zhōng", "r5": "r", "m2": "m", "lve4": "lüè", "zhuang4": "zhuàng"}
        for src, want in cases.items():
            self.assertEqual(b.numbered_to_marked(src), want, src)

    def test_strip(self):
        self.assertEqual(b.strip_tones("qīng chu"), "qingchu")
        self.assertEqual(b.strip_tones("qing1chu5"), "qingchu")
        self.assertEqual(b.strip_tones("lǜ"), "lü")


class Cedict(unittest.TestCase):
    def test_parse(self):
        lines = [
            "# comment",
            "清楚 清楚 [qing1 chu5] /clear/distinct/to understand/",
            "張 张 [Zhang1] /surname Zhang/",
            "張 张 [zhang1] /sheet of paper/CL:個|个[ge4]/to open/",
            "妳 你 [ni3] /variant of 你[ni3]/",
            "你 你 [ni3] /you (informal)/",
        ]
        d = b.parse_cedict(lines)
        self.assertEqual(d["清楚"].pinyin, "qīng chu")
        self.assertEqual(d["清楚"].glosses, ["clear", "distinct", "to understand"])
        self.assertFalse(d["张"].proper)
        self.assertEqual(d["张"].trad, "張")
        self.assertEqual(d["张"].glosses, ["sheet of paper", "to open"])  # CL: dropped
        self.assertIn("you (informal)", d["你"].glosses)


def make_wordnet_tar(path: Path):
    files = {
        "lexnames": "13 noun.food 1\n",
        "data.noun": "  copyright line\n"
                     "07123456 13 n 01 apple 0 000 | fruit with red or yellow or green skin; \"an apple a day\"\n",
        "index.noun": "  copyright\napple n 1 1 @ 1 1 07123456  \n",
    }
    for p in ("verb", "adj", "adv"):
        files[f"data.{p}"] = "  c\n"
        files[f"index.{p}"] = "  c\n"
    with tarfile.open(path, "w:gz") as tf:
        for name, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(f"dict/{name}")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))


class WordNet(unittest.TestCase):
    def test_parse(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "wn.tar.gz"
            make_wordnet_tar(p)
            wn = b.parse_wordnet(p)
        s = wn["apple"][0]
        self.assertEqual(s.definition, "fruit with red or yellow or green skin")
        self.assertEqual(s.example, "an apple a day")
        self.assertEqual(s.category, "food")


class Tatoeba(unittest.TestCase):
    def test_mono(self):
        sents = {1: "I eat an apple every day.", 2: "Apple.", 3: "The cat sleeps on the warm mat."}
        best = b.best_monolingual_examples(sents, {"apple", "cat"})
        self.assertEqual(best["apple"], "I eat an apple every day.")
        self.assertIn("cat", best)

    def test_zh(self):
        cmn = {1: "我听不清楚。", 2: "清楚"}
        links = {"en": {1: [10]}, "es": {1: [20]}}
        trans = {"en": {10: "I can't hear clearly."}, "es": {20: "No oigo bien."}}
        best = b.best_zh_examples(cmn, links, trans, {"清楚", "我"})
        self.assertEqual(best["清楚"][0], "我听不清楚。")
        self.assertEqual(best["清楚"][1]["es"], "No oigo bien.")


def jsonl_gz(path: Path, recs):
    with gzip.open(path, "wt", encoding="utf-8") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")


class Pipeline(unittest.TestCase):
    def test_dictionary_words_and_db(self):
        recs = [
            {"word": "run", "lang_code": "en", "pos": "verb", "sounds": [{"ipa": "/ɹʌn/", "tags": ["US"]}],
             "senses": [{"glosses": ["To move swiftly on foot."], "topics": ["sports"],
                         "examples": [{"text": "I run to the store every morning.", "type": "example"}]}],
             "translations": [{"lang_code": "es", "word": "correr", "sense": "move fast"},
                              {"lang_code": "cmn", "word": "跑", "sense": "move fast"}]},
            {"word": "ran", "lang_code": "en", "pos": "verb",
             "senses": [{"glosses": ["simple past of run"], "form_of": [{"word": "run"}]}]},
            {"word": "Paris", "lang_code": "en", "pos": "name", "senses": [{"glosses": ["city"]}]},
            {"word": "correr", "lang_code": "es", "pos": "verb", "senses": [{"glosses": ["x"]}]},
        ]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "en.jsonl.gz"
            jsonl_gz(p, recs)
            entries, redirects, tables = b.collect_wiktionary(p, "en", {"run", "ran", "Paris"})
            self.assertEqual(redirects, {"ran": "run"})
            self.assertNotIn("Paris", entries)
            self.assertIn(("run", "move fast", {"es": ["correr"], "zh": ["跑"]}), tables)
            words = b.build_dictionary_words("en", ["ran", "run", "Paris"], entries, redirects, None, {})
            self.assertEqual([w.lemma for w in words], ["run"])
            w = words[0]
            self.assertEqual(w.freq_rank, 1)
            self.assertEqual(w.ipa, "/ɹʌn/")
            self.assertIn("sports", w.categories)
            self.assertEqual(w.senses[0].example, "I run to the store every morning.")
            zh = b.Word("zh", "清楚", "adj", 1, 3, None, "qīng chu", None, {"emotions"},
                        [b.Sense("adj", "en", "clear", "我听不清楚。", "I can't hear clearly.", "en", "tatoeba")],
                        {"en": ["clear"]})
            db = Path(d) / "t.sqlite"
            b.write_db(db, words + [zh])
            md, flags = b.coverage(db)
            self.assertIn("| en | example sentence | 1 / 1 | 100.0% |", md)
            self.assertIn("zh: translation zh→es = 0.0%", flags)
            import sqlite3
            c = sqlite3.connect(db)
            self.assertEqual(c.execute("SELECT text FROM word_search WHERE word_id=2").fetchone()[0],
                             "清楚 | qingchu | clear")
            plan = " ".join(r[-1] for r in c.execute(
                "EXPLAIN QUERY PLAN SELECT id FROM word WHERE lang='en' AND level>=1 ORDER BY freq_rank"))
            self.assertIn("word_pick", plan)


class Misc(unittest.TestCase):
    def test_levels(self):
        self.assertEqual([b.rank_band_level(r) for r in (1, 500, 501, 3000, 5001, 9999)], [1, 1, 2, 3, 5, 6])

    def test_categories(self):
        self.assertEqual(b.categories_from_labels(["en:Foods", "Medicine", "Time", "chemistry"]),
                         {"food", "health", "time", "science"})
        # regression: maintenance categories must not match by token
        self.assertEqual(b.categories_from_labels(["Pages with etymology trees", "Chinese hanzi"]), set())

    def test_simplified_part(self):
        self.assertEqual(b.simplified_part("我聽不清楚。／我听不清楚。"), "我听不清楚。")


if __name__ == "__main__":
    unittest.main()


class RealShapes(unittest.TestCase):
    """Record shapes copied from the 2026-10-05 wiktextract dumps (see tools/inspect.txt)."""

    def test_spanish_plural_merges_into_lemma(self):
        entries = {"años": [{"pos": "noun", "pos_title": "Sustantivo masculino y plural",
                             "senses": [{"glosses": ["Día en que se cumplen años."]}]}],
                   "año": [{"pos": "noun", "pos_title": "Sustantivo masculino", "senses": [{"glosses": ["x"]}]}],
                   "left": [{"pos": "noun", "senses": [{"glosses": ["The left side."]}]}],
                   "leave": [{"pos": "verb", "senses": [{"glosses": ["To go away."]}]}]}
        redirects = {"años": "año", "left": "leave", "fue": "ir"}
        self.assertEqual(b.choose_lemma("años", entries, redirects), "año")
        self.assertEqual(b.choose_lemma("left", entries, redirects), "left")
        self.assertIsNone(b.choose_lemma("fue", entries, redirects))  # 'ir' not collected

    def test_zh_pos_and_example(self):
        trad = {"pos": "character", "senses": [
            {"glosses": ["to allow; to let; to permit"],
             "categories": [{"name": "Chinese hanzi"}, {"name": "Chinese verbs"}],
             "examples": [
                 {"tags": ["Traditional-Chinese"], "translation": "Mum won't let me go.", "text": "媽媽不讓我去。"},
                 {"tags": ["Simplified-Chinese"], "translation": "Mum won't let me go.", "text": "妈妈不让我去。"}]},
            {"glosses": ["a transliteration of the French name Jean"],
             "examples": [{"tags": ["Simplified-Chinese"], "translation": "Jean-Jacques Rousseau",
                           "text": "让-雅克·卢梭"}]}]}
        simp = {"pos": "character", "senses": [{"tags": ["no-gloss"]}]}
        self.assertEqual(b.zh_pos([simp, trad]), "verb")
        self.assertEqual(b.zh_wikt_example([simp, trad], "让"), ("妈妈不让我去。", "Mum won't let me go."))
        self.assertEqual(b.zh_pos([{"pos": "soft-redirect"}, {"pos": "noun"}]), "noun")

    def test_cedict_gloss_cleaning(self):
        g = ["of", "~'s (possessive particle)",
             "(used after a noun, verb or adjective to form a nominal expression, as in 皮革的[pi2 ge2 de5])"]
        self.assertEqual(b.clean_glosses(g), ["of", "~'s (possessive particle)"])

    def test_parent_gloss_for_ellipsis(self):
        s = {"glosses": ["Definite article.", "...because it has already been mentioned."]}
        self.assertEqual(b.sense_gloss(s), "Definite article.")
