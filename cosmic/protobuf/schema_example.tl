--- Worked examples for [`cosmic.protobuf.schema`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
local Protobuf = require("cosmic.protobuf")
local Schema = require("cosmic.protobuf.schema")

local record Example end

--- A message is a record, and the call gives each field its number. The `.proto` file this one follows would say
--- `string name = 1; int32 id = 2; repeated string emails = 3; Address home = 5; repeated double scores = 6;`. The
--- record's literal is what `encode` takes, and the record is what `decode` answers.
function Example.message_of()
  local record Address
    street?: string
    city: string
  end
  local record Person
    name: string
    id?: integer
    emails: {string}
    home?: Address
    scores: {number}
  end
  local ADDRESS <const> = Schema.message_of("Address", { street = Schema.string(1), city = Schema.string(2) })
  local PERSON <const> = Schema.message_of("Person", {
    name = Schema.string(1), id = 2, emails = Schema.string(3), home = Schema.message(5, ADDRESS),
    scores = Schema.field(6, { packed = true }),
  })
  local bytes = assert(PERSON:encode({
    name = "Ada", id = 150, emails = { "ada@example.com" }, home = { city = "London" }, scores = { 0.5, 1.5 },
  }))
  print(Codec.hex(bytes:sub(1, 8)))
  assert(Codec.hex(bytes:sub(1, 8)) == "0a03416461109601")
  local person = assert(PERSON:decode(bytes))
  print(person.name, person.id, person.emails[1], assert(person.home).city, #person.scores)
  assert(person.name == "Ada" and person.id == 150 and person.scores[2] == 1.5)
end

--- An enum's codec names the number of each value. A message carries the number, and a record the name.
function Example.enum_of()
  local enum Role
    "Reader"
    "Editor"
  end
  local record Member
    role?: Role
  end
  local ROLE <const> = Schema.enum_of("Role", { Reader = 0, Editor = 1 })
  local MEMBER <const> = Schema.message_of("Member", { role = Schema.enum(1, ROLE) })
  print(ROLE.number("Editor"), ROLE.name(0), ROLE.name(9))
  assert(ROLE.number("Editor") == 1 and ROLE.name(0) == "Reader" and ROLE.name(9) == nil)
  local bytes = assert(MEMBER:encode({ role = "Editor" }))
  print(Codec.hex(bytes), assert(MEMBER:decode(bytes)).role)
  assert(Codec.hex(bytes) == "0801")
end

--- `decode` answers nil and the first thing that did not fit, by its path from the root. A field declared
--- `city: string` must be there.
function Example.decode()
  local record Address
    street?: string
    city: string
  end
  local record Person
    name: string
    home?: Address
  end
  local ADDRESS <const> = Schema.message_of("Address", { street = Schema.string(1), city = Schema.string(2) })
  local PERSON <const> = Schema.message_of("Person", { name = Schema.string(1), home = Schema.message(5, ADDRESS) })
  local nowhere = assert(Protobuf.writer():string(1, "10 Downing St"):encode())
  local bytes = assert(Protobuf.writer():string(1, "Ada"):bytes(5, nowhere):encode())
  local person, why = PERSON:decode(bytes)
  print(person, why)
  assert(person == nil and why == "protobuf: Person.home.city (field 2): missing")
end

--- A record with a field of [`Unknown`] keeps what it does not understand: a program that reads a message, changes
--- a field and writes it loses nothing of the rest. Here field 9 is one the record does not name, and 7 is no
--- `Role`; both are written back, and the record is changed with a spread.
function Example.Unknown()
  local enum Role
    "Reader"
    "Editor"
  end
  local record Envelope
    id?: string
    role?: Role
    rest?: Schema.Unknown
  end
  local ROLE <const> = Schema.enum_of("Role", { Reader = 0, Editor = 1 })
  local ENVELOPE <const> = Schema.message_of("Envelope", { id = Schema.string(1), role = Schema.enum(2, ROLE) })
  local received = assert(Protobuf.writer():string(1, "a1"):int(2, 7):string(9, "from a newer peer"):encode())
  local envelope = assert(ENVELOPE:decode(received))
  print(envelope.id, envelope.role, #assert(envelope.rest).fields)
  local forwarded = assert(ENVELOPE:encode({ ...envelope, id = "b2" }))
  local read = assert(Protobuf.decode(forwarded))
  print(read:string(1), read:int(2), read:string(9))
  assert(read:string(1) == "b2" and read:int(2) == 7 and read:string(9) == "from a newer peer")
end

return Example
