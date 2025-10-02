SHELL := /bin/bash -o pipefail -o errexit

clean:
	find . -name \*.py[cod] -delete
	find . -name __pycache__ -delete
	rm -rf .cache build
	rm -f .coverage .coverage.* junit.xml tmpfile.rc tempfile.rc coverage.xml
	rm -rf auxlib bin conda/progressbar
	rm -rf conda-build conda_build_test_recipe record.txt
	rm -rf .pytest_cache


clean-all:
	@echo Deleting everything not belonging to the git repo:
	git clean -fdx


anaconda-submit-test: clean-all
	anaconda build submit . --queue conda-team/build_recipes --test-only


anaconda-submit-upload: clean-all
	anaconda build submit . --queue conda-team/build_recipes --label stage


pytest-version:
	pytest --version


smoketest:
	pytest tests/test_create.py -k test_create_install_update_remove


unit:
	pytest -m "not integration and not installed"


integration: clean pytest-version
	pytest -m "integration and not installed"


test-installed:
	pytest -m "installed" --shell=bash --shell=zsh


html:
	cd docs && make html


# Conda Verify Integration Targets
# =================================

# Main targets for demonstration
conda-demo: conda-clean conda-build-attested conda-sign-policy conda-verify
	@echo ""
	@echo "✅ Demo complete! Conda package built and verified with attestations."

# Quick build and verify
conda-quick-verify: conda-verify

conda-help:
	@echo "Conda Verify Command Targets"
	@echo "===================================="
	@echo ""
	@echo "Main Commands:"
	@echo "  make conda-demo       - Complete demo: build with attestations and verify"
	@echo "  make conda-verify     - Verify built package with 'conda verify' command"
	@echo ""
	@echo "Build Commands:"
	@echo "  make conda-build      - Build conda package (without attestations)"
	@echo "  make conda-build-attested - Build conda package with witness attestations"
	@echo ""
	@echo "Supporting Commands:"
	@echo "  make conda-deps       - Install dependencies for conda build"
	@echo "  make conda-setup      - Setup conda and witness dependencies"
	@echo "  make conda-sign-policy - Create and sign verification policy"
	@echo "  make conda-clean      - Clean all build artifacts"
	@echo "  make conda-test       - Run full integration test locally"
	@echo ""

conda-deps:
	python3 -m pip install build wheel setuptools hatchling hatch-vcs
	python3 -m pip install ruamel.yaml requests pycosat boltons platformdirs frozendict
	python3 -m pip install jsonpatch packaging tqdm urllib3 charset-normalizer idna

conda-setup:
	python3 setup_witness.py --current-platform
	@echo "Witness binary downloaded:"
	@ls -la conda/witness/binaries/

conda-build:
	@echo "======================================"
	@echo "Building Conda Package"
	@echo "======================================"
	@echo "Python version: $$(python3 --version)"
	@echo "Current directory: $$(pwd)"
	@echo "Git commit: $$(git rev-parse HEAD 2>/dev/null || echo 'not a git repo')"
	@echo "Starting build..."
	python3 -m build --wheel --outdir dist/
	@echo ""
	@echo "Build artifacts:"
	ls -lh dist/
	@echo ""
	@echo "Checksums:"
	cd dist && (sha256sum * 2>/dev/null || shasum -a 256 *) | tee ../checksums.txt && cd ..
	@echo ""
	@echo "Build completed successfully!"

conda-build-attested: conda-setup
	@echo "======================================"
	@echo "Building Conda Package with Attestations"
	@echo "======================================"
	@# Generate local signing key if not exists (use policy-key for both)
	@if [ ! -f policy-key.pem ]; then \
		echo "Generating signing key..."; \
		openssl genrsa -out policy-key.pem 2048; \
		openssl rsa -in policy-key.pem -pubout -out policy-key.pub; \
	fi
	@# Run witness to create attestation
	@echo "Creating attestation with witness..."
	@python3 -c "from conda.witness import get_witness_binary_path; import subprocess, os, json; \
witness = get_witness_binary_path(); \
result = subprocess.run([str(witness), 'run', \
    '--step', 'conda-package-build', \
    '--signer-file-key-path', 'policy-key.pem', \
    '--outfile', 'conda-build.attestation.json', \
    '--attestations', 'material', '--attestations', 'command-run', '--attestations', 'product', \
    '--', 'python3', '-m', 'build', '--wheel', '--outdir', 'dist/'], \
    capture_output=True, text=True); \
print(result.stdout if result.stdout else ''); \
print(result.stderr if result.stderr else ''); \
exit(result.returncode)"
	@echo "✓ Build completed with attestation"

conda-policy:
	@bash scripts/generate-witness-policy.sh

conda-sign-policy: conda-policy
	@echo "Generating test keys..."
	@if [ ! -f policy-key.pem ]; then \
		openssl genrsa -out policy-key.pem 2048; \
		openssl rsa -in policy-key.pem -pubout -out policy-key.pub; \
	fi
	@echo "Signing policy..."
	python3 -c "from conda.witness import get_witness_binary_path; import subprocess; witness = get_witness_binary_path(); subprocess.run([str(witness), 'sign', '--signer-file-key-path', 'policy-key.pem', '--outfile', 'build-policy-signed.yaml', '--infile', 'build-policy.yaml'], check=True)"
	@echo "✓ Policy signed"

conda-verify:
	@if [ -z "$$(ls dist/*.whl 2>/dev/null)" ]; then \
		echo "Error: No wheel file found in dist/. Run 'make conda-build' or 'make conda-build-attested' first."; \
		exit 1; \
	fi
	@export PYTHONPATH="$${PWD}:$${PYTHONPATH}"; \
	echo "======================================"; \
	echo "Verifying Conda Package with 'conda verify'"; \
	echo "======================================"; \
	WHEEL=$$(ls dist/*.whl | head -1); \
	echo "Package to verify: $$WHEEL"; \
	echo ""; \
	if [ -f conda-build.attestation.json ] && [ -s conda-build.attestation.json ]; then \
		echo "Attestation summary:"; \
		python3 -c "import json, sys; content = sys.stdin.read(); data = json.loads(content) if content else {}; print(f\"  Type: {data.get('type', 'unknown')}\")" < conda-build.attestation.json 2>/dev/null || echo "  Type: unable to parse attestation"; \
	elif [ -f conda-build.attestation.json ]; then \
		echo "Warning: Attestation file exists but is empty"; \
	else \
		echo "Note: No local attestation file found (may be stored in Archivista)"; \
	fi; \
	echo ""; \
	echo "Running conda verify command..."; \
	export PYTHONPATH="$${PWD}:$${PYTHONPATH}"; \
	if [ -f conda-build.attestation.json ] && [ -s conda-build.attestation.json ]; then \
		echo "Found attestation file, running conda verify with policy..."; \
		echo ""; \
		python3 -W ignore::RuntimeWarning -m conda.cli.main verify \
			--artifactfile "$$WHEEL" \
			--policy build-policy-signed.yaml \
			--publickey policy-key.pub \
			--attestations conda-build.attestation.json; \
		VERIFY_EXIT_CODE=$$?; \
		echo ""; \
		if [ $$VERIFY_EXIT_CODE -eq 0 ]; then \
			echo "✅ VERIFICATION SUCCESSFUL!"; \
		else \
			echo "❌ VERIFICATION FAILED! (exit code: $$VERIFY_EXIT_CODE)"; \
			exit $$VERIFY_EXIT_CODE; \
		fi; \
	else \
		echo "No attestations found, running basic conda verify..."; \
		python3 -W ignore::RuntimeWarning -m conda.cli.main verify \
			--artifactfile "$$WHEEL" \
			--policy build-policy-signed.yaml \
			--publickey policy-key.pub; \
		VERIFY_EXIT_CODE=$$?; \
		echo ""; \
		if [ $$VERIFY_EXIT_CODE -eq 0 ]; then \
			echo "✅ PACKAGE VERIFIED!"; \
		else \
			echo "❌ VERIFICATION FAILED! (exit code: $$VERIFY_EXIT_CODE)"; \
			exit $$VERIFY_EXIT_CODE; \
		fi; \
	fi; \
	echo ""

conda-clean:
	rm -rf dist/ build/ *.egg-info/
	rm -f *.json *.yaml *.pem *.pub *.txt
	rm -rf conda/witness/binaries/
	@echo "✓ Cleaned witness artifacts"

conda-test: conda-clean conda-deps conda-setup conda-build-attested conda-sign-policy conda-verify
	@echo ""
	@echo "======================================"
	@echo "Running Witness Integration Test"
	@echo "======================================"
	@echo "✓ Witness integration test completed"

.PHONY: $(MAKECMDGOALS)
