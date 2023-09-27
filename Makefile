SHELL = /bin/sh

all: docs check-sh check-pl

docs: $(patsubst %.sh,%.md,$(shell echo *.sh))

%.md: %.sh
	shdoc < $< > $@

check-sh: *.sh
	shellcheck -x $?

check-pl: *.pl
	perlcritic $?

clean:
	rm -f [a-z]*.md
