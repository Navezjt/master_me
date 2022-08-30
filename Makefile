#!/usr/bin/make -f

# define project version
VERSION_MAJOR = 0
VERSION_MINOR = 0
VERSION_MICRO = 1

# include dpf base makefile definitions
include dpf/Makefile.base.mk

# default build target
all: master_me

# ---------------------------------------------------------------------------------------------------------------------
# clean target, removes any build artifacts

clean:
	rm -rf bin build
	rm -rf dpf/build
	rm -f dpf-widgets/opengl/*.d
	rm -f dpf-widgets/opengl/*.o

# ---------------------------------------------------------------------------------------------------------------------
# faustpp target, building it ourselves if not available from the system

ifeq ($(shell command -v faustpp 1>/dev/null && echo true),true)
FAUSTPP_TARGET =
FAUSTPP_EXEC = faustpp
else
FAUSTPP_TARGET = build/faustpp/faustpp$(APP_EXT)
FAUSTPP_EXEC = $(CURDIR)/$(FAUSTPP_TARGET)
endif

# never rebuild faustpp
ifeq ($(wildcard build/faustpp/faustpp$(APP_EXT)),)
faustpp: $(FAUSTPP_TARGET)
.PHONY: faustpp
else
faustpp:
endif

# ---------------------------------------------------------------------------------------------------------------------
# bench target, for testing

BENCH_CMD = ./bench/faustbench -notrace $(CURDIR)/soundsgood.dsp

BENCH_FLAGS  = $(BUILD_CXX_FLAGS)
BENCH_FLAGS += -Wno-overloaded-virtual -Wno-unused-function -Wno-unused-parameter
BENCH_FLAGS += -I$(shell faust --includedir) -Ibench/soundsgood -flto -DALL_TESTS
BENCH_FLAGS += $(LINK_FLAGS)

BENCH_TARGETS = all none Ofast best prefetchloop-arrays single-precision tree-vectorize unroll-loops unsafe-loops

bench: $(BENCH_TARGETS:%=bench/soundsgood/bench.%$(APP_EXT))

bench/soundsgood/bench.all$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) -Ofast -fomit-frame-pointer -fprefetch-loop-arrays -fsingle-precision-constant -ftree-vectorize -funroll-loops -funsafe-loop-optimizations $< -o $@

bench/soundsgood/bench.none$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) $< -o $@

bench/soundsgood/bench.Ofast$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) -Ofast $< -o $@

bench/soundsgood/bench.best$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) -fprefetch-loop-arrays -fsingle-precision-constant -funroll-loops $< -o $@

bench/soundsgood/bench.prefetchloop-arrays$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) -fprefetch-loop-arrays $< -o $@

bench/soundsgood/bench.single-precision$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) -fsingle-precision-constant $< -o $@

bench/soundsgood/bench.tree-vectorize$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) -ftree-vectorize $< -o $@

bench/soundsgood/bench.unroll-loops$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) -funroll-loops $< -o $@

bench/soundsgood/bench.unsafe-loops$(APP_EXT): bench/soundsgood/faustbench.cpp
	$(CXX) $(BENCH_FLAGS) -fprefetch-loop-arrays -funroll-loops -funsafe-loop-optimizations $< -o $@

bench/soundsgood/faustbench.cpp:
	$(BENCH_CMD) -source

.PHONY: bench

# ---------------------------------------------------------------------------------------------------------------------
# dgl target, building the dpf little graphics library

DPF_EXTRA_ARGS  = DGL_NAMESPACE=MasterMeDGL
DPF_EXTRA_ARGS += FILE_BROWSER_DISABLED=true
DPF_EXTRA_ARGS += NVG_FONT_TEXTURE_FLAGS=NVG_IMAGE_NEAREST

dgl:
	$(MAKE) -C dpf/dgl opengl $(DPF_EXTRA_ARGS)

# ---------------------------------------------------------------------------------------------------------------------
# list of plugin source code files to generate, converted from faust dsp files

PLUGIN_TEMPLATE_FILES   = $(subst template/,,$(wildcard template/*.*))
PLUGIN_GENERATED_FILES  = $(foreach f,$(PLUGIN_TEMPLATE_FILES),build/master_me/$(f))
PLUGIN_GENERATED_FILES += bin/master_me.lv2/manifest.ttl
PLUGIN_GENERATED_FILES += bin/master_me.lv2/plugin.ttl
PLUGIN_GENERATED_FILES += bin/master_me.lv2/ui.ttl
PLUGIN_GENERATED_FILES += build/BuildInfo1.hpp
PLUGIN_GENERATED_FILES += build/BuildInfo2.hpp
PLUGIN_GENERATED_FILES += build/Logo.hpp

gen: $(PLUGIN_GENERATED_FILES)

# ---------------------------------------------------------------------------------------------------------------------
# master_me target, for actual building the plugin after its source code has been generated

master_me: $(PLUGIN_GENERATED_FILES) dgl
	$(MAKE) -C plugin

# ---------------------------------------------------------------------------------------------------------------------
# rules for faust dsp to plugin code conversion

FAUSTPP_ARGS = \
	-Dbinary_name="master_me" \
	-Dbrand="Klaus Scheuermann" \
	-Dhomepage="https://4ohm.de/" \
	-Dlabel="master_me" \
	-Dlicense="GPLv3+" \
	-Dlicenseurl="http://spdx.org/licenses/GPL-3.0-or-later.html" \
	-Dlibext="$(LIB_EXT)" \
	-Dlv2uri="https://github.com/trummerschlunk/master_me" \
	-Dversion_major=$(VERSION_MAJOR) \
	-Dversion_minor=$(VERSION_MINOR) \
	-Dversion_micro=$(VERSION_MICRO)

ifeq ($(MACOS),true)
FAUSTPP_ARGS += -Duitype=Cocoa
else ifeq ($(WINDOWS),true)
FAUSTPP_ARGS += -Duitype=HWND
else ifeq ($(HAVE_DGL),true)
FAUSTPP_ARGS += -Duitype=X11
endif

FAUSTPP_ARGS += -X-scal
# FAUSTPP_ARGS += -X-vec -X-fun -X-lv -X0 -X-vs -X8

bin/master_me.lv2/%: soundsgood.dsp template/LV2/% faustpp
	mkdir -p bin/master_me.lv2
	$(FAUSTPP_EXEC) $(FAUSTPP_ARGS) -a template/LV2/$* $< -o $@

build/master_me/%: soundsgood.dsp template/% faustpp
	mkdir -p build/master_me
	$(FAUSTPP_EXEC) $(FAUSTPP_ARGS) -a template/$* $< -o $@

# only generated once
build/BuildInfo1.hpp:
	mkdir -p build
	echo 'constexpr const char* const kBuildInfoString1 = ""' > $@
	echo '"A plugin by Klaus Scheuermann, made with Faust and DPF\\n"' >> $@
	echo '"DSP: Klaus Scheuermann, magnetophon, x42, jkbd\\n"' >> $@
	echo '"GUI, Plugin: falkTX\\n"' >> $@
	echo '"Supported by the Prototype Fund / German Federal Ministry of Education and Research"' >> $@
	echo ';' >> $@

# regenerated on every possible change
build/BuildInfo2.hpp: soundsgood.dsp plugin/* template/* template/LV2/*
	mkdir -p build
	echo 'constexpr const char* const kBuildInfoString2 = ""' > $@
	echo '"Built using `$(shell git branch --show-current)` branch with commit:\\n$(shell git log -n 1 --decorate=no --pretty=oneline --abbrev-commit)"' >> $@
	echo ';' >> $@

build/Logo.hpp: img/logo/master_me_white.png img/logo/master_me_white@2x.png
	mkdir -p build
	./dpf/utils/res2c.py Logo img/logo/ build/

# ---------------------------------------------------------------------------------------------------------------------
# rules for custom faustpp build

CMAKE_ARGS  = -G 'Unix Makefiles'
ifeq ($(DEBUG),true)
CMAKE_ARGS += -DCMAKE_BUILD_TYPE=Debug
else
CMAKE_ARGS += -DCMAKE_BUILD_TYPE=Release
endif
ifeq ($(WINDOWS),true)
CMAKE_ARGS += -DCMAKE_SYSTEM_NAME=Windows
endif

faustpp/CMakeLists.txt:
	git clone --recursive https://github.com/falkTX/faustpp.git --depth=1 -b use-internal=boost

build/faustpp/Makefile: faustpp/CMakeLists.txt
	cmake -Bbuild/faustpp -Sfaustpp -DFAUSTPP_USE_INTERNAL_BOOST=ON $(CMAKE_ARGS)

build/faustpp/faustpp$(APP_EXT): build/faustpp/Makefile
	$(MAKE) -C build/faustpp

# ---------------------------------------------------------------------------------------------------------------------
