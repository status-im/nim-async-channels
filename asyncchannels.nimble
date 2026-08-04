# Package

version = "0.1.0"
author = "Jacek Sieka"
description = "Thread-safe MPMC channel for Chronos"
license = "MIT"

# Earlier nim versions may be supported but haven't been tested and have
# significant bugs when used with ORC.
requires "nim >= 2.0.14",
  "chronos#b71392a13df707c0f02162b07caaddac2dd0103c", "results >= 0.5.1", "nimcrypto"

proc test(env, path: string) =
  exec "nim c " & env & " -r " & path

task test, "Runs the test suite":
  let tests =
    when (NimMajor, NimMinor) >= (2, 2):
      ["tests/test_asyncchannels.nim", "examples/sha256sum.nim"]
    else:
      ["tests/test_asyncchannels.nim"]
  for f in tests:
    # TODO https://github.com/nim-lang/Nim/issues/26014
    for opt in [
      "--mm:orc -d:useMalloc", "--mm:refc",
      "--mm:refc -d:release -d:useGcAssert -d:useSysAssert",
    ]:
      test opt, f
