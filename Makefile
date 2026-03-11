all:
	cd src && luastatic main.lua lexer.lua parser.lua analyze.lua codegen.lua ../lua-5.4.7/src/liblua.a && cd ..
	mv src/main ./lpp