.PHONY: test privacy-check verify

test:
	sui move test

privacy-check:
	./scripts/check-witness-privacy.sh

verify: test privacy-check
