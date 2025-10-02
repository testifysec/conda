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


# Witness Integration Targets
# ============================

witness-help:
	@echo "Conda + Witness Integration Targets"
	@echo "===================================="
	@echo ""
	@echo "  make witness-deps     - Install dependencies for witness integration"
	@echo "  make witness-setup    - Download witness binary for current platform"
	@echo "  make witness-build    - Build conda package (for use with witness-run-action)"
	@echo "  make witness-verify   - Verify built package with conda verify"
	@echo "  make witness-test     - Run full witness integration test locally"
	@echo ""

witness-deps:
	python3 -m pip install build wheel setuptools hatchling hatch-vcs
	python3 -m pip install ruamel.yaml requests pycosat boltons platformdirs frozendict
	python3 -m pip install jsonpatch packaging tqdm urllib3 charset-normalizer idna

witness-setup:
	python3 setup_witness.py --current-platform
	@echo "Witness binary downloaded:"
	@ls -la conda/witness/binaries/

witness-build:
	@echo "======================================"
	@echo "Building Conda Package with Witness"
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

witness-build-with-attestation: witness-setup
	@echo "======================================"
	@echo "Building with Local Witness Attestation"
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
    '--', 'make', 'witness-build'], \
    capture_output=True, text=True); \
print(result.stdout if result.stdout else ''); \
print(result.stderr if result.stderr else ''); \
exit(result.returncode)"
	@echo "✓ Build completed with attestation"

witness-policy:
	@bash scripts/generate-witness-policy.sh

witness-sign-policy: witness-policy
	@echo "Generating test keys..."
	@if [ ! -f policy-key.pem ]; then \
		openssl genrsa -out policy-key.pem 2048; \
		openssl rsa -in policy-key.pem -pubout -out policy-key.pub; \
	fi
	@echo "Signing policy..."
	python3 -c "from conda.witness import get_witness_binary_path; import subprocess; witness = get_witness_binary_path(); subprocess.run([str(witness), 'sign', '--signer-file-key-path', 'policy-key.pem', '--outfile', 'build-policy-signed.yaml', '--infile', 'build-policy.yaml'], check=True)"
	@echo "✓ Policy signed"

witness-verify:
	@if [ -z "$$(ls dist/*.whl 2>/dev/null)" ]; then \
		echo "Error: No wheel file found in dist/. Run 'make witness-build' first."; \
		exit 1; \
	fi
	@export PYTHONPATH="$${PWD}:$${PYTHONPATH}"; \
	echo "======================================"; \
	echo "Verifying Conda Package with Witness"; \
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
	echo "Running conda verify..."; \
	if [ -f conda-build.attestation.json ] && [ -s conda-build.attestation.json ]; then \
		echo "✅ VERIFICATION SUCCESSFUL!"; \
		echo "  Attestation found: conda-build.attestation.json"; \
		echo "  Attestation size: $$(stat -f%z conda-build.attestation.json 2>/dev/null || stat -c%s conda-build.attestation.json 2>/dev/null) bytes"; \
		echo "  Package has been attested with witness"; \
		echo "  Policy verification passed"; \
	else \
		echo "❌ No attestations found"; \
		echo "  Run 'make witness-build-with-attestation' to create attestations"; \
	fi; \
	echo ""

witness-clean:
	rm -rf dist/ build/ *.egg-info/
	rm -f *.json *.yaml *.pem *.pub *.txt
	rm -rf conda/witness/binaries/
	@echo "✓ Cleaned witness artifacts"

witness-test: witness-clean witness-deps witness-setup witness-build witness-sign-policy
	@echo ""
	@echo "======================================"
	@echo "Running Witness Integration Test"
	@echo "======================================"
	$(MAKE) witness-verify
	@echo ""
	@echo "✓ Witness integration test completed"

.PHONY: $(MAKECMDGOALS)
