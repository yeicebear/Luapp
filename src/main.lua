-- lpp compiler driver
-- usage: lpp <source.lpp> [-o output] [--run]

local lpp_tokenize = require("lexer")
local lpp_parse    = require("parser")
local lpp_analyze  = require("analyze")
local lpp_codegen  = require("codegen")

if type(lpp_tokenize) == "table" then lpp_tokenize = lpp_tokenize.lpp_tokenize or lpp_tokenize.scan   end
if type(lpp_parse)    == "table" then lpp_parse    = lpp_parse.lpp_parse    or lpp_parse.parse         end
if type(lpp_analyze)  == "table" then lpp_analyze  = lpp_analyze.lpp_analyze or lpp_analyze.analyze    end
if type(lpp_codegen)  == "table" then lpp_codegen  = lpp_codegen.lpp_codegen or lpp_codegen.codegen    end

local lpp_is_windows = package.config:sub(1,1) == "\\"

local function lpp_home()
    return os.getenv("USERPROFILE") or os.getenv("HOME") or "."
end

local function lpp_find_file(name)
    local candidates = {
        lpp_home().."/.lpp/lib/"..name,
        lpp_home().."/.local/lib/lpp/"..name,
        "/usr/local/lib/lpp/"..name,
        "./src/"..name,
        "./lib/"..name,
        "./"..name,
    }
    for i=1,#candidates do
        local f = io.open(candidates[i], "r")
        if f then f:close(); return candidates[i] end
    end
end

-- platform hopping god slopping dih jorkin 'add sdl2 if missing, works on both blyatforms'
local function lpp_ensure_sdl2()
    if lpp_is_windows then
        io.stderr:write("lpp: gamelib on windows requires SDL2. install via MSYS2:\n")
        io.stderr:write("     pacman -S mingw-w64-x86_64-SDL2 mingw-w64-x86_64-SDL2_ttf\n")
        return false
    end
    if os.execute("pkg-config --exists sdl2 2>/dev/null") then return true end
    io.stderr:write("lpp: SDL2 not found, trying to install it...\n")
    local uname = io.popen("uname"):read("*l")
    if uname == "Darwin" then
        os.execute("brew install sdl2 sdl2_ttf")
    else
        if os.execute("which apt-get > /dev/null 2>&1") then
            os.execute("sudo apt-get install -y libsdl2-dev libsdl2-ttf-dev")
        elseif os.execute("which pacman > /dev/null 2>&1") then
            os.execute("sudo pacman -S --noconfirm sdl2 sdl2_ttf")
        elseif os.execute("which dnf > /dev/null 2>&1") then
            os.execute("sudo dnf install -y SDL2-devel SDL2_ttf-devel")
        else
            io.stderr:write("lpp: couldn't auto-install SDL2, please install it manually\n")
            return false
        end
    end
    return true
end

local lpp_known_libs = {
    ["std"]     = { cfile="stdlib.c",  sdl=false },
    ["gamelib"] = { cfile="gamelib.c", sdl=true  },
}

local lpp_default_out = lpp_is_windows and "a.exe" or "a.out"
local lpp_infile, lpp_outfile, lpp_do_run = nil, lpp_default_out, false

do
    local i = 1
    local argv = arg or {}
    while i <= #argv do
        if     argv[i] == "-o"      then lpp_outfile = argv[i+1]; i = i+2
        elseif argv[i] == "--run"   then lpp_do_run = true; i = i+1
        elseif argv[i] == "-r"      then lpp_do_run = true; i = i+1
        elseif argv[i] == "--version" then
            print("lpp 0.4.0")
            os.exit(0)
        elseif argv[i] == "--license" then
            print([[MIT License

Copyright (c) 2026 yeicebear/icebearunreal

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.]])
            os.exit(0)
        elseif argv[i] == "--help" then
            print("lpp — Lua++")
            print("a blazingly fast (no, seriously, it compiles to native machine code!) Lua/Go/Rust/C inspired language, by icebearunreal!")
            print("")
            print("usage:  lpp <file.lpp> [flags]")
            print("")
            print("  -o <n>       name the output binary")
            print("  --run        compile and run")
            print("  --version    print version")
            print("  --license    print license")
            print("  --help       you're looking at it")
            print("")
            print("stdlib:")
            print("  linkto \"std\"               input, rand, sleep, time, print")
            print("  linkto \"gamelib\"           SDL2 canvas, text, input")
            print("  linkto \"../utils/foo.lpp\"  import another lpp file")
            print("")
            os.exit(0)
        else
            lpp_infile = argv[i]; i = i+1
        end
    end
end

if not lpp_infile then
    io.stderr:write("lpp: no input file given\n")
    io.stderr:write("     [usage] lpp <file.lpp> [-o output] [--run]\n")
    os.exit(1)
end

local ok, err = pcall(function()
    local fh = io.open(lpp_infile, "r")
    if not fh then error("can't open '"..lpp_infile.."'") end
    local src = fh:read("*all")
    fh:close()

    local lpp_ast = lpp_parse(lpp_tokenize(src))

    local function lpp_merge_lpp_file(ast, path)
        local f = io.open(path, "r")
        if not f then error("linkto: can't open '"..path.."'") end
        local src2 = f:read("*all"); f:close()
        local ast2 = lpp_parse(lpp_tokenize(src2))
        for i=1,#ast2.funcs   do ast.funcs[#ast.funcs+1]     = ast2.funcs[i]   end
        for i=1,#ast2.externs do ast.externs[#ast.externs+1] = ast2.externs[i] end
        for i=1,#ast2.links do
            if not ast2.links[i].islpp then
                ast.links[#ast.links+1] = ast2.links[i]
            end
        end
    end

    local lpp_sep   = lpp_is_windows and "\\" or "/"
    local lpp_indir = lpp_infile:match("^(.*)[/\\]") or "."
    for i=1,#lpp_ast.links do
        local lk = lpp_ast.links[i]
        if lk.islpp then
            local path = lk.libname
            if not path:match("^[/\\]") and not path:match("^%a:") then
                path = lpp_indir..lpp_sep..path
            end
            lpp_merge_lpp_file(lpp_ast, path)
        end
    end

    lpp_analyze(lpp_ast)
    local lpp_ssa = lpp_codegen(lpp_ast)

    local lpp_ssa_path = lpp_infile..".ssa"
    local lpp_asm_path = lpp_infile..".s"

    local sf = io.open(lpp_ssa_path, "w")
    sf:write(lpp_ssa); sf:close()

    local qbe = io.popen(string.format("qbe -o %s %s 2>&1", lpp_asm_path, lpp_ssa_path))
    local lpp_qbe_out = qbe:read("*a")
    local lpp_qbe_ok  = qbe:close()
    if not lpp_qbe_ok then error("qbe failed:\n"..lpp_qbe_out) end

    local extra_c     = {}
    local extra_flags = {}
    local needs_sdl   = false

    for i=1,#lpp_ast.links do
        local lk = lpp_ast.links[i]
        if not lk.islpp then
            local lib = lpp_known_libs[lk.libname]
            if lib then
                local path = lpp_find_file(lib.cfile)
                if path then
                    extra_c[#extra_c+1] = path
                else
                    io.stderr:write("lpp: warning: can't find "..lib.cfile.." for linkto \""..lk.libname.."\"\n")
                end
                if lib.sdl then needs_sdl = true end
            else
                io.stderr:write("lpp: warning: unknown library \""..lk.libname.."\"\n")
            end
        end
    end

    if needs_sdl then
        lpp_ensure_sdl2()
        extra_flags[#extra_flags+1] = "-lSDL2 -lSDL2_ttf -lm"
    end

    -- os.tmpname() gives unix paths which windows can't use, so we roll our own
    local wrap_path
    if lpp_is_windows then
        wrap_path = (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp").."\\lpp_wrap_"..os.time()..".c"
    else
        wrap_path = os.tmpname()..".c"
    end

    local wf = io.open(wrap_path, "w")
    wf:write("extern int lang_main();\nint main(){return lang_main();}\n")
    wf:close()

    local lpp_cc = lpp_is_windows and "gcc" or "cc"

    local cc_cmd = string.format("%s %s %s %s -o %s %s",
        lpp_cc,
        lpp_asm_path,
        wrap_path,
        table.concat(extra_c, " "),
        lpp_outfile,
        table.concat(extra_flags, " "))

    local cc_ok = os.execute(cc_cmd)
    if not cc_ok then error("cc failed, linker is cooked") end

    if lpp_do_run then
        if lpp_is_windows then
            os.execute(lpp_outfile)
        else
            os.execute("./"..lpp_outfile)
        end
    end
end)

if not ok then
    io.stderr:write("lpp: "..tostring(err).."\n")
    os.exit(1)
end
