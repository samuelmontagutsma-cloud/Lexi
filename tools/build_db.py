#!/usr/bin/env python3
"""Build Lexi's bundled lexicon (lexi.sqlite) from free, redistributable sources.

Decks (scope approved 2026-10-04):
  en  Dictionary mode: en word, en definition, en example
  es  Dictionary mode: es word, es definition, es example
  zh  Learn mode:      zh word + pinyin, en/es translation, zh example + en/es translation

Usage:
  python build_db.py --probe            # check every source URL and print record shapes
  python build_db.py --out lexi.sqlite  # full build + coverage_report.md

Only stdlib + wordfreq. Downloads are cached in tools/.cache.
"""
from __future__ import annotations

import argparse
import bz2
import collections
import gzip
import io
import json
import os
import re
import sqlite3
import sys
import tarfile
import time
import unicodedata
import urllib.request
import zlib
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = Path(os.environ.get("LEXI_CACHE", HERE / ".cache"))
TOP_N = 10_000
UA = {"User-Agent": "Lexi-build/1.0 (personal offline vocabulary app)"}

# ---------------------------------------------------------------- sources
# Each source lists candidate URLs. The first one that answers is used.
SOURCES = {
    "wikt_en_English": [
        "https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl.gz",
        "https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl",
    ],
    "wikt_en_Chinese": [
        "https://kaikki.org/dictionary/Chinese/kaikki.org-dictionary-Chinese.jsonl.gz",
        "https://kaikki.org/dictionary/Chinese/kaikki.org-dictionary-Chinese.jsonl",
    ],
    "wikt_es_raw": [
        "https://kaikki.org/eswiktionary/raw-wiktextract-data.jsonl.gz",
        "https://kaikki.org/eswiktionary/raw-wiktextract-data.json.gz",
    ],
    "cedict": [
        "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz",
    ],
    "wordnet31": [
        "https://wordnetcode.princeton.edu/wn3.1.dict.tar.gz",
    ],
    "hsk": [
        "https://raw.githubusercontent.com/drkameleon/complete-hsk-vocabulary/main/complete.json",
        "https://raw.githubusercontent.com/drkameleon/complete-hsk-vocabulary/master/complete.json",
    ],
    "tatoeba_cmn": ["https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences.tsv.bz2"],
    "tatoeba_eng": ["https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2"],
    "tatoeba_spa": ["https://downloads.tatoeba.org/exports/per_language/spa/spa_sentences.tsv.bz2"],
    "tatoeba_cmn_eng": ["https://downloads.tatoeba.org/exports/per_language/cmn/cmn-eng_links.tsv.bz2"],
    "tatoeba_cmn_spa": ["https://downloads.tatoeba.org/exports/per_language/cmn/cmn-spa_links.tsv.bz2"],
}

CREDITS = [
    ("Wiktionary (via wiktextract / kaikki.org)", "CC BY-SA 4.0 and GFDL",
     "https://en.wiktionary.org, https://es.wiktionary.org, https://kaikki.org"),
    ("WordNet 3.1, Princeton University", "WordNet License (BSD-style)",
     "https://wordnet.princeton.edu/license-and-commercial-use"),
    ("CC-CEDICT (MDBG)", "CC BY-SA 4.0", "https://cc-cedict.org/wiki/"),
    ("Tatoeba sentences", "CC BY 2.0 FR", "https://tatoeba.org/en/terms_of_use"),
    ("wordfreq (Robyn Speer)", "Data CC BY-SA 4.0; code Apache 2.0",
     "https://github.com/rspeer/wordfreq"),
    ("complete-hsk-vocabulary (drkameleon)", "MIT",
     "https://github.com/drkameleon/complete-hsk-vocabulary"),
]

EXCLUDED_POS = {"name", "proper noun", "prefix", "suffix", "infix", "interfix", "affix",
                "circumfix", "symbol", "character", "punct", "punctuation", "letter",
                "abbrev", "abbreviation", "initialism", "acronym", "contraction",
                "romanization", "phrase", "proverb", "soft-redirect", "unknown"}

# ---------------------------------------------------------------- categories
CATEGORIES = ["business", "science", "food", "travel", "emotions", "nature", "technology",
              "art", "health", "society", "sports", "education", "home", "body", "time"]

# keyword (lowercase, matched against wiktextract topics/categories) -> category
TOPIC_KEYWORDS = {
    "business": ["business", "finance", "economics", "commerce", "trade", "banking",
                 "accounting", "marketing", "management", "money", "currency"],
    "science": ["science", "physics", "chemistry", "biology", "mathematics", "astronomy",
                "geology", "statistics", "biochemistry", "genetics", "sciences"],
    "food": ["cooking", "food", "foods", "beverages", "drinks", "cuisine", "culinary",
             "fruits", "vegetables", "dishes", "baking", "alimentos", "gastronomía"],
    "travel": ["travel", "transport", "tourism", "aviation", "nautical", "vehicles",
               "railways", "automotive", "geography", "hospitality"],
    "emotions": ["emotions", "emotion", "feelings", "psychology", "love", "emociones",
                 "sentimientos"],
    "nature": ["nature", "botany", "zoology", "plants", "animals", "weather", "climate",
               "meteorology", "ecology", "birds", "fish", "trees", "flowers", "insects"],
    "technology": ["computing", "technology", "electronics", "internet", "software",
                   "engineering", "telecommunications", "informática", "tecnología"],
    "art": ["art", "arts", "music", "literature", "painting", "architecture", "theater",
            "theatre", "film", "dance", "poetry", "photography", "música", "arte"],
    "health": ["medicine", "medical", "pathology", "pharmacology", "disease", "diseases",
               "health", "dentistry", "nursing", "medicina", "enfermedades"],
    "society": ["law", "legal", "politics", "government", "religion", "military",
                "sociology", "society", "history", "war", "crime", "derecho", "política"],
    "sports": ["sports", "sport", "games", "football", "soccer", "baseball", "basketball",
               "tennis", "athletics", "deportes"],
    "education": ["education", "school", "university", "linguistics", "grammar",
                  "educación"],
    "home": ["furniture", "household", "clothing", "clothes", "tools", "kitchen",
             "housing", "home", "ropa", "hogar"],
    "body": ["anatomy", "body", "physiology", "body parts", "anatomía"],
    "time": ["time", "calendar", "chronology", "days of the week", "months", "tiempo"],
}
KEYWORD_TO_CAT = {k: c for c, ks in TOPIC_KEYWORDS.items() for k in ks}

WORDNET_LEXFILE_TO_CAT = {
    "noun.food": "food", "noun.plant": "nature", "noun.animal": "nature",
    "noun.phenomenon": "nature", "noun.object": "nature", "noun.feeling": "emotions",
    "verb.emotion": "emotions", "noun.body": "body", "verb.body": "body",
    "noun.time": "time", "noun.location": "travel", "verb.motion": "travel",
    "noun.group": "society", "verb.social": "society", "noun.possession": "business",
    "verb.possession": "business", "verb.competition": "sports",
    "verb.consumption": "food", "verb.weather": "nature", "noun.state": "health",
}


def categories_from_labels(labels) -> set[str]:
    out = set()
    for lab in labels:
        s = str(lab).lower()
        s = re.sub(r"^[a-z]{2,3}:", "", s)  # "en:Foods" -> "foods"
        if s in KEYWORD_TO_CAT:
            out.add(KEYWORD_TO_CAT[s])
            continue
        for tok in re.split(r"[\s_/-]+", s):
            if tok in KEYWORD_TO_CAT:
                out.add(KEYWORD_TO_CAT[tok])
    return out


# ---------------------------------------------------------------- download / IO
def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def fetch(name: str) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    errors = []
    for url in SOURCES[name]:
        dest = CACHE / f"{name}__{url.rsplit('/', 1)[-1]}"
        if dest.exists() and dest.stat().st_size > 0:
            return dest
        try:
            log(f"download {name}: {url}")
            req = urllib.request.Request(url, headers=UA)
            tmp = dest.with_suffix(dest.suffix + ".part")
            with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
            tmp.rename(dest)
            log(f"  ok {dest.stat().st_size / 1e6:.1f} MB")
            return dest
        except Exception as e:  # try next candidate
            errors.append(f"{url}: {e}")
    raise RuntimeError(f"all URLs failed for {name}:\n  " + "\n  ".join(errors))


def open_text(path: Path):
    p = str(path)
    if p.endswith(".gz"):
        return io.TextIOWrapper(gzip.open(path, "rb"), encoding="utf-8")
    if p.endswith(".bz2"):
        return io.TextIOWrapper(bz2.open(path, "rb"), encoding="utf-8")
    return open(path, encoding="utf-8")


def iter_jsonl(path: Path):
    with open_text(path) as f:
        for line in f:
            if line.strip():
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue


# ---------------------------------------------------------------- pinyin
_TONE = {"a": "āáǎà", "e": "ēéěè", "i": "īíǐì", "o": "ōóǒò", "u": "ūúǔù", "ü": "ǖǘǚǜ"}


def numbered_syllable_to_marked(syl: str) -> str:
    """'qing1' -> 'qīng', 'lu:4' -> 'lǜ', 'ma5' -> 'ma'. Non-pinyin text is returned unchanged."""
    m = re.fullmatch(r"([A-Za-zü:v]+)([1-5])", syl)
    if not m:
        return syl.replace("u:", "ü").replace("U:", "Ü")
    body, tone = m.group(1), int(m.group(2))
    body = body.replace("u:", "ü").replace("U:", "Ü").replace("v", "ü").replace("V", "Ü")
    if tone == 5:
        return body
    low = body.lower()
    # placement rule: a or e takes the mark; in "ou" the o; otherwise the last vowel
    if "a" in low:
        idx = low.index("a")
    elif "e" in low:
        idx = low.index("e")
    elif "ou" in low:
        idx = low.index("o")
    else:
        idx = max((i for i, ch in enumerate(low) if ch in "aeiouü"), default=-1)
        if idx < 0:
            return body  # e.g. "r5", "m2" interjections
    ch = low[idx]
    marked = _TONE[ch][tone - 1]
    if body[idx].isupper():
        marked = marked.upper()
    return body[:idx] + marked + body[idx + 1:]


def numbered_to_marked(pinyin: str) -> str:
    return " ".join(numbered_syllable_to_marked(s) for s in pinyin.split())


def strip_tones(pinyin: str) -> str:
    """For answer checking: 'qīng chu' -> 'qingchu'; 'qing1chu5' -> 'qingchu'."""
    s = unicodedata.normalize("NFD", pinyin.lower())
    s = "".join(c for c in s if unicodedata.category(c) != "Mn" or c == "̈")
    s = unicodedata.normalize("NFC", s)
    return re.sub(r"[\s\d'·-]", "", s)


# ---------------------------------------------------------------- CC-CEDICT
CEDICT_RE = re.compile(r"^(\S+) (\S+) \[([^\]]*)\] /(.*)/\s*$")
CEDICT_SKIP = re.compile(r"^(old )?variant of|^surname |^CL:|^used in |^see |^abbr\. for|^erhua variant",
                         re.I)


@dataclass
class CedictEntry:
    trad: str
    simp: str
    pinyin: str  # marked
    glosses: list[str]
    proper: bool


def parse_cedict(lines) -> dict[str, CedictEntry]:
    out: dict[str, CedictEntry] = {}
    for line in lines:
        if line.startswith("#"):
            continue
        m = CEDICT_RE.match(line.rstrip("\n"))
        if not m:
            continue
        trad, simp, pin, gl = m.groups()
        glosses = [g.strip() for g in gl.split("/") if g.strip() and not CEDICT_SKIP.search(g.strip())]
        proper = pin[:1].isupper()
        e = CedictEntry(trad, simp, numbered_to_marked(pin), glosses, proper)
        prev = out.get(simp)
        if prev is None:
            out[simp] = e
        elif prev.proper and not proper:
            out[simp] = e  # common word wins over proper noun
        elif prev.proper == proper and not prev.glosses and glosses:
            out[simp] = e
        elif prev.proper == proper and prev.pinyin == e.pinyin:
            prev.glosses += [g for g in glosses if g not in prev.glosses]
    return out


# ---------------------------------------------------------------- WordNet
@dataclass
class WNSense:
    pos: str
    definition: str
    example: str | None
    category: str | None


WN_POS = {"noun": "noun", "verb": "verb", "adj": "adj", "adv": "adv"}


def parse_wordnet(tar_path: Path) -> dict[str, list[WNSense]]:
    """lemma -> senses in WordNet sense-frequency order."""
    lexnames: dict[int, str] = {}
    data: dict[tuple[str, int], WNSense] = {}
    index: dict[str, list[tuple[str, int]]] = collections.defaultdict(list)
    with tarfile.open(tar_path, "r:gz") as tf:
        members = {Path(m.name).name: m for m in tf.getmembers() if m.isfile()}
        if "lexnames" in members:
            for line in tf.extractfile(members["lexnames"]).read().decode().splitlines():
                parts = line.split()
                if len(parts) >= 2:
                    lexnames[int(parts[0])] = parts[1]
        for wpos in WN_POS:
            raw = tf.extractfile(members[f"data.{wpos}"]).read().decode("utf-8", "replace")
            for line in raw.splitlines():
                if line.startswith("  "):
                    continue
                head, _, gloss = line.partition(" | ")
                f = head.split()
                offset, lexfile = int(f[0]), int(f[1], 10)
                defn, ex = split_wn_gloss(gloss)
                data[(wpos, offset)] = WNSense(WN_POS[wpos], defn, ex,
                                               WORDNET_LEXFILE_TO_CAT.get(lexnames.get(lexfile, "")))
            raw = tf.extractfile(members[f"index.{wpos}"]).read().decode("utf-8", "replace")
            for line in raw.splitlines():
                if line.startswith("  "):
                    continue
                f = line.split()
                lemma, p_cnt = f[0], int(f[3])
                synset_cnt = int(f[2])
                offsets = f[4 + p_cnt + 2:]
                for off in offsets[:synset_cnt]:
                    index[lemma.replace("_", " ")].append((wpos, int(off)))
    out = {}
    for lemma, keys in index.items():
        out[lemma] = [data[k] for k in keys if k in data]
    return out


def split_wn_gloss(gloss: str) -> tuple[str, str | None]:
    parts = [p.strip() for p in gloss.strip().split(";")]
    defs, ex = [], None
    for p in parts:
        if p.startswith('"'):
            if ex is None:
                ex = p.strip('" ')
        elif p:
            defs.append(p)
    return "; ".join(defs), ex


# ---------------------------------------------------------------- Tatoeba
def load_tatoeba_sentences(path: Path) -> dict[int, str]:
    out = {}
    with open_text(path) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                try:
                    out[int(parts[0])] = parts[2]
                except ValueError:
                    pass
    return out


def load_tatoeba_links(path: Path) -> dict[int, list[int]]:
    out = collections.defaultdict(list)
    with open_text(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                out[int(parts[0])].append(int(parts[1]))
    return out


TOKEN_RE = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)?", re.UNICODE)


def example_score(text: str) -> float:
    """Lower is better. Prefers 30-90 character, single-sentence examples."""
    n = len(text)
    s = abs(n - 60)
    if n < 15 or n > 160:
        s += 1000
    if text.count(".") + text.count("?") + text.count("!") > 1:
        s += 40
    return s


def best_monolingual_examples(sentences: dict[int, str], targets: set[str]) -> dict[str, str]:
    best: dict[str, tuple[float, str]] = {}
    for text in sentences.values():
        sc = example_score(text)
        if sc >= 1000:
            continue
        for tok in set(t.lower() for t in TOKEN_RE.findall(text)):
            if tok in targets and (tok not in best or sc < best[tok][0]):
                best[tok] = (sc, text)
    return {k: v[1] for k, v in best.items()}


def zh_example_score(text: str) -> float:
    n = len(text)
    s = abs(n - 12)
    if n < 4 or n > 40:
        s += 1000
    return s


def best_zh_examples(cmn: dict[int, str], links: dict[str, dict[int, list[int]]],
                     trans: dict[str, dict[int, str]], targets: set[str], max_len: int = 4):
    """word -> (zh sentence, {lang: translation}). Prefers sentences translated to both en and es."""
    best: dict[str, tuple[float, str, dict]] = {}
    for sid, text in cmn.items():
        tr = {}
        for lang in ("en", "es"):
            for tid in links[lang].get(sid, []):
                if tid in trans[lang]:
                    tr[lang] = trans[lang][tid]
                    break
        if not tr:
            continue
        sc = zh_example_score(text) - 5 * len(tr)
        if sc >= 990:
            continue
        seen = set()
        for i in range(len(text)):
            for j in range(i + 1, min(len(text), i + max_len) + 1):
                w = text[i:j]
                if w in targets and w not in seen:
                    seen.add(w)
                    if w not in best or sc < best[w][0]:
                        best[w] = (sc, text, tr)
    return {k: (v[1], v[2]) for k, v in best.items()}


# ---------------------------------------------------------------- Wiktionary helpers
def is_form_of(sense: dict) -> str | None:
    for key in ("form_of", "alt_of"):
        v = sense.get(key)
        if v:
            w = v[0].get("word") if isinstance(v[0], dict) else None
            if w:
                return w
    return None


def sense_gloss(sense: dict) -> str | None:
    g = sense.get("glosses") or sense.get("raw_glosses") or []
    if not g:
        return None
    text = g[-1] if len(g) > 1 else g[0]  # last gloss is the most specific in wiktextract
    text = re.sub(r"\s+", " ", str(text)).strip()
    return text or None


def sense_example(sense: dict) -> tuple[str | None, str | None]:
    """(example text, english/translation if any). Skips long quotations."""
    best = None
    for ex in sense.get("examples") or []:
        if not isinstance(ex, dict):
            continue
        if ex.get("type") == "quotation" or ex.get("ref"):
            continue
        t = (ex.get("text") or "").strip()
        if not t:
            continue
        tr = ex.get("translation") or ex.get("english")
        sc = example_score(t)
        if best is None or sc < best[0]:
            best = (sc, t, tr)
    if best and best[0] < 1000:
        return best[1], best[2]
    return None, None


def entry_ipa(entry: dict, prefer_tags=("US", "General-American", "General American")) -> str | None:
    ipas = [(s.get("ipa"), s.get("tags") or []) for s in entry.get("sounds") or [] if s.get("ipa")]
    if not ipas:
        return None
    for ipa, tags in ipas:
        if any(t in tags for t in prefer_tags):
            return ipa
    return ipas[0][0]


def entry_labels(entry: dict, sense: dict | None = None) -> list[str]:
    labs = []
    for src in ([sense] if sense else []) + [entry]:
        for key in ("topics", "categories"):
            for c in src.get(key) or []:
                labs.append(c.get("name") if isinstance(c, dict) else c)
    return [l for l in labs if l]


# ---------------------------------------------------------------- word model
@dataclass
class Sense:
    pos: str | None
    def_lang: str
    definition: str | None
    example: str | None = None
    example_translation: str | None = None
    example_translation_lang: str | None = None
    example_source: str | None = None


@dataclass
class Word:
    lang: str
    lemma: str
    pos: str | None
    freq_rank: int
    level: int = 0
    ipa: str | None = None
    pinyin: str | None = None
    traditional: str | None = None
    categories: set = field(default_factory=set)
    senses: list = field(default_factory=list)
    translations: dict = field(default_factory=dict)  # lang -> [gloss]

    @property
    def key(self):
        return f"{self.lang}:{self.lemma}"


def rank_band_level(rank: int) -> int:
    """CEFR-like band from frequency rank: 1=A1 .. 6=C2."""
    for lvl, upper in enumerate((500, 1500, 3000, 5000, 8000), start=1):
        if rank <= upper:
            return lvl
    return 6


# ---------------------------------------------------------------- language builders
def collect_wiktionary(path: Path, lang_code: str, candidates: set[str]):
    """Return (entries_by_word, redirects, translation_tables)."""
    entries = collections.defaultdict(list)
    redirects: dict[str, str] = {}
    tables = []  # list of (english sense label, {lang: [words]}) for bridging
    for e in iter_jsonl(path):
        if e.get("lang_code") != lang_code:
            continue
        w = e.get("word")
        if not w:
            continue
        pos = (e.get("pos") or "").lower()
        all_tr = list(e.get("translations") or [])
        for s_ in e.get("senses") or []:
            all_tr += s_.get("translations") or []
        if lang_code == "en" and all_tr:
            groups = collections.defaultdict(lambda: collections.defaultdict(list))
            for t in all_tr:
                code = t.get("lang_code") or t.get("code")
                lang = t.get("lang") or ""
                tw = t.get("word")
                if not tw:
                    continue
                if code in ("cmn", "zh") or lang in ("Mandarin", "Chinese Mandarin"):
                    groups[t.get("sense") or ""]["zh"].append(tw)
                elif code == "es" or lang == "Spanish":
                    groups[t.get("sense") or ""]["es"].append(tw)
            for sense_label, g in groups.items():
                tables.append((w, sense_label, dict(g)))
        if w not in candidates or pos in EXCLUDED_POS:
            continue
        senses = e.get("senses") or []
        targets = {is_form_of(s) for s in senses}
        if senses and None not in targets:
            redirects.setdefault(w, next(iter(targets)))
            continue
        entries[w].append(e)
    return entries, redirects, tables


def build_dictionary_words(lang, freq_list, entries, redirects, wordnet, tatoeba_best):
    """Rank lemmas by first appearance in the frequency list; keep TOP_N with a definition."""
    words: dict[str, Word] = {}
    order = []
    for w in freq_list:
        lemma = w if w in entries else redirects.get(w, w)
        if lemma in words or lemma not in entries and not (wordnet and lemma in wordnet):
            continue
        if not re.fullmatch(r"[^\W\d_]+(?:[-'’ ][^\W\d_]+)*", lemma):
            continue
        words[lemma] = None
        order.append(lemma)
        if len(order) >= TOP_N:
            break
    out = []
    for rank, lemma in enumerate(order, start=1):
        es = entries.get(lemma, [])
        senses: list[Sense] = []
        cats: set[str] = set()
        ipa = None
        primary_pos = None
        for e in es:
            pos = (e.get("pos") or "").lower() or None
            ipa = ipa or entry_ipa(e)
            cats |= categories_from_labels(entry_labels(e))
            for s in e.get("senses") or []:
                if is_form_of(s):
                    continue
                g = sense_gloss(s)
                if not g:
                    continue
                if "tags" in s and any(t in ("obsolete", "archaic", "rare") for t in s["tags"]):
                    continue
                primary_pos = primary_pos or pos
                ex, _ = sense_example(s)
                cats |= categories_from_labels(entry_labels({}, s))
                senses.append(Sense(pos, lang, g, ex, None, None, "wiktionary" if ex else None))
        if wordnet and lemma in wordnet:
            wn = wordnet[lemma]
            for s in wn:
                if s.category:
                    cats.add(s.category)
            if not senses:
                for s in wn[:3]:
                    senses.append(Sense(s.pos, lang, s.definition, s.example, None, None,
                                        "wordnet" if s.example else None))
                primary_pos = primary_pos or (wn[0].pos if wn else None)
            elif not any(s.example for s in senses[:3]):
                ex = next((s.example for s in wn if s.example and lemma in s.example.lower()), None)
                if ex:
                    senses[0].example, senses[0].example_source = ex, "wordnet"
        senses = senses[:3]
        if senses and not any(s.example for s in senses) and lemma.lower() in tatoeba_best:
            senses[0].example, senses[0].example_source = tatoeba_best[lemma.lower()], "tatoeba"
        if not senses:
            continue
        out.append(Word(lang, lemma, primary_pos, rank, rank_band_level(rank), ipa,
                        categories=cats, senses=senses))
    return out


def build_english(wordnet, tables_out: list) -> list[Word]:
    import wordfreq
    freq = wordfreq.top_n_list("en", 60_000)
    log("en: scanning English Wiktionary")
    entries, redirects, tables = collect_wiktionary(fetch("wikt_en_English"), "en", set(freq))
    tables_out.extend(tables)
    log(f"en: {len(entries)} entries, {len(redirects)} form redirects, {len(tables)} translation groups")
    tat = best_monolingual_examples(load_tatoeba_sentences(fetch("tatoeba_eng")), {w.lower() for w in freq})
    words = build_dictionary_words("en", freq, entries, redirects, wordnet, tat)
    return words


def build_spanish(en_words: list[Word], tables) -> tuple[list[Word], dict[str, list[str]]]:
    import wordfreq
    freq = wordfreq.top_n_list("es", 60_000)
    log("es: scanning Spanish Wiktionary")
    path = fetch("wikt_es_raw")
    entries, redirects, _ = collect_wiktionary(path, "es", set(freq))
    zh_es = collections.defaultdict(list)  # zh word -> Spanish glosses from es-wiktionary
    for e in iter_jsonl(path):
        if e.get("lang_code") in ("zh", "cmn") and e.get("word"):
            for s in e.get("senses") or []:
                g = sense_gloss(s)
                if g and not is_form_of(s) and g not in zh_es[e["word"]]:
                    zh_es[e["word"]].append(g)
    log(f"es: {len(entries)} entries, {len(redirects)} redirects, {len(zh_es)} zh entries with es glosses")
    tat = best_monolingual_examples(load_tatoeba_sentences(fetch("tatoeba_spa")), {w.lower() for w in freq})
    words = build_dictionary_words("es", freq, entries, redirects, None, tat)
    # categories bridged from English via translation tables
    en_cats = {w.lemma: w.categories for w in en_words}
    es_cats = collections.defaultdict(set)
    for en_word, _, g in tables:
        for es_word in g.get("es", []):
            es_cats[es_word] |= en_cats.get(en_word, set())
    for w in words:
        w.categories |= es_cats.get(w.lemma, set())
    return words, zh_es


def build_chinese(en_words, tables, zh_es_wikt) -> list[Word]:
    import wordfreq
    cedict = parse_cedict(open_text(fetch("cedict")))
    log(f"zh: {len(cedict)} CC-CEDICT headwords")
    hsk = load_hsk(fetch("hsk"))
    log(f"zh: {len(hsk)} HSK 2.0 words")
    freq = wordfreq.top_n_list("zh", 40_000)
    order = []
    for w in freq:
        e = cedict.get(w)
        if not e or e.proper or not e.glosses or not re.fullmatch(r"[㐀-鿿]+", w):
            continue
        order.append(w)
        if len(order) >= TOP_N:
            break
    targets = set(order)
    # en-wiktionary Chinese entries (simplified or traditional headword): pos + examples
    log("zh: scanning Chinese entries in English Wiktionary")
    trad_to_simp = {cedict[w].trad: w for w in order if cedict[w].trad != w}
    wk = collections.defaultdict(list)
    for e in iter_jsonl(fetch("wikt_en_Chinese")):
        w = e.get("word")
        key = w if w in targets else trad_to_simp.get(w)
        if key:
            wk[key].append(e)
    # Tatoeba zh examples with en/es translations
    log("zh: Tatoeba sentence pairs")
    cmn = load_tatoeba_sentences(fetch("tatoeba_cmn"))
    trans = {"en": load_tatoeba_sentences(fetch("tatoeba_eng")),
             "es": load_tatoeba_sentences(fetch("tatoeba_spa"))}
    links = {"en": load_tatoeba_links(fetch("tatoeba_cmn_eng")),
             "es": load_tatoeba_links(fetch("tatoeba_cmn_spa"))}
    tat = best_zh_examples(cmn, links, trans, targets)
    # zh -> es bridge through shared English translation-table senses
    bridge = collections.defaultdict(collections.Counter)
    for _, _, g in tables:
        for zw in g.get("zh", []):
            zw = zw.split()[0]
            zs = zw if zw in targets else trad_to_simp.get(zw)
            if zs:
                for sw in g.get("es", []):
                    bridge[zs][sw] += 1
    en_cats = {w.lemma: w.categories for w in en_words}
    out = []
    for rank, w in enumerate(order, start=1):
        ce = cedict[w]
        pos, ex, ex_en = None, None, None
        cats = set()
        for e in wk.get(w, []):
            pos = pos or (e.get("pos") or "").lower() or None
            cats |= categories_from_labels(entry_labels(e))
            for s in e.get("senses") or []:
                if ex is None:
                    t, tr = sense_example(s)
                    if t and w in t:
                        ex, ex_en = simplified_part(t), tr
        en_gl = ce.glosses[:4]
        for g in en_gl:  # bridge categories from single-word English glosses
            key = re.sub(r"^to ", "", g.split(";")[0]).strip()
            cats |= en_cats.get(key, set())
        es_gl = zh_es_wikt.get(w) or zh_es_wikt.get(ce.trad) or []
        if not es_gl and bridge.get(w):
            es_gl = [sw for sw, _ in bridge[w].most_common(3)]
        senses = []
        tat_ex = tat.get(w)
        # en sense
        e_ex, e_tr, e_src = ex, ex_en, "wiktionary" if ex else None
        if (not e_ex or not e_tr) and tat_ex and "en" in tat_ex[1]:
            e_ex, e_tr, e_src = tat_ex[0], tat_ex[1]["en"], "tatoeba"
        senses.append(Sense(pos, "en", "; ".join(en_gl), e_ex, e_tr, "en" if e_tr else None, e_src))
        if es_gl:
            s_ex, s_tr, s_src = None, None, None
            if tat_ex and "es" in tat_ex[1]:
                s_ex, s_tr, s_src = tat_ex[0], tat_ex[1]["es"], "tatoeba"
            elif e_ex:
                s_ex, s_src = e_ex, e_src  # zh example without a Spanish translation
            senses.append(Sense(pos, "es", "; ".join(es_gl[:3]), s_ex, s_tr, "es" if s_tr else None, s_src))
        word = Word("zh", w, pos, rank, hsk.get(w, 7), None, ce.pinyin,
                    ce.trad if ce.trad != w else None, cats, senses,
                    {"en": [short_gloss(g) for g in en_gl[:3]]})
        if es_gl:
            word.translations["es"] = [short_gloss(g) for g in es_gl[:3]]
        out.append(word)
    return out


def simplified_part(text: str) -> str:
    """wiktextract often gives 'trad／simp' or 'trad / simp'; keep the last (simplified) part."""
    for sep in ("／", " / "):
        if sep in text:
            return text.split(sep)[-1].strip()
    return text


def short_gloss(g: str) -> str:
    g = re.sub(r"\([^)]*\)", "", g).strip(" ;,")
    return g.split(";")[0].strip() or g


def load_hsk(path: Path) -> dict[str, int]:
    """HSK 2.0 levels (1-6). complete.json tags: 'old-1'..'old-6' (HSK 2.0), 'new-1'.. (HSK 3.0)."""
    data = json.loads(path.read_text(encoding="utf-8"))
    out = {}
    for item in data:
        simp = item.get("simplified") or item.get("s")
        levels = item.get("level") or item.get("l") or []
        olds = [int(l.split("-")[1]) for l in levels if str(l).startswith("old-")]
        if simp and olds:
            out[simp] = min(olds)
    return out


# ---------------------------------------------------------------- SQLite writer
SCHEMA = """
PRAGMA journal_mode=OFF;
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE credit(id INTEGER PRIMARY KEY, name TEXT NOT NULL, license TEXT NOT NULL, url TEXT NOT NULL);
CREATE TABLE category(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE);
CREATE TABLE word(
  id INTEGER PRIMARY KEY,
  word_key TEXT NOT NULL UNIQUE,
  lang TEXT NOT NULL CHECK(lang IN ('en','es','zh')),
  lemma TEXT NOT NULL,
  pos TEXT,
  freq_rank INTEGER NOT NULL,
  level INTEGER NOT NULL,
  ipa TEXT,
  pinyin TEXT,
  traditional TEXT
);
CREATE INDEX word_pick ON word(lang, level, freq_rank);
CREATE TABLE word_category(word_id INTEGER NOT NULL REFERENCES word(id),
                           category_id INTEGER NOT NULL REFERENCES category(id),
                           PRIMARY KEY(category_id, word_id)) WITHOUT ROWID;
CREATE TABLE sense(
  id INTEGER PRIMARY KEY,
  word_id INTEGER NOT NULL REFERENCES word(id),
  sense_order INTEGER NOT NULL,
  pos TEXT,
  def_lang TEXT NOT NULL,
  definition TEXT,
  example TEXT,
  example_translation TEXT,
  example_translation_lang TEXT,
  example_source TEXT
);
CREATE INDEX sense_word ON sense(word_id, def_lang, sense_order);
CREATE TABLE translation(
  id INTEGER PRIMARY KEY,
  word_id INTEGER NOT NULL REFERENCES word(id),
  target_lang TEXT NOT NULL,
  gloss_order INTEGER NOT NULL,
  gloss TEXT NOT NULL
);
CREATE INDEX translation_word ON translation(word_id, target_lang, gloss_order);
-- search: ~30k rows; a LIKE scan is a few ms. FTS5 trigram cannot match 1-2 character zh words.
CREATE TABLE word_search(word_id INTEGER PRIMARY KEY REFERENCES word(id), text TEXT NOT NULL);
"""


def write_db(path: Path, words: list[Word]):
    if path.exists():
        path.unlink()
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    db.executemany("INSERT INTO category(id,key) VALUES(?,?)", list(enumerate(CATEGORIES, 1)))
    cat_id = {c: i for i, c in enumerate(CATEGORIES, 1)}
    db.executemany("INSERT INTO credit(name,license,url) VALUES(?,?,?)", CREDITS)
    for wid, w in enumerate(words, start=1):
        db.execute("INSERT INTO word VALUES(?,?,?,?,?,?,?,?,?,?)",
                   (wid, w.key, w.lang, w.lemma, w.pos, w.freq_rank, w.level, w.ipa, w.pinyin,
                    w.traditional))
        db.executemany("INSERT INTO word_category VALUES(?,?)",
                       [(wid, cat_id[c]) for c in sorted(w.categories) if c in cat_id])
        db.executemany(
            "INSERT INTO sense(word_id,sense_order,pos,def_lang,definition,example,example_translation,"
            "example_translation_lang,example_source) VALUES(?,?,?,?,?,?,?,?,?)",
            [(wid, i, s.pos, s.def_lang, s.definition, s.example, s.example_translation,
              s.example_translation_lang, s.example_source) for i, s in enumerate(w.senses)])
        for lang, gl in w.translations.items():
            db.executemany("INSERT INTO translation(word_id,target_lang,gloss_order,gloss) VALUES(?,?,?,?)",
                           [(wid, lang, i, g) for i, g in enumerate(gl) if g])
        glosses = " ".join(g for gl in w.translations.values() for g in gl)
        parts = [w.lemma.lower(), strip_tones(w.pinyin) if w.pinyin else "", w.traditional or "",
                 glosses.lower()]
        db.execute("INSERT INTO word_search VALUES(?,?)", (wid, " | ".join(p for p in parts if p)))
    db.executemany("INSERT INTO meta VALUES(?,?)", [
        ("schema_version", "1"), ("builder_version", "1.0.1"), ("built_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
        ("top_n", str(TOP_N)), ("sources", json.dumps(SOURCES)),
    ])
    db.commit()
    db.execute("ANALYZE")
    db.commit()
    db.execute("VACUUM")
    db.close()


# ---------------------------------------------------------------- coverage report
def coverage(db_path: Path) -> tuple[str, list[str]]:
    db = sqlite3.connect(db_path)
    q = lambda sql, *a: db.execute(sql, a).fetchone()[0]
    rows, flags = [], []

    def pct(num, den):
        return 100.0 * num / den if den else 0.0

    def add(lang, metric, num, den):
        p = pct(num, den)
        flag = "⚠ < 80%" if p < 80 else ""
        if flag:
            flags.append(f"{lang}: {metric} = {p:.1f}%")
        rows.append(f"| {lang} | {metric} | {num:,} / {den:,} | {p:.1f}% | {flag} |")

    for lang in ("en", "es"):
        n = q("SELECT COUNT(*) FROM word WHERE lang=?", lang)
        rows.append(f"| {lang} | word count | {n:,} | | {'⚠ < 10,000' if n < TOP_N else ''} |")
        add(lang, f"monolingual definition ({lang})", q(
            "SELECT COUNT(DISTINCT w.id) FROM word w JOIN sense s ON s.word_id=w.id "
            "WHERE w.lang=? AND s.def_lang=? AND s.definition IS NOT NULL", lang, lang), n)
        add(lang, "example sentence", q(
            "SELECT COUNT(DISTINCT w.id) FROM word w JOIN sense s ON s.word_id=w.id "
            "WHERE w.lang=? AND s.example IS NOT NULL", lang), n)
        add(lang, "≥1 category", q(
            "SELECT COUNT(DISTINCT w.id) FROM word w JOIN word_category c ON c.word_id=w.id WHERE w.lang=?",
            lang), n)
        add(lang, "IPA", q("SELECT COUNT(*) FROM word WHERE lang=? AND ipa IS NOT NULL", lang), n)
    n = q("SELECT COUNT(*) FROM word WHERE lang='zh'")
    rows.append(f"| zh | word count | {n:,} | | {'⚠ < 10,000' if n < TOP_N else ''} |")
    add("zh", "pinyin", q("SELECT COUNT(*) FROM word WHERE lang='zh' AND pinyin IS NOT NULL"), n)
    for t in ("en", "es"):
        add("zh", f"translation zh→{t}", q(
            "SELECT COUNT(DISTINCT word_id) FROM translation t JOIN word w ON w.id=t.word_id "
            "WHERE w.lang='zh' AND t.target_lang=?", t), n)
        add("zh", f"zh example + {t} translation", q(
            "SELECT COUNT(DISTINCT w.id) FROM word w JOIN sense s ON s.word_id=w.id WHERE w.lang='zh' "
            "AND s.example IS NOT NULL AND s.example_translation_lang=?", t), n)
    add("zh", "zh example (any)", q(
        "SELECT COUNT(DISTINCT w.id) FROM word w JOIN sense s ON s.word_id=w.id "
        "WHERE w.lang='zh' AND s.example IS NOT NULL"), n)
    add("zh", "part of speech", q("SELECT COUNT(*) FROM word WHERE lang='zh' AND pos IS NOT NULL"), n)
    add("zh", "HSK 1–6 level", q("SELECT COUNT(*) FROM word WHERE lang='zh' AND level<=6"), n)
    size = db_path.stat().st_size / 1e6
    db.close()
    md = ["# Lexi lexicon coverage report", "",
          f"Built {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime())}. Database size: {size:.1f} MB.", "",
          "| Lang | Metric | Count | % | Flag |", "|---|---|---|---|---|", *rows, ""]
    md += ["## Flags (< 80%)", ""] + ([f"- {f}" for f in flags] or ["- none"])
    return "\n".join(md) + "\n", flags


# ---------------------------------------------------------------- probe
def probe():
    """Check every source and print the first record's keys (streams only the first ~4 MB)."""
    ok = True
    for name, urls in SOURCES.items():
        for url in urls:
            try:
                req = urllib.request.Request(url, headers=UA)
                with urllib.request.urlopen(req, timeout=60) as r:
                    size = r.headers.get("Content-Length")
                    head = r.read(4 << 20)
                text = head
                if url.endswith(".gz"):
                    text = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(head)
                elif url.endswith(".bz2"):
                    text = bz2.BZ2Decompressor().decompress(head)
                elif url.endswith(".tar.gz"):
                    text = b""
                first = text.decode("utf-8", "replace").splitlines()[:1]
                sz = f"{int(size) / 1e6:.0f} MB" if size else "size ?"
                print(f"OK   {name:18s} {sz:>9s}  {url}")
                if url.endswith((".jsonl", ".jsonl.gz", ".json.gz")) and first:
                    rec = json.loads(first[0])
                    print(f"     keys: {sorted(rec)}")
                    if rec.get("senses"):
                        print(f"     sense keys: {sorted(rec['senses'][0])}")
                elif first:
                    print(f"     first line: {first[0][:120]}")
                break
            except Exception as e:
                print(f"FAIL {name:18s} {url}: {e}")
        else:
            ok = False
    return ok


def inspect(words: list[str], out_path: str):
    """Dump raw source records for given words (debug aid)."""
    want = set(words)
    with open(out_path, "w", encoding="utf-8") as out:
        for src, lang in (("wikt_en_English", "en"), ("wikt_es_raw", "es"), ("wikt_en_Chinese", "zh")):
            n = collections.Counter()
            for e in iter_jsonl(fetch(src)):
                w = e.get("word")
                if w in want and n[w] < 3 and (lang != "es" or e.get("lang_code") == "es"):
                    n[w] += 1
                    e.pop("translations", None); e.pop("etymology_templates", None); e.pop("descendants", None)
                    e.pop("derived", None); e.pop("related", None); e.pop("forms", None)
                    for s_ in e.get("senses", [])[:4]:
                        s_.pop("links", None); s_.pop("translations", None)
                    e["senses"] = e.get("senses", [])[:4]
                    out.write(f"### {src} {w}\n" + json.dumps(e, ensure_ascii=False, indent=1)[:6000] + "\n")
    log(f"inspect -> {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--inspect", nargs="*")
    ap.add_argument("--out", default=str(HERE.parent / "Resources" / "lexi.sqlite"))
    ap.add_argument("--report", default=str(HERE / "coverage_report.md"))
    a = ap.parse_args()
    if a.probe:
        sys.exit(0 if probe() else 1)
    if a.inspect:
        inspect(a.inspect, str(HERE / "inspect.txt"))
        return
    t0 = time.time()
    log("WordNet 3.1")
    wordnet = parse_wordnet(fetch("wordnet31"))
    tables: list = []
    en = build_english(wordnet, tables)
    es, zh_es = build_spanish(en, tables)
    zh = build_chinese(en, tables, zh_es)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    write_db(out, en + es + zh)
    md, flags = coverage(out)
    Path(a.report).write_text(md, encoding="utf-8")
    print(md)
    log(f"done in {(time.time() - t0) / 60:.1f} min -> {out}")


if __name__ == "__main__":
    main()
