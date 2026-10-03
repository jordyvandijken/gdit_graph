# Git command worker.
#
# ONE long-lived thread drains a FIFO of git MUTATION commands so the caller
# never blocks, and read-only queries get their own short-lived threads
# (enqueue_read) so a multi-query refresh overlaps instead of serializing.
# The previous design started a Thread per git call and joined the
# previous one on the CALLING (main) thread, so two ops issued in the same
# frame — or any op issued while a pull was running — froze the editor UI
# until git exited.
#
# This lives in its own script deliberately. A live editor instance of
# git_manager.gd is reparsed IN PLACE every time that file is saved, and a
# member that did not exist in the previous shape reads back as Nil
# (AGENTS.md #242/#244/#245). Holding the thread, the queue and the
# Mutex/Semaphore here instead means such a reparse cannot swap them out
# from under the running loop: this object's members are only reaped when
# THIS file changes, and the loop keeps its own reference to the object.
# The manager's pointer to it may go Nil, which at worst means a fresh
# worker is created (commands still complete) rather than a wedged queue.
#
# No class_name (repo convention): load via
# preload("res://addons/gdit_graph/git_worker.gd").
extends RefCounted

const GitExecutorScript = preload("res://addons/gdit_graph/git_executor.gd")

var _queue: Array = []
var _mutex = Mutex.new()
var _sem = Semaphore.new()
var _thread = null
var _executor = null
var _repo_path: String = ""
var _stopped: bool = false
# Concurrent lane for read-only queries (see enqueue_read). Mutations stay on
# the serial _thread lane: parallel `git add`/`commit` pairs collide on
# index.lock and rapid stage-then-commit relies on completion ordering, so
# worktree/index writes must never run concurrently. Reads are independent
# snapshots and may overlap each other and an in-flight write (the panels
# refresh again after every mutation, so views converge).
var _read_threads: Array = []


# Shared git backend (see git_executor.gd). Optional: without one the worker
# lazily creates the default OS-backed executor, exactly like the manager.
func set_executor(executor) -> void:
	_executor = executor


# Work tree every queued command runs against. Changing it affects commands
# enqueued afterwards, which is what set_repo_path() means.
func set_repo_path(path: String) -> void:
	_repo_path = String(path)


func _get_executor():
	if _executor == null:
		_executor = GitExecutorScript.new()
	return _executor


# Queue one git command. Returns immediately: this never blocks, and never
# waits for the command ahead of it.
func enqueue(args: PackedStringArray, callback: Callable) -> void:
	_enqueue_command({"args": args, "callback": callback})


# Queue one helper-CLI command (e.g. `gh auth status`) on the serial lane.
# Same contract as enqueue(), but the command runs `program` instead of
# `git` (see run_cli in git_executor.gd). Creation commands go here so a
# repo-creation never interleaves with an in-flight git mutation.
func enqueue_cli(program: String, args: PackedStringArray, callback: Callable) -> void:
	_enqueue_command({"program": String(program), "args": args, "callback": callback})


# Queue one READ-ONLY helper-CLI command on its own short-lived thread
# (auth probes). Same contract as enqueue_read().
func enqueue_cli_read(program: String, args: PackedStringArray, callback: Callable) -> void:
	if _stopped:
		return
	_reap_read_threads()
	var worker := Thread.new()
	_read_threads.append(worker)
	worker.start(_execute_cli_read.bind(String(program), args, callback))


# Shared tail for enqueue()/enqueue_cli(): append one command dict to the
# serial FIFO and wake the loop. Split out so both entry points share the
# primitive checks and lazy thread startup.
func _enqueue_command(command: Dictionary) -> void:
	if _stopped:
		return
	if not _primitives_valid():
		_rebuild_primitives()
		if not _primitives_valid():
			push_error("Git Graph: git worker lost its Mutex/Semaphore to a live script reload; re-enable the plugin.")
			return
	# Start lazily so a manager that never issues a command spawns no thread,
	# and restart after a loop that died on a mangled member (see
	# _rebuild_primitives), otherwise every later command queues forever.
	if not _thread_running():
		_thread = Thread.new()
		_thread.start(_loop)
	_mutex.lock()
	_queue.append(command)
	_mutex.unlock()
	_sem.post()


# Queue one READ-ONLY git command (log, status, branch/tag lists, details,
# diffs) on its own short-lived thread, so a refresh pays the slowest query
# instead of the sum. Workers run side by side; callbacks are deferred to the
# main thread, so handlers stay serialized. Finished workers are reaped on
# every dispatch to bound the list. Never use this for mutations - they must
# keep the arrival order of enqueue() (see _thread).
func enqueue_read(args: PackedStringArray, callback: Callable) -> void:
	if _stopped:
		return
	_reap_read_threads()
	var worker := Thread.new()
	_read_threads.append(worker)
	worker.start(_execute_read.bind(args, callback))


# Join finished read workers and drop them so the list never grows without
# bound. Runs on the calling (main) thread; never waits on live work.
func _reap_read_threads() -> void:
	var live: Array = []
	for t in _read_threads:
		if t == null or not is_instance_valid(t):
			continue
		var worker := t as Thread
		if worker.is_started() and worker.is_alive():
			live.append(worker)
			continue
		if worker.is_started():
			worker.wait_to_finish()
	_read_threads = live


func _execute_read(args: PackedStringArray, callback: Callable) -> void:
	var res: Dictionary = _get_executor().run_git(_repo_path, args)
	var exit_code: int = int(res.get("exit_code", 1))
	var output: Array = res.get("output", [])
	# _execute_read runs on a worker thread; UI-touching signal handlers must
	# run on the main thread, so defer the callback there.
	callback.call_deferred(exit_code, output)


func _execute_cli_read(program: String, args: PackedStringArray, callback: Callable) -> void:
	var res: Dictionary = _get_executor().run_cli(program, args)
	var exit_code: int = int(res.get("exit_code", 1))
	var output: Array = res.get("output", [])
	# Same main-thread deferral as _execute_read (see above).
	callback.call_deferred(exit_code, output)


func _loop() -> void:
	# The loop holds its own references to the primitives. A live reparse of
	# THIS file rewrites the instance members (AGENTS.md #242/#244/#245), and
	# only these locals survive that intact - a loop reading the members died
	# on its first _mutex.lock() with a Mutex that came back as "". _queue is
	# shared by reference (the same Array object), so enqueue() and stop() keep
	# mutating what this loop pops from.
	var sem: Semaphore = _sem
	var mutex: Mutex = _mutex
	var queue: Array = _queue
	_publish_primitives(mutex, sem, queue)
	while true:
		sem.wait()
		# Republish every wake-up: if a reparse mangled the members while this
		# thread was parked in wait(), the main thread's entry points get the
		# live references back instead of the wrong-typed ones.
		_publish_primitives(mutex, sem, queue)
		mutex.lock()
		var command: Dictionary = {}
		if not queue.is_empty():
			command = queue.pop_front()
		var stopping := _stopped
		mutex.unlock()
		if command.is_empty():
			# Only a stop posts with an empty queue; anything else is a
			# stray post, so keep waiting.
			if stopping:
				return
			continue
		# Helper-CLI commands (enqueue_cli) carry a "program" key and run
		# that binary instead of git; plain git commands leave it empty.
		var res: Dictionary = _run_command(command)
		# This runs on the worker thread; UI-touching signal handlers must
		# run on the main thread, so defer the callback there.
		(command.get("callback", Callable()) as Callable).call_deferred(int(res.get("exit_code", 1)), res.get("output", []))


# Dispatch one queued command to the backend: `git` by default, the named
# helper CLI when the command carries a "program" key (see enqueue_cli).
# Runs on the worker thread; kept tiny so the loop above stays readable.
func _run_command(command: Dictionary) -> Dictionary:
	var program := String(command.get("program", ""))
	var args: PackedStringArray = command.get("args", PackedStringArray())
	if program.is_empty():
		return _get_executor().run_git(_repo_path, args)
	return _get_executor().run_cli(program, args)


# Hand this loop's primitives back to the instance when the members no longer
# hold them (a live reparse replaced them). Authoritative: the running loop is
# the only holder of the originals. Called from the worker thread, so this is a
# bare pointer store - the members are only ever compared and passed on by the
# main thread, never mutated here.
func _publish_primitives(mutex: Mutex, sem: Semaphore, queue: Array) -> void:
	if _primitives_valid():
		return
	_mutex = mutex
	_sem = sem
	_queue = queue


# A live reparse of this file can swap a member out from under a running
# instance: the editor leaves a Mutex reading back as "" (observed as
# git_worker.gd:119 "Nonexistent function '' in base 'String'"), and a worker
# with no Mutex never completes another command, so both panels go blank with
# no error to act on. A wrong-typed primitive counts as absent and is rebuilt
# - but only once no loop thread is alive, because that thread captured the
# originals (see _publish_primitives) and swapping them under it is the race
# this is avoiding.
func _primitives_valid() -> bool:
	return _mutex is Mutex and _sem is Semaphore and _queue is Array


func _rebuild_primitives() -> void:
	if _thread_running():
		return
	_mutex = Mutex.new()
	_sem = Semaphore.new()
	_queue = []
	_thread = null


func _thread_running() -> bool:
	return _thread != null and _thread.is_started() and _thread.is_alive()


# Stop the worker and join it. The queue is dropped first, so the single
# semaphore post below always finds an empty queue and the loop returns
# instead of blocking on its next wait(). In-flight read workers are joined
# too, so no thread outlives the owner. This is the one place a main-thread
# join is acceptable: plugin disable / editor close.
func stop() -> void:
	_stopped = true
	if not _primitives_valid():
		_rebuild_primitives()
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()
	if _thread != null and _thread.is_started():
		_sem.post()
		_thread.wait_to_finish()
	_thread = null
	# Reads are not queued anywhere: they run on threads that were started
	# per dispatch, so drain them directly.
	for t in _read_threads:
		if t != null and is_instance_valid(t) and (t as Thread).is_started():
			(t as Thread).wait_to_finish()
	_read_threads = []
