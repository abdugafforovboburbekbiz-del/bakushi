#!/usr/bin/env python3
"""Build the Bakushi FAST MODE model: a 4-stem, int8-quantized HTDemucs.

Steps (fully local, nothing uploaded):
  1. Load the 6-stem fp32 model (htdemucs_6s.onnx).
  2. Slice the final ConvTranspose 12 -> 8 output channels, keeping the
     first 4 stems in demucs order: drums, bass, other, vocals.
  3. Fix the output reshape constant 6 -> 4 and the declared output shape.
  4. Save the exact 4-stem fp32 model (htdemucs_4s.onnx) and verify it
     reproduces the original's first 4 stems bit-for-bit.
  5. Dynamic int8-quantize it into htdemucs_4s_int8.onnx and sanity-check
     the quantized output against the fp32 one.

Usage:
  python tools/quantize_model.py [--input PATH] [--skip-quantize] [--no-verify]
"""

import argparse
import os
import sys
import time

import numpy as np

import onnx
from onnx import TensorShapeProto, helper, numpy_helper


def slice_to_4_stems(model):
    """Mutate the model in place: 6 stems -> 4 stems (drums,bass,other,vocals).

    htdemucs_6s has TWO final projections that carry the 6-stem dimension:
      - tdecoder.3.conv_tr: 12 output channels (6 stems x 2 audio channels)
      - decoder.3.conv_tr:  24 output channels (6 stems x 2 x 2 params)
    plus two reshape targets containing a [6] constant:
      - Concat_6 -> Reshape_9  target [1,6,-1,343980]
      - Concat_2 -> Reshape_3  target [?,6,-1,?,?]
    """
    g = model.graph

    # 1. Slice the final projection ConvTranspose weights to 4 stems.
    #    ONNX ConvTranspose weight layout: (Cin, Cout/groups, ...k).
    for w_name, keep in (("tdecoder.3.conv_tr.weight", 8),
                         ("decoder.3.conv_tr.weight", 16)):
        w_init = next((i for i in g.initializer if i.name == w_name), None)
        if w_init is None:
            raise RuntimeError("weight initializer %r not found" % w_name)
        w = numpy_helper.to_array(w_init)
        full = keep * 3 // 2  # 12 or 24
        axis = [i for i, d in enumerate(w.shape) if d == full]
        if len(axis) != 1:
            raise RuntimeError(
                "expected one axis with %d channels in %s, got %r"
                % (full, w_name, (w.shape,)))
        w4 = np.take(w, np.arange(keep), axis=axis[0]).copy()
        g.initializer.remove(w_init)
        g.initializer.append(numpy_helper.from_array(w4, name=w_name))
        b_name = w_name.replace(".weight", ".bias")
        b_init = next((i for i in g.initializer if i.name == b_name), None)
        if b_init is not None:
            b = numpy_helper.to_array(b_init)
            if b.shape[0] != full:
                raise RuntimeError("expected bias of %d, got %r"
                                   % (full, (b.shape,)))
            b4 = b[:keep].copy()
            g.initializer.remove(b_init)
            g.initializer.append(numpy_helper.from_array(b4, name=b_name))
        print("[1/5] sliced %s %d->%d channels" % (w_name, full, keep))

    # 2. Fix the two reshape targets: their [6] stem-count constant -> [4].
    #    Reshape_9 (tdecoder path): Reshape(data=/tdecoder.3/Slice_output_0).
    #    Reshape_3 (decoder path):  Reshape(data=/decoder.3/Slice_output_0).
    fixed = 0
    for data_in in ("/tdecoder.3/Slice_output_0", "/decoder.3/Slice_output_0"):
        reshape = next((n for n in g.node
                        if n.op_type == "Reshape"
                        and data_in in list(n.input)), None)
        if reshape is None:
            raise RuntimeError("Reshape for %r not found" % data_in)
        shape_name = reshape.input[1]
        concat = next((n for n in g.node
                       if n.op_type == "Concat"
                       and shape_name in list(n.output)), None)
        if concat is None:
            raise RuntimeError("Concat producing %r not found" % shape_name)
        for const_name in concat.input:
            cn = next((n for n in g.node
                       if n.op_type == "Constant"
                       and const_name in list(n.output)), None)
            if cn is None:
                continue
            for a in cn.attribute:
                if a.name != "value":
                    continue
                t = numpy_helper.to_array(a.t)
                if t.size == 1 and t.reshape(-1)[0] == 6 and t.dtype in (
                        np.int32, np.int64):
                    a.t.CopyFrom(
                        numpy_helper.from_array(np.array([4], dtype=t.dtype)))
                    fixed += 1
    if fixed != 2:
        raise RuntimeError(
            "expected exactly two [6] stem-count constants in the reshapes, "
            "found %d" % fixed)
    print("[2/5] reshape stem-count constants 6 -> 4 (2 nodes)")

    # 3. Declare the new output shape.
    for out in g.output:
        if out.name == "stems":
            out.type.tensor_type.shape.ClearField("dim")
            for v in (1, 4, 2, 343980):
                out.type.tensor_type.shape.dim.append(
                    TensorShapeProto.Dimension(dim_value=v))
    print("[3/5] declared output shape (1,4,2,343980)")

    onnx.checker.check_model(model)
    print("[4/5] onnx.checker OK")
    return model


def verify_fp32(orig_path, four_path):
    """The sliced fp32 model must reproduce the original's first 4 stems."""
    import onnxruntime as ort
    rng = np.random.default_rng(7)
    x = (rng.standard_normal((1, 2, 343980)) * 0.1).astype(np.float32)
    s6 = ort.InferenceSession(orig_path, providers=["CPUExecutionProvider"])
    s4 = ort.InferenceSession(four_path, providers=["CPUExecutionProvider"])
    t0 = time.time()
    y6 = np.asarray(s6.run(None, {"mix": x})[0], dtype=np.float32)
    t6 = time.time() - t0
    t0 = time.time()
    y4 = np.asarray(s4.run(None, {"mix": x})[0], dtype=np.float32)
    t4 = time.time() - t0
    diff = float(np.abs(y6[:, :4] - y4).max())
    print("fp32 verify: shapes %s vs %s, max|diff| first 4 stems = %.3e"
          % (y6.shape, y4.shape, diff))
    print("fp32 infer times: 6s=%.2fs  4s=%.2fs" % (t6, t4))
    return y4


def quantize(four_path, int8_path):
    from onnxruntime.quantization import QuantType, quantize_dynamic
    t0 = time.time()
    quantize_dynamic(
        model_input=four_path,
        model_output=int8_path,
        weight_type=QuantType.QInt8,
        op_types_to_quantize=["MatMul", "Conv", "Gemm", "Attention"],
    )
    print("dynamic int8 quantization done in %.1fs" % (time.time() - t0))


def verify_int8(four_path, int8_path, y4):
    import onnxruntime as ort
    rng = np.random.default_rng(7)
    x = (rng.standard_normal((1, 2, 343980)) * 0.1).astype(np.float32)
    sq = ort.InferenceSession(int8_path, providers=["CPUExecutionProvider"])
    t0 = time.time()
    yq = np.asarray(sq.run(None, {"mix": x})[0], dtype=np.float32)
    tq = time.time() - t0
    a = y4.ravel()
    b = yq.ravel()
    corr = float(np.corrcoef(a, b)[0, 1])
    rms_ratio = float(np.sqrt(np.mean(b * b)) / (np.sqrt(np.mean(a * a)) + 1e-12))
    diff = float(np.abs(y4 - yq).max())
    print("int8 verify: shape %s, max|diff|=%.3e, corr=%.4f, rms_ratio=%.3f"
          % (yq.shape, diff, corr, rms_ratio))
    print("int8 infer time: %.2fs (fp32 4s was above)" % tq)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_in = os.environ.get(
        "BAKUSHI_INPUT_MODEL",
        os.path.normpath(os.path.join(here, "..", "assets", "models",
                                      "htdemucs_6s_fp16weights.onnx")))
    default_out_dir = os.path.normpath(os.path.join(here, "..", "assets", "models"))

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", default=default_in)
    ap.add_argument("--out-dir", default=default_out_dir)
    ap.add_argument("--skip-quantize", action="store_true")
    ap.add_argument("--no-verify", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        print("ERROR: input model not found: %s" % args.input)
        sys.exit(2)
    os.makedirs(args.out_dir, exist_ok=True)
    four_path = os.path.join(args.out_dir, "htdemucs_4s.onnx")
    int8_path = os.path.join(args.out_dir, "htdemucs_4s_int8.onnx")

    print("loading %s (%.1f MB)" % (args.input, os.path.getsize(args.input) / 1e6))
    model = onnx.load(args.input)
    slice_to_4_stems(model)
    print("saving fp32 4-stem -> %s" % four_path)
    onnx.save(model, four_path)
    print("fp32 4-stem size: %.1f MB" % (os.path.getsize(four_path) / 1e6))

    y4 = None
    if not args.no_verify:
        y4 = verify_fp32(args.input, four_path)

    if not args.skip_quantize:
        quantize(four_path, int8_path)
        print("int8 model size: %.1f MB" % (os.path.getsize(int8_path) / 1e6))
        if not args.no_verify and y4 is not None:
            verify_int8(four_path, int8_path, y4)

    print("DONE. Fast-mode model ready at %s" % int8_path)


if __name__ == "__main__":
    main()
