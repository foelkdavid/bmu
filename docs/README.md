# gruvkit documentation

| Read | When |
|---|---|
| [GETTING_STARTED.md](GETTING_STARTED.md) | first: build the examples, make an app, how an app is structured |
| [QUICK_REFERENCE.md](QUICK_REFERENCE.md) | the whole API and the rules on one page (give it to your AI assistant) |
| [COOKBOOK.md](COOKBOOK.md) | working recipes: forms, lists, dialogs, tabs, file picker, settings file, autosave, shortcuts, drag & drop, images, custom widgets, child processes |
| [API.md](API.md) | every function in detail, limits |
| [CONCEPTS.md](CONCEPTS.md) | immediate mode, logical pixels, layers/modals, ids/focus, buffers |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | symptom → fix |

Examples (from the gruvkit folder): `c3c build example-hello && ./build/example-hello`, `example-gallery` (every widget).
A real app: botexe (`../botexe`). A new app: `tools/new-app.sh ../my-app "My App"`.

All code in these docs is compiled by `dev/tools/check-docs.sh` (blocks starting with `// sketch` are fragments).
