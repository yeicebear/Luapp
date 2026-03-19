-- parser.lua  |  sector_8:ast_build
-- token list → AST.
-- recursive descent for statements.
-- pratt climbing for expressions (binding powers in bp_table).
-- structs accumulate into a shared table as we go so methods can see fields.

local function parse(tokens)
    local pos     = 1
    local structs = {}

    local function cur()       return tokens[pos]                          end
    local function peek(n)     return tokens[pos + (n or 1)]              end
    local function is(tag)     return cur() and cur().tag == tag           end
    local function cur_line()
        local t = tokens[pos] or tokens[pos-1]
        return t and t.line or "?"
    end

    local tok_display = {
        LBRACE="'{'",  RBRACE="'}'",  LPAREN="'('",  RPAREN="')'",
        LBRACK="'['",  RBRACK="']'",  COLON="':'",   COMMA="','",
        ASSIGN="'='",  DOT="'.'",     PLUS="'+'",    MINUS="'-'",
        STAR="'*'",    SLASH="'/'",   PCENT="'%'",
        EQ="'=='",     NEQ="'!='",    LT="'<'",      GT="'>'",
        LE="'<='",     GE="'>='",     AND="'&&'",    OR="'||'",
        AMP="'&'",     PIPE="'|'",    CARET="'^'",   BANG="'!'",
        TILDE="'~'",   SHL="'<<'",    SHR="'>>'",
        PLUSEQ="'+='", MINUSEQ="'-='",STAREQ="'*='", SLASHEQ="'/='", PCENTEQ="'%='",
        FUNC="'func'", LOCAL="'local'",IF="'if'",    ELSE="'else'",
        WHILE="'while'",FOR="'for'",  RETURN="'return'",BREAK="'break'",
        CONTINUE="'continue'",        STRUCT="'struct'", IMPL="'impl'",
        EXTERN="'extern'",LINKTO="'linkto'",GLOBAL="'global'",CASE="'case'",
        INT="'int'",   FLOAT="'float'",STR="'str'",  BOOL="'bool'",
        CHAR="'char'", LONG="'long'", TRUE="'true'", FALSE="'false'",
        IDENT="a name",NUMBER="a number",STRING="a string",EOF="end of file",
    }

    local function tok_str(t)
        if not t then return "end of file" end
        local d = tok_display[t.tag]
        if d then return d end
        if t.val then return "'"..tostring(t.val).."'" end
        return t.tag
    end

    local function advance(want)
        local t = cur()
        if not t then
            local ln = (tokens[#tokens] and tokens[#tokens].line) or "?"
            local hint = want and (", expected "..(tok_display[want] or want)) or ""
            error("lpp: line "..ln..": unexpected end of file"..hint)
        end
        if want and t.tag ~= want then
            error("lpp: line "..t.line..": expected "..(tok_display[want] or want)..", got "..tok_str(t))
        end
        pos = pos+1
        return t
    end

    local function eat_type()
        local t = cur()
        local base
        if t and (t.tag=="INT" or t.tag=="FLOAT" or t.tag=="STR" or t.tag=="BOOL"
               or t.tag=="CHAR" or t.tag=="LONG" or t.tag=="IDENT") then
            pos = pos+1
            base = t.val or t.tag:lower()
        else
            error("lpp: line "..(t and t.line or "?")..": expected type name, got "..tok_str(t))
        end
        if is("LBRACK") then
            advance("LBRACK")
            if is("RBRACK") then advance("RBRACK"); return base.."[]" end
            local sz = advance("NUMBER").val
            advance("RBRACK")
            return base.."["..sz.."]"
        end
        return base
    end

    local climb_expr, parse_block, parse_stmt

    local bp_table = {
        OR=1, AND=2,
        EQ=3, NEQ=3, LT=3, GT=3, LE=3, GE=3,
        PLUS=4, MINUS=4,
        STAR=5, SLASH=5, PCENT=5,
        PIPE=1, CARET=1, AMP=2, SHR=3, SHL=3,
    }

    local function parse_atom()
        if is("MINUS") then
            advance("MINUS")
            local sub = parse_atom()
            if sub.kind == "lit_int"   then return {kind="lit_int",   ival=-sub.ival} end
            if sub.kind == "lit_float" then return {kind="lit_float", fval=-sub.fval} end
            return {kind="uneg", x=sub}
        end
        if is("BANG") then
            advance("BANG")
            return {kind="unot", x=parse_atom()}
        end

        local t = advance()

        if t.tag == "NUMBER" then return {kind="lit_int",   ival=t.val,        line=t.line} end
        if t.tag == "FLOAT"  then return {kind="lit_float", fval=t.val,        line=t.line} end
        if t.tag == "CHAR"   then return {kind="lit_int",   ival=t.val,        line=t.line} end
        if t.tag == "TRUE"   then return {kind="lit_int",   ival=1,            line=t.line} end
        if t.tag == "FALSE"  then return {kind="lit_int",   ival=0,            line=t.line} end
        if t.tag == "STRING" then return {kind="lit_str",   sval=t.val,        line=t.line} end

        if t.tag == "LPAREN" then
            local inner = climb_expr()
            advance("RPAREN")
            return inner
        end

        if t.tag == "IDENT" then
            if is("LPAREN") then
                advance("LPAREN")
                local args = {}
                if not is("RPAREN") then
                    args[#args+1] = climb_expr()
                    while is("COMMA") do advance("COMMA"); args[#args+1] = climb_expr() end
                end
                advance("RPAREN")
                return {kind="call", fname=t.val, args=args, line=t.line}
            end

            local node = {kind="var", vname=t.val, line=t.line}

            if is("LBRACK") then
                advance("LBRACK")
                local idx = climb_expr()
                advance("RBRACK")
                node = {kind="arr_get", vname=t.val, idx=idx, line=t.line}
            elseif is("DOT") then
                advance("DOT")
                local field = advance("IDENT").val
                if is("LPAREN") then
                    advance("LPAREN")
                    local args = {}
                    if not is("RPAREN") then
                        args[#args+1] = climb_expr()
                        while is("COMMA") do advance("COMMA"); args[#args+1] = climb_expr() end
                    end
                    advance("RPAREN")
                    node = {kind="method_call", receiver=t.val, method=field, args=args, line=t.line}
                else
                    node = {kind="field_get", vname=t.val, field=field, line=t.line}
                end
            end

            return node
        end

        error("lpp: line "..t.line..": unexpected "..tok_str(t))
    end

    climb_expr = function(min_bp)
        min_bp = min_bp or 0
        local lhs = parse_atom()
        while true do
            local op = cur()
            if not op or not bp_table[op.tag] or bp_table[op.tag] < min_bp then break end
            advance()
            lhs = {kind="binop", op=op.tag, lhs=lhs, rhs=climb_expr(bp_table[op.tag]+1), line=op.line}
        end
        return lhs
    end

    parse_block = function()
        advance("LBRACE")
        local stmts = {}
        while cur() and not is("RBRACE") do
            local s = parse_stmt()
            if s then stmts[#stmts+1] = s end
        end
        advance("RBRACE")
        return {kind="block", stmts=stmts}
    end

    parse_stmt = function()
        local t = cur()
        if not t then return nil end

        if t.tag == "LOCAL" then
            local ln = t.line
            advance("LOCAL")
            local vname = advance("IDENT").val
            advance("COLON")
            local vtype = eat_type()
            local rhs   = nil
            if is("ASSIGN") then advance("ASSIGN"); rhs = climb_expr() end
            return {kind="decl", vname=vname, vtype=vtype, rhs=rhs, line=ln}

        elseif t.tag == "IDENT" then
            local name = t.val
            local ln   = t.line
            local next = peek()

            if next and next.tag == "ASSIGN" then
                advance("IDENT"); advance("ASSIGN")
                return {kind="assign", vname=name, rhs=climb_expr(), line=ln}
            end

            local compound = {PLUSEQ="PLUS", MINUSEQ="MINUS", STAREQ="STAR", SLASHEQ="SLASH", PCENTEQ="PCENT"}
            if next and compound[next.tag] then
                local binop = compound[next.tag]
                advance("IDENT"); advance(next.tag)
                local rhs = climb_expr()
                return {kind="assign", vname=name, line=ln,
                    rhs={kind="binop", op=binop, lhs={kind="var", vname=name}, rhs=rhs}}
            end

            if next and next.tag == "LBRACK" then
                advance("IDENT"); advance("LBRACK")
                local idx = climb_expr()
                advance("RBRACK"); advance("ASSIGN")
                return {kind="arr_set", vname=name, idx=idx, rhs=climb_expr(), line=ln}
            end

            if next and next.tag == "DOT" then
                advance("IDENT"); advance("DOT")
                local field = advance("IDENT").val
                if is("LPAREN") then
                    advance("LPAREN")
                    local args = {}
                    if not is("RPAREN") then
                        args[#args+1] = climb_expr()
                        while is("COMMA") do advance("COMMA"); args[#args+1] = climb_expr() end
                    end
                    advance("RPAREN")
                    return {kind="xstmt", expr={kind="method_call", receiver=name, method=field, args=args}}
                end
                advance("ASSIGN")
                return {kind="field_set", vname=name, field=field, rhs=climb_expr()}
            end

            return {kind="xstmt", expr=climb_expr()}

        elseif t.tag == "IF" then
            advance("IF")
            local cond = climb_expr()
            local yes  = parse_block()
            local no
            if is("ELSE") then
                advance("ELSE")
                if is("IF") then
                    local inner = parse_stmt()
                    no = {kind="block", stmts={inner}}
                else
                    no = parse_block()
                end
            end
            return {kind="ifx", cond=cond, yes=yes, no=no}

        elseif t.tag == "WHILE" then
            advance("WHILE")
            return {kind="loop", cond=climb_expr(), body=parse_block()}

        elseif t.tag == "FOR" then
            advance("FOR")
            local iname = advance("IDENT").val
            advance("ASSIGN")
            local start = climb_expr()
            advance("COMMA")
            local limit = climb_expr()
            local step  = {kind="lit_int", ival=1}
            if is("COMMA") then advance("COMMA"); step = climb_expr() end
            local body  = parse_block()
            local step_stmt = {kind="assign", vname=iname,
                rhs={kind="binop", op="PLUS", lhs={kind="var", vname=iname}, rhs=step}}
            table.insert(body.stmts, step_stmt)
            return {kind="forloop", iname=iname, start=start, limit=limit, step=step, body=body}

        elseif t.tag == "RETURN"   then advance("RETURN");   return {kind="ret",  val=climb_expr()}
        elseif t.tag == "BREAK"    then advance("BREAK");    return {kind="brk"}
        elseif t.tag == "CONTINUE" then advance("CONTINUE"); return {kind="cont"}

        elseif t.tag == "CASE" then
            advance("CASE")
            local subject = climb_expr()
            advance("LBRACE")
            local arms    = {}
            local default = nil
            while cur() and not is("RBRACE") do
                if is("ELSE") then
                    advance("ELSE")
                    default = parse_block()
                else
                    local val  = climb_expr()
                    local body = parse_block()
                    arms[#arms+1] = {val=val, body=body}
                end
            end
            advance("RBRACE")
            return {kind="casex", subject=subject, arms=arms, default=default}
        end

        return {kind="xstmt", expr=climb_expr()}
    end

    -- sector_8:parse_toplevel
    local function parse_funcdef()
        advance("FUNC")
        local fname  = advance("IDENT").val
        advance("LPAREN")
        local params = {}
        while cur() and not is("RPAREN") do
            local pname = advance("IDENT").val
            advance("COLON")
            params[#params+1] = {pname=pname, ptype=eat_type()}
            if is("COMMA") then advance("COMMA") end
        end
        advance("RPAREN")
        local rtype = "int"
        if is("COLON") then advance("COLON"); rtype = eat_type() end
        return {kind="fn", fname=fname, params=params, rtype=rtype,
                body=parse_block(), structs=structs}
    end

    local function parse_extern()
        advance("EXTERN"); advance("FUNC")
        local fname  = advance("IDENT").val
        advance("LPAREN")
        local ptypes = {}
        while cur() and not is("RPAREN") do
            local t2 = cur()
            if t2.tag=="IDENT" and peek() and peek().tag=="COLON" then
                advance("IDENT"); advance("COLON")
            end
            ptypes[#ptypes+1] = eat_type()
            if is("COMMA") then advance("COMMA") end
        end
        advance("RPAREN")
        local rtype = "int"
        if is("COLON") then advance("COLON"); rtype = eat_type() end
        return {kind="extern_fn", fname=fname, ptypes=ptypes, rtype=rtype}
    end

    local function parse_linkto()
        advance("LINKTO")
        local libname = advance("STRING").val
        local islpp   = libname:match("%.lpp$") and true or false
        return {kind="linkto", libname=libname, islpp=islpp}
    end

    local function parse_struct()
        advance("STRUCT")
        local sname  = advance("IDENT").val
        advance("LBRACE")
        local fields = {}
        local offset = 0
        while cur() and not is("RBRACE") do
            local fname = advance("IDENT").val
            advance("COLON")
            local ftype = eat_type()
            local fsize = (ftype=="float" or ftype=="str" or ftype=="long") and 8
                       or  ftype=="char" and 1
                       or  4
            fields[#fields+1] = {name=fname, ftype=ftype, offset=offset, size=fsize}
            offset = offset + fsize
            if is("COMMA") then advance("COMMA") end
        end
        advance("RBRACE")
        structs[sname] = {fields=fields, size=offset}
        return {kind="structdef", sname=sname}
    end

    local function parse_global()
        advance("GLOBAL")
        local gname = advance("IDENT").val
        advance("COLON")
        local gtype = eat_type()
        local ginit = nil
        if is("ASSIGN") then advance("ASSIGN"); ginit = climb_expr() end
        return {kind="globaldef", gname=gname, gtype=gtype, init=ginit}
    end

    local function parse_impl()
        advance("IMPL")
        local sname   = advance("IDENT").val
        advance("LBRACE")
        local methods = {}
        while cur() and not is("RBRACE") do
            advance("FUNC")
            local mname  = advance("IDENT").val
            advance("LPAREN")
            local params = {}
            local has_self = false
            while cur() and not is("RPAREN") do
                local pname = advance("IDENT").val
                advance("COLON")
                local ptype = eat_type()
                if pname == "self" and ptype == sname then
                    has_self = true
                    params[#params+1] = {pname="self", ptype="long", is_self=true, self_struct=sname}
                else
                    params[#params+1] = {pname=pname, ptype=ptype}
                end
                if is("COMMA") then advance("COMMA") end
            end
            advance("RPAREN")
            local rtype = "int"
            if is("COLON") then advance("COLON"); rtype = eat_type() end
            local body  = parse_block()
            methods[#methods+1] = {
                kind="fn", fname=sname.."_"..mname,
                params=params, rtype=rtype, body=body,
                structs=structs, impl_struct=sname, has_self=has_self,
            }
        end
        advance("RBRACE")
        return methods, sname
    end

    local prog = {
        kind="prog", funcs={}, externs={}, links={},
        structs=structs, globals={}, toplevel_stmts={},
    }

    while pos <= #tokens do
        local t = cur()
        if     t.tag=="EXTERN" then prog.externs[#prog.externs+1] = parse_extern()
        elseif t.tag=="LINKTO" then prog.links[#prog.links+1]     = parse_linkto()
        elseif t.tag=="FUNC"   then prog.funcs[#prog.funcs+1]     = parse_funcdef()
        elseif t.tag=="STRUCT" then parse_struct()
        elseif t.tag=="GLOBAL" then prog.globals[#prog.globals+1] = parse_global()
        elseif t.tag=="IMPL"   then
            local methods = parse_impl()
            for _, m in ipairs(methods) do prog.funcs[#prog.funcs+1] = m end
        else
            local s = parse_stmt()
            if s then prog.toplevel_stmts[#prog.toplevel_stmts+1] = s end
        end
    end

    return prog
end

return parse
