import os
import sys
from pathlib import Path

# Explicitly add the repository root to Python's search path
root_dir = str(Path(__file__).resolve().parent)
if root_dir not in sys.path:
    sys.path.insert(0, root_dir)

# Import and run your actual application logic
# (Replace 'main' with your actual execution function inside __main__.py if necessary)
from airecon.__main__ import main

if __name__ == "__main__":
    main()
