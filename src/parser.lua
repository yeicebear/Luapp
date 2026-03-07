-- lpp parser.
-- recursive descent for statements, pratt climbing for expressions.
-- supports: funcs, externs, linkto (c libs + lpp files), structs at top level
-- statements: local, assign, if/else-if/else, while, break, return, case
-- expressions: int/float/str literals, vars, calls, array index, field access, binops

local function lpp_parse(lpp_toklist)
    local lpp_cur = 1

    -- struct definitions collected at top level: name -> {fields={name,type,...}, size}
    local lpp_structs = {}

    local function lpp_curtok()   return lpp_toklist[lpp_cur] end
    local function lpp_peektok(n) return lpp_toklist[lpp_cur + (n or 1)] end

    local function lpp_curtag(tag)
        return lpp_curtok() and lpp_curtok().tag == tag
    end

    local function lpp_advance(expected)
        local t = lpp_curtok()
        if not t then
            error("lpp: unexpected end of file" .. (expected and (", wanted "..expected) or ""))
        end
        if expected and t.tag ~= expected then
            error("lpp: syntax error at token "..lpp_cur..
                  " — got "..t.tag..(t.val and ("("..tostring(t.val)..")") or "")..
                  ", expected "..expected)
        end
        lpp_cur = lpp_cur+1
        return t
    end

    -- parse a type annotation, returns type string
    -- handles: int, float, str, bool, StructName, int[N], float[N], str[N]
    local function lpp_eat_type()
        local t = lpp_curtok()
        local base
        if t and (t.tag == "INT" or t.tag == "FLOAT" or t.tag == "STR" or
                  t.tag == "BOOL" or t.tag == "IDENT") then
            lpp_cur = lpp_cur+1
            base = t.val or t.tag:lower()
        else
            error("lpp: expected type at token "..lpp_cur.." got "..(t and t.tag or "nil"))
        end
        -- check for array: Type[N]
        if lpp_curtag("LBRACK") then
            lpp_advance("LBRACK")
            local sz = lpp_advance("NUMBER").val
            lpp_advance("RBRACK")
            return base.."["..sz.."]"
        end
        return base
    end

    local lpp_climb_expr, lpp_parse_block, lpp_parse_stmt

    local lpp_bp = {
        OR=1, AND=2,
        EQ=3, NEQ=3, LT=3, GT=3, LE=3, GE=3,
        PLUS=4, MINUS=4,
        STAR=5, SLASH=5, PCENT=5,
    }

    local function lpp_parse_atom()
        if lpp_curtag("MINUS") then
            lpp_advance("MINUS")
            local sub = lpp_parse_atom()
            if sub.kind == "lit_int"   then return {kind="lit_int",   ival=-sub.ival} end
            if sub.kind == "lit_float" then return {kind="lit_float", fval=-sub.fval} end
            return {kind="uneg", x=sub}
        end

        if lpp_curtag("BANG") then
            lpp_advance("BANG")
            return {kind="unot", x=lpp_parse_atom()}
        end

        local t = lpp_advance()

        if t.tag == "NUMBER" then return {kind="lit_int",   ival=t.val} end
        if t.tag == "FLOAT"  then return {kind="lit_float", fval=t.val} end
        if t.tag == "TRUE"   then return {kind="lit_int",   ival=1} end
        if t.tag == "FALSE"  then return {kind="lit_int",   ival=0} end
        if t.tag == "STRING" then return {kind="lit_str",   sval=t.val} end

        if t.tag == "LPAREN" then
            local inner = lpp_climb_expr()
            lpp_advance("RPAREN")
            return inner
        end

        if t.tag == "IDENT" then
            -- function call
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

            -- array index: name[expr]
            if lpp_curtag("LBRACK") then
                lpp_advance("LBRACK")
                local idx = lpp_climb_expr()
                lpp_advance("RBRACK")
                node = {kind="arr_get", vname=t.val, idx=idx}
            -- field access: name.field
            elseif lpp_curtag("DOT") then
                lpp_advance("DOT")
                local field = lpp_advance("IDENT").val
                node = {kind="field_get", vname=t.val, field=field}
            end

            return node
        end

        error("lpp: unexpected "..t.tag.." at token "..(lpp_cur-1))
    end

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

        -- local declaration: local name: Type = expr
        if t.tag == "LOCAL" then
            lpp_advance("LOCAL")
            local lpp_varname = lpp_advance("IDENT").val
            lpp_advance("COLON")
            local lpp_vartype = lpp_eat_type()
            -- arrays and structs don't need = initializer
            local lpp_rhs = nil
            if lpp_curtag("ASSIGN") then
                lpp_advance("ASSIGN")
                lpp_rhs = lpp_climb_expr()
            end
            return {kind="decl", vname=lpp_varname, vtype=lpp_vartype, rhs=lpp_rhs}

        elseif t.tag == "IDENT" then
            local name = t.val
            local next = lpp_peektok()

            -- plain assign: name = expr
            if next and next.tag == "ASSIGN" then
                lpp_advance("IDENT")
                lpp_advance("ASSIGN")
                return {kind="assign", vname=name, rhs=lpp_climb_expr()}
            end

            -- array assign: name[idx] = expr
            if next and next.tag == "LBRACK" then
                lpp_advance("IDENT")
                lpp_advance("LBRACK")
                local idx = lpp_climb_expr()
                lpp_advance("RBRACK")
                lpp_advance("ASSIGN")
                return {kind="arr_set", vname=name, idx=idx, rhs=lpp_climb_expr()}
            end

            -- field assign: name.field = expr
            if next and next.tag == "DOT" then
                lpp_advance("IDENT")
                lpp_advance("DOT")
                local field = lpp_advance("IDENT").val
                lpp_advance("ASSIGN")
                return {kind="field_set", vname=name, field=field, rhs=lpp_climb_expr()}
            end

            return {kind="xstmt", expr=lpp_climb_expr()}

        elseif t.tag == "IF" then
            lpp_advance("IF")
            local lpp_cond = lpp_climb_expr()
            local lpp_yes  = lpp_parse_block()
            local lpp_no
            if lpp_curtag("ELSE") then
                lpp_advance("ELSE")
                if lpp_curtag("IF") then
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

        elseif t.tag == "RETURN" then
            lpp_advance("RETURN")
            return {kind="ret", val=lpp_climb_expr()}

        elseif t.tag == "BREAK" then
            lpp_advance("BREAK")
            return {kind="brk"}

        -- case x {
        --   1 { ... }
        --   2 { ... }
        --   else { ... }
        -- }
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
                    local lpp_val = lpp_climb_expr()
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
        local lpp_rtype = "int"
        if lpp_curtag("COLON") then lpp_advance("COLON"); lpp_rtype = lpp_eat_type() end
        return {kind="fn", fname=lpp_fname, params=lpp_params, rtype=lpp_rtype,
                body=lpp_parse_block(), structs=lpp_structs}
    end

    local function lpp_parse_extern()
        lpp_advance("EXTERN")
        lpp_advance("FUNC")
        local lpp_fname = lpp_advance("IDENT").val
        lpp_advance("LPAREN")
        local lpp_ptypes = {}
        while lpp_curtok() and not lpp_curtag("RPAREN") do
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
        local islpp = lpp_libname:match("%.lpp$") and true or false
        return {kind="linkto", libname=lpp_libname, islpp=islpp}
    end

    -- struct Foo { x: int, y: float }
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
            -- field size: float=8, int/bool=4, str=8
            local fsize = (ftype == "float" or ftype == "str") and 8 or 4
            fields[#fields+1] = {name=fname, ftype=ftype, offset=offset, size=fsize}
            offset = offset + fsize
            if lpp_curtag("COMMA") then lpp_advance("COMMA") end
        end
        lpp_advance("RBRACE")
        lpp_structs[sname] = {fields=fields, size=offset}
        return {kind="structdef", sname=sname}
    end

    local lpp_prog = {kind="prog", funcs={}, externs={}, links={}, structs=lpp_structs}
    while lpp_cur <= #lpp_toklist do
        local t = lpp_curtok()
        if t.tag == "EXTERN"  then lpp_prog.externs[#lpp_prog.externs+1] = lpp_parse_extern()
        elseif t.tag == "LINKTO" then lpp_prog.links[#lpp_prog.links+1]   = lpp_parse_linkto()
        elseif t.tag == "FUNC"   then lpp_prog.funcs[#lpp_prog.funcs+1]   = lpp_parse_funcdef()
        elseif t.tag == "STRUCT" then lpp_parse_struct() -- registered into lpp_structs
        else
            error("lpp: expected func, extern, linkto, or struct at top level, got "..t.tag)
        end
    end
    return lpp_prog
end

return lpp_parse
