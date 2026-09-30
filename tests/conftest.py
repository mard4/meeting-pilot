import os

# Pipeline output language otherwise follows the macOS language of whoever runs the
# suite; pin it so expectations are stable. Subprocess-based CLI tests inherit it.
os.environ.setdefault("OUTPUT_LANGUAGE", "it")
