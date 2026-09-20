#!/usr/bin/env python3
"""Fail if a skill's YAML frontmatter does not load.

An unquoted description containing ": " parses as a mapping and the loader
rejects the whole file. That error surfaces when someone installs the skill,
not when we write it, so it is checked here.
"""

import pathlib
import sys

import yaml


def main() -> int:
    problems = []
    skills = sorted(pathlib.Path("skills").rglob("SKILL.md"))
    if not skills:
        print("no SKILL.md found under skills/")
        return 1
    for path in skills:
        text = path.read_text(encoding="utf-8")
        if not text.startswith("---"):
            problems.append(f"{path}: no frontmatter")
            continue
        block = text.split("---", 2)[1]
        try:
            data = yaml.safe_load(block)
        except yaml.YAMLError as err:
            problems.append(f"{path}: {err}")
            continue
        if not isinstance(data, dict):
            problems.append(f"{path}: frontmatter is not a mapping")
            continue
        for key in ("name", "description"):
            value = data.get(key)
            if not isinstance(value, str) or not value.strip():
                problems.append(f"{path}: missing or empty {key}")
    for problem in problems:
        print(problem)
    print(f"checked {len(skills)} skill(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
