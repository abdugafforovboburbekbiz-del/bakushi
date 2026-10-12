# Benchmarks

Measured **2026-10-11** on this machine (Windows 11, Intel Core Ultra-class
CPU, 16 logical cores, Intel Iris Xe iGPU, 32 GB RAM) with
`tools/benchmark.py`: a fixed **30 s** synthetic clip, hop 88200
(16 chunks of 7.8 s), 60 s cooldown between runs. Full JSON:
`tools/benchmark_results.json`.

| Model | Backend | avg/chunk | total (30 s clip) | RTF | peak RAM |
| --- | --- | --- | --- | --- | --- |
| 6-stem fp32 (baseline) | **OpenVINO CPU** | 1.48 s | 24 s | **0.79x** | 3.6 GB |
| 6-stem fp32 | ORT CPU EP | 2.37 s | 38 s | 1.27x | 4.4 GB |
| 6-stem fp32 | OpenVINO GPU.1 | 1.19 s | 19 s | 0.64x | 11.2 GB |
| 4-stem fp16 (app default) | **OpenVINO CPU** | 1.44 s | 23 s | **0.77x** | 3.8 GB |
| 4-stem fp16 | ORT CPU EP | 2.33 s | 37 s | 1.25x | 4.6 GB |
| 4-stem fp16 | OpenVINO GPU | falls back to CPU (iGPU can't build the graph) | | | |
| 4-stem int8 (removed) | OpenVINO CPU | 1.58 s | 25 s | 0.85x | 4.0 GB |
| 4-stem int8 (removed) | ORT CPU EP | 6.21 s | 99 s | **3.32x** | 4.3 GB |
| 4-stem int8 (removed) | OpenVINO GPU | falls back to CPU (also can't run on GPU.1) | | | |
| any | DirectML | **not installed** (removed; returned all-zeros / OOM on Iris Xe) | | | |

## Verdicts

1. **OpenVINO is the default backend.** It is ~1.6x faster than the plain
   ORT CPU EP on every model - the difference between 1.27x and 0.78x
   real-time on CPU - and uses ~0.8 GB less RAM. It is always tried first;
   the ORT CPU EP remains the automatic fallback.
2. **int8 quantization is NOT a fast mode on this machine.** It is 2.6x
   slower than fp16 on the ORT CPU EP (3.32x RTF, poorly optimized
   QLinearConv 1-D kernels) and ~10% slower on OpenVINO CPU. The fast-mode
   option was removed from the app.
3. **DirectML is dead on this hardware**: uninstalled; historically it
   returned all-zeros silently or OOM'd (`0x8007000E`) on ConvTranspose.
   No DirectML code path remains.
4. **GPU only pays off for the 6-stem fp32 model** (0.64x RTF), at the
   cost of 11.2 GB RAM and a ~90 s OpenCL compile; neither fp16-weights
   model can run on this iGPU (compile fails on GPU.1, GPU.0 is NaN). The
   app keeps the automatic GPU→CPU fallback for exactly this reason.
5. **Recommended configuration (locked in): 4-stem fp16 weights +
   OpenVINO CPU.** ~0.77x real-time, 3.8 GB peak - the best
   quality-per-stem for MPC sampling.

## OpenVINO version pairing

The working pairing is:

- `onnxruntime-openvino == 1.24.1`
- `openvino == 2025.4.1`

Install exactly ONE ORT runtime wheel - never co-install
`onnxruntime-directml` (wheel overwrite). The ORT OpenVINO EP bridge
rejects this model's graph ("Output names mismatch"), so the sidecar uses
the **native ov.Core runtime** instead. `openvino.dll` lives in
`<pkg>/openvino/libs`; the sidecar's `_ov_bootstrap()` adds that DLL
directory before importing onnxruntime. See `docs/OPENVINO_SETUP.md`.
