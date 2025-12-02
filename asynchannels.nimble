# Package

version = "0.1.0"
author = "Jacek Sieka"
description = "Thread-safe MPMC channel for Chronos"
license = "MIT"

# Earlier nim versions may be supported but haven't been tested and have
# significant bugs when used with ORC.
requires "nim >= 2.2.4", "chronos >= 4.0.4 & < 5.0.0", "results >= 0.5.1", "nimcrypto"

proc test(env, path: string) =
  exec "nim c " & env & " -r " & path

task test, "Runs the test suite":
  for f in ["tests/test_asyncchannels.nim", "examples/sha256sum.nim"]:
    for opt in ["--mm:orc", "--mm:refc"]:
      test opt, f
