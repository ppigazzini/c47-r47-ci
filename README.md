# c43 GitHub Actions Port Workspace

This repository contains the workflow code and maintainer documentation for
porting upstream c43 from GitLab CI to GitHub Actions.

The authoritative product source remains upstream c43 on GitLab:

- https://gitlab.com/rpncalculators/c43

This repository is not a fork of the product tree. The workflows here resolve
upstream `master` at runtime and then build and validate that upstream source
inside GitHub Actions.

## What Lives Here

- `.github/workflows/`
	- GitHub Actions workflows that operate on the authoritative upstream c43
		commit

## Implemented Workflows

- `.github/workflows/c43-clang.yml`
	- resolves the authoritative upstream c43 commit
	- runs Linux simulator tests via `make test`
	- runs Linux docs generation via `make docs`
	- builds the Linux simulator package with Clang 22 via `make dist_linux`
	- builds the macOS Apple Silicon simulator package with Apple Clang via
		`make dist_macos`
	- builds the Windows simulator package with MSYS2 CLANG64 via
		`make dist_windows`
	- copies upstream `COPYING` and writes a `SOURCE` provenance manifest into
		each simulator package artifact
	- uploads Linux, macOS, and Windows package artifacts plus per-job logs
- `.github/workflows/c43-gcc-ci.yml`
	- resolves the authoritative upstream c43 commit
	- runs Linux simulator tests via `make test`
	- runs Linux docs generation via `make docs`
	- builds the Linux simulator package with Ubuntu's built-in GCC via
		`make dist_linux`
	- builds the Windows simulator package with MSYS2 UCRT64 GCC via
		`make dist_windows`
	- copies upstream `COPYING` and writes a `SOURCE` provenance manifest into
		each simulator package artifact
	- uploads Linux and Windows package artifacts plus per-job logs
- `.github/workflows/c43-clang-analysis.yml`
	- installs LLVM and Clang 22 on Linux
	- runs a Clang 22 ASan plus UBSan simulator lane against upstream c43
	- runs a Linux Valgrind lane against Clang 22-built simulators
	- uploads analysis logs
- `.github/workflows/c43-gcc-analysis.yml`
	- uses Ubuntu's built-in GCC on Linux
	- runs a GCC ASan plus UBSan simulator lane against upstream c43
	- runs a Linux Valgrind lane against GCC-built simulators
	- uploads analysis logs

## Current Limits

- Release publishing is not implemented here.
- DMCP and DMCP5 packaging are not implemented here.
- The Clang 22 and GCC ASan plus UBSan lanes use direct Meson setup because
	the upstream top-level Makefile currently exposes ASan targets, but not a
	named UBSan target.
- GitHub-hosted secrets and release settings remain future integration work.

## Licensing

This planning repo has separate licensing surfaces.

- The local GitHub Actions workflow and CI implementation files are covered by
	the Blue Oak Model License 1.0.0 in `LICENSE`.
- Simulator artifacts produced by these workflows are copies of upstream c43
	program material. They remain governed by the upstream GNU General Public
	License Version 3 shipped by c43 in root `COPYING`, not by this repo's Blue
	Oak license.
- The simulator package artifacts assembled by `.github/workflows/c43-clang.yml`
	and `.github/workflows/c43-gcc-ci.yml` include a copy of upstream `COPYING`
	and a `SOURCE` manifest that records the upstream and xlsxio repository URLs
	and pinned commits used for the build.
