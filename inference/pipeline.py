"""
LTX-2.3 inference pipeline wrapper.

Loads the model once into GPU memory and keeps it resident for the lifetime
of the server process. Handles the full generation chain:
  1. TI2VidTwoStagesPipeline — T2V + spatial upscale (960x544 → 1920x1088)
  2. ffmpeg — crop 1920x1088 → 1920x1080

Note: ltx-2.3-temporal-upscaler-x2 operates on latents and has no public
Python API in ltx_pipelines. We generate at native 24fps (121 frames ≈ 5s)
instead, avoiding interpolation artifacts entirely.
"""

import logging
import os
import random
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger(__name__)

# These are set by startup-infer.sh via environment variables
MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/opt/kalpa/models"))
COLLECTION = os.environ.get("COLLECTION", "")

# Output resolution: 1920x1088 is the nearest valid (divisible by 32) size
# above 1080p. We crop the 8px height difference with ffmpeg.
OUTPUT_WIDTH = 1920
OUTPUT_HEIGHT = 1088  # crop to 1080 in ffmpeg step


@dataclass
class GenerationRequest:
    job_id: str
    collection: str
    prompt: str
    negative_prompt: str = "worst quality, inconsistent motion, blurry, jittery, distorted"
    num_frames: int = 121       # 8*15+1, native 24fps ≈ 5s
    frame_rate: float = 24.0
    num_inference_steps: int = 40
    lora_strength: float = 0.8
    seed: int = field(default_factory=lambda: random.randint(0, 2**31))


def _gpu_memory_sampler(job_id: str, stop_event: threading.Event, interval: float = 2.0) -> None:
    """Background thread: logs GPU memory every `interval` seconds."""
    import torch
    while not stop_event.wait(interval):
        try:
            allocated = torch.cuda.memory_allocated() / 1024**3
            reserved = torch.cuda.memory_reserved() / 1024**3
            log.info(f"[{job_id}] GPU mem: {allocated:.2f} GiB alloc, {reserved:.2f} GiB reserved")
        except Exception:
            pass


def _dump_oom_snapshot(job_id: str) -> None:
    """
    Log the top live CUDA allocations via torch.cuda.memory_snapshot().
    Unlike gc.get_objects(), memory_snapshot() queries the CUDA allocator
    directly and correctly enumerates all live GPU tensors including leaf
    tensors (model weights) which are reference-counted only and invisible
    to Python's garbage collector.
    """
    import torch
    try:
        snapshot = torch.cuda.memory_snapshot()
        blocks = []
        for seg in snapshot:
            for blk in seg.get("blocks", []):
                if blk.get("state") == "active_allocated":
                    size = blk.get("size", 0)
                    if size >= 100 * 1024 * 1024:  # >= 100 MiB
                        frames = blk.get("frames", [])
                        # Extract a short stack summary (innermost frame)
                        frame_str = ""
                        if frames:
                            f = frames[-1]
                            frame_str = f"{f.get('filename', '?')}:{f.get('line', '?')} in {f.get('name', '?')}"
                        blocks.append((size, frame_str))
        blocks.sort(reverse=True)
        log.error(f"[{job_id}] Live CUDA allocations >= 100 MiB ({len(blocks)} total):")
        for size, frame in blocks[:30]:
            log.error(f"  {size / 1024**3:.3f} GiB  @ {frame}")
        if not blocks:
            log.error(f"[{job_id}]   (none found — snapshot may require PYTORCH_NO_CUDA_MEMORY_CACHING=0)")
    except Exception as e:
        log.error(f"[{job_id}] memory_snapshot failed: {e}")


class LTXPipeline:
    """
    Wraps TI2VidTwoStagesPipeline with model-resident inference.
    Call load() once at startup; then call generate() per request.
    """

    def __init__(self):
        self._pipe = None
        self._loaded = False

    @property
    def is_loaded(self) -> bool:
        return self._loaded

    def load(self, collection: str) -> None:
        """Load model + LoRA into GPU memory. Blocks until complete (~15 min)."""
        log.info("Loading LTX-2.3 pipeline (this takes ~15 min on first run)...")

        from ltx_core.loader import LoraPathStrengthAndSDOps, LTXV_LORA_COMFY_RENAMING_MAP
        from ltx_pipelines.ti2vid_two_stages import TI2VidTwoStagesPipeline

        lora_path = MODEL_DIR / "loras" / collection / "lora.safetensors"
        if not lora_path.exists():
            raise FileNotFoundError(f"LoRA not found: {lora_path}")

        loras = [
            LoraPathStrengthAndSDOps(
                str(lora_path),
                float(os.environ.get("LORA_STRENGTH", "0.8")),
                LTXV_LORA_COMFY_RENAMING_MAP,
            )
        ]

        # No quantization — bf16 throughout.
        # fp8_cast was added when the peak was estimated at ~79.3 GiB, but that
        # estimate was based on broken autograd behavior (missing inference_mode).
        # With inference_mode() fixed, LayerStreamingWrapper evicts correctly and
        # peak stays low. fp8e4nv (float8_e4m3fn) is also unsupported on A100 in
        # Triton — it is Hopper-only — so fp8_cast would fail regardless.
        self._pipe = TI2VidTwoStagesPipeline(
            checkpoint_path=str(MODEL_DIR / "ltx-2.3-22b-dev" / "ltx-2.3-22b-dev.safetensors"),
            distilled_lora=[],  # dev model, not distilled
            spatial_upsampler_path=str(
                MODEL_DIR / "ltx-2.3-spatial-upscaler-x2"
                / "ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
            ),
            gemma_root=str(MODEL_DIR / "gemma-encoder"),
            loras=loras,
        )

        self._loaded = True

        # Note: TI2VidTwoStagesPipeline uses lazy model loading — no weights exist
        # in the object until the first __call__. FP8 verification is done in the
        # OOM handler via dtype inspection of large CUDA tensors (float8_e4m3fn = working).

        log.info("Pipeline loaded and ready.")

    def generate(self, req: GenerationRequest, output_dir: Path) -> Path:
        """
        Run the full generation chain. Returns path to final 1920x1080 24fps mp4.
        output_dir should be job-specific (e.g. /tmp/kalpa-jobs/{job_id}/)
        """
        if not self._loaded:
            raise RuntimeError("Pipeline not loaded — call load() first")

        output_dir.mkdir(parents=True, exist_ok=True)
        raw_path = output_dir / "raw.mp4"
        final_path = output_dir / "output.mp4"

        # --- Stage 1 + 2: T2V + spatial upscale (960x544 → 1920x1088 @ 24fps) ---
        from ltx_core.components.guiders import MultiModalGuiderParams
        from ltx_core.model.video_vae import TilingConfig, get_video_chunks_number
        from ltx_pipelines.utils.media_io import encode_video

        import torch
        torch.cuda.empty_cache()

        # Diagnostic: log GPU memory state before pipeline runs
        allocated = torch.cuda.memory_allocated() / 1024**3
        reserved = torch.cuda.memory_reserved() / 1024**3
        total = torch.cuda.get_device_properties(0).total_memory / 1024**3
        log.info(f"[{req.job_id}] GPU memory before pipeline: "
                 f"{allocated:.2f} GiB allocated, {reserved:.2f} GiB reserved, "
                 f"{total:.2f} GiB total")

        log.info(f"[{req.job_id}] Generating {OUTPUT_WIDTH}x{OUTPUT_HEIGHT} "
                 f"@ {req.frame_rate}fps, {req.num_frames} frames "
                 f"(≈{req.num_frames / req.frame_rate:.1f}s)...")

        # Background thread samples GPU memory every 2s — reveals which phase
        # causes the memory spike (text encoder vs. stage_1 vs. stage_2).
        stop_sampler = threading.Event()
        sampler = threading.Thread(
            target=_gpu_memory_sampler,
            args=(req.job_id, stop_sampler, 2.0),
            daemon=True,
        )
        sampler.start()

        tiling_config = TilingConfig.default()
        try:
            # no_grad is critical: without it, PyTorch autograd saves references
            # to GPU weight tensors in each layer's backward graph.
            # output_hidden_states=True accumulates 46 hidden states, each
            # holding autograd refs to that layer's GPU weights — bypassing
            # LayerStreamingWrapper's eviction hooks entirely. Peak memory
            # climbs ~0.8 GiB per layer × 46 layers × 2 prompts ≈ 74 GiB.
            # no_grad prevents all autograd graph building; eviction works
            # correctly and peak stays at ~5 GiB during text encoding.
            # Note: inference_mode() would also fix the OOM but marks output
            # tensors as inference tensors, which breaks encode_video (VAE
            # decode runs outside this context with autograd on and calls
            # F.conv3d on the latents — PyTorch refuses to save inference
            # tensors for backward). no_grad() has the same eviction benefit
            # without that restriction.
            with torch.no_grad():
                video, audio = self._pipe(
                    prompt=req.prompt,
                    negative_prompt=req.negative_prompt,
                    seed=req.seed,
                    height=OUTPUT_HEIGHT,
                    width=OUTPUT_WIDTH,
                    num_frames=req.num_frames,
                    frame_rate=req.frame_rate,
                    num_inference_steps=req.num_inference_steps,
                    streaming_prefetch_count=4,
                    video_guider_params=MultiModalGuiderParams(
                        cfg_scale=3.0,
                        stg_scale=1.0,
                        rescale_scale=0.7,
                        modality_scale=3.0,
                        skip_step=0,
                        stg_blocks=[29],
                    ),
                    audio_guider_params=MultiModalGuiderParams(
                        cfg_scale=7.0,
                        stg_scale=1.0,
                        rescale_scale=0.7,
                        modality_scale=3.0,
                        skip_step=0,
                        stg_blocks=[29],
                    ),
                    images=[],
                    tiling_config=tiling_config,
                )
        except torch.cuda.OutOfMemoryError:
            # Dump memory summary. memory_snapshot() queries the CUDA allocator
            # directly and correctly enumerates ALL live GPU tensors — unlike
            # gc.get_objects() which misses leaf tensors (model weights) that are
            # reference-counted only and not tracked by Python's GC.
            log.error(f"[{req.job_id}] CUDA OOM — memory summary:\n"
                      + torch.cuda.memory_summary())
            _dump_oom_snapshot(req.job_id)
            raise
        finally:
            stop_sampler.set()
            sampler.join(timeout=5)

        video_chunks_number = get_video_chunks_number(req.num_frames, tiling_config)

        # Free the spatial upscaler's cached allocations (~16 GiB reserved but
        # not allocated) before the VAE decode allocates at 1920x1088 resolution.
        torch.cuda.empty_cache()

        # no_grad is required: the video generator (tiled VAE decode) runs lazily
        # here. VAE parameters have requires_grad=True by default, so without
        # no_grad, F.conv3d saves all 1920x1088 intermediate activations for
        # a potential backward pass — accumulating ~76 GiB before OOM.
        with torch.no_grad():
            encode_video(
                video=video,
                fps=req.frame_rate,
                audio=audio,
                output_path=str(raw_path),
                video_chunks_number=video_chunks_number,
            )
        log.info(f"[{req.job_id}] Generation complete: {raw_path}")

        # --- ffmpeg: crop 1920x1088 → 1920x1080 (remove 4px top + bottom) ---
        log.info(f"[{req.job_id}] Cropping to 1920x1080...")
        subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", str(raw_path),
                "-vf", "crop=1920:1080:0:4",
                "-c:v", "libx264",
                "-c:a", "copy",
                "-preset", "fast",
                "-crf", "18",
                str(final_path),
            ],
            check=True,
        )
        log.info(f"[{req.job_id}] Final output: {final_path}")

        raw_path.unlink(missing_ok=True)
        return final_path
