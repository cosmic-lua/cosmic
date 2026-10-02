--- Where [`build.dispatch`] leaves what makes the texts `cosmic help`
--- prints, for the `fix` verb's checks of what those texts refer to
--- ([`build.docs_checks`]' `references`). Dispatch sets it as it loads:
--- it reaches `fix` through [`build.verb_list`], so `fix` requiring
--- dispatch would close a cycle of imports. A module of its own, requiring
--- nothing, so dispatch's own load -- which every `cosmic -e` and
--- `--standalone` run pays -- loads none of the checks to set it.

local help_source = {}

--- What makes the texts `cosmic help` prints, set by [`provide`].
local source: function(): {string: string} | nil = nil

--- Names what makes the texts `cosmic help` prints, for [`texts`].
function help_source.provide(made_by: function(): {string: string})
  source = made_by
end

--- What `cosmic help` prints, by what asks for it: `""` the index,
--- `exit`, and each verb's own; the input `references` reads help from.
--- Nil and why until [`build.dispatch`] has loaded and called
--- [`provide`].
function help_source.texts(): {string: string} | nil, string
  if source == nil then
    return nil, "build.dispatch has not provided the texts of `cosmic help`"
  end
  return source(), ""
end

return help_source
