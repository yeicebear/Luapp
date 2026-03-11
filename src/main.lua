-- i wrote this, i am sorry. it is a fragile house of cards.
-- usage: lpp <source.lpp> [-o output] [--run] [--target linux|windows]
--
-- --target windows   cross-compile to .exe because i can't find a real job
--                    requires: apt install gcc-mingw-w64-x86_64
-- --target linux     force ELF output because i am predictable
-- no --target        auto-detect because i am too lazy to choose

local lpp_lexer_doer    = require("lexer")
local lpp_parser_doer   = require("parser")
local lpp_analyzer_doer = require("analyze")
local lpp_codegen_doer  = require("codegen")

if type(lpp_lexer_doer)    == "table" then lpp_lexer_doer    = lpp_lexer_doer.lpp_tokenize    or lpp_lexer_doer.scan    end
if type(lpp_parser_doer)   == "table" then lpp_parser_doer   = lpp_parser_doer.lpp_parse      or lpp_parser_doer.parse        end
if type(lpp_analyzer_doer) == "table" then lpp_analyzer_doer = lpp_analyzer_doer.lpp_analyze or lpp_analyzer_doer.analyze    end
if type(lpp_codegen_doer)  == "table" then lpp_codegen_doer  = lpp_codegen_doer.lpp_codegen   or lpp_codegen_doer.codegen    end

-- ── where am i even running this garbage ──────────────────────────────────────
local lpp_host_windows_check = package.config:sub(1,1) == "\\"
local lpp_host_mac_check     = false
if not lpp_host_windows_check then
    local up = io.popen("uname -s 2>/dev/null")
    local us = up and up:read("*l") or ""
    if up then up:close() end
    lpp_host_mac_check = (us == "Darwin")
end

-- ── sad little utility functions ──────────────────────────────────────────────
local function get_me_home_path()
    return os.getenv("USERPROFILE") or os.getenv("HOME") or "."
end

local function look_for_file_in_disaster(name)
    local candidates = {
        get_me_home_path().."/.lpp/lib/"..name,
        get_me_home_path().."/.local/lib/lpp/"..name,
        "/usr/local/lib/lpp/"..name,
        "./src/"..name,
        "./lib/"..name,
        "./"..name,
    }
    for i=1,#candidates do
        local f = io.open(candidates[i],"r")
        if f then f:close(); return candidates[i] end
    end
end

local function execute_shell_command(cmd)
    local r = os.execute(cmd)
    if r == true  then return true  end
    if r == false then return false end
    return r == 0
end

local function capture_shell_vomit(cmd)
    local pipe = io.popen(cmd.." 2>&1")
    if not pipe then return "", false end
    local out = pipe:read("*a") or ""
    local rc  = pipe:close()
    return out, (rc == true or rc == 0)
end


local function lpp_log(msg)
    if lpp_verbose then io.stderr:write("lpp: " .. msg .. "\n") end
end

-- ── qbe hates windows, so i have to perform surgery ───────────────────────────
-- qbe is a genius, my asm-patching logic is a toddler with a blunt knife.
local function lobotomize_asm_for_windows(path)
    local af = io.open(path,"r")
    if not af then return end
    local asm = af:read("*a"); af:close()

    -- 1. get rid of this because windows is allergic to it
    asm = asm:gsub('[^\n]*%.note%.GNU%-stack[^\n]*\n?','')

    -- 2. fix this because i am incapable of math
    asm = asm:gsub('%.balign%s+0%f[%s\n]','.balign 1')

    -- 3. stripping the 'q's because i am illiterate
    asm = asm:gsub('%f[%a]callq%f[%A]','call')
    asm = asm:gsub('%f[%a]jmpq%f[%A]', 'jmp')
    asm = asm:gsub('%f[%a]pushq%f[%A]','push')
    asm = asm:gsub('%f[%a]popq%f[%A]', 'pop')

    -- 4. deleting comments because i don't trust my own writing
    asm = asm:gsub('/%*.-%*/', '')

    -- 5. hiding my shame
    asm = asm:gsub('\n\n\n+','\n\n')

    local af2 = io.open(path,"w")
    af2:write(asm); af2:close()
end


-- ── begging for dependencies ──────────────────────────────────────────────────
local function install_sdl2_or_cry()
    if execute_shell_command("pkg-config --exists sdl2 2>/dev/null") then return true end
    io.stderr:write("lpp: sdl2 is missing and i am panicking...\n")
    if lpp_host_mac_check then
        execute_shell_command("brew install sdl2 sdl2_ttf")
    else
        if     execute_shell_command("which apt-get>/dev/null 2>&1") then execute_shell_command("sudo apt-get install -y libsdl2-dev libsdl2-ttf-dev")
        elseif execute_shell_command("which pacman>/dev/null 2>&1")  then execute_shell_command("sudo pacman -S --noconfirm sdl2 sdl2_ttf")
        elseif execute_shell_command("which dnf>/dev/null 2>&1")     then execute_shell_command("sudo dnf install -y SDL2-devel SDL2_ttf-devel")
        else
            io.stderr:write("lpp: i can't fix this for you, fix it yourself.\n")
            return false
        end
    end
    return true
end

local function install_cross_sdl2_or_fail()
    if execute_shell_command("dpkg -s libsdl2-mingw-dev>/dev/null 2>&1") then return true end
    io.stderr:write("lpp: cross-sdl2 is missing, i am trying to fix it...\n")
    if execute_shell_command("sudo apt-get install -y libsdl2-dev libsdl2-ttf-dev gcc-mingw-w64-x86_64 2>/dev/null") then
        return true
    end
    io.stderr:write("lpp: i am useless.\n")
    io.stderr:write("     try: sudo apt install libsdl2-mingw-dev libsdl2-ttf-mingw-dev\n")
    return false
end

-- ── hardcoded lies ────────────────────────────────────────────────────────────
local known_c_trash = {
    ["std"]     = { cfile="stdlib.c",  sdl=false },
    ["gamelib"] = { cfile="gamelib.c", sdl=true  },
}

-- ── argument disaster ─────────────────────────────────────────────────────────
local input_file_to_process = nil
local output_bin_name       = nil
local run_it_after_maybe    = false
local target_platform       = nil
local lpp_verbose           = false

do
    local argv = arg or {}
    local i = 1
    while i <= #argv do
        if argv[i] == "-o" then
            if not argv[i+1] then error("-o requires a filename") end
            output_bin_name = argv[i+1]; i = i+2
        elseif argv[i] == "--target" then
            if not argv[i+1] then error("--target requires linux or windows") end
            target_platform = argv[i+1]; i = i+2
        elseif argv[i] == "--run" or argv[i] == "-r" then run_it_after_maybe = true; i = i+1
        elseif argv[i] == "--verbose" or argv[i] == "-v" then lpp_verbose = true; i = i+1
        elseif argv[i] == "--version" then print("lpp 0.4.0"); os.exit(0)
        elseif argv[i] == "--license" then
            print("MIT License\nCopyright (c) 2026 yeicebear/icebearunreal\n(full text: run with --license-full)")
            os.exit(0)
        elseif argv[i] == "--help" then
            print("lpp — Lua++ (made by a fool)")
            print("usage:  lpp <file.lpp> [flags]")
            print("")
            print("  -o <name>         output binary name")
            print("  --target <t>      target platform: linux or windows")
            print("                    linux   = native ELF (default on linux/mac)")
            print("                    windows = cross-compile .exe (linux/mac host)")
            print("                    on windows host, always produces .exe")
            print("  --run             compile then run (native target only)")
            print("  --version         print version")
            print("  --verbose / -v    print every step (what files, what commands)")
            print("  --help            this text")
            print("")
            print("cross-compile to windows from linux:")
            print("  sudo apt install gcc-mingw-w64-x86_64")
            print("  lpp mygame.lpp --target windows -o mygame")
            print("  → produces mygame.exe, no MSYS2 needed on the target machine")
            print("")
            print("stdlib:")
            print("  linkto \"std\"      print, input, rand, sleep, time")
            print("  linkto \"gamelib\"  sdl2 canvas (requires sdl2 installed)")
            os.exit(0)
        else
            input_file_to_process = argv[i]; i = i+1
        end
    end
end


    if lpp_verbose then
        io.stderr:write("lpp verbose: #arg=" .. tostring(#(arg or {})) .. "\n")
        for k,v in pairs(arg or {}) do
            io.stderr:write("  arg[" .. tostring(k) .. "] = " .. tostring(v) .. "\n")
        end
    end
if not input_file_to_process then
    io.stderr:write("lpp: you forgot the file, genius.\n  usage: lpp <file.lpp> [-o out] [--target windows|linux] [--run]\n")
    os.exit(1)
end

if target_platform == nil then
    target_platform = lpp_host_windows_check and "windows" or "linux"
elseif target_platform ~= "linux" and target_platform ~= "windows" then
    io.stderr:write("lpp: i don't know what '"..target_platform.."' is.\n")
    os.exit(1)
end

local is_targeting_windows_now = (target_platform == "windows")
local is_a_cross_compile_nightmare = is_targeting_windows_now and not lpp_host_windows_check

if not output_bin_name then
    output_bin_name = is_targeting_windows_now and "a.exe" or "a.out"
end

if is_targeting_windows_now and not output_bin_name:match("%.[^/\\]+$") then
    output_bin_name = output_bin_name..".exe"
end

-- ── the main spaghetti pipeline ───────────────────────────────────────────────
local ok, err = pcall(function()

    local fh = io.open(input_file_to_process,"r")
    if not fh then error("i couldn't even open '"..input_file_to_process.."'") end
    local src = fh:read("*all"); fh:close()

    lpp_log("parsing " .. input_file_to_process)
    local ast_blob = lpp_parser_doer(lpp_lexer_doer(src))

    local function blend_lpp_files_into_disaster(ast, path)
        local f = io.open(path,"r")
        if not f then error("linkto: can't open file at '"..path.."'") end
        local src2 = f:read("*all"); f:close()
        local ast2 = lpp_parser_doer(lpp_lexer_doer(src2))
        for i=1,#ast2.funcs   do ast.funcs[#ast.funcs+1]   = ast2.funcs[i]   end
        for i=1,#ast2.externs do ast.externs[#ast.externs+1] = ast2.externs[i] end
        for i=1,#ast2.links   do
            if not ast2.links[i].islpp then
                ast.links[#ast.links+1] = ast2.links[i]
            end
        end
    end

    local lpp_sep  = lpp_host_windows_check and "\\" or "/"
    local lpp_indir = input_file_to_process:match("^(.*)[/\\]") or "."
    for i=1,#ast_blob.links do
        local lk = ast_blob.links[i]
        if lk.islpp then
            local path = lk.libname
            if not path:match("^[/\\]") and not path:match("^%a:") then
                path = lpp_indir..lpp_sep..path
            end
            blend_lpp_files_into_disaster(ast_blob, path)
        end
    end

    lpp_analyzer_doer(ast_blob)
    lpp_log("running codegen")
    local ssa_output = lpp_codegen_doer(ast_blob)

    local ssa_file_path = input_file_to_process..".ssa"
    local asm_file_path = input_file_to_process..".s"

    local sf = io.open(ssa_file_path,"w"); sf:write(ssa_output); sf:close()

    local qbe_executable = lpp_host_windows_check and "qbe.exe" or "qbe"
    local qbe_invocation = string.format('%s -o "%s" "%s"', qbe_executable, asm_file_path, ssa_file_path)
    lpp_log("running qbe: " .. qbe_invocation)
    local qbe_vomit, qbe_was_good = capture_shell_vomit(qbe_invocation)
    if not qbe_was_good then error("qbe failed, obviously:\n"..qbe_vomit) end

    if is_targeting_windows_now then
        lobotomize_asm_for_windows(asm_file_path)
    end

    local c_files_list  = {}
    local compiler_flags = {}
    local needs_sdl_garbage = false

    for i=1,#ast_blob.links do
        local lk = ast_blob.links[i]
        if not lk.islpp then
            local lib = known_c_trash[lk.libname]
            if lib then
                local path = look_for_file_in_disaster(lib.cfile)
                if path then
                    c_files_list[#c_files_list+1] = '"'..path..'"'
                else
                    io.stderr:write("lpp: warning: can't find "..lib.cfile..", good luck\n")
                end
                if lib.sdl then needs_sdl_garbage = true end
            else
                io.stderr:write("lpp: warning: unknown library \""..lk.libname.."\", ignoring.\n")
            end
        end
    end

    if needs_sdl_garbage then
        if is_a_cross_compile_nightmare then
            if not install_cross_sdl2_or_fail() then
                error("cross-sdl2 not available, try harder.")
            end
            compiler_flags[#compiler_flags+1] = "-lSDL2 -lSDL2_ttf -lm"
            compiler_flags[#compiler_flags+1] = "-I/usr/x86_64-w64-mingw32/include"
        elseif is_targeting_windows_now then
            if not execute_shell_command("where SDL2.dll>nul 2>&1") then
                io.stderr:write("lpp: sdl2 not found.\n")
                io.stderr:write("     pacman -S mingw-w64-x86_64-SDL2 mingw-w64-x86_64-SDL2_ttf\n")
                error("sdl2 missing, as usual")
            end
            compiler_flags[#compiler_flags+1] = "-lSDL2 -lSDL2_ttf -lm"
        else
            if not install_sdl2_or_cry() then error("sdl2 not available, i am sad") end
            compiler_flags[#compiler_flags+1] = "$(pkg-config --libs sdl2 SDL2_ttf) -lm"
        end
    end

    local temp_wrapper_path
    if lpp_host_windows_check then
        local td = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
        temp_wrapper_path = td.."\\lpp_wrap_"..os.time().."_"..math.random(10000,99999)..".c"
    else
        temp_wrapper_path = "/tmp/lpp_wrap_"..os.time().."_"..math.random(10000,99999)..".c"
    end
    local wf = io.open(temp_wrapper_path,"w")
    if not wf then error("i couldn't write the temp file: "..temp_wrapper_path) end
    wf:write("extern int lang_main();\nint main(){return lang_main();}\n")
    wf:close()

    local compiler_to_use
    if is_a_cross_compile_nightmare then
        compiler_to_use = "x86_64-w64-mingw32-gcc"
    elseif lpp_host_windows_check then
        compiler_to_use = "gcc"
    else
        compiler_to_use = "cc"
    end

    local win_linker_flags = is_targeting_windows_now
        and "-lkernel32 -static-libgcc -Wl,-Bstatic -lmingwex -Wl,-Bdynamic"
        or ""

    local full_compiler_cmd = string.format('%s "%s" "%s" %s -o "%s" %s %s',
        compiler_to_use,
        asm_file_path,
        temp_wrapper_path,
        table.concat(c_files_list," "),
        output_bin_name,
        table.concat(compiler_flags," "),
        win_linker_flags)

    lpp_log("running compiler: " .. full_compiler_cmd)
    local compile_vomit, compile_was_good = capture_shell_vomit(full_compiler_cmd)
    if not compile_was_good then
        error("compiler gave up:\n"..compile_vomit.."\ncmd: "..full_compiler_cmd)
    end

    lpp_log("cleaning up " .. temp_wrapper_path)
    os.remove(temp_wrapper_path)

    if is_a_cross_compile_nightmare then
        io.stderr:write("lpp: built "..output_bin_name.." (windows .exe, cross-compiled)\n")
    end

    if run_it_after_maybe then
            if is_targeting_windows_now and not lpp_host_windows_check then
                io.stderr:write("lpp: --run ignored because i can't run windows things here\n")
            elseif lpp_host_windows_check then
                execute_shell_command('"'..output_bin_name..'"')
            else
                local cmd = output_bin_name
                if not cmd:match("^/") then
                    cmd = "./" .. cmd
                end
                execute_shell_command(cmd)
            end
        end

end)

if not ok then
    io.stderr:write("lpp: "..tostring(err).."\n")
    os.exit(1)
end