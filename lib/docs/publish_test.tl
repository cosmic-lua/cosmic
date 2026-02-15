#!/usr/bin/env cosmic
-- test docs-publish readme generation

local cio = require("cosmic.io")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR")

local record PublishModule
  make_readme: function(docs_dir: string): string
end

-- Test that make_readme generates a table of doc links
local function test_readme_has_doc_table()
  local publish = require("lib.docs.publish") as PublishModule

  -- Create some mock doc files
  local docs_dir = fs.join(tmpdir, "docs")
  fs.makedirs(docs_dir .. "/lib/cosmic")

  -- Write mock doc files with module descriptions
  cio.barf(fs.join(docs_dir, "lib/cosmic/embed.md"), [[# embed

Embed files into cosmic executable.

## Types
]]
  )
  cio.barf(fs.join(docs_dir, "lib/cosmic/spawn.md"), [[# spawn

Process spawning utilities.

## Types
]]
  )

  local readme = publish.make_readme(docs_dir)

  -- README should have a package section (lib/cosmic -> cosmic)
  assert(readme:find("## cosmic Package"), "should have cosmic Package section")

  -- README should link to each doc file
  assert(readme:find("%[embed%]"), "should link to embed.md")
  assert(readme:find("%[spawn%]"), "should link to spawn.md")

  -- README should include descriptions from the doc files
  assert(readme:find("Embed files"), "should include embed description")
  assert(readme:find("Process spawning"), "should include spawn description")
end
test_readme_has_doc_table()

print("All publish tests passed!")
