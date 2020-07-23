import std/os
import std/selectors
import std/monotimes
import std/nativesockets
import std/tables
import std/times
import std/deques

import sorta

import cps
import cps/semaphore

export Semaphore, `==`, `<`, hash, signal, wait, isReady, withReady

const
  cpsDebug {.booldefine.} = false
  cpsPoolSize {.intdefine.} = 64

type
  Id = distinct int

  State = enum
    Unready = "the default state, pre-initialized"
    Stopped = "we are outside an event loop but available for queuing events"
    Running = "we're in a loop polling for events and running continuations"
    Stopping = "we're tearing down the dispatcher and it will shortly stop"

  Clock = MonoTime
  Fd = distinct int

  WaitingIds = seq[Id]
  PendingIds = Table[Semaphore, Id]
  EventQueue = object
    state: State                  ## dispatcher readiness
    pending: PendingIds           ## maps pending semaphores to Ids
    waiting: WaitingIds           ## maps waiting selector Fds to Ids
    goto: SortedTable[Id, Cont]   ## where to go from here!
    lastId: Id                    ## id of last-issued registration
    selector: Selector[Id]        ## watches selectable stuff
    yields: Deque[Cont]           ## continuations ready to run

    manager: Selector[Clock]      ## monitor polling, wake-ups
    timer: Fd                     ## file-descriptor of polling timer
    wake: SelectEvent             ## wake-up event for queue actions

  Cont* = ref object of RootObj
    fn*: proc(c: Cont): Cont {.nimcall.}
    when cpsDebug:
      clock: Clock                  ## time of latest poll loop
      delay: Duration               ## polling overhead
      id: Id                        ## our last registration
      fd: Fd                        ## our last file-descriptor

const
  invalidId = Id(0)
  invalidFd = Fd(-1)
  wakeupId = Id(-1)
  bogusIds = wakeupId .. invalidId
  oneMs = initDuration(milliseconds = 1)

var eq {.threadvar.}: EventQueue

template now(): Clock = getMonoTime()

proc `$`(id: Id): string = "{" & system.`$`(id.int) & "}"
proc `$`(fd: Fd): string = "[" & system.`$`(fd.int) & "]"

proc `<`(a, b: Id): bool {.borrow.}
proc `<`(a, b: Fd): bool {.borrow.}
proc `==`(a, b: Id): bool {.borrow.}
proc `==`(a, b: Fd): bool {.borrow.}

proc `[]=`(w: var WaitingIds; fd: int | Fd; id: Id) =
  while fd.int > len(w):
    setLen(w, len(w) * 2)
  system.`[]=`(w, fd.int, id)

proc pop(w: var WaitingIds; fd: int | Fd): Id =
  result = w[fd.int]
  if result != wakeupId:        # don't zap our wakeup id
    w[fd.int] = invalidId

proc init() {.inline.} =
  ## initialize the event queue to prepare it for requests
  if eq.state == Unready:
    # create a new manager
    eq.timer = invalidFd
    eq.manager = newSelector[Clock]()
    eq.wake = newSelectEvent()
    eq.selector = newSelector[Id]()

    # make sure we have a decent amount of space for registrations
    if len(eq.waiting) < cpsPoolSize:
      eq.waiting = newSeq[Id](cpsPoolSize).WaitingIds

    # the manager wakes up when triggered to do so
    registerEvent(eq.manager, eq.wake, now())

    # so does the main selector
    registerEvent(eq.selector, eq.wake, wakeupId)

    # XXX: this seems to be the only reasonable wait to get our wakeup fd
    # we want to get the fd used for the wakeup event
    trigger eq.wake
    for ready in eq.selector.select(-1):
      assert User in ready.events
      eq.waiting[ready.fd] = wakeupId

    eq.lastId = invalidId
    eq.yields = initDeque[Cont]()
    eq.state = Stopped

proc nextId(): Id {.inline.} =
  ## generate a new registration identifier
  init()
  inc eq.lastId
  result = eq.lastId

proc newSemaphore*(): Semaphore =
  result.init nextId().int

proc wakeUp() =
  case eq.state
  of Unready:
    init()
  of Stopped:
    discard "ignored wake-up to stopped dispatcher"
  of Running:
    trigger eq.wake
  of Stopping:
    discard "ignored wake-up request; dispatcher is stopping"

template wakeAfter(body: untyped): untyped =
  ## wake up the dispatcher after performing the following block
  init()
  try:
    body
  finally:
    wakeUp()

proc len*(eq: EventQueue): int =
  ## the number of pending continuations
  result = len(eq.goto) + len(eq.yields) + len(eq.pending)

proc `[]=`(eq: var EventQueue; id: Id; cont: Cont) =
  ## put a continuation into the queue according to its registration
  assert id != invalidId
  assert id != wakeupId
  assert not cont.isNil
  assert not cont.fn.isNil
  assert id notin eq.goto
  eq.goto[id] = cont

proc add*(eq: var EventQueue; cont: Cont): Id =
  ## add a continuation to the queue; returns a registration
  result = nextId()
  eq[result] = cont
  when cpsDebug:
    echo "🤞queue ", $result, " now ", len(eq), " items"

proc stop*() =
  ## tell the dispatcher to stop
  if eq.state == Running:
    eq.state = Stopping

    # tear down the manager
    assert not eq.manager.isNil
    eq.manager.unregister eq.wake
    if eq.timer != invalidFd:
      eq.manager.unregister eq.timer.int
      eq.timer = invalidFd
    close(eq.manager)

    # shutdown the wake-up trigger
    eq.selector.unregister eq.wake
    close(eq.wake)

    # discard the current selector to dismiss any pending events
    close(eq.selector)

    # discard the contents of the semaphore cache
    eq.pending = initTable[Semaphore, Id](cpsPoolSize)

    # discard the contents of the continuation cache
    eq.goto = initSortedTable[Id, Cont]()

    # re-initialize the queue
    eq.state = Unready
    init()

proc trampoline*(c: Cont) =
  ## run the supplied continuation until it is complete
  var c = c
  while not c.isNil and not c.fn.isNil:
    when cpsDebug:
      echo "🎪tramp ", cast[uint](c.fn), " at ", c.clock
    c = c.fn(c)

proc poll*() =
  ## see what needs doing and do it
  if eq.state != Running: return

  if len(eq) > 0:
    when cpsDebug:
      let clock = now()
    let ready = select(eq.selector, -1)

    # ready holds the ready file descriptors and their events.

    for event in items(ready):
      # get the registration of the pending continuation
      let id = eq.waiting.pop(event.fd)
      # the id will be wakeupId if it's a wake-up event
      assert id != invalidId
      if id == wakeupId:
        discard
      else:
        # stop listening on this fd
        unregister(eq.selector, event.fd)
        var cont: Cont
        if take(eq.goto, id, cont):
          when cpsDebug:
            cont.clock = clock
            cont.delay = now() - clock
            cont.id = id
            cont.fd = event.fd.Fd
            echo "💈delay ", id, " ", cont.delay
          trampoline cont
        else:
          raise newException(KeyError, "missing registration " & $id)

    # at this point, we've handled all timers and i/o so we can simply
    # iterate over the yields and run them.  to make sure we don't run
    # any newly-added yields in this poll, we'll process no more than
    # the current number of queued yields...

    for index in 1 .. len(eq.yields):
      let cont = popFirst eq.yields
      trampoline cont

  elif eq.timer == invalidFd:
    # if there's no timer and we have no pending continuations,
    stop()
  else:
    when cpsDebug:
      echo "💈"
    # else wait until the next polling interval or signal
    for ready in eq.manager.select(-1):
      # if we get any kind of error, all we can reasonably do is stop
      if ready.errorCode.int != 0:
        stop()
        raiseOSError(ready.errorCode, "cps eventqueue error")

proc run*(interval: Duration = DurationZero) =
  ## the dispatcher runs with a maximal polling interval; an interval of
  ## `DurationZero` causes the dispatcher to return when the queue is empty.

  # make sure the eventqueue is ready to run
  init()
  assert eq.state == Stopped
  if interval.inMilliseconds == 0:
    discard "the dispatcher returns after emptying the queue"
  else:
    # the manager wakes up repeatedly, according to the provided interval
    eq.timer = registerTimer(eq.manager,
                             timeout = interval.inMilliseconds.int,
                             oneshot = false, data = now()).Fd
  # the dispatcher is now running
  eq.state = Running
  while eq.state == Running:
    poll()

proc cpsYield*(): Cont {.cpsMagic.} =
  ## yield to pending continuations in the dispatcher before continuing
  wakeAfter:
    addLast(eq.yields, c)

proc cpsSleep*(interval: Duration): Cont {.cpsMagic.} =
  ## sleep for `interval` before continuing
  if interval < oneMs:
    raise newException(ValueError, "intervals < 1ms unsupported")
  else:
    wakeAfter:
      let id = eq.add(c)
      let fd = registerTimer(eq.selector,
        timeout = interval.inMilliseconds.int,
        oneshot = true, data = id)
      eq.waiting[fd] = id
      when cpsDebug:
        echo "⏰timer ", fd.Fd

proc cpsSleep*(ms: int): Cont {.cpsMagic.} =
  ## sleep for `ms` milliseconds before continuing
  let interval = initDuration(milliseconds = ms)
  cpsSleep(c, interval)

proc cpsSleep*(secs: float): Cont {.cpsMagic.} =
  ## sleep for `secs` seconds before continuing
  cpsSleep(c, (1_000 * secs).int)

proc cpsDiscard*(): Cont {.cpsMagic.} =
  ## discard the current continuation.
  discard

template signalImpl(s: Semaphore; body: untyped): untyped =
  var trigger = false
  var id = invalidId
  try:
    if take(eq.pending, s, id):
      var c: Cont
      if take(eq.goto, id, c):
        addLast(eq.yields, c)
        trigger = true
    else:
      body
  finally:
    if trigger:
      wakeUp()

proc cpsSignal*(s: var Semaphore): Cont {.cpsMagic.} =
  ## signal the given semaphore, causing the first waiting continuation
  ## to be queued for execution in the dispatcher; control remains in
  ## the calling procedure
  result = c
  signal s
  withReady s:
    init()
    signalImpl s:
      discard

proc cpsSignalAll*(s: var Semaphore): Cont {.cpsMagic.} =
  ## signal the given semaphore, causing all waiting continuations
  ## to be queued for execution in the dispatcher; control remains in
  ## the calling procedure
  result = c
  signal s
  if s.isReady:
    init()
    while true:
      signalImpl s:
        break
