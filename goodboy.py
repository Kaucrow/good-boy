#!/usr/bin/env python3
"""
Watchdog de archivos para Linux.

Observa creaciones, modificaciones y borrados de archivos en un directorio
y envia cada evento en JSON a un servidor HTTP.

Uso:
  python linux_file_watchdog.py --watch-path /ruta/a/observar --server-url http://localhost:8000/events
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import pwd
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from queue import Empty, Queue
from typing import Any, Dict, Optional

import requests
from watchdog.events import FileSystemEvent, FileSystemEventHandler
from watchdog.observers import Observer


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def to_iso_timestamp(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def get_file_type(path: Path) -> str:
    if path.suffix:
        return path.suffix.lower().lstrip(".")
    return "sin_extension"


def uid_to_user(uid: int) -> str:
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def stat_safe(path: Path) -> Optional[os.stat_result]:
    try:
        return path.stat()
    except (FileNotFoundError, PermissionError, OSError):
        return None


def actor_from_auditd(path: Path) -> Optional[str]:
    if not shutil_which("ausearch"):
        return None

    cmd = [
        "ausearch",
        "-f",
        str(path),
        "-ts",
        "recent",
        "-i",
    ]

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return None

    output = proc.stdout or ""
    marker = 'acct="'
    idx = output.rfind(marker)
    if idx == -1:
        return None

    start = idx + len(marker)
    end = output.find('"', start)
    if end == -1:
        return None

    username = output[start:end].strip()
    return username or None


def shutil_which(binary: str) -> Optional[str]:
    for base in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(base) / binary
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def build_event_payload(
    path: Path,
    operation: str,
    event_time_iso: str,
    host: str,
    deleted_cache_owner: Optional[str] = None,
) -> Dict[str, Any]:
    st = stat_safe(path)

    file_created_at = None
    file_modified_at = None
    owner_user = None

    if st is not None:
        file_created_at = to_iso_timestamp(st.st_ctime)
        file_modified_at = to_iso_timestamp(st.st_mtime)
        owner_user = uid_to_user(st.st_uid)
    elif deleted_cache_owner:
        owner_user = deleted_cache_owner

    actor_user = actor_from_auditd(path)
    if actor_user is None:
        actor_user = owner_user or "desconocido"

    return {
        "event_time_utc": event_time_iso,
        "hostname": host,
        "file_name": path.name,
        "file_path": str(path),
        "file_type": get_file_type(path),
        "operation": operation,
        "file_created_or_ctime_utc": file_created_at,
        "file_modified_utc": file_modified_at,
        "owner_user": owner_user,
        "actor_user": actor_user,
    }


class JsonEventSender:
    def __init__(
        self,
        server_url: str,
        timeout_seconds: int,
        queue_size: int,
        retries: int,
        retry_sleep_seconds: float,
    ) -> None:
        self.server_url = server_url
        self.timeout_seconds = timeout_seconds
        self.retries = retries
        self.retry_sleep_seconds = retry_sleep_seconds
        self.queue: Queue[Dict[str, Any]] = Queue(maxsize=queue_size)
        self._stop = threading.Event()
        self._worker = threading.Thread(target=self._run_worker, daemon=True)

    def start(self) -> None:
        self._worker.start()

    def stop(self) -> None:
        self._stop.set()
        self._worker.join(timeout=3)

    def enqueue(self, payload: Dict[str, Any]) -> None:
        try:
            self.queue.put_nowait(payload)
        except Exception:
            logging.warning("Cola de eventos llena, se descarta evento: %s", payload.get("file_path"))

    def _run_worker(self) -> None:
        while not self._stop.is_set():
            try:
                payload = self.queue.get(timeout=0.5)
            except Empty:
                continue

            self._post_with_retry(payload)
            self.queue.task_done()

    def _post_with_retry(self, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=True)
        headers = {"Content-Type": "application/json"}

        for attempt in range(1, self.retries + 2):
            try:
                response = requests.post(
                    self.server_url,
                    data=body,
                    headers=headers,
                    timeout=self.timeout_seconds,
                )
                if 200 <= response.status_code < 300:
                    logging.info("Evento enviado OK (%s): %s", response.status_code, payload["file_path"])
                    return

                logging.warning(
                    "Fallo HTTP al enviar evento (intento %s): %s - %s",
                    attempt,
                    response.status_code,
                    response.text[:200],
                )
            except requests.RequestException as exc:
                logging.warning("Error de red (intento %s): %s", attempt, exc)

            if attempt <= self.retries:
                time.sleep(self.retry_sleep_seconds)

        logging.error("No se pudo enviar evento tras reintentos: %s", payload)


class LinuxWatchHandler(FileSystemEventHandler):
    def __init__(self, sender: JsonEventSender, host: str) -> None:
        super().__init__()
        self.sender = sender
        self.host = host
        self.last_known_owner_by_path: Dict[str, str] = {}

    def _remember_owner_if_possible(self, path: Path) -> None:
        st = stat_safe(path)
        if st is not None:
            self.last_known_owner_by_path[str(path)] = uid_to_user(st.st_uid)

    def _emit(self, path: Path, operation: str) -> None:
        payload = build_event_payload(
            path=path,
            operation=operation,
            event_time_iso=utc_now_iso(),
            host=self.host,
            deleted_cache_owner=self.last_known_owner_by_path.get(str(path)),
        )
        self.sender.enqueue(payload)

    def on_created(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            return
        path = Path(event.src_path)
        self._remember_owner_if_possible(path)
        self._emit(path, "created")

    def on_modified(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            return
        path = Path(event.src_path)
        self._remember_owner_if_possible(path)
        self._emit(path, "modified")

    def on_deleted(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            return
        path = Path(event.src_path)
        self._emit(path, "deleted")

    def on_moved(self, event: FileSystemEvent) -> None:
        if event.is_directory:
            return
        src_path = Path(event.src_path)
        dst_path = Path(event.dest_path)
        self._emit(src_path, "moved_from")
        self._remember_owner_if_possible(dst_path)
        self._emit(dst_path, "moved_to")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Watchdog Linux que envia eventos de archivos en JSON")
    parser.add_argument("--watch-path", default="/home", help="Directorio a observar (default: /home)")
    parser.add_argument("--server-url", required=True, help="Endpoint HTTP receptor de eventos")
    parser.add_argument("--recursive", action="store_true", help="Observar subdirectorios")
    parser.add_argument("--timeout", type=int, default=5, help="Timeout HTTP en segundos")
    parser.add_argument("--queue-size", type=int, default=1000, help="Tamano maximo de cola local")
    parser.add_argument("--retries", type=int, default=2, help="Reintentos por evento")
    parser.add_argument("--retry-sleep", type=float, default=0.6, help="Pausa entre reintentos")
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s | %(levelname)s | %(message)s",
    )

    watch_path = Path(args.watch_path).expanduser().resolve()
    if not watch_path.exists() or not watch_path.is_dir():
        logging.error("Ruta invalida para observar: %s", watch_path)
        return 1

    host = os.uname().nodename

    sender = JsonEventSender(
        server_url=args.server_url,
        timeout_seconds=args.timeout,
        queue_size=args.queue_size,
        retries=args.retries,
        retry_sleep_seconds=args.retry_sleep,
    )
    sender.start()

    handler = LinuxWatchHandler(sender=sender, host=host)
    observer = Observer()
    observer.schedule(handler, str(watch_path), recursive=args.recursive)
    observer.start()

    logging.info("Watchdog activo en: %s", watch_path)
    logging.info("Enviando eventos a: %s", args.server_url)
    logging.info("Recursivo: %s", args.recursive)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        logging.info("Deteniendo watchdog...")
    finally:
        observer.stop()
        observer.join(timeout=3)
        sender.stop()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())