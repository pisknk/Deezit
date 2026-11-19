#!/usr/bin/env python3
"""
Deezit IPA analyser - standard library only, runs on Windows/macOS/Linux.

Answers the questions the tweak needs before any hook is written:
  1. Is every Mach-O in the bundle decrypted (cryptid == 0)?
  2. Is the UI UIKit, SwiftUI, React Native or Flutter?
  3. Which classes look like Now Playing / player / artwork screens?
  4. How is audio played: AudioUnit (RemoteIO/AUGraph), AudioQueue,
     AVAudioEngine, AVPlayer, or AVSampleBufferAudioRenderer?

Usage:
  python analyze_ipa.py <Deezer.ipa | extracted folder | Payload | Deezer.app>
                        [-o report.md] [--classes classes.txt]

The input can be an .ipa (zip, with or without the extension) or a folder
that contains Payload/*.app or is itself the .app.
"""

import argparse
import io
import os
import plistlib
import re
import struct
import sys
import zipfile
from collections import defaultdict

# --------------------------------------------------------------------------
# bundle access (zip or folder)
# --------------------------------------------------------------------------


class Bundle:
    """Read-only view of an .app bundle, from a zip or a directory."""

    def __init__(self, path):
        self.path = path
        self.zip = None
        self.root = None  # prefix inside zip, or directory on disk
        if os.path.isfile(path) and zipfile.is_zipfile(path):
            self.zip = zipfile.ZipFile(path)
            apps = sorted({
                m.split("/")[0] + "/" + m.split("/")[1]
                for m in self.zip.namelist()
                if m.startswith("Payload/") and m.count("/") >= 2
                and m.split("/")[1].endswith(".app")
            })
            if not apps:
                raise SystemExit("no Payload/*.app inside the zip")
            self.root = apps[0] + "/"
            self._names = [m[len(self.root):] for m in self.zip.namelist()
                           if m.startswith(self.root) and not m.endswith("/")]
        elif os.path.isdir(path):
            self.root = self._find_app_dir(path)
            self._names = []
            for dp, _, fns in os.walk(self.root):
                for fn in fns:
                    full = os.path.join(dp, fn)
                    self._names.append(os.path.relpath(full, self.root).replace(os.sep, "/"))
        else:
            raise SystemExit("input is neither a zip/ipa nor a folder: %s" % path)

    @staticmethod
    def _find_app_dir(path):
        if path.rstrip("/\\").endswith(".app"):
            return path
        for cand in (path, os.path.join(path, "Payload")):
            if os.path.isdir(cand):
                for e in sorted(os.listdir(cand)):
                    if e.endswith(".app") and os.path.isdir(os.path.join(cand, e)):
                        return os.path.join(cand, e)
        for dp, dns, _ in os.walk(path):
            for d in dns:
                if d.endswith(".app"):
                    return os.path.join(dp, d)
        raise SystemExit("could not find a .app folder under %s" % path)

    def names(self):
        return self._names

    def read(self, rel):
        if self.zip:
            return self.zip.read(self.root + rel)
        with open(os.path.join(self.root, rel), "rb") as f:
            return f.read()

    def size(self, rel):
        if self.zip:
            return self.zip.getinfo(self.root + rel).file_size
        return os.path.getsize(os.path.join(self.root, rel))

    def exists(self, rel):
        return rel in set(self._names)


# --------------------------------------------------------------------------
# Mach-O parsing
# --------------------------------------------------------------------------

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x80000023
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022

DYLIB_CMDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
              LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB}


def cstr(buf, off, limit=None):
    end = buf.find(b"\0", off, limit if limit is not None else len(buf))
    if end < 0:
        end = limit if limit is not None else len(buf)
    return buf[off:end].decode("utf-8", "replace")


def cstrings(blob):
    return [s.decode("utf-8", "replace") for s in blob.split(b"\0") if s]


class MachO:
    def __init__(self, data, name):
        self.name = name
        self.data = data
        self.ok = False
        self.arch_note = ""
        self.encryption = None  # (cryptid, cryptoff, cryptsize) or None
        self.dylibs = []
        self.sections = {}  # (seg, sect) -> (addr, offset, size)
        self.segments = []  # (vmaddr, vmsize, fileoff, filesize)
        self.imports = set()
        self.imports_ordered = []  # chained-fixup import table, for bind ordinals
        self.ptr_format = None  # dyld_chained_ptr format, None = classic/raw pointers
        self.base = 0  # __TEXT vmaddr
        self._class_cache = {}
        self.classic_binds = {}  # vmaddr -> symbol (LC_DYLD_INFO opcodes)
        self.swift_supers = {}  # Swift class path -> superclass path (from descriptors)
        self._parse()

    # -- slices --
    def _pick_slice(self):
        d = self.data
        if len(d) < 8:
            return None
        magic_be = struct.unpack_from(">I", d, 0)[0]
        if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
            n = struct.unpack_from(">I", d, 4)[0]
            best = None
            off = 8
            for _ in range(n):
                if magic_be == FAT_MAGIC:
                    cpu, sub, o, sz, _a = struct.unpack_from(">iiIII", d, off)
                    off += 20
                else:
                    cpu, sub, o, sz, _a, _r = struct.unpack_from(">iiQQII", d, off)
                    off += 32
                if cpu == CPU_TYPE_ARM64:
                    sub &= 0xFFFFFF
                    # prefer plain arm64 (what a sideloaded process runs)
                    if best is None or sub == 0:
                        best = (o, sz, "arm64e" if sub == 2 else "arm64")
            if best is None:
                return None
            self.arch_note = "fat, using " + best[2]
            return d[best[0]:best[0] + best[1]]
        if struct.unpack_from("<I", d, 0)[0] == MH_MAGIC_64:
            self.arch_note = "thin"
            return d
        return None

    def _parse(self):
        d = self._pick_slice()
        if d is None:
            return
        self.data = d
        magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _r = struct.unpack_from("<IiiIIIII", d, 0)
        if magic != MH_MAGIC_64:
            return
        off = 32
        symtab = None
        fixups = None
        dyld_info = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", d, off)
            if cmd == LC_SEGMENT_64:
                segname = d[off + 8:off + 24].rstrip(b"\0").decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", d, off + 24)
                nsects = struct.unpack_from("<I", d, off + 64)[0]
                self.segments.append((vmaddr, vmsize, fileoff, filesize))
                if segname == "__TEXT":
                    self.base = vmaddr
                so = off + 72
                for _s in range(nsects):
                    sect = d[so:so + 16].rstrip(b"\0").decode()
                    seg = d[so + 16:so + 32].rstrip(b"\0").decode()
                    addr, ssize = struct.unpack_from("<QQ", d, so + 32)
                    soff = struct.unpack_from("<I", d, so + 48)[0]
                    self.sections[(seg, sect)] = (addr, soff, ssize)
                    so += 80
            elif cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
                coff, csize, cid = struct.unpack_from("<III", d, off + 8)
                self.encryption = (cid, coff, csize)
            elif cmd in DYLIB_CMDS:
                noff = struct.unpack_from("<I", d, off + 8)[0]
                self.dylibs.append(cstr(d, off + noff, off + size))
            elif cmd == LC_SYMTAB:
                symtab = struct.unpack_from("<IIII", d, off + 8)
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                fixups = struct.unpack_from("<II", d, off + 8)
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                dyld_info = struct.unpack_from("<IIII", d, off + 8)  # rebase off/size, bind off/size
            off += size
        if symtab:
            self._read_undefined_symbols(*symtab)
        if fixups:
            self._read_chained_imports(*fixups)
        if dyld_info and dyld_info[3]:
            try:
                self._read_bind_opcodes(dyld_info[2], dyld_info[3])
            except (IndexError, struct.error):
                pass
        self.ok = True

    def _read_bind_opcodes(self, off, size):
        d, end = self.data, off + size
        i, seg_addr, sym = off, 0, None

        def uleb(j):
            r = sh = 0
            while True:
                b = d[j]
                j += 1
                r |= (b & 0x7F) << sh
                sh += 7
                if b < 0x80:
                    return r, j

        while i < end:
            byte = d[i]
            i += 1
            op, imm = byte & 0xF0, byte & 0x0F
            if op == 0x00:
                continue
            elif op in (0x10, 0x30, 0x50):
                pass
            elif op == 0x20:
                _v, i = uleb(i)
            elif op == 0x40:
                e = d.index(b"\0", i)
                sym = d[i:e].decode("utf-8", "replace")
                self.imports.add(sym)
                i = e + 1
            elif op == 0x60:
                _v, i = uleb(i)  # sleb, value unused
            elif op == 0x70:
                o, i = uleb(i)
                seg_addr = self.segments[imm][0] + o
            elif op == 0x80:
                o, i = uleb(i)
                seg_addr = (seg_addr + o) & 0xFFFFFFFFFFFFFFFF
            elif op == 0x90:
                self.classic_binds[seg_addr] = sym
                seg_addr += 8
            elif op == 0xA0:
                self.classic_binds[seg_addr] = sym
                o, i = uleb(i)
                seg_addr += 8 + o
            elif op == 0xB0:
                self.classic_binds[seg_addr] = sym
                seg_addr += 8 + imm * 8
            elif op == 0xC0:
                cnt, i = uleb(i)
                skip, i = uleb(i)
                for _ in range(cnt):
                    self.classic_binds[seg_addr] = sym
                    seg_addr += 8 + skip
            else:
                break

    def _read_undefined_symbols(self, symoff, nsyms, stroff, strsize):
        d = self.data
        for i in range(nsyms):
            o = symoff + i * 16
            if o + 16 > len(d):
                break
            strx, ntype = struct.unpack_from("<IB", d, o)
            if (ntype & 0x0E) == 0 and (ntype & 0x01) and strx:
                self.imports.add(cstr(d, stroff + strx, stroff + strsize))

    def _read_chained_imports(self, dataoff, datasize):
        d = self.data
        try:
            (_ver, starts_off, imports_off, symbols_off, count,
             imp_fmt, _sym_fmt) = struct.unpack_from("<IIIIIII", d, dataoff)
        except struct.error:
            return
        base = dataoff
        # pointer format: first segment that has chain starts
        try:
            seg_count = struct.unpack_from("<I", d, base + starts_off)[0]
            for si in range(seg_count):
                so = struct.unpack_from("<I", d, base + starts_off + 4 + si * 4)[0]
                if so:
                    self.ptr_format = struct.unpack_from("<H", d, base + starts_off + so + 6)[0]
                    break
        except struct.error:
            pass
        for i in range(count):
            if imp_fmt == 1:
                v = struct.unpack_from("<I", d, base + imports_off + i * 4)[0]
                name_off = v >> 9
            elif imp_fmt == 2:
                v = struct.unpack_from("<I", d, base + imports_off + i * 8)[0]
                name_off = v >> 9
            elif imp_fmt == 3:
                v = struct.unpack_from("<Q", d, base + imports_off + i * 16)[0]
                name_off = v >> 32
            else:
                return
            nm = cstr(d, base + symbols_off + name_off)
            self.imports.add(nm)
            self.imports_ordered.append(nm)

    # -- helpers --
    def section(self, seg, sect):
        s = self.sections.get((seg, sect))
        if not s or s[1] == 0:
            return b""
        return self.data[s[1]:s[1] + s[2]]

    def vm_to_off(self, addr):
        for vmaddr, vmsize, fileoff, filesize in self.segments:
            if vmaddr <= addr < vmaddr + filesize:
                return fileoff + (addr - vmaddr)
        return None

    def _decode_ptr(self, v):
        """Decode one on-disk pointer slot -> ('rebase', vmaddr) | ('bind', ordinal) | None."""
        if v == 0:
            return None
        fmt = self.ptr_format
        if fmt is None:
            return ("rebase", v)
        if fmt in (1, 9, 12):  # ARM64E, ARM64E_USERLAND, ARM64E_USERLAND24
            if (v >> 62) & 1:
                return ("bind", v & (0xFFFFFF if fmt == 12 else 0xFFFF))
            if (v >> 63) & 1:
                return ("rebase", self.base + (v & 0xFFFFFFFF))
            t = v & 0x7FFFFFFFFFF
            return ("rebase", t if fmt == 1 else self.base + t)
        if (v >> 63) & 1:  # DYLD_CHAINED_PTR_64 / 64_OFFSET bind
            return ("bind", v & 0xFFFFFF)
        t = v & 0xFFFFFFFFF
        return ("rebase", t if fmt == 2 else self.base + t)

    def _read_ptr_at_vm(self, addr):
        if addr in self.classic_binds:
            return ("symbol", self.classic_binds[addr])
        o = self.vm_to_off(addr)
        if o is None or o + 8 > len(self.data):
            return None
        return self._decode_ptr(struct.unpack_from("<Q", self.data, o)[0])

    def _string_at_vm(self, addr):
        o = self.vm_to_off(addr)
        if o is None:
            return None
        s = cstr(self.data, o, min(o + 512, len(self.data)))
        return s if s and re.match(r"^[\w.$<>:@-]+$", s) else None

    def _class_name_at(self, cls_addr):
        if cls_addr in self._class_cache:
            return self._class_cache[cls_addr]
        name = None
        data = self._read_ptr_at_vm(cls_addr + 32)
        if data and data[0] == "rebase":
            name_ptr = self._read_ptr_at_vm((data[1] & ~7) + 24)
            if name_ptr and name_ptr[0] == "rebase":
                name = self._string_at_vm(name_ptr[1])
        self._class_cache[cls_addr] = name
        return name

    def objc_classes(self):
        """[(class name, superclass name or None)] from __objc_classlist."""
        s = self.sections.get(("__DATA_CONST", "__objc_classlist")) or \
            self.sections.get(("__DATA", "__objc_classlist"))
        out = []
        if not s:
            return out
        addr, off, size = s
        for i in range(0, size, 8):
            p = self._decode_ptr(struct.unpack_from("<Q", self.data, off + i)[0])
            if not p or p[0] != "rebase":
                continue
            name = self._class_name_at(p[1])
            if not name:
                continue
            sup = self._read_ptr_at_vm(p[1] + 8)
            sname = None
            if sup and sup[0] == "symbol":
                sname = sup[1].replace("_OBJC_CLASS_$_", "")
            elif sup and sup[0] == "bind":
                if sup[1] < len(self.imports_ordered):
                    sname = self.imports_ordered[sup[1]].replace("_OBJC_CLASS_$_", "")
            elif sup and sup[0] == "rebase":
                sname = self._class_name_at(sup[1])
            out.append((demangle_objc_swift(name), demangle_objc_swift(sname) if sname else None))
        return out

    def objc_class_names(self):
        names = [n for n, _s in self.objc_classes()]
        # __objc_classname also stores ivar-layout byte strings (\x01\x11...),
        # so keep only identifier-like entries
        names += [n for n in cstrings(self.section("__TEXT", "__objc_classname"))
                  if re.match(r"^[A-Za-z_$][\w.$]*$", n)]
        return list(dict.fromkeys(demangle_objc_swift(n) for n in names))

    def objc_selectors(self):
        return cstrings(self.section("__TEXT", "__objc_methname"))

    def cstring_pool(self):
        return cstrings(self.section("__TEXT", "__cstring"))

    SWIFT_KINDS = {0: "module", 1: "extension", 2: "anonymous", 16: "class",
                   17: "struct", 18: "enum"}

    def swift_types(self):
        """Nominal Swift types from __swift5_types(2): [(kind, 'Module.Outer.Name')]."""
        out = []
        # __swift5_types2 holds extra descriptors newer toolchains split out
        for sect in ("__swift5_types", "__swift5_types2"):
            s = self.sections.get(("__TEXT", sect))
            if not s:
                continue
            addr, off, size = s
            for i in range(0, size - 3, 4):
                rel = struct.unpack_from("<i", self.data, off + i)[0]
                tgt = self._rel_target(addr + i, rel)
                if not tgt or tgt[0] != "local":
                    continue
                do = self.vm_to_off(tgt[1])
                if do is None or do + 4 > len(self.data):
                    continue
                kind = self.SWIFT_KINDS.get(struct.unpack_from("<I", self.data, do)[0] & 0x1F)
                if kind not in ("class", "struct", "enum"):
                    continue
                path = self._context_path(tgt[1])
                if path:
                    out.append((kind, path))
                    if kind == "class":
                        sup = self._swift_superclass(tgt[1], do)
                        if sup:
                            self.swift_supers[path] = sup
        return out

    def _swift_superclass(self, desc, do):
        """Superclass recorded in a Swift class descriptor (offset 20, a relative
        pointer to a mangled type name). Generic arguments are dropped, so
        `UIHostingController<Foo>` comes back as `SwiftUI.UIHostingController`.
        This covers classes with no static ObjC class object (generic superclass)."""
        if do + 24 > len(self.data):
            return None
        rel = struct.unpack_from("<i", self.data, do + 20)[0]
        if not rel:
            return None
        return self._symbolic_ref_path(desc + 20 + rel, 0)

    def _rel_target(self, field, rel):
        """Resolve a Swift relative pointer that may be indirect (low bit set).
        -> ('local', vmaddr) | ('external', 'Module.Name') | None"""
        if not rel & 1:
            return ("local", field + rel)
        return self._indirect_target(field + (rel & ~1))

    def _indirect_target(self, slot):
        """Follow a pointer slot (GOT entry) to a local descriptor or an import."""
        p = self._read_ptr_at_vm(slot)
        if not p:
            return None
        if p[0] == "rebase":
            return ("local", p[1])
        sym = p[1] if p[0] == "symbol" else (
            self.imports_ordered[p[1]] if p[1] < len(self.imports_ordered) else None)
        path = swift_symbol_path(sym) if sym else None
        return ("external", path) if path else None

    def _symbolic_ref_path(self, addr, depth):
        """Path of a mangled name that starts with a symbolic reference
        (\\x01 direct / \\x02 indirect to a context descriptor), else None."""
        o = self.vm_to_off(addr)
        if o is None or o + 5 > len(self.data):
            return None
        tag = self.data[o]
        if tag not in (1, 2):
            return swift_symbol_path(cstr(self.data, o, min(o + 256, len(self.data))))
        rel = struct.unpack_from("<i", self.data, o + 1)[0]
        # \x01: rel32 straight to the descriptor; \x02: rel32 to a pointer slot
        tgt = ("local", addr + 1 + rel) if tag == 1 else self._indirect_target(addr + 1 + rel)
        if not tgt:
            return None
        if tgt[0] == "external":
            return tgt[1]
        return self._context_path(tgt[1], depth + 1)

    def _context_path(self, desc, depth=0):
        """Dotted path of any context descriptor. Anonymous (private/fileprivate)
        contexts are transparent; an extension resolves to the type it extends."""
        if depth > 12:
            return None
        key = ("ctx", desc)
        if key in self._class_cache:
            return self._class_cache[key]
        self._class_cache[key] = None  # cycle guard
        do = self.vm_to_off(desc)
        if do is None or do + 12 > len(self.data):
            return None
        flags, prel, nrel = struct.unpack_from("<Iii", self.data, do)
        kind = self.SWIFT_KINDS.get(flags & 0x1F)
        if kind is None:
            return None
        parent = None
        if prel:
            pt = self._rel_target(desc + 4, prel)
            if pt and pt[0] == "external":
                parent = pt[1]
            elif pt:
                parent = self._context_path(pt[1], depth + 1)
        if kind == "anonymous":
            path = parent
        elif kind == "extension":
            path = self._symbolic_ref_path(desc + 8 + nrel, depth) or parent
        else:
            name_off = self.vm_to_off(desc + 8 + nrel)
            if name_off is None:
                return None
            name = cstr(self.data, name_off, min(name_off + 256, len(self.data)))
            if not name or not name.isprintable():
                return None
            path = name if kind == "module" or not parent else parent + "." + name
        self._class_cache[key] = path
        return path


def swift_symbol_path(sym):
    """Rough path of a simple Swift mangled type name or descriptor symbol:
    _$s10Foundation3URLVMn -> Foundation.URL, $sSo8NSObjectC -> __C.NSObject.
    Returns None for anything it can't read (generics, words substitutions)."""
    m = re.match(r"^_?\$s(.*)$", sym or "")
    rest = m.group(1) if m else (sym or "")
    if not re.match(r"^(So\d|s\d|[1-9])", rest):
        return None
    parts = []
    objc = rest.startswith("So")
    if objc:  # imported ObjC/C type: show the bare name (UIViewController)
        rest = rest[2:]
    elif rest.startswith("s") and rest[1:2].isdigit():  # stdlib module
        parts.append("Swift")
        rest = rest[1:]
    while rest:
        n = re.match(r"^(\d+)", rest)
        if not n:
            break
        ln = int(n.group(1))
        rest = rest[len(n.group(1)):]
        if len(rest) < ln:
            return None
        parts.append(rest[:ln])
        rest = rest[ln:]
        # skip the kind letter between nested components (C/V/O/P)
        if rest[:1] in ("C", "V", "O", "P") and rest[1:2].isdigit():
            rest = rest[1:]
    if not parts or (not objc and len(parts) < 2):
        return None
    return ".".join(parts)


def demangle_objc_swift(name):
    """_TtC6Deezer18NowPlayingViewController -> Deezer.NowPlayingViewController"""
    m = re.match(r"^_TtC(.*)$", name)
    if not m:
        return name
    rest, parts = m.group(1), []
    if rest.startswith("s"):
        parts.append("Swift")
        rest = rest[1:]
    while rest:
        n = re.match(r"^(\d+)", rest)
        if not n:
            break
        ln = int(n.group(1))
        rest = rest[len(n.group(1)):]
        parts.append(rest[:ln])
        rest = rest[ln:]
    return ".".join(parts) if parts else name


# --------------------------------------------------------------------------
# signatures
# --------------------------------------------------------------------------

AUDIO_PATHS = {
    "AudioUnit / RemoteIO (low level)": [
        "_AudioComponentFindNext", "_AudioComponentInstanceNew",
        "_AudioUnitSetProperty", "_AudioUnitRender", "_AudioOutputUnitStart",
        "_AudioUnitInitialize", "_AUGraphOpen", "_NewAUGraph", "_AUGraphStart",
    ],
    "AudioQueue": [
        "_AudioQueueNewOutput", "_AudioQueueNewOutputWithDispatchQueue",
        # NewInput = a recording queue; without NewOutput the queue is input-only
        "_AudioQueueNewInput", "_AudioQueueNewInputWithDispatchQueue",
        "_AudioQueueEnqueueBuffer", "_AudioQueueStart", "_AudioQueueAllocateBuffer",
    ],
    "AVAudioEngine": [
        "_OBJC_CLASS_$_AVAudioEngine", "_OBJC_CLASS_$_AVAudioPlayerNode",
        "_OBJC_CLASS_$_AVAudioSourceNode", "_OBJC_CLASS_$_AVAudioSinkNode",
        "_OBJC_CLASS_$_AVAudioUnitTimePitch", "_OBJC_CLASS_$_AVAudioUnitVarispeed",
        "_OBJC_CLASS_$_AVAudioUnitReverb", "_OBJC_CLASS_$_AVAudioUnitEQ",
        "_OBJC_CLASS_$_AVAudioMixerNode", "_OBJC_CLASS_$_AVAudioPCMBuffer",
        "_AVAudioEngineConfigurationChangeNotification",
    ],
    "AVPlayer": [
        "_OBJC_CLASS_$_AVPlayer", "_OBJC_CLASS_$_AVQueuePlayer",
        "_OBJC_CLASS_$_AVPlayerItem", "_OBJC_CLASS_$_AVURLAsset",
        "_OBJC_CLASS_$_AVMutableAudioMix", "_MTAudioProcessingTapCreate",
        "_OBJC_CLASS_$_AVPlayerLayer",
        "_AVAudioTimePitchAlgorithmVarispeed", "_AVAudioTimePitchAlgorithmSpectral",
    ],
    "AVSampleBufferAudioRenderer": [
        "_OBJC_CLASS_$_AVSampleBufferAudioRenderer",
        "_OBJC_CLASS_$_AVSampleBufferRenderSynchronizer",
    ],
    "Decoding / conversion": [
        "_AudioConverterNew", "_AudioConverterFillComplexBuffer", "_AudioConverterSetProperty",
        "_ExtAudioFileOpenURL", "_ExtAudioFileWrapAudioFileID", "_ExtAudioFileRead",
        "_AudioFileStreamOpen", "_AudioFileStreamParseBytes", "_AudioFileOpenWithCallbacks",
        "_OBJC_CLASS_$_AVAudioConverter", "_OBJC_CLASS_$_AVAssetReader",
        "_CMAudioSampleBufferCreateWithPacketDescriptions",
    ],
    "Audio session": [
        "_OBJC_CLASS_$_AVAudioSession", "_AVAudioSessionCategoryPlayback",
    ],
    "Now Playing info / remote commands": [
        "_OBJC_CLASS_$_MPNowPlayingInfoCenter", "_OBJC_CLASS_$_MPRemoteCommandCenter",
        "_MPMediaItemPropertyArtwork", "_OBJC_CLASS_$_MPMediaItemArtwork",
    ],
}

# strings that hint at a bundled/third-party audio stack
AUDIO_STRING_HINTS = [
    "libFLAC", "FLAC__stream_decoder", "mpg123", "minimp3", "dr_flac", "dr_mp3",
    "ffmpeg", "avcodec", "libavformat", "opus_decode", "ogg_sync", "Vorbis",
    "ExoPlayer", "Superpowered", "AudioKit", "kAudioUnitSubType_RemoteIO",
    "RemoteIO", "AUGraph", "crossfade", "Crossfade", "gapless", "Gapless",
    "replaygain", "ReplayGain", "normaliz", "Normaliz", "equalizer", "Equalizer",
]

UI_KEYWORDS = re.compile(
    r"(now.?playing|player|artwork|cover|fullscreen|full.?screen|mini.?player|"
    r"playback|queue|lyrics|audio|sound|equali[sz]er|crossfade|settings|"
    r"preferences|options)", re.I)

AUDIO_SELECTOR_HINTS = [
    "setRate:", "rate", "audioTimePitchAlgorithm", "setAudioTimePitchAlgorithm:",
    "setAudioMix:", "attachNode:", "connect:to:format:", "renderCallback",
    "enqueueSampleBuffer:", "setPlaybackRate:", "playbackRate", "setSpeed:",
    "playbackSpeed", "setPlaybackSpeed:",
    # AVAudioEngine graph building / scheduling
    "detachNode:", "connect:to:fromBus:toBus:format:", "disconnectNodeInput:",
    "mainMixerNode", "outputNode", "startAndReturnError:",
    "scheduleBuffer:completionHandler:", "scheduleBuffer:atTime:options:completionHandler:",
    "scheduleBuffer:completionCallbackType:completionHandler:",
    "scheduleFile:atTime:completionHandler:", "scheduleSegment:startingFrame:frameCount:atTime:completionHandler:",
    "installTapOnBus:bufferSize:format:block:", "setPitch:", "pitch",
    "setManualRenderingMode:", "enableManualRenderingMode:format:maximumFrameCount:error:",
]

RN_CLASSES = ["RCTBridge", "RCTRootView", "RCTSurfaceHostingView", "RCTAppDelegate",
              "RCTHost", "RCTReactNativeFactory"]
FLUTTER_CLASSES = ["FlutterViewController", "FlutterEngine"]

HERMES_MAGIC = struct.pack("<Q", 0x1F1903C103BC1FC6)


# --------------------------------------------------------------------------
# analysis
# --------------------------------------------------------------------------


def find_binaries(b, exe):
    names = b.names()
    bins = [("main", exe)]
    for n in names:
        parts = n.split("/")
        # Frameworks/X.framework/X
        if len(parts) == 3 and parts[0] == "Frameworks" and parts[1].endswith(".framework") \
                and parts[2] == parts[1][:-len(".framework")]:
            bins.append(("framework", n))
        elif len(parts) == 2 and parts[0] == "Frameworks" and parts[1].endswith(".dylib"):
            bins.append(("dylib", n))
        elif len(parts) == 3 and parts[0] == "PlugIns" and parts[1].endswith(".appex"):
            if parts[2] == parts[1][:-len(".appex")]:
                bins.append(("appex", n))
    # appex executables can differ from the folder name; read their Info.plist
    for n in names:
        parts = n.split("/")
        if len(parts) == 3 and parts[0] == "PlugIns" and parts[2] == "Info.plist":
            try:
                ex = plistlib.loads(b.read(n)).get("CFBundleExecutable")
            except Exception:
                ex = None
            cand = "PlugIns/%s/%s" % (parts[1], ex)
            if ex and b.exists(cand) and ("appex", cand) not in bins:
                bins.append(("appex", cand))
    return bins


def analyse(path, classes_out=None):
    b = Bundle(path)
    info = plistlib.loads(b.read("Info.plist"))
    exe = info.get("CFBundleExecutable")
    lines = []
    w = lines.append

    w("# Deezer IPA analysis (generated by tools/analyze_ipa.py)")
    w("")
    w("## Bundle")
    w("")
    for k in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
              "CFBundleVersion", "MinimumOSVersion", "UIBackgroundModes",
              "UIApplicationSceneManifest", "UIMainStoryboardFile", "UILaunchStoryboardName"):
        if k in info:
            v = info[k]
            if isinstance(v, dict):
                v = "present"
            w("- `%s`: %s" % (k, v))
    w("")

    binaries = find_binaries(b, exe)
    parsed = {}
    w("## Encryption")
    w("")
    w("| binary | kind | arch | size | cryptid |")
    w("|---|---|---|---|---|")
    all_decrypted = True
    for kind, rel in binaries:
        try:
            m = MachO(b.read(rel), rel)
        except Exception as e:  # keep going on odd files
            w("| `%s` | %s | ? | ? | parse error: %s |" % (rel, kind, e))
            continue
        if not m.ok:
            w("| `%s` | %s | not arm64 Mach-O | | |" % (rel, kind))
            continue
        parsed[rel] = (kind, m)
        cid = m.encryption[0] if m.encryption else "no LC_ENCRYPTION_INFO"
        if m.encryption and m.encryption[0] != 0:
            all_decrypted = False
        w("| `%s` | %s | %s | %.1f MB | %s |" % (rel, kind, m.arch_note,
                                                  b.size(rel) / 1e6, cid))
    w("")
    w("**Verdict:** %s" % ("all binaries decrypted (cryptid 0)" if all_decrypted
                           else "SOME BINARIES ARE STILL ENCRYPTED - re-dump before analysing"))
    w("")

    # ---------------- UI framework ----------------
    names = b.names()
    all_classes = {}
    swift_types = {}
    supers = {}  # class -> superclass, across all binaries
    for rel, (kind, m) in parsed.items():
        if kind == "appex":
            continue
        all_classes[rel] = m.objc_class_names()
        for c, sup in m.objc_classes():
            if sup:
                supers[c] = sup
        swift_types[rel] = m.swift_types()
    # Swift descriptors fill in classes the ObjC walk can't resolve (generic
    # superclasses, Swift-only classes); the ObjC chain wins where both exist
    for rel, (kind, m) in parsed.items():
        for c, sup in m.swift_supers.items():
            supers.setdefault(c, sup)

    def ancestry(c):
        chain, seen = [], set()
        while c in supers and c not in seen:
            seen.add(c)
            c = supers[c]
            chain.append(c)
        return chain

    UIKIT_ROOTS = ("UIViewController", "UIView", "UITableViewCell", "UICollectionViewCell",
                   "UINavigationController", "UITabBarController")
    uikit_subclasses = defaultdict(int)
    for rel, cls in all_classes.items():
        for c in cls:
            if any(r in UIKIT_ROOTS for r in ancestry(c)):
                uikit_subclasses[rel] += 1

    def label(c):
        a = ancestry(c)
        if not a:
            return c
        return "%s : %s" % (c, " > ".join(a[:4]))

    flat_classes = {c for v in all_classes.values() for c in v}
    rn_files = [n for n in names if n.endswith(".jsbundle") or n.endswith(".hbc")]
    hermes = []
    for n in rn_files:
        try:
            with_magic = b.read(n)[:8] == HERMES_MAGIC
        except Exception:
            with_magic = False
        if with_magic:
            hermes.append(n)
    rn_fw = [n for n in names if re.match(r"Frameworks/(React|hermes|RCT|Yoga|ReactNative)[^/]*\.framework/", n)]
    rn_cls = sorted(c for c in RN_CLASSES if c in flat_classes)
    fl_fw = sorted({n.split("/")[1] for n in names if re.match(r"Frameworks/(Flutter|App)\.framework/", n)})
    fl_cls = sorted(c for c in FLUTTER_CLASSES if c in flat_classes)

    swiftui_imports = defaultdict(int)
    hosting = defaultdict(int)
    uikit_link = []
    for rel, (kind, m) in parsed.items():
        if kind == "appex":
            continue
        for s in m.imports:
            if "7SwiftUI" in s:
                swiftui_imports[rel] += 1
                if "UIHostingController" in s or "19UIHostingController" in s:
                    hosting[rel] += 1
        if any(d.endswith("/UIKit") for d in m.dylibs):
            uikit_link.append(rel)

    struct_views = defaultdict(list)
    class_vcs = defaultdict(list)
    for rel, types in swift_types.items():
        for kind, name in types:
            if kind == "struct" and re.search(r"(View|Screen|Page)$", name):
                struct_views[rel].append(name)
    for rel, cls in all_classes.items():
        for c in cls:
            if re.search(r"ViewController$", c):
                class_vcs[rel].append(c)
    nibs = [n for n in names if n.endswith(".nib") or ".storyboardc/" in n]

    w("## UI framework")
    w("")
    w("- React Native: bundles=%s, hermes bytecode=%s, frameworks=%d files, classes=%s"
      % (rn_files or "none", hermes or "no", len(rn_fw), rn_cls or "none"))
    w("- Flutter: frameworks=%s, classes=%s" % (fl_fw or "none", fl_cls or "none"))
    w("- UIKit linked by: %s" % (", ".join("`%s`" % r for r in uikit_link) or "none"))
    w("- Nibs / storyboards: %d" % len(nibs))
    w("")
    w("| binary | ObjC-visible classes | UIKit subclasses (resolved) | *ViewController classes | SwiftUI imports | UIHostingController refs | Swift structs named *View/*Screen/*Page |")
    w("|---|---|---|---|---|---|---|")
    for rel in all_classes:
        w("| `%s` | %d | %d | %d | %d | %d | %d |" % (rel, len(all_classes[rel]), uikit_subclasses[rel],
                                                   len(class_vcs[rel]), swiftui_imports[rel], hosting[rel],
                                                   len(struct_views[rel])))
    w("")
    total_vc = sum(len(v) for v in class_vcs.values())
    total_sv = sum(len(v) for v in struct_views.values())
    total_su = sum(swiftui_imports.values())
    if rn_files or rn_cls:
        verdict = "React Native present (check how much of the UI it covers)"
    elif fl_fw or fl_cls:
        verdict = "Flutter present"
    elif total_su == 0:
        verdict = "UIKit only (no SwiftUI symbols imported)"
    elif total_vc > total_sv:
        verdict = "UIKit-first with some SwiftUI (%d VCs vs %d SwiftUI-style structs)" % (total_vc, total_sv)
    else:
        verdict = "SwiftUI-heavy (%d SwiftUI-style structs vs %d VCs)" % (total_sv, total_vc)
    w("**Verdict (heuristic):** %s" % verdict)
    w("")

    # ---------------- interesting classes ----------------
    w("## Player / Now Playing / artwork / settings candidates")
    w("")
    # generated GraphQL / analytics-schema types and Codable keys match the
    # keywords by the hundred but are never UI or audio; they stay in --classes
    noise = re.compile(r"(^(ApolloGenerated|TrackingPlan|XPlayerApollo)|\.CodingKeys$)")
    w("Generated `ApolloGenerated.*` / `TrackingPlan.*` / `XPlayerApollo*` types and "
      "`CodingKeys` are left out here; the `--classes` dump has everything.")
    w("")
    cap = 1500
    for rel in all_classes:
        hits = sorted({c for c in all_classes[rel] if UI_KEYWORDS.search(c) and not noise.search(c)})
        sw = sorted({n for _k, n in swift_types.get(rel, [])
                     if UI_KEYWORDS.search(n) and not noise.search(n)})
        sw = [n for n in sw if n not in set(hits)]
        if not hits and not sw:
            continue
        w("### `%s`" % rel)
        w("")
        if hits:
            w("ObjC-visible classes (%d):" % len(hits))
            w("")
            w("```")
            w("\n".join(label(c) for c in hits[:cap]))
            if len(hits) > cap:
                w("... %d more (see --classes output)" % (len(hits) - cap))
            w("```")
            w("")
        if sw:
            w("Swift-only nominal types (%d):" % len(sw))
            w("")
            w("```")
            w("\n".join(label(n) for n in sw[:cap]))
            if len(sw) > cap:
                w("... %d more (see --classes output)" % (len(sw) - cap))
            w("```")
            w("")

    # ---------------- audio ----------------
    w("## Audio playback path")
    w("")
    w("Imported symbols per binary (a hit means the binary calls/links it):")
    w("")
    audio_score = defaultdict(int)
    for rel, (kind, m) in parsed.items():
        rows = []
        for group, syms in AUDIO_PATHS.items():
            found = [s for s in syms if s in m.imports]
            if found:
                rows.append((group, found))
                audio_score[group] += len(found)
        if not rows:
            continue
        w("### `%s`" % rel)
        w("")
        for group, found in rows:
            w("- **%s**: %s" % (group, ", ".join("`%s`" % f for f in found)))
        sels = set(m.objc_selectors())
        sh = [s for s in AUDIO_SELECTOR_HINTS if s in sels]
        if sh:
            w("- selectors present: %s" % ", ".join("`%s`" % s for s in sh))
        pool = m.data
        hints = [h for h in AUDIO_STRING_HINTS if h.encode() in pool]
        if hints:
            w("- string hints: %s" % ", ".join("`%s`" % h for h in hints))
        w("")
    w("Overall hit counts: %s" % (", ".join("%s=%d" % kv for kv in sorted(audio_score.items(),
                                                                          key=lambda kv: -kv[1])) or "none"))
    w("")

    # ---------------- frameworks ----------------
    w("## Embedded frameworks")
    w("")
    fws = sorted({n.split("/")[1] for n in names if n.startswith("Frameworks/") and n.count("/") >= 1
                  and (n.split("/")[1].endswith(".framework") or n.split("/")[1].endswith(".dylib"))})
    for f in fws:
        w("- %s" % f)
    w("")

    if classes_out:
        with io.open(classes_out, "w", encoding="utf-8") as fh:
            for rel in all_classes:
                fh.write("## %s (ObjC-visible)\n" % rel)
                for c in sorted(set(all_classes[rel])):
                    fh.write(label(c) + "\n")
                fh.write("\n## %s (Swift nominal types)\n" % rel)
                for k, n in sorted(set(swift_types.get(rel, [])), key=lambda t: t[1]):
                    fh.write("%s %s\n" % (k, label(n) if k == "class" else n))
                fh.write("\n")

    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("-o", "--output", help="write the markdown report here (default: stdout)")
    ap.add_argument("--classes", help="also dump every class / Swift type name to this file")
    a = ap.parse_args()
    for out in (a.output, a.classes):
        if out and os.path.dirname(out):
            os.makedirs(os.path.dirname(out), exist_ok=True)
    report = analyse(a.path, a.classes)
    if a.output:
        with io.open(a.output, "w", encoding="utf-8") as fh:
            fh.write(report)
        print("wrote %s" % a.output)
    else:
        sys.stdout.reconfigure(encoding="utf-8") if hasattr(sys.stdout, "reconfigure") else None
        sys.stdout.write(report)


if __name__ == "__main__":
    main()
