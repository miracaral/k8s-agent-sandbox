"""tiny-notes: keep short notes in a JSON file."""
import json
import sys
from pathlib import Path

STORE = Path("notes.json")


def load():
    return json.loads(STORE.read_text()) if STORE.exists() else []


def main(argv):
    notes = load()
    if argv[:1] == ["add"] and len(argv) > 1:
        notes.append(" ".join(argv[1:]))
        STORE.write_text(json.dumps(notes, indent=2))
    for i, note in enumerate(notes, 1):
        print(f"{i}. {note}")


if __name__ == "__main__":
    main(sys.argv[1:])
