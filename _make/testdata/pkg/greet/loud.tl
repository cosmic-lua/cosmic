local record L
  shout: function(string): string
end
local l: L = {shout = function(who: string): string return "HI " .. who:upper() end}
return l
