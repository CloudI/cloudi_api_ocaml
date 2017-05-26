#-*-Mode:make;coding:utf-8;tab-width:4;c-basic-offset:4-*-
# ex: set ft=make fenc=utf-8 sts=4 ts=4 sw=4 noet nomod:

OCAMLFLAGS=-safe-string -w @A

all: \
     erlang.cmi \
     cloudi.cmi \
     erlang.cmx \
     cloudi.cmx

doc: \
     erlang.cmi \
     cloudi.cmi
	mkdir -p doc
	ocamldoc -verbose -d doc $(OCAMLFLAGS) -html *.ml *.mli

clean:
	rm -f *.cmi *.cmx *.o 

%.cmi: %.mli
	ocamlc $(OCAMLFLAGS) -o $@ -c $<

%.cmx: %.ml
	ocamlopt $(OCAMLFLAGS) -o $@ -c $<

