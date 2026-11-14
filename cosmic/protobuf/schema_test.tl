--- [`cosmic.protobuf.schema`]: a message declared once, read and written as its record.
local Protobuf = require("cosmic.protobuf")
local Schema = require("cosmic.protobuf.schema")
local Test = require("cosmic.test")

Test.policy{}

local enum Genre
  "Jazz"
  "Rock"
  "Folk"
end

local record Artist
  name: string
  born?: integer
end

local record Track
  title?: string
  seconds?: number
  rating?: number
  plays?: integer
  offset?: integer
  live?: boolean
  genre?: Genre
  artist?: Artist
  art?: string
end

local GENRE <const> = Schema.enum_of("Genre", { Jazz = 1, Rock = 2, Folk = 7 })
local ARTIST <const> = Schema.message_of("Artist", { name = Schema.string(1), born = 2 })
local TRACK <const> = Schema.message_of("Track", {
  title = Schema.string(1), seconds = 2, rating = Schema.float(3), plays = Schema.fixed64(4), offset = Schema.sint(5),
  live = 6, genre = Schema.enum(7, GENRE), artist = Schema.message(8, ARTIST), art = 9,
})

local function test_a_record_round_trips_through_its_bytes()
  local track: Track = {
    title = "Blue in Green", seconds = 337.5, rating = 4.5, plays = 12, offset = -3, live = false, genre = "Jazz",
    artist = { name = "Miles Davis", born = 1926 }, art = "\xff\x00",
  }
  local bytes = assert(TRACK:encode(track))
  local back = assert(TRACK:decode(bytes))
  assert(back.title == "Blue in Green" and back.seconds == 337.5 and back.rating == 4.5 and back.plays == 12)
  assert(back.offset == -3 and back.live == false and back.genre == "Jazz" and back.art == "\xff\x00")
  local artist = assert(back.artist)
  assert(artist.name == "Miles Davis" and artist.born == 1926)
  assert(assert(TRACK:encode(back)) == bytes)
end

local function test_the_bytes_are_the_fields_in_number_order()
  local bytes = assert(TRACK:encode({ title = "a", live = true, genre = "Folk" }))
  assert(bytes == assert(Protobuf.writer():string(1, "a"):bool(6, true):int(7, 7):encode()))
end

local function test_an_absent_optional_field_is_nil_and_a_missing_required_one_fails()
  local empty = assert(TRACK:decode(""))
  assert(empty.title == nil and empty.artist == nil and empty.genre == nil)
  local artist, why = ARTIST:decode("")
  assert(artist == nil and why == "protobuf: Artist.name (field 1): missing", why)
end

local function test_a_failure_names_the_path_from_the_root()
  local nameless = assert(Protobuf.writer():int(2, 1926):encode())
  local bytes = assert(Protobuf.writer():bytes(8, nameless):encode())
  local track, why = TRACK:decode(bytes)
  assert(track == nil and why == "protobuf: Track.artist.name (field 1): missing", why)
  local text, not_text = TRACK:decode((assert(Protobuf.writer():bytes(1, "\xff"):encode())))
  assert(text == nil and not_text == "protobuf: Track.title (field 1): not UTF-8", not_text)
end

local function test_a_record_that_drops_fails_a_field_of_another_wire_type()
  local track, why = TRACK:decode((assert(Protobuf.writer():int(1, 5):encode())))
  assert(track == nil and why == "protobuf: Track.title (field 1): it has another wire type than its encoding", why)
  local unknown = assert(TRACK:decode((assert(Protobuf.writer():int(99, 5):encode()))))
  assert(unknown.title == nil, "a field of a number the record does not name is dropped")
  local unnamed = assert(TRACK:decode((assert(Protobuf.writer():int(7, 3):encode()))))
  assert(unnamed.genre == nil, "a number the enum does not name is dropped")
end

local record Relayed
  id?: string
  genre?: Genre
  count?: integer
  codes: {integer}
  rest?: Schema.Unknown
end

local RELAYED <const> = Schema.message_of("Relayed", { id = 1, genre = Schema.enum(2, GENRE), count = 3, codes = 4 })

local function test_a_record_that_keeps_writes_back_what_it_does_not_understand()
  local bytes = assert(Protobuf.writer():bytes(1, "a"):int(2, 99):bytes(3, "not a varint"):int(4, 5):int(77, 1)
      :bytes(78, "later"):encode())
  local relayed = assert(RELAYED:decode(bytes))
  assert(relayed.id == "a" and relayed.genre == nil and relayed.count == nil and #relayed.codes == 1)
  local rest = assert(relayed.rest)
  assert(#rest.fields == 2 and #rest.held == 2)
  local again = assert(Protobuf.decode((assert(RELAYED:encode(relayed)))))
  assert(again:int(2) == 99, "the number the enum does not name is written back")
  assert(again:bytes(3) == "not a varint", "the field of another wire type is written back")
  assert(again:int(77) == 1 and again:bytes(78) == "later")
end

local function test_a_field_that_is_set_replaces_what_was_held_for_it()
  local bytes = assert(Protobuf.writer():int(2, 99):bytes(3, "not a varint"):encode())
  local relayed = assert(RELAYED:decode(bytes))
  local changed: Relayed = { ...relayed, genre = "Rock", count = 4 }
  local again = assert(Protobuf.decode((assert(RELAYED:encode(changed)))))
  assert(again:int(2) == 2 and again:int(3) == 4)
  assert(#again:fields() == 2, "neither held field is written after its field's new value")
end

local function test_a_message_with_nothing_to_keep_has_no_unknown()
  local relayed = assert(RELAYED:decode((assert(Protobuf.writer():bytes(1, "a"):encode()))))
  assert(relayed.rest == nil)
end

local record Shelf
  name: string
  sizes: {integer}
  deltas: {integer}
  weights: {number}
  ratios: {number}
  flags: {boolean}
  labels: {string}
  blobs: {string}
  genres: {Genre}
  tracks: {Track}
  shelves: {Shelf}
  notes?: {string}
  total: integer
  open: boolean
end

local SHELF <const> = Schema.message_of("Shelf", {
  name = 1, sizes = Schema.field(2, { packed = true }), deltas = Schema.sint(3), weights = 4,
  ratios = Schema.float(5, { packed = true }), flags = Schema.field(6, { packed = true }), labels = Schema.string(7),
  blobs = 8, genres = Schema.enum(9, GENRE, { packed = true }), tracks = Schema.message(10, TRACK),
  shelves = Schema.self(11), notes = 12, total = Schema.field(13, { implicit = true }),
  open = Schema.field(14, { implicit = true }),
})

local function shelf(name: string, shelves: {Shelf}): Shelf
  return {
    name = name, sizes = { 1, 300 }, deltas = { -1, 2 }, weights = { 1.5 }, ratios = { 0.5, 2.0 }, flags = { true, false },
    labels = { "a", "b" }, blobs = { "\xff" }, genres = { "Jazz", "Folk" }, tracks = { { title = "t" } },
    shelves = shelves, total = 0, open = false,
  }
end

local function test_repeated_fields_and_a_message_that_holds_itself_round_trip()
  local top = shelf("top", { shelf("inner", {}) })
  local bytes = assert(SHELF:encode(top))
  local back = assert(SHELF:decode(bytes))
  assert(back.name == "top" and back.sizes[2] == 300 and back.deltas[1] == -1 and back.weights[1] == 1.5)
  assert(back.ratios[2] == 2.0 and back.flags[1] == true and back.flags[2] == false and back.labels[2] == "b")
  assert(back.blobs[1] == "\xff" and back.genres[2] == "Folk" and assert(back.tracks[1]).title == "t")
  assert(assert(back.shelves[1]).name == "inner" and back.notes == nil)
  assert(back.total == 0 and back.open == false, "a field with no presence reads as zero where it is absent")
  assert(assert(SHELF:encode(back)) == bytes)
end

local function test_a_repeated_field_is_written_one_field_each_unless_packed()
  local wire = assert(Protobuf.decode((assert(SHELF:encode(shelf("s", {}))))))
  local sizes, deltas = 0, 0
  for _, f in ipairs(wire:fields()) do
    if f.number == 2 then sizes = sizes + 1 end
    if f.number == 3 then deltas = deltas + 1 end
  end
  assert(sizes == 1, "a packed field is one field")
  assert(deltas == 2, "a field that is not packed is one field for each element")
  assert(not wire:has(13) and not wire:has(14), "a field with no presence is not written at zero")
end

local function test_a_repeated_field_reads_packed_or_not()
  local bytes = assert(Protobuf.writer():string(1, "s"):int(2, 7):packed(2, "int", { 8, 9 }):packed(3, "sint", { -4 })
      :encode())
  local back = assert(SHELF:decode(bytes))
  assert(#back.sizes == 3 and back.sizes[3] == 9 and back.deltas[1] == -4)
end

local function test_a_failure_in_a_repeated_message_names_its_place()
  local bad = assert(Protobuf.writer():bytes(1, "\xff"):encode())
  local good = assert(Protobuf.writer():string(1, "ok"):encode())
  local bytes = assert(Protobuf.writer():string(1, "s"):bytes(10, good):bytes(10, bad):encode())
  local back, why = SHELF:decode(bytes)
  assert(back == nil and why == "protobuf: Shelf.tracks[2].title (field 1): not UTF-8", why)
end

local function test_messages_nest_no_deeper_than_the_bound()
  local bytes = assert(Protobuf.writer():string(1, "leaf"):encode())
  for _ = 1, 5 do
    bytes = assert(Protobuf.writer():string(1, "s"):bytes(11, bytes):encode())
  end
  assert(SHELF:decode(bytes))
  local back, why = SHELF:decode(bytes, { max_depth = 3 })
  assert(back == nil and why:find("nests deeper than 3 messages", 1, true) ~= nil, why)
end

local function test_encode_fails_for_what_the_schema_cannot_write()
  local record Sized
    size?: integer
    name?: string
  end
  local SIZED <const> = Schema.message_of("Sized", { size = Schema.fixed32(1), name = Schema.string(2) })
  local bytes, why = SIZED:encode({ size = -5000000000 })
  assert(bytes == nil and why:find("protobuf: Sized: ", 1, true) == 1, why)
  local text, not_text = SIZED:encode({ name = "\xff" })
  assert(text == nil and not_text:find("protobuf: Sized: ", 1, true) == 1, not_text)
end

local function test_the_bytes_the_formats_specification_gives_are_read_and_written()
  local record Test1
    a?: integer
  end
  local record Test2
    b?: string
  end
  local record Test3
    c?: Test1
  end
  local record Test4
    d: {integer}
  end
  local TEST1 <const> = Schema.message_of("Test1", { a = 1 })
  local TEST2 <const> = Schema.message_of("Test2", { b = Schema.string(2) })
  local TEST3 <const> = Schema.message_of("Test3", { c = Schema.message(3, TEST1) })
  local TEST4 <const> = Schema.message_of("Test4", { d = Schema.field(4, { packed = true }) })
  assert(assert(TEST1:encode({ a = 150 })) == "\x08\x96\x01")
  assert(assert(TEST2:encode({ b = "testing" })) == "\x12\x07testing")
  assert(assert(TEST3:encode({ c = { a = 150 } })) == "\x1a\x03\x08\x96\x01")
  assert(assert(TEST4:encode({ d = { 3, 270, 86942 } })) == "\x22\x06\x03\x8e\x02\x9e\xa7\x05")
  assert(assert(TEST1:decode("\x08\x96\x01")).a == 150)
  assert(assert(assert(TEST3:decode("\x1a\x03\x08\x96\x01")).c).a == 150)
  assert(assert(TEST4:decode("\x22\x06\x03\x8e\x02\x9e\xa7\x05")).d[3] == 86942)
end

local function test_a_fixed32_and_an_sfixed32_each_hold_their_own_range()
  local record Sizes
    plain?: integer
    signed?: integer
    all: {integer}
  end
  local SIZES <const> = Schema.message_of("Sizes", {
    plain = Schema.fixed32(1), signed = Schema.sfixed32(2), all = Schema.sfixed32(3, { packed = true }),
  })
  local back = assert(SIZES:decode((assert(SIZES:encode({ plain = 4294967295, signed = -2147483648, all = { -1 } })))))
  assert(back.plain == 4294967295 and back.signed == -2147483648 and back.all[1] == -1)
  local negative, why = SIZES:encode({ plain = -1, all = {} })
  assert(negative == nil and why == "protobuf: Sizes: field 1: -1 is outside 0 to 4294967295", why)
  local wide, too_wide = SIZES:encode({ signed = 2147483648, all = {} })
  assert(wide == nil and too_wide:find("2147483648 is outside -2147483648 to 2147483647", 1, true) ~= nil, too_wide)
  local packed, past = SIZES:encode({ all = { 0, 4294967295 } })
  assert(packed == nil and past:find("field 3: 4294967295 is outside", 1, true) ~= nil, past)
end

local record Required
  genre: Genre
  artist: Artist
end

local REQUIRED <const> = Schema.message_of("Required", { genre = Schema.enum(1, GENRE), artist = Schema.message(2, ARTIST) })

local function test_a_required_enum_and_a_required_message_must_be_there()
  local artist = assert(Protobuf.writer():string(1, "a"):encode())
  local whole = assert(REQUIRED:decode((assert(Protobuf.writer():int(1, 2):bytes(2, artist):encode()))))
  assert(whole.genre == "Rock" and whole.artist.name == "a")
  local none, why = REQUIRED:decode((assert(Protobuf.writer():bytes(2, artist):encode())))
  assert(none == nil and why == "protobuf: Required.genre (field 1): missing", why)
  local unnamed, no_name = REQUIRED:decode((assert(Protobuf.writer():int(1, 99):bytes(2, artist):encode())))
  assert(unnamed == nil and no_name == "protobuf: Required.genre (field 1): the enum names no number 99", no_name)
  local alone, no_artist = REQUIRED:decode((assert(Protobuf.writer():int(1, 2):encode())))
  assert(alone == nil and no_artist == "protobuf: Required.artist (field 2): missing", no_artist)
end

local function test_a_singular_message_that_comes_twice_is_the_two_merged()
  local first = assert(Protobuf.writer():string(1, "a"):encode())
  local second = assert(Protobuf.writer():int(2, 1926):encode())
  local track = assert(TRACK:decode((assert(Protobuf.writer():bytes(8, first):bytes(8, second):encode()))))
  local artist = assert(track.artist)
  assert(artist.name == "a" and artist.born == 1926)
end

local function test_a_field_with_no_presence_is_written_when_it_is_not_zero_and_read_when_it_is_there()
  local wire = assert(Protobuf.decode((assert(SHELF:encode({ ...shelf("s", {}), total = 7, open = true })))))
  assert(wire:int(13) == 7 and wire:bool(14) == true)
  local back = assert(SHELF:decode((assert(Protobuf.writer():string(1, "s"):int(13, 0):int(14, 1):encode()))))
  assert(back.total == 0 and back.open == true)
end

local function test_an_optional_repeated_field_is_nil_when_empty_and_its_elements_otherwise()
  local back = assert(SHELF:decode((assert(SHELF:encode({ ...shelf("s", {}), notes = { "a", "b" } })))))
  local notes = assert(back.notes)
  assert(#notes == 2 and notes[2] == "b")
  local none = assert(SHELF:decode((assert(SHELF:encode({ ...shelf("s", {}), notes = {} })))))
  assert(none.notes == nil and #none.sizes == 2, "an empty one reads as nil, and one that is not optional as a list")
end

local function test_a_failure_to_write_an_embedded_message_names_its_place()
  local bytes, why = SHELF:encode({ ...shelf("s", {}), tracks = { { title = "ok" }, { title = "\xff" } } })
  assert(bytes == nil and why:find("protobuf: Shelf.tracks[2]: ", 1, true) == 1, why)
end

local record Held
  genre?: Genre
  codes: {integer}
  labels: {string}
  total: integer
  artist?: Artist
  rest?: Schema.Unknown
end

local HELD <const> = Schema.message_of("Held", {
  genre = Schema.enum(1, GENRE), codes = 2, labels = 3, total = Schema.field(4, { implicit = true }),
  artist = Schema.message(5, ARTIST),
})

local function test_what_is_held_for_a_repeated_or_an_implicit_field_is_written_back()
  local bytes = assert(Protobuf.writer():int(2, 7):fixed32(2, 9):int(3, 5):bytes(4, "x"):int(5, 1):encode())
  local held = assert(HELD:decode(bytes))
  assert(#held.codes == 1 and #held.labels == 0 and held.total == 0 and held.artist == nil)
  local again = assert(Protobuf.decode((assert(HELD:encode(held)))))
  assert(again:int(2) == 7 and again:fixed32(2) == 9, "a field of another wire type among a repeated field's is kept")
  assert(again:int(3) == 5 and again:bytes(4) == "x" and again:int(5) == 1)
end

local function test_a_number_the_enum_does_not_name_is_not_held_once_a_later_field_replaces_it()
  local held = assert(HELD:decode((assert(Protobuf.writer():int(1, 99):int(1, 2):encode()))))
  assert(held.genre == "Rock" and held.rest == nil)
  local cleared = assert(Protobuf.decode((assert(HELD:encode({ ...held, genre = nil })))))
  assert(not cleared:has(1), "the number a later field replaced does not come back when the field is cleared")
end

local function test_an_unknown_built_by_hand_does_not_override_a_field_the_record_names()
  local forged: Schema.Unknown = { fields = { { number = 4, wire = Protobuf.VARINT, value = 9 } }, held = {} }
  local wire = assert(Protobuf.decode((assert(HELD:encode({ codes = {}, labels = {}, total = 1, rest = forged })))))
  assert(wire:int(4) == 1 and #wire:fields() == 1)
end

local function test_a_held_field_built_by_hand_is_not_written_beside_its_field()
  local forged: Schema.Unknown = { fields = {}, held = { { number = 1, wire = Protobuf.VARINT, value = 99 } } }
  local set = assert(Protobuf.decode((assert(HELD:encode({ genre = "Rock", codes = {}, labels = {}, total = 0, rest = forged })))))
  assert(set:int(1) == 2 and #set:fields() == 1)
  local unset = assert(Protobuf.decode((assert(HELD:encode({ codes = {}, labels = {}, total = 0, rest = forged })))))
  assert(unset:int(1) == 99, "while the field is nil, what is held for it is written")
end

local function test_a_required_field_of_another_wire_type_fails_a_record_that_keeps_and_says_so()
  local record Kept
    id: integer
    rest?: Schema.Unknown
  end
  local KEPT <const> = Schema.message_of("Kept", { id = 1 })
  local kept, why = KEPT:decode((assert(Protobuf.writer():bytes(1, "x"):encode())))
  assert(kept == nil and why == "protobuf: Kept.id (field 1): it has another wire type than its encoding", why)
  local none, missing = KEPT:decode("")
  assert(none == nil and missing == "protobuf: Kept.id (field 1): missing", missing)
end

local function test_a_record_of_no_fields_is_a_message_of_none()
  local record Empty
  end
  local EMPTY <const> = Schema.message_of("Empty", {})
  assert(assert(EMPTY:encode({})) == "")
  assert(EMPTY:decode((assert(Protobuf.writer():int(1, 1):encode()))) ~= nil)
end

local function test_a_record_that_drops_fails_a_misfit_field_beside_one_that_fits()
  local mixed = assert(Protobuf.writer():string(1, "a"):int(1, 5):encode())
  local track, why = TRACK:decode(mixed)
  assert(track == nil and why == "protobuf: Track.title (field 1): it has another wire type than its encoding", why)
  local nested = assert(Protobuf.writer():bytes(8, (assert(Protobuf.writer():string(1, "a"):encode()))):int(8, 1):encode())
  local other, embedded = TRACK:decode(nested)
  assert(other == nil and embedded == "protobuf: Track.artist (field 8): it has another wire type than its encoding",
    embedded)
end
