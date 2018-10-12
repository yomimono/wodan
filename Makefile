OPAMS := wodan.opam wodan-irmin.opam wodan-unix.opam $(wildcard vendor/*/*.opam)
LOCKED_OPAMS := $(patsubst %.opam, %.opam.locked, $(OPAMS))
LOCAL_LOCKED_OPAMS := $(wildcard ./*.opam.locked)

build:
	dune build
	ln -Tsf _build/default/src/wodan-unix/wodanc.exe wodanc

deps:
	git submodule update --init
	opam install -y dune opam-lock lwt_ppx
	dune external-lib-deps --missing @@default

sync:
	git submodule sync
	git submodule update --init

%.opam.locked: %.opam
	opam lock $^
	# Workaround https://github.com/AltGr/opam-lock/issues/2
	sed -i '/{= "dev"}/d; /"ocaml"/d; /"ocaml-src"/d; /"ocaml-variants"/d; /"seq"/d;' $@
	gawk -i inplace '/pin-depends/{exit}1' $@
	cp -T $@ $(notdir $@)

locked:
	git submodule update --init
	opam switch create --switch=.
	opam install -y --deps-only --switch=. $(LOCAL_LOCKED_OPAMS)

locked-travis:
	git submodule update --init
	opam install -y --deps-only $(LOCAL_LOCKED_OPAMS)

update-lock: $(LOCKED_OPAMS)

fuzz:
	dune build src/wodan-unix/wodanc.exe
	afl-fuzz -i afl/input -o afl/output -- \
		_build/default/src/wodan-unix/wodanc.exe fuzz @@

test:
	dune runtest irmin-tests

install:
	dune install

uninstall:
	dune uninstall

clean:
	rm -rf _build _opam

.PHONY: build deps locked locked-travis update-lock fuzz test install uninstall clean
