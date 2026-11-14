--- Proves [`cosmic.srp`] against RFC 5054's appendix B, against what the
--- Python library `srptools` 2.0.0 computes, and against a reference
--- written for these tests from the rules as [`Srp.Rules`] states them,
--- with Python's `hashlib` and `pow` alone. The reference agrees with
--- appendix B on k, x, v, A, B, u and the premaster secret, and with
--- `srptools` on every value of its vectors. Every answer is embedded as
--- hexadecimal. The tests also prove each group against itself, and
--- every refusal and raise.

local Bigint = require("cosmic.bigint")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Srp = require("cosmic.srp")
local Test = require("cosmic.test")

--- The bytes hexadecimal digits spell.
local function n(hex: string): string
  return (assert(Codec.unhex(hex)))
end

local record Vector
  parameters: Srp.Parameters
  identity: string
  password: string
  salt: string
  client_secret: string
  server_secret: string
  verifier: string
  client_public: string
  server_public: string
  key: string
  client_proof: string
  server_proof: string
end

--- The 1024-bit prime with a generator, 198, whose SHA-256 has the first
--- byte of the prime's: `HN xor Hg` leads with a zero byte, which no
--- group of the RFC's does under a hash here.
local odd_generator: Srp.Group = { prime = Srp.group_1024.prime, generator = "\198" }

-- RFC 5054 appendix B: its I, P, s, a, b, v, A and B. The key and the proofs are the reference's.
local rfc5054_appendix_b: Vector = {
  parameters = { group = Srp.group_1024, hash = "sha1", rules = "rfc5054" },
  identity = "alice",
  password = "password123",
  salt = n("beb25379d1a8581eb5a727673a2441ee"),
  client_secret = n("60975527035cf2ad1989806f0407210bc81edc04e2762a56afd529ddda2d4393"),
  server_secret = n("e487cb59d31ac550471e81f00f6928e01dda08e974a004f49e61f5d105284d20"),
  verifier = n(
    "7e273de8696ffc4f4e337d05b4b375beb0dde1569e8fa00a9886d8129bada1f1822223ca1a605b530e379ba4729fdc59" ..
      "f105b4787e5186f5c671085a1447b52a48cf1970b4fb6f8400bbf4cebfbb168152e08ab5ea53d15c1aff87b2b9da6e04" ..
      "e058ad51cc72bfc9033b564e26480d78e955a5e29e7ab245db2be315e2099afb"
  ),
  client_public = n(
    "61d5e490f6f1b79547b0704c436f523dd0e560f0c64115bb72557ec44352e8903211c04692272d8b2d1a5358a2cf1b6e" ..
      "0bfcf99f921530ec8e39356179eae45e42ba92aeaced825171e1e8b9af6d9c03e1327f44be087ef06530e69f66615261" ..
      "eef54073ca11cf5858f0edfdfe15efeab349ef5d76988a3672fac47b0769447b"
  ),
  server_public = n(
    "bd0c61512c692c0cb6d041fa01bb152d4916a1e77af46ae105393011baf38964dc46a0670dd125b95a981652236f99d9" ..
      "b681cbf87837ec996c6da04453728610d0c6ddb58b318885d7d82c7f8deb75ce7bd4fbaa37089e6f9c6059f388838e7a" ..
      "00030b331eb76840910440b1b27aaeaeeb4012b7d7665238a8e3fb004b117b58"
  ),
  key = n("017eefa1cefc5c2e626e21598987f31e0f1b11bb"),
  client_proof = n("3f3bc67169ea71302599cf1b0f5d408b7b65d347"),
  server_proof = n("9cab3c575a11de37d3ac1421a9f009236a48eb55"),
}

-- The reference's, for an identity whose SHA-256 leads with a zero byte, which these rules keep.
local rfc5054_hi: Vector = {
  parameters = { group = Srp.group_1024, hash = "sha256", rules = "rfc5054" },
  identity = "user159",
  password = "pw",
  salt = n("00ff"),
  client_secret = n("fb3106b1ca6e0f78d03bbf5f9b5923da41a7dfb233981593e7e701f45d2a328f"),
  server_secret = n("2230477f8f6afa6e5ed6088179412fd8cc8cae34015ca7bbf4e20d2cdc394cb9"),
  verifier = n(
    "5ec04591a5e764dbaec058fdb0ce078a693d3c2f100c5a13257c5c4b4c6836416ef6ab86f13146b57c6b1ef119306fc7" ..
      "8c4d9f6dc6354d4a60cf0867b8e744c9d608cc2aeece7bbb6fda4eec47ef3f1ac695be4a6e61d7aa43b8a8e003f52c7f" ..
      "c3094fc0303db2ee046b5785dd359c9ccd87b72d29d1c2f0b66d34a15016d8d1"
  ),
  client_public = n(
    "41dda0cc17442bfa55548e9363d23cb3f8c8b64bd9de3477420cda6674b0b355d3d9e46effb0118242fa158e3c874513" ..
      "19aa1657304bead3ea3c42b1ee12c72fb0d56f359a7838ae42f8a35c4b23ded0d6f4505d12e5d50fd4be7e50e5573628" ..
      "447a6a4249c0d27665359ba3faea7d6d08110bb6ec790531692302af8ed570b7"
  ),
  server_public = n(
    "0f4ca50f166f284621e5f92e20bd1773f7e3563f1ef064e1ae7475c19d365a830c9519ad4d2082903c60705c02ad180b" ..
      "13282a86b97a4ba7ec52a49dc56d074030aae47548e52a63f21e455667e94a971de795e7f14e1dc8d0822b74a70ab699" ..
      "b7eff6716704cc53aea75512217a2fae96c29da2d611695dbcef31841954862c"
  ),
  key = n("6459eb555171246662fa080fe40f81b65383a54e8d51d062e71f20cd02073fd6"),
  client_proof = n("f31df529fe2c4db07f9458656a4c86151d22a230007c3848e58c976f2b34b2c6"),
  server_proof = n("7411121bba1560c27aadcd8db7677e4738345e3f5a1dc12770e4444b8224351f"),
}

-- The reference's, in the group whose `HN xor Hg` leads with a zero byte.
local rfc5054_xor: Vector = {
  parameters = { group = odd_generator, hash = "sha256", rules = "rfc5054" },
  identity = "alice",
  password = "password123",
  salt = n("0001"),
  client_secret = n("82daf9d18488d2d85900caa77b2b3978fd8853fc567f1852548e8d5976fc17f0"),
  server_secret = n("216deba6d4c163347701708cf9e20766ac60b2ea32e8147e6f7550fd86b841e4"),
  verifier = n(
    "8c113f00c430c93ba0045b24088f6bdaec19c725d7d26e69c1a9706377d05e78a159dfd25e5a65c76042335d566d0e7e" ..
      "4428bf83af39448963055d6df67733634d0aec070f8d82fb35229f49f2a3d31560ce3be1fb3c27016ae6ed9f49fec972" ..
      "084f19a7a0ce5a3928334cd04c82c27ab15b786a467727ca3a4f6471e1765461"
  ),
  client_public = n(
    "106fcda0e68a743970664bba575dd3b1972325398441f23790984475cf80772be696e557e4ca45745adc8a83c2a79134" ..
      "9f4b7b7315b3fb2c9dfe5f2c6f5679b52cc6df0579fbc976eeffc8f24d528b14bc30c22c904dc34aedce89d7c6200c5b" ..
      "dbdeb444cfc3883f8369e3277aec47019984ae7f33484a78c6daa723b8e85ee3"
  ),
  server_public = n(
    "4347db3929d18648ab55a52547b48ec109496e8a30d98eefceba3448ce8ee3ebbbb61e302804950657fa0d6e4f174afc" ..
      "e33d9a0b3d6fe4fd5d673db7b002801365662837c9665ccccfeb625819348ad9e554c6ac6099d6c88d1b160ec396fae1" ..
      "956063579cb86daeaf86df0a4d9f70f16a3495d507c2ad4ee23de70a87d0de5e"
  ),
  key = n("e6b86e6757daba06b2f4b81cc300b70066ed9b5f46a8939062015978d1323cd3"),
  client_proof = n("0113956ffd5740b2606785d03083ae0f6d11d86231b06e9f97a169fa4d1e80c8"),
  server_proof = n("8ed3c668d28b6c57a8748792c932e03b35f627295952984901829c3c2eea88d2"),
}

-- srptools's: a salt and an A that lead with a zero byte.
local srptools_salt_and_A: Vector = {
  parameters = { group = Srp.group_3072, hash = "sha512", rules = "srptools" },
  identity = "alice",
  password = "password123",
  salt = n("0063479ad69a090b258277ec8fba6f99"),
  client_secret = n(
    "f89320b641ab97f7b642c6491f8cd7a39d47f8499433d9184cd43ea4ada0ab6be2df4514e892e381bca1e70f66f235e5" ..
      "4b0f969bef0e2e8233f9cdff2b1c81c6"
  ),
  server_secret = n(
    "d39d5b33398e566759f39f0e17e3a45234494dcef4cc7ff75f0c4e5b2f055fc5190041b4a93410c549923ec5577e20a8" ..
      "54e71e3f22306223decc04b47ca63f9b"
  ),
  verifier = n(
    "e40515a6c9d59de6ae52916fbac02d21a8fa9e4ba44096ca0c21e1a37004e611c2c60d0a2bc992e45a43edab1926e008" ..
      "106856e259c7c11b7ecc7e1c9d06032e26038ba84e84e907067e798bd43d4610107e0123745a8c4638c0e02a8936747b" ..
      "f01cf4728364d45e813531e9e7474faa87e534931bdc1f2126520166fc875ea2ce49499eb7e290c3bafa9fb8d1f0d029" ..
      "6ece975073179b1b2abfb2d5f598571e76a7805fec05234f43b1b41c147fb32f579a4e8c56e86a5249771493cecf490b" ..
      "36f278533bc2c4f8bb3f9efa9d0997689c371da08da8ba35f779a3fd84697efb8bf07afbeb1ed5fa787ea19dc1887b71" ..
      "c01190e07b4c556f3cc11783ca54a05ea320a7650067b82b76f083af4596f5a7105ef771e478b361b73a2911d036cd39" ..
      "fb709697848a4bef863775fd15b6331b0bf1953c4d3bbe2a7191001ba38df3d8a299badf0cbb59d066ac76202c11cca9" ..
      "ffc1f5a4838a69132a3e966a2ee561b872eecbbfa2602663ff48cde25ef13c27c1a3324649b2462dcbe0bc5003d3110d"
  ),
  client_public = n(
    "00988961504da2fe8b26348cd73de78680dcba16cc49f8071593ab6afb5498c801034dac1cdc23a3ef0303787d0cc94a" ..
      "12e60150acb97cf6e3e5041f5829977dea373f86fe949a15e0af3ad28bbea57c8e17d5b93fcf1b3e705db909344e6d34" ..
      "eca8fef4af06389e2e01357d07602539956c076242f3177bfac9be1498efdfe0308033cbf45adc3b5663999d86c7c02a" ..
      "8a8a5f56c9756068fa45e7130d9363bf7466e08828d36941ea838bdf4411145b55071fcf9149ce40e2add1b2dc0cf832" ..
      "d5cfa84018f7dc11422b7a2558a88508635f2fa774577b87a8c2109e4b3c6fdd8ee2de4ec623e0e9c27206fa7a627140" ..
      "f3b2daa4f9b2b870bd204b14dde39ca5b405cdb8d7535af73e54a674a53d074e7c23f0270d3c38fb5ded0597fd650f6a" ..
      "0a0d65ac36df77eefb26f571afc8654be47de291982a09b630f9246ad0859d595e2322f3472780287ed13516d172ead6" ..
      "787c250c5d0a502e594e257cce07d395589907c0b0c95e45107b4073cff0b2f3dc05b5e646b69a089b3f8d3bfa6ec6bb"
  ),
  server_public = n(
    "abfe87f64b21272c92d6956478dafb8d930f3fba15039cf865798581ebb92e05eed7946ea57a298ca53a526e998948f0" ..
      "3deab84acbda91229e2f8acb883dccf3b1480c4c7977e5a8982b5ab0d8229c2f4b61cefb5691b7348a21c14b639ec347" ..
      "1596485ff6cdcda709704b93777d5147d9c39694b8241d539fb4033c84f4ea1490443cf018ca39b7966090d75a129364" ..
      "6b56ad4eafcd4df6b5a162ebdb27baa5b9f73c82c36adc1985989dafefbc516c50066501b35315b248d55cd1b43d9e58" ..
      "b2ece1843dc40d62506fbd6ca95803810f18b98e2fd0ea2679b78435575c721eb0e2882ccd8c4a1f38cc1fb03c5126f2" ..
      "7cab65383229e4f170d78403f1ba2a18ac0e94607a4640cecd28ed23c2df56a571734b12adb7560cdf1b9832cf3ff7bc" ..
      "37ea62cc2affa673f17778180ac0315ceb190a73463f3685d3b39ff8681d534dbda40e0133026bff212d2eee94ed7375" ..
      "251e3dfb70b2c75ec0fc59979eb16e7309be9fac10f0f1a123c7fc1b14e36c7d71525154eaf7e18d19b2f6deb817fc95"
  ),
  key = n(
    "07b7062aaf42e24f6c29c4d885e10ddea0eac4dba2f8cdac1c888634736025f8cc12fa52a3f53ecc33729fd71f334052" ..
      "46bf45f876887e75ba4285aa01b9a793"
  ),
  client_proof = n(
    "ecfed0a947ae478d79a1507e78056664ae2aa2e39f6ba5186f3ccd10b1b1719e59b77c1738a5edfeea5ef414a3d70fc3" ..
      "f705d9b0f87c424ac183139baa733e11"
  ),
  server_proof = n(
    "a02ba30c9ee23f03bd40366668e3cbec703007a8ae4155e9b82b2b89d6f93e1edd213c9dd5b8a8f0f027505ba90e89b2" ..
      "da5313f8eacc06df15f39ebb3ac00525"
  ),
}

-- srptools's: an identity whose SHA-512 leads with a zero byte, and a B and an S that do.
local srptools_hi_B_and_S: Vector = {
  parameters = { group = Srp.group_3072, hash = "sha512", rules = "srptools" },
  identity = "user396",
  password = "correct horse",
  salt = n("c3a6a8530dbb478fb70a6ca8c7263a94"),
  client_secret = n(
    "47c2a6e8e3f30f80b93a3e37ce1456cc34cfb0b92dc39f90e111bdb9be8fb9f6645639a60eab7a5d11337cfd07423322" ..
      "a5b15c0694b21d0069a5811112b6a7c1"
  ),
  server_secret = n(
    "365a601a8c31435f62389945126cec6eb7b5b9a524cb0968e01175936868c4bc3a644fd5691d1bca7ff3e842d307b187" ..
      "3f8efaeee215624ca0712ca9ed1bbd1b"
  ),
  verifier = n(
    "098c0d61cf6f2dc4850e0c5234ead2226f28e4b0b2ba9932a7347b582aabbe5a54f9e32a30cb533cfc4ab99120926a7e" ..
      "6f38085fdc00c6ce827d1f421e3d6b30f4550d49ef7499d17a088f8a2e978e49cecabcc4e1a7a48ba8657382bf0928e2" ..
      "bd0a8db534db3fbf05ce4db034c6b58574c839a06f4f3b93bd848e469c1b7475b7fd2acf4b1fc6868cd6622e7f826fd2" ..
      "58ad4a42337bf866842966af03cf7cb5c75acb18b45d1c6701400f707b2f651e7972cbcff6ecabd2f3fa962bd1815c6f" ..
      "8b3af88c06aa8ed1ce32089133fefe24ded439d97923d9f48a0462851fae18dc78f092b533615627da3de1e94365f77f" ..
      "6664880233ee70315dff9d2d527805337764e98b3e2e644d09eb39c0568069f5dc8e29bb17cc2d5c1b8395488ce366dd" ..
      "7d76e6f060eef0a3df0fc467d7d708f6ccc743a7248e552dde9ea65706d1a951e0624c310565c216dfe77081eca8cba7" ..
      "06c13f3dd604b3e46c61d53c95c6ebd1d326427a5d297a9081f33d9a429e1e03497ee49e5171d10e865b41447d7a9e93"
  ),
  client_public = n(
    "63990f49f98e345ab827c429285c50b4efc9ef058ab28872aff716118e0f87a930e5195a7ab8de23c158e66812da845d" ..
      "6897565c7fdd53b5bc8035ba9de74b3da09ee9213dedfd84c0f131fc46069fd2ebb389b33548eb90e15ba4b65205a943" ..
      "d95e11034ff56d4b9585f9fbbcc2ac9d5cedecf0800e5489c8456e631181a37434503961c631b38886d494d144cbd94c" ..
      "b18478233e1f16ac4880bd4f4a84e3743ff49a7aa887839a8a31d835743a66990152fd89f5b794e03ba95f1ebe3a7eb1" ..
      "32893e9c43f37fa2f3ad9ffe2d77bfc8e31de56210624b275ef5eeb3d7202a3f0fdb82bfeb1ebef1adde040d3cbf46d2" ..
      "037101755cefde1c11b18bc1749222c3c92b7b6d02a7f8f3793587cbaf8dc85978882d75d65edbb3be0893f52f0c190f" ..
      "c9442b78832bffa56459f996ebee952228339f2f313c9e755a620b0d1cd098d79c512f2159d1721ef500f174a470ad52" ..
      "bee7b3cf33e718ff359eea6be01e820ab424a9aed785b028c7231c3f68d7de8e5504406d38895bb0c0ed327c8dafc82b"
  ),
  server_public = n(
    "00f1b2ccf8858731ec4e8e1dc2dec301fc104b3a8387dc514f290888b98d5b62e84318984c7807f95958bc947711c015" ..
      "645350b88f52c06fb3f5a7fb9f0e4cce27fa858366faa5f4baf11543a06a38d1205a8369faf2d997356ca242c6685d19" ..
      "a3b9751a0b27e17031e8b40d78f45305150f1d5d1b32673e0a1d3f25370ac2bd2b30c96523e56b032f0b8c81e265974f" ..
      "6f55d29610f3fcfa3551631a7ff3b4ceadd3f80cc3bf14a52b220a40c9d7569213ab0416df728e5935a2c1f7706a91cc" ..
      "e2edfaea32b4128089bfdb627df64a1c58e78985221315d79ad3bac7e79a63eaddb2d72391d7ad9adfe426aa12338039" ..
      "d2cace96d36380bff1d693d79f1128105248c3af7f780229d9a9a2bedb0952baaf44e9e61ce14bbfcc29015b327354a2" ..
      "f1d9e865f5a93863bd0780972bc130710f55d43dc9b352db0e527c21b8d4e0ac1c62cce76f130d1539c07e6a9612e5c7" ..
      "ea4416329e1f9255f230badb6a3af92bc98e25d262774a3b6edee21fb2eee374ca9670bee198878bd00a05251ae72897"
  ),
  key = n(
    "5ee8d7813e33afc17fe3a26942f274d8940c532e661d7bcace324b75694d5f844e5e2b80c259d208a4d71e7e192831c0" ..
      "8ebbf7efaf839ed77d944955d8251424"
  ),
  client_proof = n(
    "b9641b255324dea650212e8fc9ab5367a86f130fc6c16e140192b2ef2b0f53d85482b11c6024b48dc369cfbed0082dfb" ..
      "000e15718d4aa9444e07b873883fd0ce"
  ),
  server_proof = n(
    "5a50756c5f560176eba453f6caa4af9ca14f768003b99b331601be5e5f6d89403e1da67a5fae44cebe081e918db98ab9" ..
      "3cae062949f38cd83854711660e5829e"
  ),
}

-- srptools's, for the inputs of `rfc5054_hi`: the key is the same and the proofs are not.
local srptools_hi_1024: Vector = {
  parameters = { group = Srp.group_1024, hash = "sha256", rules = "srptools" },
  identity = "user159",
  password = "pw",
  salt = n("00ff"),
  client_secret = n("fb3106b1ca6e0f78d03bbf5f9b5923da41a7dfb233981593e7e701f45d2a328f"),
  server_secret = n("2230477f8f6afa6e5ed6088179412fd8cc8cae34015ca7bbf4e20d2cdc394cb9"),
  verifier = n(
    "5ec04591a5e764dbaec058fdb0ce078a693d3c2f100c5a13257c5c4b4c6836416ef6ab86f13146b57c6b1ef119306fc7" ..
      "8c4d9f6dc6354d4a60cf0867b8e744c9d608cc2aeece7bbb6fda4eec47ef3f1ac695be4a6e61d7aa43b8a8e003f52c7f" ..
      "c3094fc0303db2ee046b5785dd359c9ccd87b72d29d1c2f0b66d34a15016d8d1"
  ),
  client_public = n(
    "41dda0cc17442bfa55548e9363d23cb3f8c8b64bd9de3477420cda6674b0b355d3d9e46effb0118242fa158e3c874513" ..
      "19aa1657304bead3ea3c42b1ee12c72fb0d56f359a7838ae42f8a35c4b23ded0d6f4505d12e5d50fd4be7e50e5573628" ..
      "447a6a4249c0d27665359ba3faea7d6d08110bb6ec790531692302af8ed570b7"
  ),
  server_public = n(
    "0f4ca50f166f284621e5f92e20bd1773f7e3563f1ef064e1ae7475c19d365a830c9519ad4d2082903c60705c02ad180b" ..
      "13282a86b97a4ba7ec52a49dc56d074030aae47548e52a63f21e455667e94a971de795e7f14e1dc8d0822b74a70ab699" ..
      "b7eff6716704cc53aea75512217a2fae96c29da2d611695dbcef31841954862c"
  ),
  key = n("6459eb555171246662fa080fe40f81b65383a54e8d51d062e71f20cd02073fd6"),
  client_proof = n("395a1cc79a9fa4ea5745c280da4b60c7ae49b7f5c2a4527fa4f754d1c02042c7"),
  server_proof = n("1af6727432953d2d59a9c35a7c2be6e1be8e5b06036151b7f205685aec796985"),
}

-- srptools's, for the inputs of `rfc5054_xor`.
local srptools_xor: Vector = {
  parameters = { group = odd_generator, hash = "sha256", rules = "srptools" },
  identity = "alice",
  password = "password123",
  salt = n("0001"),
  client_secret = n("82daf9d18488d2d85900caa77b2b3978fd8853fc567f1852548e8d5976fc17f0"),
  server_secret = n("216deba6d4c163347701708cf9e20766ac60b2ea32e8147e6f7550fd86b841e4"),
  verifier = n(
    "8c113f00c430c93ba0045b24088f6bdaec19c725d7d26e69c1a9706377d05e78a159dfd25e5a65c76042335d566d0e7e" ..
      "4428bf83af39448963055d6df67733634d0aec070f8d82fb35229f49f2a3d31560ce3be1fb3c27016ae6ed9f49fec972" ..
      "084f19a7a0ce5a3928334cd04c82c27ab15b786a467727ca3a4f6471e1765461"
  ),
  client_public = n(
    "106fcda0e68a743970664bba575dd3b1972325398441f23790984475cf80772be696e557e4ca45745adc8a83c2a79134" ..
      "9f4b7b7315b3fb2c9dfe5f2c6f5679b52cc6df0579fbc976eeffc8f24d528b14bc30c22c904dc34aedce89d7c6200c5b" ..
      "dbdeb444cfc3883f8369e3277aec47019984ae7f33484a78c6daa723b8e85ee3"
  ),
  server_public = n(
    "4347db3929d18648ab55a52547b48ec109496e8a30d98eefceba3448ce8ee3ebbbb61e302804950657fa0d6e4f174afc" ..
      "e33d9a0b3d6fe4fd5d673db7b002801365662837c9665ccccfeb625819348ad9e554c6ac6099d6c88d1b160ec396fae1" ..
      "956063579cb86daeaf86df0a4d9f70f16a3495d507c2ad4ee23de70a87d0de5e"
  ),
  key = n("e6b86e6757daba06b2f4b81cc300b70066ed9b5f46a8939062015978d1323cd3"),
  client_proof = n("90334a2aa75c9c806b2ab17c05f5c08202e67f706dcdbb9afee686038874d6fb"),
  server_proof = n("fd2ad4025acaa6d89814d95023868b444ad9fc40d073ac7bd9fb576f949b7a3d"),
}

--- Runs the login of `v` from both sides and compares every value with
--- the vector's.
local function follows(v: Vector)
  local verifier = Srp.verifier(v.parameters, v.identity, v.password, v.salt)
  assert(Codec.hex(verifier) == Codec.hex(v.verifier))
  local client = Srp.client(v.parameters, v.identity, v.password, v.client_secret)
  local server = Srp.server(v.parameters, v.identity, v.salt, verifier, v.server_secret)
  assert(Codec.hex(client.public) == Codec.hex(v.client_public))
  assert(Codec.hex(server.public) == Codec.hex(v.server_public))
  local login, why = client:prove(v.salt, server.public)
  assert(login ~= nil, why)
  assert(Codec.hex(login.key) == Codec.hex(v.key))
  assert(Codec.hex(login.proof) == Codec.hex(v.client_proof))
  local session, refusal = server:verify(client.public, login.proof)
  assert(session ~= nil, refusal)
  assert(Codec.hex(session.key) == Codec.hex(v.key))
  assert(Codec.hex(session.proof) == Codec.hex(v.server_proof))
  assert(client:verify(session.proof))
end

local function test_the_rfc_rules_match_rfc_5054_appendix_b()
  local v = rfc5054_appendix_b
  follows(v)
  local premaster = n(
    "b0dc82babcf30674ae450c0287745e7990a3381f63b387aaf271a10d233861e359b48220f7c4693c9ae12b0a6f67809f" ..
      "0876e2d013800d6c41bb59b6d5979b5c00a172b4a2a5903a0bdcaf8a709585eb2afafa8f3499b200210dcc1f10eb3394" ..
      "3cd67fc88a2f39a4be5bec4ec0a3212dc346d7e474b29ede8a469ffeca686e5a"
  )
  assert(Codec.hex(v.key) == Codec.hex(Hash.digest("sha1", premaster)))
end

local function test_the_rfc_rules_keep_a_digest_that_leads_with_zero()
  assert(Hash.digest("sha256", rfc5054_hi.identity):byte(1) == 0)
  follows(rfc5054_hi)
  follows(rfc5054_xor)
end

local function test_the_srptools_rules_match_srptools_for_a_salt_and_an_a_that_lead_with_zero()
  local v = srptools_salt_and_A
  assert(v.salt:byte(1) == 0 and v.client_public:byte(1) == 0)
  follows(v)
end

local function test_the_srptools_rules_match_srptools_for_an_identity_a_b_and_an_s_that_lead_with_zero()
  local v = srptools_hi_B_and_S
  assert(Hash.digest("sha512", v.identity):byte(1) == 0 and v.server_public:byte(1) == 0)
  follows(v)
end

local function test_the_srptools_rules_strip_a_digest_that_leads_with_zero()
  follows(srptools_hi_1024)
  follows(srptools_xor)
  assert(srptools_hi_1024.key == rfc5054_hi.key and srptools_hi_1024.client_proof ~= rfc5054_hi.client_proof)
  assert(srptools_xor.key == rfc5054_xor.key and srptools_xor.client_proof ~= rfc5054_xor.client_proof)
end

local small: Srp.Parameters = { group = Srp.group_1024, hash = "sha256", rules = "rfc5054" }

--- A login under `parameters` with fresh secrets, which must end with
--- one key on both sides.
local function logs_in(parameters: Srp.Parameters)
  local salt = "\0salt"
  local verifier = Srp.verifier(parameters, "alice", "password123", salt)
  assert(#verifier == #parameters.group.prime)
  local client = Srp.client(parameters, "alice", "password123")
  local server = Srp.server(parameters, "alice", salt, verifier)
  assert(#client.public == #parameters.group.prime and #server.public == #parameters.group.prime)
  local login, why = client:prove(salt, server.public)
  assert(login ~= nil, why)
  local session, refusal = server:verify(client.public, login.proof)
  assert(session ~= nil, refusal)
  assert(session.key == login.key and client:verify(session.proof))
  assert(session.proof ~= login.proof)
end

local function test_a_client_logs_in_to_a_server_in_the_groups_to_3072_bits()
  for _, group in ipairs({ Srp.group_1024, Srp.group_1536, Srp.group_2048, Srp.group_3072 }) do
    logs_in({ group = group, hash = "sha256", rules = "rfc5054" })
  end
end

local function test_a_client_logs_in_to_a_server_in_the_4096_bit_group()
  logs_in({ group = Srp.group_4096, hash = "sha512", rules = "srptools" })
end

local function test_a_client_logs_in_to_a_server_in_the_6144_bit_group()
  logs_in({ group = Srp.group_6144, hash = "sha384", rules = "rfc5054" })
end

local function test_a_client_logs_in_to_a_server_in_the_8192_bit_group()
  logs_in({ group = Srp.group_8192, hash = "sha512", rules = "rfc5054" })
end

local function test_the_groups_are_the_widths_they_are_named_for()
  local widths: {integer: Srp.Group} = {
    [1024] = Srp.group_1024,
    [1536] = Srp.group_1536,
    [2048] = Srp.group_2048,
    [3072] = Srp.group_3072,
    [4096] = Srp.group_4096,
    [6144] = Srp.group_6144,
    [8192] = Srp.group_8192,
  }
  for bits, group in pairs(widths) do
    assert(#group.prime * 8 == bits and assert(group.prime:byte(1)) >= 128, tostring(bits))
  end
  assert(Srp.group_1024.generator == "\2" and Srp.group_3072.generator == "\5")
  assert(Srp.group_8192.generator == "\19")
end

local function test_each_login_draws_secrets_of_its_own()
  local verifier = Srp.verifier(small, "alice", "password123", "salt")
  assert(Srp.client(small, "alice", "password123").public ~= Srp.client(small, "alice", "password123").public)
  assert(Srp.server(small, "alice", "salt", verifier).public ~= Srp.server(small, "alice", "salt", verifier).public)
end

--- One side of a login under `small`, with fixed secrets.
local function sides(password?: string): Srp.Client, Srp.Server
  local verifier = Srp.verifier(small, "alice", "password123", "salt")
  return Srp.client(small, "alice", password or "password123", string.rep("a", 32)),
    Srp.server(small, "alice", "salt", verifier, string.rep("b", 32))
end

local function test_a_server_refuses_a_wrong_password()
  local client, server = sides("password124")
  local login = assert(client:prove("salt", server.public))
  local session, why = server:verify(client.public, login.proof)
  assert(session == nil and why == "srp: the client's proof is wrong")
end

local function test_a_server_refuses_another_identity_or_salt_and_a_changed_proof()
  local _, server = sides()
  local stranger = Srp.client(small, "alicf", "password123", string.rep("a", 32))
  assert(server:verify(stranger.public, assert(stranger:prove("salt", server.public)).proof) == nil)
  local client = sides()
  assert(server:verify(client.public, assert(client:prove("salu", server.public)).proof) == nil)
  local proof = assert(client:prove("salt", server.public)).proof
  local changed = proof:sub(1, -2) .. string.char(assert(proof:byte(-1)) ~ 1)
  for _, wrong in ipairs({ changed, "", proof:sub(1, -2), proof .. "\0" }) do
    assert(server:verify(client.public, wrong) == nil)
  end
  assert(server:verify(client.public, proof) ~= nil)
end

local function test_a_client_refuses_a_server_that_does_not_hold_the_verifier()
  local client = sides()
  local other = Srp.verifier(small, "alice", "another password", "salt")
  local impostor = Srp.server(small, "alice", "salt", other, string.rep("b", 32))
  local login = assert(client:prove("salt", impostor.public))
  assert(impostor:verify(client.public, login.proof) == nil)
  assert(not client:verify(login.proof))
  assert(not client:verify(""))
  local _, server = sides()
  local genuine = assert(client:prove("salt", server.public))
  local session = assert(server:verify(client.public, genuine.proof))
  assert(not client:verify(session.proof:sub(1, -2)))
  assert(client:verify(session.proof))
end

--- The public values a peer could send to choose the key: zero modulo
--- the prime, in any spelling, and anything not below the prime.
local function degenerate(): {string}
  local prime = small.group.prime
  return {
    "",
    "\0",
    string.rep("\0", #prime),
    prime,
    "\0\0" .. prime,
    Bigint.add(prime, prime),
    Bigint.add(prime, "\1"),
    string.rep("\255", #prime),
    string.rep("\255", Bigint.operand_bytes + 1),
  }
end

local function test_a_client_refuses_each_degenerate_public_value()
  local client = sides()
  for i, public in ipairs(degenerate()) do
    local login, why = client:prove("salt", public)
    assert(login == nil and why == "srp: the server's public value is not from 1 to the prime less 1", tostring(i))
  end
  Test.raises(function() client:verify("") end, "after prove")
end

local function test_a_server_refuses_each_degenerate_public_value()
  local client, server = sides()
  local login = assert(client:prove("salt", server.public))
  for i, public in ipairs(degenerate()) do
    local session, why = server:verify(public, login.proof)
    assert(session == nil and why == "srp: the client's public value is not from 1 to the prime less 1", tostring(i))
  end
  assert(server:verify(client.public, login.proof) ~= nil)
end

local function test_a_public_value_with_leading_zero_bytes_is_the_same_number()
  local client, server = sides()
  local login = assert(client:prove("salt", "\0\0\0" .. server.public))
  assert(login.proof == assert(sides():prove("salt", server.public)).proof)
  local session = assert(server:verify("\0" .. client.public, login.proof))
  assert(client:verify(session.proof))
  local short = Srp.server(small, "alice", "salt", "\0\0\7", string.rep("b", 32))
  assert(short.public == Srp.server(small, "alice", "salt", "\7", string.rep("b", 32)).public)
end

--- SHA-256, except that the digest of two numbers at the prime's width
--- is zero unless the prime is the first: that leaves `k` and makes `u`
--- zero.
local function zero_scrambler(data: string): string
  local prime = small.group.prime
  if #data == 2 * #prime and data:sub(1, #prime) ~= prime then return string.rep("\0", 32) end
  return Hash.digest("sha256", data)
end

local function test_both_sides_refuse_a_scrambling_value_of_zero()
  local rigged: Srp.Parameters = { group = small.group, hash = zero_scrambler, rules = "rfc5054" }
  local verifier = Srp.verifier(rigged, "alice", "password123", "salt")
  assert(verifier == Srp.verifier(small, "alice", "password123", "salt"))
  local client = Srp.client(rigged, "alice", "password123")
  local server = Srp.server(rigged, "alice", "salt", verifier)
  local login, why = client:prove("salt", server.public)
  assert(login == nil and why == "srp: the scrambling value is zero")
  local session, refusal = server:verify(client.public, string.rep("\0", 32))
  assert(session == nil and refusal == "srp: the scrambling value is zero")
end

local function test_a_hash_given_as_a_function_computes_what_its_name_does()
  local by_function: Srp.Parameters = {
    group = small.group,
    hash = function(data: string): string return Hash.digest("sha256", data) end,
    rules = "rfc5054",
  }
  local client = Srp.client(by_function, "alice", "password123", string.rep("a", 32))
  local named, server = sides()
  assert(client.public == named.public)
  assert(assert(client:prove("salt", server.public)).proof == assert(named:prove("salt", server.public)).proof)
end

local function test_a_secret_must_be_a_number_an_exponent_can_be()
  local verifier = Srp.verifier(small, "alice", "password123", "salt")
  for _, secret in ipairs({ "", "\0", string.rep("\0", 32), string.rep("a", 513) }) do
    Test.raises(function() Srp.client(small, "alice", "password123", secret) end, "secret")
    Test.raises(function() Srp.server(small, "alice", "salt", verifier, secret) end, "secret")
  end
  local widest = string.rep("\255", 512)
  local client = Srp.client(small, "alice", "password123", widest)
  local server = Srp.server(small, "alice", "salt", verifier, widest)
  local login = assert(client:prove("salt", server.public))
  assert(assert(server:verify(client.public, login.proof)).key == login.key)
end

local function test_a_server_raises_on_a_verifier_that_is_no_verifier()
  local prime = small.group.prime
  for _, verifier in ipairs({ "", "\0", prime, Bigint.add(prime, "\1"), string.rep("\255", 4096) }) do
    Test.raises(function() Srp.server(small, "alice", "salt", verifier) end, "verifier")
  end
end

local function test_a_group_that_cannot_be_computed_with_raises()
  local prime = small.group.prime
  local bad: {string: Srp.Group} = {
    even = { prime = prime:sub(1, -2) .. "\0", generator = "\2" },
    longer = { prime = string.rep("\255", Bigint.modulus_bytes + 1), generator = "\2" },
    generator = { prime = prime, generator = "\1" },
  }
  for word, group in pairs(bad) do
    local parameters: Srp.Parameters = { group = group, hash = "sha256", rules = "rfc5054" }
    Test.raises(function() Srp.verifier(parameters, "alice", "password123", "salt") end, word)
    Test.raises(function() Srp.client(parameters, "alice", "password123") end, word)
    Test.raises(function() Srp.server(parameters, "alice", "salt", "\7") end, word)
  end
  for _, generator in ipairs({ "", "\0", prime, string.rep("\255", #prime + 1) }) do
    local parameters: Srp.Parameters = {
      group = { prime = prime, generator = generator },
      hash = "sha256",
      rules = "rfc5054",
    }
    Test.raises(function() Srp.client(parameters, "alice", "password123") end, "generator")
  end
end
