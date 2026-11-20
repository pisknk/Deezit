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
predict: macOS-pending"), so this script does the Core ML check on the Mac:
each package's output against ONNX Runtime running the original UVR .onnx, on
the same input. Both models take the spectrogram (STFT outside the graph):

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
    with urllib.request.urlopen(req, timeout=300) as r, open(dest, "wb") as fh:
        shutil.copyfileobj(r, fh)
    return dest


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

        ml = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.CPU_ONLY)
        spec = ml.get_spec()
        ins = [(i.name, list(i.type.multiArrayType.shape)) for i in spec.description.input]
        outs = [(o.name, list(o.type.multiArrayType.shape)) for o in spec.description.output]
        print("Core ML inputs %s outputs %s, %s" % (ins, outs, spec.WhichOneof("Type")))
        if ins != [("input", [1, 4, dim_f, FRAMES])] or [o[0] for o in outs] != ["output"]:
            sys.exit("%s: unexpected inputs/outputs %s %s" % (name, ins, outs))

        # a spectrogram-like input: louder low bins, falling off with frequency
        x = rng.standard_normal((1, 4, dim_f, FRAMES)) * (2.0 / (1 + np.arange(dim_f) / 64.0))[None, None, :, None]
        x16 = x.astype(np.float16)
        sess = ort.InferenceSession(onnx_file, providers=["CPUExecutionProvider"])
        oname = sess.get_inputs()[0].name
        print("ONNX input %s %s" % (oname, sess.get_inputs()[0].shape))
        ref = sess.run(None, {oname: x16.astype(np.float32)})[0]
        got = np.asarray(ml.predict({"input": x16})["output"]).reshape(ref.shape)
        if not np.isfinite(got).all():
            sys.exit("%s: Core ML output has NaN / inf" % name)
        snr = snr_db(ref, got)
        print("::notice title=%s Core ML vs ONNX::SNR %.1f dB (fp16 package vs the original UVR .onnx, same input)" % (label, snr))
        if snr < 40:
            sys.exit("%s: Core ML differs from the original ONNX model (SNR %.1f dB, need >= 40)" % (name, snr))
        os.remove(onnx_file)

        r = subprocess.run([sys.executable, "-c", MEASURE, pkg, str(dim_f)], capture_output=True, text=True)
        entry = {"name": name, "label": label, "seconds": round(FRAMES * HOP / RATE, 3), "frames": FRAMES,
                 "bins": dim_f, "n_fft": n_fft, "hop": HOP, "step_fraction": 0.25,
                 "source": "%s@%s/%s" % (CORE_REPO, CORE_REV[:7], package)}
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
        "licence": "MIT (UVR MDX-Net by Anjok07 and Kimberley Jensen; Core ML conversion by gyoom) - see LICENSE-UVR-MDX-CoreML.txt",
        "functions": entries, "bytes": sum(e["bytes"] for e in entries),
    }
    with open("DeezitMDX.json", "w") as fh:
        json.dump(meta, fh, indent=1)


if __name__ == "__main__":
    main()
