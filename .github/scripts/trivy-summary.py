#!/usr/bin/env python3
"""Summarizes the weekly image scan for the job summary, and decides its result.

    trivy-summary.py DIR IGNOREFILE

DIR holds one Trivy JSON report per image (security-scan.yml). Prints a
Markdown table, then each finding, and exits 1 when any image has a CRITICAL
vulnerability with a fix: the scan's reports keep only fixed HIGH and
CRITICAL ones (--ignore-unfixed), minus .trivyignore.yaml. HIGH ones are
listed but do not fail it: they usually go away with the next image the
weekly update pull requests bring.

It also exits 1 when a vulnerability accepted in IGNOREFILE (.trivyignore.yaml)
is no longer found in any image (the reports list what it suppressed, with
--show-suppressed): the acceptance is no longer needed, and goes.
"""

import json
import pathlib
import re
import sys


def accepted_vulnerabilities(path):
    """The ids under "vulnerabilities:" in the ignore file, read line by line
    so the script needs nothing beyond Python's standard library."""
    ids, inside = [], False
    for line in pathlib.Path(path).read_text().splitlines():
        if re.match(r"^[a-z_]+:", line):
            inside = line.startswith("vulnerabilities:")
        elif inside and (m := re.match(r"^\s*- id: *(\S+)", line)):
            ids.append(m.group(1))
    return ids


def main():
    reports = sorted(pathlib.Path(sys.argv[1]).glob("*.json"))
    if not reports:
        print("No reports: the scan did not run.")
        return 1
    rows, details, critical, failed = [], [], 0, 0
    suppressed = set()
    for path in reports:
        try:
            data = json.loads(path.read_text())
        except ValueError:
            failed += 1
            rows.append(f"| `{path.stem}` | not scanned | not scanned |")
            continue
        image = data.get("ArtifactName", path.stem)
        counts = {"CRITICAL": 0, "HIGH": 0}
        for result in data.get("Results", []):
            for found in result.get("ExperimentalModifiedFindings") or []:
                if found.get("Type") == "vulnerability":
                    suppressed.add(found.get("Finding", {}).get("VulnerabilityID"))
            for vuln in result.get("Vulnerabilities") or []:
                severity = vuln.get("Severity", "")
                if severity not in counts:
                    continue
                counts[severity] += 1
                details.append(
                    f"| `{image.split('@')[0]}` | {severity} | {vuln['VulnerabilityID']} | "
                    f"`{vuln['PkgName']}` {vuln.get('InstalledVersion', '')} | {vuln.get('FixedVersion', '')} | "
                    f"`{result.get('Target', '')[:60]}` |"
                )
        critical += counts["CRITICAL"]
        rows.append(f"| `{image.split('@')[0]}` | {counts['CRITICAL']} | {counts['HIGH']} |")
    print("## Images on the server: vulnerabilities with a fix\n")
    print("| Image | Critical | High |\n|---|---|---|")
    print("\n".join(rows))
    if details:
        print("\n| Image | Severity | ID | Package | Fixed in | Where |\n|---|---|---|---|---|---|")
        print("\n".join(details))
    if failed:
        print(f"\n**{failed} image(s) not scanned.** The step 'Scan each image' shows why.")
    if critical:
        print(
            f"\n**{critical} critical.** Update the image (its weekly pull request, or a new digest of the same "
            "tag), or accept it for a while in `.trivyignore.yaml` with a reason and an `expired_at`."
        )
    # Only when every image was scanned: a missing report proves nothing.
    gone = [] if failed else [v for v in accepted_vulnerabilities(sys.argv[2]) if v not in suppressed]
    if gone:
        print(
            f"\n**No longer found: {', '.join(gone)}.** No image has it any more: remove its entry from "
            "`.trivyignore.yaml`."
        )
    return 1 if critical or failed or gone else 0


if __name__ == "__main__":
    sys.exit(main())
