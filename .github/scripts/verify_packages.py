#!/usr/bin/env python3
"""Verify the three release packages before they are attached to a release.

Checks per scheme:
  * exactly one deb named *-<scheme>.deb
  * Architecture matches the scheme (rootful -> iphoneos-arm, others arm64)
  * Version matches the version recorded in control
  * Depends pins firmware >= 14.0
  * the payload really contains DYStorage.dylib
  * that dylib is a thin arm64 pair (arm64 + arm64e) and embeds the version
"""

import io
import os
import pathlib
import struct
import sys
import tarfile

PACKAGES = pathlib.Path("packages")
EXPECTED_ARCH = {"rootful": "iphoneos-arm", "rootless": "iphoneos-arm64", "roothide": "iphoneos-arm64"}
CPU_TYPE_ARM = 12
CPU_TYPE_ARM64 = 12 | 0x01000000
CPU_SUBTYPE_ARM64E = 2


def read_ar_deb(path):
    blob = path.read_bytes()
    # ar magic is a single bang followed by "<arch>\n"; spelled with bytes([33])
    # so this file stays free of shell-unfriendly punctuation.
    index = 8 if blob[0:1] == bytes([33]) and blob[1:8] == b"<arch>\n" else 0
    members = {}
    while index + 60 <= len(blob):
        header = blob[index:index + 60]
        name = header[:16].strip().decode("ascii", "replace").rstrip("/")
        try:
            size = int(header[48:58].strip())
        except ValueError:
            break
        members[name] = blob[index + 60:index + 60 + size]
        index += 60 + size + (size % 2)
    return members


def first_with_prefix(members, prefix):
    for name, data in members.items():
        if name.startswith(prefix):
            return name, data
    return None, None


def tar_control(data):
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive.getmembers():
            if member.name.endswith("control"):
                return archive.extractfile(member).read().decode("utf-8", "replace")
    return ""


def tar_dylib(data, name):
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive.getmembers():
            if member.name.endswith(name):
                return archive.extractfile(member).read()
    return None


def fat_arches(blob):
    if len(blob) < 8:
        return []
    magic = struct.unpack(">I", blob[:4])[0]
    if magic not in (0xCAFEBABE, 0xCAFEBABF):
        return []
    count = struct.unpack(">I", blob[4:8])[0]
    arches = []
    offset = 8
    wide = magic == 0xCAFEBABF
    for _ in range(count):
        if wide:
            cputype, cpusubtype = struct.unpack(">iI", blob[offset:offset + 8])
            offset += 32
        else:
            cputype, cpusubtype = struct.unpack(">iI", blob[offset:offset + 8])
            offset += 20
        arches.append((cputype, cpusubtype))
    return arches


def main():
    version = None
    control_path = pathlib.Path("control")
    if control_path.exists():
        for line in control_path.read_text(encoding="utf-8").splitlines():
            if line.lower().startswith("version:"):
                version = line.split(":", 1)[1].strip()
                break

    schemes = os.environ.get("VERIFY_SCHEMES", "rootful rootless roothide").split()
    failures = []

    for scheme in schemes:
        matches = sorted(PACKAGES.glob("*-%s.deb" % scheme))
        if len(matches) != 1:
            failures.append("%s: expected exactly one deb, found %d" % (scheme, len(matches)))
            continue
        deb = matches[0]
        members = read_ar_deb(deb)
        control_name, control_data = first_with_prefix(members, "control.tar")
        data_name, data_blob = first_with_prefix(members, "data.tar")
        if control_data is None or data_blob is None:
            failures.append("%s: deb is missing control.tar or data.tar" % scheme)
            continue

        control = tar_control(control_data)
        fields = {}
        for line in control.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                fields[key.strip().lower()] = value.strip()

        arch = fields.get("architecture", "")
        if arch != EXPECTED_ARCH[scheme]:
            failures.append("%s: architecture is %r, expected %r" % (scheme, arch, EXPECTED_ARCH[scheme]))
        if version and fields.get("version") != version:
            failures.append("%s: version is %r, expected %r" % (scheme, fields.get("version"), version))
        depends = fields.get("depends", "")
        if "firmware (>= 14.0)" not in depends:
            failures.append("%s: depends does not pin firmware (>= 14.0)" % scheme)

        dylib = tar_dylib(data_blob, "DYStorage.dylib")
        if dylib is None:
            failures.append("%s: payload has no DYStorage.dylib" % scheme)
            continue
        arches = fat_arches(dylib)
        have = set()
        for cputype, cpusubtype in arches:
            # arm64e slices carry CPU_SUBTYPE_MASK capability bits in the high
            # byte (0x80000002), so compare the low 24 bits only.
            subtype = cpusubtype & 0x00FFFFFF
            if cputype == CPU_TYPE_ARM64 and subtype == CPU_SUBTYPE_ARM64E:
                have.add("arm64e")
            elif cputype == CPU_TYPE_ARM64:
                have.add("arm64")
            elif cputype == CPU_TYPE_ARM:
                have.add("arm")
        if "arm64" not in have or "arm64e" not in have:
            failures.append("%s: dylib slices are %s, expected arm64 + arm64e" % (scheme, sorted(have)))
        if version and version.encode() not in dylib:
            failures.append("%s: dylib does not embed version %s" % (scheme, version))

        print("%-8s %-14s version=%s slices=%s" % (scheme, arch, fields.get("version"), ",".join(sorted(have))))

    for failure in failures:
        print("error: %s" % failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
