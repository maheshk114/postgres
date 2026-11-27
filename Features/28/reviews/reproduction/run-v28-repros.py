import concurrent.futures
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(os.environ.get("V28_ROOT", str(Path(__file__).resolve().parent)))
REPO = Path(os.environ.get("V28_REPO", "/home/maheshbehera/worktrees/postgresql-v28-review"))
INSTALL = Path(os.environ.get("V28_INSTALL", str(ROOT / "v28-install")))
BUILD = Path(os.environ.get("V28_BUILD", str(ROOT / "v28-build")))
HARNESS = Path(__file__).resolve().with_name("v28-repro.pl")
attempt = sys.argv[1]
cases = sys.argv[2:]


def run(case):
    directory = ROOT / "v28-repros" / f"{case}-{attempt}"
    directory.mkdir(parents=True, exist_ok=False)
    (directory / "log").mkdir()
    env = os.environ.copy()
    env.update({
        "PATH": str(INSTALL / "bin") + ":" + env["PATH"],
        "LD_LIBRARY_PATH": str(INSTALL / "lib"),
        "PG_REGRESS": str(BUILD / "src/test/regress/pg_regress"),
        "TESTLOGDIR": str(directory / "log"),
        "TESTDATADIR": str(directory),
        "PG_TEST_TIMEOUT_DEFAULT": "30",
        "V28_SCENARIO": case,
        "enable_injection_points": "yes",
    })
    with (directory / "prove.log").open("w") as output:
        result = subprocess.run(
            ["timeout", "--kill-after=10s", "5m", "prove", "-v",
             "-I", str(REPO / "src/test/perl"), str(HARNESS)],
            cwd=directory, env=env, stdout=output, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    print(case, "exit", result.returncode,
          (directory / "prove.log").read_text()[-2500:], flush=True)
    return result.returncode


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(run, cases))
sys.exit(1 if any(results) else 0)
