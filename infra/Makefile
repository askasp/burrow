.PHONY: help check apply deploy lint

# Limit a run to one slice: make check TAGS=burrow
TAGS ?=
TAGS_ARG = $(if $(TAGS),--tags $(TAGS),)

help:
	@echo "make check    dry run, showing every change that would be made"
	@echo "make apply    set up or converge every machine"
	@echo "make deploy   only Burrow: check out burrow_version, build, restart"
	@echo "make lint     syntax check"
	@echo
	@echo "Add TAGS=<tag> to limit check or apply. Tags: base docker sandbox burrow tunnel backup"

check:
	ansible-playbook site.yml $(TAGS_ARG) --check --diff

apply:
	ansible-playbook site.yml $(TAGS_ARG)

deploy:
	ansible-playbook site.yml --tags burrow

lint:
	ansible-playbook site.yml --syntax-check
