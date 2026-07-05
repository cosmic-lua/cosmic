# fuzzy_bench

 Fuzzy-matching scenarios: cosmic.fuzzy.find_similar over a namespace.
 Models a "did you mean?" / autocomplete lookup: one short query matched
 against a large candidate set. The check pins the exact match set so a
 faster-but-wrong matcher (e.g. one that wrongly prunes candidates) fails
 instead of winning.
