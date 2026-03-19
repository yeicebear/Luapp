-- analyze.lua  |  sector_8:semantic_check
-- walks the ast and catches usage errors before codegen sees them.
-- not a type checker — lpp trusts you on types.
-- catches: undeclared variables, unknown functions, undefined operators.

local valid_binary_ops = {
    PLUS=1, MINUS=1, STAR=1, SLASH=1, PCENT=1,
    EQ=1, NEQ=1, GT=1, LT=1, GE=1, LE=1, AND=1, OR=1,
    AMP=1, PIPE=1, CARET=1, SHL=1, SHR=1,
}

local scope_stack   = {}
local known_funcs   = {}
local known_structs = {}
local known_globals = {}

-- print is a built-in alias for print_int — never needs an extern declaration.
local builtins = { print=1 }

local function scope_push()  scope_stack[#scope_stack+1] = {}         end
local function scope_pop()   scope_stack[#scope_stack]   = nil        end
local function scope_def(nm, t) scope_stack[#scope_stack][nm] = t or "int" end

local function scope_lookup(nm)
    for i = #scope_stack, 1, -1 do
        if scope_stack[i][nm] then return scope_stack[i][nm] end
    end
    return known_globals[nm]
end

local function die(msg, line)
    error(line and ("lpp: line "..line..": "..msg) or ("lpp: "..msg))
end

local function check_xpr(n)
    if not n then return end
    local k  = n.kind
    local ln = n.line

    if k=="lit_int" or k=="lit_float" or k=="lit_str" then return end

    if k=="var" then
        if not scope_lookup(n.vname) then
            die("'"..n.vname.."' used before declaration", ln)
        end

    elseif k=="arr_get" then
        if not scope_lookup(n.vname) then die("array '"..n.vname.."' not declared", ln) end
        check_xpr(n.idx)

    elseif k=="field_get" then
        if not scope_lookup(n.vname) then die("'"..n.vname.."' not declared", ln) end

    elseif k=="binop" then
        if not valid_binary_ops[n.op] then die("unknown operator '"..n.op.."'", ln) end
        check_xpr(n.lhs); check_xpr(n.rhs)

    elseif k=="uneg" or k=="unot" then
        check_xpr(n.x)

    elseif k=="call" then
        if not known_funcs[n.fname] and not builtins[n.fname] then
            die("'"..n.fname.."' — unknown function (missing extern or linkto?)", ln)
        end
        for _, arg in ipairs(n.args) do check_xpr(arg) end

    elseif k=="method_call" then
        for _, arg in ipairs(n.args) do check_xpr(arg) end

    else
        die("check_xpr: unhandled node '"..tostring(k).."' — compiler bug", ln)
    end
end

local function walk_block(block)
    scope_push()
    for _, s in ipairs(block.stmts) do
        local k  = s.kind
        local ln = s.line

        if k=="decl" then
            if s.rhs then check_xpr(s.rhs) end
            scope_def(s.vname, s.vtype)

        elseif k=="assign" then
            if not scope_lookup(s.vname) then
                die("'"..s.vname.."' assigned before declaration — use 'local' first", ln)
            end
            check_xpr(s.rhs)

        elseif k=="arr_set" then
            if not scope_lookup(s.vname) then die("array '"..s.vname.."' not declared", ln) end
            check_xpr(s.idx); check_xpr(s.rhs)

        elseif k=="field_set" then
            if not scope_lookup(s.vname) then die("'"..s.vname.."' not declared", ln) end
            check_xpr(s.rhs)

        elseif k=="ret"   then check_xpr(s.val)
        elseif k=="brk"   then
        elseif k=="cont"  then
        elseif k=="xstmt" then check_xpr(s.expr)

        elseif k=="ifx" then
            check_xpr(s.cond)
            walk_block(s.yes)
            if s.no then walk_block(s.no) end

        elseif k=="loop" then
            check_xpr(s.cond)
            walk_block(s.body)

        elseif k=="forloop" then
            check_xpr(s.start); check_xpr(s.limit); check_xpr(s.step)
            scope_push()
            scope_def(s.iname, "int")
            walk_block(s.body)
            scope_pop()

        elseif k=="casex" then
            check_xpr(s.subject)
            for _, arm in ipairs(s.arms) do
                check_xpr(arm.val)
                walk_block(arm.body)
            end
            if s.default then walk_block(s.default) end

        else
            die("walk_block: unhandled stmt '"..tostring(k).."' — compiler bug")
        end
    end
    scope_pop()
end

local function analyze(prog)
    if not prog or prog.kind ~= "prog" then
        die("analyze got non-program node — something upstream broke")
    end

    scope_stack   = {}
    known_funcs   = {}
    known_structs = prog.structs or {}
    known_globals = {}

    for _, g in ipairs(prog.globals or {}) do
        known_globals[g.gname] = g.gtype
    end

    for _, ex in ipairs(prog.externs) do known_funcs[ex.fname] = true end
    for _, fn in ipairs(prog.funcs)   do known_funcs[fn.fname] = true end

    for _, fn in ipairs(prog.funcs) do
        scope_push()
        for _, p in ipairs(fn.params) do scope_def(p.pname, p.ptype) end
        walk_block(fn.body)
        scope_pop()
    end

    return true
end

return analyze
