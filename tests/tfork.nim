import cps
import cps/eventqueue

var r: int

proc adder(): Cont {.cps.} =
  cps fork()
  inc r

spawn adder()
run()
if r != 2:
  raise newException(Defect, "uh oh")
