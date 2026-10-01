# Contributing to Meeting Pilot

Thanks for considering a contribution. This project has two parts: a Python CLI/backend (`src/transcribe_to_notion/`) and a macOS app (`macos/MeetingPilot/`, Swift Package Manager).

## Getting set up

Python backend:

```bash
python3 -m venv .venv311
source .venv311/bin/activate
pip install -e .
cp docs/env.example .env
```

macOS app: see [macos/MeetingPilot/README.md](../macos/MeetingPilot/README.md) and [SETUP.md](../docs/SETUP.md) for the full bootstrap process, including the FluidAudio dependency.

## Making changes

1. Fork the repo and create a branch off `main`.
2. Keep changes focused — one topic per pull request.
3. Match the existing code style:
   - Python: pragmatic, single-responsibility modules; type hints where non-obvious; exceptions bubble up rather than being swallowed; validation happens at boundaries.
   - Swift: avoid force-unwraps (`!`, `try!`, `as!`) in new code.
4. Add or update tests when you change behavior (`pytest tests/` for Python, `swift test` for the macOS app).
5. Don't commit build artifacts (`.dmg`, `.app`, `.build/`) or secrets (`.env`, API keys, tokens).

## Running tests

```bash
pytest tests/
pytest tests/test_notion_setup.py  # single file
```

```bash
cd macos/MeetingPilot
swift test
```

## Submitting a pull request

- Describe what changed and why.
- Reference any related issue.
- Make sure tests pass locally before opening the PR.

## Reporting bugs / requesting features

Please use the GitHub issue templates. Include steps to reproduce, expected vs. actual behavior, and relevant logs (`~/Library/Logs/transcribe-to-notion.{log,err}`) with any personal data redacted.

## License of contributions

Meeting Pilot is licensed under the [GPL-3.0-or-later](../LICENSE). By submitting a pull request you confirm that you wrote the contribution (or have the right to submit it), and you agree that it is licensed under the GPL-3.0-or-later and that the maintainer may also distribute it under other license terms, including commercial ones.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to abide by it.
