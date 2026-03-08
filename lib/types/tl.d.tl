local record tl
  record Error
    filename: string
    y: number
    x: number
    msg: string
  end

  record Result
    ast: any
    syntax_errors: {Error}
    type_errors: {Error}
    warnings: {Error}
  end

  record Token
    x: integer
    y: integer
    tk: string
    kind: string
    comments: {any}
  end

  path: string
  loader: function()
  init_env: function(boolean): any
  lex: function(string, string): {Token}, {Error}
  parse_program: function({Token}, {Error}, string, string): any, {string}
  process_string: function(string, boolean, any, string): Result, string
  generate: function(any, {string: any}): string
end

return tl
