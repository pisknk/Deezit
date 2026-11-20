#!/usr/bin/env python3
"""
Experimental "Sing" model: the vocals model of Demucs' htdemucs_ft
(Hybrid Transformer Demucs, Meta, MIT licence) -> Core ML, for Deezit's
on-device benchmark (Settings -> HT-Demucs -> Run benchmark).

Runs in CI (.github/workflows/vocal-model-htdemucs.yml) on a macOS runner.

The network is cut at the spectrogram, so the STFT / iSTFT (complex numbers,
which Core ML can't take) stay on the phone, where Deezit already computes a
4096 / 1024 STFT:

  inputs   mix          float32 [1, 2, 343980]        stereo window, 7.8 s @ 44.1 kHz
           spec         float32 [1, 4, 2048, 336]     Demucs' _spec(mix) as complex-as-
                                                      channels: L.re, L.im, R.re, R.im
  outputs  vocals_spec  float32 [1, 4, 2048, 336]     spectral branch, same layout
           vocals_wave  float32 [1, 2, 343980]        time branch

  vocals = vocals_wave + _ispec(complex(vocals_spec), 343980)

The script checks that this split reproduces the full model's vocals exactly,
then that Core ML (mlprogram, fp16, CPU + Neural Engine) stays close to
PyTorch, and packs the .mlpackage as one Apple Archive the tweak downloads.
"""

import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
import time

import numpy as np
import torch

SIG = "04573f0d"            # htdemucs_ft's vocals model (row [0, 0, 0, 1] of its bag weights)


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="DeezitDemucs.mlpackage")
    a = ap.parse_args()

    # nn.MultiheadAttention's fused fast path doesn't convert; use the plain ops
    if hasattr(torch.backends, "mha"):
        torch.backends.mha.set_fastpath_enabled(False)

    model = load_vocals_model()
    L = int(model.segment * model.samplerate)
    mix = music_like(L)
    with torch.no_grad():
        z = model._spec(mix)
        spec = model._magnitude(z)
    T, F = spec.shape[-1], spec.shape[-2]
    print("window %d samples, spec %s" % (L, tuple(spec.shape)))

    core = Core(model).eval()
    with torch.no_grad():
        full = model(mix)[0, model.sources.index("vocals")]
        vs, vw = core(mix, spec)
        out = vs.view(1, 1, 2, 2, F, T).permute(0, 1, 2, 4, 5, 3).contiguous()
        zout = torch.view_as_complex(out)[:, 0]
        rebuilt = vw[0] + model._ispec(zout, L)[0]
    err = (full - rebuilt).abs().max().item()
    print("split check: full model vs core + iSTFT, max |diff| %.2e" % err)
    print("::notice title=split check::max |diff| %.2e" % err)
    if err > 1e-3:
        sys.exit("the split doesn't reproduce the model")

    import coremltools as ct
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
        minimum_deployment_target=ct.target.iOS16,
    )
    print("converted in %.0f s" % (time.time() - t0))
    ml.short_description = "Demucs htdemucs_ft vocals model (Meta, MIT), split at the spectrogram, for Deezit Sing"
    ml.author = "Meta AI (Demucs); converted for Deezit"
    ml.license = "MIT"
    ml.save(a.out)

    if sys.platform == "darwin":
        t0 = time.time()
        res = ml.predict({"mix": mix.numpy(), "spec": spec.numpy()})
        print("Core ML predict on the runner: %.2f s" % (time.time() - t0))
        print("::notice title=runner predict::%.2f s per 7.8 s window (Mac, not the phone)" % (time.time() - t0))
        got = {}
        for name, want in (("vocals_spec", vs), ("vocals_wave", vw)):
            got[name] = np.asarray(res[name]).reshape(want.shape).astype(np.float32)
            w = want.numpy()
            rel = np.abs(got[name] - w).mean() / (np.abs(w).mean() + 1e-9)
            # relative to the output itself: inflated when the input has little voice (fp16 noise / tiny signal)
            print("::notice title=Core ML vs PyTorch %s::mean error %.3f of the output's own level" % (name, rel))
            if not np.isfinite(got[name]).all():
                sys.exit("Core ML output has NaN / inf (%s)" % name)
        # What matters is what you'd hear: the rebuilt vocals' error against the mix level
        with torch.no_grad():
            spec_ml = torch.from_numpy(got["vocals_spec"]).view(1, 1, 2, 2, F, T).permute(0, 1, 2, 4, 5, 3).contiguous()
            vocals_ml = torch.from_numpy(got["vocals_wave"])[0] + model._ispec(torch.view_as_complex(spec_ml)[:, 0], L)[0]
        err_db = 20 * math.log10(float((vocals_ml - rebuilt).pow(2).mean().sqrt()) / float(mix.pow(2).mean().sqrt()) + 1e-12)
        print("::notice title=Core ML vs PyTorch rebuilt vocals::error %.1f dB below the mix" % -err_db)
        if err_db > -26:
            sys.exit("Core ML rebuilt vocals differ from PyTorch by %.1f dB of the mix (need <= -26 dB)" % err_db)

    archive = a.out + ".aar"
    subprocess.run(["aa", "archive", "-d", a.out, "-o", archive], check=True)
    digest = hashlib.sha256(open(archive, "rb").read()).hexdigest()
    meta = {
        "model": "htdemucs_ft-vocals", "signature": SIG, "file": os.path.basename(archive), "format": "aar-mlpackage",
        "samples": L, "frames": T, "bins": F, "n_fft": model.nfft, "hop": model.hop_length, "sample_rate": model.samplerate,
        "inputs": {"mix": list(mix.shape), "spec": list(spec.shape)},
        "outputs": {"vocals_spec": list(spec.shape), "vocals_wave": list(mix.shape)},
        "bytes": os.path.getsize(archive), "sha256": digest,
    }
    with open("DeezitDemucs.json", "w") as fh:
        json.dump(meta, fh, indent=1)
    print("wrote %s (%.1f MB), sha256 %s" % (archive, os.path.getsize(archive) / 1e6, digest))
    print("::notice title=model::%s %.1f MB" % (os.path.basename(archive), os.path.getsize(archive) / 1e6))


if __name__ == "__main__":
    main()
