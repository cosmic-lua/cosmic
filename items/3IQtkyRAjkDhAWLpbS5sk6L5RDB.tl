return {
  ["block_reason"] = {
    ["3IQtfuCxCSIf6gYSrAjOcxC07Df"] = "the pin bump needs a cosmos release whose path.join returns plain string; bumping before it exists regenerates the same union",
    ["3IQtg7Sm2UyFfiqgJ55GGh4yWOs"] = "the pin bump needs a cosmos release whose clock_gettime returns plain integers; the time.tl asserts cannot retire before it",
  },
  ["blocked_by"] = "3IQtfuCxCSIf6gYSrAjOcxC07Df 3IQtg7Sm2UyFfiqgJ55GGh4yWOs",
  ["builders"] = "7b2d5794-d8f2-5252-98a4-78fd6c9236e6",
  ["claim"] = "7b2d5794-d8f2-5252-98a4-78fd6c9236e6",
  ["id"] = "3IQtkyRAjkDhAWLpbS5sk6L5RDB",
  ["parent"] = "3IQtewgN78SnlsiBLPgF1i3VNKE",
  ["phase"] = "check",
  ["pr"] = 1395,
  ["title"] = "cosmic: consume the exact contracts — pin bump, retire the join and clock asserts",
}
