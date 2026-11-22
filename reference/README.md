# reference/

| File | What | From |
|---|---|---|
| `findings.md` | what is known about the tool's internals, with status words (proven / seen / untested) | this skill |
| `new-program.md` | from a functional description to a built project: steps and traps | this skill |
| `design-rules.md` | what to build: block choice, constants, set values, measurements | this skill |
| `blocks.json` | block catalogue for the Python pipeline (types, versions, pins) | made by `setup` on your machine |
| `primitive-pins.txt` | every block with all pins, one line per pin | made by `setup` on your machine |
| `primitive-docs.txt` | the documentation text stored in the block files | made by `setup` on your machine |

The last three are read from the block library of your own BA Tool installation
(`scripts/win/catalogue.ps1`). They are Ouman's data: they are not in this repository, `.gitignore` keeps them
out, and they must not be published. Without `blocks.json` the plan library, the checker and the generator stop
with "block catalogue missing: run setup".
