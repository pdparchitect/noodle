---
name: no-code-docs
description: Code is documented only in the source. Use whenever writing or editing a README.md, anything under docs/, or any other Markdown documentation, and whenever a change tempts you to explain how something works outside the code.
---

# No code docs

Documentation outside the source code is for people using the apps, not for
people reading the code. Code is documented in its own comments and nowhere else.

A README says what the app is, what it does for the person using it, and how to
get and use it, in plain language. It must not contain:

- type, function, property, file or module names, or source paths;
- formats, codecs, protocols, sandbox rules, entitlements, internal limits or
  anything else about how the code does its job;
- architecture, design reasoning or implementation notes.

When a change alters what someone does or sees, update the README in those
terms. When it only changes how the code works, do not touch the README; write
the explanation as a comment beside the code.

Guidance the apps print or hand to agents lives in source files, such as the
Applet guidance or the messenger documentation. That is source, not
documentation, and follows its own rules.

Before saving a README or doc, read every sentence as someone who has never
seen the code. Delete any sentence they would not need or understand.
