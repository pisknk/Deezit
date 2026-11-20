#!/usr/bin/env python3
"""
Builds Deezit's "Sing" model: Spleeter 2-stems (Deezer Research, MIT licence)
-> one Core ML file the tweak downloads (DeezitVocals.mlmodel).

Runs in CI (.github/workflows/vocal-model.yml) on a macOS runner:

  python tools/vocal_model/convert.py --checkpoint 2stems --out DeezitVocals.mlmodel

Steps
  1. read Spleeter's TensorFlow checkpoint (tf.train.load_checkpoint only)
  2. rebuild both U-Nets (vocals, accompaniment) in PyTorch, layer by layer
     as in spleeter/model/functions/unet.py, and load the weights, checking
     every shape
  3. parity test: the same U-Net built with Keras layers (TF 'same' padding,
     NHWC) against the PyTorch one on random input, so a padding / layout
     mistake fails the build instead of producing noise on the phone
  4. sanity test: a synthetic sung vowel should come out mostly "vocals"
  5. convert to a Core ML neural network (single .mlmodel file, fp16 weights)
     and check it against PyTorch with Core ML itself

Model contract (DZVocalModel.h / DZSeparator.m):
  input  "magnitude"  float32 [1, 2, 128, 1024]  |STFT| (frame 4096, hop 1024,
                                                 periodic Hann, unnormalised),
                                                 channels L/R, time, bins 0..1023
  output "vocal_mask" float32 [1, 2, 128, 1024]  v^2 / (v^2 + a^2), Spleeter's
                                                 ratio mask (separation exponent 2)
"""

import argparse
import glob
import hashlib
import json
import os
import re
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

T, FBINS = 128, 1024
ENC = [2, 16, 32, 64, 128, 256, 512]
DEC_IN = [512, 512, 256, 128, 64, 32]
DEC_OUT = [256, 128, 64, 32, 16, 1]
BN_EPS = 1e-3     # Keras BatchNormalization default, as Spleeter uses it


# --------------------------------------------------------------------------
# PyTorch U-Net (NCHW: [batch, stereo, time, freq])
# --------------------------------------------------------------------------

class UNet(nn.Module):
    """Spleeter's U-Net; returns the sigmoid mask (before the multiply by the input)."""

    def __init__(self):
        super().__init__()
        self.convs = nn.ModuleList([nn.Conv2d(ENC[i], ENC[i + 1], 5, stride=2) for i in range(6)])
        self.enc_bn = nn.ModuleList([nn.BatchNorm2d(ENC[i + 1], eps=BN_EPS) for i in range(6)])
        self.deconvs = nn.ModuleList([nn.ConvTranspose2d(DEC_IN[i], DEC_OUT[i], 5, stride=2) for i in range(6)])
        self.dec_bn = nn.ModuleList([nn.BatchNorm2d(DEC_OUT[i], eps=BN_EPS) for i in range(6)])
        self.final = nn.Conv2d(1, 2, 4, dilation=2, padding=3)

    def forward(self, x):
        skips = []
        h = x
        for i in range(6):
            # TF 'same' with stride 2 on even sizes pads 1 before, 2 after
            c = self.convs[i](F.pad(h, (1, 2, 1, 2)))
            skips.append(c)                    # skip connections use the conv output (pre-BN)
            h = F.leaky_relu(self.enc_bn[i](c), 0.2)
        h = skips[5]                           # the decoder starts from conv6, pre-BN
        for i in range(6):
            u = self.deconvs[i](h)[:, :, 1:-2, 1:-2]   # TF 'same' transposed conv: 2n+3 -> 2n
            u = self.dec_bn[i](F.relu(u))
            h = torch.cat([skips[4 - i], u], 1) if i < 5 else u
        # 4x4, dilation 2: effective 7x7, TF 'same' pads 3/3
        return torch.sigmoid(self.final(h))


class Separator(nn.Module):
    def __init__(self):
        super().__init__()
        self.vocals = UNet()
        self.accompaniment = UNet()

    def forward(self, magnitude):
        v = self.vocals(magnitude)
        a = self.accompaniment(magnitude)
        # Spleeter: (V^2 + eps/2) / (V^2 + A^2 + eps) with V = v*|X|, A = a*|X|;
        # |X| cancels, so use the sigmoid masks directly (stable in fp16)
        v2, a2 = v * v, a * a
        return v2 / (v2 + a2 + 1e-6)


# --------------------------------------------------------------------------
# checkpoint
# --------------------------------------------------------------------------

def load_checkpoint(path):
    import tensorflow as tf
    if os.path.isdir(path):
        index = glob.glob(os.path.join(path, "**", "*.index"), recursive=True)
        if not index:
            sys.exit("no *.index in %s" % path)
        prefix = index[0][:-len(".index")]
    else:
        prefix = path
    reader = tf.train.load_checkpoint(prefix)
    shapes = reader.get_variable_to_shape_map()
    print("checkpoint %s: %d variables" % (prefix, len(shapes)))
    for name in sorted(shapes):
        print("  %-60s %s" % (name, shapes[name]))
    return reader, shapes


VAR_RE = re.compile(r"(?:^|/)(conv2d_transpose|conv2d|batch_normalization)(?:_(\d+))?/"
                    r"(kernel|bias|gamma|beta|moving_mean|moving_variance)$")


def collect(shapes):
    """{kind: {index: {param: variable name}}}, ignoring optimizer slots."""
    out = {"conv2d": {}, "conv2d_transpose": {}, "batch_normalization": {}}
    for name in shapes:
        if "Adam" in name or "Momentum" in name or "global_step" in name:
            continue
        m = VAR_RE.search(name)
        if not m:
            continue
        kind, idx, param = m.group(1), int(m.group(2) or 0), m.group(3)
        out[kind].setdefault(idx, {})[param] = name
    for kind, n in (("conv2d", 14), ("conv2d_transpose", 12), ("batch_normalization", 24)):
        got = sorted(out[kind])
        if got != list(range(n)):
            sys.exit("expected %s 0..%d, found %s" % (kind, n - 1, got))
    return out


def unet_weights(reader, layers, net):
    """Weights of U-Net `net` (0 = vocals, 1 = accompaniment), in Spleeter's
    layer creation order: instruments are built in the order of 2stems.json
    (vocals, accompaniment), each creating 7 conv2d (6 encoder + final),
    6 conv2d_transpose and 12 batch_normalization (6 encoder + 6 decoder)."""
    get = reader.get_tensor
    conv = [layers["conv2d"][net * 7 + i] for i in range(7)]
    deconv = [layers["conv2d_transpose"][net * 6 + i] for i in range(6)]
    bn = [layers["batch_normalization"][net * 12 + i] for i in range(12)]
    w = {"conv": [], "deconv": [], "bn": []}
    for i in range(6):
        k, b = get(conv[i]["kernel"]), get(conv[i]["bias"])
        assert k.shape == (5, 5, ENC[i], ENC[i + 1]), (conv[i]["kernel"], k.shape)
        w["conv"].append((k, b))
    k, b = get(conv[6]["kernel"]), get(conv[6]["bias"])
    assert k.shape == (4, 4, 1, 2), (conv[6]["kernel"], k.shape)
    w["final"] = (k, b)
    for i in range(6):
        k, b = get(deconv[i]["kernel"]), get(deconv[i]["bias"])
        assert k.shape == (5, 5, DEC_OUT[i], DEC_IN[i]), (deconv[i]["kernel"], k.shape)
        w["deconv"].append((k, b))
    for i in range(12):
        p = bn[i]
        vals = tuple(get(p[x]) for x in ("gamma", "beta", "moving_mean", "moving_variance"))
        want = ENC[i + 1] if i < 6 else DEC_OUT[i - 6]
        assert vals[0].shape == (want,), (p["gamma"], vals[0].shape, want)
        w["bn"].append(vals)
    return w


def load_into(unet, w):
    t = lambda a: torch.from_numpy(np.ascontiguousarray(a)).float()
    with torch.no_grad():
        for i in range(6):
            k, b = w["conv"][i]
            unet.convs[i].weight.copy_(t(k.transpose(3, 2, 0, 1)))          # HWIO -> OIHW
            unet.convs[i].bias.copy_(t(b))
            k, b = w["deconv"][i]
            unet.deconvs[i].weight.copy_(t(k.transpose(3, 2, 0, 1)))        # HW(out)(in) -> (in)(out)HW
            unet.deconvs[i].bias.copy_(t(b))
        k, b = w["final"]
        unet.final.weight.copy_(t(k.transpose(3, 2, 0, 1)))
        unet.final.bias.copy_(t(b))
        for i in range(12):
            g, beta, mean, var = w["bn"][i]
            m = unet.enc_bn[i] if i < 6 else unet.dec_bn[i - 6]
            m.weight.copy_(t(g)); m.bias.copy_(t(beta))
            m.running_mean.copy_(t(mean)); m.running_var.copy_(t(var))


# --------------------------------------------------------------------------
# parity: the same U-Net with Keras layers (TF semantics)
# --------------------------------------------------------------------------

def keras_unet(w):
    import tensorflow as tf
    L = tf.keras.layers
    inp = L.Input((T, FBINS, 2))
    convs, h = [], inp
    for i in range(6):
        c = L.Conv2D(ENC[i + 1], 5, strides=2, padding="same")
        x = c(h); c.set_weights(list(w["conv"][i]))
        convs.append(x)
        bn = L.BatchNormalization(epsilon=BN_EPS)
        y = bn(x); bn.set_weights(list(w["bn"][i]))
        h = L.LeakyReLU(0.2)(y)   # first argument is the slope in Keras 2 (alpha) and 3 (negative_slope)
    h = convs[5]
    for i in range(6):
        d = L.Conv2DTranspose(DEC_OUT[i], 5, strides=2, padding="same")
        u = d(h); d.set_weights(list(w["deconv"][i]))
        u = L.ReLU()(u)
        bn = L.BatchNormalization(epsilon=BN_EPS)
        u = bn(u); bn.set_weights(list(w["bn"][6 + i]))
        h = L.Concatenate(axis=-1)([convs[4 - i], u]) if i < 5 else u
    f = L.Conv2D(2, 4, dilation_rate=2, padding="same", activation="sigmoid")
    out = f(h); f.set_weights(list(w["final"]))
    return tf.keras.Model(inp, out)


def parity(torch_unet, w):
    rng = np.random.default_rng(0)
    x = np.abs(rng.normal(0, 1, (1, T, FBINS, 2))).astype(np.float32) * 3
    k = keras_unet(w)(x, training=False).numpy()                              # NHWC
    with torch.no_grad():
        p = torch_unet(torch.from_numpy(x.transpose(0, 3, 1, 2))).numpy()     # NCHW
    diff = np.abs(k.transpose(0, 3, 1, 2) - p).max()
    print("parity Keras vs PyTorch U-Net: max |diff| = %.2e" % diff)
    if diff > 2e-3:
        sys.exit("PyTorch port doesn't match Spleeter's layers")


# --------------------------------------------------------------------------
# sanity: a sung vowel should be vocals, a drum loop accompaniment
# --------------------------------------------------------------------------

def stft_mag(x, n=4096, hop=1024):
    w = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)                     # periodic Hann
    frames = 1 + (len(x) - n) // hop
    out = np.empty((frames, n // 2 + 1), np.float32)
    for f in range(frames):
        out[f] = np.abs(np.fft.rfft(x[f * hop:f * hop + n] * w))
    return out


def synthetic(kind, sr=44100):
    n = (T - 1) * 1024 + 4096
    t = np.arange(n) / sr
    rng = np.random.default_rng(1)
    if kind == "vowel":
        f0 = 220 * (1 + 0.01 * np.sin(2 * np.pi * 5.5 * t))                  # vibrato
        phase = 2 * np.pi * np.cumsum(f0) / sr
        y = sum(np.sin(h * phase) / h for h in range(1, 40))
        for fc, bw in ((700, 110), (1220, 120), (2600, 160)):                 # /a/ formants via resonant boost
            spec = np.fft.rfft(y)
            freqs = np.fft.rfftfreq(len(y), 1 / sr)
            spec *= 1 + 8 * np.exp(-0.5 * ((freqs - fc) / bw) ** 2)
            y = np.fft.irfft(spec, len(y))
        y = y / np.abs(y).max() * 0.3
        return np.stack([y, y])                                              # centred
    beat = np.zeros(n)
    for start in range(0, n, sr // 2):                                       # kick + hat noise
        k = np.arange(min(4000, n - start))
        beat[start:start + len(k)] += np.sin(2 * np.pi * 55 * k / sr) * np.exp(-k / 800)
        h = start + sr // 4
        if h < n:
            m = min(1500, n - h)
            beat[h:h + m] += rng.normal(0, 0.3, m) * np.exp(-np.arange(m) / 200)
    beat /= np.abs(beat).max() / 0.3
    return np.stack([beat, beat * 0.9])


def sanity(model):
    for kind in ("vowel", "drums"):
        y = synthetic(kind)
        mag = np.stack([stft_mag(c)[:T, :FBINS] for c in y])[None]           # [1,2,T,F]
        with torch.no_grad():
            mask = model(torch.from_numpy(mag)).numpy()
        weight = mag / (mag.sum() + 1e-9)
        print("sanity: %-5s -> energy-weighted vocal mask %.2f" % (kind, float((mask * weight).sum())))


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True, help="Spleeter 2stems folder (or checkpoint prefix)")
    ap.add_argument("--out", default="DeezitVocals.mlmodel")
    a = ap.parse_args()

    reader, shapes = load_checkpoint(a.checkpoint)
    layers = collect(shapes)
    model = Separator().eval()
    weights = [unet_weights(reader, layers, net) for net in (0, 1)]
    load_into(model.vocals, weights[0])
    load_into(model.accompaniment, weights[1])
    print("weights loaded: %.1f M parameters" % (sum(p.numel() for p in model.parameters()) / 1e6))

    parity(model.vocals, weights[0])
    parity(model.accompaniment, weights[1])
    sanity(model)

    import coremltools as ct
    example = torch.rand(1, 2, T, FBINS) * 3
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="magnitude", shape=(1, 2, T, FBINS), dtype=np.float32)],
        outputs=[ct.TensorType(name="vocal_mask")],
        convert_to="neuralnetwork",
        minimum_deployment_target=ct.target.iOS14,
    )
    from coremltools.models.neural_network import quantization_utils
    mlmodel = quantization_utils.quantize_weights(mlmodel, nbits=16)
    mlmodel.short_description = "Spleeter 2-stems vocal mask (Deezer Research, MIT) for Deezit Sing"
    mlmodel.author = "Deezer Research (Spleeter); converted for Deezit"
    mlmodel.license = "MIT"
    mlmodel.save(a.out)

    if sys.platform == "darwin":
        x = (np.abs(np.random.default_rng(2).normal(0, 1, (1, 2, T, FBINS))) * 3).astype(np.float32)
        got = ct.models.MLModel(a.out).predict({"magnitude": x})["vocal_mask"]
        with torch.no_grad():
            want = model(torch.from_numpy(x)).numpy()
        diff = np.abs(np.asarray(got).reshape(want.shape) - want)
        print("Core ML vs PyTorch: max |diff| %.3f, mean %.4f" % (diff.max(), diff.mean()))
        if diff.mean() > 0.02:
            sys.exit("Core ML output drifts too far from PyTorch")

    digest = hashlib.sha256(open(a.out, "rb").read()).hexdigest()
    with open(a.out + ".sha256", "w") as fh:
        fh.write("%s  %s\n" % (digest, os.path.basename(a.out)))
    with open(a.out + ".json", "w") as fh:
        json.dump({"model": "spleeter-2stems", "frames": T, "bins": FBINS, "n_fft": 4096, "hop": 1024,
                   "sample_rate": 44100, "bytes": os.path.getsize(a.out), "sha256": digest}, fh, indent=1)
    print("wrote %s (%.1f MB), sha256 %s" % (a.out, os.path.getsize(a.out) / 1e6, digest))


if __name__ == "__main__":
    main()
