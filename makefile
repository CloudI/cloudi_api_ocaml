#-*-Mode:make;coding:utf-8;tab-width:4;c-basic-offset:4-*-
# ex: set ft=make fenc=utf-8 sts=4 ts=4 sw=4 noet nomod:

OCAMLC ?= ocamlc
OCAMLOPT ?= ocamlopt
OCAMLDEP ?= ocamldep
OCAMLMKLIB ?= ocamlmklib
OCAMLDOC ?= ocamldoc
OCAMLFLAGS = -safe-string -w @A
STDLIBDIR = $(shell $(OCAMLC) -where)
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
    nums.cmxa \
    nums.cma

all: \
     cloudi.cmxa \
     cloudi.cma

cloudi.cmxa: \
             dependency_num \
             erlang.cmi \
             cloudi.cmi \
             erlang.cmx \
             cloudi.cmx
	$(OCAMLOPT) $(OCAMLFLAGS) -a erlang.cmx cloudi.cmx -o $@

cloudi.cma: \
            dependency_num \
            erlang.cmi \
            cloudi.cmi \
            erlang.cmo \
            cloudi.cmo
	$(OCAMLC) $(OCAMLFLAGS) -a erlang.cmo cloudi.cmo -o $@

dependency_num:
	test -f $(STDLIBDIR)/nums.cmxa || \
    (cd external/num-1.1/src && \
     $(MAKE) OCAMLC="$(OCAMLC)" \
             OCAMLOPT="$(OCAMLOPT)" \
             OCAMLDEP="$(OCAMLDEP)" \
             OCAMLMKLIB="$(OCAMLMKLIB)" \
             nums.cmxa nums.cma libnums.a && \
     cp $(OCAMLDEPS_NUM) ../../..)
	touch $@

doc: \
     dependency_num \
     erlang.cmi \
     cloudi.cmi
	mkdir -p doc
	$(OCAMLDOC) -verbose -d doc $(OCAMLFLAGS) -html *.ml *.mli

clean:
	rm -f *.cmi *.cmx *.cmo *.o cloudi.cmxa cloudi.cma cloudi.a \
          dependency_num $(OCAMLDEPS_NUM)
	cd external/num-1.1/src && $(MAKE) clean

%.cmi: %.mli
	$(OCAMLC) $(OCAMLFLAGS) -o $@ -c $<

%.cmx: %.ml
	$(OCAMLOPT) $(OCAMLFLAGS) -o $@ -c $<

%.cmo: %.ml
	$(OCAMLC) $(OCAMLFLAGS) -o $@ -c $<

