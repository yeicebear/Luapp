-- lpp semantic pass.
-- catches undefined vars/functions before we hit qbe.
-- tracks array and struct declarations for basic validation.

local lpp_valid_ops = {
    PLUS=1, MINUS=1, STAR=1, SLASH=1, PCENT=1,
    EQ=1, NEQ=1, GT=1, LT=1, GE=1, LE=1, AND=1, OR=1,
}

local lpp_scopestack = {}
local lpp_known_fns
local lpp_known_structs

-- builtins always available without linkto
local lpp_builtins = {
    print=1, print_str=1, print_int=1,
}

local function lpp_scope_enter()  lpp_scopestack[#lpp_scopestack+1] = {} end
local function lpp_scope_leave()  lpp_scopestack[#lpp_scopestack] = nil  end
local function lpp_scope_bind(nm, vtype)
    lpp_scopestack[#lpp_scopestack][nm] = vtype or "int"
end
local function lpp_scope_lookup(nm)
    for i = #lpp_scopestack, 1, -1 do
        if lpp_scopestack[i][nm] then return lpp_scopestack[i][nm] end
    end
end

local function lpp_err(msg) error("lpp: " .. msg) end

local function lpp_chk_xpr(nd)
    if not nd then return end
    local k = nd.kind

    if k == "lit_int" or k == "lit_float" or k == "lit_str" then return

    elseif k == "var" then
        if not lpp_scope_lookup(nd.vname) then
            lpp_err("'"..nd.vname.."' used before it was declared")
        end

    elseif k == "arr_get" then
        if not lpp_scope_lookup(nd.vname) then
            lpp_err("array '"..nd.vname.."' used before declared")
        end
        lpp_chk_xpr(nd.idx)

    elseif k == "field_get" then
        if not lpp_scope_lookup(nd.vname) then
            lpp_err("'"..nd.vname.."' used before declared")
        end

    elseif k == "binop" then
        if not lpp_valid_ops[nd.op] then lpp_err("unknown operator '"..nd.op.."'") end
        lpp_chk_xpr(nd.lhs); lpp_chk_xpr(nd.rhs)

    elseif k == "uneg" or k == "unot" then
        lpp_chk_xpr(nd.x)

    elseif k == "call" then
        if not lpp_known_fns[nd.fname] and not lpp_builtins[nd.fname] then
            lpp_err("'"..nd.fname.."' — no such function")
        end
        for i=1,#nd.args do lpp_chk_xpr(nd.args[i]) end

    else lpp_err("lpp_chk_xpr: unhandled node '"..tostring(k).."'")
    end
end

local function lpp_scope_walk(bl)
    lpp_scope_enter()
    for i=1,#bl.stmts do
        local s = bl.stmts[i]
        local k = s.kind

        if k == "decl" then
            if s.rhs then lpp_chk_xpr(s.rhs) end
            lpp_scope_bind(s.vname, s.vtype)

        elseif k == "assign" then
            if not lpp_scope_lookup(s.vname) then
                lpp_err("can't assign to '"..s.vname.."' — declare it first with local")
            end
            lpp_chk_xpr(s.rhs)

        elseif k == "arr_set" then
            if not lpp_scope_lookup(s.vname) then
                lpp_err("array '"..s.vname.."' not declared")
            end
            lpp_chk_xpr(s.idx); lpp_chk_xpr(s.rhs)

        elseif k == "field_set" then
            if not lpp_scope_lookup(s.vname) then
                lpp_err("'"..s.vname.."' not declared")
            end
            lpp_chk_xpr(s.rhs)

        elseif k == "ret"   then lpp_chk_xpr(s.val)
        elseif k == "brk"   then
        elseif k == "xstmt" then lpp_chk_xpr(s.expr)

        elseif k == "ifx" then
            lpp_chk_xpr(s.cond)
            lpp_scope_walk(s.yes)
            if s.no then lpp_scope_walk(s.no) end

        elseif k == "loop" then
            lpp_chk_xpr(s.cond)
            lpp_scope_walk(s.body)

        elseif k == "casex" then
            lpp_chk_xpr(s.subject)
            for j=1,#s.arms do
                lpp_chk_xpr(s.arms[j].val)
                lpp_scope_walk(s.arms[j].body)
            end
            if s.default then lpp_scope_walk(s.default) end

        else lpp_err("lpp_scope_walk: unhandled stmt '"..tostring(k).."'")
        end
    end
    lpp_scope_leave()
end

local function lpp_analyze(prog)
    if not prog or prog.kind ~= "prog" then
        lpp_err("lpp_analyze didn't get a program node")
    end

    lpp_scopestack  = {}
    lpp_known_fns   = {}
    lpp_known_structs = prog.structs or {}

    for i=1,#prog.externs do lpp_known_fns[prog.externs[i].fname] = true end
    for i=1,#prog.funcs   do lpp_known_fns[prog.funcs[i].fname]   = true end

    for i=1,#prog.funcs do
        local fn = prog.funcs[i]
        lpp_scope_enter()
        for j=1,#fn.params do lpp_scope_bind(fn.params[j].pname, fn.params[j].ptype) end
        lpp_scope_walk(fn.body)
        lpp_scope_leave()
    end
    return true
end

-- This stupid ass problem alone caused me 4 sleepless nights.

return lpp_analyze
