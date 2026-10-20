--- Uses of a record's own fields, found through the type the new checker gave the value they are read from:
--- `w:add_file(...)` or `w.add_file` where `w` is a [`Zip.Writer`] is a use of `Writer.add_file` in [`cosmic.zip`],
--- whatever `w` is called and however it was made. The port of [`build.receivers`]'s `references`, which asked the fork's
--- reporter for the types; this reads the type report of the driver ([`build.driver`]) by the id of the node.
---
--- A receiver resolves to a symbol only when its record is one some module's own record declares, nested under it
--- ([`Zip.Writer`], [`Stream.Reader`]) -- [`build.syntax_report`]'s `owner_of`. A record a file keeps to itself has no row
--- in `docs` to be a use of, and the module's own record is the syntactic half's to answer
--- ([`build.syntax_analyzer`]'s references).
---
--- A field the record inherits is a use of the interface that declares it, when some module declares that interface
--- ([`Writer.write`], not `Collector.write`).
local Ast = require("lang.ast")
local Node = require("build.syntax_node")
local Report = require("build.syntax_report")

local record Receivers
  --- One use of a record's field: `member` is the field's canonical path within `module` (`"Writer.add_file"`), the same
  --- shape [`build.receivers`] and [`build.analyzer.Reference`] give a module member.
  record Reference
    module: string
    member: string
    line: integer
  end

  --- Every `x.f` read and `x:f(...)` call in the subject whose `x` the checker typed as a record some module declares,
  --- as that record's field; an assignment's own target is a definition, not a use. Ordered by line, module and member,
  --- once each.
  references: function(subject: Report.Subject): {Reference}

  --- The lines on which a field is read or a method called through a value the checker typed `invalid` (a type that failed to
  --- lower, a value reached through an error already reported, a binding of C), in order, once each: a use there is not
  --- seen, whatever record the value is.
  blind: function(subject: Report.Subject): {integer}

  --- Of the places `wanted` (`<line> <name>`), those where a field or method of that name is read through a value the checker
  --- gave a known type (not `invalid`), whether or not it is a record some module declares: the places the type report speaks
  --- for, in order.
  known: function(subject: Report.Subject, wanted: {string: boolean}): {string}
end

-- TODO: attribute a call through a value of a class, or of the record a module returns, to the method it calls
-- (`counter:add(word)` is a use of `Counter.add`), once [`Report.owner_of`] ([`build.syntax_report`]) names the owner of a
-- declaration that is not nested under its module's record and [`build.tree_checks`]' `typed` comparison with
-- [`build.receivers`] is dropped with the fork (doc/plans/strict-teal.md, "the switch"): the fork does not attribute them
-- either, and a class is always top-level in the new grammar, so no call through a class value is found until then.
function Receivers.references(subject: Report.Subject): {Receivers.Reference}
  local out: {Receivers.Reference} = {}
  local seen: {string: boolean} = {}
  local targets: {integer: boolean} = {}
  local program = subject.program
  --- The use of the field `name` of `object`, written on `line`.
  local function use(object: Ast.Exp, name: string, line: integer)
    local decl = Report.decl_of(subject.types[Node.base(object).id])
    if decl == nil then
      return
    end
    -- An enum or an alias to one is a string, and `kind:sub()` is a method of strings: only a record, class, interface or
    -- userdata record has fields, and only one that declares (or lists, or as a value holds) the name is read.
    local kind = decl.kind
    if kind == "enum" then
      return
    end
    local statics = program.statics[decl]
    if not Report.has_member(decl, name) and Report.declaring(decl, name) == nil and
        not (statics ~= nil and statics[name] ~= nil) then
      return
    end
    local owner = Report.owner_of(program, decl)
    if owner == nil then
      return
    end
    local from = Report.declaring(decl, name)
    if from ~= nil then
      local inherited = Report.owner_of(program, from)
      if inherited ~= nil then
        owner = inherited
      end
    end
    local member = owner.path .. "." .. name
    local id = owner.module .. "\n" .. member .. "\n" .. tostring(line)
    if seen[id] ~= true then
      seen[id] = true
      out[#out + 1] = { module = owner.module, member = member, line = line }
    end
  end
  Node.walk(subject.chunk, function(node: Ast.Node)
    if node is Ast.Assign then
      for _, target in ipairs(node.targets) do
        targets[Node.base(target).id] = true
      end
    elseif targets[Node.base(node).id] then
      return
    elseif node is Ast.Field then
      -- The name is the last token of `x.f`.
      use(node.object, node.name, Report.line(subject, Node.base(node).last))
    elseif node is Ast.MethodCall then
      -- The name follows the colon, which follows the object.
      use(node.object, node.name, Report.line(subject, Node.base(node.object).last + 2))
    end
  end)
  table.sort(out, function(p: Receivers.Reference, q: Receivers.Reference): boolean
    if p.line ~= q.line then
      return p.line < q.line
    end
    if p.module ~= q.module then
      return p.module < q.module
    end
    return p.member < q.member
  end)
  return out
end

function Receivers.blind(subject: Report.Subject): {integer}
  local lines: {integer: boolean} = {}
  Node.walk(subject.chunk, function(node: Ast.Node)
    if node is Ast.Field then
      local t = subject.types[Node.base(node.object).id]
      if t ~= nil and t.tag == "invalid" then
        lines[Report.line(subject, Node.base(node).last)] = true
      end
    elseif node is Ast.MethodCall then
      local t = subject.types[Node.base(node.object).id]
      if t ~= nil and t.tag == "invalid" then
        lines[Report.line(subject, Node.base(node.object).last + 2)] = true
      end
    end
  end)
  local out: {integer} = {}
  for line in pairs(lines) do
    out[#out + 1] = line
  end
  table.sort(out)
  return out
end

function Receivers.known(subject: Report.Subject, wanted: {string: boolean}): {string}
  local found: {string: boolean} = {}
  local function note(object: Ast.Exp, name: string, line: integer)
    local at = tostring(line) .. " " .. name
    local t = subject.types[Node.base(object).id]
    if wanted[at] == true and t ~= nil and t.tag ~= "invalid" then
      found[at] = true
    end
  end
  Node.walk(subject.chunk, function(node: Ast.Node)
    if node is Ast.Field then
      note(node.object, node.name, Report.line(subject, Node.base(node).last))
    elseif node is Ast.MethodCall then
      note(node.object, node.name, Report.line(subject, Node.base(node.object).last + 2))
    end
  end)
  local out: {string} = {}
  for at in pairs(found) do
    out[#out + 1] = at
  end
  table.sort(out)
  return out
end

return Receivers
