"""Bounded live command output; cancellation owns the whole process group."""
import asyncio
import anyio
import codecs
import os
import signal

async def command_events(command, cwd, stop, timeout=300, output_limit=1024*1024):
    proc = await asyncio.create_subprocess_shell(command, executable='/bin/zsh', cwd=cwd,
        stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, start_new_session=True)
    pending = {}
    decoders = {name: codecs.getincrementaldecoder('utf-8')(errors='replace') for name in ['stdout','stderr']}
    timed_out = truncated = cancelled = False
    count = 0
    deadline = asyncio.get_running_loop().time()+timeout
    try:
        for name, pipe in [('stdout',proc.stdout),('stderr',proc.stderr)]:
            pending[asyncio.create_task(pipe.read(4096))] = (name,pipe)
        while pending or proc.returncode is None:
            if stop.is_set():
                cancelled=True; break
            if asyncio.get_running_loop().time() >= deadline:
                timed_out=True; break
            if not pending:
                await asyncio.sleep(.05); continue
            done,_ = await asyncio.wait(pending,timeout=.1,return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                name,pipe=pending.pop(task)
                data=task.result()
                available=max(0,output_limit-count)
                bounded=data[:available]
                count+=len(bounded)
                text=decoders[name].decode(bounded,final=not data or len(data)>available)
                if text:
                    yield {'type':name,'text':text}
                if len(data)>available:
                    truncated=True; break
                if data:
                    pending[asyncio.create_task(pipe.read(4096))]=(name,pipe)
            if truncated:
                break
    finally:
        # Kill synchronously: disconnect cancellation must never skip process termination.
        try:
            os.killpg(proc.pid,signal.SIGKILL)
        except ProcessLookupError:
            pass
        for task in pending:
            task.cancel()
        with anyio.CancelScope(shield=True):
            if pending:
                await asyncio.gather(*pending,return_exceptions=True)
            await proc.wait()
    yield {'type':'exit','returncode':-1 if timed_out or truncated or cancelled else proc.returncode,
           'timed_out':timed_out,'truncated':truncated,'cancelled':cancelled}
