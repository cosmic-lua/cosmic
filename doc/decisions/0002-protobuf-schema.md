# 0002 protobuf schema

status: proposed

## context

`cosmic.protobuf` is the Protocol Buffers wire format with no schema: a message is a list of fields, each a number, a
wire type and a value. it is intended and not in the tree yet. a program that speaks a protocol of many messages
writes, for each message, a record, a reader and a writer on that codec. a client of the Media Remote Protocol holds
about 2,700 lines of them, by its author's count.

the question is where a message's field numbers and encodings are declared, so that one declaration gives the record,
the reader and the writer.

the evidence is a slice of that protocol written five ways and run: ten messages, four enums and 60 fields, by hand
and under each alternative below. the messages follow the protocol's public descriptions. their field numbers are
illustrative: the client's own module was not read. three of them are the worked messages of this record:

- `CommandInfo`: scalars, an enum, repeated scalars (packed) and a repeated enum.
- `ContentItem`: bytes, a nested message and a message that holds itself.
- `Protocol`: an enum whose values grow, the payload messages as fields (the protocol declares them as extensions),
  and the fields a reader does not know.

the protocol's descriptions use no `oneof` keyword and no map field. what stands for each is given below.

## decision

a message is a Teal record. its field numbers, and the encodings its types do not give, are the argument of a call the
build resolves, as it resolves [`Shape.record_of`]: `Protobuf.message_of("Module.Record", { field = number })`. the
build reads the record's declaration and the table, checks one against the other, and writes the reader and the writer
as Teal the checker types. all of it is intended.

the principle: what a record's declaration cannot say rides in the arguments of the call that names the record, as
values the checker and the build both read. it does not ride in a comment, a name or a second language.

### what the caller writes

```teal skip=intended
local Protobuf = require("cosmic.protobuf")

local record Messages
  enum Command
    "Play"
    "Pause"
    "SeekToPlaybackPosition"
  end

  enum RepeatMode
    "Unknown"
    "One"
    "All"
  end

  enum Type
    "Unknown"
    "DeviceInfo"
    "UpdateContentItem"
  end

  record CommandInfo
    command?: Command
    enabled?: boolean
    active?: boolean
    preferredIntervals: {number}
    localizedTitle?: string
    minimumRating?: number
    supportedRates: {number}
    repeatMode?: RepeatMode
    supportedRepeatModes: {RepeatMode}
    skipInterval?: integer
  end

  record ContentItemMetadata
    title?: string
    duration?: number
    playbackRate?: number
    trackNumber?: integer
    playCount?: integer
  end

  record ContentItem
    identifier?: string
    metadata?: ContentItemMetadata
    artworkData?: string
    sections: {ContentItem}
  end

  record DeviceInfo
    name: string
    uniqueIdentifier?: string
    protocolVersion?: integer
    allowsPairing?: boolean
  end

  record Protocol
    type?: Type
    identifier?: string
    timestamp?: integer
    deviceInfo?: DeviceInfo
    contentItem?: ContentItem
    unknown?: Protobuf.Unknown
  end
end

local COMMAND <const> = Protobuf.enum_of("Messages.Command", { Play = 1, Pause = 2, SeekToPlaybackPosition = 24 })
local REPEAT <const> = Protobuf.enum_of("Messages.RepeatMode", { Unknown = 0, One = 1, All = 2 })
local TYPE <const> = Protobuf.enum_of("Messages.Type", { Unknown = 0, DeviceInfo = 15, UpdateContentItem = 60 })

local COMMAND_INFO <const> = Protobuf.message_of("Messages.CommandInfo", {
  command = Protobuf.enum(1, COMMAND), enabled = 2, active = 3, preferredIntervals = 4, localizedTitle = 5,
  minimumRating = Protobuf.float(6), supportedRates = Protobuf.float(8), repeatMode = Protobuf.enum(10, REPEAT),
  supportedRepeatModes = Protobuf.enum(11, REPEAT), skipInterval = Protobuf.sint(12),
})
local METADATA <const> = Protobuf.message_of("Messages.ContentItemMetadata", {
  title = 1, duration = 4, playbackRate = Protobuf.float(5), trackNumber = 6, playCount = Protobuf.fixed64(9),
})
local CONTENT_ITEM <const> = Protobuf.message_of("Messages.ContentItem", {
  identifier = 1, metadata = Protobuf.message(2, METADATA), artworkData = 3, sections = Protobuf.self(7),
})
local DEVICE_INFO <const> = Protobuf.message_of("Messages.DeviceInfo", {
  uniqueIdentifier = 1, name = 2, protocolVersion = 7, allowsPairing = 10,
})
local PROTOCOL <const> = Protobuf.message_of("Messages.Protocol", {
  type = Protobuf.enum(1, TYPE), identifier = 2, timestamp = 5,
  deviceInfo = Protobuf.message(20, DEVICE_INFO), contentItem = Protobuf.message(60, CONTENT_ITEM),
})
```

a message is built as a record literal and read as a record:

```teal skip=intended
local item: Messages.ContentItem = { identifier = "b2", sections = {} }
local bytes = PROTOCOL:encode({ type = "UpdateContentItem", identifier = "a1", contentItem = item })
local message, why = PROTOCOL:decode(bytes)
if message == nil then return nil, why end
local content = message.contentItem
if content ~= nil then print(content.identifier, #content.sections) end
```

### what the types say

- `message_of` answers a `Protobuf.Message<T>`, with `T` the record, as [`Shape.record_of`] answers a `Typed<T>`:
  the type comes from the functions the build puts into the call, so no annotation can say another.
- `decode` answers `T?, string`. every read after it is a typed read of a record.
- `encode` takes a `T`. a message under construction is a record literal, so a misspelled field (`literal_unknown`),
  a value of the wrong type (`not_assignable`) and a required field left out are refused by the checker.
- the build refuses, at the call's line: a field with no number, a number with no field, a number given twice or out
  of the format's range, an encoding that does not fit the field's type (`Protobuf.float` on a `string`), an enum value
  with no number or with the number of another value, and a field of a type with no encoding (a function, a union,
  a generic).
- the call's own form is ordinary Teal: the table is a `{string: integer | Protobuf.Field}`, and a stand-in module of
  that signature, given the functions by hand, passes the checker.

### how a field's type maps

a bare number takes the encoding the type gives. a helper names another, and each takes options as its last
argument. `Protobuf.field(n, options)` is the type's own encoding with options.

- `integer`: a varint in two's complement, which is `int32`, `int64`, `uint32` and `uint64` on the wire.
  `Protobuf.sint(n)`, `Protobuf.fixed32(n)`, `Protobuf.fixed64(n)`, `Protobuf.sfixed32(n)` and
  `Protobuf.sfixed64(n)` name the others. a `uint64` above the largest integer reads as the negative integer of the
  same bits.
- `number`: a double. `Protobuf.float(n)` is a float.
- `boolean`: a bool. `string`: a length-delimited field, which is both `string` and `bytes`.
- an enum: `Protobuf.enum(n, CODEC)`, with the codec `enum_of` answers for that enum.
- a record: `Protobuf.message(n, CODEC)`, with the codec `message_of` answers for that record. the checker holds the
  codec to the field's type: the code the build writes assigns what `CODEC` decodes to the field. the codec is a
  value, so one from another module comes through a `require`, and one of this module is declared above the call.
  `Protobuf.self(n)` is the record's own codec, for a message that holds itself: the build writes its reader as a
  function that names itself.
- `{T}`: a repeated field of `T`'s encoding. numbers, booleans and enums are written packed, and read packed or not,
  as the format requires of a reader. `{ packed = false }` writes them one field each.
- `Protobuf.Unknown`: the fields whose numbers the call does not name. it takes no number.

presence follows the field's own declaration:

- `f?: T` is nil when the field is absent, and is not written when nil. this is proto2's `optional` and proto3's.
- `f: T` must be there: its absence is a failure of `decode`, and it is always written. this is proto2's `required`,
  and the rule [`cosmic.shape`] holds a record's field to.
- `f: {T}` is the exception, since the wire cannot tell an empty repeated field from an absent one: absent reads as
  an empty array, and an empty array writes nothing. a literal still writes `f = {}`. `f?: {T}` spares the literal:
  nil writes nothing, and absent reads as nil.
- `{ implicit = true }` on a field declared `f: T` is proto3's field without presence: absent reads as zero, `""` or
  false, and that value is not written.

a singular field that occurs twice keeps the last occurrence, a message included.

an enum's codec is closed. `enum_of` names each value's number, which may be zero or negative, and refuses two
values of one number. a number the enum does not name makes an optional field nil and a repeated field one element
shorter, and fails a required field. the number is dropped, not kept among the unknown fields: kept there, it would be
written after the field's new value and a reader, which takes the last, would read the old number back. so an enum
that a peer may extend, such as `Protocol.type`, is better declared `integer` and compared with
`TYPE:number("DeviceInfo")`: the field then holds whatever number came, and writes it back.

a oneof is its members as optional fields that name one group with `{ oneof = "name" }`, the tagged record
[`cosmic.shape`] asks for in place of a union. `decode` leaves at most one member set, the last on the wire, as the
format says. `encode` of a record with two set is a bug in the caller and raises. the checker does not know that one
is set: the caller tests each member.

an extension is a field of the record it extends, declared with the others, and no group binds it: `Protocol` above
declares two. an extension the call does not name is an unknown field, which a caller reads with the wire codec's own
readers.

unknown fields are the fields whose numbers the call does not name. they are kept where the record declares a field
of `Protobuf.Unknown`, in wire order, and `encode` writes them after the known fields. no known number is among them,
so writing them back changes no known field. a record with no such field drops them, as a shape drops a key it does
not name.

### failures and bounds

`decode` never raises, whatever the bytes. it answers nil and the first thing that did not fit, named by the path of
fields from the root, which is built only on failure: `protobuf: Protocol.contentItem.sections[3].metadata (field 2):
12 bytes declared, 7 left`.

- a known field with another wire type than its encoding is a failure, not an unknown field.
- a length is checked against the bytes left before anything is copied.
- a varint is at most 10 bytes.
- messages nest at most `max_depth` deep, 64 unless `decode` is given another, as [`Json.decode`] takes one.
- nothing bounds the input's length: the caller bounds the frame it reads. the memory `decode` takes is a multiple
  of that length.

### cost

measured on the slice with a stand-in for the wire codec, a 951-byte message, five runs on a shared host whose times
moved by a third between runs. the ratios below are the spread of those runs:

- the code the build writes costs what careful hand-written code costs: from 8% faster to 17% slower to encode, and
  from 11% faster to 12% slower to decode (about 90 µs and 120 µs).
- the source falls from 625 lines to about 170: the 115 lines of records stay, and 510 lines of readers and writers
  become about 55 lines of calls. that is 73% less. if the client's module is shaped as the slice is, its 2,700 lines
  become 700 to 1,000. the conversion measures it.
- a built program carries the generated functions and nothing of the build. their Lua is 1.3 times the hand-written
  text for the slice (24.7 kB against 18.8 kB).
- the build gains one resolver beside [`build.syntax_shape_specs`], which is 649 lines, and the tool carries it. the
  two places that run the shape resolver run it too: the tree's compile ([`build/tree_program.tl`]) and the language
  server ([`build/lsp/syntax_read.tl`]).
- a generated reader names one local for each field beside a few of its own, and a Lua function holds 200, so a
  message has at most about 190 fields. this bounds a message that carries every payload as a field of its own.

what the measurement stands on: a script wrote the readers and writers from a table of the slice's fields, as
functions of one module that call each other by name, and the checker took them as written. the build would put each
message's pair into its own call, where a nested message is reached through its codec's field, one index more for
each nested message, which was not timed. the stand-in checked the call's form, a nested codec and a record that holds
itself in that form. it did not write the failure path, the oneof rule, the options or a required field's failure.

### tests

- the resolver's refusals, each by its message, as [`build/syntax_shape_specs_test.tl`] holds the shape resolver's.
- bytes the format's specification gives, and bytes another implementation wrote, kept as fixtures.
- a fuzz test over a fixture schema that holds every encoding: `decode` of any bytes answers or fails and never
  raises, `decode(encode(x))` is `x`, and nesting past `max_depth` fails (promise 1: "the parsers that face untrusted
  input are fuzzed").
- an example file, which `cosmic docs` shows.

## rejected alternatives

each is sketched for the same messages. line counts are of the whole slice, blank lines and comments left out, against
625 by hand.

### numbers in comments, in names or by position

```text
record ContentItem
  identifier?: string             -- = 1
  metadata?: ContentItemMetadata  -- = 2
  artworkData?: string            -- = 3 bytes
  sections: {ContentItem}         -- = 7
end
```

this is the shortest form in Teal, one line for each field. it loses for three reasons.

- the checker reads no comment, and the types the build reads carry none ([`lang/types.tl`]'s `Field` holds a name, a
  type, `mut` and `omittable`). a tag is checked by its own parser alone, and a reference to another message's codec
  has no value to be checked against.
- a trailing comment is no doc comment ([`doc/writing.md`]), and it is where a marker goes (`-- checked: ...`). a doc
  comment above each field doubles the lines.
- a comment that changes the bytes on the wire is not what a reader takes a comment for.

a naming rule (`identifier_1`) puts the number in every read of the field. numbering by position breaks the wire
when a field is inserted, and cannot say that a number is skipped.

### a schema built at run time

```text
local CommandInfo <const> = Schema.message("CommandInfo")
local ContentItem <const> = Schema.message("ContentItem")

local record CommandInfoFields
  command: Schema.Field<string>
  enabled: Schema.Field<boolean>
  preferredIntervals: Schema.List<number>
  skipInterval: Schema.Field<integer>
end

local COMMAND_INFO: CommandInfoFields = {
  command = Schema.enum(CommandInfo, 1, "command", COMMAND),
  enabled = Schema.bool(CommandInfo, 2, "enabled"),
  preferredIntervals = Schema.doubles(CommandInfo, 4, "preferredIntervals"),
  skipInterval = Schema.sint(CommandInfo, 12, "skipInterval"),
}

local record ContentItemFields
  identifier: Schema.Field<string>
  metadata: Schema.Field<Schema.Message>
  sections: Schema.List<Schema.Message>
end

local CONTENT_ITEM: ContentItemFields = {
  identifier = Schema.string(ContentItem, 1, "identifier"),
  metadata = Schema.sub(ContentItem, 2, "metadata", ContentItemMetadata),
  sections = Schema.subs(ContentItem, 7, "sections", ContentItem),
}

local record ProtocolFields
  type: Schema.Field<string>
  deviceInfo: Schema.Field<Schema.Message>
  contentItem: Schema.Field<Schema.Message>
end

local PROTOCOL: ProtocolFields = {
  type = Schema.enum(Protocol, 1, "type", TYPE),
  deviceInfo = Schema.sub(Protocol, 20, "deviceInfo", DeviceInfo),
  contentItem = Schema.sub(Protocol, 60, "contentItem", ContentItem),
}

local message = Schema.new(CommandInfo)
COMMAND_INFO.enabled.set(message, true)
local enabled = COMMAND_INFO.enabled.get(message)     -- boolean?
local wrong = CONTENT_ITEM.identifier.get(message)    -- compiles, and is nil
```

- no code at run time can answer a record: "Lua erases record types, so shapes construct their records rather than
  asserting them" ([design.md](../design.md), on Teal; principle 4 forecloses the cast). so a message is one
  opaque type, read through a typed handle for each field. the prototype keeps a store for each Teal type, since no
  handle can turn an `any` into a `T`.
- the checker knows the type of a scalar read. it does not know which message a value is: the handle of one message
  reads another and answers nil. an enum is a `string`, since no generic code can answer an enum type. a nested
  message is the same opaque type. a required field left out is found by nobody.
- the handles of a message need a record that declares them: a table of handles of several types has no type of its
  own (`arms_differ`), and a module cannot return one (`export_not_declared`). so each field is written twice, and the
  slice is 213 lines (66% less), against 170.
- it decodes 2.2 to 2.6 times slower than the hand-written code, and encodes 1.1 to 1.4 times slower.
- it adds nothing to the build. the run-time module is 342 lines.

### `.proto` files read by the build

```text
message CommandInfo {
  optional Command command = 1;
  optional bool enabled = 2;
  optional bool active = 3;
  repeated double preferredIntervals = 4 [packed = true];
  optional string localizedTitle = 5;
  optional float minimumRating = 6;
  repeated float supportedRates = 8 [packed = true];
  optional RepeatMode repeatMode = 10;
  repeated RepeatMode supportedRepeatModes = 11 [packed = true];
  optional sint32 skipInterval = 12;
}

message ContentItem {
  optional string identifier = 1;
  optional ContentItemMetadata metadata = 2;
  optional bytes artworkData = 3;
  repeated ContentItem sections = 7;
}

message Protocol {
  optional Type type = 1;
  optional string identifier = 2;
  optional uint64 timestamp = 5;
  extensions 6 to 999;
}

extend Protocol {
  optional DeviceInfo deviceInfo = 20;
  optional ContentItem contentItem = 60;
}
```

a `messages.proto` beside a module would become the module `messages`, as a `.tmpl` becomes one
([`build/derivation.tl`]), exporting the records and their codecs. it is the least to write: 114 lines for the slice
(82% less). it loses on what it adds and on what it hides.

- the build gains a second language: a lexer and a parser (those of [`cosmic.template`] are 724 lines), the mapping of
  its names and scopes to Teal's, `import` across files, and a derivation. the subset it would take is `syntax`,
  `package`, `import`, `message`, `enum`, `oneof`, `map`, `repeated`, `optional`, `required`, `reserved`,
  `extensions`, `extend` and the `packed` option. it would refuse services, groups, custom options and the
  well-known types.
- the record a program reads is declared in no Teal source. a reader of the program finds it with `cosmic docs`
  alone, and what `T?` or `T` a proto2 `optional` or a proto3 field becomes is a rule to learn, not a declaration to
  read.
- its gain over the decision is 56 lines of the slice, and a file taken unchanged from a protocol's publisher. the
  protocol at hand publishes none: its descriptions are reconstructed.

it stays open as a front end: a `.proto` reader would write the records and the `message_of` calls this decision
defines, and need nothing else of the run time. it is worth its cost when a program must track a publisher's `.proto`
files.

### helpers on the wire codec

```text
local function encode_command_info(m: Messages.CommandInfo): string
  local out: mut {string} = {}
  Wire.put_enum(out, 1, m.command, COMMAND_NUMBER)
  Wire.put_bool(out, 2, m.enabled)
  Wire.put_bool(out, 3, m.active)
  Wire.packed_double(out, 4, m.preferredIntervals)
  Wire.put_string(out, 5, m.localizedTitle)
  Wire.put_float(out, 6, m.minimumRating)
  Wire.packed_float(out, 8, m.supportedRates)
  Wire.put_enum(out, 10, m.repeatMode, REPEAT_NUMBER)
  Wire.put_enums(out, 11, m.supportedRepeatModes, REPEAT_NUMBER)
  Wire.put_sint(out, 12, m.skipInterval)
  return table.concat(out)
end

local function decode_command_info(bytes: string, depth: integer): Messages.CommandInfo?, string
  local r, why = Wire.reader("CommandInfo", bytes, depth)
  if r == nil then return nil, why end
  local m: Messages.CommandInfo = {
    command = Wire.enum(r, 1, COMMAND),
    enabled = Wire.bool(r, 2),
    active = Wire.bool(r, 3),
    preferredIntervals = Wire.doubles(r, 4),
    localizedTitle = Wire.string(r, 5),
    minimumRating = Wire.float(r, 6),
    supportedRates = Wire.floats(r, 8),
    repeatMode = Wire.enum(r, 10, REPEAT),
    supportedRepeatModes = Wire.enums(r, 11, REPEAT),
    skipInterval = Wire.sint(r, 12),
  }
  if r.bad ~= "" then return nil, r.bad end
  return m, ""
end

local function decode_content_item(bytes: string, depth: integer): Messages.ContentItem?, string
  local r, why = Wire.reader("ContentItem", bytes, depth)
  if r == nil then return nil, why end
  local m: Messages.ContentItem = {
    identifier = Wire.string(r, 1),
    metadata = Wire.message(r, 2, decode_content_item_metadata),
    artworkData = Wire.string(r, 3),
    sections = Wire.messages(r, 7, decode_content_item),
  }
  if r.bad ~= "" then return nil, r.bad end
  return m, ""
end

local function decode_protocol(bytes: string): Messages.Protocol?, string
  local r, why = Wire.reader("Protocol", bytes, 1)
  if r == nil then return nil, why end
  local m: Messages.Protocol = {
    type = Wire.enum(r, 1, TYPE),
    identifier = Wire.string(r, 2),
    timestamp = Wire.int(r, 5),
    deviceInfo = Wire.message(r, 20, decode_device_info),
    contentItem = Wire.message(r, 60, decode_content_item),
    unknown = Wire.others(r, { 1, 2, 5, 20, 60 }),
  }
  if r.bad ~= "" then return nil, r.bad end
  return m, ""
end
```

a reader that indexes a message's fields by number and answers each by type, and writers that take an optional
value. generic functions type all of it, the nested and repeated messages included, and the build gains nothing.
the writers of `ContentItem` and `Protocol` follow `encode_command_info` line for line.

- the slice is 385 lines (38% less), not half: a field is still written three times, in the record, the reader and
  the writer, and each enum twice, by number and by name.
- the reader and the writer of a field each name its number and its encoding, so they can disagree, and nothing
  checks one against the other. this is the class of bug the declaration removes.
- the oneof rule and the list of known numbers for the unknown fields are written by hand in each message.
- it decodes 1.3 to 1.6 times slower than the hand-written code: it indexes the fields, then scans them once for
  each repeated field.

it is what remains if the build is to gain nothing, and its helpers are small enough to land with the wire codec.

### a schema walked at run time, with the record built by the build

the build would write only the function that makes the record from decoded values, and a table that describes the
fields; run-time code would walk the wire against the table. the reads are as typed as the decision's, the program
carries one walker in place of a reader and a writer for each message, and no message has a field limit. it was not
prototyped. it loses on two counts. the build's part is the same resolver, so it saves nothing there. and the walk
is the run-time schema's, which decoded 2.2 to 2.6 times slower, where principle 1 has size yield to performance. it
is the form to return to if the generated code's size is ever what a program cannot afford.

### the wire decoded to a table, then `Shape.record_of`

a map from numbers to names would turn the wire's fields into a table keyed by name, and the record's shape would
check it. no resolver is added. it loses because the shape checks what JSON decodes: it has no rule for an enum's
numbers, a packed field, a float against a double or a field that occurs twice, so each is settled before the check
by code that needs the schema anyway. every message is built twice. a failure names a JSON path, not a field number.
and the shape resolver refuses a record that holds itself ("has no finite shape").

### a new form in the grammar

a field attribute for the number (`identifier?: string = 1`) would serve one module. "grammar grows only where it
removes boilerplate without opening an escape hatch" ([0001](0001-friction-triage.md)), and the call's table removes
the same boilerplate with no grammar.

## consequences

- a message and its codec are one declaration, and the checker types every read and every literal of it.
- the build holds a second resolver that reads a record's declaration. what the two share (finding the call, spelling
  a declaration from the calling module, the splice) becomes one module, so a third costs less. they differ on a
  record that holds itself: the shape resolver refuses it, and this one writes a function that names itself.
- like `record_of`, the call is resolved only where a module is compiled: an aliased or computed call, a chunk loaded
  by hand and a script run with `--standalone` raise, saying so.
- field numbers sit in a table apart from the fields, so a field added to the record without a number is a build
  error at the call, not a field silently left off the wire.
- every field name of a message is written twice in the module, once in the record and once in the call.
- a program built with it is larger than one built on helpers, by the generated functions (principle 1, size yields
  to performance).

## left out

- services and RPC, groups, `Any` and the well-known types, the JSON mapping, text format, and reflection over a
  schema at run time.
- validating that a `string` is UTF-8. a Teal string is bytes, and a caller that needs text checks it.
- merging the occurrences of a singular message field, which the format asks of a reader. the last occurrence wins.
- a field's declared default (`[default = x]`). an absent optional field is nil, and the caller supplies the value.
- two enum values of one number (`allow_alias`).
- an extension declared in another module than the record. it is an unknown field there.
- keeping an enum number the enum does not name. the field is declared `integer` where that matters.
- map fields, until a protocol in use has one. the form is reserved: a field typed `{string: T}` or `{integer: T}`
  with `Protobuf.map(n, ...)`, written in key order.
- integer kinds that refuse a value outside 32 bits. `integer` holds what the wire holds.
- a tagged union of records for a oneof, which would let the checker see that one member is set. it costs a wrapper
  record for each member.

## open questions

1. is a field declared `f: T` required, as the decision has it, or proto3's field without presence? required agrees
   with [`cosmic.shape`] and with "types never lie". a protocol that is all proto3 would then write `{ implicit =
   true }` on most scalar fields, or declare them optional.
2. is a known field with the wrong wire type a failure, as the decision has it, or an unknown field, as the reference
   implementations treat it? failing is stricter than the peers a program talks to.
3. does `encode` raise on a record the schema cannot write (two members of a oneof set, a `fixed32` out of range), as
   the decision has it, or answer `string?, string`? raising keeps `encode` one value for every caller that has no
   such field.
4. do `message_of` and `enum_of` live in `cosmic.protobuf`, as `record_of` lives in [`cosmic.shape`], or in a module
   of their own, so that a program that uses the wire codec alone does not carry their run-time part?
5. two records that hold each other need a codec named before it is defined. the checker refuses a function that
   names a local assigned later (`not_assigned`), so the build cannot write the pair as two functions. a
   `Protobuf.forward("Module.Record")` that a later `message_of` fills costs a line for each cycle and an indirect
   call. is it wanted now, or when a protocol has such a pair? a message that holds itself needs none.
6. is 64 the default depth, or the 100 of the reference implementations?
7. which module is converted first to measure the estimate, and does its protocol message stay under 190 fields?
8. is an enum's unnamed number dropped, as the decision has it, or kept as proto2 keeps it? keeping it needs the
   writer to leave out a kept number whose field has since been set, for each enum field.

## pull requests

each starts from main after the one before has merged.

1. the wire codec, `cosmic.protobuf`. everything below depends on it.
2. `build: share what a record's resolver needs`. the parts of [`build.syntax_shape_specs`] a second resolver uses
   move to a module of their own. no behavior changes. depends on nothing.
3. `protobuf: declare a message once`. `enum_of` and `message_of` for singular scalars, enums, nested messages,
   presence and unknown fields, with failures, bounds, the language server, the fuzz test and the example. depends
   on 1 and 2, and on questions 1 to 4 and 6.
4. `protobuf: repeated, packed and recursive fields`, the resolver's walk of a record that holds itself included.
   depends on 3, and on question 5 for a cycle of two.
5. `protobuf: oneof groups`. depends on 3.
6. `doc: a guide to a protobuf protocol`, with the roadmap's entry for what is left out. depends on 4 and 5.
7. outside this tree: the client's module converted, and the estimate measured. depends on 4 and 5.

[`build.syntax_shape_specs`]: ../../build/syntax_shape_specs.tl
[`build/derivation.tl`]: ../../build/derivation.tl
[`build/lsp/syntax_read.tl`]: ../../build/lsp/syntax_read.tl
[`build/syntax_shape_specs_test.tl`]: ../../build/syntax_shape_specs_test.tl
[`build/tree_program.tl`]: ../../build/tree_program.tl
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.template`]: ../../cosmic/template/init.tl
[`doc/writing.md`]: ../writing.md
[`Json.decode`]: ../../cosmic/json.tl
[`lang/types.tl`]: ../../lang/types.tl
[`Shape.record_of`]: ../../cosmic/shape.tl
