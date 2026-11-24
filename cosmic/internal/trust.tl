--- The CA roots a TLS client trusts, as [`cosmic.http`]'s `opts.roots`
--- and `opts.ca` and [`Tls.client`]'s choose them: from the roots this
--- binary carries (Mozilla's store, with its distrust dates and OneCRL,
--- which core/http.c holds), the certificates `$SSL_CERT_FILE` names,
--- and the caller's own. Both clients read them here, so the two trust
--- the same roots for the same words.

local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")

local http = require("cosmic.internal.http")

--- The roots of `opts.roots = "minimal"`, by the SHA-256 of each root's
--- DER as lower-case hex.
local MINIMAL_ROOTS <const>: {string} = {
  "96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6", -- ISRG Root X1
  "69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470", -- ISRG Root X2
  "cb3ccbb76031e5e0138f8dd39a23f9de47ffc35e43c1144cea27d46a5ab1cb5f", -- DigiCert Global Root G2
  "31ad6648f8104138c738f39ea4320133393e3a18cc02296ef97c2ac9ef6731d0", -- DigiCert Global Root G3
  "018e13f0772532cf809bd1b17281867283fc48c6e13be9c69812854a490c1b05", -- DigiCert TLS ECC P384 Root G5
  "371a00dc0533b3721a7eeb40e8419e70799d2b0a0f2c1d80693165f7cec4ad75", -- DigiCert TLS RSA4096 Root G5
  "e793c9b02fd8aa13e21c31228accb08119643b749c898964b1746d46c3d4cbd2", -- USERTrust RSA Certification Authority
  "4ff460d54b9c86dabfbcfc5712e0400d2bed3fbc4d4fbdaa86e06adcd2a9ad7a", -- USERTrust ECC Certification Authority
  "7bb647a62aeeac88bf257aa522d01ffea395e0ab45c73f93f65654ec38f25a06", -- Sectigo Public Server Authentication Root R46
  "c90f26f0fb1b4018b22227519b5ca2b53e2ca5b3be5cf18efe1bef47380c5383", -- Sectigo Public Server Authentication Root E46
  "cbb522d7b7f127ad6a0113865bdf1cd4102e7d0759af635a7cf4720dc963c53b", -- GlobalSign Root CA - R3
  "2cabeafe37d06ca22aba7391c0033d25982952c453647349763a3ab5ad6ccf69", -- GlobalSign Root CA - R6
  "4fa3126d8d3a11d1c4855a4f807cbad6cf919d3a5a88b03bea2c6372d93c40c9", -- GlobalSign Root R46
  "cbb9c44d84b8043e1050ea31a69f514955d7bfd2e2c6b49301019ad61d9f5058", -- GlobalSign Root E46
  "b085d70b964f191a73e4af0d54ae7a0e07aafdaf9b71dd0862138ab7325a24a2", -- GlobalSign ECC Root CA - R4
  "179fbc148a3dd00fd24ea13458cc43bfa7f59c8182d783a513f6ebec100c8924", -- GlobalSign ECC Root CA - R5
  "d947432abde7b7fa90fc2e6b59101b1280e0e1c7e4e40fa3c6887fff57a7f4cf", -- GTS Root R1
  "34d8a73ee208d9bcdb0d956520934b4e40e69482596e8b6f73c8426b010a6f48", -- GTS Root R3
  "349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d", -- GTS Root R4
  "8ecde6884f3d87b1125ba31ac3fcb13d7016de7f57cc904fe1cb97c6ae98196e", -- Amazon Root CA 1
  "1ba5b2aa8c65401a82960118f80bec4f62304d83cec4713a19c39c011ea46db4", -- Amazon Root CA 2
  "18ce6cfe7bf14e60b2e347b8dfe868cb31d02ebb3ada271569f50343b46db3a4", -- Amazon Root CA 3
  "e35d28419ed02025cfa69038cd623962458da5c695fbdea3c22b0bfb25897092", -- Amazon Root CA 4
  "568d6905a2c88708a4b3025190edcfedb1974a606a13c6e5290fcb2ae63edab5", -- Starfield Services Root Certificate Authority - G2
  "c741f70f4b2a8d88bf2e71c14122ef53ef10eba0cfa5e64cfa20f418853073e0", -- Microsoft RSA Root Certificate Authority 2017
  "358df39d764af9e1b766e9c972df352ee15cfac227af6ad1d70e8e4a6edcba02", -- Microsoft ECC Root Certificate Authority 2017
}

--- What `roots` and `ca` choose to trust, for [`Trust.pem`] to give
--- the TLS stack.
local record Chosen
  --- The roots' name ("minimal", "none", "mozilla"), and a NUL and `ca`
  --- when one is given: what names the blob every request with these
  --- makes. Nil for a list of digests, whose blob is the request's own.
  key: string?
  --- Every carried root, rather than only those `wanted` names.
  all: boolean
  --- Carried roots by the SHA-256 of their DER.
  wanted: {string:boolean}
  --- Whether the certificates $SSL_CERT_FILE names are trusted too.
  extra: boolean
  ca: string?
end

--- What each request would otherwise work out again, kept for the
--- program's life.
local record Kept
  --- What `cosmic build --roots` recorded in this executable ("" for
  --- nothing): the store does not change under a running program.
  mut recorded?: string
  --- The roots of "minimal" as [`Chosen`]'s `wanted`; no caller writes to it.
  mut minimal?: {string:boolean}
end
local kept: Kept = { recorded = nil, minimal = nil }

--- What `cosmic build --roots` recorded in this executable, or "".
local function recorded_roots(): string
  local held = kept.recorded
  if held == nil then
    held = Store.meta("ca_roots_default") or ""
    kept.recorded = held
  end
  return held
end

--- The roots of "minimal", by the SHA-256 of each one's DER, decoded once.
local function minimal_wanted(): {string:boolean}
  local held = kept.minimal
  if held ~= nil then return held end
  local made: mut {string:boolean} = {}
  for _, hex in ipairs(MINIMAL_ROOTS) do
    made[assert(Codec.unhex(hex))] = true
  end
  kept.minimal = made
  return made
end

--- The roots a caller that names none trusts, "minimal" or "mozilla",
--- and "": `COSMIC_CA_ROOTS` when it is set, else what `cosmic build
--- --roots` recorded in this executable, else "minimal". Nil and why
--- when either names anything else, worded for `who`.
local function default_roots(who: string): string?, string
  local chosen = Env.read("COSMIC_CA_ROOTS") or ""
  local from = "COSMIC_CA_ROOTS"
  if chosen == "" then
    chosen = recorded_roots()
    from = "this executable's `cosmic build --roots`"
  end
  if chosen == "" then
    return "minimal", ""
  end
  if chosen ~= "minimal" and chosen ~= "mozilla" then
    return nil, ("%s: %s names %q, not minimal or mozilla"):format(who, from, chosen:sub(1, 40))
  end
  return chosen, ""
end

--- `roots` and `ca` as a [`Chosen`], or nil when they leave the trust
--- store core/http.c holds (every carried root) as it is; and "", or
--- why the roots a caller naming none trusts cannot be told
--- ([`default_roots`]). Raises at `level` for either of the wrong
--- shape, naming it as `who`'s `opts.roots` or `opts.ca`.
local function chosen_of(roots: (string | {string})?, ca: string?, who: string, level: integer): Chosen?, string
  if ca ~= nil and type(ca) ~= "string" then
    error(who .. ": opts.ca must be a string", level)
  end
  if roots == nil then
    local default, why = default_roots(who)
    if default == nil then
      return nil, why
    end
    roots = default
  end
  if roots == "mozilla" then
    if ca == nil then return nil, "" end
    return { key = "mozilla\0" .. ca, all = true, wanted = {}, extra = true, ca = ca }, ""
  elseif roots == "minimal" then
    local key = "minimal"
    if ca ~= nil then key = "minimal\0" .. ca end
    return { key = key, all = false, wanted = minimal_wanted(), extra = true, ca = ca }, ""
  elseif roots == "none" then
    local key = "none"
    if ca ~= nil then key = "none\0" .. ca end
    return { key = key, all = false, wanted = {}, extra = false, ca = ca }, ""
  elseif type(roots) == "table" then
    local wanted: mut {string:boolean} = {}
    for i, hex in ipairs(roots) do
      local digest = ""
      if type(hex) == "string" then
        digest = (hex:gsub(":", ""))
      end
      local bytes, _ = Codec.unhex(digest)
      if #digest ~= 64 or bytes == nil then
        error(("%s: opts.roots[%d] must be a root's SHA-256, as 64 hex digits"):format(who, i), level)
      end
      wanted[bytes] = true
    end
    return { key = nil, all = false, wanted = wanted, extra = true, ca = ca }, ""
  end
  error(who .. ': opts.roots must be "minimal", "mozilla", "none" or a list of SHA-256 digests', level)
end

--- `der` as PEM.
local function pem(der: string): string
  local encoded = Codec.base64(der)
  local lines: mut {string} = { "-----BEGIN CERTIFICATE-----" }
  for at = 1, #encoded, 64 do
    lines[#lines + 1] = encoded:sub(at, at + 63)
  end
  lines[#lines + 1] = "-----END CERTIFICATE-----\n"
  return table.concat(lines, "\n")
end

local BEGIN <const> = "%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-"
local END <const> = "%-%-%-%-%-END CERTIFICATE%-%-%-%-%-"

--- The certificates `text` holds, as DER: each PEM block, or `text`
--- itself when it holds none and is one DER certificate. Nil and why
--- when one is not closed, not base64, or not a certificate the TLS
--- stack reads.
local function certificates(text: string): {string}?, string
  if not text:find("-----BEGIN", 1, true) then
    local ok, why = http.check_certificate(text)
    if not ok then return nil, why end
    return { text }, ""
  end
  local _, begun = text:gsub(BEGIN, "")
  local ders: mut {string} = {}
  for body in text:gmatch(BEGIN .. "(.-)" .. END) do
    local der, why = Codec.unbase64((body:gsub("%s", "")))
    if der == nil then
      return nil, ("certificate %d is not base64: %s"):format(#ders + 1, why)
    end
    local ok, unread = http.check_certificate(der)
    if not ok then
      return nil, ("certificate %d: %s"):format(#ders + 1, unread)
    end
    ders[#ders + 1] = der
  end
  if #ders == 0 then
    return nil, "holds no certificate"
  end
  if #ders ~= begun then
    return nil, ("certificate %d is not closed"):format(#ders + 1)
  end
  return ders, ""
end

--- One carried root, under the SHA-256 of its DER.
local record Carried
  der: string
  digest: string
end

--- The trust store's certificates, read once: the carried roots with
--- their digests, and those $SSL_CERT_FILE named.
local record Held
  mut carried: {Carried}?
  mut extra: {string}
  --- The blob of each [`Chosen`] with a `key`, by it, made once, until
  --- `BLOBS_MOST` of them drop them all.
  mut blobs: mut {string:string}
  --- How many `blobs` holds, at most `BLOBS_MOST`: a program that trusts
  --- a new `ca` per request holds no more than that.
  mut counted: integer
end
local BLOBS_MOST <const> = 32
local store: Held = { carried = nil, extra = {}, blobs = {}, counted = 0 }

--- The carried roots with their digests, read from the trust store
--- the first time, or nil and why when it cannot be made.
local function carried_roots(): {Carried}?, string
  local held = store.carried
  if held ~= nil then
    return held, ""
  end
  local roots, trouble = http.roots()
  if roots == nil then
    return nil, trouble
  end
  local read: mut {Carried} = {}
  for _, der in ipairs(roots.carried) do
    read[#read + 1] = { der = der, digest = Hash.sha256(der) }
  end
  store.carried = read
  store.extra = roots.extra
  return read, ""
end

--- The PEM of every certificate `trust` names, or nil and why, worded
--- for `who`: when the trust store cannot be made, `trust.ca` holds
--- what the TLS stack cannot read, or nothing is left to trust.
local function trusted(trust: Chosen, who: string): string?, string
  local key = trust.key
  if key ~= nil then
    local made = store.blobs[key]
    if made ~= nil then
      return made, ""
    end
  end
  local pems: mut {string} = {}
  -- A trust of `ca` alone reads nothing of the store, so a binary that
  -- carries no roots still trusts a private CA.
  if trust.all or trust.extra or next(trust.wanted) ~= nil then
    local carried, trouble = carried_roots()
    if carried == nil then
      return nil, trouble
    end
    for _, root in ipairs(carried) do
      if trust.all or trust.wanted[root.digest] == true then
        pems[#pems + 1] = pem(root.der)
      end
    end
    if trust.extra then
      for _, der in ipairs(store.extra) do
        pems[#pems + 1] = pem(der)
      end
    end
  end
  local ca = trust.ca
  if ca ~= nil then
    local ders, why = certificates(ca)
    if ders == nil then
      return nil, who .. ": opts.ca: " .. why
    end
    for _, der in ipairs(ders) do
      pems[#pems + 1] = pem(der)
    end
  end
  if #pems == 0 then
    return nil, who .. ": no CA roots to trust: opts.roots names none this binary carries, and opts.ca none"
  end
  local blob = table.concat(pems)
  if key ~= nil then
    if store.counted >= BLOBS_MOST then store.blobs, store.counted = {}, 0 end
    store.blobs[key] = blob
    store.counted = store.counted + 1
  end
  return blob, ""
end

local record Trust
  --- What `roots` and `ca` choose: see [`Chosen`].
  type Chosen = Chosen
end

--- The roots of "minimal", by the SHA-256 of each root's DER as
--- lower-case hex, in a list of the caller's own.
function Trust.minimal_roots(): {string}
  return { table.unpack(MINIMAL_ROOTS) }
end

--- The roots a caller that names none trusts: see [`default_roots`].
function Trust.default_roots(who: string): string?, string
  return default_roots(who)
end

--- `roots` and `ca` as a [`Chosen`]: see [`chosen_of`]. `level` is
--- where to raise as the caller of this would give it to `error`.
function Trust.chosen(roots: (string | {string})?, ca: string?, who: string, level: integer): Chosen?, string
  -- A tail call: this frame is gone when `error` counts, so the caller
  -- is one level up from chosen_of.
  return chosen_of(roots, ca, who, level + 1)
end

--- Every carried root, the certificates `$SSL_CERT_FILE` names, and
--- `ca`: what a [`Chosen`] of nil leaves the trust store to mean.
function Trust.everything(ca?: string): Chosen
  return { key = if ca == nil then "mozilla" else "mozilla\0" .. ca end, all = true, wanted = {}, extra = true, ca = ca }
end

--- The PEM of every certificate `chosen` names: see [`trusted`].
function Trust.pem(chosen: Chosen, who: string): string?, string
  return trusted(chosen, who)
end

return Trust
