# Project conventions for Claude

## Language

**All written output must be in English.** That includes:

- Source code (variable names, function names, file names)
- Code comments (block comments, line comments, docstrings)
- Git commit messages
- Pull-request titles, descriptions, review comments
- Issue text on GitHub
- Any other artifact that ends up on GitHub or in the repo

Chat replies inside the editor may use whatever language the user is
writing in (German is fine), but the moment something gets committed
or posted to GitHub, switch to English.

The user is a native German speaker but explicitly wants the project
to stay in English so future contributors / public review aren't
blocked by language. Don't ask for translation help — just translate
inline when authoring commit messages, PR bodies, etc.

## Other reminders

- Keep files small; split into new `*.ahk` modules via `#Include`
  when a single file grows substantially.
- New functions get a short 2-3 line comment explaining purpose,
  parameters, and return value.
- Variable names follow existing camelCase / snake_case style of
  surrounding code.
- Check `https://gitlab.com/bylafko/gamehelper2` (the original C#
  reference project) when starting on a new feature — solutions or
  approaches may already exist there.
