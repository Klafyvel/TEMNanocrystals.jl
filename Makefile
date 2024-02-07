JULIA=$(shell which julia)
EXECUTABLE="build/bin/TEMNanocrystals"

build: build.tar.xz
build.tar.xz: $(EXECUTABLE)
	tar -cvJf build.tar.xz build/*
$(EXECUTABLE): src/TEMNanocrystals.jl
	$(JULIA) make_sysimage.jl
clean-build:
	rm -rf build/
	rm -rf build.tar.xz

clean: clean-build

.PHONY: build clean clean-build
