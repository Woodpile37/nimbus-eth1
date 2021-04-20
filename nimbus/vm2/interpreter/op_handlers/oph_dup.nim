# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Duplication Operations
## ===========================================
##


const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ./oph_defs,
  ./oph_helpers,
  sequtils,
  strformat,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../stack

else:
  # function stubs from stack.nim (to satisfy compiler logic)
  proc dup(stack: var Stack, position: int | UInt256) = discard

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc fnName(n: int): string {.compileTime.} =
  &"dup{n}Op"

proc opName(n: int): string {.compileTime.} =
  &"Dup{n}"

proc fnInfo(n: int): string {.compileTime.} =
  var blurb = case n
              of 1: "first"
              of 2: "second"
              of 3: "third"
              else: &"{n}th"
  &"Duplicate {blurb} item in the stack"


proc dupImpl(k: var Vm2Ctx; n: int) =
  k.cpt.stack.dup(n)

const
  inxRange = toSeq(1 .. 16)

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

genOphHandlers fnName, fnInfo, inxRange, dupImpl

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

genOphList fnName, fnInfo, inxRange, "vm2OpExecDup", opName

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------