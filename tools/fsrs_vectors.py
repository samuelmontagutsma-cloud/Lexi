#!/usr/bin/env python3
"""Generate FSRS reference vectors with the official py-fsrs package (MIT).

The Swift port in Packages/LexiCore must reproduce these outputs.
Usage: pip install "fsrs>=6,<7"; python fsrs_vectors.py <out.json>
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone
from importlib.metadata import version

from fsrs import Card, Rating, Scheduler, State

CONFIGS = {
    "default_r090": dict(desired_retention=0.90),
    "r080": dict(desired_retention=0.80),
    "r095": dict(desired_retention=0.95),
    "no_learning_steps": dict(learning_steps=(), relearning_steps=()),
    "one_step": dict(learning_steps=(timedelta(minutes=5),), relearning_steps=(timedelta(minutes=10),)),
}
START = datetime(2026, 1, 1, 9, 0, tzinfo=timezone.utc)


def offset(rng: random.Random, card: Card) -> timedelta:
    """Review time relative to due: on time, late, early, or same day."""
    k = rng.random()
    if k < 0.45:
        return timedelta(0)
    if k < 0.75:
        return timedelta(hours=rng.randint(1, 24 * 20))
    if k < 0.9:
        return timedelta(minutes=rng.randint(1, 600))
    return -timedelta(minutes=rng.randint(1, 600))  # early review


def main(out_path: str):
    rng = random.Random(20261004)
    cases = []
    for name, kw in CONFIGS.items():
        sched = Scheduler(enable_fuzzing=False, **kw)
        for c in range(40):
            card = Card(card_id=c + 1, state=State.Learning, step=0, due=START)
            now = START
            steps = []
            for _ in range(rng.randint(4, 14)):
                now = max(now, card.due + offset(rng, card))
                rating = rng.choices([1, 2, 3, 4], weights=[2, 2, 5, 1])[0]
                r_before = sched.get_card_retrievability(card, now) if card.last_review else 0.0
                card, _ = sched.review_card(card, Rating(rating), review_datetime=now)
                steps.append({
                    "rating": rating,
                    "at": now.timestamp(),
                    "r_before": r_before,
                    "state": int(card.state),
                    "step": card.step,
                    "stability": card.stability,
                    "difficulty": card.difficulty,
                    "due": card.due.timestamp(),
                })
            cases.append({"config": name, "steps": steps})
    params = {k: {"desired_retention": v.get("desired_retention", 0.9),
                  "learning_steps": [s.total_seconds() for s in v.get("learning_steps", (timedelta(minutes=1), timedelta(minutes=10)))],
                  "relearning_steps": [s.total_seconds() for s in v.get("relearning_steps", (timedelta(minutes=10),))]}
              for k, v in CONFIGS.items()}
    doc = {"fsrs_version": version("fsrs"), "weights": list(Scheduler().parameters),
           "configs": params, "cases": cases}
    with open(out_path, "w") as f:
        json.dump(doc, f, indent=1)
    n = sum(len(c["steps"]) for c in cases)
    print(f"py-fsrs {doc['fsrs_version']}: {len(cases)} cards, {n} reviews -> {out_path}")


if __name__ == "__main__":
    main(sys.argv[1])
