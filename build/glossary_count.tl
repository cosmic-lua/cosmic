--- The words of doc/writing.md's glossary that a comment no longer uses, counted per file so that the count only falls
--- ([`build.ceilings_base`] holds it to the merge base, as it holds the markers). A comment says "returns" for what a
--- function gives back and "responds" for a server's reply, since the old word ([`glossary_count.word`]) reads as either.
--- A line counts once however many times it has the word, and a line counts when it holds `--` anywhere before the word,
--- in a string too. Some lines keep it on purpose (a DNS record of that name, a
--- peer's reply), so the rule is a ceiling, not a refusal: a file may hold as many as it did, and a new one is refused.

local record glossary_count
  --- The code a file's count is held under, beside the markers' `<stage> <code>` keys.
  code: string
  --- The word a line holds, in any case, after its `--`, to count.
  word: string
end

glossary_count.code = "prose answers"

glossary_count.word = "answer"
local needle <const> = glossary_count.word

--- Whether `text` holds a line that counts, found without splitting it: most files hold none.
function glossary_count.mentions(text: string): boolean
  return text:lower():find(needle, 1, true) ~= nil
end

--- The count of `text`'s comment lines that use the word, as `{ [code] = n }`, or an empty table where none does.
function glossary_count.counts(text: string): {string: integer}
  local out: mut {string: integer} = {}
  if not glossary_count.mentions(text) then return out end
  local n = 0
  for line in text:gmatch("[^\n]+") do
    local at = line:find("--", 1, true)
    if at ~= nil and line:sub(at):lower():find(needle, 1, true) ~= nil then
      n = n + 1
    end
  end
  if n > 0 then out[glossary_count.code] = n end
  return out
end

return glossary_count
