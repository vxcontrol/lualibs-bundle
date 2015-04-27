#!/bin/bash
shopt -s nullglob

describe() {
	echo " Compile and link together LuaJIT, Lua modules, Lua/C modules, C libraries,"
	echo " and other static assets into a single fat executable."
	echo
	echo " Tested with mingw, gcc and clang on Windows, Linux and OSX respectively."
	echo " Written by Cosmin Apreutesei. Public Domain."
}

say() { [ "$VERBOSE" ] && echo "$@"; }
verbose() { say "$@"; "$@"; }
die() { echo "$@" >&2; exit 1; }

# defaults -------------------------------------------------------------------

BLUA_PREFIX=Blua_
BBIN_PREFIX=Bbin_

# note: only the mingw linker is smart to ommit dlibs that are not used.
DLIBS_mingw="gdi32 msimg32 opengl32 winmm ws2_32"
DLIBS_linux=
DLIBS_osx=
FRAMEWORKS="ApplicationServices" # for OSX

APREFIX_mingw=
APREFIX_linux=lib
APREFIX_osx=lib

ALIBS="luajit"
MODULES="bundle_loader"
ICON=csrc/bundle/luajit2.ico

IGNORE_ODIR=
COMPRESS_EXE=
NOCONSOLE=
VERBOSE=

# list modules and libs ------------------------------------------------------

# usage: P=<platform> $0 basedir/file.lua|.dasl -> file.lua|.dasl
# note: skips test and demo modules, and other platforms modules.
lua_module() {
	local f=$1
	local ext=${f##*.}
	[ "$ext" != lua -a "$ext" != dasl ] && return
	[ "${f%_test.lua}" != $f ] && return
	[ "${f%_demo.lua}" != $f ] && return
	[ "${f#bin/}" != $f -a "${f#bin/$P/}" = $f ] && return
	echo $f
}

# usage: P=<platform> $0 [dir] -> module1.lua|.dasl ...
# note: skips looking in special dirs.
lua_modules() {
	for f in $1*; do
		if [ -d $f ]; then
			[ "${f:0:1}" != "." \
				-a "${f:0:4}" != csrc \
				-a "${f:0:5}" != media \
			] && \
				lua_modules $f/
		else
			lua_module $f
		fi
	done
}

# usage: P=<platform> $0 -> lib1 ...
alibs() {
	(cd bin/$P &&
		for f in *.a; do
			local m=${f%*.*}   # libz.* -> libz
			echo ${m#$APREFIX} # libz -> z
		done)
}

# compiling ------------------------------------------------------------------

# usage: CFLAGS=... f=file.* o=file.o sym=symbolname $0 CFLAGS... -> file.o
compile_bin_file() {
	local sec=.rodata
	[ $OS = osx ] && sec="__TEXT,__const"
	# symbols must be prefixed with an underscore on OSX
	local sym=$sym; [ $OS = osx ] && sym=_$sym
	# insert a shim to avoid 'address not in any section file' error in OSX/i386
	local shim; [ $P = osx32 ] && shim=".byte 0"
	echo "\
		.section $sec
		.global $sym
		$sym:
			.int label_2 - label_1
		label_1:
			.incbin \"$f\"
		label_2:
			$shim
	" | gcc -c -xassembler - -o $o $CFLAGS "$@"
}

# usage: CFLAGS=... f=file.c o=file.o $0 CFLAGS... -> file.o
compile_c_module() {
	gcc -c -xc $f -o $o $CFLAGS "$@"
}

# usage: [ filename=file.lua ] f=file.lua|- o=file.o $0 CFLAGS... -> file.o
compile_lua_module() {
	./luajit -b -t raw -g $f $o.luac
	local sym=$filename
	[ "$sym" ] || sym=$f
	sym=${sym#bin/$P/lua/}       # bin/<platform>/lua/a.lua -> a.lua
	sym=${sym%.lua}              # a.lua -> a
	sym=${sym%.dasl}             # a.dasl -> a
	sym=${sym//[\-\.\/\\]/_}     # a-b.c/d -> a_b_c_d
	sym=$BLUA_PREFIX$sym f=$o.luac compile_bin_file "$@"
}

# usage: f=file.dasl o=file.o $0 CFLAGS... -> file.o
compile_dasl_module() {
	./luajit dynasm.lua $f | filename=$f f=- compile_lua_module "$@"
}

# usage: f=file.* o=file.o $0 CFLAGS... -> file.o
compile_bin_module() {
	local sym=${f//[\-\.\/\\]/_}  # foo/bar-baz.ext -> foo_bar_baz_ext
	sym=$BBIN_PREFIX$sym compile_bin_file "$@"
}

sayt() { [ "$VERBOSE" ] && printf "  %-15s %s\n" "$1" "$2"; }

# usage: osuffix=suffix $0 file[.lua]|.c|.dasl|.* CFLAGS... -> file.o
compile_module() {
	local f=$1; shift

	# disambiguate between file `a.b` and Lua module `a.b`.
	[ -f $f ] || {
		local luaf=${f//\./\/}    # a.b -> a/b
		luaf=$luaf.lua            # a/b -> a/b.lua
		[ -f $luaf ] || die "File not found: $f (nor $luaf)"
		f=$luaf
	}

	# infer file type from file extension
	local x=${f##*.}             # a.ext -> ext
	[ $x = c -o $x = lua -o $x = dasl ] || x=bin

	local o=$ODIR/$f$osuffix.o   # a.ext -> $ODIR/a.ext.o

	# add the .o file to the list of files to be linked
	OFILES="$OFILES $o"

	# use the cached .o file if the source file hasn't changed, make-style.
	[ -z "$IGNORE_ODIR" -a -f $o -a $o -nt $f ] && return

	# or, compile the source file into the .o file
	sayt $x $f
	mkdir -p `dirname $o`
	f=$f o=$o compile_${x}_module "$@"
}

# usage: $0 file.c CFLAGS... -> file.o
compile_bundle_module() {
	local f=$1; shift
	compile_module csrc/bundle/$f -Icsrc/bundle -Icsrc/luajit/src/src "$@"
}

# usage: o=file.o s="res code..." $0
compile_resource() {
	OFILES="$OFILES $o"
	echo "$s" | windres -o $o
}

# add an icon file for the exe file and main window (Windows only)
# usage: $0 file.ico -> _icon.o
compile_icon() {
	[ $OS = mingw ] || return
	local f=$1; shift
	[ "$f" ] || return
	sayt icon $f
	o=$ODIR/_icon.o s="0  ICON  \"$f\"" compile_resource
}

# add a manifest file to enable the exe to use comctl 6.0
# usage: $0 file.manifest -> _manifest.o
compile_manifest() {
	[ $OS = mingw ] || return
	local f=$1; shift
	[ "$f" ] || return
	sayt manifest $f
	s="\
		#include \"winuser.h\"
		1 RT_MANIFEST $f
		" o=$ODIR/_manifest.o compile_resource
}

# usage: MODULES='mod1 ...' $0 -> $ODIR/*.o
compile_all() {
	say "Compiling modules..."

	# the dir where .o files are generated
	ODIR=.bundle-tmp/$P
	mkdir -p $ODIR || { echo "Cannot mkdir $ODIR"; exit 1; }

	# the compile_*() functions will add the names of all .o files to this var
	OFILES=

	# the icon has to be linked first, believe it!
	# so we compile it first so that it's added to $OFILES first.
	compile_icon "$ICON"
	compile_manifest "bin/mingw32/luajit.exe.manifest"

	# compile all the modules
	for m in $MODULES; do
		compile_module $m
	done

	# compile bundle.c which implements bundle_add_loaders() and bundle_main().
	local osuffix
	local copt
	[ "$MAIN" ] && {
		# bundle.c is a template: it compiles differently for each $MAIN,
		# so we make a different .o file for each unique value of $MAIN.
		osuffix=_$MAIN
		copt=-DBUNDLE_MAIN=$MAIN
	}
	osuffix=$osuffix compile_bundle_module bundle.c $copt

	# compile our custom luajit frontend which calls bundle_add_loaders()
	# and bundle_main() on startup.
	compile_bundle_module luajit.c
}

# linking --------------------------------------------------------------------

aopt() { for f in $1; do echo "bin/$P/$APREFIX$f.a"; done; }
lopt() { for f in $1; do echo "-l$f"; done; }
fopt() { for f in $1; do echo "-framework $f"; done; }

# usage: LDFLAGS=... P=platform ALIBS='lib1 ...' DLIBS='lib1 ...' \
#          EXE=exe_file NOCONSOLE=1 $0
link_mingw() {

	local mingw_lib_dir
	if [ $P = mingw32 ]; then
		mingw_lib_dir="$(dirname "$(which gcc)")/../lib"
	else
		mingw_lib_dir="$(dirname "$(which gcc)")/../x86_64-w64-mingw32/lib"
	fi

	# make a windows app or a console app
	local xopt; [ "$NOCONSOLE" ] && xopt=-mwindows

	verbose g++ $LDFLAGS $OFILES -o "$EXE" \
		-static -static-libgcc -static-libstdc++ \
		-Wl,--export-all-symbols \
		-Wl,--whole-archive `aopt "$ALIBS"` \
		-Wl,--no-whole-archive \
		"$mingw_lib_dir"/libmingw32.a \
		`lopt "$DLIBS"` $xopt
}

# usage: LDFLAGS=... P=platform ALIBS='lib1 ...' DLIBS='lib1 ...' EXE=exe_file
link_linux() {
	verbose g++ $LDFLAGS $OFILES -o "$EXE" \
		-static-libgcc -static-libstdc++ \
		-Wl,-E \
		-Lbin/$P \
		-pthread \
		-Wl,--whole-archive `aopt "$ALIBS"` \
		-Wl,--no-whole-archive -lm -ldl `lopt "$DLIBS"`
	chmod +x "$EXE"
}

# usage: LDFLAGS=... P=platform ALIBS='lib1 ...' DLIBS='lib1 ...' EXE=exe_file
link_osx() {
	# note: luajit needs these flags for OSX/x64, see http://luajit.org/install.html#embed
	local xopt; [ $P = osx64 ] && xopt="-pagezero_size 10000 -image_base 100000000"
	# note: using -stdlib=libstdc++ because in 10.9+, libc++ is the default.
	verbose g++ $LDFLAGS $OFILES -o "$EXE" \
		-mmacosx-version-min=10.6 \
		-stdlib=libstdc++ \
		-Lbin/$P \
		`lopt "$DLIBS"` \
		`fopt "$FRAMEWORKS"` \
		-Wl,-all_load `aopt "$ALIBS"` $xopt
	chmod +x "$EXE"
	install_name_tool -add_rpath @loader_path/ "$EXE"
}

link_all() {
	say "Linking $EXE..."
	link_$OS
}

compress_exe() {
	[ "$COMPRESS_EXE" ] || return
	say "Compressing $EXE..."
	which upx >/dev/null || { say "UPX not found."; return; }
	upx -qqq "$EXE"
}

# usage: P=platform MODULES='mod1 ...' ALIBS='lib1 ...' DLIBS='lib1 ...'
#         MAIN=module EXE=exe_file NOCONSOLE=1 ICON=icon COMPRESS_EXE=1 $0
bundle() {
	say "Bundle parameters:"
	say "  Platform:      " "$OS ($P)"
	say "  Modules:       " $MODULES
	say "  Static libs:   " $ALIBS
	say "  Dynamic libs:  " $DLIBS
	say "  Main module:   " $MAIN
	say "  Icon:          " $ICON
	compile_all
	link_all
	compress_exe
	say "Done."
}

# cmdline --------------------------------------------------------------------

usage() {
	echo
	describe
	echo
	echo " USAGE: $0 options..."
	echo
	echo "  -o  --output FILE                  Output executable (required)"
	echo
	echo "  -m  --modules \"FILE1 ...\"|--all|-- Lua (or other) modules to bundle [1]"
	echo "  -a  --alibs \"LIB1 ...\"|--all|--    Static libs to bundle            [2]"
	echo "  -d  --dlibs \"LIB1 ...\"|--          Dynamic libs to link against     [3]"
	[ $OS = osx ] && \
	echo "  -f  --frameworks \"FRM1 ...\"        Frameworks to link against       [4]"
	echo
	echo "  -M  --main MODULE                  Module to run on start-up"
	echo
	[ $OS = osx ] && \
	echo "  -m32                               Force 32bit platform"
	echo "  -z  --compress                     Compress the executable (needs UPX)"
	[ $OS = mingw ] && \
	echo "  -i  --icon FILE                    Set icon"
	[ $OS = mingw ] && \
	echo "  -w  --no-console                   Hide the terminal / console"
	echo
	echo "  -ll --list-lua-modules             List Lua modules"
	echo "  -la --list-alibs                   List static libs (.a files)"
	echo
	echo "  -C  --clean                        Ignore the object cache"
	echo
	echo "  -v  --verbose                      Be verbose"
	echo "  -h  --help                         Show this screen"
	echo
   echo " Passing -- clears the list of args for that option, including implicit args."
	echo
	echo " [1] .lua, .c and .dasl are compiled, other files are added as blobs."
	echo
	echo " [2] implicit static libs:           "$ALIBS
	echo " [3] implicit dynamic libs:          "$DLIBS
	[ $OS = osx ] && \
	echo " [4] implicit frameworks:            "$FRAMEWORKS
	echo
	exit
}

# usage: $0 [force_32bit]
set_platform() {

	# detect platform
	if [ "$OSTYPE" = msys ]; then
		[ "$1" -o ! -f "$SYSTEMROOT\SysWOW64\kernel32.dll" ] && \
			P=mingw32 || P=mingw64
	else
		local a
		[ "$1" -o "$(uname -m)" != x86_64 ] && a=32 || a=64
		[ "${OSTYPE#darwin}" != "$OSTYPE" ] && P=osx$a || P=linux$a
	fi

	# set platform-specific variables
	OS=${P%[0-9][0-9]}
	eval DLIBS=\$DLIBS_$OS
	eval APREFIX=\$APREFIX_$OS

	[ $P = osx32 ] && { CFLAGS="-arch i386";   LDFLAGS="-arch i386"; }
	[ $P = osx64 ] && { CFLAGS="-arch x86_64"; LDFLAGS="-arch x86_64"; }
}

parse_opts() {
	while [ "$1" ]; do
		local opt="$1"; shift
		case "$opt" in
			-o  | --output)
				EXE="$1"; shift;;
			-m  | --modules)
				[ "$1" = -- ] && MODULES= || \
					[ "$1" = --all ] && MODULES="$(lua_modules)" || \
					MODULES="$MODULES $1"
				shift
				;;
			-M  | --main)
				MAIN="$1"; shift;;
			-a  | --alibs)
				[ "$1" = -- ] && ALIBS= || \
					[ "$1" = --all ] && ALIBS="$(alibs)" || \
						ALIBS="$ALIBS $1"
				shift
				;;
			-d  | --dlibs)
				[ "$1" = -- ] && DLIBS= || DLIBS="$DLIBS $1"
				shift
				;;
			-f  | --frameworks)
				[ "$1" = -- ] && FRAMEWORKS= || FRAMEWORKS="$FRAMEWORKS $1"
				shift
				;;
			-ll | --list-lua-modules)
				lua_modules; exit;;
			-la | --list-alibs)
				alibs; exit;;
			-C  | --clean)
				IGNORE_ODIR=1;;
			-m32)
				set_platform m32;;
			-z  | --compress)
				COMPRESS_EXE=1;;
			-i  | --icon)
				ICON="$1"; shift;;
			-w  | --no-console)
				NOCONSOLE=1;;
			-h  | --help)
				usage;;
			-v | --verbose)
				VERBOSE=1;;
			*)
				echo "Invalid option: $opt"
				usage "$opt"
				;;
		esac
	done
	[ "$EXE" ] || usage
}

PWD0="$PWD"
cd "$(dirname "$0")" || die "Could not cd to the script's directory."
[ "$PWD" = "$PWD0" ] || die "Only run this script from it's directory."

set_platform
parse_opts "$@"
bundle
