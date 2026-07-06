# lsqlite3

Type declarations for the `lsqlite3` module.

## Types

### Context

 A callback context is available as a parameter inside the callback functions
 `db:create_aggregate()` and `db:create_function()`. It can be used to get
 further information about the state of a query.

```teal
local record Context
  get_aggregate_data: function(self: Context): any
  --  Set the user-definable data field for callback funtions to `udata`.
  set_aggregate_data: function(self: Context, udata: any)
  --  Sets the result of a callback function to `res`. The type of the result
  --  depends on the type of `res` and is either a number or a string or `nil`.
  --  All other values will raise an error message.
  result: function(self: Context, res?: string | number)
  --  Sets the result of a callback function to the binary string in blob.
  result_blob: function(self: Context, blob: string)
  --  Sets the result of a callback function to the value number.
  result_double: function(self: Context, double: number)
  --  Sets the result of a callback function to the value number. Alias for
  --  `lsqlite3.Context:result_double()`.
  result_number: function(self: Context, double: number)
  --  Sets the result of a callback function to the error value in `err`.
  result_error: function(self: Context, err: any)
  --  Sets the result of a callback function to the integer `number`
  result_int: function(self: Context, number: number)
  --  Sets the result of a callback function to `nil`.
  result_null: function(self: Context)
  --  Sets the result of a callback function to the string in `str`.
  result_text: function(self: Context, str: string)
  --  Returns the userdata parameter given in the call to install the callback
  --  function (see db:create_aggregate() and db:create_function() for details).
  user_data: function(self: Context): any
end
```

### Database

 After opening a database with `lsqlite3.open()` or `lsqlite3.open_memory()`
 the returned database object should be used for all further method calls in
 connection with that database.

```teal
local record Database
  apply_changeset: function(self: Database, changeset: string, conflict_cb: function, filter_cb: function, udata?: any, rebaser?: Rebaser, flags?: number): boolean | nil, number
  --  Sets or removes a busy handler for a database.
  --  The handler function is called with two parameters: `udata` and the number
  --  of (re-)tries for a pending transaction. It should return `nil`, `false` or
  --  `0` if the transaction is to be aborted. All other values will result in
  --  another attempt to perform the transaction. (See the SQLite documentation
  --  for important hints about writing busy handlers.)
  busy_handler: function(self: Database, func?: function(udata: any, tries: number), udata?: any)
  --  Sets a busy handler that waits for `milliseconds` if a transaction cannot proceed.
  --  Calling this function will remove any busy handler set by `db:busy_handler()`;
  --  calling it with an argument less than or equal to `0` will turn off all busy handlers.
  busy_timeout: function(self: Database, milliseconds: number)
  --  Only changes that are directly specified by INSERT, UPDATE, or DELETE
  --  statements are counted. Auxiliary changes caused by triggers are not
  --  counted. Use `db:total_changes()` to find the total number of changes.
  changes: function(self: Database): number
  --  Closes a database. All SQL statements prepared using `db:prepare()` should
  --  have been finalized before this function is called. The function returns
  --  `lsqlite3.OK` on success or else a numerical error code.
  close: function(self: Database): number
  --  Finalizes all statements that have not been explicitly finalized. If
  --  `temponly` is `true`, only internal, temporary statements are finalized.
  close_vm: function(self: Database, temponly?: boolean)
  --  This function installs a `commit_hook` callback handler.
  --  If `func` returns `false` or `nil` the COMMIT is allowed to proceed,
  --  otherwise the COMMIT is converted to a ROLLBACK.
  --  See: `db:rollback_hook` and `db:update_hook`
  commit_hook: function(self: Database, func: function(udata: any), udata: any)
  --  Concatenate a list of changesets.
  concat_changeset: function(self: Database, changesets: {string}): string
  --  It should accept a function context (see Methods for callback contexts) plus
  --  the same number of parameters as given in `nargs`.
  --  It receives one argument, the function context.
  --  The function context can be used inside the two callback functions to
  --  communicate with SQLite3. Here is a simple example:
  --      db:exec[=[
  --          CREATE TABLE numbers(num1,num2);
  --          INSERT INTO numbers VALUES(1,11);
  --          INSERT INTO numbers VALUES(2,22);
  --          INSERT INTO numbers VALUES(3,33);
  --      ]=]
  --      local num_sum=0
  --      local function oneRow(context, num)  -- add one column in all rows
  --          num_sum = num_sum + num
  --      end
  --      local function afterLast(context)   -- return sum after last row has been processed
  --          context:result_number(num_sum)
  --          num_sum = 0
  --      end
  --      db:create_aggregate("do_the_sums", 1, oneRow, afterLast)
  --      for sum in db:urows('SELECT do_the_sums(num1) FROM numbers') do print("Sum of col 1:",sum) end
  --      for sum in db:urows('SELECT do_the_sums(num2) FROM numbers') do print("Sum of col 2:",sum) end
  --  This prints:
  --      Sum of col 1:   6
  --      Sum of col 2:   66
  create_aggregate: function(self: Database, name: string, nargs: number, step: function(ctx: Context, ...: string | number), final: function(ctx: Context), userdata?: any): boolean
  --  This creates a collation callback. A collation callback is used to establish
  --  a collation order, mostly for string comparisons and sorting purposes.
  --  A simple example:
  --     local function collate(s1,s2)
  --       s1=s1:lower()
  --       s2=s2:lower()
  --       if s1==s2 then return 0
  --       elseif s1<s2 then return -1
  --       else return 1 end
  --     end
  --     db:exec[=[
  --       CREATE TABLE test(id INTEGER PRIMARY KEY,content COLLATE CINSENS);
  --       INSERT INTO test VALUES(NULL,'hello world');
  --       INSERT INTO test VALUES(NULL,'Buenos dias');
  --       INSERT INTO test VALUES(NULL,'HELLO WORLD');
  --     ]=]
  --     db:create_collation('CINSENS',collate)
  --     for row in db:nrows('SELECT * FROM test') do
  --       print(row.id, row.content)
  --     end
  create_collation: function(self: Database, name: string, func: (function(s1: string, s2: string): number))
  --  This function creates a callback function. Callback function are called by
  --  SQLite3 once for every row in a query.
  --  It should accept a function context (see Methods for callback contexts) plus
  --  the same number of parameters as given in `nargs`.
  --  Here is an example:
  --      db:exec'CREATE TABLE test(col1,col2,col3)'
  --      db:exec'INSERT INTO test VALUES(1,2,4)'
  --      db:exec'INSERT INTO test VALUES(2,4,9)'
  --      db:exec'INSERT INTO test VALUES(3,6,16)'
  --      db:create_function('sum_cols',3,function(ctx,a,b,c)
  --        ctx:result_number(a+b+c)
  --      end))
  --      for col1,col2,col3,sum in db:urows('SELECT *,sum_cols(col1,col2,col3) FROM test') do
  --        util.printf('%2i+%2i+%2i=%2i\n',col1,col2,col3,sum)
  --      end
  create_function: function(self: Database, name: string, nargs: number, func: function(ctx: Context, ...: any), userdata?: any): boolean
  create_rebaser: function(self: Database): Rebaser | nil, number
  create_session: function(self: Database, name?: string): Session | nil, number
  --  If there is no attached database name on the database connection, then no value is
  --  returned; if database name is a temporary or in-memory database, then an
  --  empty string is returned.
  db_filename: function(self: Database, name: string): string | nil
  --  Deserializes data from a string which was created by `db:serialize`.
  deserialize: function(self: Database, s: string)
  --  See https://lua.sqlite.org/home/doc/tip/doc/lsqlite3.wiki#numerical_error_and_result_codes for details.
  error_code: function(self: Database): number
  --  Alias for `lsqlite3.Database:error_code()`.
  errcode: function(self: Database): number
  error_message: function(self: Database): string
  --  Alias for `lsqlite3.Database:error_message()`.
  errmsg: function(self: Database): string
  --  Compiles and executes the SQL statement(s) given in string sql. The statements
  --  are simply executed one after the other and not stored. The function returns
  --  `lsqlite3.OK` on success or else a numerical error code.
  --  If one or more of the SQL statements are queries, then the callback function
  --  specified in func is invoked once for each row of the query result (if func is
  --  `nil`, no callback is invoked).
  --  The callback receives four arguments:
  --  -  `udata (the third parameter of the db:exec() call),
  --  - the number of columns in the row
  --  - a table with the column values
  --  - another table with the column names.
  --  The callback function should return `0`. If the callback returns a non-zero
  --  value then the query is aborted, all subsequent SQL statements are skipped
  --  and `db:exec()` returns `lsqlite3.ABORT`. Here is a simple example:
  --      sql=[=[
  --          CREATE TABLE numbers(num1,num2,str);
  --          INSERT INTO numbers VALUES(1,11,"ABC");
  --          INSERT INTO numbers VALUES(2,22,"DEF");
  --          INSERT INTO numbers VALUES(3,33,"UVW");
  --          INSERT INTO numbers VALUES(4,44,"XYZ");
  --          SELECT * FROM numbers;
  --      ]=]
  --      function showrow(udata,cols,values,names)
  --          assert(udata=='test_udata')
  --          print('exec:')
  --          for i=1,cols do print('',names[i],values[i]) end
  --          return 0
  --      end
  --      db:exec(sql,showrow,'test_udata')
  execute: function(self: Database, sql: string, func?: (function(udata: any, cols: number, values: {string}, names: {string}): number), udata?: any)
  --  Alias for `lsqlite3.Database:execute()`.
  exec: function(self: Database, sql: string, func?: (function(udata: any, cols: number, values: {string}, names: {string}): number), udata?: any)
  --  This function causes any pending database operation to abort and return at
  --  the next opportunity.
  interrupt: function(self: Database)
  invert_changeset: function(self: Database, changeset: string): string
  isopen: function(self: Database): boolean
  iterate_changeset: function(self: Database, name: string, flags?: number): Iterator | nil, number
  --  Each row in an SQLite table has a unique 64-bit signed integer key called
  --  the rowid. This id is always available as an undeclared column named ROWID,
  --  OID, or _ROWID_. If the table has a column of type INTEGER PRIMARY KEY then
  --  that column is another alias for the rowid.
  --  If an INSERT occurs within a trigger, then the rowid of the inserted row is
  --  returned as long as the trigger is running. Once the trigger terminates, the
  --  value returned reverts to the last value inserted before the trigger fired.
  last_insert_rowid: function(self: Database): number
  --  Creates an iterator that returns the successive rows selected by the
  --  SQL statement given in string `sql`. Each call to the iterator
  --  returns a table in which the named fields correspond to the columns
  --  in the database. Here is an example:
  --      db:exec[=[
  --          CREATE TABLE numbers(num1,num2);
  --          INSERT INTO numbers VALUES(1,11);
  --          INSERT INTO numbers VALUES(2,22);
  --          INSERT INTO numbers VALUES(3,33);
  --      ]=]
  --      for a in db:nrows('SELECT * FROM numbers') do table.print(a) end
  --  This script prints:
  --      num2: 11
  --      num1: 1
  --      num2: 22
  --      num1: 2
  --      num2: 33
  --      num1: 3
  nrows: function(self: Database, sql: string): function(vm: VM), VM
  --  This function compiles the SQL statement in string sql into an internal
  --  representation and returns this as userdata. The returned object should be
  --  used for all further method calls in connection with this specific SQL
  --  statement.
  --  See https://lua.sqlite.org/home/doc/tip/doc/lsqlite3.wiki#methods_for_prepared_statements for details.
  prepare: function(self: Database, sql: string): Statement
  --  Returns `true` if the database `name` of connection `db` is read-only,
  --  `false` if it is read/write. Returns `nil` plus an error message if
  --  `name` is not the name of a database on connection `db`.
  readonly: function(self: Database, name?: string): boolean | nil, string
  --  This function installs a rollback_hook callback handler.
  --  See: `db:commit_hook` and `db:update_hook`
  rollback_hook: function(self: Database, func: function(udata: any), udata: any)
  --  Creates an iterator that returns the successive rows selected by the SQL
  --  statement given in string `sql`. Each call to the iterator returns a table in
  --  which the numerical indices 1 to n correspond to the selected columns 1 to n in
  --  the database. Here is an example:
  --      db:exec[=[
  --          CREATE TABLE numbers(num1,num2);
  --          INSERT INTO numbers VALUES(1,11);
  --          INSERT INTO numbers VALUES(2,22);
  --          INSERT INTO numbers VALUES(3,33);
  --      ]=]
  --      for a in db:rows('SELECT * FROM numbers') do table.print(a) end
  --  This script prints:
  --      1: 1
  --      2: 11
  --      1: 2
  --      2: 22
  --      1: 3
  --      2: 33
  rows: function(self: Database, sql: string): function, VM
  --  Serialize a database to be restored later with `Database:deserialize`.
  serialize: function(self: Database): string | nil
  --  This includes UPDATE, INSERT and DELETE statements executed as part of trigger
  --  programs. All changes are counted as soon as the statement that produces them
  --  is completed by calling either `stmt:reset()` or `stmt:finalize()`.
  total_changes: function(self: Database): number
  --  This function installs an update_hook Data Change Notification
  --  Callback handler. See: `db:commit_hook` and `db:rollback_hook`
  --  whenever a row is updated, inserted or deleted. This callback
  --  receives five arguments: the first is the `udata` argument used
  --  when the callback was installed; the second is an integer
  --  indicating the operation that caused the callback to be invoked
  --  (one of `lsqlite3.UPDATE`, `lsqlite3.INSERT`, or
  --  `lsqlite3.DELETE`). The third and fourth arguments are the
  --  database and table name containing the affected row. The final
  --  callback parameter is the rowid of the row. In the case of an
  --  update, this is the rowid after the update takes place.
  update_hook: function(self: Database, func: function(udata: any, op: number, db: Database, name: string, rowid: number), udata: any)
  --  Creates an iterator that returns the successive rows selected by the SQL
  --  statement given in string sql. Each call to the iterator returns the values
  --  that correspond to the columns in the currently selected row.
  --  Here is an example:
  --      db:exec[=[
  --          CREATE TABLE numbers(num1,num2);
  --          INSERT INTO numbers VALUES(1,11);
  --          INSERT INTO numbers VALUES(2,22);
  --          INSERT INTO numbers VALUES(3,33);
  --      ]=]
  --      for num1,num2 in db:urows('SELECT * FROM numbers') do print(num1,num2) end
  --  This script prints:
  --      1       11
  --      2       22
  --      3       33
  urows: function(self: Database, sql: string): function, VM
  wal_checkpoint: function(self: Database, mode?: number, name?: string): number | nil, number, number
  wal_hook: function(self: Database, func?: (function(udata: any, db: Database, name: string, page_count: number): number), udata?: any)
end
```

### Iterator

 Returned by `db:iterate_changeset`

```teal
local record Iterator
  conflict: function(self: Iterator): {string | number | boolean} | nil, number
  fk_conflicts: function(self: Iterator): number | nil, number
  finalize: function(self: Iterator): boolean | nil, number
  next: function(self: Iterator): number | nil, number
  new: function(self: Iterator): {string | number | boolean | nil}, number
  old: function(self: Iterator): {string | number | boolean | nil}, number
  op: function(self: Iterator): string | nil, number, boolean, number
  pk: function(self: Iterator): {boolean} | nil, number
end
```

### Rebaser

 Returned by `db:create_rebaser`.

```teal
local record Rebaser
  delete: function(self: Rebaser)
  rebase: function(self: Rebaser, changeset: string): string | nil, number
end
```

### Session

 Returned by `db:create_session`.

```teal
local record Session
  attach: function(self: Session, filter_cb?: function(udata: any), udata?: any): boolean | nil, number
  changeset: function(self: Session): string
  --  Closes the session. Further method calls on the session will throw errors.
  delete: function(self: Session)
  diff: function(self: Session, s1: string, s2: string): boolean
  enable: function(self: Session): boolean
  indirect: function(self: Session): boolean
  isempty: function(self: Session): boolean
  patchset: function(self: Session): string
end
```

### Statement

 After creating a prepared statement with `db:prepare()` the returned statement
 object should be used for all further calls in connection with that statement.

```teal
local record Statement
  --  Binds `value` to statement parameter `n`. If the type of `value` is
  --  string it is bound as text. If the type of value is number, it is
  --  bound as an integer or double depending on its subtype using
  --  `lua_isinteger`. If `value` is a boolean then it is bound as `0` for
  --  `false` or `1` for `true`. If `value` is `nil` or missing, any
  --  previous binding is removed.
  bind: function(self: Statement, n: number, value: string | number | boolean): number
  --  Binds string `blob` (which can be a binary string) as a blob to
  --  statement parameter `n`.
  bind_blob: function(self: Statement, n: number, blob: string): number
  --  Binds the values in `nametable` to statement parameters. If the
  --  statement parameters are named (i.e., of the form `":AAA"` or
  --  `"$AAA"`) then this function looks for appropriately named fields in
  --  nametable; if the statement parameters are not named, it looks for
  --  numerical fields 1 to the number of statement parameters.
  bind_names: function(self: Statement, nametable: table): number, number
  --  When the statement parameters are of the forms `":AAA"` or `"?"`, then they are
  --  assigned sequentially increasing numbers beginning with one, so the value
  --  returned is the number of parameters. However if the same statement parameter
  --  name is used multiple times, each occurrence is given the same number, so the
  --  value returned is the number of unique statement parameter names.
  --  If statement parameters of the form `"?NNN"` are used (where `NNN` is an
  --  integer) then there might be gaps in the numbering and the value returned by
  --  this interface is the index of the statement parameter with the largest index
  --  value.
  bind_parameter_count: function(self: Statement): any
  --  Statement parameters of the form `":AAA"` or `"@AAA"` or `"$VVV"` have a name
  --  which is the string `":AAA"` or `"@AAA"` or `"$VVV"`. In other words, the
  --  initial `":"` or `"$"` or `"@"` is included as part of the name. Parameters of
  --  the form `"?"` or `"?NNN"` have no name. The first bound parameter has an index
  --  of `1`. If the value `n` is out of range or if the `n`-th parameter is nameless,
  --  then `nil` is returned.
  bind_parameter_name: function(self: Statement, n: number): string | nil
  --  Binds the given values to statement parameters.
  bind_values: function(self: Statement, ...: string | number): number
  columns: function(self: Statement): number
  --  This function frees the prepared statement.
  finalize: function(self: Statement): number
  get_name: function(self: Statement, n: any): any
  get_named_types: function(self: Statement): table
  --  Alias for `lsqlite3.Statement:get_named_types()`.
  type: function(self: Statement): table
  get_named_values: function(self: Statement): table
  --  Alias for `lsqlite3.Statement:get_named_values()`.
  data: function(self: Statement): table
  get_names: function(self: Statement): {string}
  --  Alias for `lsqlite3.Statement:get_names()`.
  inames: function(self: Statement): {string}
  get_type: function(self: Statement, n: any): any
  get_types: function(self: Statement): {any}
  --  Alias for `lsqlite3.Statement:get_types()`.
  itypes: function(self: Statement): {any}
  get_unames: function(self: Statement): {any}
  get_utypes: function(self: Statement): {any}
  get_uvalues: function(self: Statement): {any}
  get_value: function(self: Statement, n: any): any
  get_values: function(self: Statement): {any}
  --  Alias for `lsqlite3.Statement:get_values()`.
  idata: function(self: Statement): {any}
  isopen: function(self: Statement): boolean
  nrows: function(self: Statement): function
  --  Returns `true` if the prepared statement makes no direct changes to
  --  the content of the database file, `false` otherwise.
  readonly: function(self: Statement): boolean
  --  This function resets the SQL statement, so that it is ready to be re-executed. Any statement variables that had values bound to them using the `stmt:bind*()` functions retain their values.
  reset: function(self: Statement)
  rows: function(self: Statement): function
  --  This function must be called to evaluate the (next iteration of the) prepared statement.
  --  - `lsqlite3.BUSY`: the engine was unable to acquire the locks needed.
  --    If the statement is a COMMIT or occurs outside of an explicit transaction,
  --    then you can retry the statement. If the statement is not a COMMIT and occurs
  --    within a explicit transaction then you should rollback the transaction before
  --    continuing.
  --  - `lsqlite3.DONE`: the statement has finished executing successfully.
  --    `stmt:step()` should not be called again on this statement without first
  --    calling `stmt:reset()` to reset the virtual machine back to the initial state.
  --  - `lsqlite3.ROW`: this is returned each time a new row of data is ready for
  --     processing by the caller. The values may be accessed using the column access
  --     functions. `stmt:step()` can be called again to retrieve the next
  --     row of data.
  --  - `lsqlite3.ERROR`: a run-time error (such as a constraint violation) has
  --     occurred. `stmt:step()` should not be called again. More
  --     information may be found by calling `db:errmsg()`. A more specific error
  --     code (can be obtained by calling `stmt:reset()`.
  --  - `lsqlite3.MISUSE`: the function was called inappropriately, perhaps because
  --     the statement has already been finalized or a previous call to `stmt:step()`
  --     has returned `lsqlite3.ERROR` or `lsqlite3.DONE`.
  step: function(self: Statement): number
  --  Each iteration returns the values for the current row. This is the prepared
  --  statement equivalent of `db:urows()`.
  urows: function(self: Statement): function
  last_insert_rowid: function(self: Statement): any
end
```

### VM

```teal
local record VM
  bind: function(self: VM, index: number, value: string | number | boolean): number
  bind_blob: function(self: VM, index: number, value: string): number
  bind_names: function(self: VM, names: {string}): number
  bind_parameter_count: function(self: VM): number
  bind_parameter_name: function(self: VM, index: number): string
  bind_values: function(self: VM, ...: string | number): number
  columns: function(self: VM): number
  finalize: function(self: VM): number
  get_name: function(self: VM, index: number): string
  get_named_types: function(self: VM): {string}
  --  Alias for `lsqlite3.VM:get_named_types()`.
  type: function(self: VM): {string}
  get_named_values: function(self: VM): {string | number | nil}
  --  Alias for `lsqlite3.VM:get_named_values()`.
  data: function(self: VM): {string | number | nil}
  get_names: function(self: VM): {string}
  --  Alias for `lsqlite3.VM:get_names()`.
  inames: function(self: VM): {string}
  get_type: function(self: VM, index: number): string
  get_types: function(self: VM): {string}
  --  Alias for `lsqlite3.VM:get_types()`.
  itypes: function(self: VM): {string}
  get_unames: function(self: VM): string...
  get_utypes: function(self: VM): string...
  get_uvalues: function(self: VM): string | number | nil
  get_value: function(self: VM, index: number): string | number | nil
  get_values: function(self: VM): {string | number | nil}
  --  Alias for `lsqlite3.VM:get_values()`.
  idata: function(self: VM): {string | number | nil}
  isopen: function(self: VM): boolean
  last_insert_rowid: function(self: VM): number
  nrows: function(self: VM, sql: string): function(self: VM): {string: string | number}
  --  Returns `true` if the prepared statement makes no direct changes to
  --  the content of the database file, `false` otherwise.
  readonly: function(self: VM): boolean
  reset: function(self: VM): number
  rows: function(self: VM, sql: string): function(self: VM): {string | number}
  step: function(self: VM): number
  urows: function(self: VM, sql: string): function(self: VM): any...
end
```

### lsqlite3 Constants

Constants defined in the lsqlite3 module.

```teal
local record lsqlite3 Constants
  --  The `lsqlite3.OK` result code means that the operation was successful
  --  and that there were no errors. Most other result codes indicate an
  --  error.
  OK: number
  --  The `lsqlite3.ERROR` result code is a generic error code that is used
  --  when no other more specific error code is available.
  ERROR: number
  --  The `lsqlite3.INTERNAL` result code indicates an internal malfunction.
  --  In a working version of SQLite, an application should never see this
  --  result code. If application does encounter this result code, it shows
  --  that there is a bug in the database engine.
  --  SQLite does not currently generate this result code. However,
  --  application-defined SQL functions or virtual tables, or VFSes, or other
  --  extensions might cause this result code to be returned.
  INTERNAL: number
  --  The `lsqlite3.PERM` result code indicates that the requested access mode
  --  for a newly created database could not be provided.
  PERM: number
  --  The `lsqlite3.ABORT` result code indicates that an operation was aborted
  --  prior to completion, usually be application request. See also:
  --  `lsqlite3.INTERRUPT`.
  --  If the callback function to `exec()` returns non-zero, then `exec()`
  --  will return `lsqlite3.ABORT`.
  --  If a ROLLBACK operation occurs on the same database connection as a
  --  pending read or write, then the pending read or write may fail with an
  --  `lsqlite3.ABORT` error.
  ABORT: number
  --  The lsqlite3.BUSY result code indicates that the database file could not
  --  be written (or in some cases read) because of concurrent activity by
  --  some other database connection, usually a database connection in a
  --  separate process.
  --  For example, if process A is in the middle of a large write transaction
  --  and at the same time process B attempts to start a new write
  --  transaction, process B will get back an `lsqlite3.BUSY` result because
  --  SQLite only supports one writer at a time. Process B will need to wait
  --  for process A to finish its transaction before starting a new
  --  transaction. The `db:busy_timeout()` and `db:busy_handler()` interfaces
  --  are available to process B to help it deal with `lsqlite3.BUSY` errors.
  --  An `lsqlite3.BUSY` error can occur at any point in a transaction: when
  --  the transaction is first started, during any write or update operations,
  --  or when the transaction commits. To avoid encountering `lsqlite3.BUSY`
  --  errors in the middle of a transaction, the application can use
  --  `BEGIN IMMEDIATE` instead of just `BEGIN` to start a transaction. The
  --  `BEGIN IMMEDIATE` command might itself return `lsqlite3.BUSY`, but if it
  --  succeeds, then SQLite guarantees that no subsequent operations on the same database through the next COMMIT will return `lsqlite3.BUSY`.
  --  The `lsqlite3.BUSY` result code differs from `lsqlite3.LOCKED` in that
  --  `lsqlite3.BUSY` indicates a conflict with a separate database
  --  connection, probably in a separate process, whereas `lsqlite3.LOCKED`
  --  indicates a conflict within the same database connection (or sometimes
  --  a database connection with a shared cache).
  BUSY: number
  --  The `lsqlite3.LOCKED` result code indicates that a write operation could
  --  not continue because of a conflict within the same database connection
  --  or a conflict with a different database connection that uses a shared
  --  cache.
  --  For example, a DROP TABLE statement cannot be run while another thread
  --  is reading from that table on the same database connection because
  --  dropping the table would delete the table out from under the concurrent
  --  reader.
  --  The `lsqlite3.LOCKED` result code differs from `lsqlite3.BUSY` in that
  --  `lsqlite3.LOCKED` indicates a conflict on the same database connection
  --  (or on a connection with a shared cache) whereas `lsqlite3.BUSY`
  --  indicates a conflict with a different database connection, probably in
  --  a different process.
  LOCKED: number
  --  The `lsqlite3.NOMEM` result code indicates that SQLite was unable to
  --  allocate all the memory it needed to complete the operation. In other
  --  words, an internal call to `sqlite3_malloc()` or `sqlite3_realloc()` has
  --  failed in a case where the memory being allocated was required in order
  --  to continue the operation.
  NOMEM: number
  --  The `lsqlite3.READONLY` result code is returned when an attempt is made
  --  to alter some data for which the current database connection does not
  --  have write permission.
  READONLY: number
  --  The `lsqlite3.INTERRUPT` result code indicates that an operation was
  --  interrupted by the `sqlite3_interrupt()` interface. See also:
  --  `lsqlite3.ABORT`
  INTERRUPT: number
  --  The `lsqlite3.IOERR` result code says that the operation could not
  --  finish because the operating system reported an I/O error.
  --  A full disk drive will normally give an `lsqlite3.FULL` error rather
  --  than an `lsqlite3.IOERR` error.
  --  There are many different extended result codes for I/O errors that
  --  identify the specific I/O operation that failed.
  IOERR: number
  --  The `lsqlite3.CORRUPT` result code indicates that the database file has
  --  been corrupted. See [How To Corrupt Your Database Files](https://www.sqlite.org/lockingv3.html#how_to_corrupt)
  --  for further discussion on how corruption can occur.
  CORRUPT: number
  --  The `lsqlite3.NOTFOUND` result code is exposed in three ways:
  --  `lsqlite3.NOTFOUND` can be returned by the `sqlite3_file_control()`
  --  interface to indicate that the file control opcode passed as the third
  --  argument was not recognized by the underlying VFS.
  --  `lsqlite3.NOTFOUND` can also be returned by the xSetSystemCall() method
  --  of an sqlite3_vfs object.
  --  `lsqlite3.NOTFOUND` an be returned by sqlite3_vtab_rhs_value() to
  --  indicate that the right-hand operand of a constraint is not available
  --  to the xBestIndex method that made the call.
  --  The `lsqlite3.NOTFOUND` result code is also used internally by the
  --  SQLite implementation, but those internal uses are not exposed to the
  --  application.
  NOTFOUND: number
  --  The `lsqlite3.FULL` result code indicates that a write could not
  --  complete because the disk is full. Note that this error can occur when
  --  trying to write information into the main database file, or it can also
  --  occur when writing into temporary disk files.
  --  Sometimes applications encounter this error even though there is an
  --  abundance of primary disk space because the error occurs when writing
  --  into temporary disk files on a system where temporary files are stored
  --  on a separate partition with much less space that the primary disk.
  FULL: number
  --  The `lsqlite3.CANTOPEN` result code indicates that SQLite was unable to
  --  open a file. The file in question might be a primary database file or
  --  one of several temporary disk files.
  CANTOPEN: number
  --  The `lsqlite3.PROTOCOL` result code indicates a problem with the file
  --  locking protocol used by SQLite. The `lsqlite3.PROTOCOL` error is
  --  currently only returned when using WAL mode and attempting to start a
  --  new transaction. There is a race condition that can occur when two
  --  separate database connections both try to start a transaction at the
  --  same time in WAL mode. The loser of the race backs off and tries again,
  --  after a brief delay. If the same connection loses the locking race
  --  dozens of times over a span of multiple seconds, it will eventually give
  --  up and return `lsqlite3.PROTOCOL`. The `lsqlite3.PROTOCOL` error should
  --  appear in practice very, very rarely, and only when there are many
  --  separate processes all competing intensely to write to the same
  --  database.
  PROTOCOL: number
  --  The `lsqlite3.EMPTY` result code is not currently used.
  EMPTY: number
  --  The `lsqlite3.SCHEMA` result code indicates that the database schema has
  --  changed. This result code can be returned from `Statement:step()`. If
  --  the database schema was changed by some other process in between the
  --  time that the statement was prepared and the time the statement was run,
  --  this error can result.
  --  The statement is automatically re-prepared if the schema changes, up to
  --  `SQLITE_MAX_SCHEMA_RETRY` times (default: 50). The `step()` interface
  --  will only return `lsqlite3.SCHEMA` back to the application if the
  --  failure persists after these many retries.
  SCHEMA: number
  --  The `lsqlite3.TOOBIG` error code indicates that a string or BLOB was too
  --  large. The default maximum length of a string or BLOB in SQLite is
  --  1,000,000,000 bytes. This maximum length can be changed at compile-time
  --  using the `SQLITE_MAX_LENGTH` compile-time option. The `lsqlite3.TOOBIG`
  --  error results when SQLite encounters a string or BLOB that exceeds the
  --  compile-time limit.
  --  The `lsqlite3.TOOBIG` error code can also result when an oversized SQL
  --  statement is passed into one of the `db:prepare()` interface. The
  --  maximum length of an SQL statement defaults to a much smaller value of
  --  1,000,000,000 bytes.
  TOOBIG: number
  --  The `lsqlite3.CONSTRAINT` error code means that an SQL constraint
  --  violation occurred while trying to process an SQL statement. Additional
  --  information about the failed constraint can be found by consulting the
  --  accompanying error message (returned via `errmsg()`) or by looking at
  --  the extended error code.
  --  The `lsqlite3.CONSTRAINT` code can also be used as the return value from
  --  the `xBestIndex()` method of a virtual table implementation. When
  --  `xBestIndex()` returns `lsqlite3.CONSTRAINT`, that indicates that the
  --  particular combination of inputs submitted to `xBestIndex()` cannot
  --  result in a usable query plan and should not be given further
  --  consideration.
  CONSTRAINT: number
  --  SQLite is normally very forgiving about mismatches between the type of a
  --  value and the declared type of the container in which that value is to
  --  be stored. For example, SQLite allows the application to store a large
  --  BLOB in a column with a declared type of BOOLEAN. But in a few cases,
  --  SQLite is strict about types. The `lsqlite3.MISMATCH` error is returned
  --  in those few cases when the types do not match.
  --  The rowid of a table must be an integer. Attempt to set the rowid to
  --  anything other than an integer (or a NULL which will be automatically
  --  converted into the next available integer rowid) results in an
  --  `lsqlite3.MISMATCH` error.
  MISMATCH: number
  --  The `lsqlite3.MISUSE` return code might be returned if the application
  --  uses any SQLite interface in a way that is undefined or unsupported. For
  --  example, using a prepared statement after that prepared statement has
  --  been finalized might result in an `lsqlite3.MISUSE` error.
  --  SQLite tries to detect misuse and report the misuse using this result
  --  code. However, there is no guarantee that the detection of misuse will
  --  be successful. Misuse detection is probabilistic. Applications should
  --  never depend on an `lsqlite3.MISUSE` return value.
  --  If SQLite ever returns `lsqlite3.MISUSE` from any interface, that means
  --  that the application is incorrectly coded and needs to be fixed. Do not
  --  ship an application that sometimes returns `lsqlite3.MISUSE` from a
  --  standard SQLite interface because that application contains potentially
  --  serious bugs.
  MISUSE: number
  --  The `lsqlite3.NOLFS` error can be returned on systems that do not
  --  support large files when the database grows to be larger than what the
  --  filesystem can handle. "NOLFS" stands for "NO Large File Support".
  NOLFS: number
  --  The `lsqlite3.FORMAT` error code is not currently used by SQLite.
  FORMAT: number
  --  The `lsqlite3.RANGE` error indices that the parameter number argument to
  --  one of the `bind` routines or the column number in one of the `column`
  --  routines is out of range.
  RANGE: number
  --  When attempting to open a file, the `lsqlite3.NOTADB` error indicates
  --  that the file being opened does not appear to be an SQLite database
  --  file.
  NOTADB: number
  --  The `lsqlite3.ROW` result code returned by sqlite3_step() indicates that
  --  another row of output is available.
  ROW: number
  --  The `lsqlite3.DONE` result code indicates that an operation has
  --  completed. The `lsqlite3.DONE` result code is most commonly seen as a
  --  return value from `step()` indicating that the SQL statement has run to
  --  completion, but `lsqlite3.DONE` can also be returned by other multi-step
  --  interfaces.
  DONE: number
  CREATE_INDEX: number
  CREATE_TABLE: number
  CREATE_TEMP_INDEX: number
  CREATE_TEMP_TABLE: number
  CREATE_TEMP_TRIGGER: number
  CREATE_TEMP_VIEW: number
  CREATE_TRIGGER: number
  CREATE_VIEW: number
  DELETE: number
  DROP_INDEX: number
  DROP_TABLE: number
  DROP_TEMP_INDEX: number
  DROP_TEMP_TABLE: number
  DROP_TEMP_TRIGGER: number
  DROP_TEMP_VIEW: number
  DROP_TRIGGER: number
  DROP_VIEW: number
  INSERT: number
  PRAGMA: number
  READ: number
  SELECT: number
  TRANSACTION: number
  UPDATE: number
  ATTACH: number
  DETACH: number
  ALTER_TABLE: number
  REINDEX: number
  ANALYZE: number
  CREATE_VTABLE: number
  DROP_VTABLE: number
  FUNCTION: number
  SAVEPOINT: number
  --  The database is created if it does not already exist.
  OPEN_CREATE: number
  --  The database is opened with shared cache disabled, overriding the
  --  default shared cache setting provided by sqlite3_enable_shared_cache().
  OPEN_PRIVATECACHE: number
  --  The new database connection will use the "serialized" threading mode.
  --  This means the multiple threads can safely attempt to use the same
  --  database connection at the same time. (Mutexes will block any actual
  --  concurrency, but in this mode there is no harm in trying.)
  OPEN_FULLMUTEX: number
  --  The new database connection will use the "multi-thread" threading mode.
  --  This means that separate threads are allowed to use SQLite at the same
  --  time, as long as each thread is using a different database connection.
  OPEN_NOMUTEX: number
  --  The database will be opened as an in-memory database. The database is
  --  named by the "filename" argument for the purposes of cache-sharing, if
  --  shared cache mode is enabled, but the "filename" is otherwise ignored.
  OPEN_MEMORY: number
  --  The filename can be interpreted as a URI if this flag is set. See
  --  https://www.sqlite.org/c3ref/open.html
  OPEN_URI: number
  --  The database is opened for reading and writing if possible, or reading
  --  only if the file is write protected by the operating system. In either
  --  case the database must already exist, otherwise an error is returned.
  OPEN_READWRITE: number
  --  The database is opened in read-only mode. If the database does not
  --  already exist, an error is returned.
  OPEN_READONLY: number
  --  The database is opened shared cache enabled, overriding the default
  --  shared cache setting provided by sqlite3_enable_shared_cache(). The use
  --  of shared cache mode is discouraged and hence shared cache capabilities
  --  may be omitted from many builds of SQLite. In such cases, this option is
  --  a no-op.
  OPEN_SHAREDCACHE: number
  TEXT: number
  BLOB: number
  NULL: number
  FLOAT: number
  INTEGER: number
  CONFIG_SINGLETHREAD: number
  CONFIG_MULTITHREAD: number
  CONFIG_SERIALIZED: number
  CONFIG_LOG: number
  --  for any database readers or writers to finish. See `db:wal_checkpoint`.
  CHECKPOINT_PASSIVE: number
  --  reading from the most recent database snapshot, then checkpoints all
  --  frames. See `db:wal_checkpoint`.
  CHECKPOINT_FULL: number
  --  blocks until all readers are reading from the database file only.
  --  See `db:wal_checkpoint`.
  CHECKPOINT_RESTART: number
  --  truncates the log file before returning. See `db:wal_checkpoint`.
  CHECKPOINT_TRUNCATE: number
  --  changeset while iterating it.
  CHANGESETSTART_INVERT: number
  --  SAVEPOINT that is otherwise used to rollback partially applied changes.
  CHANGESETAPPLY_NOSAVEPOINT: number
  --  before applying it.
  CHANGESETAPPLY_INVERT: number
  --  "before" values. See `db:apply_changeset`.
  CHANGESET_DATA: number
  --  database. See `db:apply_changeset`.
  CHANGESET_NOTFOUND: number
  --  See `db:apply_changeset`.
  CHANGESET_CONFLICT: number
  --  constraint. See `db:apply_changeset`.
  CHANGESET_CONSTRAINT: number
  --  after all changes were applied. See `db:apply_changeset`.
  CHANGESET_FOREIGN_KEY: number
  --  change. See `db:apply_changeset`.
  CHANGESET_OMIT: number
  --  row with the change. See `db:apply_changeset`.
  CHANGESET_REPLACE: number
  --  changeset. See `db:apply_changeset`.
  CHANGESET_ABORT: number
end
```

## Functions

### open

```teal
function open(filename: string, flags?: number): Database | nil, number
```

 Opens (or creates if it does not exist) an SQLite database with name filename
 and returns its handle as userdata (the returned object should be used for all
 further method calls in connection with this specific database, see Database
 methods). Example:
     myDB = lsqlite3.open('MyDatabase.sqlite3')  -- open
     -- do some database calls...
     myDB:close()  -- close
 In case of an error, the function returns `nil`, an error code and an error message.
 Since `0.9.4`, there is a second optional `flags` argument to `lsqlite3.open`.
 See https://www.sqlite.org/c3ref/open.html for an explanation of these flags and options.
     local db = lsqlite3.open('foo.db', lsqlite3.OPEN_READWRITE + lsqlite3.OPEN_CREATE + lsqlite3.OPEN_SHAREDCACHE)

**Parameters:**

- `filename` (string)
- `flags` (number)

**Returns:**

- Database | nil
- number

### open_memory

```teal
function open_memory(): Database | nil, number
```

 Opens an SQLite database in memory and returns its handle as userdata. In case
 of an error, the function returns `nil`, an error code and an error message.
 (In-memory databases are volatile as they are never stored on disk.)

**Returns:**

- Database | nil
- number

### lversion

```teal
function lversion(): string
```

**Returns:**

- string

### version

```teal
function version(): string
```

**Returns:**

- string

### config

```teal
function config(option: number, func?: function, udata?: any): number | nil, function | nil, any, number
```

 Sets global SQLite3 library configuration options.
 `option` may be one of:
 - `lsqlite3.CONFIG_SINGLETHREAD`, `lsqlite3.CONFIG_MULTITHREAD`, or
   `lsqlite3.CONFIG_SERIALIZED`: selects the global threading mode.
   Returns `lsqlite3.OK` on success, or `nil` plus a numerical error
   code on failure.
 - `lsqlite3.CONFIG_LOG`: installs a Lua callback that is invoked as
   `func(udata, errcode, message)` for every SQLite3 log event, or
   removes the current callback when `func` is `nil`. Returns
   `lsqlite3.OK` followed by the previously installed callback and its
   user data.

**Parameters:**

- `option` (number)
- `func` (function)
- `udata` (any)

**Returns:**

- number | nil
- function | nil
- any
- number
