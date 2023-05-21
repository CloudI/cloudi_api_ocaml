#-*-Mode:make;coding:utf-8;tab-width:4;c-basic-offset:4-*-
# ex: set ft=make fenc=utf-8 sts=4 ts=4 sw=4 noet nomod:

OCAMLC ?= ocamlc
OCAMLOPT ?= ocamlopt
OCAMLDEP ?= ocamldep
OCAMLMKLIB ?= ocamlmklib
OCAMLDOC ?= ocamldoc
OCAMLFLAGS = -safe-string -w @A
STDLIBDIR = $(shell $(OCAMLC) -where)
OCAMLDEPS_ZARITH = \
    big_int_Z.cmi \
    big_int_Z.cmx \
    libzarith.a \
    q.cmi \
    q.cmx \
    zarith.a \
    zarith.cma \
    zarith.cmxa \
    zarith_top.cma \
    zarith_top.cmi \
    zarith_version.cmi \
    zarith_version.cmx \
    z.cmi \
    z.cmx

all: \
     cloudi.cmxa \
     cloudi.cma

cloudi.cmxa: \
             dependency_zarith \
             erlang.cmi \
             cloudi.cmi \
             erlang.cmx \
             cloudi.cmx
	$(OCAMLOPT) $(OCAMLFLAGS) -a erlang.cmx cloudi.cmx -o $@

cloudi.cma: \
            dependency_zarith \
            erlang.cmi \
            cloudi.cmi \
            erlang.cmo \
            cloudi.cmo
	$(OCAMLC) $(OCAMLFLAGS) -a erlang.cmo cloudi.cmo -o $@

dependency_zarith:
	(cd external/zarith-1.12 && \
     ./configure && \
     $(MAKE) && \
     cp $(OCAMLDEPS_ZARITH) ../..)
	touch $@

doc: \
     dependency_zarith \
     erlang.cmi \
     cloudi.cmi
	mkdir -p doc
	$(OCAMLDOC) -verbose -d doc $(OCAMLFLAGS) -html *.ml *.mli

clean:
	cd external/zarith-1.12 && $(MAKE) clean || exit 0
	rm -f *.cmi *.cmx *.cmo *.o cloudi.cmxa cloudi.cma cloudi.a \
          dependency_zarith $(OCAMLDEPS_ZARITH)

%.cmi: %.mli
	$(OCAMLC) $(OCAMLFLAGS) -o $@ -c $<

%.cmx: %.ml
	$(OCAMLOPT) $(OCAMLFLAGS) -o $@ -c $<

%.cmo: %.ml
	$(OCAMLC) $(OCAMLFLAGS) -o $@ -c $<

