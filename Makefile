.PHONY: build test fmt clean sizes

build:
	forge build

test:
	forge test -vvv

fmt:
	forge fmt

sizes:
	forge build --sizes

clean:
	rm -rf out cache broadcast


