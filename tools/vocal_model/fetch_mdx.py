#!/usr/bin/env python3
"""
UVR MDX-Net vocal models for Deezit's on-device benchmark (Settings -> Model
lab -> Run benchmark), re-hosted on the `vocal-model-mdx-v1` release.

Runs in CI (.github/workflows/vocal-model-mdx.yml) on a macOS runner.

Source: the Core ML (fp16 mlprogram, iOS 16) conversions in
huggingface.co/gyoom/UVR-MDX-CoreML (MIT), pinned to one revision. Their
weights come from the Ultimate Vocal Remover MDX-Net models by Anjok07
(UVR-MDXNET 9482) and Kimberley Jensen (UVR-MDX-NET Voc FT), MIT, via
github.com/TRvlvr/model_repo, mirrored at huggingface.co/Politrees/UVR_resources.

That repo verified its conversion against ONNX only before Core ML ("Core ML
predict: macOS-pending"). Here, on the Mac, its package came out at only
23 dB SNR against ONNX Runtime running the original UVR .onnx (random input).
So this script also converts the .onnx itself (onnx2torch -> coremltools,
fp16 and fp32), checks every candidate against ONNX Runtime on the same
realistic input (the STFT of a synthetic mix, as the phone would compute it),
and publishes the first fp16 candidate that clears the bar. Both models take the spectrogram (STFT outside the graph):

  input   "input"   fp16 [1, 4, dim_f, 256]   complex-as-channels L.re, L.im, R.re, R.im
  output  "output"  fp16 [1, 4, dim_f, 256]   the vocals' spectrogram (same layout)

  9482:   n_fft 4096, hop 1024, dim_f 2048 (the STFT Deezit already computes)
  Voc FT: n_fft 6144, hop 1024, dim_f 3072

256 frames at hop 1024 = 262144 samples, about 5.9 s at 44.1 kHz.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

import numpy as np

CORE_REPO, CORE_REV = "gyoom/UVR-MDX-CoreML", "aa27ab16896fdb298cdb73cceb76c950e7580c00"
ONNX_REPO, ONNX_REV = "Politrees/UVR_resources", "929e057b81aa49bc2e6490bef8671f47b2c120f6"
FRAMES, HOP, RATE = 256, 1024, 44100

MODELS = [
    # name, label, package in CORE_REPO, onnx in ONNX_REPO, n_fft, dim_f
    ("mdx9482", "MDX-Net 9482", "UVR_MDXNET_9482.mlpackage", "models/MDXNet/UVR_MDXNET_9482.onnx", 4096, 2048),
    ("mdxvocft", "MDX-Net Voc FT", "UVR-MDX-NET-Voc_FT.mlpackage", "models/MDXNet/UVR-MDX-NET-Voc_FT.onnx", 6144, 3072),
]
PACKAGE_FILES = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]


def fetch(repo, rev, path, dest):
    url = "https://huggingface.co/%s/resolve/%s/%s" % (repo, rev, path)
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "deezit-ci"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=300) as r, open(dest, "wb") as fh:
                shutil.copyfileobj(r, fh)
            return dest
        except OSError as e:          # connection resets happen; retry
            print("download %s failed (%s), retrying" % (path, e))
            time.sleep(10 * (attempt + 1))
    sys.exit("couldn't download %s" % url)


def music_like(length, seed=0):
    """Tones + transients + noise, stereo, about -12 dBFS."""
    rng = np.random.default_rng(seed)
    t = np.arange(length) / RATE
    y = np.zeros((2, length))
    for f, pan in ((110, 0.5), (220, 0.3), (330, 0.7), (523, 0.5), (659, 0.4), (1318, 0.6)):
        s = np.sin(2 * np.pi * f * t * (1 + 0.003 * np.sin(2 * np.pi * 5 * t)))
        y[0] += (1 - pan) * s * 0.08
        y[1] += pan * s * 0.08
    for start in range(0, length, 22050):
        n = min(3000, length - start)
        y[:, start:start + n] += rng.normal(0, 0.2, n) * np.exp(-np.arange(n) / 400)
    return y + rng.normal(0, 0.005, y.shape)


def spectrogram(wave, n_fft, dim_f):
    """UVR's MDX STFT: periodic Hann, centred with reflect padding, unnormalised,
    hop 1024, Nyquist dropped -> [1, 4, dim_f, FRAMES] as L.re, L.im, R.re, R.im."""
    win = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n_fft) / n_fft)
    out = np.zeros((1, 4, dim_f, FRAMES), np.float32)
    for c in range(2):
        x = np.pad(wave[c], n_fft // 2, mode="reflect")
        frames = np.stack([x[i * HOP:i * HOP + n_fft] * win for i in range(FRAMES)], axis=1)
        z = np.fft.rfft(frames, axis=0)[:dim_f]
        out[0, 2 * c] = z.real
        out[0, 2 * c + 1] = z.imag
    return out


def snr_db(ref, got):
    err = np.sum((ref.astype(np.float64) - got.astype(np.float64)) ** 2)
    return 10 * np.log10(np.sum(ref.astype(np.float64) ** 2) / max(err, 1e-30))


MEASURE = r"""
import resource, sys, time, numpy as np, coremltools as ct
path, F = sys.argv[1], int(sys.argv[2])
rss = lambda: resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576.0   # bytes on macOS
base = rss()
m = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_AND_NE)
loaded = rss()
x = {"input": (np.random.randn(1, 4, F, 256) * 0.5).astype(np.float16)}
m.predict(x)
t0 = time.time(); m.predict(x); dt = time.time() - t0
print("%.0f %.0f %.2f" % (loaded - base, rss() - base, dt))
"""


def convert_onnx(ct, onnx_file, dim_f, precision, out):
    import torch
    from onnx2torch import convert
    net = convert(onnx_file).eval()
    x = torch.zeros(1, 4, dim_f, FRAMES)
    traced = torch.jit.trace(net, x, check_trace=False)
    ml = ct.convert(traced, convert_to="mlprogram",
                    inputs=[ct.TensorType(name="input", shape=(1, 4, dim_f, FRAMES), dtype=np.float32)],
                    outputs=[ct.TensorType(name="output")],
                    compute_precision=precision, compute_units=ct.ComputeUnit.CPU_AND_NE,
                    minimum_deployment_target=ct.target.iOS16)
    ml.author = "UVR MDX-Net (Anjok07 / Kimberley Jensen), converted for Deezit"
    ml.license = "MIT"
    shutil.rmtree(out, ignore_errors=True)
    ml.save(out)
    return out


def diagnose(ct, onnx_file, x, ref, label):
    """Where does the conversion go wrong? PyTorch (onnx2torch) vs ONNX Runtime,
    then Core ML fp32 vs PyTorch at every layer: the first layers that differ."""
    import copy
    import torch
    from onnx2torch import convert
    from torch.fx import Interpreter

    gm = convert(onnx_file).eval()
    xt = torch.from_numpy(x)
    with torch.no_grad():
        tout = gm(xt).numpy()
    print("::notice title=%s diagnosis: PyTorch vs ONNX::SNR %.1f dB" % (label, snr_db(ref, tout)))

    vals = {}
    seen = {xt.data_ptr()}

    class Capture(Interpreter):
        def run_node(self, n):
            r = super().run_node(n)
            # skip pass-throughs (same storage as the input or an earlier layer):
            # Core ML can't have one variable as two outputs, or as input and output
            if (n.op.startswith("call_") and isinstance(r, torch.Tensor) and r.dim() >= 2 and r.is_floating_point()
                    and r.data_ptr() not in seen):
                seen.add(r.data_ptr())
                vals[n.name] = r.detach().numpy().copy()
            return r

    with torch.no_grad():
        Capture(gm).run(xt)
    order = [n for n in gm.graph.nodes if n.name in vals]
    info = {n.name: "%s %s" % (n.op, n.target if n.op != "call_module" else type(gm.get_submodule(n.target)).__name__ + " " + str(n.target))
            for n in order}
    g2 = copy.deepcopy(gm)
    keep = set(vals)
    sel = [n for n in g2.graph.nodes if n.name in keep]
    out = [n for n in g2.graph.nodes if n.op == "output"][0]
    out.args = (tuple(sel),)
    g2.graph.lint()
    g2.recompile()
    traced = torch.jit.trace(g2.eval(), xt, check_trace=False, strict=False)
    ml = ct.convert(traced, convert_to="mlprogram",
                    inputs=[ct.TensorType(name="input", shape=tuple(x.shape), dtype=np.float32)],
                    compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY,
                    minimum_deployment_target=ct.target.iOS16)
    names = [o.name for o in ml.get_spec().description.output]
    res = ml.predict({"input": x})
    rows = []
    for n, oname in zip(sel, names):
        want = vals[n.name]
        got = np.asarray(res[oname]).reshape(want.shape) if np.asarray(res[oname]).size == want.size else None
        db = snr_db(want, got) if got is not None else -999.0
        rows.append((n.name, info[n.name], tuple(want.shape), db))
    bad = [r for r in rows if r[3] < 60]
    lines = ["%d layers compared; %d below 60 dB" % (len(rows), len(bad))]
    for r in bad[:12]:
        lines.append("%s | %s | %s | %.1f dB" % r)
    if bad:
        i = rows.index(bad[0])
        lines.append("before the first bad one:")
        for r in rows[max(0, i - 3):i]:
            lines.append("%s | %s | %s | %.1f dB" % r)
    if bad:
        # the graph from the last good layer to the first bad one, with each module
        names_all = [n.name for n in gm.graph.nodes]
        good_before = rows[rows.index(bad[0]) - 1][0] if rows.index(bad[0]) > 0 else names_all[0]
        a_i, b_i = names_all.index(good_before), names_all.index(bad[0][0])
        lines.append("graph %s .. %s:" % (good_before, bad[0][0]))
        for n in list(gm.graph.nodes)[a_i:b_i + 1]:
            mod = repr(gm.get_submodule(n.target)) if n.op == "call_module" else n.target
            lines.append("  %s = %s %s(%s)" % (n.name, n.op, str(mod).replace("\n", " ")[:160], ", ".join(str(x) for x in n.args)[:120]))
        # the first bad layer alone: its PyTorch input -> Core ML fp32 vs PyTorch
        node = [n for n in gm.graph.nodes if n.name == bad[0][0]][0]
        if node.op == "call_module" and len(node.args) == 1 and hasattr(node.args[0], "name"):
            src = node.args[0].name
            full = {}

            class All(Interpreter):
                def run_node(self, n):
                    r = super().run_node(n)
                    if isinstance(r, torch.Tensor):
                        full[n.name] = r.detach().clone()
                    return r

            with torch.no_grad():
                All(gm).run(xt)
            if src in full:
                inp = full[src].contiguous()
                mod = gm.get_submodule(node.target).eval()
                with torch.no_grad():
                    want = mod(inp).numpy()
                one = ct.convert(torch.jit.trace(mod, inp), convert_to="mlprogram",
                                 inputs=[ct.TensorType(name="x", shape=tuple(inp.shape), dtype=np.float32)],
                                 compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY,
                                 minimum_deployment_target=ct.target.iOS16)
                got1 = list(one.predict({"x": inp.numpy()}).values())[0]
                lines.append("%s alone (its PyTorch input, Core ML fp32): %.1f dB; input %s contiguous-in-graph %s" % (
                    node.name, snr_db(want, np.asarray(got1).reshape(want.shape)), tuple(inp.shape), full[src].is_contiguous()))
    text = "\n".join(lines)
    print(text)
    print("::notice title=%s diagnosis: Core ML fp32 vs PyTorch per layer::%s" % (label, text.replace("%", "%25").replace("\n", "%0A")))


def check(ct, pkg, x, ref, units):
    ml = ct.models.MLModel(pkg, compute_units=units)
    dtype = np.float16 if ml.get_spec().description.input[0].type.multiArrayType.dataType == 65552 else np.float32
    got = np.asarray(ml.predict({"input": x.astype(dtype)})["output"]).astype(np.float32).reshape(ref.shape)
    return snr_db(ref, got) if np.isfinite(got).all() else -999.0


def main():
    import coremltools as ct
    import onnxruntime as ort

    fetch(CORE_REPO, CORE_REV, "LICENSE", "LICENSE-UVR-MDX-CoreML.txt")
    rng = np.random.default_rng(0)
    entries = []
    for name, label, package, onnx_path, n_fft, dim_f in MODELS:
        print("== %s (%s)" % (label, package))
        pkg = "DeezitMDX-%s.mlpackage" % name
        shutil.rmtree(pkg, ignore_errors=True)
        for f in PACKAGE_FILES:
            fetch(CORE_REPO, CORE_REV, "%s/%s" % (package, f), os.path.join(pkg, f))
        onnx_file = fetch(ONNX_REPO, ONNX_REV, onnx_path, os.path.basename(onnx_path))

        sess = ort.InferenceSession(onnx_file, providers=["CPUExecutionProvider"])
        oname = sess.get_inputs()[0].name
        print("ONNX input %s %s" % (oname, sess.get_inputs()[0].shape))
        # the phone's input: the STFT of a mix, rounded to fp16 (what fp16 I/O sees)
        x = spectrogram(music_like(FRAMES * HOP + n_fft), n_fft, dim_f).astype(np.float16).astype(np.float32)
        print("input |x| max %.1f, rms %.2f" % (np.abs(x).max(), np.sqrt((x ** 2).mean())))
        ref = sess.run(None, {oname: x})[0]

        ours16 = convert_onnx(ct, onnx_file, dim_f, ct.precision.FLOAT16, "ours16-" + pkg)
        ours32 = convert_onnx(ct, onnx_file, dim_f, ct.precision.FLOAT32, "ours32-" + pkg)
        results = {}
        for tag, path in (("gyoom fp16", pkg), ("ours fp16", ours16), ("ours fp32", ours32)):
            for units_name, units in (("CPU", ct.ComputeUnit.CPU_ONLY), ("CPU+NE", ct.ComputeUnit.CPU_AND_NE)):
                results[(tag, units_name)] = check(ct, path, x, ref, units)
        summary = ", ".join("%s on %s %.1f dB" % (t, u, v) for (t, u), v in results.items())
        print("::notice title=%s vs ONNX (SNR)::%s" % (label, summary))
        onnx_file_kept = onnx_file

        # first fp16 candidate whose worst case clears the bar
        chosen = None
        for tag, path in (("gyoom fp16", pkg), ("ours fp16", ours16)):
            worst = min(results[(tag, "CPU")], results[(tag, "CPU+NE")])
            if worst >= 35:
                chosen = (tag, path, worst)
                break
        if not chosen:
            try:
                diagnose(ct, onnx_file_kept, x, ref, label)
            except Exception as e:
                print("::warning title=%s diagnosis failed::%s: %s" % (label, type(e).__name__, str(e)[:800].replace("\n", " ")))
            sys.exit("%s: no fp16 Core ML version stays within 35 dB of ONNX: %s" % (label, summary))
        print("::notice title=%s chosen::%s (worst %.1f dB)" % (label, chosen[0], chosen[2]))
        if chosen[1] != pkg:
            shutil.rmtree(pkg)
            shutil.move(chosen[1], pkg)
        for extra in (ours16, ours32):
            shutil.rmtree(extra, ignore_errors=True)
        os.remove(onnx_file)

        r = subprocess.run([sys.executable, "-c", MEASURE, pkg, str(dim_f)], capture_output=True, text=True)
        entry = {"name": name, "label": label, "seconds": round(FRAMES * HOP / RATE, 3), "frames": FRAMES,
                 "bins": dim_f, "n_fft": n_fft, "hop": HOP, "step_fraction": 0.25,
                 "source": ("%s@%s/%s" % (CORE_REPO, CORE_REV[:7], package)) if chosen[0].startswith("gyoom")
                           else ("converted from %s@%s/%s" % (ONNX_REPO, ONNX_REV[:7], onnx_path)),
                 "snr_vs_onnx_db": round(chosen[2], 1)}
        if r.returncode == 0:
            load_mb, run_mb, secs = r.stdout.split()[-3:]
            entry["runner_load_mb"], entry["runner_run_mb"] = float(load_mb), float(run_mb)
            print("::notice title=%s on the runner (Mac CPU+NE)::load +%s MB, load + run +%s MB, %s s per run" % (label, load_mb, run_mb, secs))
        else:
            print("::warning title=%s runner measurement::%s" % (label, (r.stderr or "")[-400:].replace("\n", " ")))

        archive = pkg + ".aar"
        subprocess.run(["aa", "archive", "-d", pkg, "-o", archive], check=True)
        entry["file"] = archive
        entry["bytes"] = os.path.getsize(archive)
        entry["sha256"] = hashlib.sha256(open(archive, "rb").read()).hexdigest()
        print("::notice title=%s model::%s %.1f MB" % (label, archive, entry["bytes"] / 1e6))
        entries.append(entry)

    meta = {
        "model": "uvr-mdx-net", "format": "aar-mlpackage-per-window", "sample_rate": RATE,
        "licence": "MIT (UVR MDX-Net by Anjok07 and Kimberley Jensen; see LICENSE-UVR-MDX-CoreML.txt)",
        "functions": entries, "bytes": sum(e["bytes"] for e in entries),
    }
    with open("DeezitMDX.json", "w") as fh:
        json.dump(meta, fh, indent=1)


if __name__ == "__main__":
    main()
