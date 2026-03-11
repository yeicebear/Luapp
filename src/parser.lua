-- lpp parser
-- takes the token list from the lexer and builds an AST.
-- recursive descent for statements, pratt climbing for expressions.
-- i looked up pratt parsing once and now i won't shut up about it.
-- structs are collected into a shared table as we go so functions can see them.

local function lpp_parse(lpp_toklist)
    local lpp_cur = 1
    local lpp_structs = {}  -- struct definitions, filled in as we see them at top level

    local function lpp_curtok()   return lpp_toklist[lpp_cur] end
    local function lpp_peektok(n) return lpp_toklist[lpp_cur + (n or 1)] end
    local function lpp_curtag(tag) return lpp_curtok() and lpp_curtok().tag == tag end

    local function lpp_advance(expected)
        local t = lpp_curtok()
        if not t then
            error("lpp: unexpected end of file"..(expected and (", wanted "..expected) or ""))
        end
        if expected and t.tag ~= expected then
            -- this error message has saved me from losing my mind many times
            error("lpp: syntax error at token "..lpp_cur..
                  " — got "..t.tag..(t.val and ("("..tostring(t.val)..")") or "")..
                  ", expected "..expected)
        end
        lpp_cur = lpp_cur+1
        return t
    end

    -- parse a type annotation after a colon.
    -- handles plain types, fixed arrays Type[N], and dynamic arrays Type[]
    -- char and long are their own types now, lucky them
    local function lpp_eat_type()
        local t = lpp_curtok()
        local base
        if t and (t.tag=="INT" or t.tag=="FLOAT" or t.tag=="STR" or t.tag=="BOOL"
               or t.tag=="CHAR" or t.tag=="LONG" or t.tag=="IDENT") then
            lpp_cur = lpp_cur+1
            base = t.val or t.tag:lower()
        else
            error("lpp: expected type at token "..lpp_cur.." got "..(t and t.tag or "nil"))
        end
        -- check for array suffix
        if lpp_curtag("LBRACK") then
            lpp_advance("LBRACK")
            if lpp_curtag("RBRACK") then
                -- dynamic array: Type[] — no size, heap allocated
                lpp_advance("RBRACK")
                return base.."[]"
            else
                -- fixed array: Type[N] — stack allocated, size known at compile time
                local sz = lpp_advance("NUMBER").val
                lpp_advance("RBRACK")
                return base.."["..sz.."]"
            end
        end
        return base
    end

    local lpp_climb_expr, lpp_parse_block, lpp_parse_stmt

    -- binding powers for infix operators.
    -- higher number = tighter binding = done first.
    -- if you change these and things break, that's on you.
    local lpp_bp = { -- this is a comment
        OR=1, AND=2, -- tis too
        EQ=3, NEQ=3, LT=3, GT=3, LE=3, GE=3,
        PLUS=4, MINUS=4, -- to bee or to be
        STAR=5, SLASH=5, PCENT=5, --bab (spell it out )
        PIPE=1, CARET=1, AMP=2, SHR=3, SHL=3,  -- bitwise
    }

    local function lpp_parse_atom()
        -- unary minus: flip the sign, or for literals just negate the value directly
        if lpp_curtag("MINUS") then
            lpp_advance("MINUS")
            local sub = lpp_parse_atom()
            if sub.kind == "lit_int"   then return {kind="lit_int",   ival=-sub.ival} end
            if sub.kind == "lit_float" then return {kind="lit_float", fval=-sub.fval} end
            return {kind="uneg", x=sub}
        end

        -- logical not
        if lpp_curtag("BANG") then
            lpp_advance("BANG")
            return {kind="unot", x=lpp_parse_atom()}
        end

        local t = lpp_advance()

        if t.tag == "NUMBER" then return {kind="lit_int",   ival=t.val} end
        if t.tag == "FLOAT"  then return {kind="lit_float", fval=t.val} end
        if t.tag == "CHAR"   then return {kind="lit_int",   ival=t.val} end  -- char is just an int, don't @ me
        if t.tag == "TRUE"   then return {kind="lit_int",   ival=1} end
        if t.tag == "FALSE"  then return {kind="lit_int",   ival=0} end
        if t.tag == "STRING" then return {kind="lit_str",   sval=t.val} end

        -- parenthesised expression
        if t.tag == "LPAREN" then
            local inner = lpp_climb_expr()
            lpp_advance("RPAREN")
            return inner
        end

        if t.tag == "IDENT" then
            -- if the next token is '(' it's a function call
            if lpp_curtag("LPAREN") then
                lpp_advance("LPAREN")
                local lpp_arglist = {}
                if not lpp_curtag("RPAREN") then
                    lpp_arglist[#lpp_arglist+1] = lpp_climb_expr()
                    while lpp_curtag("COMMA") do
                        lpp_advance("COMMA")
                        lpp_arglist[#lpp_arglist+1] = lpp_climb_expr()
                    end
                end
                lpp_advance("RPAREN")
                return {kind="call", fname=t.val, args=lpp_arglist}
            end

            local node = {kind="var", vname=t.val}
-- hi!
            -- array index: name[expr]
            if lpp_curtag("LBRACK") then
                lpp_advance("LBRACK")
                local idx = lpp_climb_expr()
                lpp_advance("RBRACK")
                node = {kind="arr_get", vname=t.val, idx=idx}
            -- dot: either field access name.field or method call name.method(args)
            elseif lpp_curtag("DOT") then
                lpp_advance("DOT")
                local field = lpp_advance("IDENT").val
                if lpp_curtag("LPAREN") then
                    -- method call: obj.method(args) -> StructType_method(&obj, args)
                    -- we don't know the struct type here, codegen resolves it via vartypes
                    lpp_advance("LPAREN")
                    local args = {}
                    if not lpp_curtag("RPAREN") then
                        args[#args+1] = lpp_climb_expr()
                        while lpp_curtag("COMMA") do
                            lpp_advance("COMMA")
                            args[#args+1] = lpp_climb_expr()
                        end
                    end
                    lpp_advance("RPAREN")
                    -- receiver stored as a special first arg that codegen turns into &obj
                    node = {kind="method_call", receiver=t.val, method=field, args=args}
                else
                    node = {kind="field_get", vname=t.val, field=field}
                end
            end

            return node
        end

        error("lpp: unexpected "..t.tag.." at token "..(lpp_cur-1))
    end

    -- pratt expression climbing.
    -- min_bp is the minimum binding power we're willing to consume.
    -- starts at 0 which means "eat everything".
    lpp_climb_expr = function(lpp_min_bp)
        lpp_min_bp = lpp_min_bp or 0
        local lhs = lpp_parse_atom()
        while true do
            local op = lpp_curtok()
            if not op or not lpp_bp[op.tag] or lpp_bp[op.tag] < lpp_min_bp then break end
            lpp_advance()
            lhs = {kind="binop", op=op.tag, lhs=lhs, rhs=lpp_climb_expr(lpp_bp[op.tag]+1)}
        end
        return lhs
    end

    lpp_parse_block = function()
        lpp_advance("LBRACE")
        local lpp_stmtlist = {}
        while lpp_curtok() and not lpp_curtag("RBRACE") do
            local s = lpp_parse_stmt()
            if s then lpp_stmtlist[#lpp_stmtlist+1] = s end
        end
        lpp_advance("RBRACE")
        return {kind="block", stmts=lpp_stmtlist}
    end

    lpp_parse_stmt = function()
        local t = lpp_curtok()
        if not t then return nil end

        -- variable declaration: local name: Type [= expr]
        -- the initializer is optional for arrays and structs
        if t.tag == "LOCAL" then
            lpp_advance("LOCAL")
            local lpp_varname = lpp_advance("IDENT").val
            lpp_advance("COLON")
            local lpp_vartype = lpp_eat_type()
            local lpp_rhs = nil
            if lpp_curtag("ASSIGN") then
                lpp_advance("ASSIGN")
                lpp_rhs = lpp_climb_expr()
            end
            return {kind="decl", vname=lpp_varname, vtype=lpp_vartype, rhs=lpp_rhs}

        elseif t.tag == "IDENT" then
            local name = t.val
            local next = lpp_peektok()

            -- plain assignment: name = expr
            if next and next.tag == "ASSIGN" then
                lpp_advance("IDENT"); lpp_advance("ASSIGN")
                return {kind="assign", vname=name, rhs=lpp_climb_expr()}
            end

            -- compound assignment: name += expr  etc
            local compound_ops = {PLUSEQ="PLUS", MINUSEQ="MINUS", STAREQ="STAR", SLASHEQ="SLASH", PCENTEQ="PCENT"}
            if next and compound_ops[next.tag] then
                local binop = compound_ops[next.tag]
                lpp_advance("IDENT"); lpp_advance(next.tag)
                local rhs = lpp_climb_expr()
                -- desugar: name op= rhs  ->  name = name op rhs
                return {kind="assign", vname=name,
                    rhs={kind="binop", op=binop,
                        lhs={kind="var", vname=name},
                        rhs=rhs}}
            end

            -- array element assignment: name[idx] = expr
            if next and next.tag == "LBRACK" then
                lpp_advance("IDENT"); lpp_advance("LBRACK")
                local idx = lpp_climb_expr()
                lpp_advance("RBRACK"); lpp_advance("ASSIGN")
                return {kind="arr_set", vname=name, idx=idx, rhs=lpp_climb_expr()}
            end

            -- struct field assignment: name.field = expr
            if next and next.tag == "DOT" then
                lpp_advance("IDENT"); lpp_advance("DOT")
                local field = lpp_advance("IDENT").val
                -- is it a method call statement or a field assignment?
                if lpp_curtag("LPAREN") then
                    -- method call statement: obj.method(args)
                    lpp_advance("LPAREN")
                    local args = {}
                    if not lpp_curtag("RPAREN") then
                        args[#args+1] = lpp_climb_expr()
                        while lpp_curtag("COMMA") do
                            lpp_advance("COMMA")
                            args[#args+1] = lpp_climb_expr()
                        end
                    end
                    lpp_advance("RPAREN")
                    return {kind="xstmt", expr={kind="method_call", receiver=name, method=field, args=args}}
                end
                lpp_advance("ASSIGN")
                return {kind="field_set", vname=name, field=field, rhs=lpp_climb_expr()}
            end

            -- just a bare expression statement (usually a function call we don't use the return value of)
            return {kind="xstmt", expr=lpp_climb_expr()}

        elseif t.tag == "IF" then
            lpp_advance("IF")
            local lpp_cond = lpp_climb_expr()
            local lpp_yes  = lpp_parse_block()
            local lpp_no
            if lpp_curtag("ELSE") then
                lpp_advance("ELSE")
                if lpp_curtag("IF") then
                    -- else if: wrap the inner if as a single-statement block
                    -- not the prettiest trick but it works fine
                    local inner = lpp_parse_stmt()
                    lpp_no = {kind="block", stmts={inner}}
                else
                    lpp_no = lpp_parse_block()
                end
            end
            return {kind="ifx", cond=lpp_cond, yes=lpp_yes, no=lpp_no}

        elseif t.tag == "WHILE" then
            lpp_advance("WHILE")
            return {kind="loop", cond=lpp_climb_expr(), body=lpp_parse_block()}

        elseif t.tag == "FOR" then
            -- for i = start, limit [, step] { body }
            -- desugars to: local i = start; while i < limit { body; i = i + step }
            lpp_advance("FOR")
            local iname = lpp_advance("IDENT").val
            lpp_advance("ASSIGN")
            local start_expr = lpp_climb_expr()
            lpp_advance("COMMA")
            local limit_expr = lpp_climb_expr()
            local step_expr = {kind="lit_int", ival=1}
            if lpp_curtag("COMMA") then
                lpp_advance("COMMA")
                step_expr = lpp_climb_expr()
            end
            local body = lpp_parse_block()
            -- inject i = i + step at the end of the body (before any continue)
            local step_stmt = {kind="assign", vname=iname,
                rhs={kind="binop", op="PLUS",
                    lhs={kind="var", vname=iname}, rhs=step_expr}}
            table.insert(body.stmts, step_stmt)
            return {kind="forloop", iname=iname, start=start_expr,
                    limit=limit_expr, step=step_expr, body=body}

        elseif t.tag == "RETURN" then
            lpp_advance("RETURN")
            return {kind="ret", val=lpp_climb_expr()}

        elseif t.tag == "BREAK" then
            lpp_advance("BREAK")
            return {kind="brk"}

        elseif t.tag == "CONTINUE" then
            lpp_advance("CONTINUE")
            return {kind="cont"}

        -- case statement: case expr { val { ... } val { ... } else { ... } }
        -- compiles down to a chain of if/else comparisons. nothing fancy.
        elseif t.tag == "CASE" then
            lpp_advance("CASE")
            local lpp_subject = lpp_climb_expr()
            lpp_advance("LBRACE")
            local lpp_arms = {}
            local lpp_default = nil
            while lpp_curtok() and not lpp_curtag("RBRACE") do
                if lpp_curtag("ELSE") then
                    lpp_advance("ELSE")
                    lpp_default = lpp_parse_block()
                else
                    local lpp_val  = lpp_climb_expr()
                    local lpp_body = lpp_parse_block()
                    lpp_arms[#lpp_arms+1] = {val=lpp_val, body=lpp_body}
                end
            end
            lpp_advance("RBRACE")
            return {kind="casex", subject=lpp_subject, arms=lpp_arms, default=lpp_default}
        end

        return {kind="xstmt", expr=lpp_climb_expr()}
    end

    local function lpp_parse_funcdef()
        lpp_advance("FUNC")
        local lpp_fname = lpp_advance("IDENT").val
        lpp_advance("LPAREN")
        local lpp_params = {}
        while lpp_curtok() and not lpp_curtag("RPAREN") do
            local lpp_pname = lpp_advance("IDENT").val
            lpp_advance("COLON")
            lpp_params[#lpp_params+1] = {pname=lpp_pname, ptype=lpp_eat_type()}
            if lpp_curtag("COMMA") then lpp_advance("COMMA") end
        end
        lpp_advance("RPAREN")
        local lpp_rtype = "int"  -- default return type is int, like God intended
        if lpp_curtag("COLON") then lpp_advance("COLON"); lpp_rtype = lpp_eat_type() end
        -- pass the struct table into the function node so codegen can look up field offsets
        return {kind="fn", fname=lpp_fname, params=lpp_params, rtype=lpp_rtype,
                body=lpp_parse_block(), structs=lpp_structs}
    end

    -- extern declares a C function so lpp knows the name and types without having to trust us
    local function lpp_parse_extern()
        lpp_advance("EXTERN")
        lpp_advance("FUNC")
        local lpp_fname = lpp_advance("IDENT").val
        lpp_advance("LPAREN")
        local lpp_ptypes = {}
        while lpp_curtok() and not lpp_curtag("RPAREN") do
            -- allow optional param names before the colon — we throw them away anyway
            local t2 = lpp_curtok()
            if t2.tag == "IDENT" and lpp_peektok() and lpp_peektok().tag == "COLON" then
                lpp_advance("IDENT"); lpp_advance("COLON")
            end
            lpp_ptypes[#lpp_ptypes+1] = lpp_eat_type()
            if lpp_curtag("COMMA") then lpp_advance("COMMA") end
        end
        lpp_advance("RPAREN")
        local lpp_rtype = "int"
        if lpp_curtag("COLON") then lpp_advance("COLON"); lpp_rtype = lpp_eat_type() end
        return {kind="extern_fn", fname=lpp_fname, ptypes=lpp_ptypes, rtype=lpp_rtype}
    end

    local function lpp_parse_linkto()
        lpp_advance("LINKTO")
        local lpp_libname = lpp_advance("STRING").val
        -- if it ends in .lpp we'll merge it at the AST level before compiling
        -- otherwise it's a C library name and main.lua handles finding the file
        local islpp = lpp_libname:match("%.lpp$") and true or false
        return {kind="linkto", libname=lpp_libname, islpp=islpp}
    end

    -- struct definition at top level.
    -- fields get their byte offsets calculated here so codegen doesn't have to think.
    -- char is 1 byte, everything else is either 4 or 8.
    local function lpp_parse_struct()
        lpp_advance("STRUCT")
        local sname = lpp_advance("IDENT").val
        lpp_advance("LBRACE")
        local fields = {}
        local offset = 0
        while lpp_curtok() and not lpp_curtag("RBRACE") do
            local fname = lpp_advance("IDENT").val
            lpp_advance("COLON")
            local ftype = lpp_eat_type()
            local fsize
            if ftype == "float" or ftype == "str" or ftype == "long" then fsize = 8
            elseif ftype == "char" then fsize = 1
            else fsize = 4 end
            fields[#fields+1] = {name=fname, ftype=ftype, offset=offset, size=fsize}
            offset = offset + fsize
            if lpp_curtag("COMMA") then lpp_advance("COMMA") end
        end
        lpp_advance("RBRACE")
        lpp_structs[sname] = {fields=fields, size=offset}
        return {kind="structdef", sname=sname}
    end

    -- global variable declaration at top level.
    -- global name: Type [= expr]
    -- scalars only — no fixed arrays, no structs (those need runtime init which globals don't have).
    -- initializers must be compile-time constants (int/float/str literals only).
    local function lpp_parse_global()
        lpp_advance("GLOBAL")
        local gname = lpp_advance("IDENT").val
        lpp_advance("COLON")
        local gtype = lpp_eat_type()
        local ginit = nil
        if lpp_curtag("ASSIGN") then
            lpp_advance("ASSIGN")
            ginit = lpp_climb_expr()  -- must be a literal, codegen will verify
        end
        return {kind="globaldef", gname=gname, gtype=gtype, init=ginit}
    end

    -- impl block: attach methods to a struct.
    -- impl Vec2 { func length(self: Vec2): float { ... } }
    --
    -- desugaring rules:
    --   - first param named "self" with the struct type becomes a hidden long (pointer to the struct)
    --   - the method is emitted as a regular function named "StructName_methodname"
    --   - calling obj.method(args) in expressions desugars to StructName_method(&obj, args)
    local function lpp_parse_impl()
        lpp_advance("IMPL")
        local sname = lpp_advance("IDENT").val
        lpp_advance("LBRACE")
        local methods = {}
        while lpp_curtok() and not lpp_curtag("RBRACE") do
            lpp_advance("FUNC")
            local mname = lpp_advance("IDENT").val
            lpp_advance("LPAREN")
            local params = {}
            local has_self = false
            while lpp_curtok() and not lpp_curtag("RPAREN") do
                local pname = lpp_advance("IDENT").val
                lpp_advance("COLON")
                local ptype = lpp_eat_type()
                -- "self" with the struct type becomes a long pointer under the hood
                if pname == "self" and ptype == sname then
                    has_self = true
                    params[#params+1] = {pname="self", ptype="long", is_self=true, self_struct=sname}
                else
                    params[#params+1] = {pname=pname, ptype=ptype}
                end
                if lpp_curtag("COMMA") then lpp_advance("COMMA") end
            end
            lpp_advance("RPAREN")
            local rtype = "int"
            if lpp_curtag("COLON") then lpp_advance("COLON"); rtype = lpp_eat_type() end
            local body = lpp_parse_block()
            -- emit as a top-level function named StructName_methodname
            methods[#methods+1] = {kind="fn", fname=sname.."_"..mname,
                params=params, rtype=rtype, body=body, structs=lpp_structs,
                impl_struct=sname, has_self=has_self}
        end
        lpp_advance("RBRACE")
        return methods, sname
    end

    -- main parse loop — only top-level things allowed here
    -- no statements at the top level, lpp is not a script
    local lpp_prog = {kind="prog", funcs={}, externs={}, links={}, structs=lpp_structs, globals={}, toplevel_stmts={}}
    while lpp_cur <= #lpp_toklist do
        local t = lpp_curtok()
        if     t.tag == "EXTERN"  then lpp_prog.externs[#lpp_prog.externs+1] = lpp_parse_extern()
        elseif t.tag == "LINKTO"  then lpp_prog.links[#lpp_prog.links+1]     = lpp_parse_linkto()
        elseif t.tag == "FUNC"    then lpp_prog.funcs[#lpp_prog.funcs+1]     = lpp_parse_funcdef()
        elseif t.tag == "STRUCT"  then lpp_parse_struct()
        elseif t.tag == "GLOBAL"  then
            lpp_prog.globals[#lpp_prog.globals+1] = lpp_parse_global()
        elseif t.tag == "IMPL" then
            local methods = lpp_parse_impl()
            for i=1,#methods do lpp_prog.funcs[#lpp_prog.funcs+1] = methods[i] end
        else
            -- anything else is a top-level statement — parse it and collect it
            -- it'll get emitted into a synthetic __init function by codegen
            local s = lpp_parse_stmt()
            if s then lpp_prog.toplevel_stmts[#lpp_prog.toplevel_stmts+1] = s end
        end
    end
    return lpp_prog
end

return lpp_parse