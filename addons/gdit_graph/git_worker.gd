# Serial git command worker.
#
# ONE long-lived thread drains a FIFO of git commands so the caller never
# blocks. The previous design started a Thread per git call and joined the
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
	if _stopped:
		return
	# Start lazily so a manager that never issues a command spawns no thread.
	if _thread == null:
		_thread = Thread.new()
		_thread.start(_loop)
	_mutex.lock()
	_queue.append({"args": args, "callback": callback})
	_mutex.unlock()
	_sem.post()


func _loop() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		var command: Dictionary = {}
		if not _queue.is_empty():
			command = _queue.pop_front()
		var stopping := _stopped
		_mutex.unlock()
		if command.is_empty():
			# Only a stop posts with an empty queue; anything else is a
			# stray post, so keep waiting.
			if stopping:
				return
			continue
		var res: Dictionary = _get_executor().run_git(_repo_path, command.get("args", PackedStringArray()))
		# This runs on the worker thread; UI-touching signal handlers must
		# run on the main thread, so defer the callback there.
		(command.get("callback", Callable()) as Callable).call_deferred(int(res.get("exit_code", 1)), res.get("output", []))


# Stop the worker and join it. The queue is dropped first, so the single
# semaphore post below always finds an empty queue and the loop returns
# instead of blocking on its next wait(). This is the one place a
# main-thread join is acceptable: plugin disable / editor close.
func stop() -> void:
	_stopped = true
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()
	if _thread != null and _thread.is_started():
		_sem.post()
		_thread.wait_to_finish()
	_thread = null
