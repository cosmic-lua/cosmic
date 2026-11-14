local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Plist = require("cosmic.plist")

--- What `plistlib` writes before an XML property list's value, and after it.
local XML_HEAD <const> = '<?xml version="1.0" encoding="UTF-8"?>\n' ..
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' ..
  '<plist version="1.0">\n'
local XML_TAIL <const> = "</plist>\n"

--- A value and what Python 3.13's `plistlib` writes for it with `sort_keys=False`.
local record Case
  name: string
  value: Plist.Value
  --- The binary form, in hexadecimal.
  binary?: string
  --- The XML form, between `XML_HEAD` and `XML_TAIL`. Absent where `plistlib` does not write the value to
  --- XML (a UID) or XML does not hold it (a date's fraction).
  xml?: string
end

local CASES <const>: {Case} = {
  {
    name = "booleans",
    value = Plist.array({ Plist.boolean(true), Plist.boolean(false) }),
    binary = "62706c6973743030a201020908080b0c000000000000010100000000000000030000000000000000000000000000000d",
    xml = "<array>\n" ..
      "\t<true/>\n" ..
      "\t<false/>\n" ..
      "</array>\n",
  },
  {
    name = "integers at each width",
    value = Plist.array({
      Plist.integer(0),
      Plist.integer(1),
      Plist.integer(255),
      Plist.integer(256),
      Plist.integer(65535),
      Plist.integer(65536),
      Plist.integer(4294967295),
      Plist.integer(4294967296),
      Plist.integer(9223372036854775807),
      Plist.integer(-1),
      Plist.integer(-255),
      Plist.integer(math.mininteger),
      Plist.integer(math.mininteger, true),
      Plist.integer(-1, true),
    }),
    binary = "62706c6973743030ae0102030405060708090a0b0c0d0e1000100110ff11010011ffff120001000012ffffffff130000" ..
      "000100000000137fffffffffffffff13ffffffffffffffff13ffffffffffffff01138000000000000000140000000000" ..
      "0000008000000000000000140000000000000000ffffffffffffffff0817191b1d2023282d363f48515a6b0000000000" ..
      "000101000000000000000f0000000000000000000000000000007c",
    xml = "<array>\n" ..
      "\t<integer>0</integer>\n" ..
      "\t<integer>1</integer>\n" ..
      "\t<integer>255</integer>\n" ..
      "\t<integer>256</integer>\n" ..
      "\t<integer>65535</integer>\n" ..
      "\t<integer>65536</integer>\n" ..
      "\t<integer>4294967295</integer>\n" ..
      "\t<integer>4294967296</integer>\n" ..
      "\t<integer>9223372036854775807</integer>\n" ..
      "\t<integer>-1</integer>\n" ..
      "\t<integer>-255</integer>\n" ..
      "\t<integer>-9223372036854775808</integer>\n" ..
      "\t<integer>9223372036854775808</integer>\n" ..
      "\t<integer>18446744073709551615</integer>\n" ..
      "</array>\n",
  },
  {
    name = "reals",
    value = Plist.array({
      Plist.real(0.0),
      Plist.real(1.0),
      Plist.real(-1.5),
      Plist.real(0.1),
      Plist.real(1e+100),
      Plist.real(1.5e-05),
      Plist.real(0.0001),
      Plist.real(1e-05),
      Plist.real(1000000000000000.0),
      Plist.real(1e+16),
      Plist.real(123456.789),
      Plist.real(5e-324),
      Plist.real(1.7976931348623157e+308),
      Plist.real(2.5e-08),
      Plist.real(1.2345678901234568e+17),
      Plist.real(math.huge),
      Plist.real(-math.huge),
    }),
    binary = "62706c6973743030af10110102030405060708090a0b0c0d0e0f1011230000000000000000233ff000000000000023bf" ..
      "f8000000000000233fb999999999999a2354b249ad2594c37d233eef75104d551d69233f1a36e2eb1c432d233ee4f8b5" ..
      "88e368f123430c6bf526340000234341c37937e080002340fe240c9fbe76c9230000000000000001237fefffffffffff" ..
      "ff233e5ad7f29abcaf4823437b69b4ba630f35237ff000000000000023fff0000000000000081c252e374049525b646d" ..
      "767f88919aa3ac00000000000001010000000000000012000000000000000000000000000000b5",
    xml = "<array>\n" ..
      "\t<real>0.0</real>\n" ..
      "\t<real>1.0</real>\n" ..
      "\t<real>-1.5</real>\n" ..
      "\t<real>0.1</real>\n" ..
      "\t<real>1e+100</real>\n" ..
      "\t<real>1.5e-05</real>\n" ..
      "\t<real>0.0001</real>\n" ..
      "\t<real>1e-05</real>\n" ..
      "\t<real>1000000000000000.0</real>\n" ..
      "\t<real>1e+16</real>\n" ..
      "\t<real>123456.789</real>\n" ..
      "\t<real>5e-324</real>\n" ..
      "\t<real>1.7976931348623157e+308</real>\n" ..
      "\t<real>2.5e-08</real>\n" ..
      "\t<real>1.2345678901234568e+17</real>\n" ..
      "\t<real>inf</real>\n" ..
      "\t<real>-inf</real>\n" ..
      "</array>\n",
  },
  {
    name = "a real that is not a number",
    value = Plist.real((string.unpack(">d", "\x7F\xF8\0\0\0\0\0\0"))),
    binary = "62706c6973743030237ff800000000000008000000000000010100000000000000010000000000000000000000000000" ..
      "0011",
    xml = "<real>nan</real>\n",
  },
  {
    name = "strings",
    value = Plist.array({
      Plist.string(""),
      Plist.string("ascii"),
      Plist.string("fourteen chars"),
      Plist.string("fifteen chars.."),
      Plist.string(("x"):rep(300)),
      Plist.string("h\u{E9}"),
      Plist.string("\u{1F600}"),
      Plist.string("a\tb\nc"),
      Plist.string(" lead and trail "),
      Plist.string("<&>\"' ]]>"),
      Plist.string("\u{65E5}\u{672C}\u{8A9E}"),
      Plist.string("\u{D7FF}\u{E000}\u{FFFD}"),
    }),
    binary = "62706c6973743030ac0102030405060708090a0b0c505561736369695e666f75727465656e2063686172735f100f6669" ..
      "667465656e2063686172732e2e5f11012c78787878787878787878787878787878787878787878787878787878787878" ..
      "787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878" ..
      "787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878" ..
      "787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878" ..
      "787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878" ..
      "787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878" ..
      "787878787878787878787878787878787878787878787878787878787862006800e962d83dde00556109620a635f1010" ..
      "206c65616420616e6420747261696c20593c263e2227205d5d3e6365e5672c8a9e63d7ffe000fffd000800150016001c" ..
      "002b003d016d01720177017d0190019a01a10000000000000201000000000000000d0000000000000000000000000000" ..
      "01a8",
    xml = "<array>\n" ..
      "\t<string></string>\n" ..
      "\t<string>ascii</string>\n" ..
      "\t<string>fourteen chars</string>\n" ..
      "\t<string>fifteen chars..</string>\n" ..
      "\t<string>xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx</string>\n" ..
      "\t<string>h\u{E9}</string>\n" ..
      "\t<string>\u{1F600}</string>\n" ..
      "\t<string>a\tb\n" ..
      "c</string>\n" ..
      "\t<string> lead and trail </string>\n" ..
      "\t<string>&lt;&amp;&gt;\"' ]]&gt;</string>\n" ..
      "\t<string>\u{65E5}\u{672C}\u{8A9E}</string>\n" ..
      "\t<string>\u{D7FF}\u{E000}\u{FFFD}</string>\n" ..
      "</array>\n",
  },
  {
    name = "data",
    value = Plist.array({
      Plist.data(""),
      Plist.data("\x00\xff"),
      Plist.data("fourteen bytes"),
      Plist.data("fifteen bytes.."),
      Plist.data(("\x01"):rep(255)),
      Plist.data(("\x02"):rep(256)),
      Plist.data(("\x03"):rep(100)),
    }),
    binary = "62706c6973743030a701020304050607404200ff4e666f75727465656e2062797465734f100f6669667465656e206279" ..
      "7465732e2e4f10ff01010101010101010101010101010101010101010101010101010101010101010101010101010101" ..
      "010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101" ..
      "010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101" ..
      "010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101" ..
      "010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101" ..
      "01010101010101010101010101010101010101010101014f110100020202020202020202020202020202020202020202" ..
      "020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202" ..
      "020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202" ..
      "020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202" ..
      "020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202020202" ..
      "020202020202020202020202020202020202020202020202020202020202020202020202020202020202024f10640303" ..
      "030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303" ..
      "030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303" ..
      "03030008001000110014002300350137023b000000000000020100000000000000080000000000000000000000000000" ..
      "02a2",
    xml = "<array>\n" ..
      "\t<data>\n" ..
      "\t</data>\n" ..
      "\t<data>\n" ..
      "\tAP8=\n" ..
      "\t</data>\n" ..
      "\t<data>\n" ..
      "\tZm91cnRlZW4gYnl0ZXM=\n" ..
      "\t</data>\n" ..
      "\t<data>\n" ..
      "\tZmlmdGVlbiBieXRlcy4u\n" ..
      "\t</data>\n" ..
      "\t<data>\n" ..
      "\tAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB\n" ..
      "\tAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB\n" ..
      "\tAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB\n" ..
      "\tAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB\n" ..
      "\tAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB\n" ..
      "\t</data>\n" ..
      "\t<data>\n" ..
      "\tAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC\n" ..
      "\tAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC\n" ..
      "\tAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC\n" ..
      "\tAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC\n" ..
      "\tAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC\n" ..
      "\tAg==\n" ..
      "\t</data>\n" ..
      "\t<data>\n" ..
      "\tAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMD\n" ..
      "\tAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAw==\n" ..
      "\t</data>\n" ..
      "</array>\n",
  },
  {
    name = "data nested, whose lines of base64 shorten",
    value = Plist.dict({
      { key = "a", value = Plist.dict({
        { key = "b", value = Plist.dict({
          { key = "c", value = Plist.dict({
            { key = "d", value = Plist.dict({
              { key = "e", value = Plist.dict({
                { key = "f", value = Plist.dict({
                  { key = "g", value = Plist.dict({
                    { key = "h", value = Plist.dict({
                      { key = "i", value = Plist.data(("\x04"):rep(100)) },
                    }) },
                  }) },
                }) },
              }) },
            }) },
          }) },
        }) },
      }) },
    }),
    binary = "62706c6973743030d101025161d103045162d105065163d107085164d1090a5165d10b0c5166d10d0e5167d10f105168" ..
      "d1111251694f106404040404040404040404040404040404040404040404040404040404040404040404040404040404" ..
      "040404040404040404040404040404040404040404040404040404040404040404040404040404040404040404040404" ..
      "040404040404040404040404080b0d101215171a1c1f212426292b2e3033350000000000000101000000000000001300" ..
      "00000000000000000000000000009c",
    xml = "<dict>\n" ..
      "\t<key>a</key>\n" ..
      "\t<dict>\n" ..
      "\t\t<key>b</key>\n" ..
      "\t\t<dict>\n" ..
      "\t\t\t<key>c</key>\n" ..
      "\t\t\t<dict>\n" ..
      "\t\t\t\t<key>d</key>\n" ..
      "\t\t\t\t<dict>\n" ..
      "\t\t\t\t\t<key>e</key>\n" ..
      "\t\t\t\t\t<dict>\n" ..
      "\t\t\t\t\t\t<key>f</key>\n" ..
      "\t\t\t\t\t\t<dict>\n" ..
      "\t\t\t\t\t\t\t<key>g</key>\n" ..
      "\t\t\t\t\t\t\t<dict>\n" ..
      "\t\t\t\t\t\t\t\t<key>h</key>\n" ..
      "\t\t\t\t\t\t\t\t<dict>\n" ..
      "\t\t\t\t\t\t\t\t\t<key>i</key>\n" ..
      "\t\t\t\t\t\t\t\t\t<data>\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBAQEBAQEBAQE\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBAQEBAQEBAQE\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBAQEBAQEBAQE\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBAQEBAQEBAQE\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBAQEBAQEBAQE\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBAQEBAQEBAQE\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBAQEBAQEBAQE\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBAQEBAQEBAQE\n" ..
      "\t\t\t\t\t\t\t\t\tBAQEBA==\n" ..
      "\t\t\t\t\t\t\t\t\t</data>\n" ..
      "\t\t\t\t\t\t\t\t</dict>\n" ..
      "\t\t\t\t\t\t\t</dict>\n" ..
      "\t\t\t\t\t\t</dict>\n" ..
      "\t\t\t\t\t</dict>\n" ..
      "\t\t\t\t</dict>\n" ..
      "\t\t\t</dict>\n" ..
      "\t\t</dict>\n" ..
      "\t</dict>\n" ..
      "</dict>\n",
  },
  {
    name = "dates",
    value = Plist.array({
      Plist.date(978307200),
      Plist.date(0),
      Plist.date(1794659696),
      Plist.date(-62135596800),
      Plist.date(253402300799),
      Plist.date(1709251199),
      Plist.date(-1),
      Plist.date(-2203891200),
    }),
    binary = "62706c6973743030a8010203040506070833000000000000000033c1cd27e4400000003341c854467800000033c22d63" ..
      "c37f00000033424d62d23c7f80003341c5c8a8ff80000033c1cd27e44080000033c1e7b58fd000000008111a232c353e" ..
      "47500000000000000101000000000000000900000000000000000000000000000059",
    xml = "<array>\n" ..
      "\t<date>2001-01-01T00:00:00Z</date>\n" ..
      "\t<date>1970-01-01T00:00:00Z</date>\n" ..
      "\t<date>2026-11-14T12:34:56Z</date>\n" ..
      "\t<date>0001-01-01T00:00:00Z</date>\n" ..
      "\t<date>9999-12-31T23:59:59Z</date>\n" ..
      "\t<date>2024-02-29T23:59:59Z</date>\n" ..
      "\t<date>1969-12-31T23:59:59Z</date>\n" ..
      "\t<date>1900-03-01T00:00:00Z</date>\n" ..
      "</array>\n",
  },
  {
    name = "a date with a fraction",
    value = Plist.array({
      Plist.date(1794659696 + 500000 / 1000000),
      Plist.date(-14182940 + 250000 / 1000000),
    }),
    binary = "62706c6973743030a201023341c854467840000033c1cd94194de00000080b1400000000000001010000000000000003" ..
      "0000000000000000000000000000001d",
  },
  {
    name = "arrays",
    value = Plist.array({
      Plist.array({}),
      Plist.array({ Plist.array({}) }),
      Plist.array({
        Plist.array({ Plist.integer(1) }),
        Plist.array({ Plist.integer(2), Plist.array({ Plist.integer(3) }) }),
      }),
      Plist.array({
        Plist.integer(100),
        Plist.integer(101),
        Plist.integer(102),
        Plist.integer(103),
        Plist.integer(104),
        Plist.integer(105),
        Plist.integer(106),
        Plist.integer(107),
        Plist.integer(108),
        Plist.integer(109),
        Plist.integer(110),
        Plist.integer(111),
        Plist.integer(112),
        Plist.integer(113),
        Plist.integer(114),
      }),
      Plist.array({
        Plist.integer(200),
        Plist.integer(201),
        Plist.integer(202),
        Plist.integer(203),
        Plist.integer(204),
        Plist.integer(205),
        Plist.integer(206),
        Plist.integer(207),
        Plist.integer(208),
        Plist.integer(209),
        Plist.integer(210),
        Plist.integer(211),
        Plist.integer(212),
        Plist.integer(213),
      }),
    }),
    binary = "62706c6973743030a50102040b1ba0a103a0a20507a1061001a208091002a10a1003af100f0c0d0e0f10111213141516" ..
      "1718191a106410651066106710681069106a106b106c106d106e106f107010711072ae1c1d1e1f202122232425262728" ..
      "2910c810c910ca10cb10cc10cd10ce10cf10d010d110d210d310d410d5080e0f11121517191c1e20223436383a3c3e40" ..
      "424446484a4c4e505261636567696b6d6f71737577797b0000000000000101000000000000002a000000000000000000" ..
      "0000000000007d",
    xml = "<array>\n" ..
      "\t<array/>\n" ..
      "\t<array>\n" ..
      "\t\t<array/>\n" ..
      "\t</array>\n" ..
      "\t<array>\n" ..
      "\t\t<array>\n" ..
      "\t\t\t<integer>1</integer>\n" ..
      "\t\t</array>\n" ..
      "\t\t<array>\n" ..
      "\t\t\t<integer>2</integer>\n" ..
      "\t\t\t<array>\n" ..
      "\t\t\t\t<integer>3</integer>\n" ..
      "\t\t\t</array>\n" ..
      "\t\t</array>\n" ..
      "\t</array>\n" ..
      "\t<array>\n" ..
      "\t\t<integer>100</integer>\n" ..
      "\t\t<integer>101</integer>\n" ..
      "\t\t<integer>102</integer>\n" ..
      "\t\t<integer>103</integer>\n" ..
      "\t\t<integer>104</integer>\n" ..
      "\t\t<integer>105</integer>\n" ..
      "\t\t<integer>106</integer>\n" ..
      "\t\t<integer>107</integer>\n" ..
      "\t\t<integer>108</integer>\n" ..
      "\t\t<integer>109</integer>\n" ..
      "\t\t<integer>110</integer>\n" ..
      "\t\t<integer>111</integer>\n" ..
      "\t\t<integer>112</integer>\n" ..
      "\t\t<integer>113</integer>\n" ..
      "\t\t<integer>114</integer>\n" ..
      "\t</array>\n" ..
      "\t<array>\n" ..
      "\t\t<integer>200</integer>\n" ..
      "\t\t<integer>201</integer>\n" ..
      "\t\t<integer>202</integer>\n" ..
      "\t\t<integer>203</integer>\n" ..
      "\t\t<integer>204</integer>\n" ..
      "\t\t<integer>205</integer>\n" ..
      "\t\t<integer>206</integer>\n" ..
      "\t\t<integer>207</integer>\n" ..
      "\t\t<integer>208</integer>\n" ..
      "\t\t<integer>209</integer>\n" ..
      "\t\t<integer>210</integer>\n" ..
      "\t\t<integer>211</integer>\n" ..
      "\t\t<integer>212</integer>\n" ..
      "\t\t<integer>213</integer>\n" ..
      "\t</array>\n" ..
      "</array>\n",
  },
  {
    name = "dicts",
    value = Plist.dict({
      { key = "z", value = Plist.integer(1) },
      { key = "a", value = Plist.dict({}) },
      { key = "m", value = Plist.dict({
        { key = "k", value = Plist.array({
          Plist.dict({
            { key = "deep", value = Plist.boolean(true) },
          }),
        }) },
      }) },
      { key = "", value = Plist.string("empty key") },
      { key = "h\u{E9}", value = Plist.string("h\u{E9}") },
      { key = "k", value = Plist.string("k") },
    }),
    binary = "62706c6973743030d60102030405060708090e0506517a5161516d5062006800e9516b1001d0d1060aa10bd10c0d5464" ..
      "6565700959656d707479206b6579081517191b1c21232526292b2e33340000000000000101000000000000000f000000" ..
      "0000000000000000000000003e",
    xml = "<dict>\n" ..
      "\t<key>z</key>\n" ..
      "\t<integer>1</integer>\n" ..
      "\t<key>a</key>\n" ..
      "\t<dict/>\n" ..
      "\t<key>m</key>\n" ..
      "\t<dict>\n" ..
      "\t\t<key>k</key>\n" ..
      "\t\t<array>\n" ..
      "\t\t\t<dict>\n" ..
      "\t\t\t\t<key>deep</key>\n" ..
      "\t\t\t\t<true/>\n" ..
      "\t\t\t</dict>\n" ..
      "\t\t</array>\n" ..
      "\t</dict>\n" ..
      "\t<key></key>\n" ..
      "\t<string>empty key</string>\n" ..
      "\t<key>h\u{E9}</key>\n" ..
      "\t<string>h\u{E9}</string>\n" ..
      "\t<key>k</key>\n" ..
      "\t<string>k</string>\n" ..
      "</dict>\n",
  },
  {
    name = "scalars written once",
    value = Plist.array({
      Plist.string("a"),
      Plist.string("a"),
      Plist.integer(1),
      Plist.integer(1),
      Plist.boolean(true),
      Plist.integer(1),
      Plist.real(1.0),
      Plist.real(1.0),
      Plist.data("a"),
      Plist.data("a"),
      Plist.date(978307200),
      Plist.date(978307200),
      Plist.boolean(false),
      Plist.boolean(true),
      Plist.string("a"),
      Plist.dict({
        { key = "a", value = Plist.string("a") },
      }),
    }),
    binary = "62706c6973743030af1010010102020302040405050606070301085161100109233ff000000000000041613300000000" ..
      "0000000008d10101081b1d1f20292b343500000000000001010000000000000009000000000000000000000000000000" ..
      "38",
  },
  {
    name = "more objects than one byte numbers",
    value = Plist.array({
      Plist.integer(1000),
      Plist.integer(1001),
      Plist.integer(1002),
      Plist.integer(1003),
      Plist.integer(1004),
      Plist.integer(1005),
      Plist.integer(1006),
      Plist.integer(1007),
      Plist.integer(1008),
      Plist.integer(1009),
      Plist.integer(1010),
      Plist.integer(1011),
      Plist.integer(1012),
      Plist.integer(1013),
      Plist.integer(1014),
      Plist.integer(1015),
      Plist.integer(1016),
      Plist.integer(1017),
      Plist.integer(1018),
      Plist.integer(1019),
      Plist.integer(1020),
      Plist.integer(1021),
      Plist.integer(1022),
      Plist.integer(1023),
      Plist.integer(1024),
      Plist.integer(1025),
      Plist.integer(1026),
      Plist.integer(1027),
      Plist.integer(1028),
      Plist.integer(1029),
      Plist.integer(1030),
      Plist.integer(1031),
      Plist.integer(1032),
      Plist.integer(1033),
      Plist.integer(1034),
      Plist.integer(1035),
      Plist.integer(1036),
      Plist.integer(1037),
      Plist.integer(1038),
      Plist.integer(1039),
      Plist.integer(1040),
      Plist.integer(1041),
      Plist.integer(1042),
      Plist.integer(1043),
      Plist.integer(1044),
      Plist.integer(1045),
      Plist.integer(1046),
      Plist.integer(1047),
      Plist.integer(1048),
      Plist.integer(1049),
      Plist.integer(1050),
      Plist.integer(1051),
      Plist.integer(1052),
      Plist.integer(1053),
      Plist.integer(1054),
      Plist.integer(1055),
      Plist.integer(1056),
      Plist.integer(1057),
      Plist.integer(1058),
      Plist.integer(1059),
      Plist.integer(1060),
      Plist.integer(1061),
      Plist.integer(1062),
      Plist.integer(1063),
      Plist.integer(1064),
      Plist.integer(1065),
      Plist.integer(1066),
      Plist.integer(1067),
      Plist.integer(1068),
      Plist.integer(1069),
      Plist.integer(1070),
      Plist.integer(1071),
      Plist.integer(1072),
      Plist.integer(1073),
      Plist.integer(1074),
      Plist.integer(1075),
      Plist.integer(1076),
      Plist.integer(1077),
      Plist.integer(1078),
      Plist.integer(1079),
      Plist.integer(1080),
      Plist.integer(1081),
      Plist.integer(1082),
      Plist.integer(1083),
      Plist.integer(1084),
      Plist.integer(1085),
      Plist.integer(1086),
      Plist.integer(1087),
      Plist.integer(1088),
      Plist.integer(1089),
      Plist.integer(1090),
      Plist.integer(1091),
      Plist.integer(1092),
      Plist.integer(1093),
      Plist.integer(1094),
      Plist.integer(1095),
      Plist.integer(1096),
      Plist.integer(1097),
      Plist.integer(1098),
      Plist.integer(1099),
      Plist.integer(1100),
      Plist.integer(1101),
      Plist.integer(1102),
      Plist.integer(1103),
      Plist.integer(1104),
      Plist.integer(1105),
      Plist.integer(1106),
      Plist.integer(1107),
      Plist.integer(1108),
      Plist.integer(1109),
      Plist.integer(1110),
      Plist.integer(1111),
      Plist.integer(1112),
      Plist.integer(1113),
      Plist.integer(1114),
      Plist.integer(1115),
      Plist.integer(1116),
      Plist.integer(1117),
      Plist.integer(1118),
      Plist.integer(1119),
      Plist.integer(1120),
      Plist.integer(1121),
      Plist.integer(1122),
      Plist.integer(1123),
      Plist.integer(1124),
      Plist.integer(1125),
      Plist.integer(1126),
      Plist.integer(1127),
      Plist.integer(1128),
      Plist.integer(1129),
      Plist.integer(1130),
      Plist.integer(1131),
      Plist.integer(1132),
      Plist.integer(1133),
      Plist.integer(1134),
      Plist.integer(1135),
      Plist.integer(1136),
      Plist.integer(1137),
      Plist.integer(1138),
      Plist.integer(1139),
      Plist.integer(1140),
      Plist.integer(1141),
      Plist.integer(1142),
      Plist.integer(1143),
      Plist.integer(1144),
      Plist.integer(1145),
      Plist.integer(1146),
      Plist.integer(1147),
      Plist.integer(1148),
      Plist.integer(1149),
      Plist.integer(1150),
      Plist.integer(1151),
      Plist.integer(1152),
      Plist.integer(1153),
      Plist.integer(1154),
      Plist.integer(1155),
      Plist.integer(1156),
      Plist.integer(1157),
      Plist.integer(1158),
      Plist.integer(1159),
      Plist.integer(1160),
      Plist.integer(1161),
      Plist.integer(1162),
      Plist.integer(1163),
      Plist.integer(1164),
      Plist.integer(1165),
      Plist.integer(1166),
      Plist.integer(1167),
      Plist.integer(1168),
      Plist.integer(1169),
      Plist.integer(1170),
      Plist.integer(1171),
      Plist.integer(1172),
      Plist.integer(1173),
      Plist.integer(1174),
      Plist.integer(1175),
      Plist.integer(1176),
      Plist.integer(1177),
      Plist.integer(1178),
      Plist.integer(1179),
      Plist.integer(1180),
      Plist.integer(1181),
      Plist.integer(1182),
      Plist.integer(1183),
      Plist.integer(1184),
      Plist.integer(1185),
      Plist.integer(1186),
      Plist.integer(1187),
      Plist.integer(1188),
      Plist.integer(1189),
      Plist.integer(1190),
      Plist.integer(1191),
      Plist.integer(1192),
      Plist.integer(1193),
      Plist.integer(1194),
      Plist.integer(1195),
      Plist.integer(1196),
      Plist.integer(1197),
      Plist.integer(1198),
      Plist.integer(1199),
      Plist.integer(1200),
      Plist.integer(1201),
      Plist.integer(1202),
      Plist.integer(1203),
      Plist.integer(1204),
      Plist.integer(1205),
      Plist.integer(1206),
      Plist.integer(1207),
      Plist.integer(1208),
      Plist.integer(1209),
      Plist.integer(1210),
      Plist.integer(1211),
      Plist.integer(1212),
      Plist.integer(1213),
      Plist.integer(1214),
      Plist.integer(1215),
      Plist.integer(1216),
      Plist.integer(1217),
      Plist.integer(1218),
      Plist.integer(1219),
      Plist.integer(1220),
      Plist.integer(1221),
      Plist.integer(1222),
      Plist.integer(1223),
      Plist.integer(1224),
      Plist.integer(1225),
      Plist.integer(1226),
      Plist.integer(1227),
      Plist.integer(1228),
      Plist.integer(1229),
      Plist.integer(1230),
      Plist.integer(1231),
      Plist.integer(1232),
      Plist.integer(1233),
      Plist.integer(1234),
      Plist.integer(1235),
      Plist.integer(1236),
      Plist.integer(1237),
      Plist.integer(1238),
      Plist.integer(1239),
      Plist.integer(1240),
      Plist.integer(1241),
      Plist.integer(1242),
      Plist.integer(1243),
      Plist.integer(1244),
      Plist.integer(1245),
      Plist.integer(1246),
      Plist.integer(1247),
      Plist.integer(1248),
      Plist.integer(1249),
      Plist.integer(1250),
      Plist.integer(1251),
      Plist.integer(1252),
      Plist.integer(1253),
      Plist.integer(1254),
      Plist.integer(1255),
      Plist.integer(1256),
      Plist.integer(1257),
      Plist.integer(1258),
      Plist.integer(1259),
      Plist.integer(1260),
      Plist.integer(1261),
      Plist.integer(1262),
      Plist.integer(1263),
      Plist.integer(1264),
      Plist.integer(1265),
      Plist.integer(1266),
      Plist.integer(1267),
      Plist.integer(1268),
      Plist.integer(1269),
      Plist.integer(1270),
      Plist.integer(1271),
      Plist.integer(1272),
      Plist.integer(1273),
      Plist.integer(1274),
      Plist.integer(1275),
      Plist.integer(1276),
      Plist.integer(1277),
      Plist.integer(1278),
      Plist.integer(1279),
      Plist.integer(1280),
      Plist.integer(1281),
      Plist.integer(1282),
      Plist.integer(1283),
      Plist.integer(1284),
      Plist.integer(1285),
      Plist.integer(1286),
      Plist.integer(1287),
      Plist.integer(1288),
      Plist.integer(1289),
      Plist.integer(1290),
      Plist.integer(1291),
      Plist.integer(1292),
      Plist.integer(1293),
      Plist.integer(1294),
      Plist.integer(1295),
      Plist.integer(1296),
      Plist.integer(1297),
      Plist.integer(1298),
      Plist.integer(1299),
    }),
    binary = "62706c6973743030af11012c000100020003000400050006000700080009000a000b000c000d000e000f001000110012" ..
      "0013001400150016001700180019001a001b001c001d001e001f0020002100220023002400250026002700280029002a" ..
      "002b002c002d002e002f0030003100320033003400350036003700380039003a003b003c003d003e003f004000410042" ..
      "0043004400450046004700480049004a004b004c004d004e004f0050005100520053005400550056005700580059005a" ..
      "005b005c005d005e005f0060006100620063006400650066006700680069006a006b006c006d006e006f007000710072" ..
      "0073007400750076007700780079007a007b007c007d007e007f0080008100820083008400850086008700880089008a" ..
      "008b008c008d008e008f0090009100920093009400950096009700980099009a009b009c009d009e009f00a000a100a2" ..
      "00a300a400a500a600a700a800a900aa00ab00ac00ad00ae00af00b000b100b200b300b400b500b600b700b800b900ba" ..
      "00bb00bc00bd00be00bf00c000c100c200c300c400c500c600c700c800c900ca00cb00cc00cd00ce00cf00d000d100d2" ..
      "00d300d400d500d600d700d800d900da00db00dc00dd00de00df00e000e100e200e300e400e500e600e700e800e900ea" ..
      "00eb00ec00ed00ee00ef00f000f100f200f300f400f500f600f700f800f900fa00fb00fc00fd00fe00ff010001010102" ..
      "0103010401050106010701080109010a010b010c010d010e010f0110011101120113011401150116011701180119011a" ..
      "011b011c011d011e011f0120012101220123012401250126012701280129012a012b012c1103e81103e91103ea1103eb" ..
      "1103ec1103ed1103ee1103ef1103f01103f11103f21103f31103f41103f51103f61103f71103f81103f91103fa1103fb" ..
      "1103fc1103fd1103fe1103ff11040011040111040211040311040411040511040611040711040811040911040a11040b" ..
      "11040c11040d11040e11040f11041011041111041211041311041411041511041611041711041811041911041a11041b" ..
      "11041c11041d11041e11041f11042011042111042211042311042411042511042611042711042811042911042a11042b" ..
      "11042c11042d11042e11042f11043011043111043211043311043411043511043611043711043811043911043a11043b" ..
      "11043c11043d11043e11043f11044011044111044211044311044411044511044611044711044811044911044a11044b" ..
      "11044c11044d11044e11044f11045011045111045211045311045411045511045611045711045811045911045a11045b" ..
      "11045c11045d11045e11045f11046011046111046211046311046411046511046611046711046811046911046a11046b" ..
      "11046c11046d11046e11046f11047011047111047211047311047411047511047611047711047811047911047a11047b" ..
      "11047c11047d11047e11047f11048011048111048211048311048411048511048611048711048811048911048a11048b" ..
      "11048c11048d11048e11048f11049011049111049211049311049411049511049611049711049811049911049a11049b" ..
      "11049c11049d11049e11049f1104a01104a11104a21104a31104a41104a51104a61104a71104a81104a91104aa1104ab" ..
      "1104ac1104ad1104ae1104af1104b01104b11104b21104b31104b41104b51104b61104b71104b81104b91104ba1104bb" ..
      "1104bc1104bd1104be1104bf1104c01104c11104c21104c31104c41104c51104c61104c71104c81104c91104ca1104cb" ..
      "1104cc1104cd1104ce1104cf1104d01104d11104d21104d31104d41104d51104d61104d71104d81104d91104da1104db" ..
      "1104dc1104dd1104de1104df1104e01104e11104e21104e31104e41104e51104e61104e71104e81104e91104ea1104eb" ..
      "1104ec1104ed1104ee1104ef1104f01104f11104f21104f31104f41104f51104f61104f71104f81104f91104fa1104fb" ..
      "1104fc1104fd1104fe1104ff11050011050111050211050311050411050511050611050711050811050911050a11050b" ..
      "11050c11050d11050e11050f110510110511110512110513000802640267026a026d0270027302760279027c027f0282" ..
      "02850288028b028e029102940297029a029d02a002a302a602a902ac02af02b202b502b802bb02be02c102c402c702ca" ..
      "02cd02d002d302d602d902dc02df02e202e502e802eb02ee02f102f402f702fa02fd0300030303060309030c030f0312" ..
      "03150318031b031e032103240327032a032d0330033303360339033c033f034203450348034b034e035103540357035a" ..
      "035d0360036303660369036c036f037203750378037b037e038103840387038a038d0390039303960399039c039f03a2" ..
      "03a503a803ab03ae03b103b403b703ba03bd03c003c303c603c903cc03cf03d203d503d803db03de03e103e403e703ea" ..
      "03ed03f003f303f603f903fc03ff040204050408040b040e041104140417041a041d0420042304260429042c042f0432" ..
      "04350438043b043e044104440447044a044d0450045304560459045c045f046204650468046b046e047104740477047a" ..
      "047d0480048304860489048c048f049204950498049b049e04a104a404a704aa04ad04b004b304b604b904bc04bf04c2" ..
      "04c504c804cb04ce04d104d404d704da04dd04e004e304e604e904ec04ef04f204f504f804fb04fe050105040507050a" ..
      "050d0510051305160519051c051f052205250528052b052e053105340537053a053d0540054305460549054c054f0552" ..
      "05550558055b055e056105640567056a056d0570057305760579057c057f058205850588058b058e059105940597059a" ..
      "059d05a005a305a605a905ac05af05b205b505b805bb05be05c105c405c705ca05cd05d005d305d605d905dc05df05e2" ..
      "05e50000000000000202000000000000012d000000000000000000000000000005e8",
  },
  {
    name = "a keyed archive",
    value = Plist.dict({
      { key = "$version", value = Plist.integer(100000) },
      { key = "$archiver", value = Plist.string("NSKeyedArchiver") },
      { key = "$top", value = Plist.dict({
        { key = "root", value = Plist.uid(1) },
      }) },
      { key = "$objects", value = Plist.array({
        Plist.string("$null"),
        Plist.dict({
          { key = "NS.objects", value = Plist.array({ Plist.uid(2), Plist.uid(3) }) },
          { key = "$class", value = Plist.uid(4) },
        }),
        Plist.string("first"),
        Plist.string("second"),
        Plist.dict({
          { key = "$classname", value = Plist.string("NSArray") },
          { key = "$classes", value = Plist.array({ Plist.string("NSArray"), Plist.string("NSObject") }) },
        }),
      }) },
    }),
    binary = "62706c6973743030d4010203040506070a582476657273696f6e592461726368697665725424746f7058246f626a6563" ..
      "747312000186a05f100f4e534b657965644172636869766572d1080954726f6f748001a50b0c13141555246e756c6cd2" ..
      "0d0e0f125a4e532e6f626a656374735624636c617373a21011800280038004556669727374567365636f6e64d2161718" ..
      "195a24636c6173736e616d655824636c6173736573574e534172726179a2181a584e534f626a65637408111a24293237" ..
      "494c5153595f646f76797b7d7f858c919ca5adb00000000000000101000000000000001b000000000000000000000000" ..
      "000000b9",
  },
  {
    name = "UIDs at each width",
    value = Plist.array({
      Plist.uid(0),
      Plist.uid(255),
      Plist.uid(256),
      Plist.uid(65535),
      Plist.uid(65536),
      Plist.uid(4294967295),
      Plist.uid(4294967296),
      Plist.uid(9223372036854775807),
    }),
    binary = "62706c6973743030a80102030405060708800080ff81010081ffff830001000083ffffffff870000000100000000877f" ..
      "ffffffffffffff08111315181b20252e0000000000000101000000000000000900000000000000000000000000000037",
  },
  {
    name = "every type",
    value = Plist.dict({
      { key = "boolean", value = Plist.boolean(true) },
      { key = "integer", value = Plist.integer(-42) },
      { key = "real", value = Plist.real(3.25) },
      { key = "string", value = Plist.string("text") },
      { key = "data", value = Plist.data("\xde\xad\xbe\xef") },
      { key = "date", value = Plist.date(1582977600) },
      { key = "array", value = Plist.array({ Plist.integer(1), Plist.string("two"), Plist.real(3.0) }) },
      { key = "dict", value = Plist.dict({
        { key = "inner", value = Plist.boolean(false) },
      }) },
    }),
    binary = "62706c6973743030d80102030405060708090a0b0c0d0e0f1357626f6f6c65616e57696e7465676572547265616c5673" ..
      "7472696e675464617461546461746555617272617954646963740913ffffffffffffffd623400a000000000000547465" ..
      "787444deadbeef3341c20544e0000000a310111210015374776f234008000000000000d1141555696e6e657208081921" ..
      "292e353a3f454a4b545d62677074767a83868c0000000000000101000000000000001600000000000000000000000000" ..
      "00008d",
    xml = "<dict>\n" ..
      "\t<key>boolean</key>\n" ..
      "\t<true/>\n" ..
      "\t<key>integer</key>\n" ..
      "\t<integer>-42</integer>\n" ..
      "\t<key>real</key>\n" ..
      "\t<real>3.25</real>\n" ..
      "\t<key>string</key>\n" ..
      "\t<string>text</string>\n" ..
      "\t<key>data</key>\n" ..
      "\t<data>\n" ..
      "\t3q2+7w==\n" ..
      "\t</data>\n" ..
      "\t<key>date</key>\n" ..
      "\t<date>2020-02-29T12:00:00Z</date>\n" ..
      "\t<key>array</key>\n" ..
      "\t<array>\n" ..
      "\t\t<integer>1</integer>\n" ..
      "\t\t<string>two</string>\n" ..
      "\t\t<real>3.0</real>\n" ..
      "\t</array>\n" ..
      "\t<key>dict</key>\n" ..
      "\t<dict>\n" ..
      "\t\t<key>inner</key>\n" ..
      "\t\t<false/>\n" ..
      "\t</dict>\n" ..
      "</dict>\n",
  },
}

--- Whether two values are the same, a real that is not a number being the same as another.
local function same(a: Plist.Value, b: Plist.Value): boolean
  if a.kind ~= b.kind then return false end
  local a_real, b_real = a.real, b.real
  if a_real ~= nil and b_real ~= nil and a_real ~= a_real then
    return b_real ~= b_real
  end
  if a.boolean ~= b.boolean or a.integer ~= b.integer or (a.unsigned == true) ~= (b.unsigned == true) or
      a_real ~= b_real or a.text ~= b.text or a.data ~= b.data or a.date ~= b.date or a.uid ~= b.uid then
    return false
  end
  local a_items, b_items = a.items, b.items
  if (a_items == nil) ~= (b_items == nil) then return false end
  if a_items ~= nil and b_items ~= nil then
    if #a_items ~= #b_items then return false end
    for i, item in ipairs(a_items) do
      local other = b_items[i]
      if other == nil or not same(item, other) then return false end
    end
  end
  local a_entries, b_entries = a.entries, b.entries
  if (a_entries == nil) ~= (b_entries == nil) then return false end
  if a_entries ~= nil and b_entries ~= nil then
    if #a_entries ~= #b_entries then return false end
    for i, entry in ipairs(a_entries) do
      local other = b_entries[i]
      if other == nil or entry.key ~= other.key or not same(entry.value, other.value) then
        return false
      end
    end
  end
  return true
end

local function unhex(hex: string): string
  local bytes = assert(Codec.unhex(hex))
  return bytes
end

--- `bytes` are refused, for a reason that holds `fragment`.
local function refused(bytes: string, fragment: string, opts?: Plist.DecodeOptions)
  local value, why = Plist.decode(bytes, opts)
  assert(value == nil, ("read, where a refusal with %q was wanted"):format(fragment))
  assert(why:find(fragment, 1, true) ~= nil, ("refused with %q, not with %q"):format(why, fragment))
  assert(why:sub(1, 7) == "plist: ", why)
end

--- `value` is not written, for a reason that holds `fragment`.
local function unwritable(value: Plist.Value, fragment: string, opts?: Plist.EncodeOptions)
  local bytes, why = Plist.encode(value, opts)
  assert(bytes == nil, ("written, where a refusal with %q was wanted"):format(fragment))
  assert(why:find(fragment, 1, true) ~= nil, ("refused with %q, not with %q"):format(why, fragment))
end

local function read(bytes: string, opts?: Plist.DecodeOptions): Plist.Value
  local value = assert(Plist.decode(bytes, opts))
  return value
end

local function written(value: Plist.Value, opts?: Plist.EncodeOptions): string
  local bytes = assert(Plist.encode(value, opts))
  return bytes
end

--- How a binary property list built by `bplist` departs from what a writer would lay out.
local record Layout
  top?: integer
  offset_size?: integer
  ref_size?: integer
  count?: integer
  --- Where the trailer says the offset table is, and the offsets in it.
  table_at?: integer
  offsets?: {integer}
  --- Bytes between the objects and the offset table.
  padding?: string
end

--- A binary property list of the objects whose bytes these are, numbered from 0, with one byte to an offset
--- and to a reference unless `layout` says otherwise.
local function bplist(objects: {string}, layout?: Layout): string
  local l: Layout = layout or {}
  local offset_size = l.offset_size or 1
  local parts: mut {string} = { "bplist00" }
  local offsets: mut {integer} = {}
  local at = 8
  for _, object in ipairs(objects) do
    offsets[#offsets + 1] = at
    parts[#parts + 1] = object
    at = at + #object
  end
  local padding = l.padding or ""
  parts[#parts + 1] = padding
  at = at + #padding
  local width = if offset_size >= 1 and offset_size <= 8 then offset_size else 1 end
  for _, offset in ipairs(l.offsets or offsets) do
    local packed = string.pack(">I" .. tostring(width), offset)
    parts[#parts + 1] = packed
  end
  local trailer = string.pack(">I5BBBi8i8i8", 0, 0, offset_size, l.ref_size or 1, l.count or #objects, l.top or 0,
    l.table_at or at)
  parts[#parts + 1] = trailer
  return table.concat(parts)
end

--- An XML property list of this value's elements.
local function xml(body: string): string
  return "<plist>" .. body .. "</plist>"
end

local function test_what_plistlib_writes_reads_as_its_value()
  for _, case in ipairs(CASES) do
    local binary, body = case.binary, case.xml
    if binary ~= nil then
      assert(same(read(unhex(binary)), case.value), case.name .. ": the binary form reads as another value")
    end
    if body ~= nil then
      assert(same(read(XML_HEAD .. body .. XML_TAIL), case.value), case.name .. ": the XML form reads as another value")
    end
  end
end

local function test_a_value_is_written_as_plistlib_writes_it()
  for _, case in ipairs(CASES) do
    local binary, body = case.binary, case.xml
    if binary ~= nil then
      assert(Codec.hex(written(case.value)) == binary, case.name .. ": the binary form differs")
      assert(Codec.hex(written(case.value, { form = "binary" })) == binary, case.name)
    end
    if body ~= nil then
      local text = written(case.value, { form = "xml" })
      assert(text == XML_HEAD .. body .. XML_TAIL, case.name .. ": the XML form differs:\n" .. text)
    end
  end
end

local function test_every_value_reads_back_from_both_forms()
  for _, case in ipairs(CASES) do
    assert(same(read(written(case.value)), case.value), case.name .. ": binary")
    -- XML holds every case but a date's fraction, which has a test of its own.
    if case.name ~= "a date with a fraction" then
      assert(same(read(written(case.value, { form = "xml" })), case.value), case.name .. ": XML")
    end
  end
end

local function test_sort_keys_writes_a_dict_in_the_order_of_its_keys()
  local value = Plist.dict({
    { key = "b", value = Plist.integer(2) },
    { key = "a", value = Plist.integer(1) },
    { key = "C", value = Plist.integer(3) },
    { key = "\u{E9}", value = Plist.integer(4) },
    { key = "aa", value = Plist.integer(5) },
  })
  -- What `plistlib` writes for it with `sort_keys=True`.
  assert(Codec.hex(written(value, { sort_keys = true })) ==
      "62706c6973743030d50102030405060708090a5143516152616151626100e910031001100510021004081315171a1c1f" ..
      "212325270000000000000101000000000000000b00000000000000000000000000000029")
  assert(written(value, { form = "xml", sort_keys = true }) == XML_HEAD .. "<dict>\n" ..
      "\t<key>C</key>\n\t<integer>3</integer>\n\t<key>a</key>\n\t<integer>1</integer>\n" ..
      "\t<key>aa</key>\n\t<integer>5</integer>\n\t<key>b</key>\n\t<integer>2</integer>\n" ..
      "\t<key>\u{E9}</key>\n\t<integer>4</integer>\n</dict>\n" .. XML_TAIL)
  local kept = assert(read(written(value)).entries)
  assert(assert(kept[1]).key == "b" and assert(kept[5]).key == "aa", "a dict's entries left their order")
end

local function test_a_table_in_several_places_is_one_object()
  local shared = Plist.array({ Plist.integer(1), Plist.integer(2) })
  local value = Plist.array({ shared, shared, Plist.dict({ { key = "k", value = shared } }) })
  -- What `plistlib` writes for one list held three times.
  local bytes = unhex("62706c6973743030a3010104a2020310011002d10501516b080c0f111316000000000000010100000000000000060000" ..
      "0000000000000000000000000018")
  assert(written(value) == bytes)
  local back = assert(read(bytes).items)
  local first, second, third = assert(back[1]), assert(back[2]), assert(back[3])
  assert(rawequal(first, second), "an object referred to twice is read as two tables")
  assert(rawequal(Plist.get(third, "k"), first))
  -- Equal arrays in two tables are two objects, as two lists are to `plistlib`.
  local apart = Plist.array({ Plist.array({ Plist.integer(1) }), Plist.array({ Plist.integer(1) }) })
  local read_apart = assert(read(written(apart)).items)
  assert(not rawequal(read_apart[1], read_apart[2]))
  -- A UID is one object for each table, so one table held twice is written once and an equal one again.
  local uid = Plist.uid(7)
  assert(Codec.hex(written(Plist.array({ uid, uid, Plist.uid(7) }))) ==
      "62706c6973743030a301010280078007080c0e0000000000000101000000000000000300000000000000000000000000" ..
      "000010")
  -- The XML form writes the shared table at each place.
  local _, count = written(value, { form = "xml" }):gsub("<array>", "")
  assert(count == 4)
end

local function test_lengths_past_two_bytes_are_written_as_plistlib_writes_them()
  local value = Plist.array({ Plist.string(("y"):rep(70000)), Plist.data(("z"):rep(70000)),
    Plist.string(("\u{E9}"):rep(300)) })
  local bytes = written(value)
  -- The length and digest of what `plistlib` writes: lengths of four bytes, offsets of four.
  assert(#bytes == 140676)
  assert(Hash.hex_sha256(bytes) == "5710e44a0b5935d9ac1c1c63d579f7b3bc0db126b1e521fe10d5a61edab44064")
  assert(same(read(bytes), value))
end

local function test_minus_zero_is_kept_apart_from_zero()
  -- `plistlib` writes one object for the two, and the sign is lost.
  local items = assert(read(written(Plist.array({ Plist.real(0.0), Plist.real(-0.0) }))).items)
  local zero, minus = assert(assert(items[1]).real), assert(assert(items[2]).real)
  assert(1 / zero == math.huge and 1 / minus == -math.huge)
  local from_xml = assert(read(written(Plist.real(-0.0), { form = "xml" })).real)
  assert(1 / from_xml == -math.huge)
end

local function test_a_date_keeps_its_fraction_in_binary_and_loses_it_in_xml()
  local date = Plist.date(1794659696.5)
  assert(date.date == 1794659696.5 - Plist.reference_date and Plist.reference_date == 978307200)
  assert(read(written(date)).date == date.date)
  assert(written(date, { form = "xml" }) == XML_HEAD .. "<date>2026-11-14T12:34:56Z</date>\n" .. XML_TAIL)
  -- Before 1970 the fraction is dropped toward the earlier second, as `plistlib` drops it.
  assert(written(Plist.date(-0.5), { form = "xml" }) == XML_HEAD .. "<date>1969-12-31T23:59:59Z</date>\n" .. XML_TAIL)
  assert(read(written(Plist.date(-0.5), { form = "xml" })).date == -1.0 - Plist.reference_date)
end

local function test_a_binary_date_is_written_back_as_the_bytes_it_was_read_from()
  -- Seconds from 2001 that a double counted from 1970 would not hold: the last bits of a fraction near
  -- 2001, and the double under a whole second, which would round up into the next.
  for _, since in ipairs({ 0.123456789, 1.9999999999999998, 86399.99999999999, -0.1, 5e-324, 753194096.123456, 1e300 }) do
    local bytes = bplist({ "\x33" .. string.pack(">d", since) })
    local value = read(bytes)
    assert(value.date == since)
    assert(written(value) == bytes)
  end
  assert(written(read(bplist({ "\x33" .. string.pack(">d", 1.9999999999999998) })), { form = "xml" }) ==
      XML_HEAD .. "<date>2001-01-01T00:00:01Z</date>\n" .. XML_TAIL)
  -- Dates a last bit apart are two objects.
  local near = Plist.array({ { kind = "date", date = 0.1 }, { kind = "date", date = 0.1 + 2.0 ^ -56 } })
  assert(#written(near) == #written(Plist.array({ Plist.integer(1), Plist.integer(2) })) + 14)
  assert(same(read(written(near)), near))
end

local function test_a_date_outside_four_digit_years_is_binary_only()
  for _, seconds in ipairs({ -62135596801.0, 253402300800.0, 1e300, -1e300 }) do
    local date = Plist.date(seconds)
    assert(read(written(date)).date == date.date)
    unwritable(date, "outside the years 0001 to 9999", { form = "xml" })
  end
  assert(written(Plist.date(-62135596800), { form = "xml" }):find("<date>0001-01-01T00:00:00Z</date>", 1, true) ~= nil)
  assert(written(Plist.date(253402300799.5), { form = "xml" }):find("<date>9999-12-31T23:59:59Z</date>", 1, true) ~= nil)
end

local function test_a_uid_passes_through_xml_as_a_dict_of_cf_uid()
  local archive = Plist.dict({
    { key = "$top", value = Plist.dict({ { key = "root", value = Plist.uid(1) } }) },
    { key = "$objects", value = Plist.array({ Plist.string("$null"), Plist.uid(4294967296) }) },
  })
  local text = written(archive, { form = "xml" })
  assert(text == XML_HEAD .. "<dict>\n\t<key>$top</key>\n\t<dict>\n\t\t<key>root</key>\n" ..
      "\t\t<dict>\n\t\t\t<key>CF$UID</key>\n\t\t\t<integer>1</integer>\n\t\t</dict>\n\t</dict>\n" ..
      "\t<key>$objects</key>\n\t<array>\n\t\t<string>$null</string>\n" ..
      "\t\t<dict>\n\t\t\t<key>CF$UID</key>\n\t\t\t<integer>4294967296</integer>\n\t\t</dict>\n\t</array>\n</dict>\n" ..
      XML_TAIL, text)
  assert(same(read(text), archive))
  -- A dict of that shape that was no UID is one after XML, and stays a dict in binary.
  local lookalike = Plist.dict({ { key = "CF$UID", value = Plist.integer(5) } })
  assert(read(written(lookalike, { form = "xml" })).kind == "uid")
  assert(same(read(written(lookalike)), lookalike))
  -- Only that shape: another key beside it, a value that is no integer, or one that is no UID's number.
  for _, body in ipairs({
      "<dict><key>CF$UID</key><integer>1</integer><key>x</key><true/></dict>",
      "<dict><key>CF$UID</key><string>1</string></dict>",
      "<dict><key>CF$UID</key><integer>-1</integer></dict>",
      "<dict><key>CF$UID</key><integer>9223372036854775808</integer></dict>",
  }) do
    assert(read(xml(body)).kind == "dict", body)
  end
end

local function test_a_keyed_archive_reads_with_its_uids()
  local archive: Case? = nil
  for _, case in ipairs(CASES) do
    if case.name == "a keyed archive" then archive = case end
  end
  local value = read(unhex(assert(assert(archive).binary)))
  local root = assert(Plist.get(assert(Plist.get(value, "$top")), "root"))
  assert(root.kind == "uid" and root.uid == 1)
  local objects = assert(assert(Plist.get(value, "$objects")).items)
  local array = assert(objects[assert(root.uid) + 1])
  local members = assert(assert(Plist.get(array, "NS.objects")).items)
  local texts: mut {string} = {}
  for _, member in ipairs(members) do
    local text = assert(assert(objects[assert(member.uid) + 1]).text)
    texts[#texts + 1] = text
  end
  assert(table.concat(texts, ",") == "first,second")
  local class = assert(objects[assert(assert(Plist.get(array, "$class")).uid) + 1])
  assert(assert(Plist.get(class, "$classname")).text == "NSArray")
  assert(Plist.get(class, "missing") == nil and Plist.get(root, "root") == nil)
end

local function test_form_goes_by_the_first_bytes()
  assert(Plist.form("bplist00") == "binary" and Plist.form("bplist15...") == "binary")
  assert(Plist.form("<?xml") == "xml" and Plist.form("  \n<plist>") == "xml" and Plist.form("\xEF\xBB\xBF<plist/>") == "xml")
  assert(Plist.form("\xFE\xFF\0<\0p") == "xml" and Plist.form("\xFF\xFE<\0p\0") == "xml")
  assert(Plist.form("") == nil and Plist.form("{ a = 1; }") == nil and Plist.form("bplis") == nil)
  refused("", "neither a binary property list nor XML")
  refused("{ a = 1; }", "neither a binary property list nor XML")
  refused("bplist15" .. ("\0"):rep(40), "version other than 00")
  refused("bplist0", "version other than 00")
end

local function test_xml_is_read_in_the_encodings_xml_has()
  local document = '<?xml version="1.0" encoding="UTF-16"?><plist><string>h\u{E9}</string></plist>'
  local wide: mut {string} = { "\xFE\xFF" }
  for _, code in utf8.codes(document) do
    local unit = string.pack(">I2", code)
    wide[#wide + 1] = unit
  end
  assert(read(table.concat(wide)).text == "h\u{E9}")
  assert(read("\xEF\xBB\xBF" .. xml("<string>bom</string>")).text == "bom")
  assert(read('<?xml version="1.0" encoding="ISO-8859-1"?><plist><string>h\xE9</string></plist>').text == "h\u{E9}")
end

local function test_xml_text_is_read_as_xml_spells_it()
  assert(read(xml("<string>a<![CDATA[<b>&]]>c&#x41;&amp;<!-- note -->d</string>")).text == "a<b>&cA&d")
  assert(read(xml("<string>  kept \n </string>")).text == "  kept \n ")
  assert(read(xml("<string/>")).text == "" and read(xml("<data/>")).data == "")
  assert(read(xml("\n<!-- a note -->\n<array>\n\t<true/> <!-- another --> <false/>\n</array>\n")).kind == "array")
  assert(read(xml("<data>\n\taGVs\n\tbG8=\n</data>")).data == "hello")
  -- A carriage return is written as a reference, so a reader does not fold it into a line feed.
  local text = written(Plist.string("a\rb\r\nc"), { form = "xml" })
  assert(text:find("<string>a&#13;b&#13;\nc</string>", 1, true) ~= nil, text)
  assert(read(text).text == "a\rb\r\nc")
  local keyed = Plist.dict({ { key = "<&>\r", value = Plist.boolean(true) } })
  assert(same(read(written(keyed, { form = "xml" })), keyed))
end

local function test_xml_integers_are_decimal_or_hexadecimal()
  local function integer(text: string): integer, boolean
    local value = read(xml("<integer>" .. text .. "</integer>"))
    assert(value.kind == "integer")
    return assert(value.integer), value.unsigned == true
  end
  local n, unsigned = integer(" 12 ")
  assert(n == 12 and not unsigned)
  assert(integer("+7") == 7 and integer("-0") == 0 and integer("000000000000000000000000012") == 12)
  assert(integer("0x10") == 16 and integer("0XfF") == 255 and integer("-0x10") == -16 and integer("0x0000000000000000001") == 1)
  assert(integer("9223372036854775807") == math.maxinteger and integer("-9223372036854775808") == math.mininteger)
  assert(integer("-0x8000000000000000") == math.mininteger and integer("0x7fffffffffffffff") == math.maxinteger)
  n, unsigned = integer("9223372036854775808")
  assert(n == math.mininteger and unsigned)
  n, unsigned = integer("18446744073709551615")
  assert(n == -1 and unsigned)
  n, unsigned = integer("0xffffffffffffffff")
  assert(n == -1 and unsigned)
  for _, text in ipairs({ "", " ", "abc", "1.5", "1e3", "1_0", "--1", "0x", "0xg", "1 2", "18446744073709551616",
      "-9223372036854775809", "0x10000000000000000", "-0x8000000000000001", "99999999999999999999",
      "123456789012345678901" }) do
    refused(xml("<integer>" .. text .. "</integer>"), "not an integer")
  end
end

local function test_xml_reals_are_decimals_and_the_names_of_what_is_not()
  local function real(text: string): number
    local value = read(xml("<real>" .. text .. "</real>"))
    assert(value.kind == "real")
    return assert(value.real)
  end
  assert(real("1.5") == 1.5 and real(" -2 ") == -2.0 and real("+.5") == 0.5 and real("5.") == 5.0 and real("1E3") == 1000.0)
  assert(math.type(real("3")) == "float" and real("1e-2") == 0.01 and real("1e400") == math.huge)
  assert(real("inf") == math.huge and real("-Infinity") == -math.huge and real("+INF") == math.huge)
  local nan = real("NaN")
  assert(nan ~= nan)
  for _, text in ipairs({ "", ".", "e5", "1e", "1e+", "0x1p3", "0x10", "1,5", "1.5.2", "infinite", "nan1", "1 2", "--1" }) do
    refused(xml("<real>" .. text .. "</real>"), "not a real")
  end
end

local function test_long_runs_of_whitespace_cost_one_pass()
  -- Each of these is read or refused in the time it takes to scan it once: a pattern that tried every pair
  -- of ends would run past the test's deadline.
  local run = (" "):rep(200000)
  for _, element in ipairs({ "real", "integer", "date", "data", "true" }) do
    refused(xml("<" .. element .. ">" .. run .. "x" .. run .. "y" .. run .. "</" .. element .. ">"), "plist: ")
  end
  assert(read(xml("<real>" .. run .. "1.5" .. run .. "</real>")).real == 1.5)
  assert(read(xml("<integer>" .. run .. "7" .. run .. "</integer>")).integer == 7)
  assert(read(xml("<integer>" .. ("0"):rep(200000) .. "7</integer>")).integer == 7)
  assert(read(xml("<data>" .. run .. "aGk=" .. run .. "</data>")).data == "hi")
  assert(read(xml("<array>" .. run .. "<true/>" .. run .. "</array>")).kind == "array")
end

local function test_xml_dates_are_one_spelling_of_a_real_moment()
  assert(read(xml("<date>1970-01-01T00:00:00Z</date>")).date == -978307200.0)
  assert(read(xml("<date> 2000-02-29T23:59:59Z\n</date>")).date == 951868799.0 - 978307200.0)
  assert(math.type(read(xml("<date>2001-01-01T00:00:00Z</date>")).date) == "float")
  for _, text in ipairs({ "", "2020-01", "2020-01-02", "2020-01-02T03:04:05", "2020-01-02 03:04:05Z", "2020-13-01T00:00:00Z",
      "2020-00-10T00:00:00Z", "2021-02-29T00:00:00Z", "1900-02-29T00:00:00Z", "2020-04-31T00:00:00Z",
      "2020-01-00T00:00:00Z", "2020-01-02T24:00:00Z", "2020-01-02T00:60:00Z", "2020-01-02T00:00:60Z",
      "0000-01-01T00:00:00Z", "20200-01-01T00:00:00Z", "2020-01-02T03:04:05.5Z", "2020-01-02T03:04:05+00:00" }) do
    refused(xml("<date>" .. text .. "</date>"), "not a date")
  end
end

local function test_xml_that_is_no_property_list_is_refused()
  refused("<plist><array>", "xml: ")
  refused("<plist><string>\1</string></plist>", "xml: ")
  refused("<integer>1</integer>", "the root element is <integer>, not <plist>")
  refused(xml(""), "does not hold one value")
  refused(xml("  \n "), "does not hold one value")
  refused(xml("<integer>1</integer><integer>2</integer>"), "does not hold one value")
  refused(xml("stray<integer>1</integer>"), "text between the elements of <plist>")
  refused(xml("<array>stray<integer>1</integer></array>"), "text between the elements of <array>")
  refused(xml("<dict>stray</dict>"), "text between the elements of <dict>")
  refused(xml("<dict><key>a</key></dict>"), "does not hold a value for each key")
  refused(xml("<dict><integer>1</integer><integer>2</integer></dict>"), "<integer> where a key goes")
  refused(xml("<dict><key>a<b/></key><true/></dict>"), "<key> where a key goes")
  refused(xml("<dict><key>a</key><true/><key>a</key><false/></dict>"), "holds a key twice")
  refused(xml("<dict><key>a</key><true/><key>&#x61;</key><false/></dict>"), "holds a key twice")
  refused(xml("<string>a<b/>c</string>"), "<string> holds an element")
  refused(xml("<true>x</true>"), "<true> holds text")
  refused(xml("<false><true/></false>"), "<false> holds an element")
  refused(xml("<set/>"), "<set> is no element of a property list")
  refused(xml("<key>a</key>"), "<key> is no element of a property list")
  refused(xml("<plist><true/></plist>"), "<plist> is no element of a property list")
  refused(xml("<data>!!!</data>"), "data that is not base64")
  refused(xml("<data>YQ</data>"), "data that is not base64")
  refused(xml("<data>YQ==YQ==</data>"), "data that is not base64")
  assert(read(xml("<true> </true>")).boolean == true)
end

local function test_an_xml_refusal_names_where_it_is()
  local _, why = Plist.decode(xml("<dict><key>users</key><array><dict/><dict><key>age</key><integer>x</integer></dict></array></dict>"))
  assert(why == "plist: not an integer from -2^63 to 2^64 - 1 (at users/2/age)", why)
  -- A long way to it is cut to its innermost end, at a whole character.
  local long = ("\u{E9}"):rep(200)
  local _, long_why = Plist.decode(xml("<dict><key>" .. long .. "</key><real>x</real></dict>"))
  assert(long_why == "plist: not a real (at ..." .. ("\u{E9}"):rep(48) .. ")", long_why)
end

local function test_entities_are_held_to_what_xml_allows()
  assert(read('<!DOCTYPE plist [<!ENTITY e "entity">]><plist><string>&e;</string></plist>').text == "entity")
  local bomb: mut {string} = { '<!DOCTYPE plist [<!ENTITY a0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">' }
  for i = 1, 12 do
    local declaration = ('<!ENTITY a%d "%s">'):format(i, ("&a%d;"):format(i - 1):rep(16))
    bomb[#bomb + 1] = declaration
  end
  bomb[#bomb + 1] = "]><plist><string>&a12;</string></plist>"
  refused(table.concat(bomb), "xml: ")
  refused('<!DOCTYPE plist [<!ENTITY x SYSTEM "file:///etc/passwd">]><plist><dict><key a="&x;">k</key><true/></dict></plist>',
    "xml: ")
end

local function test_nesting_is_held_to_max_depth()
  local function nested_xml(depth: integer): string
    return xml(("<array>"):rep(depth) .. ("</array>"):rep(depth))
  end
  local function nested_binary(depth: integer): string
    local objects: mut {string} = {}
    for i = 1, depth - 1 do
      local object = "\xA1" .. string.pack(">I2", i)
      objects[#objects + 1] = object
    end
    objects[#objects + 1] = "\xA0"
    return bplist(objects, { ref_size = 2, offset_size = 2 })
  end
  local function depth_of(value: Plist.Value): integer
    local depth = 0
    local at: Plist.Value? = value
    while at ~= nil and at.kind == "array" do
      depth = depth + 1
      at = assert(at.items)[1]
    end
    return depth
  end
  for _, nested in ipairs({ nested_xml, nested_binary }) do
    assert(depth_of(read(nested(64))) == 64)
    refused(nested(65), "nested deeper than 64")
    assert(depth_of(read(nested(3), { max_depth = 3 })) == 3)
    refused(nested(4), "nested deeper than 3", { max_depth = 3 })
    refused(nested(2), "nested deeper than 1", { max_depth = 1 })
    assert(read(nested(1), { max_depth = 1 }).kind == "array")
    local deep = read(nested(1000), { max_depth = 1000 })
    assert(depth_of(deep) == 1000)
    unwritable(deep, "nested deeper than 64")
    unwritable(deep, "nested deeper than 64", { form = "xml" })
    assert(depth_of(read(written(deep, { max_depth = 1000 }), { max_depth = 1000 })) == 1000)
    assert(depth_of(read(written(deep, { max_depth = 1000, form = "xml" }), { max_depth = 1000 })) == 1000)
    refused(nested(1001), "nested deeper than 1000", { max_depth = 1000 })
  end
  -- An object read first where it is not too deep is too deep where it is held again: the array at 3 is
  -- two deep by way of 0 and 3, and four by way of 0, 1, 2 and 3.
  local shared = { "\xA2\x03\x01", "\xA1\x02", "\xA1\x03", "\xA1\x04", "\xA0" }
  assert(read(bplist(shared), { max_depth = 5 }).kind == "array")
  refused(bplist(shared), "object 3 is nested deeper than 4", { max_depth = 4 })
  -- The dict that spells a UID in XML is no level: a UID inside the deepest array reads back.
  local deepest = Plist.array({ Plist.array({ Plist.uid(7) }) })
  assert(same(read(written(deepest, { form = "xml", max_depth = 2 }), { max_depth = 2 }), deepest))
  refused(xml("<array><array><dict><key>CF$UID</key><integer>-1</integer></dict></array></array>"),
    "nested deeper than 2", { max_depth = 2 })
  refused(xml("<array><array><dict><key>CF$UID</key><array/></dict></array></array>"), "nested deeper than 2",
    { max_depth = 2 })
  -- Only a dict of `CF$UID` and an integer is no level: one that holds another is, however many nest,
  -- and a chain of them far past any limit is refused, where reading down it would end the stack.
  refused(xml(("<dict><key>CF$UID</key>"):rep(4) .. "<integer>1</integer>" .. ("</dict>"):rep(4)), "nested deeper than 2",
    { max_depth = 2 })
  refused(xml(("<dict><key>CF$UID</key>"):rep(200000) .. "<integer>1</integer>" .. ("</dict>"):rep(200000)),
    "nested deeper than 64")
  local chain: mut {string} = {}
  for i = 1, 400000 do chain[i] = "\xA1" .. string.pack(">I4", i) end
  chain[#chain + 1] = "\xA0"
  refused(bplist(chain, { ref_size = 4, offset_size = 4 }), "object 64 is nested deeper than 64")
  -- A dict counts as an array does, and a scalar inside the deepest does not.
  refused(xml("<dict><key>a</key><array><dict/></array></dict>"), "nested deeper than 2", { max_depth = 2 })
  assert(read(xml("<dict><key>a</key><array><true/></array></dict>"), { max_depth = 2 }).kind == "dict")
  for _, max_depth in ipairs({ 0, -1, 1001 }) do
    local ok, why = pcall(Plist.decode, "bplist00", { max_depth = max_depth })
    assert(not ok and tostring(why):find("max_depth is " .. tostring(max_depth) .. ", not 1 to 1000", 1, true) ~= nil)
    ok, why = pcall(Plist.encode, Plist.boolean(true), { max_depth = max_depth })
    assert(not ok and tostring(why):find("max_depth is", 1, true) ~= nil)
  end
end

local function test_a_binary_trailer_is_checked_before_it_is_followed()
  local one = { "\x09" }
  assert(read(bplist(one)).boolean == true)
  refused("bplist00" .. ("\0"):rep(33), "too short")
  refused("bplist00", "too short")
  refused(bplist(one, { offset_size = 0 }), "not 1 to 8 bytes wide")
  refused(bplist(one, { offset_size = 9 }), "not 1 to 8 bytes wide")
  refused(bplist(one, { ref_size = 0 }), "not 1 to 8 bytes wide")
  refused(bplist(one, { ref_size = 200 }), "not 1 to 8 bytes wide")
  refused(bplist(one, { table_at = 8 }), "offset table outside the bytes")
  refused(bplist(one, { table_at = 0 }), "offset table outside the bytes")
  refused(bplist(one, { table_at = 10 }), "offset table outside the bytes")
  refused(bplist(one, { table_at = 1 << 40 }), "offset table outside the bytes")
  refused(bplist(one, { table_at = -1 }), "offset table outside the bytes")
  refused(bplist(one, { table_at = math.mininteger }), "offset table outside the bytes")
  refused(bplist(one, { count = 0 }), "counts more objects")
  refused(bplist(one, { count = 2 }), "counts more objects")
  refused(bplist(one, { count = -1 }), "counts more objects")
  refused(bplist(one, { count = math.maxinteger }), "counts more objects")
  refused(bplist(one, { count = 1 << 61, offset_size = 8 }), "counts more objects")
  refused(bplist(one, { top = 1 }), "top object is not in the list")
  refused(bplist(one, { top = -1 }), "top object is not in the list")
  -- Offsets of any width from 1 to 8 bytes, and a table with room to spare before the trailer.
  for size = 1, 8 do
    assert(read(bplist({ "\x10\x07", "\x09" }, { offset_size = size, top = 1 })).boolean == true)
    assert(read(bplist({ "\xA1" .. string.pack(">I" .. tostring(size), 1), "\x10\x07" }, { ref_size = size })).kind == "array")
  end
  assert(read(bplist({ "\x09", "\x08" }, { count = 1 })).boolean == true)
end

local function test_a_binary_offset_stays_inside_the_objects()
  refused(bplist({ "\x09" }, { offsets = { 7 } }), "object 0 has an offset outside the objects")
  refused(bplist({ "\x09" }, { offsets = { 0 } }), "offset outside the objects")
  -- The offset table's own first byte, and the trailer.
  refused(bplist({ "\x09" }, { offsets = { 9 } }), "offset outside the objects")
  refused(bplist({ "\x09" }, { offsets = { 20 } }), "offset outside the objects")
  refused(bplist({ "\x09" }, { offsets = { 255 } }), "offset outside the objects")
  refused(bplist({ "\x09" }, { offset_size = 8, offsets = { -1 } }), "offset outside the objects")
  refused(bplist({ "\xA1\x01", "\x09" }, { offsets = { 8, 200 } }), "object 1 has an offset outside the objects")
end

local function test_a_binary_object_ends_inside_the_objects()
  -- Each object is cut short where the offset table begins.
  refused(bplist({ "\x11\x01" }), "ends before its integer")
  refused(bplist({ "\x13\0\0\0\0\0\0\0" }), "ends before its integer")
  refused(bplist({ "\x14" .. ("\0"):rep(15) }), "ends before its integer")
  refused(bplist({ "\x23\0\0\0\0\0\0\0" }), "real that is not 4 or 8 bytes")
  refused(bplist({ "\x22\0\0\0" }), "real that is not 4 or 8 bytes")
  refused(bplist({ "\x33\0\0\0\0\0\0\0" }), "date that is not 8 bytes")
  refused(bplist({ "\x45abcd" }), "longer than its bytes could hold")
  refused(bplist({ "\x55abcd" }), "longer than its bytes could hold")
  refused(bplist({ "\x62\0a\0" }), "longer than its bytes could hold")
  refused(bplist({ "\x81\x01" }), "UID that is not 1 to 8 bytes")
  refused(bplist({ "\x4F" }), "ends before its length")
  refused(bplist({ "\x4F\x11\x01" }), "ends before its length")
  refused(bplist({ "\x4F\x13\0\0\0\0\0\0\0" }), "ends before its length")
  refused(bplist({ "\x4F\x09" }), "length that is not an integer")
  refused(bplist({ "\x4F\x14" .. ("\0"):rep(16) }), "length that is not an integer")
  refused(bplist({ "\x4F\x23\0\0\0\0\0\0\0\0" }), "length that is not an integer")
  refused(bplist({ "\x4F\x12\xFF\xFF\xFF\xFFabc" }), "longer than its bytes could hold")
  refused(bplist({ "\x5F\x13\x7F\xFF\xFF\xFF\xFF\xFF\xFF\xFFabc" }), "longer than its bytes could hold")
  refused(bplist({ "\x6F\x13\x7F\xFF\xFF\xFF\xFF\xFF\xFF\xFF\0a" }), "longer than its bytes could hold")
  refused(bplist({ "\x4F\x13\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFFabc" }), "longer than its bytes could hold")
  refused(bplist({ "\xAF\x13\x7F\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x00" }), "holds more than its bytes could")
  refused(bplist({ "\xDF\x13\x7F\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x00\x00" }), "holds more than its bytes could")
  refused(bplist({ "\xDF\x13\x40\0\0\0\0\0\0\x01\x00\x00" }, { ref_size = 8 }), "holds more than its bytes could")
  refused(bplist({ "\x09", "\xA2\x00" }, { top = 1 }), "holds more than its bytes could")
  refused(bplist({ "\x51k", "\xD1\x00" }, { top = 1 }), "holds more than its bytes could")
  -- A length in an integer of each width reads, where the bytes are there.
  assert(read(bplist({ "\x4F\x10\x03abc" })).data == "abc")
  assert(read(bplist({ "\x5F\x11\x00\x03abc" })).text == "abc")
  assert(read(bplist({ "\x4F\x12\x00\x00\x00\x03abc" })).data == "abc")
  assert(read(bplist({ "\x4F\x13\0\0\0\0\0\0\0\x03abc" })).data == "abc")
  assert(read(bplist({ "\x40" })).data == "" and read(bplist({ "\x50" })).text == "" and read(bplist({ "\x60" })).text == "")
end

local function test_a_binary_reference_leads_to_an_object()
  refused(bplist({ "\xA1\x01" }), "object 0 refers to an object the list does not have")
  refused(bplist({ "\xA1\xFF", "\x09" }), "refers to an object the list does not have")
  refused(bplist({ "\xD1\x01\x02", "\x51k" }), "refers to an object the list does not have")
  refused(bplist({ "\xD1\x02\x01", "\x51k" }), "refers to an object the list does not have")
  refused(bplist({ "\xA1" .. ("\xFF"):rep(8), "\x09" }, { ref_size = 8 }), "refers to an object the list does not have")
end

local function test_a_binary_container_that_holds_itself_is_refused()
  refused(bplist({ "\xA1\x00" }), "object 0 holds itself")
  refused(bplist({ "\xA1\x01", "\xA1\x00" }), "object 0 holds itself")
  refused(bplist({ "\xA2\x01\x02", "\x09", "\xD1\x03\x00", "\x51k" }), "object 0 holds itself")
  refused(bplist({ "\xD1\x01\x00", "\x51k" }), "object 0 holds itself")
  refused(bplist({ "\xD1\x00\x01", "\x09" }), "object 0 holds itself")
  refused(bplist({ "\xA1\x01", "\xA1\x02", "\xA1\x01" }), "object 1 holds itself")
end

local function test_a_binary_value_holds_no_more_values_than_the_input_has_bytes()
  -- Forty arrays, each holding the next twice: 2^40 values as a tree, in 200 bytes.
  local objects: mut {string} = {}
  for i = 1, 40 do
    local object = "\xA2" .. string.char(i, i)
    objects[#objects + 1] = object
  end
  objects[#objects + 1] = "\xA0"
  refused(bplist(objects), "holds more values than the input has bytes", { max_depth = 100 })
  -- The same through a dict's values, and through sixteen bytes of references to one array of many.
  local dicts: mut {string} = { "\x51k" }
  for i = 1, 40 do
    local object = "\xA2" .. string.char(i + 1, i + 1)
    dicts[#dicts + 1] = if i % 2 == 0 then object else "\xD1\x00" .. string.char(i + 1) end
  end
  dicts[#dicts + 1] = "\xA0"
  refused(bplist(dicts, { top = 1 }), "holds more values than the input has bytes", { max_depth = 100 })
  local wide = "\xAF\x10\xC8" .. ("\x02"):rep(200)
  refused(bplist({ "\xAF\x10\x10" .. ("\x01"):rep(16), wide, "\x09" }), "holds more values than the input has bytes")
  -- An array held a few times is read, and so is one scalar held at every place of a long array.
  local few = read(bplist({ "\xA3\x01\x01\x01", "\xA2\x02\x02", "\x09" }))
  assert(#assert(few.items) == 3)
  local many = read(bplist({ wide, "\x10\x07", "\x09" }))
  assert(#assert(many.items) == 200)
end

local function test_binary_strings_and_data_hold_no_more_bytes_than_the_input_has()
  -- Forty offsets that lead to one data of a hundred bytes: four thousand bytes of data from two hundred.
  local refs: mut {string} = {}
  local offsets: mut {integer} = { 8 }
  for i = 1, 40 do
    refs[i] = string.char(i)
    offsets[#offsets + 1] = 51
  end
  local objects = { "\xAF\x10\x28" .. table.concat(refs), "\x4F\x10\x64" .. ("d"):rep(100) }
  refused(bplist(objects, { offsets = offsets, count = 41 }), "strings and data hold more bytes than the input has")
  -- Strings that overlap: each begins a byte into the one before.
  local overlapping: mut {integer} = { 8 }
  for i = 1, 40 do overlapping[#overlapping + 1] = 50 + i end
  local run = "\xAF\x10\x28" .. table.concat(refs) .. ("\x5F\x10\x50"):rep(14) .. ("s"):rep(100)
  refused(bplist({ run }, { offsets = overlapping, count = 41 }), "strings and data hold more bytes than the input has")
  -- One object referred to from every place, and an input that is nearly all one string, are read.
  local shared = { "\xAF\x10\x28" .. ("\x01"):rep(40), "\x4F\x10\x64" .. ("d"):rep(100) }
  assert(#assert(read(bplist(shared)).items) == 40)
  assert(read(bplist({ "\x5F\x11\x10\x00" .. ("s"):rep(4096) }, { offset_size = 2 })).text == ("s"):rep(4096))
  assert(#assert(read(bplist({ "\x6F\x11\x08\x00" .. ("\x00s"):rep(2048) }, { offset_size = 2 })).text) == 2048)
end

local function test_binary_integers_are_read_at_each_width()
  local function integer(bytes: string): integer, boolean
    local value = read(bplist({ bytes }))
    assert(value.kind == "integer")
    return assert(value.integer), value.unsigned == true
  end
  assert(integer("\x10\xFF") == 255 and integer("\x11\xFF\xFF") == 65535 and integer("\x12\xFF\xFF\xFF\xFF") == 4294967295)
  assert(integer("\x13" .. ("\xFF"):rep(8)) == -1)
  -- Sixteen bytes that fit: a small number, a negative one, and the unsigned range past a signed 64 bits.
  assert(integer("\x14" .. ("\0"):rep(15) .. "\x05") == 5)
  assert(integer("\x14" .. ("\xFF"):rep(15) .. "\xFB") == -5)
  assert(integer("\x14" .. ("\xFF"):rep(8) .. "\x80" .. ("\0"):rep(7)) == math.mininteger)
  local n, unsigned = integer("\x14" .. ("\0"):rep(8) .. ("\xFF"):rep(8))
  assert(n == -1 and unsigned)
  n, unsigned = integer("\x14" .. ("\0"):rep(8) .. "\x80" .. ("\0"):rep(7))
  assert(n == math.mininteger and unsigned)
  -- Sixteen bytes that do not: 2^64, -2^63 - 1, and the ends of 128 bits.
  for _, bytes in ipairs({ ("\0"):rep(7) .. "\x01" .. ("\0"):rep(8), ("\xFF"):rep(8) .. "\x7F" .. ("\xFF"):rep(7),
      "\x7F" .. ("\xFF"):rep(15), "\x80" .. ("\0"):rep(15), ("\xFF"):rep(7) .. "\xFE" .. ("\xFF"):rep(8) }) do
    refused(bplist({ "\x14" .. bytes }), "integer outside -2^63 to 2^64 - 1")
  end
  refused(bplist({ "\x15" .. ("\0"):rep(32) }), "integer wider than 16 bytes")
  refused(bplist({ "\x1F" .. ("\0"):rep(64) }), "integer wider than 16 bytes")
  -- What was read wide is written at the width `plistlib` gives it.
  assert(written(Plist.integer(5)) == bplist({ "\x10\x05" }))
  assert(written(Plist.integer(-1, true)) == bplist({ "\x14" .. ("\0"):rep(8) .. ("\xFF"):rep(8) }))
  assert(same(Plist.integer(5, true), Plist.integer(5)))
end

local function test_binary_reals_and_dates_are_numbers()
  assert(read(bplist({ "\x22" .. string.pack(">f", 1.5) })).real == 1.5)
  assert(read(bplist({ "\x22" .. string.pack(">f", 0.1) })).real == string.unpack(">f", string.pack(">f", 0.1)))
  assert(read(bplist({ "\x23" .. string.pack(">d", 0.1) })).real == 0.1)
  refused(bplist({ "\x20\x00" }), "real that is not 4 or 8 bytes")
  refused(bplist({ "\x21\x00\x00" }), "real that is not 4 or 8 bytes")
  refused(bplist({ "\x24" .. ("\0"):rep(16) }), "real that is not 4 or 8 bytes")
  assert(read(bplist({ "\x33" .. string.pack(">d", 0.0) })).date == 0.0)
  assert(same(read(bplist({ "\x33" .. string.pack(">d", -978307200.0) })), Plist.date(0)))
  refused(bplist({ "\x33" .. string.pack(">d", 0.0 / 0.0) }), "date that is not a number")
  refused(bplist({ "\x33" .. string.pack(">d", math.huge) }), "date that is not a number")
  refused(bplist({ "\x33" .. string.pack(">d", -math.huge) }), "date that is not a number")
  refused(bplist({ "\x32" .. ("\0"):rep(4) }), "date that is not 8 bytes")
  refused(bplist({ "\x30\x00" }), "date that is not 8 bytes")
end

local function test_binary_strings_are_ascii_or_utf16()
  assert(read(bplist({ "\x53a\x00b" })).text == "a\0b")
  refused(bplist({ "\x51\x80" }), "ASCII string with a byte past 127")
  refused(bplist({ "\x52a\xC3" }), "ASCII string with a byte past 127")
  assert(read(bplist({ "\x63\x00h\x00\xE9\xFF\xFD" })).text == "h\u{E9}\u{FFFD}")
  assert(read(bplist({ "\x63\xD8\x3D\xDE\x00\x00\x00" })).text == "\u{1F600}\0")
  assert(read(bplist({ "\x62\xDB\xFF\xDF\xFF" })).text == "\u{10FFFF}")
  -- A surrogate with no partner: a high one last, one before what is no low one, and a low one first.
  refused(bplist({ "\x61\xD8\x3D" }), "string that is not UTF-16")
  -- A high one last, where the bytes after the string are a low one of another object's.
  refused(bplist({ "\x61\xD8\x00", "\xDC\x00" }), "object 0 is a string that is not UTF-16")
  refused(bplist({ "\x62\xD8\x3D\x00a" }), "string that is not UTF-16")
  refused(bplist({ "\x62\xD8\x3D\xD8\x3D" }), "string that is not UTF-16")
  refused(bplist({ "\x61\xDE\x00" }), "string that is not UTF-16")
  refused(bplist({ "\x62\xDE\x00\xD8\x3D" }), "string that is not UTF-16")
  -- What `plistlib` writes for each: ASCII as it is, anything else as UTF-16, counted in 16-bit units.
  assert(written(Plist.string("a\0b")) == bplist({ "\x53a\x00b" }))
  assert(written(Plist.string("\u{1F600}")) == bplist({ "\x62\xD8\x3D\xDE\x00" }))
  assert(written(Plist.string(("\u{1F600}"):rep(8))) == bplist({ "\x6F\x10\x10" .. ("\xD8\x3D\xDE\x00"):rep(8) }))
end

local function test_binary_uids_are_one_to_eight_bytes()
  local function uid(bytes: string): integer
    local value = read(bplist({ bytes }))
    assert(value.kind == "uid")
    return assert(value.uid)
  end
  assert(uid("\x80\x07") == 7 and uid("\x81\x01\x00") == 256 and uid("\x82\x01\x00\x00") == 65536)
  assert(uid("\x87\x7F" .. ("\xFF"):rep(7)) == math.maxinteger and uid("\x84\0\0\0\0\x09") == 9)
  refused(bplist({ "\x87\x80" .. ("\0"):rep(7) }), "UID of 2^63 or more")
  refused(bplist({ "\x88" .. ("\0"):rep(9) }), "UID that is not 1 to 8 bytes")
  refused(bplist({ "\x8F" .. ("\0"):rep(16) }), "UID that is not 1 to 8 bytes")
end

local function test_binary_objects_no_property_list_has_are_refused()
  refused(bplist({ "\x00" }), "object 0 is a null, which no property list holds")
  refused(bplist({ "\xA1\x01", "\x00" }), "object 1 is a null")
  for _, marker in ipairs({ 0x01, 0x07, 0x0A, 0x0F, 0x70, 0x71, 0x90, 0xB0, 0xC0, 0xC1, 0xE0, 0xF0, 0xFF }) do
    refused(bplist({ string.char(marker) .. "\0\0\0\0" }), ("marker no property list has (0x%02X)"):format(marker))
  end
end

local function test_a_binary_dict_has_each_string_key_once()
  refused(bplist({ "\xD1\x01\x02", "\x10\x01", "\x09" }), "object 0 has a key that is not a string")
  refused(bplist({ "\xD1\x01\x02", "\x41k", "\x09" }), "has a key that is not a string")
  refused(bplist({ "\xD1\x01\x02", "\xA0", "\x09" }), "has a key that is not a string")
  refused(bplist({ "\xD2\x01\x01\x02\x02", "\x51k", "\x09" }), "object 0 holds a key twice")
  -- The same key as two objects, one of them UTF-16.
  refused(bplist({ "\xD2\x01\x03\x02\x02", "\x51k", "\x09", "\x61\x00k" }), "holds a key twice")
  local ordered = assert(read(bplist({ "\xD2\x01\x03\x02\x02", "\x51z", "\x09", "\x51a" })).entries)
  assert(assert(ordered[1]).key == "z" and assert(ordered[2]).key == "a")
end

local function test_a_value_no_property_list_holds_is_not_written()
  local forms: {Plist.Form} = { "binary", "xml" }
  for _, form in ipairs(forms) do
    local opts: Plist.EncodeOptions = { form = form }
    unwritable({ kind = "integer" }, "an integer with no `integer`", opts)
    unwritable({ kind = "boolean", integer = 1 }, "a boolean with no `boolean`", opts)
    unwritable({ kind = "real" }, "a real with no `real`", opts)
    unwritable({ kind = "string", data = "x" }, "a string with no `text`", opts)
    unwritable({ kind = "data" }, "a data with no `data`", opts)
    unwritable({ kind = "date" }, "a date with no `date`", opts)
    unwritable({ kind = "array" }, "an array with no `items`", opts)
    unwritable({ kind = "dict" }, "a dict with no `entries`", opts)
    unwritable({ kind = "uid" }, "a UID with no `uid`", opts)
    unwritable(Plist.uid(-1), "a UID is negative", opts)
    unwritable(Plist.string("\xFF"), "a string is not UTF-8", opts)
    unwritable(Plist.string("\xED\xA0\x80"), "a string is not UTF-8", opts)
    unwritable(Plist.date(0.0 / 0.0), "a date is not a number", opts)
    unwritable(Plist.date(math.huge), "a date is not a number", opts)
    unwritable(Plist.array({ Plist.array({ Plist.uid(-1) }) }), "a UID is negative", opts)
    unwritable(Plist.dict({ { key = "a", value = Plist.integer(1) }, { key = "a", value = Plist.integer(2) } }),
      "a dict holds a key twice", opts)
    unwritable(Plist.dict({ { key = "\xFF", value = Plist.integer(1) } }), "a key is not text this form can hold", opts)
    unwritable(Plist.dict({ { key = "k", value = Plist.dict({ { key = "k", value = { kind = "real" } } }) } }),
      "a real with no `real`", opts)
  end
  -- What the binary form holds and XML cannot.
  for _, text in ipairs({ "\0", "a\1b", "\11", "\x1F", "\u{FFFE}", "\u{FFFF}" }) do
    assert(read(written(Plist.string(text))).text == text)
    unwritable(Plist.string(text), "a string holds a character XML cannot", { form = "xml" })
    local keyed = Plist.dict({ { key = text, value = Plist.boolean(true) } })
    assert(same(read(written(keyed)), keyed))
    unwritable(keyed, "a key is not text this form can hold", { form = "xml" })
  end
end

local function test_max_bytes_bounds_what_is_written()
  -- A string of 20000 bytes at 2000 places: one object in the binary form, and 40 MB of XML.
  local text = Plist.string(("s"):rep(20000))
  local items: mut {Plist.Value} = {}
  for i = 1, 2000 do items[i] = text end
  local value = Plist.array(items)
  local binary = written(value)
  assert(#binary < 30000 and #assert(read(binary).items) == 2000)
  unwritable(read(binary), "the value takes more than 1000000 bytes", { form = "xml", max_bytes = 1000000 })
  unwritable(value, "the value takes more than 20000 bytes", { max_bytes = 20000 })
  assert(written(value, { max_bytes = #binary }) == binary)
  unwritable(value, "the value takes more than", { max_bytes = #binary - 1 })
  local small = Plist.array({ Plist.string("a"), Plist.string("b") })
  local small_xml = written(small, { form = "xml" })
  assert(written(small, { form = "xml", max_bytes = #small_xml }) == small_xml)
  unwritable(small, "the value takes more than", { form = "xml", max_bytes = #small_xml - 1 })
end

local function test_a_value_that_holds_itself_is_not_written()
  local items: mut {Plist.Value} = {}
  local loop = Plist.array(items)
  items[1] = loop
  unwritable(loop, "an array or a dict holds itself")
  unwritable(loop, "an array or a dict holds itself", { form = "xml" })
  local entries: mut {Plist.Entry} = {}
  local dict = Plist.dict(entries)
  entries[1] = { key = "again", value = Plist.array({ dict }) }
  unwritable(dict, "an array or a dict holds itself")
  unwritable(dict, "an array or a dict holds itself", { form = "xml" })
end
