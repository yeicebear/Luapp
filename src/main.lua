-- lpp compiler driver
-- usage: lpp <source.lpp> [-o output] [--run]

local lpp_tokenize = require("lexer")
local lpp_parse    = require("parser")
local lpp_analyze  = require("analyze")
local lpp_codegen  = require("codegen")

-- luastatic sometimes wraps modules in a table
if type(lpp_tokenize) == "table" then lpp_tokenize = lpp_tokenize.lpp_tokenize or lpp_tokenize.scan   end
if type(lpp_parse)    == "table" then lpp_parse    = lpp_parse.lpp_parse    or lpp_parse.parse         end
if type(lpp_analyze)  == "table" then lpp_analyze  = lpp_analyze.lpp_analyze or lpp_analyze.analyze    end
if type(lpp_codegen)  == "table" then lpp_codegen  = lpp_codegen.lpp_codegen or lpp_codegen.codegen    end

-- runtime.c gets compiled and linked with every lpp program.
-- shipped to /usr/local/lib/lpp/ but falls back to local copies
-- so it works from the source tree without installing.
local function lpp_find_runtime()
    local lpp_rt_candidates = {
        "/usr/local/lib/lpp/runtime.c",
        "./runtime.c",
        "./lib/runtime.c",
        "./src/runtime.c",
    }
    for i=1,#lpp_rt_candidates do
        local f = io.open(lpp_rt_candidates[i], "r")
        if f then f:close(); return lpp_rt_candidates[i] end
    end
end

-- parse CLI args the dumb way, no libraries
local lpp_infile, lpp_outfile, lpp_do_run = nil, "a.out", false
do
    local i = 1
    local argv = arg or {}
    while i <= #argv do
        if     argv[i] == "-o"     then lpp_outfile = argv[i+1]; i = i+2
        elseif argv[i] == "--run"  then lpp_do_run = true; i = i+1
        elseif argv[i] == "-r"     then lpp_do_run = true; i = i+1
        elseif argv[i] == "--version" then
            print("Lua++ 0.1.0 \n MIT")
            print([[MIT License

            Copyright (c) 2026 yeicebear

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
            SOFTWARE.
            ]])
            os.exit(0)
        elseif argv[i] == "--help" then
            print("lpp — Lua++")
            print("a blazingly fast (no, seriously, it compiles to native machine code!) Lua/Go/Rust/C inspired language, by icebearunreal!")
            print("")
            print("usage:  lpp <file.lpp> [flags]")
            print("")
            print("  -o <name>    name the output binary")
            print("  --run        compile and run")
            print("  --version    print version")
            print("  --help       you're looking at it")
            print("")
            os.exit(0)
        else
            lpp_infile = argv[i]; i = i+1
        end
    end
end

if not lpp_infile then
    io.stderr:write("lpp: no input file given\n")
    io.stderr:write("     usage: lpp <file.lpp> [-o output] [--run]\n")
    os.exit(1)
end

local lpp_runtime = lpp_find_runtime()
if not lpp_runtime then
    io.stderr:write("lpp: can't find runtime.c — try reinstalling lpp\n")
    os.exit(1)
end

local ok, err = pcall(function()
    local fh = io.open(lpp_infile, "r")
    if not fh then error("can't open '"..lpp_infile.."'") end
    local src = fh:read("*all")
    fh:close()

    local lpp_ast = lpp_parse(lpp_tokenize(src))
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

    local lpp_cc_ok = os.execute(string.format("cc %s %s -o %s",
        lpp_asm_path, lpp_runtime, lpp_outfile))
    if not lpp_cc_ok then error("cc failed — linker error") end

    if lpp_do_run then os.execute("./"..lpp_outfile) end
end)

if not ok then
    io.stderr:write("lpp: "..tostring(err).."\n")
    os.exit(1)
end