.POSIX:
PREFIX   ?= /usr/local
BINDIR   ?= $(PREFIX)/bin
PONYC    ?= ponyc
RM       ?= rm -f
RMDIR    ?= rm -rf
MKDIR    ?= mkdir -p
INSTALL  ?= install

BIN      = cu-chulainn

all: $(BIN)

$(BIN):
	$(PONYC) --bin-name $(BIN) --pic -p /usr/lib/gcc/x86_64-pc-linux-gnu/15.2.1 -o . src/

public/index.html: public
	echo '<h1>It works!</h1>' > $@

public:
	$(MKDIR) $@

clean:
	$(RM) $(BIN) $(BIN).o

distclean: clean
	$(RMDIR) public

install: $(BIN)
	$(MKDIR) $(DESTDIR)$(BINDIR)
	$(INSTALL) $(BIN) $(DESTDIR)$(BINDIR)/$(BIN)

uninstall:
	$(RM) $(DESTDIR)$(BINDIR)/$(BIN)

.PHONY: all clean distclean install uninstall