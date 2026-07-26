local record G
  hi: function(string): string
end
local g: G = {hi = function(who: string): string return "hi " .. who end}
return g
