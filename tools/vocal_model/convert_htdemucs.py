#!/usr/bin/env python3
"""
Experimental "Sing" model: the vocals model of Demucs' htdemucs_ft
(Hybrid Transformer Demucs, Meta, MIT licence) -> Core ML, for Deezit's
on-device benchmark (Settings -> HT-Demucs -> Run benchmark).

Runs in CI (.github/workflows/vocal-model-htdemucs.yml) on a macOS runner.

The network is cut at the spectrogram, so the STFT / iSTFT (complex numbers,
which Core ML can't take) stay on the phone, where Deezit already computes a
4096 / 1024 STFT. Per window of L samples (T = ceil(L / 1024) frames):

  inputs   mix          float32 [1, 2, L]             stereo window @ 44.1 kHz
           spec         float32 [1, 4, 2048, T]       Demucs' _spec(mix) as complex-as-
                                                      channels: L.re, L.im, R.re, R.im
  outputs  vocals_spec  float32 [1, 4, 2048, T]       spectral branch, same layout
           vocals_wave  float32 [1, 2, L]             time branch

  vocals = vocals_wave + _ispec(complex(vocals_spec), L)

Window length. Demucs runs this model on 7.8 s windows, but on an iPhone 13
loading that took ~2.2 GB and got Deezer killed: the cross-transformer attends
over every frequency x time position of the window, so its memory grows with
the square of the window. So there is one Core ML model per shorter window
(2.6 and 3.9 s; separate packages, since the phone refused a multifunction
one), and the phone's benchmark tries them shortest first. Shorter windows are
not how Demucs was trained, so their quality still has to be judged.

Checks: Core ML (fp16) stays close to PyTorch for every window (the exact
split check needs 7.8 s, the only length the full model runs at; it passed
there in earlier runs). The runner's memory for loading + running each function is reported
(Mac CPU, so only a rough guide for the phone).
"""

import argparse
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import time

import numpy as np
import torch

SIG = "04573f0d"            # htdemucs_ft's vocals model (row [0, 0, 0, 1] of its bag weights)
WINDOWS = (("w26", 2.6), ("w39", 3.9))   # 7.8 s (the training segment) needed ~2.2 GB on an iPhone 13


def load_vocals_model():
    from demucs.pretrained import get_model
    from demucs.apply import BagOfModels
    m = get_model(SIG)
    if isinstance(m, BagOfModels):
        m = m.models[0]
    m.eval()
    assert list(m.sources) == ["drums", "bass", "other", "vocals"], m.sources
    print("model %s: %s, %.1f M parameters, segment %s s, nfft %d, hop %d, cac %s" % (
        SIG, type(m).__name__, sum(p.numel() for p in m.parameters()) / 1e6,
        m.segment, m.nfft, m.hop_length, m.cac))
    return m


class Core(torch.nn.Module):
    """HTDemucs.forward from the magnitude on, vocals only (htdemucs.py, eval, no padding)."""

    def __init__(self, model):
        super().__init__()
        self.m = model
        self.vocals = model.sources.index("vocals")

    def forward(self, mix, spec):
        m = self.m
        x = spec
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = m.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)

        S = len(m.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]
        xt = xt.view(B, S, -1, mix.shape[-1])
        xt = xt * stdt[:, None] + meant[:, None]
        return x[:, self.vocals], xt[:, self.vocals]


def music_like(length, seed=0):
    """Something with structure (tones + transients + noise), not pure noise."""
    rng = np.random.default_rng(seed)
    t = np.arange(length) / 44100.0
    y = np.zeros((2, length))
    for f, pan in ((110, 0.5), (220, 0.3), (330, 0.7), (523, 0.5), (659, 0.4)):
        s = np.sin(2 * np.pi * f * t * (1 + 0.003 * np.sin(2 * np.pi * 5 * t)))
        y[0] += (1 - pan) * s * 0.08
        y[1] += pan * s * 0.08
    for start in range(0, length, 22050):
        n = min(3000, length - start)
        burst = rng.normal(0, 0.2, n) * np.exp(-np.arange(n) / 400)
        y[:, start:start + n] += burst
    y += rng.normal(0, 0.005, y.shape)
    return torch.from_numpy(y.astype(np.float32))[None]


def rebuild(model, vs, vw, F, T, L):
    out = vs.view(1, 1, 2, 2, F, T).permute(0, 1, 2, 4, 5, 3).contiguous()
    return vw[0] + model._ispec(torch.view_as_complex(out)[:, 0], L)[0]


def convert_window(model, ct, name, seconds):
    train = int(model.segment * model.samplerate)
    L = train if seconds is None else int(round(seconds * model.samplerate))
    mix = music_like(L)
    with torch.no_grad():
        spec = model._magnitude(model._spec(mix))
    T, F = spec.shape[-1], spec.shape[-2]
    print("== %s: %d samples (%.2f s), spec %s" % (name, L, L / model.samplerate, tuple(spec.shape)))

    core = Core(model).eval()
    with torch.no_grad():
        vs, vw = core(mix, spec)
        rebuilt = rebuild(model, vs, vw, F, T, L)
        if L == train:   # the full model pads shorter inputs to 7.8 s, so it's only comparable here
            full = model(mix)[0, model.sources.index("vocals")]
            err = (full - rebuilt).abs().max().item()
            print("::notice title=split check::max |diff| %.2e" % err)
            if err > 1e-3:
                sys.exit("the split doesn't reproduce the model")

    traced = torch.jit.trace(core, (mix, spec), check_trace=False)
    t0 = time.time()
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=tuple(mix.shape), dtype=np.float32),
                ct.TensorType(name="spec", shape=tuple(spec.shape), dtype=np.float32)],
        outputs=[ct.TensorType(name="vocals_spec"), ct.TensorType(name="vocals_wave")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        # iOS 16 like the first HT-Demucs model, which the phone loaded. (iOS 18
        # multifunction packages were refused on the phone: "This MLModel doesn't
        # support the multi-function description syntax".)
        minimum_deployment_target=ct.target.iOS16,
    )
    print("converted in %.0f s" % (time.time() - t0))
    path = "DeezitDemucs-%s.mlpackage" % name
    shutil.rmtree(path, ignore_errors=True)
    ml.save(path)

    if sys.platform == "darwin":
        res = ml.predict({"mix": mix.numpy(), "spec": spec.numpy()})
        got = {}
        for key, want in (("vocals_spec", vs), ("vocals_wave", vw)):
            got[key] = np.asarray(res[key]).reshape(want.shape).astype(np.float32)
            if not np.isfinite(got[key]).all():
                sys.exit("Core ML output has NaN / inf (%s %s)" % (name, key))
        with torch.no_grad():
            vocals_ml = rebuild(model, torch.from_numpy(got["vocals_spec"]), torch.from_numpy(got["vocals_wave"]), F, T, L)
        err_db = 20 * math.log10(float((vocals_ml - rebuilt).pow(2).mean().sqrt()) / float(mix.pow(2).mean().sqrt()) + 1e-12)
        print("::notice title=%s Core ML vs PyTorch::rebuilt vocals differ %.1f dB below the mix" % (name, -err_db))
        if err_db > -26:
            sys.exit("%s: Core ML rebuilt vocals differ from PyTorch by %.1f dB of the mix (need <= -26 dB)" % (name, err_db))
    del ml
    return {"name": name, "seconds": round(L / model.samplerate, 3), "samples": L, "frames": T, "bins": F, "path": path}


# Loads one window's model the way the phone does (from the package) and runs it.
MEASURE = r"""
import resource, sys, time, numpy as np, coremltools as ct
path, L, T = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rss = lambda: resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1048576.0   # bytes on macOS
base = rss()
m = ct.models.MLModel(path, compute_units=ct.ComputeUnit.CPU_AND_NE)
loaded = rss()
x = {"mix": np.random.rand(1, 2, L).astype(np.float32) * 0.2, "spec": np.random.rand(1, 4, 2048, T).astype(np.float32)}
m.predict(x)
t0 = time.time(); m.predict(x); dt = time.time() - t0
print("%.0f %.0f %.2f" % (loaded - base, rss() - base, dt))
"""


def main():
    ap = argparse.ArgumentParser()
    ap.parse_args()

    # nn.MultiheadAttention's fused fast path doesn't convert; use the plain ops
    if hasattr(torch.backends, "mha"):
        torch.backends.mha.set_fastpath_enabled(False)

    import coremltools as ct
    model = load_vocals_model()
    windows = []
    for name, seconds in WINDOWS:
        w = convert_window(model, ct, name, seconds)
        package = w.pop("path")
        if sys.platform == "darwin":
            r = subprocess.run([sys.executable, "-c", MEASURE, package, str(w["samples"]), str(w["frames"])],
                               capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit("%s: loading the saved model failed: %s" % (name, (r.stderr or "")[-1500:]))
            load_mb, run_mb, secs = r.stdout.split()[-3:]
            w["runner_load_mb"], w["runner_run_mb"] = float(load_mb), float(run_mb)
            print("::notice title=%s on the runner (Mac CPU)::%s s window: load +%s MB, load + run +%s MB, %s s per run" % (
                name, w["seconds"], load_mb, run_mb, secs))
        archive = package + ".aar"
        subprocess.run(["aa", "archive", "-d", package, "-o", archive], check=True)
        w["file"] = archive
        w["bytes"] = os.path.getsize(archive)
        w["sha256"] = hashlib.sha256(open(archive, "rb").read()).hexdigest()
        print("::notice title=%s model::%s %.1f MB" % (name, archive, w["bytes"] / 1e6))
        windows.append(w)

    meta = {
        "model": "htdemucs_ft-vocals", "signature": SIG, "format": "aar-mlpackage-per-window",
        "n_fft": model.nfft, "hop": model.hop_length, "sample_rate": model.samplerate,
        "functions": windows,
        "bytes": sum(w["bytes"] for w in windows),
    }
    with open("DeezitDemucs.json", "w") as fh:
        json.dump(meta, fh, indent=1)


if __name__ == "__main__":
    main()
