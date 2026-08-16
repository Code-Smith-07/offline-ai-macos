#!/bin/sh
# The production frontend is compiled before wheel packaging. Hatch invokes npm
# again while assembling the wheel; this successful no-op keeps that packaging
# step deterministic and includes the existing build/ directory.
exit 0
