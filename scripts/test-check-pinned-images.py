#!/usr/bin/env python3
"""Pins scripts/check-pinned-images.py on throwaway repositories: what counts as pinned, which
files it reads, and that one image pinned two ways fails."""
import contextlib
import importlib.util
import io
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_pinned_images", HERE / "check-pinned-images.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

A = "@sha256:" + "a" * 64
B = "@sha256:" + "b" * 64


def run(files):
    """Exit code and problems for a repository holding [files] (path -> text), all tracked."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        for path, text in files.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        found = check.problems(check.dockerfiles(root), root)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = check.main(["check", str(root)])
        return code, found


def expect(got, want, what):
    if got != want:
        raise SystemExit(f"check-pinned-images: {what}: expected {want!r}, got {got!r}")


code, found = run({"a/Dockerfile": f"FROM alpine:3.22{A}\nRUN true\n"})
expect((code, found), (0, []), "a pinned image")

code, found = run({"wireguard/Dockerfile": "# peer\nFROM alpine:3.22\nRUN true\n"})
expect(code, 1, "an image pinned by tag only")
expect(found, ["wireguard/Dockerfile:2: alpine:3.22 is not pinned by digest; use alpine:3.22@sha256:<digest>"],
       "the unpinned line")

code, found = run({"Dockerfile": f"FROM --platform=linux/amd64 alpine:3.22{A} AS build\n"
                                 "FROM build\nFROM scratch\nfrom Build as final\n"})
expect((code, found), (0, []), "platform flags, earlier stages and scratch")

code, found = run({"Dockerfile": "FROM $BASE\n"})
expect(code, 1, "an image named by a variable cannot be shown pinned")

code, found = run({"tools/build.Dockerfile": "FROM golang:1.26\n", "Dockerfile.dev": "FROM node:24\n",
                   "app/Containerfile": "FROM alpine:3.22\n", "notes.md": "FROM alpine:3.22\n"})
expect(len(found), 2, "Scorecard's files: every name containing Dockerfile, and only those")

code, found = run({"one/Dockerfile": f"FROM alpine:3.22{A}\n", "two/Dockerfile": f"FROM alpine:3.22{B}\n",
                   "three/Dockerfile": f"FROM alpine:3.21{B}\n"})
expect(code, 1, "one image and tag pinned to two digests")
expect(len(found), 1, "only the image with two digests")
expect(found[0].startswith("alpine:3.22 is pinned to 2 different digests"), True, "names the image")

print("check-pinned-images tests passed.")
