from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

from .config import get_workspace_root

logger = logging.getLogger("airecon.proxy.filesystem")

_LINE_COUNT_EXTENSIONS = {
    ".txt",
    ".csv",
    ".out",
    ".log",
    ".nmap",
    ".md",
    ".json",
    ".xml",
    ".html",
    ".htm",
    ".sh",
    ".py",
}
_MAX_DEPTH = 3

_MAX_CREATE_FILE_BYTES = 50 * 1024 * 1024

# Files larger than this get a "use shell/script" advisory instead of truncated content.
_LARGE_FILE_BYTE_THRESHOLD = 200 * 1024  # 200 KB
_LARGE_FILE_LINE_THRESHOLD = 1000


def _resolve_workspace_path(path: str, workspace_root: Path) -> Path:
    clean = str(path).strip().lstrip("/")
    if clean.startswith("workspace/"):
        clean = clean[len("workspace/") :]
    return (workspace_root / clean).resolve() if clean else workspace_root


def create_file(path: str, content: str) -> dict[str, Any]:
    try:
        if len(content.encode("utf-8")) > _MAX_CREATE_FILE_BYTES:
            return {
                "success": False,
                "error": "Content too large: maximum file size is 50 MB",
            }

        workspace_root = get_workspace_root().resolve()
        file_path = _resolve_workspace_path(path, workspace_root)

        try:
            file_path.relative_to(workspace_root)
        except ValueError:
            return {
                "success": False,
                "error": "Access denied: Path must be inside workspace",
            }

        if file_path.is_symlink():
            resolved = file_path.resolve()
            try:
                resolved.relative_to(workspace_root)
            except ValueError:
                return {
                    "success": False,
                    "error": "Access denied: Symlink target outside workspace",
                }

        file_path.parent.mkdir(parents=True, exist_ok=True)

        import tempfile

        fd, temp_path = tempfile.mkstemp(dir=file_path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(content)
            os.replace(temp_path, str(file_path))
        except Exception:
            try:
                os.unlink(temp_path)
            except Exception as e2:
                logger.debug("Expected failure cleaning up temp file: %s", e2)
            raise

        return {
            "success": True,
            "result": f"File created at {file_path}",
            "path": str(file_path),
        }
    except Exception as e:
        return {"success": False, "error": str(e)}


def read_file(path: str, offset: int = 0, limit: int = 500) -> dict[str, Any]:
    try:
        if os.path.isabs(path) and os.path.isfile(path):
            abs_path = Path(path).resolve()
            workspace_root = get_workspace_root().resolve()
            project_root = Path(__file__).parent.parent.resolve()

            is_in_workspace = abs_path.is_relative_to(workspace_root)
            is_in_project = abs_path.is_relative_to(project_root)

            if not (is_in_workspace or is_in_project):
                return {
                    "success": False,
                    "error": f"Access denied: Absolute path {path} is outside the allowed sandbox.",
                }

            return _read_with_pagination(abs_path, offset, limit)

        workspace_root = get_workspace_root().resolve()
        file_path = _resolve_workspace_path(path, workspace_root)

        try:
            file_path.relative_to(workspace_root)
        except ValueError:
            return {
                "success": False,
                "error": "Access denied: Cannot read files outside workspace.",
            }

        if file_path.is_symlink():
            resolved = file_path.resolve()
            try:
                resolved.relative_to(workspace_root)
            except ValueError:
                return {
                    "success": False,
                    "error": "Access denied: Symlink target outside workspace",
                }

        if not file_path.exists():
            return {
                "success": False,
                "error": (
                    f"File not found in workspace: {path}. "
                    f"Resolved path: {file_path}. "
                    "Tip: relative paths are resolved against the workspace directory. "
                    "To read a file outside the workspace, use its absolute path."
                ),
            }

        return _read_with_pagination(file_path, offset, limit)

    except Exception as e:
        return {"success": False, "error": str(e)}


def _count_lines_streaming(file_path: Path) -> int:
    try:
        with file_path.open("r", errors="ignore") as fh:
            return sum(1 for _ in fh)
    except Exception:
        return -1


def _read_sample_lines(file_path: Path, n: int = 10) -> list[str]:
    sample: list[str] = []
    try:
        with file_path.open("r", errors="ignore") as fh:
            for i, line in enumerate(fh):
                if i >= n:
                    break
                sample.append(line.rstrip())
    except Exception:
        pass
    return sample


def _build_large_file_advisory(
    file_path: Path, file_size: int, total_lines: int, sample: list[str]
) -> dict[str, Any]:
    size_str = _fmt_size(file_size)
    lines_str = f"{total_lines:,}" if total_lines >= 0 else "unknown"
    sample_text = "\n".join(sample) if sample else "(could not read sample)"
    fname = file_path.name
    stem = file_path.stem

    advisory = (
        f"[LARGE FILE — do NOT read directly, use shell one-liner or Python script]\n"
        f"File  : {fname}\n"
        f"Size  : {size_str}  |  Lines: {lines_str}\n"
        f"\n"
        f"Reading this file would give partial/truncated data. The full raw data is\n"
        f"preserved on disk. Use the `execute` tool to filter and validate it:\n"
        f"\n"
        f"Sample (first 10 lines):\n"
        f"---\n"
        f"{sample_text}\n"
        f"---\n"
        f"\n"
        f"Suggested shell one-liners (run with `execute`):\n"
        f"  # Count total lines / unique entries\n"
        f"  wc -l output/{fname} && sort -u output/{fname} | wc -l\n"
        f"  # Extract unique domains\n"
        f"  cut -d'/' -f3 output/{fname} | sort -u | head -50\n"
        f"  # Filter URLs with parameters (potential injection points)\n"
        f"  grep '?' output/{fname} | sort -u | head -100\n"
        f"  # Extract unique paths (strip query strings)\n"
        f"  cut -d'?' -f1 output/{fname} | sort -u | head -100\n"
        f"  # Validate live URLs with httpx (writes only live results)\n"
        f"  cat output/{fname} | httpx -silent -status-code -mc 200,301,302 -threads 50 -o output/live_{stem}.txt\n"
        f"\n"
        f"Or write a Python script with `create_file` → tools/filter_{stem}.py, then run\n"
        f"it with `execute`. Let the script sort, deduplicate, and probe liveness —\n"
        f"do not try to paginate through this file manually."
    )

    return {
        "success": True,
        "large_file": True,
        "total_lines": total_lines,
        "file_size_bytes": file_size,
        "result": advisory,
    }


def _read_with_pagination(file_path: Path, offset: int, limit: int) -> dict[str, Any]:
    # For large files, return an advisory instead of truncated content so the LLM
    # is directed to use shell one-liners or Python scripts to process the raw data.
    file_size = file_path.stat().st_size
    if file_size > _LARGE_FILE_BYTE_THRESHOLD:
        total_lines = _count_lines_streaming(file_path)
        if total_lines < 0 or total_lines > _LARGE_FILE_LINE_THRESHOLD:
            sample = _read_sample_lines(file_path, n=10)
            return _build_large_file_advisory(file_path, file_size, total_lines, sample)

    try:
        raw = file_path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        return {"success": False, "error": str(e)}

    offset = max(0, offset)
    limit = max(1, min(limit, 5000))

    lines = raw.splitlines()
    total_lines = len(lines)

    if offset == 0 and total_lines <= limit:
        return {
            "success": True,
            "result": raw,
            "total_lines": total_lines,
        }

    chunk = lines[offset : offset + limit]
    has_more = (offset + limit) < total_lines
    result_text = "\n".join(chunk)

    meta_parts = [f"[Lines {offset + 1}–{offset + len(chunk)} of {total_lines} total]"]
    if has_more:
        next_offset = offset + limit
        meta_parts.append(
            f"[More lines available — read next page with: offset={next_offset}, limit={limit}]"
        )

    return {
        "success": True,
        "result": "\n".join(meta_parts) + "\n" + result_text,
        "total_lines": total_lines,
        "offset": offset,
        "limit": limit,
        "has_more": has_more,
    }


def list_files(path: str = "") -> dict[str, Any]:
    try:
        workspace_root = get_workspace_root().resolve()
        base_dir = _resolve_workspace_path(path, workspace_root)

        try:
            base_dir.relative_to(workspace_root)
        except ValueError:
            return {
                "success": False,
                "error": "Access denied: Path is outside the workspace.",
            }

        if not base_dir.exists():
            return {"success": False, "error": f"Directory not found: {path}"}

        if not base_dir.is_dir():
            return {"success": False, "error": f"Path is not a directory: {path}"}

        lines_output: list[str] = []
        try:
            rel = base_dir.relative_to(workspace_root)
            display_root = f"workspace/{rel}" if str(rel) != "." else "workspace/"
        except ValueError:
            display_root = "workspace/"
        lines_output.append(f"{display_root}")

        _walk_dir(base_dir, workspace_root, lines_output, depth=0, prefix="")

        if not lines_output[1:]:
            lines_output.append("  (empty)")

        return {
            "success": True,
            "result": "\n".join(lines_output),
        }

    except Exception as e:
        return {"success": False, "error": str(e)}


def _walk_dir(
    directory: Path,
    workspace_root: Path,
    output: list[str],
    depth: int,
    prefix: str,
) -> None:
    if depth >= _MAX_DEPTH:
        return

    try:
        entries = sorted(
            directory.iterdir(), key=lambda p: (p.is_file(), p.name.lower())
        )
    except PermissionError:
        return

    dirs = [e for e in entries if e.is_dir() and not e.is_symlink()]
    files = [e for e in entries if e.is_file()]
    all_entries = dirs + files

    for i, entry in enumerate(all_entries):
        is_last = i == len(all_entries) - 1
        connector = "└── " if is_last else "├── "
        child_prefix = prefix + ("    " if is_last else "│   ")

        if entry.is_dir():
            try:
                child_count = sum(1 for _ in entry.iterdir())
            except Exception:
                child_count = 0
            output.append(f"{prefix}{connector}{entry.name}/ ({child_count} items)")
            _walk_dir(entry, workspace_root, output, depth + 1, child_prefix)
        else:
            stat = entry.stat()
            size = _fmt_size(stat.st_size)
            line_info = ""
            large_tag = ""
            if entry.suffix.lower() in _LINE_COUNT_EXTENSIONS:
                try:
                    lc = sum(1 for _ in entry.open("r", errors="ignore"))
                    line_info = f", {lc:,} lines"
                    if stat.st_size > _LARGE_FILE_BYTE_THRESHOLD and lc > _LARGE_FILE_LINE_THRESHOLD:
                        large_tag = " [LARGE — use shell/script]"
                except Exception as e:
                    logger.debug(
                        "Expected failure counting lines for %s: %s", entry.name, e
                    )
            output.append(f"{prefix}{connector}{entry.name} ({size}{line_info}){large_tag}")


def _fmt_size(size_bytes: int) -> str:
    if size_bytes >= 1_048_576:
        return f"{size_bytes / 1_048_576:.1f} MB"
    if size_bytes >= 1024:
        return f"{size_bytes / 1024:.1f} KB"
    return f"{size_bytes} B"
