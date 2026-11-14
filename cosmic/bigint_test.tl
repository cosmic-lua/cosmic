--- Proves [`cosmic.bigint`] against values worked by hand and against
--- Python's integers (`pow(b, e, m)`, `*`, `%`), whose answers are
--- embedded as hexadecimal: every operation, the edges of each, and every
--- refusal and raise.
---
--- The functions for secrets are proved to compute the right numbers at
--- the right widths, and nothing here times them: a test must not depend
--- on the host's speed. That their time is fixed by lengths rests on the
--- guarantees mbedtls documents for the functions core/bigint.c calls,
--- and on reading that file, not on a measurement.

local Bigint = require("cosmic.bigint")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

--- The number hexadecimal digits spell.
local function n(hex: string): string
  return (assert(Codec.unhex(hex)))
end

-- The secp256k1 field prime, the 2048-bit prime of RFC 3526 (group 14)
-- and its 3072-bit prime (group 15), which RFC 5054 uses with the
-- generator 5.
local p256 = n("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")
local p2048 = n(
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" ..
    "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" ..
    "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" ..
    "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ..
    "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" ..
    "15728e5a8aacaa68ffffffffffffffff"
)
local p3072 = n(
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" ..
    "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" ..
    "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" ..
    "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ..
    "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" ..
    "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7" ..
    "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c" ..
    "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff"
)
local v256_base = n("236c4216356fc531cbbe09171e330c1f765bc4c50decb48287e188208e903ee8")
local v256_exponent = n("3c29ac9cc4d8d68f431d663b5b3478d94a813015aba69084238df3b89d50542b")
local v256_power = n("8ace389d549bd8951c0be82737218aacdea0b9589add790de749903626523e81")
local v2048_exponent = n(
  "1c58ec36b6dc3d4b86c27555ccc5f2f6cbe9517d669275555b8bab74e7664faeeb73d190ceab8371e13ba2e8f4b92abf" ..
    "04518c1e481ac0534735f438d0877dcd66d70156b5e1c288939b7c7d9141d119ac4300d00ec00ef139962a8f5bd3a52a" ..
    "92174f9191fdcf965cf013be5c974c7745b5a49e29d589ac8e4b590ed13692c4892a0f4143fdadf30727e087f7d9608f" ..
    "af9a9c95a4c7ce2ef563005b950de9766a7f000daa2c9d7f65dc3109b3b0312455c5ae8de88535dbf520a98129ed0e11" ..
    "753a45e210cc63e2881c62692ace759e6dcd281494fc7c1fa45e24f0585174e37020a4d013c6fb748de9e79db9944f20" ..
    "9de8c2d18e5efb2812dc3fb214dad23c"
)
local v2048_power = n(
  "1397b455d05b2f52f03c5d691185d89d14229dc8002bc00f7fa66a3a155aa885e9495c3b9885b0c0ade2b99dfdbfa4a0" ..
    "d9b97d25234710705a14666782c29709a9ba5aec81e0af5a624b11e71e346cd09e6fcdf1ce42bbd0f86bed44874a451d" ..
    "26ffd583a3d213de162298689f777769159879606506e3eac737823091522e462a5dbeee804d174862fcc3b91ba72793" ..
    "a8022af83306767b29714296b4b759e6719f2ba351a7cd2fbb7c3ff3bb32b4798454b906f3e8b697d680021c8a55ef18" ..
    "a8599a111f28faa29ca927f175d95db649400d812485a524d00d4073b10450fcb894e23b7f71deb39a4c15c54918c07b" ..
    "979b8defb00342293ae0773ebcceff47"
)
local g5_exponent = n("0626dfa834d248fe451fc47fd4924295babda25f6b85f7485939cf4ab4a242dd")
local g5_power = n(
  "2c047da1e11cdeb095bc9cc9db560aa7aa3530d694d8e7305fa34bcf20ce0d74c6db362af30313d76560afd240935f6c" ..
    "9414ca5b803f79257f3a1d1bf7f7cfd3d54f5e42a3d0fbd9c2d11046741ea41f4099c9cfce44d9a44ec77fb99e9ffe6a" ..
    "f96671e8847ecb6a582fa2c32b27d68d2c5887e0dfc2daabae22ea40804d32e9e15d23ba8873de24aff0550fffd27b09" ..
    "385b54ed30fb2b75647b62f18cca239de5ebdb92caf49b4c66bd08b23b4f8bd0c44bb58d03e0f886f362a9d8a2d2673b" ..
    "47aafbdf60293756f3bb8c1c5fb865f36055f13d8ed457b9cf4ed8f15cec70f850856f4cc31c482a63cbd18c8168757c" ..
    "393a7261088ef51b62fb573101a914f72538325381c5858e3bde30aa899578b13b073710b738b1a6972c218a7c2f9acd" ..
    "10ffa4e4e58b7f72f5e325f48838abe2aefb3c5ca674de45dde531ec68d10f050e589cdc03b1aee7f6da02d59c3cf16e" ..
    "779cbcbe1eb75f09333119227af42cea9fc72ee836abe6b4d468d40a5226d4593ab279f3065eea924e6bf3bd3275de00"
)
local v3072_base = n(
  "b97ef566fdeef69b4184ae0c5298006aa98bf51ed8f7e3e5e26edf7d044ab0d072f76bbab3036269a52d572675bf0beb" ..
    "bbe75bf7746437c54615943b8b9044421a9dcc59b19cda753f30b09fa3cde51f0694341ce324dbf0c3f0813b81cb6791" ..
    "a4e38b29017488dc8aa1e36b01e0a1d4ebeaa39275f4d649e04430f8d97bd0da3bd00647deb8bd32d30126d2793e9f68" ..
    "39a1ff9763f265e8aeee0542d52a9d7e01e0e6a30eade9d1c9c606e188b1b486b081b507763474db74419dbad3fccf09" ..
    "3616c81f37c0070f6fb640ef49a8d09e16dc5a2a708fa728ead7cbebc4230e09f33ee7042fcd54f8f70d6535443a5d24" ..
    "a0b21c3bc42a45352fbe045bb1972987a6d20fe6768bcd50ebde20e843ff42286ef1b2812a3acbea5e3612975000e0f7" ..
    "5f341d4c1ef78fb34924ff18412d5c6c2cfef3d6f3e0b388e9524ca26d5964e33efb6dd6d7efe07cdc804672de27e2f5" ..
    "fb0550bca7f461c099de3f59ab3bd35b1fec0eeff8bc4e9977940194e62dcd8dee6b421c9f6a270e9ad1f61cceaddfb4"
)
local v3072_exponent = n(
  "65e8931045baa5de5db296be2c1f1bc7486cec048102927dfb79e98b670bf8d8d2da5a2ec3da4f752d02461486e1ba58" ..
    "b42129e9c560d47d8b55171a89f0d6f2a5252d5486e304d0f3cf664b686d98148aa34fa4a9812fff3bc84d4779df0662" ..
    "8841ad4b5567d8f9503fd692eb9c67f359d97853dd8f45019948139996b5eb2c8fab6496bafd10d306b04abb930a147c" ..
    "9976bd77e47bdbc9d670361074889ade27db92f6eb01462fcdd4326ae519c5103fc7ef5b2ddecc798774fe0efa3a20e9" ..
    "1c449de6a10d2bbbc30568796d173d841d1082eff06d45d678a92886a30a5e087350137558feff0c6cfab5c4fcfcdcdc" ..
    "5daba450c6cd88e88d5f3c95336f9d9ab55dba73e9aec5874457e0c1b031b2e40286fc89e1afaae744753a0f531161b2" ..
    "f3b0a1a5b6edfc7dbabc0632c02ff27ec86fdc181764fbda7b55944373a776dcebf92d9ecf6dbc3016c47b848ee442c4" ..
    "372868898b4214bd95bf968274c72d1b5363b99239374cc7fc92a18adb008e7e797677bc556d8de660f2abc17a310968"
)
local v3072_power = n(
  "7b5509fd207262894a1593b12d60c8e50cff78cbc6d749a5b8b889ef781f597cbd0e9af6490b3401d9fe5836fb7bd5d8" ..
    "bb93adeae92c58aa7ae9d668193ae52712c3077aba15b29347ef61f38d572fc300e6e5ff7d4940c610b1f83707230ee9" ..
    "2396cef78955e3fedabc617aa280df40b94471aaee2851ac6ed8e769b84108dde4aba21022bf9a33afd79a8c6eff6ef2" ..
    "7429027095975e6c4f9c4778387fe503cfa569fec2be5ac3e29942bddc5245fe858c4213dfc912718ed7884ebd9fb068" ..
    "4b4747b23b156ce4ca658a71812fdee15bf404180a78e0184912cfdb5687fcf0b0cb090359307b2461562a27a9a4cd1a" ..
    "28691dddf5c510818bb9e14d0d4d6bce06df931acd5ecf96b817d2a5bc32cb34fe6937a68e293334474c81b4cb85bf8c" ..
    "0e44a546f290160dd86993e6301a6011b7cba595b7463d931c287bfd23788323ccfdf76d0595174cf6007050182fbe88" ..
    "2e267ebb5c85db37c5294ee914a59a083442a8ef4834528f864297f099c9a4c86fb71193aabc8ece6ebf431e21e2576c"
)
local wide_base = n(
  "88c32668dd0ab51318fbce5a43c16fb8a899e2a99087d7d05c8a4117e6e778e50ec5700ae8ea6e3bdc6c4a62458fb292" ..
    "783123ae5fb4c544418b71e830ae54a6667d56e2178f0248a61ddf2f3c338d74022c559436f41250b2973dff1919349a" ..
    "991e845ed0dd394168c61c252a267793d1599092988293a447948bf05c12ea981aaee535fc60a00745c2c597af594988" ..
    "47c2d2de2ab8998a3338a3dfa777b61944d87167ec7317d6484c9093da37820755ba029028d390149717fae55bcf813e" ..
    "ce7997557d396cc1627db1d8aa1a5ce3436fa4c81b6021d3cfc6d6a5e9aa4f328cc24aed98da02b9faa5f785333b89b1" ..
    "bf54b846e51ce167429140321eb4795bed060c6ac2db2ccb84e1247dd0e8afaa9c3a4eeed8becbbf8d821492658f8357" ..
    "7e9fbe79098a728a9b8ced31ad4dd054f79218543331d468b09a67147c7f2da02313fac0f037000579be4bb95bd90521" ..
    "bebbe1b912dacba908511c8b1da930a60f1634fda9ae6bca7e226bbba4ec2bdcac61d4af8b0158fe2ef0ba22393f660c" ..
    "496c16ead6d4ff2f7a69c38cbd62d0e77f642a63a90f673722ba19f4d1940efda6042a10933b6c123086fbe980661fe2" ..
    "1fa51d03c923c047d0ec41253a6adef60f853f158833779be94875687a71826561e60e729c0005b2f84a09090d2a25ca" ..
    "c62a9bffd4a4fb4acddc3f2ecd79da0bf66b2e2733fab6e8f423c58b2ab1880f"
)
local wide_exponent = n("d6d807c64f1a5943fe1b8076d817fea6a0aa046bdc1774c446c2db9f4e79839f")
local wide_power = n(
  "67619d2aea0492e5367ec9f35d80e6f3c6557335b258cdc1ff91c4044e95177039edc2d52d6e2d1cf39f5e6e4d2687d4" ..
    "54d3f73de5f05e23f31dc6628539020de9321e7c1295886531eb8804c6e06fcf30b5cbcf7835274ba675d915d9f9deff" ..
    "21857f4647ba7c7edffec3884482731b956608e10c9ba9d078caef4febc73b84776cebd4ab468e70a4be12cf6b2ba3a0" ..
    "20926688c66dc68c1013a58ad55e1c2fc0578d55fd14c5c9f3dbfff3910099106037c3a2068c0fc2b20ad4f679e40b1b" ..
    "4076d49ef422d5744ad8a26c40a2dd4f30b32e14ab70dc043e7a267141c53485b9a6bf2209c7ab6699bd9f110dc8b55e" ..
    "47317bf18dbd70ef6a1b4a11158c16c8"
)
local composite = n(
  "7fffffffffffffffffffffffffffffffffffffffffffffffffffffff7ffffe0480000000000000000000000000000000" ..
    "00000000000000000000001300004883"
)
local composite_base = n(
  "7ca9870676e2106c50f7f588fea310e489aead97d3b82bf1011e54bc8654fb0a477112abe4e1d068f5c2b0595c4c68bd" ..
    "6a6c41d794798d11d67411a6d148"
)
local composite_exponent = n(
  "0fbea8b1dc708cf74c75581d5fcc0d556bace680cbb1f0f6ac96bf42cb89a1b9568038b563605fadd229d14fceacc192" ..
    "67fa54df1638393b826186057164df"
)
local composite_power = n(
  "25193d72a986aac5ae413b583e8d7324dd9c97459560e8725de07db6218eb8a23d9dafee00cba2f43b61082df599e963" ..
    "48d69192fef4ae8099329fd1381e9cda"
)
local a = n(
  "91ae6073ceb1072d13bda8cee55963d429e29ddab5852745c835a0f917d03ccd44af9d89aa5b3d117826c3c8ab0b4c7e" ..
    "fd84ef3ea590846405166cfa8772a8f8df180d0532dd87ebb4cb3ee586c61cfd1cc8f5a2833a05ff2b12be092b7371e9" ..
    "30dc127c537fa77eadfb869d4a46ad410bc4941ca00e239947ea10236f97c55d"
)
local b = n(
  "f408d314d73cea98e7a62e4345b510af21e297b057ddc5b4e445cbe8ead1fb0c49d48247de4696cffcef22d76b88c27e" ..
    "bf643ac28fbde4105c79a0731cff760e009e58e965c6df0c56bc36f5f0b0017726e4b2e7913533edcd44e092bcc01598" ..
    "9246bafe98f5e4a36618b51065e449ccb4b9c6bad3e9b0cf2a1da5ab85"
)
local m = n(
  "01d9869c9cc8f525d54cf68eca0522af529cc9cd53bd8f94b2858a9de3b69ba1fe8264fdbd37fca263ab68e220406a4f" ..
    "ff4ad352ad9cfd76b70a64c7c5c233590aa3ceaea9d055ac0b07542940620d7e3a6ec5e416395d54f3a48aee534bc56c" ..
    "2ecf"
)
local a_plus_b = n(
  "91ae6167d7841c0450a841b68b87a719def34cfc981cd79da5fb55dd5d9c25b816aaa9d37edd84efbebd93c59a2e23ea" ..
    "86476dfe09cb46f3c2fa7d5701131c15de8e1b05d13671517baa4b3c42fd12edccca6cc967eced906046abd6705404a5" ..
    "f0f1ab0e9a3aa617a3e02a0362fbbda6f00e60d159d4de6d319adf4d8d3d70e2"
)
local a_minus_b = n(
  "91ae5f7fc5ddf255d6d30fe73f2b208e74d1eeb8d2ed76edea6fec14d20453e272b4913fd5d8f533318ff3cbbbe87513" ..
    "74c2707f4155c1d447325c9e0dd235dbdfa1ff0494849e85edec328eca8f270c6cc77e7b9e871e6df5ded03be692df2c" ..
    "70c679ea0cc4a8e5b816e33731919cdb277ac767e64768c55e3940f951f219d8"
)
local a_times_b = n(
  "8adf397ffa3a4a2784394241121150ab8a9a82702c476ed8808f645f48f7a7702bb60be59a1279d193ffb75e1345617d" ..
    "be4b9a0e403761ee4924d1a4b763e0b3edd66fb1a11dc28e9d23d4767d0d7a462577d8046f2ada7cd636c8223128aaf5" ..
    "dafa745a6c9023b5587217df2b9625b9048b007513441d9eb52606fb3dfa74f1bdd0ba17b2f9f417259f7b4efc7a133d" ..
    "800e9cdb0471583b1dd93963fcddaa50ae6cfb5022ac64f61de2a6e59c8c6594ec7d2e778295683001ac5164dfb1a706" ..
    "cd6692293d9c50ea6f8b9a3da478583a4886b5856e84ec60f85d173a0d1ea4de8507a2d5997bd880371d02663dbdc901" ..
    "856add25087c49c063189fa851"
)
local a_times_b_mod_m = n(
  "a3a6c49f06d621da3cfca31fe6847ff49adc6c818637cc6de0fd4341029c472173d9f0782e5921f4852d93c247e03990" ..
    "379cfc6dc84a34adad997926cbd3f45077b2c568295a72dc060a3349b439daea19db14713c502ce06729ee9013add728" ..
    "04"
)
local a_mod_m = n(
  "012f8b7b7fb99d623e9e47d66473209156072be59f04a70800cc57b9231f7ea5efbefa23da50fe78365d94b8575c76e6" ..
    "8131644c2e44e9e5c9fa10f8301ab3426ca3452957902ab0f3759f4903a44b0ee9ed207292de6c756b9e78b699d75c84" ..
    "5686"
)

-- Operands and answers for the functions for secrets, from Python: a
-- number below the 3072-bit prime, one of a digest's length, one of 700
-- bytes, an even modulus of 40 bytes and an odd one of 13. The last six
-- are SHA-256 digests of answers at the limits, whose operands `drawn`
-- makes.
local s_a = n(
  "43ca95e3bc07292b6039dfb5262eabe72d1a95674819872a700efca2ce8a1eb0d1857a9a23de885ed0a49b97ecb60c98" ..
    "ae06c30855846842a3b74a7bf6ae9ab02dbb1a7e86c54a0d5d0fcf691ce406d42efb5c91383f3572daac890912f9051f" ..
    "9c279eb2241e1ddfa13b442ee3a55a6ea2734f466b7b07c3e58c30e4a4496fa77516d6a92d6c5974d2c107925b73f675" ..
    "e80a4727f88566bc904e99fdfbd432d32f3e6de4a3e85d5e1ff96923bbd8dd1cf6e518fec6ab6e614a82a3267b1aee40" ..
    "f8d7c1e7650819ba317e83e8eae6d11de1afdbc4d84de38d5e0d3dd1e2899e303606a45c90beda6d85cd9356f00b8a63" ..
    "a78b96832648da4a7480447d3d26bec03867293445684e9fb230d6db65a66d6661030b858a4391ecc5382758a74e66d4" ..
    "9d1fd1a7d51e51d46bb1a8cfd94b9a1b06c9e87a275f9bbdbd7674ddf8a494036e0c59b13c83ca78d83810d5c883e3cb" ..
    "70057f540649725e7f47cc862103b33ec3b485c281607aa67bfe5dbbedf42504964278938db492c53dac1e0110672a4d"
)
local s_b = n(
  "268e3fcbd96622adf51872c09aa3a89a6403bd4e5b4f0c046cb732a4814e2f437a359d186c2e013f267d3faf0f92499f" ..
    "2e0faa5f39cba66c25f76c1bd0dcc44e"
)
local s_wide = n(
  "87ce485f673d13a2c9b7a90f1cf178ebb945d7063c67ae5241ef8ad198aa34f42ef7e547608292ed2d2c36632cd8a1a2" ..
    "c386f70529e024ea4a4226fd45092a0182de338291221ebbb5a059ca01dde4f1a8f44914a724b3278e88d609aa6812ea" ..
    "4d8d44e0b98d81820b95da31b43ce2ef5fac6dd4f3ecee114baa92515d421bad32d77da36ed9ba4b16b0c26d93e606e8" ..
    "8e5eedc94ae282bab8adf87f7b2e47b2a11c17954e47cbf873e49116efc81a8e7cc8aa5bc3f853001a3e4a5dc54e48f0" ..
    "ce9f3a730a12b061440504c6dc08bb01dcc0cf32244809c8dc831b69a84f70620ebb533c25ca97afed56083552c3db4c" ..
    "719b9cb41b6954a65db3cdc14b334ae50751b2940e60969ae18e9c66a4265af912ac372debfd8ef3fdc6b35c7326b106" ..
    "4597cee0d8cd3556c2d5080efa13486fbc9a866ae6903d4a4787c6cae17365b5b3803762ce6ac914daa302a09d2482a1" ..
    "820315622b386eacbd82930034c0d18e84cc77e7258170afde236f8970b203df3c530423b830b3db1fe619951deacce3" ..
    "6ec7b8eb70584c29a86c13952d09a040dfca7946f85fd4dd67be578b1c0be182030599f4e7de596cc40ce6922c167f94" ..
    "5f18744059baf5b8d0cf90dd88fd4c6b41df5225801714fcf64f5509e7c2de8f2783e5bb6cbb0dd4f6701af0d07c0aec" ..
    "ad450d836ea7e222e32c9a5230e2b9e25374a6eb62486af6b5cc04e3c995950cb3116319d2e78ca2d31dcedc073afa4c" ..
    "a9af57f13212f99af0fa407eaca68b41991e6d29746e323d7eb39a3190ffbede9b88abff34105497411821ed5ed0389d" ..
    "84b7e589702b093dc42fafac3e30672b75d698f6d87ce577bf6e3242fb6a680ba29f78f7832a1fabb1b4ab1ecd705b3b" ..
    "1f939625cd06fac27e2997035250d25c2785a697edde944f7e4788f27cafe5b9ffae60ea349ce5a1f50f979986cc36a7" ..
    "c8fc62215cb9f2d4c344d6329b0770d65a7cbec29d7456c2552534e9"
)
local s_even = n("eeee397645d21f3c40c62c0f08cf69014ccd01df3461da37404de3e893e78b72050f53d2a28ca6d0")
local s_odd = n("89aac84481ced6db65877a46fd")
local s_a_times_b_mod_p = n(
  "0eec20e489941d8743bb79c5574d4b721441236f9acc6a64d9c6218b2cad79b683f38becc2e03f63941d0a042cdcd383" ..
    "5b9bae83e58b4ecbae99fa5c7a7e2fc16f9597d0f31fd141f10c0f5bb67b103faf58f713484982ae7b41724112c9dbac" ..
    "9df83fc56ab1e60c90f95599d142ab99a39edd5484592a03f4aa220ebec8d9a55ee2a9dd380ae7d4462242fd6184cf50" ..
    "9fadc607f4de073288b2d5ee3a7e74efd14d6a35e45f67ffdbf27c2e761b014adc0c7ad05d637f61bc08e62fd0d7b0d9" ..
    "17f1e906156a5484aa99441180aafe419a96c50263ca8fb4dec5216760e422cbc9c80ca05d74262b5c8efee51cc0357f" ..
    "44d677c91fea954e9431e3976b12103a0d42ee32746d05a7d1b0b2be2b90cf045b75b0030a316681a01086f412981165" ..
    "ae5a6db2f1a4c5ffc4f8a6a0e89fc7fc61ddebc4694fc6161630200018f6e9583a708e17be721e62c27546241a05f158" ..
    "8c131698dacb3753b705f2e1a3c3b246fd8c3bca21b7b364e46eb4926f8f816876e128c6df4669d059e27eff0112042e"
)
local s_a_plus_b_mod_p = n(
  "43ca95e3bc07292b6039dfb5262eabe72d1a95674819872a700efca2ce8a1eb0d1857a9a23de885ed0a49b97ecb60c98" ..
    "ae06c30855846842a3b74a7bf6ae9ab02dbb1a7e86c54a0d5d0fcf691ce406d42efb5c91383f3572daac890912f9051f" ..
    "9c279eb2241e1ddfa13b442ee3a55a6ea2734f466b7b07c3e58c30e4a4496fa77516d6a92d6c5974d2c107925b73f675" ..
    "e80a4727f88566bc904e99fdfbd432d32f3e6de4a3e85d5e1ff96923bbd8dd1cf6e518fec6ab6e614a82a3267b1aee40" ..
    "f8d7c1e7650819ba317e83e8eae6d11de1afdbc4d84de38d5e0d3dd1e2899e303606a45c90beda6d85cd9356f00b8a63" ..
    "a78b96832648da4a7480447d3d26bec03867293445684e9fb230d6db65a66d6661030b858a4391ecc5382758a74e66d4" ..
    "9d1fd1a7d51e51d46bb1a8cfd94b9a1b06c9e87a275f9bbdbd7674ddf8a49403949a997d15e9ed26cd50839663278c65" ..
    "d4093ca261987e62ebfeff2aa251e2823dea22daed8e7be5a27b9d6afd866ea3c45222f2c780393163a38a1ce143ee9b"
)
local s_b_minus_a_mod_p = n(
  "bc356a1c43f8d6d468d5faecfb3a164d97abcd2438c295a6b8f35165bbddadc33086440c173512c380a56ce1a17df845" ..
    "418e56ab77b5dad88c73bff1fbb0798722261aeee68c78388775e60d457a77f2c550e6586df8b7f83152d3ade10db2ce" ..
    "5210cd49366b81c60d63dfe298a5c577a6b5170b81695379dc744bd3fd1a4f5e23c3718ceee97a2596553816a1b0d8e9" ..
    "9b5b15fbe41e46d98c14595824b11fe86f96bb22ccae390f4712cc2a8ee3bae7fa8f530a036cb31ae80dbb1fb31bdffa" ..
    "eac6b544b3066c4969a8ffba0120d171d415822b96fe6f3c801e8e24b2ce78e8038ea52059d69077900492c1a8ee7aac" ..
    "6de6f7d76461e9e338b2d28fc729bb736fedf87799b46bc53acaae28f33581a429e765d1d2c27a90ee5ee82cff937df3" ..
    "0ed5dce505eae202b2daec1070d9c782c819e9abf37352ae33b98528e0e5746190f7e88ddbaac2996eff8d02e99ae4db" ..
    "afdf5551cf66f7126478eedf1b23c2e6bf6366f65fb331c9ee5a3df0029b3528e35002ec5551e671e84b4e1ac0759a00"
)
local s_wide_mod_p = n(
  "71067d88667055870ad595e42f51e7558ab9c43bc210200208cb7e49708a93a2fdf35c1c465510008ac02b0538f5c92c" ..
    "d48370d61c44d442218f48a7f48671f69e7611063dc2418f9a9d6e1511aea173a1f0ba34753961e57c189ccd8d0b6a15" ..
    "23c8d048358460c83b376ff975b58388dc95ea44692f1b3e90602856f68dc13eff9c00444eb1bd36a452ea79f2b74c3b" ..
    "675ea21aae8c2694b18e844185c389625c4b34bb6a79ac0700691da8cb4f61548f0401a2f2929788f709f201d53c1338" ..
    "4ede53ac9926ddd60e08796ee6a65bbf7e6734b1ffa3e5ebabf1793c07fb718ad676c86c8d3b2c7cd9df3fe2f3dfac53" ..
    "073469ce7adf417ea9b6364e2bfb04ed408c1828ba6473a6292ba24b691eb4711f6bdcc8a31d6eacd19c6f6faf7c86c6" ..
    "d73da698dd9589ac524fb117424c0c199343b3ec42756b97be3daae3200bf3683248d54b1f1baca22d9fa3d1ad81d3c6" ..
    "0c65e56793a917a99a47091741ffb7d1f4a6a2829eadc97202cb30ac8e258f38f16eec710500985cea96edee62cf3fde"
)
local s_wide_times_a_mod_p = n(
  "d6d56deada121afde94b899d8be1a5a864522688bd2b4e0fd2d412bf3ec43ddfe035bd26770811be35a77356c1291e2e" ..
    "6bb2b514924cff1280c07d215cb3432de1c5baee981e0f2e453739bd89665ca0927e013b29b5b3c9669697672df4c8d3" ..
    "452958a396eeb79430cec24c9e0973d9dc39ad4871e05752430129f474bb7b5e7e528cd792bd5d9ca2b5570135294136" ..
    "b1f92724e6545f0e48a336edddc9d7d17eecb0b8630504bf88061babb5e9939e00900c00d241933b43bde837b41e059e" ..
    "02c9c714f8af27e8109f4ea9349993b399c069de2f265c5acee2358fed1af008a82512b169b41b93dd8c1ae3297a96ae" ..
    "6d03c227d71d86c8a5fc3e0b23814073f6fed25a2405c031dfea2ac02ad61f5cda93234cdef495a6032875ec40903ead" ..
    "2eeb8077745e9c207d9c754846e27c5460d7c1e426924132c9da9ed0871439bc32401678eb93a9350cf2b24f0ca2bb08" ..
    "99bba6b39a82b8e6bc7cf9e5ca252a5f5616867d83c837d1992507195026235059b02f604a633a76a5f4e3f9c65d88aa"
)
local s_wide_plus_wide_mod_p = n(
  "e20cfb10cce0ab0e15ab2bc85ea3ceab15738877842040041196fc92e1152745fbe6b8388caa20011580560a71eb9259" ..
    "a906e1ac3889a884431e914fe90ce3ed3cec220c7b84831f353adc2a235d42e743e17468ea72c3caf831399b1a16d42a" ..
    "4791a0906b08c190766edff2eb6b0711b92bd488d25e367d20c050aded1b827dff3800889d637a6d48a5d4f3e56e9876" ..
    "cebd44355d184d29631d08830b8712c4b8966976d4f3580e00d23b51969ec2a91e080345e5252f11ee13e403aa782670" ..
    "9dbca759324dbbac1c10f2ddcd4cb77efcce6963ff47cbd757e2f2780ff6e315aced90d91a7658f9b3be7fc5e7bf58a6" ..
    "0e68d39cf5be82fd536c6c9c57f609da8118305174c8e74c52574496d23d68e23ed7b991463add59a338dedf5ef90d8d" ..
    "ae7b4d31bb2b1358a49f622e84981833268767d884ead72f7c7b55c64017e6d06491aa963e3759445b3f47a35b03a78c" ..
    "18cbcacf27522f53348e122e83ff6fa3e94d45053d5b92e4059661591c4b1e71e2ddd8e20a0130b9d52ddbdcc59e7fbc"
)
local s_a_minus_wide_mod_p = n(
  "d2c4185b5596d3a41e742473184586c6672733b706e583f99045cc61e8675781d59ddd24189d1380972e790c41f44849" ..
    "c9186be60679d71bb2530c41f4873cf0df263ee5b654cac3a6f816ca6d93e4278156e546693dc0f86a9348f279f452f8" ..
    "66973a6549235cbd14a2f846ea3af6cc0f05cb53ef3047c3172c85464f1f6d6e0e551e9afb106fd897845cc165e1799a" ..
    "04110231269cedbdfb2309129695fc2c71c86230aa0547c4869c80c93b4613cd595583649e30f85486090f6ad415a944" ..
    "8d97e566e3efc1e7be9d8e1cf04817ee190e050347f6506b9047908c6fe643bd9925256cee1918d5c1c0798c9525e320" ..
    "b5c9bb0f36145cf977fd253c157c3406a03032b76a20955e7600b9945563a7ffcc81a014442c2fbda732c76e9eb3c4d5" ..
    "71d7d99bd291fbff37ee8c98e124ef9f426a06b3ffbd1e91f068c401b222a900143986d95c30883afcb7981c327d3012" ..
    "1f80b143ed01b8215c0a4c2f99dd424ed7f032e057985c65bd0e890c40cba659f0565d4331eecd3353153012ad97ea6e"
)
local s_a_times_b_mod_p256 = n("e1361d6e6109cac9c2e6c180bc97485765b4d80680a7ecea2a0df98a9a8dbd2c")
local s_a_mod_p256 = n("4d06a20ac1e6cd0899c703bdc8ea5795a98ebceec9165cb7c8c9f1984c17cb6c")
local s_a_times_wide_mod_odd = n("190eca6b56b41b4b1bf60ace3c")
local s_wide_mod_odd = n("50143739cac0bcd8a102e30235")
local s_a_plus_b_mod_odd = n("3058f8a0fa3c45523c39c3f616")
local s_b_minus_a_mod_odd = n("457b317ece43e12e69f37d7078")
local s_a_mod_even = n("ee668554d5c8a99bf2ca30abf2031016da280303d59d34d5d26a331f53c2a909e14fde8822fe679d")
local s_a_plus_wide_mod_even = n("47e60af8bf704487a25d087cd338a52b77d53f37463b6615bc2b38be46170110330a71f98c8e8ce6")
local s_b_minus_wide_mod_even = n("ad5f95a26aa97f150b3010cd9afdb83fe98bc5eb09479ccfccffeda505b5f8ae7077fcec9e33a805")
local s_a_times_b = n(
  "0a35bd83c85507e5defd2ad5ee2f93a2ad4b8dcf639cce16bfd94e429a5e1b171c34b153cb3b107c05c3198dd5aa294e" ..
    "61c334843484c90e149b6edac51ed2330adbe95140bd9cd9ad2a435bbbebe2d9c3537cd7e7b5b10c11f82851a09e231c" ..
    "cdb529a1605ab0274257a4cf20f3bb0129ffa7393f490c9ab06bb4e4cd12b4a63924b66dbe51ec197f3cf4e6d532bce1" ..
    "3b44a54a8d080726d3b039741225e5a43a6cd63c8a00bd3efb0214c914c45df6247b9d9a993463c78f1ac743b34a6e9a" ..
    "9835bac49c9add56f0d3354b36e3a2d5cdac899b196c1bcdbb5f3c480ac3279610398ebface8c71221ad557ca5ded6de" ..
    "0d7857d7f699652f448035cbb6765d50c0f24f985a68d88d2da80832f1cbfb92ef29c722606b512d9d2cffbf17ceae5f" ..
    "cccdb6227ad31b247c735ae7d42d681bb10cb08758b6c46c9f0388a76a85fb9b9860a87374eacd887fe2adb41daa6d2d" ..
    "5522d2b4df7375b886ed0be789bb866f21900781f90ca94fc3da59968746e86b6c0131973a796f579453a70394d2babc" ..
    "516f02a3238906cd946fc9331c324137b1dd734d17965a9a9bd86c94567df42c4ffcbe421da398a4fe1209b010d4546f" ..
    "fd246dfd8a38b3c669acd207e5fdd776"
)
local s_a_plus_b = n(
  "0043ca95e3bc07292b6039dfb5262eabe72d1a95674819872a700efca2ce8a1eb0d1857a9a23de885ed0a49b97ecb60c" ..
    "98ae06c30855846842a3b74a7bf6ae9ab02dbb1a7e86c54a0d5d0fcf691ce406d42efb5c91383f3572daac890912f905" ..
    "1f9c279eb2241e1ddfa13b442ee3a55a6ea2734f466b7b07c3e58c30e4a4496fa77516d6a92d6c5974d2c107925b73f6" ..
    "75e80a4727f88566bc904e99fdfbd432d32f3e6de4a3e85d5e1ff96923bbd8dd1cf6e518fec6ab6e614a82a3267b1aee" ..
    "40f8d7c1e7650819ba317e83e8eae6d11de1afdbc4d84de38d5e0d3dd1e2899e303606a45c90beda6d85cd9356f00b8a" ..
    "63a78b96832648da4a7480447d3d26bec03867293445684e9fb230d6db65a66d6661030b858a4391ecc5382758a74e66" ..
    "d49d1fd1a7d51e51d46bb1a8cfd94b9a1b06c9e87a275f9bbdbd7674ddf8a49403949a997d15e9ed26cd50839663278c" ..
    "65d4093ca261987e62ebfeff2aa251e2823dea22daed8e7be5a27b9d6afd866ea3c45222f2c780393163a38a1ce143ee" ..
    "9b"
)
local s_wide_plus_a = n(
  "0087ce485f673d13a2c9b7a90f1cf178ebb945d7063c67ae5241ef8ad198aa34f42ef7e547608292ed2d2c36632cd8a1" ..
    "a2c386f70529e024ea4a4226fd45092a0182de338291221ebbb5a059ca01dde4f1a8f44914a724b3278e88d609aa6812" ..
    "ea4d8d44e0b98d81820b95da31b43ce2ef5fac6dd4f3ecee114baa92515d421bad32d77da36ed9ba4b16b0c26d93e606" ..
    "e88e5eedc94ae282bab8adf87f7b2e47b2a11c17954e47cbf873e49116efc81a8e7cc8aa5bc3f853001a3e4a5dc54e48" ..
    "f0ce9f3a730a12b061440504c6dc08bb01dcc0cf32244809c8dc831b69a84f70620ebb533c25ca97afed56083552c3db" ..
    "4c719b9cb41b6954a65db3cdc14b334ae50751b2940e60969ae18e9c66a4265af912ac372debfd8ef3fdc6b35c7326b1" ..
    "064597cee0d8cd3556c2d5080efa13486fbc9a866ae6903d4a4787c6cb253dfb996f87608e2ea4a8ca00d1ae87ca3f18" ..
    "08ca1c9c8c9b476b4f8c0cb1b106464c28a8ab0045f6260c47cad97c221eb8c6e791d76c665be7fe571694b4454ba5e7" ..
    "61f58d02f8cd681b92c5501a695c04fcd21809aeb9d30c5de67ab75caab83380342723b7d489199d9ba7b24100ce89ce" ..
    "daca937c043f47269d75190084fe1423146f4bab9a52d81c8f51c34b7fcfcd25b720094c77fd09a7d2f2444dc3ffba78" ..
    "d1512d6ae18ea14b469f05776f27c7d2e11a20154caccb0e1d30e6f324c26d56f418197cd40466108bbe049ff9e8ead6" ..
    "1181fd3b7e9020376cd383deaee2ad2f9e29dd4796fa3bc5946ebf2495388b5561c1d18649a89099147e3ee0ad973761" ..
    "d1ca203429225be01929d61d129f3372b1001a2ae39db50cd066bc9917988a39b377bdcacbeedbc87b8b004539d43a43" ..
    "b546f331e38a7d6fa076ce2b06c05d2c0d64097110c616a52546cb6cbdecb5650e05f7d348b3e4b22816134ad84a80bc" ..
    "6a4a5cdcc7d8b85090b138fb373149e969e8315187db2074c3658c5f36"
)
local lim_times = n("4d8aa99b099daa2a5874f822aba768211d3a988728be1264b4db14dbd06e696d")
local lim_plus = n("9ae2ffde51dab1334d13319ecdc44bb647b127ea6bc1e56ad5293da650dafe56")
local lim_minus = n("0e93b3455e5a4cb1731725540d9fe138dc83d87ae2ab115c9e67190716a3c823")
local lim_mod = n("7f057f5ee662a4b9ef864f4c2b81c4953f9c857ee061930f3446f3c7a8f876a5")
local lim_product = n("c72774ab97fecd7020abf6b758de7671b0a2d84ea16bfc1a16e0c2dd79919679")
local lim_sum = n("95edf9e7d9df0a988c1daedca98193df27d199f4beadadc237cc61d4d113194f")

local zero = "\0"
local one = "\1"

local function test_small_values_are_what_hand_arithmetic_gives()
  assert(Bigint.powmod("\4", "\13", n("01f1")) == n("01bd"), "4^13 mod 497 is 445")
  assert(Bigint.powmod("\2", "\10", n("03e9")) == "\23", "2^10 mod 1001 is 23")
  assert(Bigint.mul("\255", "\255") == n("fe01"), "255 * 255 is 65025")
  assert(Bigint.add("\255", "\1") == n("0100"), "255 + 1 carries into a second byte")
  assert(assert(Bigint.sub(n("0100"), "\1")) == "\255", "256 - 1 borrows back to one byte")
  assert(Bigint.mod(n("03e8"), "\7") == "\6", "1000 mod 7 is 6")
  assert(Bigint.compare("\2", "\3") == -1)
  assert(Bigint.compare("\3", "\3") == 0)
  assert(Bigint.compare(n("0100"), "\255") == 1)
end

local function test_zero_is_one_zero_byte_and_an_answer_has_no_leading_zero()
  assert(Bigint.add("", "") == zero, "the empty string is zero, written as one byte")
  assert(Bigint.mul(zero, a) == zero)
  assert(Bigint.mod(m, m) == zero)
  assert(assert(Bigint.sub(a, a)) == zero)
  assert(Bigint.powmod(zero, "\5", "\7") == zero)
  assert(Bigint.add("\0\0\0\1", "\0\0") == one)
  assert(Bigint.mul("\0\0\2", "\0\3") == "\6")
  assert(Bigint.mod("\0\0\9", "\0\0\5") == "\4")
  assert(Bigint.powmod("\0\4", "\0\0\13", n("000001f1")) == n("01bd"))
  assert(assert(Bigint.sub("\0\0\9", "\0\4")) == "\5")
end

local function test_compare_reads_numbers_not_strings()
  assert(Bigint.compare("\0\0\5", "\5") == 0, "leading zero bytes do not count")
  assert(Bigint.compare("", zero) == 0)
  assert(Bigint.compare("\0\1", "\2") == -1, "a longer string is not a larger number")
  assert(Bigint.compare(a, b) == 1)
  assert(Bigint.compare(b, a) == -1)
  assert(Bigint.compare(a_times_b, a) == 1, "a product of two operands is compared")
end

local function test_sums_differences_and_products_match_python()
  assert(Bigint.add(a, b) == a_plus_b)
  assert(Bigint.add(b, a) == a_plus_b)
  assert(assert(Bigint.sub(a, b)) == a_minus_b)
  assert(assert(Bigint.sub(Bigint.add(a, b), b)) == a, "a + b - b is a")
  assert(Bigint.mul(a, b) == a_times_b)
  assert(Bigint.mul(b, a) == a_times_b)
  assert(Bigint.mod(a, m) == a_mod_m)
  assert(Bigint.mod(Bigint.mul(a, b), m) == a_times_b_mod_m)
  assert(Bigint.mod(Bigint.mul(Bigint.mod(a, m), Bigint.mod(b, m)), m) == a_times_b_mod_m,
    "reducing the factors first changes nothing")
  assert(Bigint.mod(b, a) == b, "a number below the modulus is its own remainder")
end

local function test_sub_refuses_a_negative_difference()
  local difference, why = Bigint.sub(b, a)
  assert(difference == nil and why == "bigint: the difference is negative", why)
  difference, why = Bigint.sub(zero, one)
  assert(difference == nil and why == "bigint: the difference is negative", why)
  local equal, none = Bigint.sub(one, "\0\1")
  assert(equal == zero and none == "", "equal numbers differ by zero")
end

local function test_powmod_matches_python_at_256_bits()
  assert(Bigint.powmod(v256_base, v256_exponent, p256) == v256_power)
end

local function test_powmod_matches_python_at_2048_bits()
  assert(Bigint.powmod("\2", v2048_exponent, p2048) == v2048_power)
end

local function test_powmod_matches_python_in_the_3072_bit_group_of_rfc_5054()
  assert(#p3072 == 384)
  assert(Bigint.powmod("\5", g5_exponent, p3072) == g5_power, "the generator to a 256-bit exponent")
  assert(Bigint.powmod(v3072_base, v3072_exponent, p3072) == v3072_power, "a base and an exponent of 3072 bits")
end

local function test_leading_zero_words_of_a_modulus_and_an_exponent_change_nothing()
  local zeros = string.rep("\0", 24)
  assert(Bigint.powmod(zeros .. v256_base, zeros .. v256_exponent, zeros .. p256) == v256_power)
  assert(Bigint.mod(zeros .. a, zeros .. m) == a_mod_m)
end

local function test_powmod_takes_an_odd_modulus_that_is_not_prime()
  assert(Bigint.powmod(composite_base, composite_exponent, composite) == composite_power)
end

local function test_powmod_reduces_a_base_that_is_not_below_the_modulus()
  assert(#wide_base == 2 * #p2048)
  assert(Bigint.powmod(wide_base, wide_exponent, p2048) == wide_power)
  assert(Bigint.powmod(p2048, "\3", p2048) == zero, "the modulus itself is zero modulo it")
  assert(Bigint.powmod(Bigint.add(p256, "\2"), "\5", p256) == "\32", "p + 2 is 2 modulo p")
  assert(Bigint.powmod(Bigint.mul(a, b), "\1", m) == a_times_b_mod_m, "a product is reduced as a base")
end

local function test_powmod_at_the_edges_of_its_exponent_and_modulus()
  assert(Bigint.powmod(v256_base, zero, p256) == one, "anything to the power zero is one")
  assert(Bigint.powmod(v256_base, "", p256) == one, "the empty exponent is zero")
  assert(Bigint.powmod(zero, zero, p256) == one, "zero to the power zero is one, as Python's pow has it")
  assert(Bigint.powmod(zero, v256_exponent, p256) == zero)
  assert(Bigint.powmod(one, v256_exponent, p256) == one)
  assert(Bigint.powmod(v256_base, one, p256) == Bigint.mod(v256_base, p256))
  assert(Bigint.powmod(v256_base, v256_exponent, one) == zero, "everything is zero modulo one")
  assert(Bigint.powmod(v256_base, zero, one) == zero)
  assert(Bigint.powmod(v256_base, "", one) == zero)
  assert(Bigint.powmod(zero, "", "\0\1") == zero)
  assert(Bigint.powmod("\2", "\2", "\3") == one, "the smallest odd modulus above one")
  -- Fermat: a^(p-1) is 1 modulo a prime p that does not divide a.
  assert(Bigint.powmod(v256_base, assert(Bigint.sub(p256, one)), p256) == one)
end

local function test_powmod_raises_on_an_even_or_zero_modulus()
  local why = Test.raises(function() Bigint.powmod("\3", "\5", "\8") end, "the modulus is even")
  assert(why:find("bad argument #3 to 'powmod'", 1, true), why)
  Test.raises(function() Bigint.powmod("\3", "\5", "\2") end, "the modulus is even")
  Test.raises(function() Bigint.powmod("\3", "\5", Bigint.add(p2048, one)) end, "the modulus is even")
  Test.raises(function() Bigint.powmod("\3", "\5", zero) end, "the modulus is zero")
  Test.raises(function() Bigint.powmod("\3", "\5", "") end, "the modulus is zero")
  Test.raises(function() Bigint.powmod("\3", "\5", "\0\0\0") end, "the modulus is zero")
end

local function test_mod_raises_on_a_zero_modulus_and_takes_an_even_one()
  local why = Test.raises(function() Bigint.mod(a, zero) end, "the modulus is zero")
  assert(why:find("bad argument #2 to 'mod'", 1, true), why)
  Test.raises(function() Bigint.mod(a, "") end, "the modulus is zero")
  assert(Bigint.mod(n("03e9"), "\8") == one, "1001 mod 8 is 1")
  assert(Bigint.mod(a, one) == zero)
end

local function test_the_limits_are_8192_bits_and_twice_that()
  assert(Bigint.modulus_bytes == 1024)
  assert(Bigint.operand_bytes == 2048)
end

local function test_numbers_at_their_limit_are_computed()
  -- 2^8192 - 1, an odd modulus of exactly the limit, and the exponent
  -- 2^8191 + 5: 2 has order 8192 modulo it, and 8192 divides 2^8191, so
  -- the power is 2^5.
  local mersenne = string.rep("\255", Bigint.modulus_bytes)
  local exponent = "\128" .. string.rep("\0", Bigint.modulus_bytes - 2) .. "\5"
  assert(#exponent == Bigint.modulus_bytes)
  assert(Bigint.powmod("\2", exponent, mersenne) == "\32")
  assert(Bigint.mod(string.rep("\255", Bigint.operand_bytes), mersenne) == zero,
    "2^16384 - 1 is (2^8192 - 1)(2^8192 + 1)")
  -- (2^k - 1)^2 is 2^2k - 2^(k+1) + 1.
  local most = string.rep("\255", Bigint.operand_bytes)
  local square = Bigint.mul(most, most)
  assert(square == string.rep("\255", Bigint.operand_bytes - 1) .. "\254" ..
      string.rep("\0", Bigint.operand_bytes - 1) .. "\1")
  assert(Bigint.add(most, one) == one .. string.rep("\0", Bigint.operand_bytes), "a sum one byte past the limit")
  assert(assert(Bigint.sub(most, most)) == zero)
  assert(Bigint.compare(most, most) == 0)
  assert(Bigint.powmod(most, one, mersenne) == zero, "a base of the operand limit")
  assert(Bigint.mul(string.rep("\0", Bigint.operand_bytes - 1) .. "\2", "\3") == "\6",
    "leading zeros up to the limit")
end

local function test_a_number_over_its_limit_raises()
  local wide = string.rep("\1", Bigint.operand_bytes + 1)
  local long = string.rep("\1", Bigint.modulus_bytes + 1)
  local says = "the number is longer than 2048 bytes"
  local why = Test.raises(function() Bigint.mul(wide, one) end, says)
  assert(why:find("bad argument #1 to 'mul'", 1, true), why)
  why = Test.raises(function() Bigint.mul(one, wide) end, says)
  assert(why:find("bad argument #2 to 'mul'", 1, true), why)
  Test.raises(function() Bigint.add(wide, one) end, says)
  Test.raises(function() Bigint.add(one, wide) end, says)
  Test.raises(function() Bigint.sub(wide, one) end, says)
  Test.raises(function() Bigint.sub(one, wide) end, says)
  Test.raises(function() Bigint.compare(wide, one) end, says)
  Test.raises(function() Bigint.compare(one, wide) end, says)
  Test.raises(function() Bigint.mod(wide, "\3") end, says)
  Test.raises(function() Bigint.powmod(wide, one, "\3") end, says)
  says = "the number is longer than 1024 bytes"
  why = Test.raises(function() Bigint.mod(one, long) end, says)
  assert(why:find("bad argument #2 to 'mod'", 1, true), why)
  why = Test.raises(function() Bigint.powmod(one, long, "\3") end, says)
  assert(why:find("bad argument #2 to 'powmod'", 1, true), why)
  why = Test.raises(function() Bigint.powmod(one, one, long) end, says)
  assert(why:find("bad argument #3 to 'powmod'", 1, true), why)
  -- The limit counts the bytes given: zero, written too long, is refused.
  Test.raises(function() Bigint.powmod(one, string.rep("\0", Bigint.modulus_bytes + 1), "\3") end, says)
end

local function test_pad_writes_a_number_in_a_fixed_width()
  local padded, none = Bigint.pad("\5", 4)
  assert(padded == "\0\0\0\5" and none == "")
  assert(assert(Bigint.pad("\0\0\0\0\0\5", 2)) == "\0\5", "leading zeros are dropped before the width is met")
  assert(assert(Bigint.pad(a, #a)) == a, "a number already of the width is itself")
  assert(assert(Bigint.pad(g5_power, #p3072)) == string.rep("\0", #p3072 - #g5_power) .. g5_power)
  assert(assert(Bigint.pad(zero, 3)) == "\0\0\0")
  assert(assert(Bigint.pad("", 1)) == zero)
  assert(assert(Bigint.pad(zero, 0)) == "", "zero fits in no bytes")
  assert(assert(Bigint.pad("", 0)) == "")
  local long = string.rep("\0", 5000) .. "\7"
  assert(assert(Bigint.pad(long, 1)) == "\7", "pad reads a string of any length")
end

local function test_pad_refuses_a_number_that_does_not_fit()
  local padded, why = Bigint.pad(n("0100"), 1)
  assert(padded == nil and why == "bigint: the number needs 2 bytes, more than 1", why)
  padded, why = Bigint.pad(one, 0)
  assert(padded == nil and why == "bigint: the number needs 1 byte, more than 0", why)
  padded, why = Bigint.pad(p3072, 383)
  assert(padded == nil and why == "bigint: the number needs 384 bytes, more than 383", why)
  Test.raises(function() Bigint.pad(one, -1) end, "pad's width must be 0 or more")
end

--- `number` in exactly `width` bytes.
local function wide(number: string, width: integer): string
  return (assert(Bigint.pad(number, width)))
end

--- `count` bytes that `seed` fixes: SHA-256 of the seed and a counter
--- byte, block after block, which the Python that made the answers below
--- draws the same way.
local function drawn(seed: string, count: integer): string
  local blocks: mut {string} = {}
  while #blocks * 32 < count do
    local block = Hash.digest("sha256", seed .. string.char(#blocks))
    blocks[#blocks + 1] = block
  end
  return table.concat(blocks):sub(1, count)
end

--- Holds the six functions for secrets to the plain ones on `x`, `y` and
--- the modulus `modulus`, which is not zero: the same numbers, at the
--- widths the arguments fix.
local function assert_agreement(x: string, y: string, modulus: string)
  local width = #modulus
  local where = ("a of %d bytes, b of %d, a modulus of %d"):format(#x, #y, width)
  assert(Bigint.reduce(x, modulus) == wide(Bigint.mod(x, modulus), width), where)
  assert(Bigint.addmod(x, y, modulus) == wide(Bigint.mod(Bigint.add(x, y), modulus), width), where)
  local lifted = Bigint.add(Bigint.mod(x, modulus), modulus)
  local difference = Bigint.mod(assert(Bigint.sub(lifted, Bigint.mod(y, modulus))), modulus)
  assert(Bigint.submod(x, y, modulus) == wide(difference, width), where)
  if assert(modulus:byte(-1)) % 2 == 1 then
    assert(Bigint.mulmod(x, y, modulus) == wide(Bigint.mod(Bigint.mul(x, y), modulus), width), where)
  end
  assert(Bigint.product(x, y) == wide(Bigint.mul(x, y), #x + #y), where)
  assert(Bigint.sum(x, y) == wide(Bigint.add(x, y), math.max(#x, #y) + 1), where)
end

local function test_arithmetic_for_secrets_on_small_values_is_what_hand_arithmetic_gives()
  assert(Bigint.mulmod("\7", "\200", "\101") == "\87", "7 * 200 is 1400, 87 modulo 101")
  assert(Bigint.addmod("\100", "\100", "\101") == "\99", "200 is 99 modulo 101")
  assert(Bigint.submod("\7", "\200", "\101") == "\9", "7 - 200 is -193, 9 modulo 101")
  assert(Bigint.submod("\200", "\7", "\101") == "\92", "193 is 92 modulo 101")
  assert(Bigint.reduce(n("03e8"), "\7") == "\6", "1000 mod 7 is 6")
  assert(Bigint.product("\255", "\255") == n("fe01"), "255 * 255 is 65025")
  assert(Bigint.sum("\255", "\1") == n("0100"), "255 + 1 carries into the byte the sum adds")
end

local function test_an_answer_for_secrets_is_as_wide_as_its_arguments_fix()
  assert(Bigint.reduce("\5", "\0\0\0\7") == "\0\0\0\5", "a modulus's leading zero bytes count in the width")
  assert(Bigint.mulmod("\2", "\3", "\0\7") == "\0\6")
  assert(Bigint.addmod("", "", "\0\0\9") == "\0\0\0")
  assert(Bigint.submod("\0\0\0\0\1", "\2", "\0\9") == "\0\8", "an operand's length changes no width")
  assert(#Bigint.mulmod("\2", "\3", p3072) == #p3072)
  assert(Bigint.product("\0\0\2", "\0\3") == "\0\0\0\0\6", "as many bytes as both operands have")
  assert(Bigint.product("", "") == "", "zero in no bytes")
  assert(Bigint.product("\2", "") == zero)
  assert(Bigint.product("", "\2\2") == "\0\0")
  assert(Bigint.sum("", "") == zero, "one byte more than the longer operand")
  assert(Bigint.sum("\255\255", "\1") == "\1\0\0")
  assert(Bigint.sum("\1", "\0\0\0\1") == "\0\0\0\0\2")
  assert(Bigint.sum("\1", "") == "\0\1")
end

local function test_arithmetic_for_secrets_matches_python_modulo_a_3072_bit_prime()
  assert(#s_a == #p3072 and #s_b == 64 and #s_wide == 700)
  assert(Bigint.mulmod(s_a, s_b, p3072) == s_a_times_b_mod_p)
  assert(Bigint.mulmod(s_b, s_a, p3072) == s_a_times_b_mod_p)
  assert(Bigint.addmod(s_a, s_b, p3072) == s_a_plus_b_mod_p)
  assert(Bigint.addmod(s_b, s_a, p3072) == s_a_plus_b_mod_p)
  assert(Bigint.submod(s_b, s_a, p3072) == s_b_minus_a_mod_p, "the smaller less the larger wraps")
  assert(Bigint.submod(Bigint.addmod(s_a, s_b, p3072), s_a, p3072) == wide(s_b, #p3072), "a + b - a is b")
  assert(Bigint.reduce(s_a, p3072) == s_a, "a number below the modulus is its own remainder")
end

local function test_arithmetic_for_secrets_reduces_an_operand_above_the_modulus()
  assert(Bigint.compare(s_wide, p3072) == 1)
  assert(Bigint.reduce(s_wide, p3072) == s_wide_mod_p)
  assert(Bigint.mulmod(s_wide, s_a, p3072) == s_wide_times_a_mod_p)
  assert(Bigint.mulmod(s_a, s_wide, p3072) == s_wide_times_a_mod_p)
  assert(Bigint.addmod(s_wide, s_wide, p3072) == s_wide_plus_wide_mod_p)
  assert(Bigint.submod(s_a, s_wide, p3072) == s_a_minus_wide_mod_p)
  assert(Bigint.mulmod(s_a, s_b, p256) == s_a_times_b_mod_p256, "operands twelve times the modulus's length")
  assert(Bigint.reduce(s_a, p256) == s_a_mod_p256)
end

local function test_arithmetic_for_secrets_takes_a_modulus_that_ends_inside_a_word()
  assert(#s_odd == 13)
  assert(Bigint.mulmod(s_a, s_wide, s_odd) == s_a_times_wide_mod_odd)
  assert(Bigint.reduce(s_wide, s_odd) == s_wide_mod_odd)
  assert(Bigint.addmod(s_a, s_b, s_odd) == s_a_plus_b_mod_odd)
  assert(Bigint.submod(s_b, s_a, s_odd) == s_b_minus_a_mod_odd)
end

local function test_all_but_mulmod_take_an_even_modulus()
  assert(assert(s_even:byte(-1)) % 2 == 0)
  assert(Bigint.reduce(s_a, s_even) == s_a_mod_even)
  assert(Bigint.addmod(s_a, s_wide, s_even) == s_a_plus_wide_mod_even)
  assert(Bigint.submod(s_b, s_wide, s_even) == s_b_minus_wide_mod_even)
  assert(Bigint.addmod(one, one, "\2") == zero)
  assert(Bigint.submod(zero, one, "\2") == one)
  assert(Bigint.reduce("\255", "\2") == one)
  local why = Test.raises(function() Bigint.mulmod("\3", "\5", "\8") end, "the modulus is even")
  assert(why:find("bad argument #3 to 'mulmod'", 1, true), why)
  Test.raises(function() Bigint.mulmod("\3", "\5", "\2") end, "the modulus is even")
  Test.raises(function() Bigint.mulmod(s_a, s_b, s_even) end, "the modulus is even")
  Test.raises(function() Bigint.mulmod(s_a, s_b, "\0\0" .. s_even) end, "the modulus is even")
end

local function test_products_and_sums_for_secrets_match_python()
  assert(Bigint.product(s_a, s_b) == s_a_times_b)
  assert(Bigint.product(s_b, s_a) == s_a_times_b)
  assert(Bigint.sum(s_a, s_b) == s_a_plus_b)
  assert(Bigint.sum(s_b, s_a) == s_a_plus_b)
  assert(Bigint.sum(s_wide, s_a) == s_wide_plus_a)
  assert(Bigint.sum(s_a, Bigint.product(s_b, s_b)) == wide(Bigint.add(s_a, Bigint.mul(s_b, s_b)), #s_a + 1),
    "an exponent of the form a + u*x")
end

local function test_leading_zero_bytes_change_a_width_and_no_number()
  local zeros = string.rep("\0", 24)
  assert(Bigint.mulmod(zeros .. s_a, zeros .. s_b, p3072) == s_a_times_b_mod_p)
  assert(Bigint.mulmod(s_a, s_b, zeros .. p3072) == zeros .. s_a_times_b_mod_p)
  assert(Bigint.addmod(zeros .. s_a, s_b, zeros .. p3072) == zeros .. s_a_plus_b_mod_p)
  assert(Bigint.submod(s_b, zeros .. s_a, "\0" .. p3072) == "\0" .. s_b_minus_a_mod_p)
  assert(Bigint.reduce(zeros .. s_wide, "\0\0\0" .. p3072) == "\0\0\0" .. s_wide_mod_p)
  assert(Bigint.product(zeros .. s_a, s_b) == zeros .. s_a_times_b)
  assert(Bigint.sum(zeros .. s_a, s_b) == zeros .. s_a_plus_b)
end

local function test_arithmetic_for_secrets_at_zero_one_and_the_modulus_less_one()
  local width = #p3072
  local nothing, unit = string.rep("\0", width), wide(one, width)
  local last = assert(Bigint.sub(p3072, one))
  assert(Bigint.mulmod(last, last, p3072) == unit, "minus one, squared")
  assert(Bigint.mulmod(zero, s_a, p3072) == nothing)
  assert(Bigint.mulmod(s_a, "", p3072) == nothing, "the empty string is zero")
  assert(Bigint.mulmod(one, s_a, p3072) == s_a)
  assert(Bigint.mulmod(s_a, one, p3072) == s_a)
  assert(Bigint.addmod(last, one, p3072) == nothing)
  assert(Bigint.addmod(last, last, p3072) == assert(Bigint.sub(p3072, "\2")), "the largest sum of two residues")
  assert(Bigint.addmod(zero, "", p3072) == nothing)
  assert(Bigint.addmod(s_a, zero, p3072) == s_a)
  assert(Bigint.submod(zero, one, p3072) == last, "zero less one is the modulus less one")
  assert(Bigint.submod(zero, last, p3072) == unit)
  assert(Bigint.submod(s_a, s_a, p3072) == nothing)
  assert(Bigint.submod(last, zero, p3072) == last)
  assert(Bigint.reduce("", p3072) == nothing)
  assert(Bigint.reduce(last, p3072) == last)
end

local function test_an_operand_equal_to_the_modulus_is_zero()
  local nothing = string.rep("\0", #p3072)
  assert(Bigint.reduce(p3072, p3072) == nothing)
  assert(Bigint.addmod(p3072, p3072, p3072) == nothing)
  assert(Bigint.mulmod(p3072, s_a, p3072) == nothing)
  assert(Bigint.mulmod(s_a, p3072, p3072) == nothing)
  assert(Bigint.submod(p3072, one, p3072) == assert(Bigint.sub(p3072, one)))
  assert(Bigint.submod(s_a, p3072, p3072) == s_a)
  assert(Bigint.mulmod(Bigint.add(p256, "\2"), "\3", p256) == wide("\6", #p256), "p + 2 is 2 modulo p")
end

local function test_everything_is_zero_modulo_one_and_three_is_the_smallest_modulus_mulmod_works_in()
  assert(Bigint.reduce(s_a, one) == zero)
  assert(Bigint.mulmod(s_a, s_b, one) == zero)
  assert(Bigint.addmod(s_a, s_b, "\0\1") == "\0\0")
  assert(Bigint.submod(zero, one, one) == zero)
  assert(Bigint.mulmod("\2", "\2", "\3") == one)
  assert(Bigint.submod(one, "\2", "\3") == "\2")
end

local function test_arithmetic_for_secrets_agrees_with_the_plain_functions_across_word_boundaries()
  -- A limb is 8 bytes: the lengths cross one, two and three of them, an
  -- operand shorter than, as long as and longer than each modulus.
  for _, modulus_length in ipairs{ 1, 2, 7, 8, 9, 15, 16, 17, 24, 25 } do
    local modulus = drawn(("modulus %d"):format(modulus_length), modulus_length)
    local odd = modulus:sub(1, -2) .. string.char(assert(modulus:byte(-1)) | 1)
    local even = modulus:sub(1, -2) .. string.char(assert(modulus:byte(-1)) & 254 | 2)
    for _, x_length in ipairs{ 0, 1, 7, 8, 9, 16, 17, 33 } do
      for _, y_length in ipairs{ 0, 3, 8, 15, 16, 40 } do
        local x = drawn(("x %d %d"):format(modulus_length, x_length), x_length)
        local y = drawn(("y %d %d"):format(modulus_length, y_length), y_length)
        assert_agreement(x, y, odd)
        assert_agreement(y, x, even)
        assert_agreement(string.rep("\255", x_length), string.rep("\255", y_length), odd)
      end
    end
  end
end

local function test_arithmetic_for_secrets_raises_on_a_zero_modulus()
  local why = Test.raises(function() Bigint.reduce(a, zero) end, "the modulus is zero")
  assert(why:find("bad argument #2 to 'reduce'", 1, true), why)
  Test.raises(function() Bigint.reduce(a, "") end, "the modulus is zero")
  Test.raises(function() Bigint.reduce(a, "\0\0\0") end, "the modulus is zero")
  why = Test.raises(function() Bigint.addmod(a, b, zero) end, "the modulus is zero")
  assert(why:find("bad argument #3 to 'addmod'", 1, true), why)
  Test.raises(function() Bigint.addmod(a, b, "") end, "the modulus is zero")
  why = Test.raises(function() Bigint.submod(a, b, "\0\0") end, "the modulus is zero")
  assert(why:find("bad argument #3 to 'submod'", 1, true), why)
  Test.raises(function() Bigint.submod(a, b, "") end, "the modulus is zero")
  why = Test.raises(function() Bigint.mulmod(a, b, zero) end, "the modulus is zero")
  assert(why:find("bad argument #3 to 'mulmod'", 1, true), why)
  Test.raises(function() Bigint.mulmod(a, b, "") end, "the modulus is zero")
end

local function test_arithmetic_for_secrets_at_the_limits_matches_python()
  local mersenne = string.rep("\255", Bigint.modulus_bytes)
  local v, u = drawn("v", Bigint.operand_bytes), drawn("u", Bigint.operand_bytes)
  local function digest(number: string): string
    return Hash.digest("sha256", number)
  end
  assert(digest(Bigint.mulmod(v, u, mersenne)) == lim_times)
  assert(digest(Bigint.addmod(v, u, mersenne)) == lim_plus)
  assert(digest(Bigint.submod(v, u, mersenne)) == lim_minus)
  assert(digest(Bigint.reduce(v, mersenne)) == lim_mod)
  local product, sum = Bigint.product(v, u), Bigint.sum(v, u)
  assert(#product == 2 * Bigint.operand_bytes and digest(product) == lim_product)
  assert(#sum == Bigint.operand_bytes + 1 and digest(sum) == lim_sum)
  local most = string.rep("\255", Bigint.operand_bytes)
  assert(Bigint.reduce(most, mersenne) == string.rep("\0", Bigint.modulus_bytes),
    "2^16384 - 1 is (2^8192 - 1)(2^8192 + 1)")
  assert(Bigint.mulmod(most, most, mersenne) == string.rep("\0", Bigint.modulus_bytes))
  -- (2^k - 1)^2 is 2^2k - 2^(k+1) + 1, and twice 2^k - 1 is 2^(k+1) - 2.
  assert(Bigint.product(most, most) == string.rep("\255", Bigint.operand_bytes - 1) .. "\254" ..
      string.rep("\0", Bigint.operand_bytes - 1) .. "\1")
  assert(Bigint.sum(most, most) == "\1" .. string.rep("\255", Bigint.operand_bytes - 1) .. "\254")
end

local function test_arithmetic_for_secrets_raises_on_a_number_over_its_limit()
  local over = string.rep("\1", Bigint.operand_bytes + 1)
  local long = string.rep("\1", Bigint.modulus_bytes + 1)
  local says = "the number is longer than 2048 bytes"
  local why = Test.raises(function() Bigint.reduce(over, "\3") end, says)
  assert(why:find("bad argument #1 to 'reduce'", 1, true), why)
  for name, call in pairs{ addmod = Bigint.addmod, submod = Bigint.submod, mulmod = Bigint.mulmod } do
    why = Test.raises(function() call(over, one, "\3") end, says)
    assert(why:find("bad argument #1 to '" .. name .. "'", 1, true), why)
    why = Test.raises(function() call(one, over, "\3") end, says)
    assert(why:find("bad argument #2 to '" .. name .. "'", 1, true), why)
    why = Test.raises(function() call(one, one, long) end, "the number is longer than 1024 bytes")
    assert(why:find("bad argument #3 to '" .. name .. "'", 1, true), why)
  end
  for name, call in pairs{ product = Bigint.product, sum = Bigint.sum } do
    why = Test.raises(function() call(over, one) end, says)
    assert(why:find("bad argument #1 to '" .. name .. "'", 1, true), why)
    why = Test.raises(function() call(one, over) end, says)
    assert(why:find("bad argument #2 to '" .. name .. "'", 1, true), why)
  end
  why = Test.raises(function() Bigint.reduce(one, long) end, "the number is longer than 1024 bytes")
  assert(why:find("bad argument #2 to 'reduce'", 1, true), why)
  -- The limit counts the bytes given: zero, written too long, is refused.
  Test.raises(function() Bigint.sum(string.rep("\0", Bigint.operand_bytes + 1), one) end, says)
end
