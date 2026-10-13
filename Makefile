.PHONY: app run test clean release release-local
app:
	./scripts/bundle.sh
run: app
	open build/Camdeck.app
test:
	swift test
clean:
	rm -rf .build build

release:
	./scripts/release.sh $(VERSION)

release-local:
	./scripts/release-local.sh $(VERSION)
