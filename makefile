#-*-Mode:make;coding:utf-8;tab-width:4;c-basic-offset:4-*-
# ex: set ft=make fenc=utf-8 sts=4 ts=4 sw=4 noet nomod:

OCAMLC ?= ocamlc
OCAMLOPT ?= ocamlopt
OCAMLDEP ?= ocamldep
OCAMLMKLIB ?= ocamlmklib
OCAMLDOC ?= ocamldoc
OCAMLFLAGS = -safe-string -w @A
OCAMLDEPS_NUM = \
    arith_flags.cmi \
    arith_flags.cmx \
    arith_status.cmi \
    arith_status.cmx \
    big_int.cmi \
    big_int.cmx \
    int_misc.cmi \
    int_misc.cmx \
    nat.cmi \
    nat.cmx \
    num.cmi \
    num.cmx \
    ratio.cmi \
    ratio.cmx \
    libnums.a \
    nums.a \
    nums.cmxa

all: \
     cloudi.cmxa

cloudi.cmxa: nums.cmxa \
             erlang.cmi \
             cloudi.cmi \
             erlang.cmx \
             cloudi.cmx
	$(OCAMLOPT) $(OCAMLFLAGS) -a erlang.cmx cloudi.cmx -o $@

nums.cmxa:
	cd external/num-1.1/src && \
    $(MAKE) OCAMLC="$(OCAMLC)" \
            OCAMLOPT="$(OCAMLOPT)" \
            OCAMLDEP="$(OCAMLDEP)" \
            OCAMLMKLIB="$(OCAMLMKLIB)" \
            nums.cmxa libnums.a && \
    cp $(OCAMLDEPS_NUM) ../../..

doc: \
     erlang.cmi \
     cloudi.cmi
	mkdir -p doc
	$(OCAMLDOC) -verbose -d doc $(OCAMLFLAGS) -html *.ml *.mli

clean:
	rm -f *.cmi *.cmx *.o cloudi.cmxa cloudi.a $(OCAMLDEPS_NUM)
	cd external/num-1.1/src && $(MAKE) clean

%.cmi: %.mli
	$(OCAMLC) $(OCAMLFLAGS) -o $@ -c $<

%.cmx: %.ml
	$(OCAMLOPT) $(OCAMLFLAGS) -o $@ -c $<

