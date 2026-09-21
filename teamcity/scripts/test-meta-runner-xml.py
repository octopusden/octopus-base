#!/usr/bin/env python3
"""Formatting must preserve the verdict; semantic regressions must still fail."""

import copy
import importlib.util
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("xml_check", HERE / "check-meta-runner-xml.py")
xml_check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(xml_check)
CASES = (
    ("OctopusCalculateBuildParameters", "Calculate PROJECT_VERSION", {
        "env.BUILD_COUNTER": "%build.counter%",
        "env.IS_DEFAULT_BRANCH": "%teamcity.build.branch.is_default%",
    }),
    ("OctopusCheckReleaseVersionIsNew", "Check release version is new", {
        "env.BUILD_NUMBER": "%BUILD_NUMBER%",
        "env.LAST_RELEASE_VERSION": "%LAST_RELEASE_VERSION%",
    }),
)


class MetaRunnerXmlTest(unittest.TestCase):
    def cases(self):
        for filename, name, bindings in CASES:
            root = ET.parse(HERE.parent.parent / "teamcity.meta-runners" / (filename + ".xml")).getroot()
            yield root, name, bindings

    def test_equivalent_formatting(self):
        for root, name, bindings in self.cases():
            with self.subTest(runner=name):
                self.assertEqual([], xml_check.check(root, name, bindings))
                for element in root.iter():
                    attributes = list(element.attrib.items())[::-1]
                    element.attrib.clear()
                    element.attrib.update(attributes)
                text = ET.tostring(root, encoding="unicode")
                single_quotes = re.sub(r'="([^"]*)"', lambda m: "='" + m[1].replace("'", "&apos;") + "'", text)
                for formatted in (text, text.replace(" />", "/>"), single_quotes,
                                  text.replace(" name=", "\n name=").replace(" value=", "\n value=")):
                    self.assertEqual([], xml_check.check(ET.fromstring(formatted), name, bindings))

    def test_wrong_runner_settings(self):
        for original, name, bindings in self.cases():
            for field in ("type", "use.custom.script", "log.stderr.as.errors", "env."):
                for operation in ("remove", "wrong"):
                    with self.subTest(runner=name, field=field, operation=operation):
                        root = copy.deepcopy(original)
                        runner = root.find(f"./settings/build-runners/runner[@name='{name}']")
                        if field == "type":
                            runner.attrib.pop("type")
                            if operation == "wrong":
                                runner.set("type", "jetbrains_powershell")
                        elif field == "env.":
                            param = root.find(f"./settings/parameters/param[@name='{next(iter(bindings))}']")
                            root.find("./settings/parameters").remove(param)
                            if operation == "wrong":
                                runner.find("./parameters").append(param)
                        else:
                            param = runner.find(f"./parameters/param[@name='{field}']")
                            if operation == "remove":
                                runner.find("./parameters").remove(param)
                            else:
                                param.set("value", "false")
                        self.assertTrue(xml_check.check(root, name, bindings))

    def test_invalid_requirement(self):
        for original, name, bindings in self.cases():
            for mutation in ("commented", "misplaced", "value", "name", "operator", "split"):
                with self.subTest(runner=name, mutation=mutation):
                    root = copy.deepcopy(original)
                    requirements = root.find("./settings/requirements")
                    requirement = requirements.find("./does-not-contain")
                    if mutation == "commented":
                        requirements.remove(requirement)
                        requirements.append(ET.Comment(ET.tostring(requirement, encoding="unicode")))
                    elif mutation == "misplaced":
                        root.find("./settings").remove(requirements)
                        root.append(requirements)
                    elif mutation == "operator":
                        requirement.tag = "contains"
                    elif mutation == "split":
                        requirement.set("value", "Linux")
                        ET.SubElement(requirements, "equals", name="unrelated", value="Windows")
                    else:
                        requirement.set(mutation, "wrong")
                    self.assertTrue(xml_check.check(root, name, bindings))


if __name__ == "__main__":
    unittest.main()
