"""Collect native Windows loader evidence without importing socket."""

from __future__ import annotations

import importlib.util
import os
import sys
import traceback


def zone_identifier(path: str) -> str:
    try:
        with open(path + ":Zone.Identifier", encoding="utf-8", errors="replace") as stream:
            return stream.read().strip().replace("\n", "; ") or "present but empty"
    except FileNotFoundError:
        return "not present"
    except OSError as exc:
        return f"could not read ({exc})"


def main() -> int:
    socket_path = os.path.abspath(os.path.join(os.environ["APP"], "DLLs", "_socket.pyd"))
    spec = importlib.util.find_spec("_socket")

    print("=== Native Windows loader evidence ===")
    print("Windows:", sys.getwindowsversion())
    print("Python:", sys.executable)
    print("Python version:", sys.version.replace("\n", " "))
    print("PROCESSOR_ARCHITECTURE:", os.environ.get("PROCESSOR_ARCHITECTURE", "not set"))
    print("PROCESSOR_ARCHITEW6432:", os.environ.get("PROCESSOR_ARCHITEW6432", "not set"))
    print("Resolved _socket:", spec.origin if spec else "not found")
    print("Expected _socket:", socket_path)
    print(
        "Resolved path matches expected:",
        "YES"
        if spec and os.path.normcase(os.path.realpath(spec.origin)) == os.path.normcase(socket_path)
        else "NO",
    )
    print("Python internet-zone marker:", zone_identifier(sys.executable))
    print("_socket internet-zone marker:", zone_identifier(socket_path))
    print("Python search path:")
    for entry in sys.path:
        print("  ", entry)

    try:
        import ctypes

        print("ctypes native support: OK")
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        get_module_filename = kernel32.GetModuleFileNameW
        get_module_filename.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_wchar),
            ctypes.c_uint,
        ]
        get_module_filename.restype = ctypes.c_uint

        get_module_handle = kernel32.GetModuleHandleW
        get_module_handle.argtypes = [ctypes.c_wchar_p]
        get_module_handle.restype = ctypes.c_void_p

        def loaded_path(handle: int) -> str:
            buffer = ctypes.create_unicode_buffer(32768)
            length = get_module_filename(handle, buffer, len(buffer))
            if not length:
                raise ctypes.WinError(ctypes.get_last_error())
            return buffer.value

        runtime_path = loaded_path(get_module_handle("python312.dll"))
        expected_runtime = os.path.abspath(os.path.join(os.environ["APP"], "python312.dll"))
        print("Loaded Python runtime:", runtime_path)
        print(
            "Loaded Python runtime matches expected:",
            "YES" if os.path.normcase(runtime_path) == os.path.normcase(expected_runtime) else "NO",
        )
        preloaded_socket = get_module_handle("_socket.pyd")
        print(
            "_socket already loaded before direct probe:",
            loaded_path(preloaded_socket) if preloaded_socket else "NO",
        )

        module = ctypes.WinDLL(socket_path, winmode=0x00001100)

        get_proc_address = kernel32.GetProcAddress
        get_proc_address.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        get_proc_address.restype = ctypes.c_void_p
        export_address = get_proc_address(module._handle, b"PyInit__socket")

        native_loaded_path = loaded_path(module._handle)
        print("Windows loaded _socket from:", native_loaded_path)
        print(
            "Windows-loaded _socket matches expected:",
            "YES"
            if os.path.normcase(native_loaded_path) == os.path.normcase(socket_path)
            else "NO",
        )
        print("Windows sees PyInit__socket:", "YES" if export_address else "NO")
        for dependency in ("WS2_32.dll", "IPHLPAPI.DLL", "VCRUNTIME140.dll", "ucrtbase.dll"):
            handle = get_module_handle(dependency)
            print(
                f"Loaded dependency {dependency}:",
                loaded_path(handle) if handle else "NOT LOADED",
            )
        if not export_address:
            print("GetProcAddress error:", ctypes.get_last_error())
            return 1
    except BaseException:
        print("Native loader probe: FAILED")
        traceback.print_exc()
        return 1

    print("Native loader probe: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
