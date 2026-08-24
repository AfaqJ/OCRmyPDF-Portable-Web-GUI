"""Start OCRmyPDF on Windows even when Python's socket extension is blocked.

OCRmyPDF uses threads by default, but importing Python's multiprocessing and
logging helpers still imports ``socket``.  Some managed Windows computers
block the bundled ``_socket.pyd`` even when its path and hash are correct.
This entry point uses the real socket module when it works.  Only after that
specific import fails does it install a non-network placeholder sufficient for
OCRmyPDF's thread-based, local processing path.
"""

from __future__ import annotations

import os
import sys
import types


class NetworkUnavailable(OSError):
    pass


class DisabledSocket:
    def __init__(self, *args, **kwargs):
        raise NetworkUnavailable("Networking is disabled in the native OCR runtime")


def disabled(*args, **kwargs):
    raise NetworkUnavailable("Networking is disabled in the native OCR runtime")


def socket_placeholder() -> types.ModuleType:
    module = types.ModuleType("socket")
    module._GLOBAL_DEFAULT_TIMEOUT = object()
    module.socket = DisabledSocket
    module.SocketType = DisabledSocket
    module.error = NetworkUnavailable
    module.timeout = TimeoutError
    module.gaierror = NetworkUnavailable
    module.herror = NetworkUnavailable
    module.has_ipv6 = False
    module.AF_INET = 2
    module.AF_INET6 = 23
    module.SOCK_STREAM = 1
    module.SOCK_DGRAM = 2
    module.SOL_SOCKET = 0xFFFF
    module.SO_REUSEADDR = 4
    module.SO_TYPE = 0x1008
    module.IPPROTO_TCP = 6
    module.TCP_NODELAY = 1
    module.SHUT_RDWR = 2
    module.gethostname = lambda: os.environ.get("COMPUTERNAME", "localhost")
    module.getfqdn = lambda name="": name or module.gethostname()
    module.getdefaulttimeout = lambda: None
    module.setdefaulttimeout = disabled
    module.create_connection = disabled
    module.getaddrinfo = disabled
    module.fromfd = disabled
    module.fromshare = disabled
    module.socketpair = disabled
    return module


def prepare_runtime(force_fallback: bool = False) -> bool:
    if not force_fallback:
        try:
            import socket  # noqa: F401

            return False
        except ImportError:
            pass
    sys.modules.pop("socket", None)
    sys.modules.pop("_socket", None)
    sys.modules["socket"] = socket_placeholder()
    return True


def selftest() -> None:
    used_fallback = prepare_runtime(force_fallback=True)
    import email.utils  # noqa: F401
    import http.client  # noqa: F401
    import logging.handlers  # noqa: F401
    import multiprocessing  # noqa: F401
    import multiprocessing.connection  # noqa: F401
    import ssl  # noqa: F401
    import urllib.request  # noqa: F401

    assert used_fallback
    assert sys.modules["socket"].socket is DisabledSocket
    print("socketless OCR entry selftest ok")


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    if sys.argv[1:] == ["--selftest-ocr-fallback"]:
        prepare_runtime(force_fallback=True)
        from ocrmypdf import __version__
        from ocrmypdf.fpdf_renderer import Fpdf2PdfRenderer

        assert Fpdf2PdfRenderer
        print(f"socketless OCRmyPDF import ok - {__version__}")
        return 0

    used_fallback = prepare_runtime()
    if used_fallback:
        print(
            "NOTICE: Python socket support is unavailable; using the local OCR "
            "compatibility path.",
            file=sys.stderr,
            flush=True,
        )
    from ocrmypdf.__main__ import run

    return int(run(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
