--- A fixture data module: not a `cosmic.template` module in its own
--- right, just a small typed record for `codegen_test.tl` and
--- `init_test.tl` to compile templates against and feed to
--- `cosmic --check types`. `testdata/` is never embedded in the
--- cosmic binary, so this fixture ships in the tree and nowhere else.
local record Item
  label: string
end

local record Page
  title: string
  body: string
  show_body: boolean
  items: {Item}
end

local record FixturePageModule
  type Item = Item
  type Page = Page
end

local M: FixturePageModule = {}
return M
