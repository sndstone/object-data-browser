#!/usr/bin/env python3
"""Package a staged Windows release directory (or MSI) into a single portable .exe.

Builds the zero-dependency Go GUI launcher stub (with the app icon and an
asInvoker UAC manifest embedded via a COFF .rsrc .syso), zips the staged
Flutter + 5-engine Release payload, and appends the ZIP + 120-byte ODBPORT1
trailer to produce a standalone single-file portable Windows executable.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


TRAILER_MAGIC = b"ODBPORT1"
TRAILER_SIZE = 120
EXPECTED_ENGINES = ("python", "go", "rust", "rust-raw", "java")

MANIFEST_XML = b"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="2.4.0.0" processorArchitecture="*" name="ObjectDataBrowser.Portable" type="win32"/>
  <description>Object Data Browser Portable</description>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
</assembly>
"""


def _align4(buf: bytearray) -> None:
    rem = len(buf) % 4
    if rem:
        buf.extend(b"\x00" * (4 - rem))


def _parse_ico(ico_path: Path) -> tuple[bytes, list[bytes]]:
    raw = ico_path.read_bytes()
    if len(raw) < 6:
        raise ValueError(f"Invalid ICO header in {ico_path}")
    reserved, ico_type, count = struct.unpack_from("<HHH", raw, 0)
    if reserved != 0 or ico_type != 1 or count == 0:
        raise ValueError(f"Unsupported ICO format in {ico_path}")
    grp = bytearray(struct.pack("<HHH", 0, 1, count))
    images: list[bytes] = []
    for idx in range(count):
        off = 6 + idx * 16
        w, h, color_count, res, planes, bit_count, size, img_off = struct.unpack_from(
            "<BBBBHHII", raw, off
        )
        img = raw[img_off : img_off + size]
        if len(img) != size:
            raise ValueError(f"Truncated ICO image {idx} in {ico_path}")
        images.append(img)
        # GRPICONDIRENTRY uses uint16 icon ID (1-based) instead of uint32 offset.
        grp.extend(
            struct.pack(
                "<BBBBHHIH",
                w,
                h,
                color_count,
                res,
                planes or 1,
                bit_count or 32,
                size,
                idx + 1,
            )
        )
    return bytes(grp), images


def build_coff_rsrc_syso(ico_path: Path, arch: str, output_path: Path) -> None:
    """Write a minimal COFF object (.syso) containing RT_ICON, RT_GROUP_ICON, RT_MANIFEST."""
    grp_icon, icon_images = _parse_ico(ico_path)

    # Resource tree: type_id -> { name_id -> { lang_id -> bytes } }
    RT_ICON = 3
    RT_GROUP_ICON = 14
    RT_MANIFEST = 24
    LANG_EN_US = 0x0409

    tree: dict[int, dict[int, dict[int, bytes]]] = {
        RT_ICON: {i + 1: {LANG_EN_US: img} for i, img in enumerate(icon_images)},
        RT_GROUP_ICON: {1: {LANG_EN_US: grp_icon}},
        RT_MANIFEST: {1: {LANG_EN_US: MANIFEST_XML}},
    }

    # Pre-calculate directory & data-entry layout inside .rsrc section.
    # Each directory table = 16 bytes + 8 * len(entries).
    # Each data entry = 16 bytes.
    rsrc = bytearray()
    relocations: list[int] = []  # section-relative offsets of DataRVA fields

    sorted_types = sorted(tree.keys())
    # Reserve root directory.
    root_off = 0
    rsrc.extend(b"\x00" * (16 + 8 * len(sorted_types)))

    type_dir_offs: dict[int, int] = {}
    name_dir_offs: dict[tuple[int, int], int] = {}
    data_entry_offs: dict[tuple[int, int, int], int] = {}

    for t_id in sorted_types:
        type_dir_offs[t_id] = len(rsrc)
        names = sorted(tree[t_id].keys())
        rsrc.extend(b"\x00" * (16 + 8 * len(names)))

    for t_id in sorted_types:
        for n_id in sorted(tree[t_id].keys()):
            name_dir_offs[(t_id, n_id)] = len(rsrc)
            langs = sorted(tree[t_id][n_id].keys())
            rsrc.extend(b"\x00" * (16 + 8 * len(langs)))

    for t_id in sorted_types:
        for n_id in sorted(tree[t_id].keys()):
            for l_id in sorted(tree[t_id][n_id].keys()):
                data_entry_offs[(t_id, n_id, l_id)] = len(rsrc)
                rsrc.extend(b"\x00" * 16)

    # Append raw resource payloads and patch data entries.
    data_blobs: dict[tuple[int, int, int], tuple[int, int]] = {}
    for t_id in sorted_types:
        for n_id in sorted(tree[t_id].keys()):
            for l_id in sorted(tree[t_id][n_id].keys()):
                _align4(rsrc)
                blob = tree[t_id][n_id][l_id]
                blob_off = len(rsrc)
                rsrc.extend(blob)
                data_blobs[(t_id, n_id, l_id)] = (blob_off, len(blob))

    # Populate root directory.
    struct.pack_into("<IIHHHH", rsrc, root_off, 0, 0, 0, 0, 0, len(sorted_types))
    for i, t_id in enumerate(sorted_types):
        struct.pack_into(
            "<II", rsrc, root_off + 16 + i * 8, t_id, 0x80000000 | type_dir_offs[t_id]
        )

    # Populate type directories.
    for t_id in sorted_types:
        off = type_dir_offs[t_id]
        names = sorted(tree[t_id].keys())
        struct.pack_into("<IIHHHH", rsrc, off, 0, 0, 0, 0, 0, len(names))
        for i, n_id in enumerate(names):
            struct.pack_into(
                "<II",
                rsrc,
                off + 16 + i * 8,
                n_id,
                0x80000000 | name_dir_offs[(t_id, n_id)],
            )

    # Populate name directories & data entries.
    for t_id in sorted_types:
        for n_id in sorted(tree[t_id].keys()):
            off = name_dir_offs[(t_id, n_id)]
            langs = sorted(tree[t_id][n_id].keys())
            struct.pack_into("<IIHHHH", rsrc, off, 0, 0, 0, 0, 0, len(langs))
            for i, l_id in enumerate(langs):
                de_off = data_entry_offs[(t_id, n_id, l_id)]
                struct.pack_into("<II", rsrc, off + 16 + i * 8, l_id, de_off)
                blob_off, blob_len = data_blobs[(t_id, n_id, l_id)]
                struct.pack_into("<IIII", rsrc, de_off, blob_off, blob_len, 0, 0)
                relocations.append(de_off)

    _align4(rsrc)

    # COFF machine & relocation type (ADDR32NB)
    if arch == "x64":
        machine = 0x8664  # IMAGE_FILE_MACHINE_AMD64
        reloc_type = 0x0003  # IMAGE_REL_AMD64_ADDR32NB
    elif arch == "arm64":
        machine = 0xAA64  # IMAGE_FILE_MACHINE_ARM64
        reloc_type = 0x0002  # IMAGE_REL_ARM64_ADDR32NB
    else:
        raise ValueError(f"Unsupported arch: {arch}")

    coff_header_size = 20
    section_header_size = 40
    raw_data_ptr = coff_header_size + section_header_size
    reloc_ptr = raw_data_ptr + len(rsrc)
    sym_table_ptr = reloc_ptr + len(relocations) * 10

    coff = bytearray()
    # COFF File Header (20 bytes)
    coff.extend(
        struct.pack(
            "<HHIIIHH",
            machine,
            1,  # NumberOfSections
            0,  # TimeDateStamp
            sym_table_ptr,
            1,  # NumberOfSymbols (".rsrc" section symbol)
            0,  # SizeOfOptionalHeader
            0,  # Characteristics
        )
    )
    # Section Header for .rsrc (40 bytes)
    # Characteristics: CNT_INITIALIZED_DATA (0x40) | MEM_READ (0x40000000)
    coff.extend(
        struct.pack(
            "<8sIIIIIIHHI",
            b".rsrc\x00\x00\x00",
            0,  # VirtualSize
            0,  # VirtualAddress
            len(rsrc),
            raw_data_ptr,
            reloc_ptr,
            0,  # PointerToLinenumbers
            len(relocations),
            0,  # NumberOfLinenumbers
            0x40000040,
        )
    )
    coff.extend(rsrc)
    for rel_off in relocations:
        coff.extend(struct.pack("<IIH", rel_off, 0, reloc_type))
    # Single section symbol ".rsrc" (18 bytes) + empty string table (4 bytes)
    coff.extend(struct.pack("<8sIHHBB", b".rsrc\x00\x00\x00", 0, 1, 0, 3, 0))
    coff.extend(struct.pack("<I", 4))

    output_path.write_bytes(coff)


def read_pubspec_version(root_dir: Path) -> str:
    pubspec = (root_dir / "apps/flutter_app/pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*(\S+)", pubspec)
    if not match:
        return "2.4.0"
    raw = match.group(1)
    if "+" in raw:
        ver, build = raw.split("+", 1)
        return f"{ver}-build{build}"
    return raw


def verify_staged_release(release_dir: Path) -> None:
    app_exe = release_dir / "s3_browser_crossplat.exe"
    if not app_exe.is_file():
        raise RuntimeError(f"Missing s3_browser_crossplat.exe in {release_dir}")
    engines_dir = release_dir / "engines"
    manifest_path = engines_dir / "manifest.json"
    if not manifest_path.is_file():
        raise RuntimeError(f"Missing engines/manifest.json in {release_dir}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    by_id = {e["id"]: e for e in manifest.get("engines", [])}
    for eid in EXPECTED_ENGINES:
        if eid not in by_id:
            raise RuntimeError(f"Engine manifest is missing required engine: {eid}")
        for req in by_id[eid].get("requiredFiles", []):
            req_path = engines_dir / Path(req.replace("\\", "/"))
            if not req_path.exists():
                raise RuntimeError(f"Missing required sidecar path for {eid}: {req_path}")


def extract_msi(msi_path: Path, dest_dir: Path) -> Path:
    if os.name == "nt":
        cmd = ["msiexec.exe", "/a", str(msi_path.resolve()), "/qn", f"TARGETDIR={dest_dir.resolve()}"]
    else:
        msiextract = shutil.which("msiextract")
        if not msiextract:
            raise RuntimeError("msiextract is required to extract an MSI on non-Windows hosts.")
        cmd = [msiextract, "-C", str(dest_dir), str(msi_path)]
    subprocess.run(cmd, check=True)
    for exe in dest_dir.rglob("s3_browser_crossplat.exe"):
        return exe.parent
    raise RuntimeError(f"Could not find s3_browser_crossplat.exe inside extracted MSI {msi_path}")


def build_launcher_stub(root_dir: Path, arch: str, stub_out: Path) -> None:
    launcher_dir = root_dir / "packaging/windows/portable-launcher"
    ico_path = root_dir / "apps/flutter_app/windows/runner/resources/app_icon.ico"
    go_arch = "amd64" if arch == "x64" else "arm64"
    syso_path = launcher_dir / f"rsrc_windows_{go_arch}.syso"
    try:
        build_coff_rsrc_syso(ico_path, arch, syso_path)
        env = dict(os.environ)
        env["GOOS"] = "windows"
        env["GOARCH"] = go_arch
        env["CGO_ENABLED"] = "0"
        subprocess.run(
            [
                "go",
                "build",
                "-trimpath",
                "-ldflags",
                "-H=windowsgui -s -w",
                "-o",
                str(stub_out.resolve()),
                ".",
            ],
            cwd=launcher_dir,
            env=env,
            check=True,
        )
    finally:
        if syso_path.exists():
            syso_path.unlink()


CRT_DLLS = ("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")


def create_payload_zip(release_dir: Path, zip_path: Path) -> tuple[int, bytes]:
    files = sorted(p for p in release_dir.rglob("*") if p.is_file())
    included: dict[str, bytes] = {}
    for file_path in files:
        rel = file_path.relative_to(release_dir).as_posix()
        included[rel] = file_path.read_bytes()

    # Ensure portable deployments run on clean Windows machines without a global
    # VC++ Redistributable by placing the matching-arch CRT DLLs from the bundled
    # JRE/Python runtime next to the Flutter app and Rust sidecars.
    crt_sources = [
        release_dir / "engines/java/runtime/bin",
        release_dir / "engines/python",
    ]
    crt_targets = ["", "engines/rust", "engines/rust-raw"]
    for dll in CRT_DLLS:
        src_bytes = None
        for src_dir in crt_sources:
            candidate = src_dir / dll
            if candidate.is_file():
                src_bytes = candidate.read_bytes()
                break
        if src_bytes is None:
            continue
        for target_dir in crt_targets:
            rel = f"{target_dir}/{dll}" if target_dir else dll
            if rel not in included:
                included[rel] = src_bytes

    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in sorted(included.keys()):
            info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100755 << 16
            zf.writestr(info, included[rel], compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    h = hashlib.sha256()
    size = 0
    with zip_path.open("rb") as fh:
        while chunk := fh.read(1024 * 1024):
            h.update(chunk)
            size += len(chunk)
    return size, h.digest()


def assemble_portable_exe(stub_path: Path, zip_path: Path, version: str, output_path: Path) -> None:
    stub_bytes = stub_path.read_bytes()
    if not stub_bytes.startswith(b"MZ"):
        raise RuntimeError("Launcher stub does not start with a valid Windows PE MZ header.")
    payload_offset = len(stub_bytes)
    payload_size = zip_path.stat().st_size
    h = hashlib.sha256()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as out:
        out.write(stub_bytes)
        with zip_path.open("rb") as zp:
            while chunk := zp.read(1024 * 1024):
                h.update(chunk)
                out.write(chunk)
        ver_bytes = version.encode("utf-8")[:64].ljust(64, b"\x00")
        trailer = (
            TRAILER_MAGIC
            + struct.pack("<QQ", payload_offset, payload_size)
            + h.digest()
            + ver_bytes
        )
        assert len(trailer) == TRAILER_SIZE
        out.write(trailer)

    # Self-verify assembled binary trailer.
    total_size = output_path.stat().st_size
    with output_path.open("rb") as fh:
        fh.seek(total_size - TRAILER_SIZE)
        got = fh.read(TRAILER_SIZE)
    assert got[:8] == TRAILER_MAGIC
    got_off, got_sz = struct.unpack_from("<QQ", got, 8)
    assert got_off == payload_offset
    assert got_sz == payload_size
    assert got_off + got_sz + TRAILER_SIZE == total_size
    assert got[24:56] == h.digest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--release-dir", type=Path, help="Staged Windows Release directory")
    src.add_argument("--from-msi", type=Path, help="Existing Windows MSI to repackage as portable .exe")
    parser.add_argument("--arch", choices=("x64", "arm64"), default="x64")
    parser.add_argument("--version", default="")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    root_dir = Path(__file__).resolve().parent.parent
    version = args.version or read_pubspec_version(root_dir)

    with tempfile.TemporaryDirectory(prefix="odb-portable-") as tmp:
        tmp_dir = Path(tmp)
        release_dir = args.release_dir
        if args.from_msi is not None:
            release_dir = extract_msi(args.from_msi, tmp_dir / "msi-extract")
        assert release_dir is not None
        verify_staged_release(release_dir)

        stub_path = tmp_dir / "launcher.exe"
        zip_path = tmp_dir / "payload.zip"
        build_launcher_stub(root_dir, args.arch, stub_path)
        payload_size, payload_sha = create_payload_zip(release_dir, zip_path)
        assemble_portable_exe(stub_path, zip_path, version, args.output)

    final_sha = hashlib.sha256(args.output.read_bytes()).hexdigest()
    print(
        f"Created portable Windows {args.arch} executable: {args.output} "
        f"({args.output.stat().st_size:,} bytes, payload={payload_size:,} bytes, "
        f"payload_sha256={payload_sha.hex()[:12]}, exe_sha256={final_sha})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
