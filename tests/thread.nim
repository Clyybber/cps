import cps
import cps/eventqueue

var sem = newSemaphore()
var success = false

proc tick(ms: int): Cont {.cps.} =
  cps detach()
  cps sleep(ms)
  signal(sem)

proc tock(): Cont {.cps.} =
  cps wait(sem)
  success = true

trampoline tick(10)
trampoline tock()

run()
if success != true:
  raise newException(Defect, "uh oh")
