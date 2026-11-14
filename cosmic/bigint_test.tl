--- Proves [`cosmic.bigint`] against values worked by hand and against
--- Python's integers (`pow(b, e, m)`, `*`, `%`), whose answers are
--- embedded as hexadecimal: every operation, the edges of each, and every
--- refusal and raise.

local Bigint = require("cosmic.bigint")
local Codec = require("cosmic.codec")
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
  assert(padded == nil and why == "bigint: the number needs 1 bytes, more than 0", why)
  padded, why = Bigint.pad(p3072, 383)
  assert(padded == nil and why == "bigint: the number needs 384 bytes, more than 383", why)
  Test.raises(function() Bigint.pad(one, -1) end, "pad's width must be 0 or more")
end
