# SPDX-License-Identifier: GPL-3.0-or-later
import csv
import copy
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "tools/devbench-control/image_quality_analysis.py"
SPEC = importlib.util.spec_from_file_location("image_quality", MODULE_PATH)
analysis = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analysis)


def region(zone="transition", **changes):
    return dict(dict(Eye="left", Zone=zone, Model="squircle", X=0, Y=0,
                     Width=384, Height=256, NativeX=944, NativeY=712, EyeWidth=1512, EyeHeight=1680,
                     CenterX=.5, CenterY=.5, RadiusX=.25, RadiusY=.25, Power=4, Feather=.2,
                     CenterLimit=.9, OuterMargin=.1, SafeMin=.1, SafeMax=.9), **changes)


def capture_fixture(root):
    run = root/"capture"
    sequence = run/"sequence"/"manifest.json"
    sequence.parent.mkdir(parents=True)
    still, atlas = run/"still.png", sequence.parent/"atlas.png"
    still.write_bytes(b"still"); atlas.write_bytes(b"atlas")
    def artifact(path):
        return dict(path=path.name,sha256=analysis.digest(path),bytes=path.stat().st_size)
    planes = [dict(eye=eye,sourceWidth=1512,sourceHeight=1680,stagedWidth=384,stagedHeight=768,
                   boundsApplied=True,tonemapSceneHdr=False,orientation=dict(flipHorizontal=False,flipVertical=False),
                   submittedBounds=dict(uMin=0.0,vMin=0.0,uMax=1.0,vMax=1.0),colourSpace=1,dxgiFormat=28,
                   burstRegions=[dict(x=x,y=y,width=384,height=256) for x,y in ((564,712),(944,712),(1128,1200))])
              for eye in ("left","right")]
    encoding = dict(colourContract="sdr_srgb",format="png",view="side_by_side",width=768,height=768)
    children = [dict(ordinal=i,state="completed",errors=[],artifacts=[dict(artifact(atlas),committed=True,actual=encoding)],
                     actual=dict(source=dict(fallbackApplied=False),acquisition=dict(sourceKind="hmd_submission",
                         planes=planes,engineFrame=i,compositorCycle=i,monotonicTimestampUs=i*100))) for i in range(1,4)]
    seq = dict(continuity=dict(complete=True),errors=[],children=children)
    analysis.write(sequence,seq)
    manifest = dict(schema="comparison-native-images-v2",verified=True,views=[dict(view="test",
                    fullStereo=dict(artifact(still),width=3024,height=1680),
                    burst=dict(manifest="sequence/manifest.json",frameCount=3))])
    analysis.write(run/"image-manifest.json",manifest)
    values = dict(area=.5,horizontalScale=1,feather=.05,leftX=0,leftY=0,rightX=0,rightY=0)
    analysis.write(root/"settings.json",values)
    config = dict(schema="stereo-image-analysis-v1",run="capture",
                  imageManifestSha256=analysis.digest(run/"image-manifest.json"),
                  mask=dict(source=dict(path="settings.json",sha256=analysis.digest(root/"settings.json")),
                            model="squircle",power=4,effectiveRuntimeVerified=False,fields={k:"/"+k for k in values}),
                  regionPolicy=dict(centerDistanceMax=.9,outerDistanceMargin=.1,safeUvMin=.1,safeUvMax=.9),
                  views=[dict(view="test",sequenceSha256=analysis.digest(sequence),phases=[])])
    analysis.write(root/"input.json",config)
    return config, seq, sequence


class AnalysisTest(unittest.TestCase):
    def test_prepare_qualifies_receipts_and_rejects_malformed_acquisition(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config, sequence, path = capture_fixture(root)
            # Geometry selection has independent pixel tests; isolate receipt admission here.
            with patch.object(analysis,"pixel_region",side_effect=lambda r:r), patch.object(analysis,"contained_rectangle",
                              return_value=dict(x=564,y=712,width=8,height=8)):
                evidence = {}
                _, jobs, _, audit = analysis.prepare(root/"input.json",evidence)
                self.assertEqual(len(jobs),2)
                self.assertEqual(audit[0]["frames"],3)
                self.assertEqual(len(evidence),5)
                variants = []
                empty = copy.deepcopy(sequence); empty["children"] = []; variants.append(empty)
                for field, value in (("sourceWidth",1512.5),("orientation",{}),("burstRegions",[])):
                    altered = copy.deepcopy(sequence)
                    altered["children"][0]["actual"]["acquisition"]["planes"][0][field] = value
                    variants.append(altered)
                altered = copy.deepcopy(sequence)
                altered["children"][1]["actual"]["acquisition"]["engineFrame"] = 9; variants.append(altered)
                altered = copy.deepcopy(sequence)
                altered["children"][0]["artifacts"][0]["actual"]["colourContract"] = "hdr"; variants.append(altered)
                for variant in variants:
                    analysis.write(path,variant)
                    config["views"][0]["sequenceSha256"] = analysis.digest(path)
                    analysis.write(root/"input.json",config)
                    with self.subTest(sequence=variant), self.assertRaises(ValueError):
                        analysis.prepare(root/"input.json")

    def test_changed_input_during_measurement_cannot_publish_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path, output = root/"input.json", root/"output"
            config = dict(mask=dict(effectiveRuntimeVerified=False),regionLabels={},views=[])
            analysis.write(config_path,config)
            job = dict(view="test",kind="burst",regions=[dict(Eye="left",Zone="center",Width=4,Height=4,MaskRuns=[[0,4]]*4)],
                       frames=[dict(ordinal=1,timestampUs=100)])
            def runner(*args,**kwargs):
                (output/"frame-metrics.csv").write_text(
                    "view,kind,ordinal,timestampUs,eye,region,samples,meanLuma,edgeContrast,previousMeanAbsDiff\n"
                    "test,burst,1,100,left,center,4,10,2,\n")
                analysis.write(config_path,dict(config,changed=True))
            with patch.object(sys,"argv",["analyzer","--input",str(config_path),"--output",str(output),"--measure-only"]), \
                 patch.object(analysis,"prepare",return_value=(config,[job],[],[])), \
                 patch.object(analysis.subprocess,"run",side_effect=runner):
                with self.assertRaisesRegex(ValueError,"Hash mismatch"):
                    analysis.main()
            self.assertFalse((output/"analysis-receipt.json").exists())

    def test_json_pointer_reads_runtime_arrays(self):
        self.assertEqual(analysis.pointer({"results":[{"a/b":.5}]}, "/results/0/a~1b"), .5)
        self.assertEqual(analysis.pointer({"a":{"":3}}, "/a/"), 3)
        self.assertEqual(analysis.pointer({"a":3}, ""), {"a":3})
        for index in ("-1", "01"):
            with self.assertRaises(ValueError):
                analysis.pointer([1,2], "/" + index)

    def test_rectangle_search_retains_smaller_valid_window(self):
        spec = region(Width=30, Height=30, NativeX=0, NativeY=0)
        with patch.object(analysis, "includes", side_effect=lambda s,x,y: x < 7 or (20 <= x < 28 and y < 8)):
            self.assertEqual(analysis.contained_rectangle(spec), dict(x=20,y=0,width=8,height=8))

    def test_crop_requires_exact_pixels_and_accepts_effective_pixel_metadata(self):
        plane = dict(eye="left", sourceWidth=101, sourceHeight=100,
                     burstRegions=[dict(x=0,y=0,width=50,height=50)])
        policy = dict(centerDistanceMax=.9,outerDistanceMargin=.1,safeUvMin=.1,safeUvMax=.9)
        values = dict(leftX=.25,leftY=.25,leftW=.5,leftH=.5,featherPixels=8)
        mask = dict(model="rectangle-inward")
        with self.assertRaisesRegex(ValueError, "Fractional crop"):
            analysis.region_spec(plane,0,0,mask,values,policy)
        values.update(leftX=25,leftY=25,leftW=50,leftH=50)
        spec = analysis.region_spec(plane,0,0,dict(mask,cropUnits="pixels"),values,policy)
        self.assertEqual((spec["CropX"], spec["CropWidth"]), (25,50))
        with self.assertRaisesRegex(ValueError, "outside eye"):
            analysis.region_spec(plane,0,0,dict(mask,cropUnits="pixels"),dict(values,leftW=100),policy)

    def test_relocated_capture_never_reads_original_or_escapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original, selected = root/"original"/"capture", root/"selected"/"capture"
            for run in (original, selected):
                (run/"sequence").mkdir(parents=True)
                (run/"sequence"/"manifest.json").write_text("{}")
            self.assertEqual(analysis.resolve_capture_path(selected,selected,original/"sequence/manifest.json"),
                             (selected/"sequence/manifest.json").resolve())
            self.assertEqual(analysis.resolve_capture_path(selected,selected,"sequence/manifest.json"),
                             (selected/"sequence/manifest.json").resolve())
            for path in ("../outside.json", root/"unrelated.json"):
                with self.assertRaises(ValueError):
                    analysis.resolve_capture_path(selected,selected,path)

    def test_metric_validation_rejects_missing_duplicate_and_corrupt_rows(self):
        job = dict(view="test",kind="burst",regions=[dict(Eye="left",Zone="center",Width=4,Height=4,MaskRuns=[[0,4]]*4)],
                   frames=[dict(ordinal=i,timestampUs=i*100) for i in range(1,4)])
        rows = [dict(view="test",kind="burst",eye="left",region="center",ordinal=str(i),timestampUs=str(i*100),
                     samples="4",meanLuma="10",edgeContrast="2",previousMeanAbsDiff="1" if i>1 else "") for i in range(1,4)]
        analysis.validate_metrics(rows,[job])
        bad_rows = [rows[:-1], rows+[rows[0]]]
        for field, value in (("samples","3"),("timestampUs","100"),("meanLuma","nan"),
                             ("previousMeanAbsDiff",""),("edgeContrast","256"),("eye","right")):
            altered = copy.deepcopy(rows)
            altered[1][field] = value
            bad_rows.append(altered)
        for altered in bad_rows:
            with self.subTest(rows=altered), self.assertRaises(ValueError):
                analysis.validate_metrics(altered,[job])

    def test_reference_scores_must_cover_requests_and_have_consistent_verdicts(self):
        requests = [dict(view="test",config=dict(threshold=.98,regions=[dict(name="left-center")]))]
        result = dict(view="test",regions=[dict(name="left-center",ssim=.9,threshold=.98,passed=False)],ssim=.9,passed=False)
        analysis.validate_scores([result],requests)
        invalid = [[],[dict(result,regions=[])],[dict(result,ssim=.8)],[dict(result,passed=True)]]
        for field,value in (("ssim",float("nan")),("threshold",.8),("passed",True),("name","wrong")):
            altered = copy.deepcopy(result)
            altered["regions"][0][field] = value
            invalid.append([altered])
        for results in invalid:
            with self.subTest(results=results), self.assertRaises(ValueError):
                analysis.validate_scores(results,requests)

    def test_transition_rectangle_contains_only_transition_pixels(self):
        spec = region()
        rect = analysis.contained_rectangle(spec)
        self.assertIsNotNone(rect)
        for y in range(rect["y"], rect["y"] + rect["height"]):
            for x in range(rect["x"], rect["x"] + rect["width"]):
                self.assertTrue(analysis.includes(spec, x-spec["NativeX"], y-spec["NativeY"]))

    def test_disjoint_fork_transitions_are_not_called_shared(self):
        csx = region()
        os_region = region(Model="rectangle-inward", CropX=378, CropY=420,
                           CropWidth=756, CropHeight=840, FeatherPixels=64)
        self.assertIsNone(analysis.contained_rectangle(csx, os_region))
        self.assertEqual(analysis.contained_rectangle(os_region)["x"], 1070)

    def test_safe_outer_excludes_border(self):
        spec = region("outer", NativeX=1128, NativeY=1200)
        self.assertFalse(analysis.includes(spec, 383, 120))
        rect = analysis.contained_rectangle(spec)
        self.assertLessEqual((rect["x"] + rect["width"] - .5) / 1512, .9)

    def test_offsets_and_eye_size_change_selection(self):
        a = analysis.contained_rectangle(region())
        b = analysis.contained_rectangle(region(CenterX=.52))
        self.assertNotEqual(a, b)
        self.assertNotEqual(a, analysis.contained_rectangle(region(EyeWidth=1600)))

    def test_pixel_runs_and_rectangle_share_selection(self):
        spec = region(Width=64, Height=16, NativeX=1120)
        raster = analysis.pixel_region(spec)
        for y, row in enumerate(raster["MaskRuns"]):
            for x in range(spec["Width"]):
                self.assertEqual(any(a <= x < b for a,b in zip(row[::2],row[1::2])),
                                 analysis.includes(spec, x, y))

    def test_pairs_never_cross_phase_or_excluded_prefix_tail(self):
        phases = analysis.phase_map([
            dict(name="initial-hold",first=5,last=8,basis="review"),
            dict(name="sweep",first=9,last=12,basis="review"),
            dict(name="final-hold",first=13,last=16,basis="review")], range(1,20))
        for ordinal in (1,4,5,9,13,17,18):
            self.assertIsNone(analysis.pair_phase(ordinal, phases))
        self.assertEqual(analysis.pair_phase(6, phases), "initial-hold")
        self.assertEqual(analysis.pair_phase(16, phases), "final-hold")

    def test_reject_missing_or_reordered_phases(self):
        with self.assertRaises(ValueError):
            analysis.phase_map([], range(1, 20))
        with self.assertRaises(ValueError):
            analysis.phase_map([dict(name=n,first=a,last=a+2,basis="review") for n,a in
                               [("sweep",1),("initial-hold",4),("final-hold",7)]],range(1,20))

    def test_hash_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"data"
            path.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                analysis.checked(path, "0"*64)

    @unittest.skipUnless(os.name == "nt", "System.Drawing pixel engine requires Windows")
    def test_pixel_engine_ignores_unselected_pixels_and_measures_real_delta(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def bmp(name, value, outside):
                pixels = b"".join(bytes([value if x < 2 else outside])*3 for y in range(4) for x in range(4))
                header = b"BM" + struct.pack("<IHHI", 54+len(pixels),0,0,54)
                dib = struct.pack("<IiiHHIIiiII",40,4,4,1,24,0,len(pixels),0,0,0,0)
                path=root/name; path.write_bytes(header+dib+pixels)
                return str(path)
            frames=[dict(path=bmp("a.bmp",10,255),ordinal=1,timestampUs=1),
                    dict(path=bmp("b.bmp",20,0),ordinal=2,timestampUs=40001)]
            plan=[dict(view="synthetic",kind="burst",width=4,height=4,frames=frames,
                       regions=[dict(Eye="left",Zone="center",X=0,Y=0,Width=4,Height=4,MaskRuns=[[0,2]]*4)])]
            analysis.write(root/"plan.json",plan)
            subprocess.run(["pwsh","-NoProfile","-File",str(MODULE_PATH.with_name("Measure-ImageRegions.ps1")),
                            "-PlanPath",str(root/"plan.json"),"-OutputPath",str(root/"metrics.csv")],check=True,
                           capture_output=True,text=True)
            with (root/"metrics.csv").open(encoding="utf-8-sig") as source:
                rows=list(csv.DictReader(source))
            self.assertEqual(float(rows[1]["previousMeanAbsDiff"]),10)
            self.assertEqual(float(rows[1]["edgeContrast"]),0)
            self.assertEqual(rows[0]["previousMeanAbsDiff"],"")
            for width, x, error in ((2147483647,0,"Invalid image dimensions"),
                                    (4,2147483647,"Region outside image")):
                plan[0]["width"] = width
                plan[0]["regions"][0]["X"] = x
                analysis.write(root/"plan.json",plan)
                result = subprocess.run(["pwsh","-NoProfile","-File",str(MODULE_PATH.with_name("Measure-ImageRegions.ps1")),
                                         "-PlanPath",str(root/"plan.json"),"-OutputPath",str(root/"invalid.csv")],
                                        capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
                self.assertIn(error,result.stderr)
                self.assertFalse((root/"invalid.csv").exists())


if __name__ == "__main__":
    unittest.main()
