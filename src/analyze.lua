-- lpp semantic pass.
-- not a type system. catches stuff that would give you a
-- completely useless error from qbe like "undefined temporary %x_slot"
-- instead of "you forgot to declare x, dummy"

local lpp_valid_ops = {
    PLUS=1, MINUS=1, STAR=1, SLASH=1, PCENT=1,
    EQ=1, NEQ=1, GT=1, LT=1, GE=1, LE=1, AND=1, OR=1,
}

-- scope is just a stack of tables. nothing fancy.
local lpp_scopestack = {}

local function lpp_scope_enter()  lpp_scopestack[#lpp_scopestack+1] = {} end
local function lpp_scope_leave()  lpp_scopestack[#lpp_scopestack] = nil  end
local function lpp_scope_bind(nm) lpp_scopestack[#lpp_scopestack][nm] = true end
local function lpp_scope_lookup(nm)
    for i = #lpp_scopestack, 1, -1 do
        if lpp_scopestack[i][nm] then return true end
    end
end

local function lpp_err(msg) error("lpp: " .. msg) end

local lpp_known_fns  -- populated by lpp_analyze, read by lpp_chk_xpr

-- builtins always available without declaration
local lpp_builtins = {
    print=1, print_str=1, print_int=1,
    -- gamelib builtins (provided by gamelib.c)
    rand_int=1, sleep_ms=1, time_ms=1, input_int=1,
}

local function lpp_chk_xpr(nd)
    if not nd then return end
    local k = nd.kind

    if k == "lit_int" then return
    elseif k == "lit_str" then return

    elseif k == "var" then
        if not lpp_scope_lookup(nd.vname) then
            lpp_err("'"..nd.vname.."' used before it was declared")
        end

    elseif k == "binop" then
        if not lpp_valid_ops[nd.op] then lpp_err("unknown operator '"..nd.op.."'") end
        lpp_chk_xpr(nd.lhs)
        lpp_chk_xpr(nd.rhs)

    elseif k == "uneg" or k == "unot" then
        lpp_chk_xpr(nd.x)

    elseif k == "call" then
        if not lpp_known_fns[nd.fname] and not lpp_builtins[nd.fname] then
            lpp_err("'"..nd.fname.."' — no such function")
        end
        for i=1,#nd.args do lpp_chk_xpr(nd.args[i]) end

    else lpp_err("lpp_chk_xpr: unhandled node kind '"..tostring(k).."'")
    end
end

local function lpp_scope_walk(bl)
    lpp_scope_enter()
    for i=1,#bl.stmts do
        local s = bl.stmts[i]
        local k = s.kind

        if k == "decl" then
            lpp_chk_xpr(s.rhs)
            lpp_scope_bind(s.vname)  -- bind after rhs so `local x: int = x` is caught

        elseif k == "assign" then
            if not lpp_scope_lookup(s.vname) then
                lpp_err("can't assign to '"..s.vname.."', declare it first with local")
            end
            lpp_chk_xpr(s.rhs)

        elseif k == "ret"   then lpp_chk_xpr(s.val)
        elseif k == "brk"   then  -- loop depth is codegen's problem
        elseif k == "xstmt" then lpp_chk_xpr(s.expr)

        elseif k == "ifx" then
            lpp_chk_xpr(s.cond)
            lpp_scope_walk(s.yes)
            if s.no then lpp_scope_walk(s.no) end

        elseif k == "loop" then
            lpp_chk_xpr(s.cond)
            lpp_scope_walk(s.body)

        else lpp_err("lpp_scope_walk: unhandled stmt kind '"..tostring(k).."'")
        end
    end
    lpp_scope_leave()
end

local function lpp_analyze(prog)
    if not prog or prog.kind ~= "prog" then
        lpp_err("lpp_analyze didn't get a program node, something is very wrong")
    end

    lpp_scopestack = {}  -- reset between runs
    lpp_known_fns = {}

    -- register extern declarations as known functions
    for i=1,#prog.externs do
        lpp_known_fns[prog.externs[i].fname] = true
    end

    -- register all user-defined functions
    for i=1,#prog.funcs do
        local fn = prog.funcs[i]
        if not fn.fname or fn.fname == "" then lpp_err("unnamed function") end
        lpp_known_fns[fn.fname] = true
    end

    for i=1,#prog.funcs do
        local fn = prog.funcs[i]
        lpp_scope_enter()
        for j=1,#fn.params do lpp_scope_bind(fn.params[j].pname) end
        lpp_scope_walk(fn.body)
        lpp_scope_leave()
    end
    return true
end

-- This stupid ass problem alone caused me 4 sleepless nights.

return lpp_analyze
