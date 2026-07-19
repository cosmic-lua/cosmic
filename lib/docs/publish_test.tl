#!/usr/bin/env cosmic
-- test docs-publish readme generation and the public-surface filter

local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR")

local record PublishModule
  make_readme: function(docs_dir: string): string
  prune_internal: function(docs_dir: string)
end

local function write_doc(docs_dir: string, rel: string, title: string, desc: string)
  local path = fs.join(docs_dir, rel)
  fs.makedirs(fs.dirname(path))
  fs.write(path, "# " .. title .. "\n\n" .. desc .. "\n\n## Types\n")
end

-- Build a mock generated-docs tree with public and internal pages.
local function make_mock_docs(name: string): string
  local docs_dir = fs.join(tmpdir, name)
  write_doc(docs_dir, "lib/cosmic/embed.md", "embed", "Embed files into cosmic executable.")
  write_doc(docs_dir, "lib/cosmic/child.md", "child", "Process spawning utilities.")
  write_doc(docs_dir, "lib/cosmic/fs/init.md", "fs", "Unified filesystem module.")
  write_doc(docs_dir, "cosmo/unix.md", "unix", "System call bindings.")
  -- internal: directory-module shards, CLI helper, repo tooling
  write_doc(docs_dir, "lib/cosmic/child/io.md", "io", "Low-level child-process I/O.")
  write_doc(docs_dir, "lib/cosmic/cli/args.md", "args", "CLI option definitions.")
  write_doc(docs_dir, "lib/cosmic/fs/walk.md", "walk", "Directory walking utilities.")
  write_doc(docs_dir, "lib/perf/harness.md", "harness", "Benchmark harness.")
  return docs_dir
end

-- Test that make_readme generates a table of doc links
local function test_readme_has_doc_table()
  local publish = require("lib.docs.publish")
  local docs_dir = make_mock_docs("docs-readme")

  local readme = publish.make_readme(docs_dir)

  -- README should have a package section (lib/cosmic -> cosmic)
  assert(readme:find("## cosmic Package"), "should have cosmic Package section")

  -- README should link to each doc file
  assert(readme:find("%[embed%]"), "should link to embed.md")
  assert(readme:find("%[child%]"), "should link to child.md")

  -- README should include descriptions from the doc files
  assert(readme:find("Embed files"), "should include embed description")
  assert(readme:find("Process spawning"), "should include child description")
end
test_readme_has_doc_table()

-- The published site carries the public surface only (issue #556):
-- prune_internal removes internal module pages, keeps public module
-- pages (including directory-module init pages) and cosmo.* docs.
local function test_prune_internal_keeps_public_surface_only()
  local publish = require("lib.docs.publish") as PublishModule
  local docs_dir = make_mock_docs("docs-prune")

  publish.prune_internal(docs_dir)

  local kept = {
    "lib/cosmic/embed.md",
    "lib/cosmic/child.md",
    "lib/cosmic/fs/init.md",
    "cosmo/unix.md",
  }
  for _, rel in ipairs(kept) do
    assert(fs.isfile(fs.join(docs_dir, rel)), "must keep public page: " .. rel)
  end

  local pruned = {
    "lib/cosmic/child/io.md",
    "lib/cosmic/cli/args.md",
    "lib/cosmic/fs/walk.md",
    "lib/perf/harness.md",
  }
  for _, rel in ipairs(pruned) do
    assert(not fs.isfile(fs.join(docs_dir, rel)), "must prune internal page: " .. rel)
  end

  local readme = publish.make_readme(docs_dir)
  assert(not readme:find("child/io"), "README must not index internal pages")
end
test_prune_internal_keeps_public_surface_only()

print("All publish tests passed!")
