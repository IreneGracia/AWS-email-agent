import sys
import types
import pathlib

ROOT = pathlib.Path(__file__).parent.parent
sys.path.insert(0, str(ROOT / "lambdas"))

# strands @tool is a no-op in tests
_strands = types.ModuleType("strands")
_strands.tool = lambda fn: fn
sys.modules.setdefault("strands", _strands)