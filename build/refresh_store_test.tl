--- `cosmic refresh`: a program `cosmic build` wrote, refreshed from
--- files on disk -- the vendored bundle, a tzdata sdist made here from
--- the vendored zones -- and read back: its rows, the release its bill
--- of materials records, and that it still runs; and the docs that find
--- the verb. These need `store`: building that program copies every
--- `cosmic.*` module's rows from this program's own database
--- ([`embed.database`] reads [`Store.databases()`]), and `docs` searches
--- them. Refreshing this program itself is in build/refresh_tool_test.tl,
--- and what needs neither in build/refresh_test.tl.

local Child = require("cosmic.child")
local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Test = require("cosmic.test")
local artifact = require("build.artifact")
local embed = require("build.embed")
local invoke = require("build.invoke")
local refresh = require("build.refresh")
local Clock = require("cosmic.clock")
local build_paths = require("build.paths")

--- The vendored bundle and zones a refresh replaces, and this program,
--- whose core a program it builds runs on.
--- `store`: [`embed.database`] reads every `cosmic.*` module's rows, and
--- `docs` searches them.
Test.policy{
  profiles = { "cosmic" },
  grants = {
    { path = "o/bin", letters = "rx" },
    { path = "vendor/cacert/", letters = "r" },
    { path = "vendor/tzdata/", letters = "r" },
    { path = "o/cosmic.db", letters = "r" },
  },
}

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

local bundle <const> = "vendor/cacert/certdata.txt"
local zones <const> = "vendor/tzdata/zoneinfo"

local datasets: mut {string:refresh.Dataset} = {}
for _, dataset in ipairs(refresh.datasets) do
  datasets[dataset.name] = dataset
end

--- A program `cosmic build` wrote under `tmp`, which prints "ok": one of this
--- host's alone (`cosmic build --host`), which a test runs with nothing of the
--- system's, or with `portable` a portable one, which only a tool of every
--- core writes ([`build.embed_portable_tool_test`] refreshes one). A refresh
--- reads and writes either layout alike ([`artifact.split`]).
local function program(tmp: string, portable?: boolean): string
  local tree = tmp .. "/tree"
  assert(Fs.mkdirs(tree .. "/cmd/ok"))
  assert(Fs.write(tree .. "/cmd/ok/main.tl", 'return function(): integer print("ok") return 0 end\n'))
  assert(embed.tree(tree, portable ~= true))
  return build_dir(tree) .. "/bin/ok"
end

--- The database the artifact at `path` carries, opened from a copy.
local function carried(path: string): Sqlite.Handle
  local parts = assert(artifact.split((assert(Fs.read(path)))))
  assert(Fs.write(path .. ".db", parts.database))
  return (assert(Sqlite.open(path .. ".db")))
end

local function rows(db: Sqlite.Handle, sql: string): Sqlite.Rows
  return (assert(Sqlite.text_rows(db, sql)))
end

--- The roots the artifact at `path` carries, as a PEM bundle of their
--- labels and certificates, in its order.
local function carried_pem(path: string): string
  local db = carried(path)
  local found = assert(Sqlite.rows(db, "SELECT label, der FROM ca_roots ORDER BY rowid"))
  assert(db:close())
  local parts: mut {string} = {}
  for _, row in ipairs(found) do
    local encoded = Codec.base64(row:blob(2))
    parts[#parts + 1] = row:text(1) .. "\n" .. ("="):rep(#row:text(1)) .. "\n-----BEGIN CERTIFICATE-----\n" ..
      encoded:gsub(("."):rep(64), "%0\n"):gsub("\n$", "") .. "\n-----END CERTIFICATE-----\n\n"
  end
  return table.concat(parts)
end

--- A tzdata sdist as PyPI publishes one, `version`'s, holding `files`
--- under its `src/tzdata/`, as a gzipped tar at `path`.
local function sdist(path: string, version: string, files: {string:string})
  local out = Stream.collect()
  local w = Tar.writer(out, { deterministic = true })
  local names: mut {string} = {}
  for name in pairs(files) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    assert(w:add_file(("tzdata-%s/src/tzdata/%s"):format(version, name), files[name]))
  end
  assert(w:close())
  assert(Fs.write(path, (assert(Compress.deflate("gzip", out:result())))))
end

--- Every vendored zone, by its path under the sdist's `src/tzdata/`.
local function vendored_zones(): mut {string:string}
  local files: mut {string:string} = {}
  for _, name in ipairs((assert(Fs.walk_following(zones)))) do
    files["zoneinfo/" .. name] = assert(Fs.read(zones .. "/" .. name))
  end
  return files
end

--- The very bundle the binary was built from, refreshed in, makes the
--- binary it was: the same parse, the same rows in the same order,
--- the same release recorded, the same vacuumed bytes.
local function test_the_carried_bundle_makes_the_same_binary(tmp: string)
  local path = program(tmp)
  local out = tmp .. "/refreshed"
  local lines = assert(refresh.binary(path, out, { datasets.cacert }, { cacert = bundle }))
  assert(lines[1]:find("(as it was)", 1, true), lines[1])
  assert(Fs.read(out) == Fs.read(path), "a refresh to the carried release changed the binary")
end

--- A different bundle replaces the roots, records the release it came
--- from, and leaves a program that still runs.
local function test_a_new_bundle_replaces_the_roots(tmp: string)
  local path = program(tmp)
  local text = assert(Fs.read(bundle))
  -- The root store less one root: its last server trust made one that
  -- only says to verify, as Mozilla's is for a root it no longer trusts.
  local trusted <const> = "\nCKA_TRUST_SERVER_AUTH CK_TRUST CKT_NSS_TRUSTED_DELEGATOR\n"
  local last = 0
  local from = 1
  while true do
    local at = text:find(trusted, from, true)
    if at == nil then break end
    last, from = at, at + 1
  end
  assert(last > 0, "the root store trusts a root")
  local smaller = text:sub(1, last - 1) .. "\nCKA_TRUST_SERVER_AUTH CK_TRUST CKT_NSS_MUST_VERIFY_TRUST\n" ..
    text:sub(last + #trusted)
  local file = tmp .. "/smaller.txt"
  assert(Fs.write(file, smaller))
  local before = carried(path)
  local count = math.tointeger(tonumber(rows(before, "SELECT count(*) FROM ca_roots")[1]:text(1)))
  assert(before:close())

  local out = tmp .. "/refreshed"
  assert(refresh.binary(path, out, { datasets.cacert }, { cacert = file }))
  local after = carried(out)
  assert(rows(after, "SELECT count(*) FROM ca_roots")[1]:text(1) == tostring(count - 1))
  local component = rows(after, "SELECT version, url, sha256 FROM components WHERE name = 'cacert'")[1]
  -- certdata.txt names no version of its own.
  assert(component:text(1) == "sha256:" .. Hash.hex_sha256(smaller):sub(1, 12), component:text(1))
  assert(component:text(2) == "file:smaller.txt", component:text(2))
  assert(component:text(3) == Hash.hex_sha256(smaller), component:text(3))
  assert(after:close())

  local ran = assert(Child.run({ out }, { stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(ran.ok and ran.stdout == "ok\n", tostring(ran.stderr))
end

--- An sdist of the vendored zones makes the table a boot made of them,
--- row for row, and records the sdist's version; what the PIN drops
--- stays out.
local function test_a_tzdata_sdist_replaces_the_zones(tmp: string)
  local path = program(tmp)
  local files = vendored_zones()
  files["zoneinfo/__init__.py"] = ""
  files["zoneinfo/tzdata.zi"] = "# version 2099a\n"
  files["zoneinfo/zone1970.tab"] = "# tab\n"
  files["__init__.py"] = ""
  local archive = tmp .. "/tzdata-2099.1.tar.gz"
  sdist(archive, "2099.1", files)

  local out = tmp .. "/refreshed"
  local lines = assert(refresh.binary(path, out, { datasets.tzdata }, { tzdata = archive }))
  assert(lines[1]:find("-> 2099.1", 1, true), lines[1])
  local before = carried(path)
  local after = carried(out)
  local query = "SELECT rowid, name, hex(sha256(data)) FROM zoneinfo ORDER BY rowid"
  local was, now = rows(before, query), rows(after, query)
  assert(#now == #was, #now .. " zones, not " .. #was)
  for i, row in ipairs(was) do
    assert(now[i]:text(1) == row:text(1) and now[i]:text(2) == row:text(2) and now[i]:text(3) == row:text(3), row:text(2))
  end
  local component = rows(after, "SELECT version, sha256 FROM components WHERE name = 'tzdata'")[1]
  assert(component:text(1) == "2099.1", component:text(1))
  assert(component:text(2) == Hash.hex_sha256((assert(Fs.read(archive)))), component:text(2))
  assert(before:close())
  assert(after:close())
end

--- A release with one row that does not check out writes nothing.
local function test_a_bad_release_writes_nothing(tmp: string)
  local path = program(tmp)
  local archive = tmp .. "/tzdata.tar.gz"
  sdist(archive, "2099.1", { ["zoneinfo/Bad/Zone"] = "TZif not really" })
  local out = tmp .. "/refreshed"
  local lines, trouble = refresh.binary(path, out, { datasets.tzdata }, { tzdata = archive })
  assert(lines == nil and trouble:find("zone Bad/Zone", 1, true) ~= nil, trouble)

  -- A DER sequence, `30 03 'abc'`, that is no certificate: a binary
  -- carrying only it would trust nothing.
  local pem = tmp .. "/bad.pem"
  assert(Fs.write(pem, "Bad\n===\n-----BEGIN CERTIFICATE-----\nMANhYmM=\n-----END CERTIFICATE-----\n"))
  lines, trouble = refresh.binary(path, out, { datasets.cacert }, { cacert = pem })
  assert(lines == nil and trouble:find("certificate 1 (Bad)", 1, true) ~= nil, trouble)
  assert(Fs.exists(out) ~= true)

  -- Among roots it can read, it is left out, as the binary would drop
  -- it, and named.
  local mixed = tmp .. "/mixed.pem"
  assert(Fs.write(mixed, (assert(Fs.read(pem))) .. carried_pem(path)))
  lines, trouble = refresh.binary(path, out, { datasets.cacert }, { cacert = mixed })
  assert(lines ~= nil, trouble)
  assert(lines[1]:find("left out certificate 1 (Bad)", 1, true), lines[1])
  local after = carried(out)
  local want = carried(path)
  local query = "SELECT hex(sha256), label FROM ca_roots ORDER BY rowid"
  local now, was = rows(after, query), rows(want, query)
  assert(#now == #was, #now .. " roots, not " .. #was)
  assert(after:close())
  assert(want:close())
  assert(Fs.remove(out))
  assert(Fs.exists(out) ~= true)
end

--- The command line: -o is required, and a dataset it does not know is
--- refused; -o naming the binary itself writes nothing.
local function test_the_command_line_is_refused_by_name(tmp: string)
  local path = program(tmp)
  local pem = assert(Fs.absolute(bundle))
  local cases: {{string}} = {
    { "refresh", "--binary", path, "--cacert", pem },
    { "refresh", "-o", tmp .. "/out", "--binary", path, "nosuch" },
  }
  for _, words in ipairs(cases) do
    local result = invoke.run(words, { cwd = tmp })
    assert(result.code == 2, table.concat(words, " ") .. ": exit " .. result.code)
  end
  -- Not a usage error, but never done: the binary it reads is not written.
  local itself = invoke.run({ "refresh", "-o", path, "--binary", path, "--cacert", pem }, { cwd = tmp })
  assert(itself.code == 1 and itself.stderr:find("never written", 1, true) ~= nil, itself.stderr)
  assert(not itself.stderr:find("\nrefresh: ", 1, true), "a failure was summarized: " .. itself.stderr)
  local result = invoke.run({ "refresh", "-o", tmp .. "/out", "--binary", path, "--cacert", pem },
    { cwd = tmp })
  assert(result.code == 0, result.stderr)
  assert(Fs.read(tmp .. "/out") == Fs.read(path))
end

--- What someone whose data went stale would ask `cosmic docs` finds
--- the verb.
local function test_docs_finds_refresh_by_what_it_is_for(tmp: string)
  for _, words in ipairs({ "update certificates", "refresh revoked certificates", "time zone database out of date" }) do
    local result = invoke.run({ "docs", words }, { cwd = tmp })
    assert(result.stdout:find("Cli.refresh", 1, true), words .. ":\n" .. result.stdout)
  end
end

--- Let's Encrypt's intermediate R11, which ISRG Root X1 issued with a
--- notBefore of 2024-03-13 (https://letsencrypt.org/certs/2024/r11.der).
local R11 <const> = "30820506308202eea0030201020211008a7d3e13d62f30ef2386bd29076b34f8300d06092a864886f70d01010b0500304f31" ..
  "0b300906035504061302555331293027060355040a1320496e7465726e657420536563757269747920526573656172636820" ..
  "47726f7570311530130603550403130c4953524720526f6f74205831301e170d3234303331333030303030305a170d323730" ..
  "3331323233353935395a3033310b300906035504061302555331163014060355040a130d4c6574277320456e637279707431" ..
  "0c300a0603550403130352313130820122300d06092a864886f70d01010105000382010f003082010a0282010100ba87bc5c" ..
  "1b0039cbca0acdd46710f9013ca54ea561cb26ca52fb1501b7b928f5281eed27b324183967090c08ece03ab03b770ebdf3e5" ..
  "3954410c4eae41d69974de51dbef7bff58bda8b713f6de31d5f272c9726a0b8374959c4600641499f3b1d922d9cda892aa1c" ..
  "267a3ffeef58057b089581db710f8efbe33109bb09be504d5f8f91763d5a9d9e83f2e9c466b3e106664348188065a037189a" ..
  "9b843297b1b2bdc4f815009d2788fbe26317966c9b27674bc4db285e69c279f0495ce02450e1c4bca105ac7b406d00b4c241" ..
  "3fa758b82fc55c9ba5bb099ef1feebb08539fda80aef45c478eb652ac2cf5f3cdee35c4d1bf70b272baa0b4277534f796a1d" ..
  "87d90203010001a381f83081f5300e0603551d0f0101ff040403020186301d0603551d250416301406082b06010505070302" ..
  "06082b0601050507030130120603551d130101ff040830060101ff020100301d0603551d0e04160414c5cf46a4eaf4c3c07a" ..
  "6c95c42db05e922f26e3b9301f0603551d2304183016801479b459e67bb6e5e40173800888c81a58f6e99b6e303206082b06" ..
  "01050507010104263024302206082b060105050730028616687474703a2f2f78312e692e6c656e63722e6f72672f30130603" ..
  "551d20040c300a3008060667810c01020130270603551d1f0420301e301ca01aa0188616687474703a2f2f78312e632e6c65" ..
  "6e63722e6f72672f300d06092a864886f70d01010b050003820201004ee2895d0a031c9038d0f51ff9715cf8c38fb237887a" ..
  "6fb0251fedbeb7d886068ee90984cd72bf81f3fccacf5348edbdf66942d4a5113e35c813b2921d055fea2ed4d8f849c3adf5" ..
  "99969cef26d8e1b4240b48204dfcd354b4a9c621c8e1361bff77642917b9f04bef5deacd79d0bf90bfbe23b290da4aa94831" ..
  "74a9440be1e2f62d8371a4757bd294c10519461cb98ff3c47448252a0de5f5db43e2db939bb919b41f2fdf6a0e8f31d3630f" ..
  "bb29dcdd662c3fb01b6751f8413ce44db9acb8a49c6663f5ab85231dcc53b6ab71aedcc50171da36ee0a182a32fd09317c8f" ..
  "f673e79c9cb54a156a77825acfda8d45fe1f2a6405303e73c2c60cb9d63b634aab4603fe99c04640276063df503a0747d815" ..
  "4a9fea471f995a08620cb66c33084dd738ed482d2e0568ae805def4cdcd820415f68f1bb5acde30eb00c31879b43de4943e1" ..
  "c8043fd13c1b87453069a8a9720e79121c31d83e2357dda74fa0f01c81d1771f6fd6d2b9a8b3031681394b9f55aed26ae4b3" ..
  "bfeaa5d59f4ba3c9d63b72f34af654ab0cfc38f76080df6e35ca75a154e42fbc6e17c91aa537b5a29abaecf4c075464f77a8" ..
  "e8595691662d6ede2981d6a697055e6445be2cceea644244b0c34fadf0b4dc03ca999b098295820d638a66f91972f8d5b989" ..
  "10e289980935f9a21cbe92732374e99d1fd73b4a9a845810c2f3a7e235ec7e3b45ce3046526bc0c0"

--- A program, under `tmp`, that opens https once for each of `ders`, over
--- a script whose server presents that certificate as far as a canned
--- first flight takes a handshake, and prints why each open failed, a
--- line each: the chain trusted makes it a name that does not match,
--- refused something else.
local function presenter(tmp: string, ders: {string}): string
  local hexes: mut {string} = {}
  for i, der in ipairs(ders) do
    hexes[i] = '"' .. Codec.hex(der) .. '"'
  end
  local tree = tmp .. "/presenter"
  assert(Fs.mkdirs(tree .. "/cmd/present"))
  assert(Fs.write(tree .. "/cmd/present/main.tl", ([[
local Codec = require("cosmic.codec")
local Http = require("cosmic.http")

local function message(kind: integer, body: string): string
  return string.char(kind) .. string.pack(">I3", #body) .. body
end

return function(): integer
  for _, hex in ipairs({ %s }) do
    local der = (assert(Codec.unhex(hex)))
    local hello = message(2, "\3\3" .. string.rep("B", 32) .. "\0" .. "\192\47" .. "\0")
    local certificate = message(11, string.pack(">I3", #der + 3) .. string.pack(">I3", #der) .. der)
    local records = hello .. certificate
    local flight = "\22\3\3" .. string.pack(">I2", #records) .. records
    local _, why = Http.open("https://cosmic.test/", { script = { flight } })
    print((why:gsub("\n", " ")))
  end
  return 0
end
]]):format(table.concat(hexes, ", "))))
  assert(embed.tree(tree, true))
  return build_dir(tree) .. "/bin/present"
end

--- What the program at `path` printed, a line each.
local function presented(path: string): {string}
  local ran = assert(Child.run({ path }, { stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) }))
  assert(ran.ok, tostring(ran.stderr))
  local lines: mut {string} = {}
  local stdout = assert(ran.stdout)
  for line in stdout:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

--- Whether `line`, what [`presenter`]'s program printed, says the chain
--- was trusted.
local function trusted(line: string): boolean
  return line:find("Common Name", 1, true) ~= nil and line:find("distrust", 1, true) == nil and
    line:find("not correctly signed", 1, true) == nil
end

--- `text`, NSS's certdata.txt, with ISRG Root X1 trusted for no server
--- certificate issued after 2020-01-01: `200101000000Z`, as certdata.txt
--- writes a UTCTime.
local function isrg_dated(text: string): string
  local isrg = assert(text:find('\n# Certificate "ISRG Root X1"\n', 1, true))
  local undated <const> = "\nCKA_NSS_SERVER_DISTRUST_AFTER CK_BBOOL CK_FALSE\n"
  local at = assert(text:find(undated, isrg, true))
  local dated = "\nCKA_NSS_SERVER_DISTRUST_AFTER MULTILINE_OCTAL\n" ..
    "\\062\\060\\060\\061\\060\\061\\060\\060\\060\\060\\060\\060\\132\nEND\n"
  return text:sub(1, at - 1) .. dated .. text:sub(at + #undated)
end

--- A root Mozilla trusts for no server certificate issued after a date
--- refuses one issued after it, as the binary verifies a chain
--- (core/http.c's `cosmic_tls_distrust`), naming the root and the date,
--- and still trusts one issued before it. ISRG Root X1, dated 2020:
--- R11 (2024), which it issued, is refused; the root itself (2015),
--- presented as the server's certificate, is not. Undated, the program
--- trusts both.
local function test_a_root_s_distrust_date_refuses_what_it_issued_after(tmp: string)
  local file = tmp .. "/dated.txt"
  assert(Fs.write(file, isrg_dated((assert(Fs.read(bundle))))))
  local db = carried(program(tmp))
  local isrg = assert(assert(Sqlite.rows(db, "SELECT der FROM ca_roots WHERE label = 'ISRG Root X1'"))[1]):blob(1)
  assert(db:close())
  local path = presenter(tmp, { isrg, (assert(Codec.unhex(R11))) })
  local before = presented(path)
  assert(#before == 2 and trusted(assert(before[1])) and trusted(assert(before[2])), table.concat(before, "\n"))

  local out = tmp .. "/refreshed"
  assert(refresh.binary(path, out, { assert(datasets["cacert"]) }, { cacert = file }))
  local after = presented(out)
  assert(#after == 2, table.concat(after, "\n"))
  local root, issued = assert(after[1]), assert(after[2])
  assert(trusted(root), root)
  assert(issued:find('the CA root "ISRG Root X1" is trusted for no server certificate issued after ' ..
      "20200101000000 UTC", 1, true) ~= nil, issued)
end

--- A binary built before `ca_roots` held distrust dates is refreshed
--- all the same: the column is added, and its rows hold the dates.
local function test_a_binary_from_before_distrust_dates_is_refreshed(tmp: string)
  local path = program(tmp)
  local parts = assert(artifact.split((assert(Fs.read(path)))))
  local copy = tmp .. "/old.db"
  assert(Fs.write(copy, parts.database))
  local db = assert(Sqlite.open(copy, { writable = true }))
  assert(db:exec("ALTER TABLE ca_roots DROP COLUMN distrust_after; VACUUM"))
  assert(db:close())
  local old = tmp .. "/old"
  assert(Fs.write(old, (assert(artifact.rejoin(parts, (assert(Fs.read(copy))))))))

  local file = tmp .. "/dated.txt"
  assert(Fs.write(file, isrg_dated((assert(Fs.read(bundle))))))
  local out = tmp .. "/refreshed"
  assert(refresh.binary(old, out, { assert(datasets["cacert"]) }, { cacert = file }))
  local after = carried(out)
  local dated = rows(after, "SELECT label FROM ca_roots WHERE distrust_after = '20200101000000'")
  assert(#dated == 1 and assert(dated[1]):text(1) == "ISRG Root X1")
  assert(after:close())
end

--- A OneCRL changeset revoking R11 by `change`, a JSON object's text.
local function revoking(change: string): string
  return '{"metadata":{},"timestamp":1792622041776,"changes":[' .. change .. ']}'
end

--- A certificate OneCRL revokes is refused wherever it sits in a chain,
--- by its issuer and serial number or by its subject and key, naming it,
--- while the chain's root alone is still trusted: here Let's Encrypt's
--- R11 under ISRG Root X1, which the unrefreshed program trusts.
local function test_a_certificate_onecrl_revokes_is_refused(tmp: string)
  local db = carried(program(tmp))
  local isrg = assert(assert(Sqlite.rows(db, "SELECT der FROM ca_roots WHERE label = 'ISRG Root X1'"))[1]):blob(1)
  assert(db:close())
  local path = presenter(tmp, { isrg, (assert(Codec.unhex(R11))) })
  local before = presented(path)
  assert(#before == 2 and trusted(assert(before[1])) and trusted(assert(before[2])), table.concat(before, "\n"))
  local changes: {string} = {
    -- R11's issuer, ISRG Root X1's Name, and its serial number.
    '{"issuerName":"ME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBTZWN1cml0eSBSZXNlYXJjaCBHcm91cDEV' ..
      'MBMGA1UEAxMMSVNSRyBSb290IFgx","serialNumber":"AIp9PhPWLzDvI4a9KQdrNPg="}',
    -- R11's subject and the SHA-256 of its key.
    '{"subject":"MDMxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNSMTE=",' ..
      '"pubKeyHash":"bdrBhpj38ffhxpubzkINl0rG+UyossdhcBYj+Zx2fcc="}',
  }
  for i, change in ipairs(changes) do
    local file = tmp .. "/onecrl-" .. tostring(i) .. ".json"
    assert(Fs.write(file, revoking(change)))
    local out = tmp .. "/revoked-" .. tostring(i)
    assert(refresh.binary(path, out, { assert(datasets["onecrl"]) }, { onecrl = file }))
    local after = presented(out)
    assert(#after == 2, table.concat(after, "\n"))
    local root, issued = assert(after[1]), assert(after[2])
    assert(trusted(root), root)
    assert(issued:find("CN=R11", 1, true) ~= nil and issued:find("is revoked by Mozilla's OneCRL", 1, true) ~= nil,
      issued)
  end
end

--- A binary built before cosmic carried OneCRL records no onecrl
--- component, and its core reads none: refreshing every dataset passes it
--- over, saying so, and naming it refuses.
local function test_a_binary_without_onecrl_is_passed_over(tmp: string)
  local path = program(tmp)
  local parts = assert(artifact.split((assert(Fs.read(path)))))
  local copy = tmp .. "/old.db"
  assert(Fs.write(copy, parts.database))
  local db = assert(Sqlite.open(copy, { writable = true }))
  assert(db:exec("DELETE FROM components WHERE name = 'onecrl'; DROP TABLE ca_revoked; VACUUM"))
  assert(db:close())
  local old = tmp .. "/old"
  assert(Fs.write(old, (assert(artifact.rejoin(parts, (assert(Fs.read(copy))))))))
  local file = tmp .. "/onecrl.json"
  assert(Fs.write(file, '{"metadata":{},"timestamp":1,"changes":[]}'))

  local every = assert(refresh.binary(old, tmp .. "/every", { assert(datasets["cacert"]), assert(datasets["onecrl"]) },
    { cacert = bundle, onecrl = file }, true))
  local said = table.concat(every, "\n")
  assert(said:find("onecrl: none: the binary was built before cosmic carried one", 1, true) ~= nil, said)
  local named, why = refresh.binary(old, tmp .. "/named", { assert(datasets["onecrl"]) }, { onecrl = file })
  assert(named == nil and why:find("records no onecrl component", 1, true) ~= nil, tostring(why))
end
