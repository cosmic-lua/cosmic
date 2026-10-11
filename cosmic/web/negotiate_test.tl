local Negotiate = require("cosmic.web.negotiate")

local HTML_OR_JSON <const>: {string} = { "text/html", "application/json" }

local function test_no_accept_header_takes_the_first_offer()
  assert(Negotiate.best(nil, HTML_OR_JSON) == "text/html")
  assert(Negotiate.best("", HTML_OR_JSON) == "text/html")
  assert(Negotiate.best("  ", { "application/json" }) == "application/json")
  assert(Negotiate.best(nil, {}) == nil)
end

local function test_the_exact_range_beats_the_wildcards()
  assert(Negotiate.best("application/json", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("text/html, application/json", HTML_OR_JSON) == "text/html")
  assert(Negotiate.best("application/json, text/*;q=0.5", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("*/*", HTML_OR_JSON) == "text/html", "a tie goes to the earlier offer")
  assert(Negotiate.best("text/*", HTML_OR_JSON) == "text/html")
end

local function test_the_most_specific_range_gives_the_weight()
  -- text/html is named at 0, so the */* at 1 does not rescue it.
  assert(Negotiate.best("text/html;q=0, */*;q=0.1", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("*/*;q=0.1, text/html;q=0.9", HTML_OR_JSON) == "text/html")
  assert(Negotiate.best("application/json;q=0.8, text/html;q=0.7", HTML_OR_JSON) == "application/json")
end

local function test_a_weight_of_zero_refuses_and_nothing_acceptable_is_nil()
  assert(Negotiate.best("text/html;q=0", { "text/html" }) == nil)
  assert(Negotiate.best("image/png", HTML_OR_JSON) == nil)
  assert(Negotiate.best("text/plain", HTML_OR_JSON) == nil)
end

local function test_a_malformed_range_or_weight_is_skipped()
  assert(Negotiate.best("garbage, text/html", HTML_OR_JSON) == "text/html")
  assert(Negotiate.best("text/html;q=abc, application/json", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("text/html;q=1.5, application/json", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("*/html, application/json", HTML_OR_JSON) == "application/json")
end

local function test_a_weight_needs_its_dot_before_fraction_digits()
  assert(Negotiate.best("text/html;q=01, application/json;q=0.5", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("text/html;q=05, application/json;q=0.1", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("text/html;q=0.5, application/json;q=1.", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("text/html;q=1.0000, application/json;q=0.1", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("text/html;q=1, application/json;q=0.999", HTML_OR_JSON) == "text/html")
end

local function test_an_accept_header_with_no_valid_range_is_read_as_absent()
  assert(Negotiate.best(",,,", HTML_OR_JSON) == "text/html")
  assert(Negotiate.best("garbage", HTML_OR_JSON) == "text/html")
  assert(Negotiate.best("text/html;q=abc", HTML_OR_JSON) == "text/html")
  assert(Negotiate.best("text/html;q=0", HTML_OR_JSON) == nil, "a valid range that refuses all is not garbage")
  assert(Negotiate.best("image/png", HTML_OR_JSON) == nil, "a valid range that matches none is not garbage")
end

local function test_case_and_spaces_do_not_matter()
  assert(Negotiate.best("Application/JSON ; Q=0.5 , TEXT/HTML ; q=0.2", HTML_OR_JSON) == "application/json")
  assert(Negotiate.best("text/html;level=1;q=0.4, application/json;q=0.3", HTML_OR_JSON) == "text/html")
end
