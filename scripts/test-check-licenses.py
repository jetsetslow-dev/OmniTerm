#!/usr/bin/env python3
"""Pins scripts/check-licenses.py without the network: how it names licence texts, how it reads the
allowlist from a workflow, and which modules it fails."""
import importlib.util
import pathlib
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_licenses", HERE / "check-licenses.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def expect(got, want, what):
    if got != want:
        raise SystemExit(f"check-licenses: {what}: expected {want!r}, got {got!r}")


BSD3 = """Copyright 2009 The Go Authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission."""
BSD2 = """Redistribution and use in source and binary forms, with or without modification, are
permitted provided that the following conditions are met: ..."""
PATENTS = """Additional IP Rights Grant (Patents)

"This implementation" means the copyrightable works distributed by
Google as part of the Go project.
... to make, have made, use, offer to sell, sell, import, transfer and otherwise
run, modify and propagate the contents of this implementation of Go, ..."""
BSD2_VIEWS = """Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met: ...

The views and conclusions contained in the software and documentation
are those of the authors and should not be interpreted as representing
official policies, either expressed or implied, of Richard Crowley."""
MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software ..."""
APACHE = """                                 Apache License
                           Version 2.0, January 2004"""
TAILSCALE_PATENTS = """Additional IP Rights Grant (Patents)

"This implementation" means the copyrightable works distributed by
Tailscale Inc. as part of the Tailscale project.

Tailscale Inc. hereby grants to You a perpetual, worldwide,
non-exclusive, no-charge, royalty-free, irrevocable (except as stated
in this section) patent license to make, have made, use, offer to
sell, sell, import, transfer and otherwise run, modify and propagate
the contents of this implementation of Tailscale, ..."""
ISC_AND_OR = """Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies."""
ISC_AND = """Permission to use, copy, modify, and distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies."""
GPL = """GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007"""
AGPL = """GNU AFFERO GENERAL PUBLIC LICENSE Version 3, 19 November 2007 ... the GNU General Public License"""

expect(check.licences_in(BSD3), {"BSD-3-Clause"}, "the three-clause BSD is not also called two-clause")
expect(check.licences_in(BSD2), {"BSD-2-Clause"}, "the two-clause BSD")
expect(check.licences_in(BSD2_VIEWS), {"BSD-2-Clause-Views"},
       "the FreeBSD licence (go-metrics'), which Dependency review names apart from BSD-2-Clause")
expect(check.licences_in(PATENTS), {"LicenseRef-scancode-google-patent-license-golang"}, "Go's PATENTS file")
expect(check.licences_in(TAILSCALE_PATENTS), {"LicenseRef-scancode-google-patent-license-golang"},
       "Tailscale's PATENTS file, Go's grant with Tailscale's name")
expect(check.licences_in(ISC_AND_OR), {"ISC"}, "ISC as OpenBSD words it")
expect(check.licences_in(ISC_AND), {"ISC"}, "ISC worded \"modify, and distribute\" (coder/websocket)")
expect(check.licences_in(MIT), {"MIT"}, "MIT")
expect(check.licences_in(APACHE + "\nSome files carry the following license:\n" + MIT), {"Apache-2.0", "MIT"},
       "a file holding two licences (gVisor's)")
expect(check.licences_in(GPL), {"GPL"}, "the GPL")
expect(check.licences_in(AGPL), {"AGPL"}, "the AGPL, which quotes the GPL's name")
expect(check.licences_in("All rights reserved."), set(), "an unnamed licence")

with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    workflow = tmp / "dependency-review.yml"
    workflow.write_text("""jobs:
  review:
    steps:
      - uses: actions/dependency-review-action@abc # v5.0.0
        with:
          fail-on-severity: moderate
          # A comment inside the list is not a licence.
          allow-licenses: >-
            Apache-2.0, MIT,
            # Nor is this one.
            BSD-3-Clause,
            LicenseRef-scancode-google-patent-license-golang
          comment-summary-in-pr: never
""")
    allowed = check.allowed_licences(workflow)
    expect(allowed, {"Apache-2.0", "MIT", "BSD-3-Clause", "LicenseRef-scancode-google-patent-license-golang"},
           "the folded allowlist, without comments or the next key")
    inline = tmp / "inline.yml"
    inline.write_text("        with:\n          allow-licenses: MIT, ISC\n")
    expect(check.allowed_licences(inline), {"MIT", "ISC"}, "an allowlist on one line")
    expect(check.allowed_licences(HERE.parent / ".github/workflows/dependency-review.yml") >= {
        "BSD-3-Clause", "LicenseRef-scancode-google-patent-license-golang"}, True,
        "the real workflow allows Go's x/ libraries")

    def module(name, **files):
        directory = tmp / name
        directory.mkdir()
        for file, text in files.items():
            (directory / file.replace("_", ".")).write_text(text)
        (directory / "README_md").write_text(GPL)  # Not a licence file, so never read as one.
        return name, directory

    good = [module("x-net", LICENSE=BSD3, PATENTS=PATENTS), module("wireguard", LICENSE_md=MIT)]
    expect(check.problems(good, allowed), [], "allowed modules")
    expect(check.problems(good, allowed - {"LicenseRef-scancode-google-patent-license-golang"}),
           [("x-net", "PATENTS is LicenseRef-scancode-google-patent-license-golang, which allow-licenses does not list")],
           "the PATENTS file Dependency review rejected on PR #147")
    expect(check.problems([module("copyleft", COPYING=GPL)], allowed),
           [("copyleft", "COPYING is GPL, which allow-licenses does not list")], "a GPL module")
    expect(check.problems([module("bare")], allowed), [("bare", "has no licence file")], "no licence file")
    expect(check.problems([module("go-metrics", LICENSE=BSD2_VIEWS)], allowed | {"BSD-2-Clause"}),
           [("go-metrics", "LICENSE is BSD-2-Clause-Views, which allow-licenses does not list")],
           "the FreeBSD licence Dependency review rejected on PR #154 is not let through as BSD-2-Clause")
    # tailscale.com's license_test.go is code that checks its files' headers, not a licence file.
    ts = tmp / "tailscale"
    ts.mkdir()
    (ts / "LICENSE").write_text(BSD3)
    (ts / "PATENTS").write_text(TAILSCALE_PATENTS)
    (ts / "license_test.go").write_text("package tailscaleroot\n\nfunc TestLicenseHeaders(t *testing.T) {}\n")
    (ts / "LICENSE-MIT").write_text(MIT)
    expect(check.problems([("tailscale", ts)], allowed), [], "Tailscale's licence files, and no source file read as one")
    expect(check.problems([("tailscale", ts)], allowed - {"MIT"}),
           [("tailscale", "LICENSE-MIT is MIT, which allow-licenses does not list")],
           "a licence file with a suffix is still read")
    expect([m for _, m in check.problems([module("odd", LICENSE="All rights reserved.")], allowed)],
           ["LICENSE holds a licence this script cannot name; read it and add it to SIGNATURES"], "an unnamed licence")

print("test-check-licenses: licence check tests passed")
