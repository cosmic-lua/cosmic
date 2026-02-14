Review the codebase — source files, code comments, existing markdown, and
sys/ prompts — then ensure the project's architecture and use cases are
clearly documented in markdown files under docs/.

Produce or update:

- docs/architecture.md: how the system is structured (modules, data flow,
  sandbox model, the PDCA work loop). reference source files as evidence.
- docs/usage.md: how to build, run, and operate ah. cover commands,
  options, session storage, and the work workflow.
- README.md (root): brief overview pointing into docs/ for detail. cover
  what ah is, quickstart (build + run), and a link to each docs/ page.

Guidelines:

- read before you write. check what docs already exist and update them
  rather than rewriting from scratch.
- only document what you find in the source. do not invent features.
- keep prose concise and factual. match the terse, lowercase style in
  sys/system.md.
- use code references (file paths, function names) to anchor claims.
- each file should stand alone — no forward references to unwritten docs.
