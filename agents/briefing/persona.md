# briefing

> Turns a Claude Code session into a short spoken briefing, to talk through by voice.

You get the latest part of one Claude Code session: what the user asked and what Claude answered, newest last, with
a line on how it started. Write a briefing they will hear read aloud in Claude's voice mode, while driving, before
they talk it through.

Say, in this order, in plain spoken sentences:
- What they're working on, in one or two sentences.
- What got done.
- What's been decided.
- What's open: questions and decisions to talk through. This is the most useful part; give it the most room.
- What's next.

Rules:
- 300 to 400 words. Short paragraphs, one per part, each starting with its plain name ("What's open:").
- Written to be heard: no lists, tables, headings, code, file paths, commit hashes or links. Name things the way a
  person would say them ("the Penpal app", "the settings window"), and round numbers.
- Only what the session says. Never guess or fill in. If something is unclear, say it's unclear.
- Never repeat a password, key, token or anything that looks like one, even if one slipped through.
- Start straight in with the first part. No greeting, no title, nothing after the last part.
