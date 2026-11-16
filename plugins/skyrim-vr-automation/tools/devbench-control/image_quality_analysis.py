# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline analysis of existing stereo stills and native ROI burst receipts."""

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def checked(path, sha256, evidence=None):
    path = Path(path).resolve()
    require(digest(path) == sha256.lower(), f"Hash mismatch: {path}")
    if evidence is not None:
        require(str(path) not in evidence or evidence[str(path)] == sha256.lower(), "Conflicting evidence hashes")
        evidence[str(path)] = sha256.lower()
    return path


def pointer(value, path):
    require(path == "" or path.startswith("/"), "Expected JSON pointer")
    for part in path.split("/")[1:]:
        key = part.replace("~1", "/").replace("~0", "~")
        if isinstance(value, list):
            require(key.isascii() and key.isdigit() and (key == "0" or not key.startswith("0")), "Invalid array index")
        value = value[int(key)] if isinstance(value, list) else value[key]
    return value


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def load_mask(config, base, evidence=None):
    source = checked(base / config["source"]["path"], config["source"]["sha256"], evidence)
    settings = read(source)
    values = {key: pointer(settings, field) for key, field in config["fields"].items()}
    require(all(finite_number(x) for x in values.values()), "Non-numeric or non-finite mask settings")
    require(config["model"] in ("squircle", "rectangle-inward"), "Unsupported mask model; do not infer geometry")
    if config["model"] == "squircle":
        require(finite_number(config["power"]) and config["power"] >= 1, "Invalid mask exponent")
        require(0.25 <= values["area"] <= 1 and 1 <= values["horizontalScale"] <= 2,
                "Mask settings outside shader contract")
        require(values["feather"] >= 0, "Negative mask feather")
    else:
        require(values["maskMode"] == 0 and values["blendMode"] in (1, 2), "Expected rectangular blended crop")
        require(values["featherPixels"] > 0, "Invalid inward feather")
        require(config.get("cropUnits", "uv") in ("uv", "pixels"), "Unsupported crop units")
    require(isinstance(config["effectiveRuntimeVerified"], bool), "Specify mask provenance")
    return values


def region_spec(plane, index, eye_x, mask, values, policy):
    roi = plane["burstRegions"][index]
    name = plane["eye"]
    spec = dict(Eye=name, Zone=("center", "transition", "outer")[index], Model=mask["model"],
                X=eye_x, Y=sum(r["height"] for r in plane["burstRegions"][:index]),
                Width=roi["width"], Height=roi["height"], NativeX=roi["x"], NativeY=roi["y"],
                EyeWidth=plane["sourceWidth"], EyeHeight=plane["sourceHeight"],
                CenterLimit=policy["centerDistanceMax"], OuterMargin=policy["outerDistanceMargin"],
                SafeMin=policy["safeUvMin"], SafeMax=policy["safeUvMax"])
    if mask["model"] == "rectangle-inward":
        crop = [values[name + key] * (size if mask.get("cropUnits", "uv") == "uv" else 1)
                for key, size in zip(("X", "Y", "W", "H"), (spec["EyeWidth"], spec["EyeHeight"]) * 2)]
        require(all(abs(v - round(v)) < 1e-6 for v in crop),
                "Fractional crop pixels: supply the effective integer crop with cropUnits=pixels")
        x, y, width, height = map(round, crop)
        require(0 <= x < x + width <= spec["EyeWidth"] and 0 <= y < y + height <= spec["EyeHeight"],
                "Effective crop outside eye")
        spec.update(CropX=x, CropY=y, CropWidth=width, CropHeight=height, FeatherPixels=values["featherPixels"])
        return spec
    radius_y = values["area"] * 0.5
    spec.update(
                CenterX=max(0, min(1, 0.5 + values[name + "X"])),
                CenterY=max(0, min(1, 0.5 + values[name + "Y"])),
                RadiusX=radius_y * values["horizontalScale"], RadiusY=radius_y,
                Power=mask["power"], Feather=max(values["feather"], 1e-4) / radius_y)
    return spec


def includes(spec, x, y):
    u = (spec["NativeX"] + x + 0.5) / spec["EyeWidth"]
    v = (spec["NativeY"] + y + 0.5) / spec["EyeHeight"]
    if spec["Model"] == "rectangle-inward":
        local_x, local_y = spec["NativeX"] + x - spec["CropX"], spec["NativeY"] + y - spec["CropY"]
        edge = min(local_x, local_y, spec["CropWidth"] - 1 - local_x, spec["CropHeight"] - 1 - local_y)
        if spec["Zone"] == "center":
            return edge >= spec["FeatherPixels"]
        if spec["Zone"] == "transition":
            return 0 <= edge < spec["FeatherPixels"]
        return edge < 0 and spec["SafeMin"] <= u <= spec["SafeMax"] and spec["SafeMin"] <= v <= spec["SafeMax"]
    distance = (abs((u - spec["CenterX"]) / spec["RadiusX"]) ** spec["Power"] +
                abs((v - spec["CenterY"]) / spec["RadiusY"]) ** spec["Power"]) ** (1 / spec["Power"])
    if spec["Zone"] == "center":
        return distance <= spec["CenterLimit"]
    if spec["Zone"] == "transition":
        return 1 < distance < 1 + spec["Feather"]
    return (distance >= 1 + spec["Feather"] + spec["OuterMargin"] and
            spec["SafeMin"] <= u <= spec["SafeMax"] and spec["SafeMin"] <= v <= spec["SafeMax"])


def contained_rectangle(spec, reference_spec=None):
    """Largest pixel rectangle wholly in the selected zone in both images."""
    heights = [0] * spec["Width"]
    best_area, best = 0, None
    for y in range(spec["Height"]):
        for x in range(spec["Width"]):
            inside = includes(spec, x, y) and (reference_spec is None or includes(reference_spec, x, y))
            heights[x] = heights[x] + 1 if inside else 0
        stack = []
        for x, height in enumerate(heights + [0]):
            start = x
            while stack and stack[-1][1] > height:
                left, old_height = stack.pop()
                area = (x - left) * old_height
                if area > best_area and x - left >= 8 and old_height >= 8:
                    best_area = area
                    best = dict(x=spec["NativeX"] + left, y=spec["NativeY"] + y - old_height + 1,
                                width=x - left, height=old_height)
                start = left
            if not stack or stack[-1][1] < height:
                stack.append((start, height))
    return best


def pixel_region(spec):
    """Share the exact selection between rectangle scoring and pixel measurements."""
    result = {k: spec[k] for k in ("Eye", "Zone", "X", "Y", "Width", "Height")}
    rows = []
    for y in range(spec["Height"]):
        boundaries, active = [], False
        for x in range(spec["Width"] + 1):
            selected = x < spec["Width"] and includes(spec, x, y)
            if selected != active:
                boundaries.append(x)
                active = selected
        rows.append(boundaries)
    result["MaskRuns"] = rows
    return result


def phase_map(phases, ordinals):
    allowed = set(ordinals)
    result = {}
    require([p["name"] for p in phases] == ["initial-hold", "sweep", "final-hold"],
            "Each view requires reviewed initial hold, sweep and final hold")
    previous_end = 0
    for phase in phases:
        require(type(phase["first"]) is int and type(phase["last"]) is int, "Non-integer phase ordinal")
        require(phase["first"] > previous_end and phase["last"] >= phase["first"] + 2,
                "Overlapping, unordered or too-short phases")
        require(phase.get("basis"), "Phase needs an image-review basis")
        for ordinal in range(phase["first"], phase["last"] + 1):
            require(ordinal in allowed, "Phase references absent frame")
            result[ordinal] = phase["name"]
        previous_end = phase["last"]
    return result


def pair_phase(ordinal, phases):
    current = phases.get(ordinal)
    return current if current and phases.get(ordinal - 1) == current else None


def resolve_capture_path(run, parent, value):
    run = Path(run).resolve()
    path = Path(value)
    if not path.is_absolute():
        path = parent / path
    elif not path.resolve().is_relative_to(run):
        # Always select the requested copy, even when the original capture still exists.
        matches = [i for i, part in enumerate(path.parts) if part.casefold() == run.name.casefold()]
        require(len(matches) == 1, f"Cannot unambiguously relocate receipt path: {path}")
        path = run.joinpath(*path.parts[matches[0] + 1:])
    require(path.resolve().is_relative_to(run), "Receipt path escapes selected capture")
    return path.resolve()


def resolve_artifact(run, sequence, artifact, evidence=None):
    path = resolve_capture_path(run, sequence.parent, artifact["path"])
    require(artifact.get("committed", True) is True, "Uncommitted artifact")
    require(path.stat().st_size == artifact["bytes"], f"Size mismatch: {path}")
    return checked(path, artifact["sha256"], evidence)


def prepare(config_path, evidence=None):
    config_path = Path(config_path).resolve()
    config, base = read(config_path), config_path.parent
    require(config["schema"] == "stereo-image-analysis-v1", "Unknown analysis schema")
    run = (base / config["run"]).resolve()
    manifest_path = checked(run / "image-manifest.json", config["imageManifestSha256"], evidence)
    manifest = read(manifest_path)
    require(manifest["schema"] == "comparison-native-images-v2" and manifest["verified"] is True,
            "Image manifest schema/verification mismatch")
    values = load_mask(config["mask"], base, evidence)
    reference_values = load_mask(config["referenceMask"], base, evidence) if "referenceMask" in config else None
    policy = config["regionPolicy"]
    require(all(finite_number(v) for v in policy.values()), "Non-finite region policy")
    require(0 < policy["centerDistanceMax"] <= 1 and policy["outerDistanceMargin"] >= 0,
            "Invalid zone policy")
    require(0.1 <= policy["safeUvMin"] < policy["safeUvMax"] <= 0.9, "Unsafe outer-image bounds")
    views = {v["view"]: v for v in manifest["views"]}
    require(views and len(views) == len(manifest["views"]) == len(config["views"]), "Empty or duplicate views")
    require(set(views) == {v["view"] for v in config["views"]}, "Review must cover every selected view")
    if any("reference" in v for v in config["views"]):
        require(finite_number(config["similarityThreshold"]) and -1 <= config["similarityThreshold"] <= 1,
                "Invalid similarity threshold")
    jobs, scoring, audit = [], [], []
    for review in config["views"]:
        view = views[review["view"]]
        sequence_path = resolve_capture_path(run, run, view["burst"]["manifest"])
        checked(sequence_path, review["sequenceSha256"], evidence)
        sequence = read(sequence_path)
        require(sequence["continuity"]["complete"] is True and not sequence["errors"], "Incomplete sequence")
        children = sequence["children"]
        require(children and type(view["burst"]["frameCount"]) is int and
                len(children) == view["burst"]["frameCount"], "Empty sequence or frame count mismatch")
        planes = children[0]["actual"]["acquisition"]["planes"]
        require([p["eye"] for p in planes] == ["left", "right"], "Stereo planes missing/reordered")
        regions, offset = [], 0
        for plane in planes:
            require(all(type(plane[k]) is int and plane[k] > 0 for k in
                        ("sourceWidth", "sourceHeight", "stagedWidth", "stagedHeight")), "Invalid plane dimensions")
            require(len(plane["burstRegions"]) == 3, "Expected three region crops per eye")
            require(plane["boundsApplied"] is True and plane["tonemapSceneHdr"] is False, "Unsupported source transform")
            require(plane["orientation"] == dict(flipHorizontal=False, flipVertical=False), "Unsupported image orientation")
            require(plane["colourSpace"] == planes[0]["colourSpace"] and
                    plane["dxgiFormat"] == planes[0]["dxgiFormat"], "Inconsistent stereo colour encoding")
            require(plane["submittedBounds"] == dict(uMin=0.0, vMin=0.0, uMax=1.0, vMax=1.0),
                    "Non-full submitted bounds require explicit UV mapping")
            require(plane["stagedHeight"] == sum(r["height"] for r in plane["burstRegions"]), "Atlas layout mismatch")
            for i, roi in enumerate(plane["burstRegions"]):
                require(all(type(roi[k]) is int for k in ("x", "y", "width", "height")), "Non-integer ROI")
                require(0 <= roi["x"] < roi["x"] + roi["width"] <= plane["sourceWidth"] and
                        0 <= roi["y"] < roi["y"] + roi["height"] <= plane["sourceHeight"], "ROI out of bounds")
                require(roi["width"] <= plane["stagedWidth"], "ROI exceeds atlas width")
                regions.append(region_spec(plane, i, offset, config["mask"], values, policy))
            offset += plane["stagedWidth"]
        require(planes[0]["stagedHeight"] == planes[1]["stagedHeight"], "Unequal atlas heights")
        frames, previous = [], None
        geometry_keys = ("eye", "sourceWidth", "sourceHeight", "burstRegions", "stagedWidth", "stagedHeight",
                         "boundsApplied", "tonemapSceneHdr", "orientation", "submittedBounds", "colourSpace", "dxgiFormat")
        for child in children:
            require(child["state"] == "completed" and not child["errors"], "Failed frame")
            acquisition = child["actual"]["acquisition"]
            require(all(type(acquisition[k]) is int and acquisition[k] >= 0 for k in
                        ("engineFrame", "compositorCycle", "monotonicTimestampUs")), "Invalid acquisition counters")
            require(acquisition["sourceKind"] == "hmd_submission" and
                    child["actual"]["source"]["fallbackApplied"] is False, "Non-native frame source")
            require(len(acquisition["planes"]) == 2, "Missing eye")
            for expected, actual in zip(planes, acquisition["planes"]):
                require(all(actual[k] == expected[k] for k in geometry_keys), "Geometry changed within burst")
            require(type(child["ordinal"]) is int and child["ordinal"] == len(frames) + 1, "Non-consecutive ordinals")
            if previous:
                require(acquisition["engineFrame"] == previous["engineFrame"] + 1 and
                        acquisition["compositorCycle"] == previous["compositorCycle"] + 1 and
                        acquisition["monotonicTimestampUs"] > previous["monotonicTimestampUs"], "Broken acquisition continuity")
            require(len(child["artifacts"]) == 1, "Expected single stereo atlas")
            encoding = dict(colourContract="sdr_srgb", format="png", view="side_by_side",
                            width=offset, height=planes[0]["stagedHeight"])
            require(all(child["artifacts"][0]["actual"].get(k) == v for k, v in encoding.items()),
                    "Unsupported atlas encoding/layout")
            path = resolve_artifact(run, sequence_path, child["artifacts"][0], evidence)
            frames.append(dict(ordinal=child["ordinal"], timestampUs=acquisition["monotonicTimestampUs"],
                               path=str(path), sha256=child["artifacts"][0]["sha256"]))
            previous = acquisition
        jobs.append(dict(view=view["view"], kind="burst", width=offset, height=planes[0]["stagedHeight"],
                         regions=[pixel_region(r) for r in regions], frames=frames))
        still = resolve_artifact(run, manifest_path, view["fullStereo"], evidence)
        ew, eh = planes[0]["sourceWidth"], planes[0]["sourceHeight"]
        require(all((p["sourceWidth"], p["sourceHeight"]) == (ew, eh) for p in planes), "Unequal eye sizes")
        require((view["fullStereo"]["width"], view["fullStereo"]["height"]) == (2 * ew, eh), "Still dimensions mismatch")
        still_regions = [dict(r, X=r["NativeX"] + (ew if r["Eye"] == "right" else 0), Y=r["NativeY"]) for r in regions]
        jobs.append(dict(view=view["view"], kind="still", width=ew * 2, height=eh,
                         regions=[pixel_region(r) for r in still_regions], frames=[dict(ordinal=0, timestampUs=0, path=str(still))]))
        rects = []
        for r in regions:
            ref_spec = None
            if reference_values is not None:
                plane = planes[0 if r["Eye"] == "left" else 1]
                ref_spec = region_spec(plane, ("center", "transition", "outer").index(r["Zone"]),
                                       0, config["referenceMask"], reference_values, policy)
            rect = contained_rectangle(r, ref_spec)
            if rect:
                rects.append(dict(eye=r["Eye"], region=r["Zone"], zoneOwner="shared" if ref_spec else "candidate", **rect))
            else:
                for owner, spec in (("candidate", r), ("reference", ref_spec)):
                    require(spec is not None, "No comparable mask region")
                    own_rect = contained_rectangle(spec)
                    require(own_rect is not None, "Capture does not contain required mask zone")
                    rects.append(dict(eye=r["Eye"], region=r["Zone"], zoneOwner=owner, **own_rect))
        if "reference" in review:
            require(reference_values is not None, "Reference mask metadata required for regional scoring")
            reference = checked(base / review["reference"]["path"], review["reference"]["sha256"], evidence)
            score_regions = [dict(name=r["eye"] + "-" + r["region"] + "-" + r["zoneOwner"],
                                 x=(r["x"] + (ew if r["eye"] == "right" else 0)) / (ew * 2),
                                 y=r["y"] / eh, w=r["width"] / (ew * 2), h=r["height"] / eh)
                             for r in rects]
            scoring.append(dict(view=view["view"], candidate=str(still), golden=str(reference),
                                config=dict(threshold=config["similarityThreshold"], regions=score_regions)))
        phases = phase_map(review["phases"], [f["ordinal"] for f in frames]) if review["phases"] else {}
        for phase in review["phases"]:
            for endpoint in ("first", "last"):
                require(phase[endpoint + "TimestampUs"] == frames[phase[endpoint] - 1]["timestampUs"],
                        "Phase timestamps do not match selected receipt")
        audit.append(dict(view=view["view"], sequence=str(sequence_path), sequenceSha256=digest(sequence_path),
                          frames=len(frames), phases=review["phases"], goldenRectangles=rects,
                          excludedFromPhaseAnalysis=[f["ordinal"] for f in frames if f["ordinal"] not in phases]))
    return config, jobs, scoring, audit


def percentile(values, q):
    values = sorted(values)
    i = (len(values) - 1) * q
    lo, hi = math.floor(i), math.ceil(i)
    return values[lo] + (values[hi] - values[lo]) * (i - lo)


def validate_metrics(rows, jobs):
    """Require exactly one finite measurement for every planned frame/eye/zone."""
    expected = {}
    for job in jobs:
        for region in job["regions"]:
            count = sum(any(a <= x < b for a, b in zip(row[::2], row[1::2]))
                        for row in region["MaskRuns"][:region["Height"] - 1:2]
                        for x in range(0, region["Width"] - 1, 2))
            require(count > 0, "Empty sampled region")
            for index, frame in enumerate(job["frames"]):
                key = (job["view"], job["kind"], frame["ordinal"], region["Eye"], region["Zone"])
                require(key not in expected, "Duplicate planned metric")
                expected[key] = (frame["timestampUs"], count, index > 0)
    for row in rows:
        key = (row["view"], row["kind"], int(row["ordinal"]), row["eye"], row["region"])
        require(key in expected, f"Unexpected or duplicate metric: {key}")
        timestamp, count, has_previous = expected.pop(key)
        require(int(row["timestampUs"]) == timestamp and int(row["samples"]) == count, f"Metric metadata mismatch: {key}")
        require(bool(row["previousMeanAbsDiff"]) == has_previous, f"Invalid first/adjacent-frame metric: {key}")
        for name in ("meanLuma", "edgeContrast", "previousMeanAbsDiff"):
            if name == "previousMeanAbsDiff" and not has_previous:
                continue
            value = float(row[name])
            require(math.isfinite(value) and 0 <= value <= 255, f"Invalid {name}: {key}")
    require(not expected, f"Missing {len(expected)} planned metric rows")


def validate_scores(results, requests):
    require(isinstance(results, list) and len(results) == len(requests), "Missing reference-score views")
    for result, request in zip(results, requests):
        require(result["view"] == request["view"], "Reference-score view mismatch")
        require([r["name"] for r in result["regions"]] == [r["name"] for r in request["config"]["regions"]],
                "Missing, duplicate or unexpected reference-score regions")
        for region in result["regions"]:
            require(finite_number(region["ssim"]) and -1 <= region["ssim"] <= 1, "Invalid SSIM")
            require(region["threshold"] == request["config"]["threshold"] and
                    region["passed"] is (region["ssim"] >= region["threshold"]), "Inconsistent reference-score verdict")
        require(result["ssim"] == min(r["ssim"] for r in result["regions"]) and
                result["passed"] is all(r["passed"] for r in result["regions"]), "Inconsistent aggregate SSIM")


def summary(rows, jobs, config):
    validate_metrics(rows, jobs)
    summaries = []
    for job in jobs:
        if job["kind"] != "burst":
            continue
        review = next(v for v in config["views"] if v["view"] == job["view"])
        phases = phase_map(review["phases"], [f["ordinal"] for f in job["frames"]])
        times = {f["ordinal"]: f["timestampUs"] for f in job["frames"]}
        for eye in ("left", "right"):
            for region in ("center", "transition", "outer"):
                for phase in ("initial-hold", "sweep", "final-hold"):
                    selected = [r for r in rows if r["kind"] == "burst" and r["view"] == job["view"] and
                                r["eye"] == eye and r["region"] == region and
                                pair_phase(int(r["ordinal"]), phases) == phase]
                    require(len(selected) >= 2, f"Insufficient adjacent pairs: {job['view']}/{phase}")
                    counts = {int(r["samples"]) for r in selected}
                    require(len(counts) == 1, "Pixel selection changed")
                    values = [float(r["previousMeanAbsDiff"]) for r in selected]
                    cadence = [(times[int(r["ordinal"])] - times[int(r["ordinal"]) - 1]) / 1000 for r in selected]
                    summaries.append(dict(view=job["view"], eye=eye, region=region, phase=phase,
                                          pairs=len(values), pixels=counts.pop(),
                                          medianLuma255=statistics.median(values), p95Luma255=percentile(values, .95),
                                          cadenceMedianMs=statistics.median(cadence), cadenceP95Ms=percentile(cadence, .95)))
    return summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ssim-exe", type=Path)
    parser.add_argument("--measure-only", action="store_true", help="Prepare evidence for phase review without a quality verdict")
    args = parser.parse_args()
    output = args.output.resolve()
    require(not output.exists(), "Use a new derived output directory; do not overwrite evidence")
    evidence = {str(args.input.resolve()): digest(args.input)}
    producers = {str(Path(__file__).resolve().with_name(name)): digest(Path(__file__).with_name(name))
                 for name in ("image_quality_analysis.py", "ImageMetrics.cs", "Measure-ImageRegions.ps1")}
    config, jobs, scoring, audit = prepare(args.input, evidence)
    if not args.measure_only:
        for view in config["views"]:
            require(view["phases"], "Review phases first, or use --measure-only")
    if scoring:
        require(args.ssim_exe is not None, "Existing DevBench SSIM adapter required when references are supplied")
        producers[str(args.ssim_exe.resolve())] = digest(args.ssim_exe)
    output.mkdir(parents=True)
    write(output / "input.json", config)
    write(output / "plan.json", jobs)
    write(output / "golden-requests.json", scoring)
    write(output / "region-and-phase-audit.json", audit)
    subprocess.run(["pwsh", "-NoProfile", "-File", str(Path(__file__).with_name("Measure-ImageRegions.ps1")),
                    "-PlanPath", str(output / "plan.json"), "-OutputPath", str(output / "frame-metrics.csv")], check=True)
    if scoring:
        result = subprocess.run([str(args.ssim_exe.resolve()), str(output / "golden-requests.json")],
                                capture_output=True, text=True, check=True)
        scores = json.loads(result.stdout)
        validate_scores(scores, scoring)
        write(output / "reference-scores.json", scores)
    with (output / "frame-metrics.csv").open(encoding="utf-8-sig", newline="") as source:
        rows = list(csv.DictReader(source))
    if not args.measure_only:
        summaries = summary(rows, jobs, config)
        with (output / "temporal-per-eye.csv").open("w", encoding="utf-8", newline="") as target:
            writer = csv.DictWriter(target, fieldnames=summaries[0].keys())
            writer.writeheader()
            writer.writerows(summaries)
    else:
        validate_metrics(rows, jobs)
    for path, sha256 in (evidence | producers).items():
        checked(path, sha256)
    write(output / "analysis-receipt.json", dict(status="phase_review_pending" if args.measure_only else "computed",
          inputPath=str(args.input.resolve()), inputSha256=evidence[str(args.input.resolve())],
          evidenceSha256=evidence, producerSha256=producers,
          outputSha256={p.name: digest(p) for p in sorted(output.iterdir()) if p.is_file()},
          maskEffectiveRuntimeVerified=config["mask"]["effectiveRuntimeVerified"],
          referenceRole=config.get("referenceRole"), regionLabels=config["regionLabels"],
          visualReview=config.get("visualReview"),
          interpretation="Raw luminance change includes animation and camera motion; SSIM is similarity, not quality."))
    print(f"Analyzed {len(audit)} views; results: {output}")


if __name__ == "__main__":
    main()
