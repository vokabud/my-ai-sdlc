#!/usr/bin/env python3
"""Validate one result document against the code-agent JSON Schema."""

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} SCHEMA DOCUMENT", file=sys.stderr)
        return 2

    schema_path, document_path = map(Path, sys.argv[1:])
    with schema_path.open(encoding="utf-8") as schema_file:
        schema = json.load(schema_file)
    with document_path.open(encoding="utf-8") as document_file:
        document = json.load(document_file)

    Draft202012Validator.check_schema(schema)
    errors = sorted(
        Draft202012Validator(schema).iter_errors(document),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    for error in errors:
        location = ".".join(str(part) for part in error.absolute_path) or "<root>"
        print(f"{location}: {error.message}", file=sys.stderr)

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
