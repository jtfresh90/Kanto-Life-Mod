#!/usr/bin/env python3
"""Run the Api3Features mock tests + compile-check every Lua file in the mod."""
import pathlib
import sys

from lupa import LuaRuntime

ROOT = pathlib.Path(__file__).resolve().parent.parent

lua = LuaRuntime(unpack_returned_tuples=True)

# Compile-check all Lua sources first (syntax only).
# Baseline: three FireRed files use a loop-variable assignment that the
# engine's LuaJIT accepts but lupa's newer Lua rejects (documented
# pre-existing behaviour, identical on the unmodified main branch).
BASELINE_FAIL = {"FireRedAmbient.lua", "FireRedInteractions.lua", "FireRedRoutines.lua"}
bad = []
n = 0
for p in sorted(ROOT.rglob("*.lua")):
    n += 1
    src = p.read_text(encoding="utf-8", errors="replace")
    try:
        lua.compile(src)
    except Exception as e:  # noqa: BLE001
        if p.name in BASELINE_FAIL:
            print(f"compile check: {p.name} skipped (known lupa/LuaJIT baseline difference)")
            continue
        bad.append((str(p), str(e)))
if bad:
    for p, e in bad:
        print(f"COMPILE FAIL {p}: {e}")
    sys.exit(1)
print(f"compile check: {n} Lua files OK (minus documented baseline)")

lua.globals()["API3_PATH"] = str(ROOT / "lib" / "Api3Features.lua")
lua.globals()["SHARED_PATH"] = str(ROOT / "lib" / "SharedEvents.lua")
test_src = (ROOT / "tests" / "api3_mock_test.lua").read_text(encoding="utf-8")
try:
    lua.execute(test_src)
except Exception as e:  # noqa: BLE001
    print(f"TEST RUN ERROR: {e}")
    sys.exit(1)
