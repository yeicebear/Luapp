-- lpp parser.
-- recursive descent for statements, pratt climbing for expressions.
-- i went back and forth on whether to make lpp_climb_expr iterative or
-- recursive and landed on recursive because the call stack depth
-- for any sane lpp program is not going to be a problem.

local function lpp_parse(lpp_toklist)
    local lpp_cur = 1

    local function lpp_curtok()  return lpp_toklist[lpp_cur] end
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

    -- type annotations: int, bool, str, or any ident
    local function lpp_eat_typeannot()
        local t = lpp_curtok()
        if t and (t.tag == "INT" or t.tag == "BOOL" or t.tag == "IDENT") then
            lpp_cur = lpp_cur+1
            return t.val or t.tag:lower()
        end
        -- also allow "str" as a keyword-ish type
        if t and t.tag == "IDENT" and t.val == "str" then
            lpp_cur = lpp_cur+1
            return "str"
        end
        error("lpp: expected type annotation at token "..lpp_cur)
    end

    local lpp_climb_expr, lpp_parse_block, lpp_parse_stmt

    -- binding powers for infix operators
    local lpp_bp = {
        OR=1, AND=2,
        EQ=3, NEQ=3, LT=3, GT=3, LE=3, GE=3,
        PLUS=4, MINUS=4,
        STAR=5, SLASH=5, PCENT=5,
    }

    local function lpp_parse_atom()
        -- unary minus
        if lpp_curtag("MINUS") then
            lpp_advance("MINUS")
            local sub = lpp_parse_atom()
            if sub.kind == "lit_int" then
                return {kind="lit_int", ival=-sub.ival}
            end
            return {kind="uneg", x=sub}
        end

        if lpp_curtag("BANG") then
            lpp_advance("BANG")
            return {kind="unot", x=lpp_parse_atom()}
        end

        local t = lpp_advance()

        if t.tag == "NUMBER" then return {kind="lit_int", ival=t.val} end
        if t.tag == "TRUE"   then return {kind="lit_int", ival=1} end
        if t.tag == "FALSE"  then return {kind="lit_int", ival=0} end
        if t.tag == "STRING" then return {kind="lit_str", sval=t.val} end

        if t.tag == "LPAREN" then
            local inner = lpp_climb_expr()
            lpp_advance("RPAREN")
            return inner
        end

        if t.tag == "IDENT" then
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
            return {kind="var", vname=t.val}
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

        if t.tag == "LOCAL" then
            lpp_advance("LOCAL")
            local lpp_varname = lpp_advance("IDENT").val
            lpp_advance("COLON")
            local lpp_vartype = lpp_eat_typeannot()
            lpp_advance("ASSIGN")
            return {kind="decl", vname=lpp_varname, vtype=lpp_vartype, rhs=lpp_climb_expr()}

        elseif t.tag == "IDENT" then
            if lpp_peektok() and lpp_peektok().tag == "ASSIGN" then
                local lpp_varname = lpp_advance("IDENT").val
                lpp_advance("ASSIGN")
                return {kind="assign", vname=lpp_varname, rhs=lpp_climb_expr()}
            end
            return {kind="xstmt", expr=lpp_climb_expr()}

        elseif t.tag == "IF" then
            lpp_advance("IF")
            local lpp_cond = lpp_climb_expr()
            local lpp_yes  = lpp_parse_block()
            local lpp_no
            if lpp_curtag("ELSE") then lpp_advance("ELSE"); lpp_no = lpp_parse_block() end
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
        end

        -- fallthrough: bare expression statement
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
            lpp_params[#lpp_params+1] = {pname=lpp_pname, ptype=lpp_eat_typeannot()}
            if lpp_curtag("COMMA") then lpp_advance("COMMA") end
        end
        lpp_advance("RPAREN")
        local lpp_rtype = "int"
        if lpp_curtag("COLON") then lpp_advance("COLON"); lpp_rtype = lpp_eat_typeannot() end
        return {kind="fn", fname=lpp_fname, params=lpp_params, rtype=lpp_rtype, body=lpp_parse_block()}
    end

    -- extern func_name(type, type, ...): rettype
    local function lpp_parse_extern()
        lpp_advance("EXTERN")
        lpp_advance("FUNC")
        local lpp_fname = lpp_advance("IDENT").val
        lpp_advance("LPAREN")
        local lpp_ptypes = {}
        while lpp_curtok() and not lpp_curtag("RPAREN") do
            -- param can be "name: type" or just "type"
            local t = lpp_curtok()
            local lpp_ptype
            if t.tag == "IDENT" and lpp_peektok() and lpp_peektok().tag == "COLON" then
                lpp_advance("IDENT")  -- name
                lpp_advance("COLON")
                lpp_ptype = lpp_eat_typeannot()
            else
                lpp_ptype = lpp_eat_typeannot()
            end
            lpp_ptypes[#lpp_ptypes+1] = lpp_ptype
            if lpp_curtag("COMMA") then lpp_advance("COMMA") end
        end
        lpp_advance("RPAREN")
        local lpp_rtype = "int"
        if lpp_curtag("COLON") then lpp_advance("COLON"); lpp_rtype = lpp_eat_typeannot() end
        return {kind="extern_fn", fname=lpp_fname, ptypes=lpp_ptypes, rtype=lpp_rtype}
    end

    -- linkto "libname"
    local function lpp_parse_linkto()
        lpp_advance("LINKTO")
        local lpp_libname = lpp_advance("STRING").val
        return {kind="linkto", libname=lpp_libname}
    end

    local lpp_prog = {kind="prog", funcs={}, externs={}, links={}}
    while lpp_cur <= #lpp_toklist do
        local t = lpp_curtok()
        if t.tag == "EXTERN" then
            local ex = lpp_parse_extern()
            lpp_prog.externs[#lpp_prog.externs+1] = ex
        elseif t.tag == "LINKTO" then
            local lk = lpp_parse_linkto()
            lpp_prog.links[#lpp_prog.links+1] = lk
        elseif t.tag == "FUNC" then
            lpp_prog.funcs[#lpp_prog.funcs+1] = lpp_parse_funcdef()
        else
            error("lpp: expected func, extern, or linkto at top level, got "..t.tag)
        end
    end
    return lpp_prog
end

return lpp_parse
