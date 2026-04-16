"""
Kalpa inference server.

FastAPI server that runs on the A100 instance during the demo window.
Keeps the LTX-2.3 model loaded in GPU memory and processes generation
jobs sequentially via an in-memory async queue.

Endpoints:
  POST /inference    — queue a generation job (requires X-API-Key)
  GET  /health       — server + model status
  GET  /status/:id   — job status + GCS path when complete
"""

import asyncio
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from google.cloud import storage
from pydantic import BaseModel

from pipeline import GenerationRequest, LTXPipeline

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# --- Config from environment ---
API_KEY = os.environ["INFERENCE_API_KEY"]
GCS_BUCKET = os.environ["GCS_BUCKET"].removeprefix("gs://")
COLLECTION = os.environ["COLLECTION"]
JOBS_TMP_DIR = Path(os.environ.get("JOBS_TMP_DIR", "/tmp/kalpa-jobs"))


# --- Job state ---
class JobStatus(str, Enum):
    pending = "pending"
    running = "running"
    complete = "complete"
    failed = "failed"


class Job(BaseModel):
    job_id: str
    status: JobStatus
    collection: str
    prompt: str
    gcs_path: Optional[str] = None
    shelby_blob: Optional[str] = None
    error: Optional[str] = None
    created_at: str
    completed_at: Optional[str] = None


jobs: dict[str, Job] = {}
job_queue: asyncio.Queue = asyncio.Queue()
pipeline = LTXPipeline()
gcs_client = storage.Client()  # uses instance's service account credentials


# --- Startup / shutdown ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Starting up — loading model into GPU memory...")
    loop = asyncio.get_event_loop()
    # Load model in a thread so the event loop stays responsive
    await loop.run_in_executor(None, pipeline.load, COLLECTION)
    log.info("Model loaded. Starting job worker.")
    worker_task = asyncio.create_task(job_worker())
    yield
    worker_task.cancel()


app = FastAPI(title="Kalpa Inference Server", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten to your Vercel domain in prod
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# --- Auth helper ---
def verify_api_key(x_api_key: str = Header(...)) -> None:
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


# --- Routes ---
class InferenceRequest(BaseModel):
    collection: str
    prompt: str
    seed: Optional[int] = None


@app.post("/inference")
async def create_job(
    req: InferenceRequest,
    x_api_key: str = Header(...),
):
    verify_api_key(x_api_key)

    if not pipeline.is_loaded:
        raise HTTPException(status_code=503, detail="Model is still loading, try again shortly")

    if req.collection != COLLECTION:
        raise HTTPException(
            status_code=400,
            detail=f"Server is loaded with collection '{COLLECTION}', got '{req.collection}'"
        )

    job_id = str(uuid.uuid4())
    job = Job(
        job_id=job_id,
        status=JobStatus.pending,
        collection=req.collection,
        prompt=req.prompt,
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    jobs[job_id] = job
    gen_kwargs = dict(
        job_id=job_id,
        collection=req.collection,
        prompt=req.prompt,
    )
    if req.seed is not None:
        gen_kwargs["seed"] = req.seed
    await job_queue.put(GenerationRequest(**gen_kwargs))

    log.info(f"Job queued: {job_id} (queue depth: {job_queue.qsize()})")
    return {"job_id": job_id, "status": "pending"}


@app.get("/health")
async def health():
    return {
        "status": "online" if pipeline.is_loaded else "loading",
        "collection": COLLECTION,
        "queue_depth": job_queue.qsize(),
    }


@app.get("/status/{job_id}")
async def get_status(job_id: str, x_api_key: str = Header(...)):
    verify_api_key(x_api_key)
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")
    return jobs[job_id]


# --- Background job worker ---
async def job_worker():
    """Processes jobs sequentially. Runs for the lifetime of the server."""
    log.info("Job worker started.")
    loop = asyncio.get_event_loop()
    while True:
        gen_req: GenerationRequest = await job_queue.get()
        job = jobs[gen_req.job_id]
        job.status = JobStatus.running
        log.info(f"Processing job: {gen_req.job_id}")

        try:
            output_dir = JOBS_TMP_DIR / gen_req.job_id
            final_path = await loop.run_in_executor(
                None, pipeline.generate, gen_req, output_dir
            )
            gcs_path = await loop.run_in_executor(
                None, _upload_to_gcs, final_path, gen_req
            )
            shelby_blob = await loop.run_in_executor(
                None, _upload_to_shelby, final_path, gen_req
            )
            job.status = JobStatus.complete
            job.gcs_path = gcs_path
            job.shelby_blob = shelby_blob
            job.completed_at = datetime.now(timezone.utc).isoformat()
            log.info(f"Job complete: {gen_req.job_id} → {gcs_path} | shelby: {shelby_blob}")
        except Exception as e:
            log.exception(f"Job failed: {gen_req.job_id}")
            job.status = JobStatus.failed
            job.error = str(e)
        finally:
            job_queue.task_done()
            # Clean up job temp dir
            import shutil
            shutil.rmtree(JOBS_TMP_DIR / gen_req.job_id, ignore_errors=True)


def _upload_to_gcs(local_path: Path, req: GenerationRequest) -> str:
    """Upload output video to GCS. Returns gs:// path."""
    blob_name = f"outputs/{req.collection}/{req.job_id}.mp4"
    bucket = gcs_client.bucket(GCS_BUCKET)
    blob = bucket.blob(blob_name)
    blob.upload_from_filename(str(local_path), content_type="video/mp4")
    gcs_path = f"gs://{GCS_BUCKET}/{blob_name}"
    log.info(f"Uploaded to GCS: {gcs_path}")
    return gcs_path


def _upload_to_shelby(local_path: Path, req: GenerationRequest) -> str:
    """Upload output video to Shelby. Returns blob name."""
    import subprocess
    blob_name = f"outputs/{req.collection}/{req.job_id}.mp4"
    subprocess.run(
        ["shelby", "upload", str(local_path), blob_name, "-e", "in 30 days"],
        check=True,
    )
    log.info(f"Uploaded to Shelby: {blob_name}")
    return blob_name


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")
