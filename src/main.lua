-- main.lua  |  sector_8:compiler_driver
-- source.lpp → tokens → ast → checked ast → qbe ir → asm → binary.
-- usage: lpp <file.lpp> [-o output] [--run] [--target linux|windows] [-v]
--
-- library system:
--   linkto "name" pulls in a .c file and injects extern declarations from
--   a .lpplib header. every library is isolated — no shared symbols.
--   you must be explicit. nothing is implicit.

local tokenize = require("lexer")
local parse    = require("parser")
local analyze  = require("analyze")
local codegen  = require("codegen")

local host_is_windows = package.config:sub(1,1) == "\\"
local host_is_mac     = false
if not host_is_windows then
    local u = io.popen("uname -s 2>/dev/null")
    local s = u and u:read("*l") or ""
    if u then u:close() end
    host_is_mac = (s == "Darwin")
end

local function home_dir()
    return os.getenv("USERPROFILE") or os.getenv("HOME") or "."
end

local function find_file(name)
    local search_paths = {
        home_dir().."/.lpp/lib/"..name,
        home_dir().."/.local/lib/lpp/"..name,
        "/usr/local/lib/lpp/"..name,
        "./src/"..name,
        "./lib/"..name,
        "./"..name,
    }
    for _, p in ipairs(search_paths) do
        local f = io.open(p, "r")
        if f then f:close(); return p end
    end
end

local function shell(cmd)
    local r = os.execute(cmd)
    return r == true or r == 0
end

local function capture(cmd)
    local pipe = io.popen(cmd.." 2>&1")
    if not pipe then return "", false end
    local out = pipe:read("*a") or ""
    local rc  = pipe:close()
    return out, (rc == true or rc == 0)
end

local verbose = false
local function log(msg)
    if verbose then io.stderr:write("lpp: "..msg.."\n") end
end

-- sector_8:lib_registry
-- each entry: cfile, lpplib, and linker requirements.
-- no two libraries may export the same symbol.
local lib_registry = {
    ["std"]       = { cfile="stdlib.c",    lpplib="stdlib.lpplib",    sdl=false, pthread=false, math=false },
    ["gamelib"]   = { cfile="gamelib.c",   lpplib="gamelib.lpplib",   sdl=true,  pthread=false, math=false },
    ["mathlib"]   = { cfile="mathlib.c",   lpplib="mathlib.lpplib",   sdl=false, pthread=false, math=true  },
    ["threadlib"] = { cfile="threadlib.c", lpplib="threadlib.lpplib", sdl=false, pthread=true,  math=false },
    ["netlib"]    = { cfile="netlib.c",    lpplib="netlib.lpplib",    sdl=false, pthread=false, math=false },
    ["ailib"]     = { cfile="ailib.c",     lpplib="ailib.lpplib",     sdl=false, pthread=false, math=true  },
}

-- stdlib is an alias people commonly try
lib_registry["stdlib"] = nil

-- strip qbe's linux-specific asm directives so mingw-gcc accepts the output
local function patch_asm_for_windows(path)
    local f   = io.open(path, "r"); if not f then return end
    local asm = f:read("*a"); f:close()
    asm = asm:gsub('[^\n]*%.note%.GNU%-stack[^\n]*\n?', '')
    asm = asm:gsub('%.balign%s+0%f[%s\n]', '.balign 1')
    asm = asm:gsub('%f[%a]callq%f[%A]', 'call')
    asm = asm:gsub('%f[%a]jmpq%f[%A]',  'jmp')
    asm = asm:gsub('%f[%a]pushq%f[%A]', 'push')
    asm = asm:gsub('%f[%a]popq%f[%A]',  'pop')
    asm = asm:gsub('/%*.-%*/', '')
    asm = asm:gsub('\n\n\n+', '\n\n')
    local f2 = io.open(path, "w"); f2:write(asm); f2:close()
end

local function install_sdl2()
    if shell("pkg-config --exists sdl2 2>/dev/null") then return true end
    io.stderr:write("lpp: sdl2 not found, trying to install...\n")
    if host_is_mac then
        shell("brew install sdl2 sdl2_ttf")
    elseif shell("which apt-get>/dev/null 2>&1") then
        shell("sudo apt-get install -y libsdl2-dev libsdl2-ttf-dev")
    elseif shell("which pacman>/dev/null 2>&1") then
        shell("sudo pacman -S --noconfirm sdl2 sdl2_ttf")
    elseif shell("which dnf>/dev/null 2>&1") then
        shell("sudo dnf install -y SDL2-devel SDL2_ttf-devel")
    else
        io.stderr:write("lpp: install sdl2 manually:\n")
        io.stderr:write("  ubuntu: sudo apt install libsdl2-dev libsdl2-ttf-dev\n")
        return false
    end
    return true
end

local function install_cross_sdl2()
    if shell("dpkg -s libsdl2-mingw-dev>/dev/null 2>&1") then return true end
    io.stderr:write("lpp: cross-sdl2 not found, trying to install...\n")
    if shell("sudo apt-get install -y libsdl2-dev libsdl2-ttf-dev gcc-mingw-w64-x86_64 2>/dev/null") then
        return true
    end
    io.stderr:write("lpp: try: sudo apt install libsdl2-mingw-dev libsdl2-ttf-mingw-dev\n")
    return false
end

-- sector_8:arg_parse
local input_file        = nil
local output_bin        = nil
local run_after         = false
local target            = nil
local conserve_artifacts = false
do
    local argv = arg or {}
    local i    = 1
    while i <= #argv do
        local a = argv[i]
        if     a=="-o"        then output_bin = argv[i+1]; i=i+2
        elseif a=="--target"  then target     = argv[i+1]; i=i+2
        elseif a=="--run" or a=="-r"        then run_after=true;  i=i+1
        elseif a=="--verbose" or a=="-v"    then verbose=true;    i=i+1
        elseif a=="--version" then print("lpp 0.8.0"); os.exit(0)
        elseif a=="--conserve-artifacts" then conserve_artifacts=true; i=i+1
        elseif a=="--license" then
            print("MIT License\nCopyright (c) 2026 yeicebear/icebearunreal")
            os.exit(0)
        elseif a=="--help" then
            print("lpp is a blazingly fast programming language.")
            print("usage: lpp <file.lpp> [flags]")
            print("")
            print("  -o <name>        output binary")
            print("  --target <t>     linux or windows")
            print("  --run / -r       compile then run")
            print("  --verbose / -v   print each step")
            print("")
            print("libraries (use linkto in your .lpp file):")
            local names = {}
            for k in pairs(lib_registry) do names[#names+1] = k end
            table.sort(names)
            for _, n in ipairs(names) do print("  "..n) end
            print("")
            print("rules: every library is independent. no two share any function.")
            print("std and gamelib both define print_int — don't linkto both.")
            os.exit(0)
        else
            input_file = argv[i]; i=i+1
        end
    end
end

if verbose then
    io.stderr:write("lpp: args parsed, input="..tostring(input_file).."\n")
end

if not input_file then
    io.stderr:write("lpp: no input file. usage: lpp <file.lpp>\n")
    os.exit(1)
end

if not target then
    target = host_is_windows and "windows" or "linux"
elseif target ~= "linux" and target ~= "windows" then
    io.stderr:write("lpp: unknown target '"..target.."' — use linux or windows\n")
    os.exit(1)
end

local win_target = target == "windows"
local cross      = win_target and not host_is_windows

if not output_bin then output_bin = win_target and "a.exe" or "a.out" end
if win_target and not output_bin:match("%.[^/\\]+$") then output_bin = output_bin..".exe" end

-- sector_8:compile_pipeline
local ok, err = pcall(function()

    local fh = io.open(input_file, "r")
    if not fh then error("can't open '"..input_file.."'") end
    local src = fh:read("*all"); fh:close()

    log("lex+parse "..input_file)
    local ast = parse(tokenize(src))

    -- merge .lpp linkto files into the ast before analysis
    local sep    = host_is_windows and "\\" or "/"
    local indir  = input_file:match("^(.*)[/\\]") or "."
    for _, lk in ipairs(ast.links) do
        if lk.islpp then
            local path = lk.libname
            if not path:match("^[/\\]") and not path:match("^%a:") then
                path = indir..sep..path
            end
            local f2 = io.open(path, "r")
            if not f2 then error("linkto: can't open '"..path.."'") end
            local src2 = f2:read("*all"); f2:close()
            local ast2 = parse(tokenize(src2))
            for _, fn in ipairs(ast2.funcs)   do ast.funcs[#ast.funcs+1]     = fn  end
            for _, ex in ipairs(ast2.externs) do ast.externs[#ast.externs+1] = ex  end
            for _, lk2 in ipairs(ast2.links)  do
                if not lk2.islpp then ast.links[#ast.links+1] = lk2 end
            end
        end
    end

    -- inject extern declarations from .lpplib headers
    do
        local seen_externs = {}
        for _, ex in ipairs(ast.externs) do seen_externs[ex.fname] = true end

        local function inject_lpplib(path)
            local f = io.open(path, "r"); if not f then return end
            local src2 = f:read("*all"); f:close()
            local hdr  = parse(tokenize(src2))
            for _, ex in ipairs(hdr.externs) do
                if not seen_externs[ex.fname] then
                    ast.externs[#ast.externs+1] = ex
                    seen_externs[ex.fname] = true
                end
            end
        end

        for _, lk in ipairs(ast.links) do
            if not lk.islpp then
                local lib = lib_registry[lk.libname]
                if lib and lib.lpplib then
                    local hpath = find_file(lib.lpplib)
                    if hpath then
                        log("inject header: "..hpath)
                        inject_lpplib(hpath)
                    else
                        io.stderr:write("lpp: warning: can't find "..lib.lpplib.."\n")
                    end
                elseif not lib then
                    local known = {}
                    for k in pairs(lib_registry) do known[#known+1] = k end
                    table.sort(known)
                    error("unknown library \""..lk.libname.."\"\n"..
                          "  known: "..table.concat(known, ", "))
                end
            end
        end
    end

    log("analyze")
    analyze(ast)

    local has_main = false
    for _, fn in ipairs(ast.funcs) do if fn.fname=="main" then has_main=true; break end end
    if not has_main and not (ast.toplevel_stmts and #ast.toplevel_stmts > 0) then
        error("no main() in '"..input_file.."'\n\n"..
              "    func main(): int {\n        return 0\n    }\n")
    end

    log("codegen")
    local ir_text = codegen(ast)

    local ssa_path = input_file..".ssa"
    local asm_path = input_file..".s"
    local sf       = io.open(ssa_path, "w"); sf:write(ir_text); sf:close()

    local qbe_bin = host_is_windows and "qbe.exe" or "qbe"
    local qbe_cmd = string.format('%s -o "%s" "%s"', qbe_bin, asm_path, ssa_path)
    log("qbe: "..qbe_cmd)
    local qbe_out, qbe_ok = capture(qbe_cmd)
    if not qbe_ok then error("qbe failed:\n"..qbe_out) end

    if win_target then patch_asm_for_windows(asm_path) end

    local c_files    = {}
    local link_flags = {}
    local need_sdl   = false
    local need_math  = false
    local need_pthrd = false

    for _, lk in ipairs(ast.links) do
        if not lk.islpp then
            local lib = lib_registry[lk.libname]
            if lib then
                local path = find_file(lib.cfile)
                if path then c_files[#c_files+1] = '"'..path..'"'
                else io.stderr:write("lpp: warning: can't find "..lib.cfile.."\n")
                end
                if lib.sdl     then need_sdl   = true end
                if lib.math    then need_math   = true end
                if lib.pthread then need_pthrd  = true end
            end
        end
    end

    if need_math  then link_flags[#link_flags+1] = "-lm"       end
    if need_pthrd then link_flags[#link_flags+1] = "-lpthread"  end

    if need_sdl then
        if cross then
            if not install_cross_sdl2() then error("cross-sdl2 unavailable") end
            link_flags[#link_flags+1] = "-lSDL2 -lSDL2_ttf -lm"
            link_flags[#link_flags+1] = "-I/usr/x86_64-w64-mingw32/include"
        elseif win_target then
            link_flags[#link_flags+1] = "-lSDL2 -lSDL2_ttf -lm"
        else
            if not install_sdl2() then error("sdl2 unavailable") end
            link_flags[#link_flags+1] = "$(pkg-config --libs sdl2 SDL2_ttf) -lm"
        end
    end

    local tmp_wrap
    if host_is_windows then
        local td = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
        tmp_wrap = td.."\\lpp_wrap_"..os.time()..math.random(10000,99999)..".c"
    else
        tmp_wrap = "/tmp/lpp_wrap_"..os.time()..math.random(10000,99999)..".c"
    end
    local wf = io.open(tmp_wrap, "w")
    if not wf then error("can't write temp file: "..tmp_wrap) end
    wf:write("extern int lang_main();\nint main(){return lang_main();}\n")
    wf:close()

    local cc       = cross and "x86_64-w64-mingw32-gcc" or host_is_windows and "gcc" or "cc"
    local win_extra = win_target
        and "-lkernel32 -static-libgcc -Wl,-Bstatic -lmingwex -Wl,-Bdynamic"
        or  ""

    local cc_cmd = string.format('%s "%s" "%s" %s -o "%s" %s %s',
        cc, asm_path, tmp_wrap,
        table.concat(c_files, " "),
        output_bin,
        table.concat(link_flags, " "),
        win_extra)

    log("cc: "..cc_cmd)
    local cc_out, cc_ok = capture(cc_cmd)
    if not cc_ok then error("compiler failed:\n"..cc_out.."\ncmd: "..cc_cmd) end

    os.remove(tmp_wrap)
    if cross then io.stderr:write("lpp: built "..output_bin.." (windows, cross-compiled)\n") end
    if not conserve_artifacts then
        if ssa_path then os.remove(ssa_path) end
        if asm_path then os.remove(asm_path) end
    end

    if run_after then
        if win_target and not host_is_windows then
            io.stderr:write("lpp: --run skipped (can't execute .exe on this host)\n")
        elseif host_is_windows then
            shell('"'..output_bin..'"')
        else
            local run_cmd = output_bin:match("^/") and output_bin or "./"..output_bin
            shell(run_cmd)
        end
    end

end)

if not ok then
    local msg = tostring(err):gsub("^[^:\n]+:%d+: ", "")
    io.stderr:write(msg.."\n")
    os.exit(1)
end
