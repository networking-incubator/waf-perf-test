# Sample Results Fixture

These files are a fixture for exercising the report generators without requiring a Kubernetes cluster. They were measured on a different cluster and are provided solely to verify that the report code works.

**Important:** No performance number in these files is reportable for this repository. They represent a prior measurement environment and are not comparable to results you would obtain from your own test runs.

**Never copy these files into `results/`.** `scripts/report.py` takes the median of every run it finds for a tag, so a fixture sitting in `results/` silently averages another cluster into your delta, with no error and nothing in the output marking it. The filenames are exactly the shape `scripts/run.sh` produces, so nothing distinguishes them once they are there.

## Exercising the report code

`scripts/report.py` reads whatever directory you point it at, so it runs against the fixture directly. It renders one scenario group per invocation and the fixture holds three, so name the one you want:

```bash
python3 scripts/report.py --results testdata/sample-results \
  --scenario fixed-500qps+baseline-get --out /tmp/fixture-report.html
```

The three groups are `fixed-500qps+baseline-get`, `fixed-500qps+args-heavy` and `fixed-500qps+headers-heavy`.

`generate-report.py` takes no arguments and reads the `results/` directory beside itself, so it cannot be pointed here. On a fresh clone it fails with `FileNotFoundError` because `results/` does not exist yet. To exercise it, copy the fixture in, run it, then delete both the copy and the report it wrote:

```bash
mkdir -p results && cp testdata/sample-results/* results/
python3 generate-report.py
find results -type f -delete
```

Delete that output before doing anything else. It reports twelve completed tests and asserts the cluster named in [Known limitations](../../README.md#known-limitations), with nothing inside it saying the numbers came from a fixture.
