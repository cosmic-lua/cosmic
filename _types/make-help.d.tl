local record make_help
  record Item
    type: string
    name: string
    description: string
  end

  parse_makefile: function(content: string): {Item}
  format_help: function(items: {Item}): string
  parse_phony_targets: function(content: string): {string: boolean}
end

return make_help
